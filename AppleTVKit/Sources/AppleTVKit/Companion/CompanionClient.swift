import Foundation
import Network

private func pairingData(_ message: OPACK) throws -> Data {
    guard let data = message["_pd"]?.dataValue else {
        throw CompanionError.protocolError("données de jumelage absentes")
    }
    if let error = TLV8.decode(data)[.error], let code = error.first {
        throw PairingError.deviceError(code: code)
    }
    return data
}

/// Pair-setup over Companion: `begin()` makes the Apple TV display a PIN, `finish(pin:)`
/// completes the exchange and returns long-term credentials.
public final class CompanionPairing: @unchecked Sendable {
    private let channel: CompanionChannel
    private let setup = HAPPairSetup()
    private var m2: Data?

    public init(endpoint: NWEndpoint) {
        channel = CompanionChannel(endpoint: endpoint)
    }

    public func begin() async throws {
        try await channel.start()
        let response = try await channel.exchangeAuth(
            .pairSetupStart, [("_pd", .data(setup.startRequest())), ("_pwTy", .int(1))])
        m2 = try pairingData(response)
    }

    public func finish(pin: String, displayName: String) async throws -> HAPCredentials {
        guard let m2 else { throw CompanionError.notConnected }
        defer { channel.close() }
        let m3 = try setup.proofRequest(m2: m2, pin: pin)
        let m4 = try await channel.exchangeAuth(.pairSetupNext, [("_pd", .data(m3)), ("_pwTy", .int(1))])
        guard let m4Data = m4["_pd"]?.dataValue else { throw CompanionError.protocolError("M4") }
        let m5 = try setup.exchangeRequest(m4: m4Data, name: displayName)
        let m6 = try await channel.exchangeAuth(.pairSetupNext, [("_pd", .data(m5)), ("_pwTy", .int(1))])
        return try setup.finish(m6: try pairingData(m6))
    }

    public func cancel() {
        channel.close()
    }
}

/// An authenticated, encrypted Companion session with an Apple TV.
public final class CompanionClient: @unchecked Sendable {
    public static let touchpadSize = 1000.0

    private let channel: CompanionChannel
    private let credentials: HAPCredentials
    private let identity: ClientIdentity
    private let lock = NSLock()
    private var touchBase = DispatchTime.now().uptimeNanoseconds
    private var sessionID: UInt64 = 0
    private var textSession: TextInputSession?

    /// Receives state changes; called on a background queue.
    public var eventHandler: ((CompanionEvent) -> Void)?

    public init(endpoint: NWEndpoint, credentials: HAPCredentials, identity: ClientIdentity) {
        self.credentials = credentials
        self.identity = identity
        channel = CompanionChannel(endpoint: endpoint)
        channel.eventHandler = { [weak self] identifier, content in self?.handleEvent(identifier, content) }
        channel.closeHandler = { [weak self] error in
            self?.eventHandler?(.disconnected(error?.localizedDescription))
        }
    }

    public var currentTextSession: TextInputSession? {
        lock.withLock { textSession }
    }

    // MARK: Connection

    public func connect() async throws {
        try await channel.start()
        try await verify()
        try await sendSystemInfo()

        touchBase = DispatchTime.now().uptimeNanoseconds
        try await channel.request("_touchStart", [
            "_height": .float(Self.touchpadSize), "_tFl": 0, "_width": .float(Self.touchpadSize),
        ])

        let localSID = UInt64(UInt32.random(in: 0...UInt32.max))
        let session = try await channel.request("_sessionStart", [
            "_srvT": "com.apple.tvremoteservices", "_sid": .int(Int64(localSID)),
        ])
        if let remoteSID = session["_c"]?["_sid"]?.intValue {
            sessionID = UInt64(truncatingIfNeeded: remoteSID) << 32 | localSID
        }

        // Newer tvOS versions only answer some requests once a TV remote session exists.
        _ = try? await channel.request("TVRCSessionStart", ["ProtocolVersionKey": "1.2"])

        for event in ["_iMC", "SystemStatus", "TVSystemStatus"] {
            channel.sendEvent("_interest", ["_regEvents": [.string(event)]])
        }

        _ = try? await restartTextInput()

        if let attention = try? await channel.request("FetchAttentionState"),
           let state = attention["_c"]?["state"]?.intValue {
            eventHandler?(.powerState(PowerState(systemStatus: state)))
        }
    }

    public func disconnect() {
        channel.sendEvent("_interest", ["_deregEvents": ["_iMC", "SystemStatus", "TVSystemStatus"]])
        channel.close()
    }

    private func verify() async throws {
        let verifier = HAPPairVerify(credentials: credentials)
        let m2 = try await channel.exchangeAuth(
            .pairVerifyStart, [("_pd", .data(verifier.startRequest())), ("_auTy", .int(4))])
        let m3 = try verifier.finishRequest(m2: try pairingData(m2))
        let m4 = try await channel.exchangeAuth(.pairVerifyNext, [("_pd", .data(m3))])
        try verifier.finish(m4: try pairingData(m4))
        channel.enableEncryption(
            outputKey: verifier.deriveKey(salt: "", info: "ClientEncrypt-main"),
            inputKey: verifier.deriveKey(salt: "", info: "ServerEncrypt-main")
        )
    }

    private func sendSystemInfo() async throws {
        try await channel.request("_systemInfo", [
            "_bf": 0,
            "_cf": 512,
            "_clFl": 128,
            "_i": .string(identity.rpID),
            "_idsID": .data(credentials.clientID),
            "_pubID": .string(identity.deviceID),
            "_sf": 256,
            "_sv": "170.18",
            "model": .string(identity.model),
            "name": .string(identity.name),
        ])
    }

    // MARK: Buttons

    /// Sends a button press or release.
    public func hid(_ command: HIDCommand, pressed: Bool) async throws {
        try await channel.request("_hidC", ["_hBtS": pressed ? 1 : 2, "_hidC": .int(command.rawValue)])
    }

    /// Presses and releases a button.
    public func press(_ command: HIDCommand) async throws {
        try await hid(command, pressed: true)
        try await hid(command, pressed: false)
    }

    /// Sends a button press or release without waiting for the answer. Calls made from
    /// the same thread reach the device in order, which keeps press/release pairs intact.
    public func send(_ command: HIDCommand, pressed: Bool) {
        channel.post("_hidC", ["_hBtS": pressed ? 1 : 2, "_hidC": .int(command.rawValue)])
    }

    /// Sends a media control command without waiting for the answer.
    public func send(_ command: MediaCommand, _ arguments: [(String, OPACK)] = []) {
        var content: [(OPACK, OPACK)] = [(.string("_mcc"), .int(command.rawValue))]
        content += arguments.map { (.string($0.0), $0.1) }
        channel.post("_mcc", .dict(content))
    }

    public func turnOn() async throws {
        try await hid(.wake, pressed: false)
    }

    public func turnOff() async throws {
        try await hid(.sleep, pressed: false)
    }

    // MARK: Media control

    @discardableResult
    public func mediaControl(_ command: MediaCommand, _ arguments: [(String, OPACK)] = []) async throws -> OPACK {
        var content: [(OPACK, OPACK)] = [(.string("_mcc"), .int(command.rawValue))]
        content += arguments.map { (.string($0.0), $0.1) }
        return try await channel.request("_mcc", .dict(content))
    }

    public func skip(seconds: Double) async throws {
        try await mediaControl(.skipBy, [("_skpS", .float(seconds))])
    }

    /// Volume in 0...1, only available when the audio output supports it (e.g. HomePod).
    public func volume() async throws -> Double? {
        try await mediaControl(.getVolume)["_c"]?["_vol"]?.doubleValue
    }

    public func setVolume(_ level: Double) async throws {
        try await mediaControl(.setVolume, [("_vol", .float(min(max(level, 0), 1)))])
    }

    // MARK: Touch surface

    /// Sends a touch event; coordinates are in 0...1000 with the origin at the top left.
    public func touch(x: Double, y: Double, phase: TouchPhase) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- touchBase
        let clampedX = Int64(min(max(x, 0), Self.touchpadSize))
        let clampedY = Int64(min(max(y, 0), Self.touchpadSize))
        channel.sendEvent("_hidT", [
            "_ns": .int(Int64(elapsed)), "_tFg": 1, "_cx": .int(clampedX), "_tPh": .int(phase.rawValue), "_cy": .int(clampedY),
        ])
    }

    // MARK: Apps

    public func launchableApps() async throws -> [LaunchableApp] {
        let response = try await channel.request("FetchLaunchableApplicationsEvent", timeout: 10)
        guard let pairs = response["_c"]?.dictPairs else { return [] }
        return pairs.compactMap { key, value in
            guard let bundleID = key.stringValue, let name = value.stringValue else { return nil }
            return LaunchableApp(bundleID: bundleID, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func launch(bundleID: String) async throws {
        try await channel.request("_launchApp", ["_bundleID": .string(bundleID)])
    }

    public func open(url: String) async throws {
        try await channel.request("_launchApp", ["_urlS": .string(url)])
    }

    // MARK: Text input

    /// Restarts the text input session to learn about the currently focused field.
    @discardableResult
    public func restartTextInput() async throws -> TextInputSession? {
        _ = try? await channel.request("_tiStop")
        let response = try await channel.request("_tiStart")
        let session = response["_c"]?["_tiD"]?.dataValue.flatMap(Self.parseTextSession)
        lock.withLock { textSession = session }
        eventHandler?(session.map { .textInputStarted($0) } ?? .textInputStopped)
        return session
    }

    /// Sends an arbitrary request and returns the raw response, for debugging.
    public func rawRequest(_ identifier: String, _ content: OPACK) async throws -> OPACK {
        try await channel.request(identifier, content)
    }

    /// Raw archive describing the focused field, for debugging.
    public func textInputArchive() async throws -> PlistValue? {
        _ = try? await channel.request("_tiStop")
        let response = try await channel.request("_tiStart")
        return try response["_c"]?["_tiD"]?.dataValue.map(BinaryPlist.decode)
    }

    private func activeTextSession(refresh: Bool) async throws -> TextInputSession {
        if !refresh, let session = currentTextSession { return session }
        guard let session = try await restartTextInput() else { throw CompanionError.noTextField }
        return session
    }

    /// Replaces the content of the focused text field.
    public func setText(_ text: String, refresh: Bool = false) async throws {
        let session = try await activeTextSession(refresh: refresh)
        channel.sendEvent("_tiC", ["_tiV": 1, "_tiD": .data(KeyedArchive.rtiClearTextPayload(sessionUUID: session.sessionUUID))])
        if !text.isEmpty {
            channel.sendEvent("_tiC", [
                "_tiV": 1, "_tiD": .data(KeyedArchive.rtiInputTextPayload(sessionUUID: session.sessionUUID, text: text)),
            ])
        }
        lock.withLock { textSession?.text = text }
    }

    /// Inserts text at the cursor of the focused text field.
    public func appendText(_ text: String, refresh: Bool = false) async throws {
        let session = try await activeTextSession(refresh: refresh)
        channel.sendEvent("_tiC", [
            "_tiV": 1, "_tiD": .data(KeyedArchive.rtiInputTextPayload(sessionUUID: session.sessionUUID, text: text)),
        ])
        lock.withLock { textSession?.text += text }
    }

    static func parseTextSession(_ archive: Data) -> TextInputSession? {
        guard let uuid = KeyedArchive.property(in: archive, path: ["sessionUUID"])?.dataValue else { return nil }
        let text = KeyedArchive.property(in: archive, path: ["documentState", "docSt", "contextBeforeInput"])?.stringValue ?? ""
        let title = KeyedArchive.property(in: archive, path: ["documentTraits", "title"])?.stringValue
        let placeholder = KeyedArchive.property(in: archive, path: ["documentTraits", "prompt"])?.stringValue
        return TextInputSession(sessionUUID: uuid, text: text, title: title, placeholder: placeholder)
    }

    // MARK: Events

    private func handleEvent(_ identifier: String, _ content: OPACK) {
        logger.debug("Event \(identifier): \(content.description)")
        switch identifier {
        case "_iMC":
            if let flags = content["_mcF"]?.intValue {
                let controls = MediaControlFlags(rawValue: flags)
                eventHandler?(.mediaControls(controls))
                if controls.contains(.volume) {
                    Task { [weak self] in
                        if let level = try? await self?.volume() { self?.eventHandler?(.volume(level)) }
                    }
                }
            }
        case "SystemStatus", "TVSystemStatus":
            if let state = content["state"]?.intValue {
                eventHandler?(.powerState(PowerState(systemStatus: state)))
            }
        case "_tiStarted":
            let session = content["_tiD"]?.dataValue.flatMap(Self.parseTextSession)
            lock.withLock { textSession = session }
            eventHandler?(session.map { .textInputStarted($0) } ?? .textInputStopped)
        case "_tiStopped":
            lock.withLock { textSession = nil }
            eventHandler?(.textInputStopped)
        default:
            break
        }
    }
}
