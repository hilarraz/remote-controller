import Foundation
import Network

public enum AirPlayError: LocalizedError {
    case httpStatus(Int)
    case notAuthorized
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "L'Apple TV a refusé la requête AirPlay (code \(code))."
        case .notAuthorized: return "Jumelage AirPlay requis."
        case .protocolError(let reason): return "Réponse AirPlay inattendue : \(reason)"
        }
    }
}

private let hapHeaders: [(String, String)] = [
    ("User-Agent", "AirPlay/320.20"),
    ("Connection", "keep-alive"),
    ("X-Apple-HKP", "3"),
    ("Content-Type", "application/octet-stream"),
]

private func postPairing(_ http: HTTPClient, _ path: String, _ body: Data) async throws -> Data {
    let response = try await http.send(HTTPMessage(startLine: "POST \(path) HTTP/1.1", headers: hapHeaders, body: body))
    guard let code = response.statusCode else { throw AirPlayError.protocolError(response.startLine) }
    if code == 470 || code == 401 || code == 403 { throw AirPlayError.notAuthorized }
    guard (200..<300).contains(code) else { throw AirPlayError.httpStatus(code) }
    return response.body
}

/// Pair-setup over AirPlay: `begin()` makes the Apple TV display a PIN.
public final class AirPlayPairing: @unchecked Sendable {
    private let connection: HAPConnection
    private let http: HTTPClient
    private let setup = HAPPairSetup()
    private var m2: Data?

    public init(endpoint: NWEndpoint) {
        connection = HAPConnection(endpoint: endpoint, queue: DispatchQueue(label: "AppleTVKit.airplay-pairing"))
        http = HTTPClient(connection: connection)
    }

    public func begin() async throws {
        try await connection.start()
        _ = try await postPairing(http, "/pair-pin-start", Data())
        m2 = try await postPairing(http, "/pair-setup", setup.startRequest())
    }

    public func finish(pin: String, displayName: String) async throws -> HAPCredentials {
        guard let m2 else { throw CompanionError.notConnected }
        defer { connection.close() }
        let m4 = try await postPairing(http, "/pair-setup", try setup.proofRequest(m2: m2, pin: pin))
        let m6 = try await postPairing(http, "/pair-setup", try setup.exchangeRequest(m4: m4, name: displayName))
        return try setup.finish(m6: m6)
    }

    public func cancel() {
        connection.close()
    }
}

/// An AirPlay 2 "remote control only" session carrying MediaRemote (MRP) messages,
/// which is how tvOS publishes what is playing.
public final class NowPlayingSession: @unchecked Sendable {
    private let endpoint: NWEndpoint
    private let credentials: HAPCredentials
    private let identity: ClientIdentity
    private let queue = DispatchQueue(label: "AppleTVKit.airplay")

    private var control: HAPConnection?
    private var http: HTTPClient?
    private var eventChannel: HAPConnection?
    private var dataChannel: HAPConnection?
    private var feedbackTask: Task<Void, Never>?
    private var isClosed = false

    private var cseq = 0
    private let sessionID = UInt32.random(in: 0...UInt32.max)
    private let dacpID = String(format: "%016llX", UInt64.random(in: 0...UInt64.max))
    private let activeRemote = UInt32.random(in: 0...UInt32.max)
    private let sendSeqno = UInt64.random(in: 0x1_0000_0000...0x1_FFFF_FFFF)
    private var dataBuffer = Data()
    private var eventBuffer = Data()
    private let tracker = NowPlayingTracker()
    private var deviceInfoContinuation: CheckedContinuation<Void, Never>?
    private var receivedDeviceInfo = false

    /// Called on a background queue whenever what is playing changes.
    public var updateHandler: ((NowPlayingInfo?) -> Void)?
    /// Called once on a background queue when the session ends.
    public var closeHandler: ((Error?) -> Void)?

    public init(endpoint: NWEndpoint, credentials: HAPCredentials, identity: ClientIdentity) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.identity = identity
        tracker.requestItem = { [weak self] location in self?.requestQueueItem(location: location) }
    }

    public func start() async throws {
        let control = HAPConnection(endpoint: endpoint, queue: queue)
        let http = HTTPClient(connection: control)
        self.control = control
        self.http = http
        try await control.start()

        let verifier = HAPPairVerify(credentials: credentials)
        let m2 = try await postPairing(http, "/pair-verify", verifier.startRequest())
        let m4 = try await postPairing(http, "/pair-verify", try verifier.finishRequest(m2: m2))
        try verifier.finish(m4: m4)
        queue.sync {
            control.enableEncryption(
                outputKey: verifier.deriveKey(salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
                inputKey: verifier.deriveKey(salt: "Control-Salt", info: "Control-Read-Encryption-Key")
            )
        }
        guard let remoteHost = control.remoteHost else { throw AirPlayError.protocolError("adresse inconnue") }

        // Event channel: required even though we only acknowledge what arrives on it.
        let eventSetup = try await rtsp("SETUP", body: .dict([
            ("isRemoteControlOnly", .bool(true)),
            ("osName", .string("iPhone OS")),
            ("sourceVersion", .string("550.10")),
            ("timingProtocol", .string("None")),
            ("model", .string(identity.model)),
            ("deviceID", .string(identity.deviceID)),
            ("osVersion", .string("14.7.1")),
            ("osBuildVersion", .string("18G82")),
            ("macAddress", .string(identity.deviceID)),
            ("sessionUUID", .string(UUID().uuidString)),
            ("name", .string(identity.name)),
        ]))
        guard let eventPort = try BinaryPlist.decode(eventSetup.body)["eventPort"]?.intValue,
              let eventNWPort = NWEndpoint.Port(rawValue: UInt16(eventPort)) else {
            throw AirPlayError.protocolError("eventPort")
        }
        let eventChannel = HAPConnection(endpoint: .hostPort(host: remoteHost, port: eventNWPort), queue: queue)
        self.eventChannel = eventChannel
        try await eventChannel.start()
        queue.sync {
            // The receiver opens this channel's sessions, hence the swapped key names.
            eventChannel.enableEncryption(
                outputKey: verifier.deriveKey(salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
                inputKey: verifier.deriveKey(salt: "Events-Salt", info: "Events-Write-Encryption-Key")
            )
            eventChannel.dataHandler = { [weak self] data in self?.handleEventData(data) }
            eventChannel.closeHandler = { [weak self] error in self?.finish(error) }
        }

        _ = try await rtsp("RECORD")

        // Data channel carrying the MRP protobuf messages.
        let seed = UInt64.random(in: 0..<UInt64(Int64.max))
        let dataSetup = try await rtsp("SETUP", body: .dict([
            ("streams", .array([.dict([
                ("controlType", .int(2)),
                ("channelID", .string(UUID().uuidString)),
                ("seed", .int(Int64(seed))),
                ("clientUUID", .string(UUID().uuidString)),
                ("type", .int(130)),
                ("wantsDedicatedSocket", .bool(true)),
                ("clientTypeUUID", .string("1910A70F-DBC0-4242-AF95-115DB30604E1")),
            ])])),
        ]))
        guard let dataPort = try BinaryPlist.decode(dataSetup.body)["streams"]?[0]?["dataPort"]?.intValue,
              let dataNWPort = NWEndpoint.Port(rawValue: UInt16(dataPort)) else {
            throw AirPlayError.protocolError("dataPort")
        }
        let dataChannel = HAPConnection(endpoint: .hostPort(host: remoteHost, port: dataNWPort), queue: queue)
        self.dataChannel = dataChannel
        try await dataChannel.start()
        queue.sync {
            dataChannel.enableEncryption(
                outputKey: verifier.deriveKey(salt: "DataStream-Salt\(seed)", info: "DataStream-Output-Encryption-Key"),
                inputKey: verifier.deriveKey(salt: "DataStream-Salt\(seed)", info: "DataStream-Input-Encryption-Key")
            )
            dataChannel.dataHandler = { [weak self] data in self?.handleStreamData(data) }
            dataChannel.closeHandler = { [weak self] error in self?.finish(error) }
            control.closeHandler = { [weak self] error in self?.finish(error) }
        }

        startFeedback()

        // MRP handshake: device information first, then ask for updates.
        send(MRPMessages.deviceInfo(identity: identity, clientID: String(decoding: credentials.clientID, as: UTF8.self)))
        await waitForDeviceInfo(timeout: 5)
        send(MRPMessages.setConnectionState())
        send(MRPMessages.clientUpdatesConfig())
        send(MRPMessages.getKeyboardSession())
    }

    public func stop() {
        feedbackTask?.cancel()
        feedbackTask = nil
        queue.async {
            self.isClosed = true
            self.closeHandler = nil
            self.dataChannel?.close()
            self.eventChannel?.close()
            self.control?.close()
        }
    }

    /// Jumps to a position (in seconds) in what is playing.
    public func seek(to position: Double) {
        send(MRPMessages.seek(to: position))
    }

    /// Turns on an audio track or subtitle (`enable`), or turns a subtitle off.
    public func setLanguageOption(_ option: LanguageOption, enabled: Bool) {
        send(MRPMessages.languageCommand(option, enable: enabled))
        // Apps do not always announce the new selection: read it back.
        queue.asyncAfter(deadline: .now() + 0.8) {
            if let location = self.tracker.currentLocation { self.requestQueueItem(location: location) }
        }
    }

    private func finish(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        feedbackTask?.cancel()
        dataChannel?.close()
        eventChannel?.close()
        control?.close()
        closeHandler?(error)
        closeHandler = nil
    }

    // MARK: RTSP

    private func rtsp(_ method: String, uri: String? = nil, body: PlistValue? = nil) async throws -> HTTPMessage {
        guard let http, let control else { throw CompanionError.notConnected }
        let local = control.localHost ?? "0.0.0.0"
        let sequence: Int = queue.sync {
            defer { cseq += 1 }
            return cseq
        }
        var headers: [(String, String)] = [("User-Agent", "AirPlay/550.10")]
        var payload = Data()
        if let body {
            payload = BinaryPlist.encode(body)
            headers.append(("Content-Type", "application/x-apple-binary-plist"))
        }
        headers += [
            ("CSeq", String(sequence)),
            ("DACP-ID", dacpID),
            ("Active-Remote", String(activeRemote)),
            ("Client-Instance", dacpID),
        ]
        let target = uri ?? "rtsp://\(local)/\(sessionID)"
        let response = try await http.send(HTTPMessage(startLine: "\(method) \(target) RTSP/1.0", headers: headers, body: payload))
        guard let code = response.statusCode, (200..<300).contains(code) else {
            throw AirPlayError.httpStatus(response.statusCode ?? 0)
        }
        return response
    }

    /// iOS sends feedback every two seconds to keep the session alive.
    private func startFeedback() {
        feedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                do {
                    _ = try await self.rtsp("POST", uri: "/feedback")
                } catch {
                    self.queue.async { self.finish(error) }
                    return
                }
            }
        }
    }

    // MARK: Event channel

    private func handleEventData(_ data: Data) {
        eventBuffer.append(data)
        while let request = HTTPMessage.parse(from: &eventBuffer) {
            var headers: [(String, String)] = [("Content-Length", "0"), ("Audio-Latency", "0")]
            if let server = request.header("Server") { headers.append(("Server", server)) }
            if let cseq = request.header("CSeq") { headers.append(("CSeq", cseq)) }
            let response = HTTPMessage(startLine: "\(request.protocolVersion) 200 OK", headers: headers)
            eventChannel?.send(response.serialized())
        }
    }

    // MARK: Data stream

    private static func frameHeader(size: Int, type: String, command: Data, seqno: UInt64) -> Data {
        var header = Data()
        header.append(bigEndian: UInt32(size))
        header.append(Data(type.utf8) + Data(repeating: 0, count: 12 - type.utf8.count))
        header.append(command)
        header.append(bigEndian: seqno)
        header.append(bigEndian: UInt32(0))
        return header
    }

    private func send(_ protobuf: Data) {
        var framed = ProtoWriter.varint(UInt64(protobuf.count))
        framed.append(protobuf)
        let payload = BinaryPlist.encode(.dict([("params", .dict([("data", .data(framed))]))]))
        let header = Self.frameHeader(size: 32 + payload.count, type: "sync", command: Data("comm".utf8), seqno: sendSeqno)
        queue.async { self.dataChannel?.send(header + payload) }
    }

    private func handleStreamData(_ data: Data) {
        dataBuffer.append(data)
        while dataBuffer.count >= 32 {
            let size = Int(dataBuffer.readBigEndian(at: 0, count: 4))
            guard size >= 32 else {
                dataBuffer.removeAll()
                return
            }
            guard dataBuffer.count >= size else { break }
            let frame = Data(dataBuffer.prefix(size))
            dataBuffer = Data(dataBuffer.dropFirst(size))

            let messageType = frame.subdata(in: 4..<16)
            let seqno = frame.readBigEndian(at: 20, count: 8)
            let payload = frame.subdata(in: 32..<size)

            if !payload.isEmpty, let plist = try? BinaryPlist.decode(payload),
               let protobufs = plist["params"]?["data"]?.dataValue {
                for message in Self.splitProtobufs(protobufs) {
                    handle(message)
                }
            }
            if messageType.starts(with: Data("sync".utf8)) {
                let reply = Self.frameHeader(size: 32, type: "rply", command: Data(count: 4), seqno: seqno)
                dataChannel?.send(reply)
            }
        }
    }

    /// Messages are prefixed with their varint length, except a lone message, which
    /// starts directly with the type field (tag 0x08).
    static func splitProtobufs(_ data: Data) -> [ProtoMessage] {
        var messages: [ProtoMessage] = []
        var bytes = [UInt8](data)[...]
        while let first = bytes.first {
            if first == 0x08 {
                if let message = ProtoMessage(Data(bytes)) { messages.append(message) }
                break
            }
            var length = 0
            var shift = 0
            while let byte = bytes.first {
                bytes = bytes.dropFirst()
                length |= Int(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            guard bytes.count >= length else { break }
            if let message = ProtoMessage(Data(bytes.prefix(length))) { messages.append(message) }
            bytes = bytes.dropFirst(length)
        }
        return messages
    }

    private func handle(_ message: ProtoMessage) {
        let type = Int(message.uint(1) ?? 0)
        trace("<< MRP type \(type)")
        if type == MRPMessages.Kind.deviceInfo {
            receivedDeviceInfo = true
            deviceInfoContinuation?.resume()
            deviceInfoContinuation = nil
            return
        }
        if tracker.handle(message, type: type) {
            updateHandler?(tracker.current)
        }
    }

    private func waitForDeviceInfo(timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard !self.receivedDeviceInfo else { return continuation.resume() }
                self.deviceInfoContinuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.deviceInfoContinuation?.resume()
                    self.deviceInfoContinuation = nil
                }
            }
        }
    }

    private func requestQueueItem(location: Int) {
        send(MRPMessages.playbackQueueRequest(location: location))
    }
}
