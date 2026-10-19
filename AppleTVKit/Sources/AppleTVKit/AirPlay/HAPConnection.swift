import Foundation
import Network

/// A TCP connection that can switch to HAP transport encryption: plaintext is split in
/// blocks of at most 1024 bytes, each sent as a 2-byte little-endian length (used as
/// additional authenticated data) followed by the ChaCha20-Poly1305 sealed block.
final class HAPConnection: @unchecked Sendable {
    let queue: DispatchQueue
    private let connection: NWConnection
    private var cipher: ChaChaStream?
    private var encryptedBuffer = Data()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isClosed = false

    /// Called on `queue` with decrypted bytes.
    var dataHandler: ((Data) -> Void)?
    /// Called on `queue` once when the connection goes away.
    var closeHandler: ((Error?) -> Void)?

    init(endpoint: NWEndpoint, queue: DispatchQueue) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.connectionTimeout = 10
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Our address on the local network, as seen on this connection.
    var localHost: String? {
        if case .hostPort(let host, _) = connection.currentPath?.localEndpoint {
            return Self.describe(host)
        }
        return nil
    }

    var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
            return host
        }
        return nil
    }

    private static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    return continuation.resume(throwing: CompanionError.connectionFailed("connexion annulée"))
                }
                self.readyContinuation = continuation
                self.connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, let pending = self.readyContinuation else { return }
                    self.readyContinuation = nil
                    pending.resume(throwing: CompanionError.connectionFailed("délai dépassé"))
                    self.close()
                }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
            receive()
        case .waiting(let error):
            if let pending = readyContinuation {
                readyContinuation = nil
                pending.resume(throwing: CompanionError.connectionFailed(error.localizedDescription))
                close()
            }
        case .failed(let error):
            if let pending = readyContinuation {
                readyContinuation = nil
                pending.resume(throwing: CompanionError.connectionFailed(error.localizedDescription))
            }
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.received(data) }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    private func received(_ data: Data) {
        guard cipher != nil else {
            dataHandler?(data)
            return
        }
        encryptedBuffer.append(data)
        var plaintext = Data()
        while encryptedBuffer.count >= 2 {
            let lengthBytes = Data(encryptedBuffer.prefix(2))
            let length = Int(lengthBytes.readLittleEndian(at: 0, count: 2))
            guard encryptedBuffer.count >= 2 + length + 16 else { break }
            let block = Data(encryptedBuffer.dropFirst(2).prefix(length + 16))
            encryptedBuffer = Data(encryptedBuffer.dropFirst(2 + length + 16))
            do {
                plaintext.append(try cipher!.decrypt(block, aad: lengthBytes))
            } catch {
                logger.error("HAP decrypt failed: \(error.localizedDescription)")
                finish(error)
                return
            }
        }
        if !plaintext.isEmpty { dataHandler?(plaintext) }
    }

    /// Must be called on `queue`, before any further data is exchanged.
    func enableEncryption(outputKey: Data, inputKey: Data) {
        cipher = ChaChaStream(outputKey: outputKey, inputKey: inputKey, layout: .zeroPaddedCounter8)
    }

    /// Must be called on `queue`.
    func send(_ data: Data) {
        guard !isClosed else { return }
        var output = Data()
        if cipher != nil {
            var offset = 0
            while offset < data.count {
                let block = data.subdata(in: offset..<min(offset + 1024, data.count))
                offset += block.count
                var length = Data()
                length.append(littleEndian: UInt16(block.count))
                do {
                    output.append(length)
                    output.append(try cipher!.encrypt(block, aad: length))
                } catch {
                    finish(error)
                    return
                }
            }
        } else {
            output = data
        }
        connection.send(content: output, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    func close() {
        queue.async {
            self.connection.cancel()
            self.finish(nil)
        }
    }

    private func finish(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        closeHandler?(error)
        closeHandler = nil
        dataHandler = nil
    }
}
