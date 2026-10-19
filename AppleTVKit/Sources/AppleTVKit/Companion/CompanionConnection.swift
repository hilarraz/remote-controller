import Foundation
import Network
import os

let logger = Logger(subsystem: "AppleTVKit", category: "companion")

/// Set ATVKIT_DEBUG=1 to print every Companion message to stderr.
let traceMessages = ProcessInfo.processInfo.environment["ATVKIT_DEBUG"] != nil

func trace(_ message: @autoclosure () -> String) {
    guard traceMessages else { return }
    FileHandle.standardError.write(Data("[\(Date().timeIntervalSince1970)] \(message())\n".utf8))
}

enum CompanionFrameType: UInt8 {
    case unknown = 0
    case noOp = 1
    case pairSetupStart = 3
    case pairSetupNext = 4
    case pairVerifyStart = 5
    case pairVerifyNext = 6
    case unencryptedOPACK = 7
    case encryptedOPACK = 8
    case packedOPACK = 9
    case pairAuthRequest = 10
    case pairAuthResponse = 11
    case sessionStartRequest = 16
    case sessionStartResponse = 17
    case sessionData = 18
    case familyIdentityRequest = 32
    case familyIdentityResponse = 33
    case familyIdentityUpdate = 34
}

public enum CompanionError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case timeout(String)
    case protocolError(String)
    case commandFailed(String)
    case noTextField

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Non connecté à l'Apple TV."
        case .connectionFailed(let reason): return "Connexion impossible : \(reason)"
        case .timeout(let what): return "L'Apple TV ne répond pas (\(what))."
        case .protocolError(let reason): return "Réponse inattendue : \(reason)"
        case .commandFailed(let reason): return "Commande refusée : \(reason)"
        case .noTextField: return "Aucun champ de texte n'est actif sur l'Apple TV."
        }
    }
}

/// TCP transport for Companion frames: a 1-byte type, a 3-byte big-endian length and a
/// payload that is ChaCha20-Poly1305 encrypted once pair-verify has completed.
final class CompanionConnection: @unchecked Sendable {
    let queue: DispatchQueue
    private let connection: NWConnection
    private var buffer = Data()
    private var cipher: ChaChaStream?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isClosed = false

    /// Called on `queue` for each received frame.
    var frameHandler: ((CompanionFrameType, Data) -> Void)?
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
            // The path is unusable (e.g. host unreachable); fail fast instead of waiting forever.
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
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    private func processBuffer() {
        while buffer.count >= 4 {
            let header = Data(buffer.prefix(4))
            let length = Int(header.readBigEndian(at: 1, count: 3))
            guard buffer.count >= 4 + length else { break }
            var payload = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))

            let type = CompanionFrameType(rawValue: header[0]) ?? .unknown
            if cipher != nil, !payload.isEmpty {
                do {
                    payload = try cipher!.decrypt(payload, aad: header)
                } catch {
                    logger.error("Failed to decrypt frame: \(error.localizedDescription)")
                    continue
                }
            }
            frameHandler?(type, payload)
        }
    }

    /// Must be called on `queue`.
    func enableEncryption(outputKey: Data, inputKey: Data) {
        cipher = ChaChaStream(outputKey: outputKey, inputKey: inputKey, layout: .counter12)
    }

    /// Must be called on `queue`.
    func send(_ type: CompanionFrameType, payload: Data) {
        guard !isClosed else { return }
        var body = payload
        var length = payload.count
        if cipher != nil, !payload.isEmpty { length += 16 }
        var header = Data([type.rawValue])
        header.append(UInt8((length >> 16) & 0xFF))
        header.append(UInt8((length >> 8) & 0xFF))
        header.append(UInt8(length & 0xFF))
        if cipher != nil, !payload.isEmpty {
            do {
                body = try cipher!.encrypt(payload, aad: header)
            } catch {
                logger.error("Failed to encrypt frame: \(error.localizedDescription)")
                return
            }
        }
        connection.send(content: header + body, completion: .contentProcessed { [weak self] error in
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
        frameHandler = nil
    }
}

/// Request/response and event plumbing on top of `CompanionConnection`.
final class CompanionChannel: @unchecked Sendable {
    enum MessageType: Int64 {
        case event = 1
        case request = 2
        case response = 3
    }

    let connection: CompanionConnection
    private var queue: DispatchQueue { connection.queue }
    private var nextXID = Int64.random(in: 0...0xFFFF)
    private var pendingAuth: [CompanionFrameType: (token: Int64, continuation: CheckedContinuation<OPACK, Error>)] = [:]
    private var pendingResponses: [Int64: CheckedContinuation<OPACK, Error>] = [:]

    /// Called on the connection queue for each event (identifier, content).
    var eventHandler: ((String, OPACK) -> Void)?
    /// Called on the connection queue when the transport closes.
    var closeHandler: ((Error?) -> Void)?

    init(endpoint: NWEndpoint) {
        connection = CompanionConnection(endpoint: endpoint, queue: DispatchQueue(label: "AppleTVKit.companion"))
        connection.frameHandler = { [weak self] type, payload in self?.handleFrame(type, payload) }
        connection.closeHandler = { [weak self] error in self?.handleClose(error) }
    }

    func start() async throws {
        try await connection.start()
    }

    func close() {
        connection.close()
    }

    func enableEncryption(outputKey: Data, inputKey: Data) {
        queue.sync { connection.enableEncryption(outputKey: outputKey, inputKey: inputKey) }
    }

    /// Sends a pair-setup / pair-verify frame and waits for the matching `*Next` frame.
    func exchangeAuth(_ type: CompanionFrameType, _ content: [(String, OPACK)], timeout: TimeInterval = 30) async throws -> OPACK {
        let responseType: CompanionFrameType
        switch type {
        case .pairSetupStart: responseType = .pairSetupNext
        case .pairVerifyStart: responseType = .pairVerifyNext
        default: responseType = type
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let xid = self.takeXID()
                self.pendingAuth[responseType] = (xid, continuation)
                var message = content
                message.append(("_x", .int(xid)))
                self.connection.send(type, payload: OPACK.dict(message.map { (.string($0.0), $0.1) }).encoded())
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    // Only expire this exchange, not a later one waiting on the same frame type.
                    guard let pending = self.pendingAuth[responseType], pending.token == xid else { return }
                    self.pendingAuth.removeValue(forKey: responseType)
                    pending.continuation.resume(throwing: CompanionError.timeout("jumelage"))
                }
            }
        }
    }

    /// Sends a request and waits for its response (matched on the transaction id `_x`).
    @discardableResult
    func request(_ identifier: String, _ content: OPACK = .dict([]), timeout: TimeInterval = 5) async throws -> OPACK {
        let response: OPACK = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let xid = self.takeXID()
                self.pendingResponses[xid] = continuation
                self.sendMessage(identifier: identifier, type: .request, content: content, xid: xid)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pendingResponses.removeValue(forKey: xid)?.resume(throwing: CompanionError.timeout(identifier))
                }
            }
        }
        if let message = response["_em"]?.stringValue {
            throw CompanionError.commandFailed(message)
        }
        return response
    }

    /// Sends a request whose response is ignored.
    func post(_ identifier: String, _ content: OPACK) {
        queue.async {
            self.sendMessage(identifier: identifier, type: .request, content: content, xid: self.takeXID())
        }
    }

    func sendEvent(_ identifier: String, _ content: OPACK) {
        queue.async {
            self.sendMessage(identifier: identifier, type: .event, content: content, xid: self.takeXID())
        }
    }

    private func sendMessage(identifier: String, type: MessageType, content: OPACK, xid: Int64) {
        let message: OPACK = .dict([
            (.string("_i"), .string(identifier)),
            (.string("_t"), .int(type.rawValue)),
            (.string("_c"), content),
            (.string("_x"), .int(xid)),
        ])
        trace(">> \(message)")
        connection.send(.encryptedOPACK, payload: message.encoded())
    }

    private func takeXID() -> Int64 {
        defer { nextXID += 1 }
        return nextXID
    }

    private func handleFrame(_ type: CompanionFrameType, _ payload: Data) {
        let message: OPACK
        do {
            message = try OPACK.decode(payload)
        } catch {
            logger.error("Undecodable frame of type \(type.rawValue): \(error)")
            return
        }

        trace("<< \(message)")
        switch type {
        case .pairSetupStart, .pairSetupNext, .pairVerifyStart, .pairVerifyNext:
            pendingAuth.removeValue(forKey: type)?.continuation.resume(returning: message)
        case .unencryptedOPACK, .encryptedOPACK, .packedOPACK:
            switch message["_t"]?.intValue.flatMap(MessageType.init(rawValue:)) {
            case .event:
                if let identifier = message["_i"]?.stringValue {
                    eventHandler?(identifier, message["_c"] ?? .dict([]))
                }
            case .response:
                if let xid = message["_x"]?.intValue {
                    pendingResponses.removeValue(forKey: xid)?.resume(returning: message)
                }
            case .request, nil:
                logger.debug("Unhandled message: \(message.description)")
            }
        default:
            logger.debug("Ignoring frame type \(type.rawValue)")
        }
    }

    private func handleClose(_ error: Error?) {
        let failure = CompanionError.connectionFailed(error?.localizedDescription ?? "connexion fermée")
        pendingAuth.values.forEach { $0.continuation.resume(throwing: failure) }
        pendingAuth.removeAll()
        pendingResponses.values.forEach { $0.resume(throwing: failure) }
        pendingResponses.removeAll()
        closeHandler?(error)
        closeHandler = nil
    }
}
