import AppKit
import AppleTVKit
import Observation

/// App-wide state: discovered Apple TVs, the active connection and everything the UI shows.
@MainActor
@Observable
final class RemoteModel {
    enum ConnectionState: Equatable {
        case searching
        case needsPairing
        case connecting
        case connected
        case failed(String)
    }

    static let shared = RemoteModel()

    private(set) var devices: [AppleTVDevice] = []
    private(set) var selectedDeviceID: String?
    private(set) var state: ConnectionState = .searching
    private(set) var powerState: PowerState = .unknown
    private(set) var mediaControls: MediaControlFlags = []
    private(set) var volume: Double?
    private(set) var textSession: TextInputSession?
    private(set) var apps: [LaunchableApp] = []
    private(set) var isLoadingApps = false
    /// Short-lived message shown at the bottom of the remote.
    private(set) var toast: String?
    var pairing: PairingFlow?
    let nowPlaying = NowPlayingModel()

    private var store: PairingStore
    private var client: CompanionClient?
    private let browser = AppleTVBrowser()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: Duration = .seconds(1)
    private var toastTask: Task<Void, Never>?

    static let storeURL = URL.applicationSupportDirectory
        .appendingPathComponent("Remote", isDirectory: true)
        .appendingPathComponent("store.json")

    private init() {
        store = PairingStore.load(from: Self.storeURL, defaultName: Host.current().localizedName ?? "Mac")
        selectedDeviceID = store.lastDeviceID
        try? store.save(to: Self.storeURL)

        browser.devicesHandler = { [weak self] devices in
            self?.devicesChanged(devices)
        }
        browser.errorHandler = { [weak self] message in
            self?.showToast("Recherche impossible : \(message)")
        }
        browser.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect(after: .seconds(2)) }
        }
    }

    var selectedDevice: AppleTVDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isConnected: Bool { state == .connected }

    var identityName: String { store.identity.name }

    func isPaired(_ device: AppleTVDevice) -> Bool {
        store.companionCredentials(for: device.id) != nil
    }

    // MARK: Device selection and connection

    private func devicesChanged(_ devices: [AppleTVDevice]) {
        self.devices = devices
        if selectedDevice == nil {
            // Prefer a paired device, otherwise the first one found.
            if let device = devices.first(where: isPaired) ?? devices.first {
                select(device)
            } else {
                state = .searching
            }
        } else if client == nil, state != .connecting {
            connect()
        }
    }

    func select(_ device: AppleTVDevice) {
        guard device.id != selectedDeviceID || client == nil else { return }
        disconnect()
        selectedDeviceID = device.id
        store.lastDeviceID = device.id
        persist()
        connect()
    }

    func connect() {
        guard let device = selectedDevice else {
            state = .searching
            return
        }
        guard let credentials = store.companionCredentials(for: device.id) else {
            state = .needsPairing
            return
        }
        guard client == nil else { return }

        state = .connecting
        let client = CompanionClient(endpoint: device.endpoint, credentials: credentials, identity: store.identity)
        client.eventHandler = { [weak self, weak client] event in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.handle(event)
            }
        }
        self.client = client

        Task {
            do {
                try await client.connect()
                guard self.client === client else { return }
                state = .connected
                reconnectDelay = .seconds(1)
                nowPlaying.start(device: device, store: store)
            } catch {
                guard self.client === client else { return }
                self.client = nil
                client.disconnect()
                if Self.isRejectedPairing(error) {
                    // The Apple TV no longer knows us (pairing removed in tvOS settings).
                    forgetPairing(of: device)
                    showToast("L'Apple TV a refusé le jumelage enregistré. Jumelez-la à nouveau.")
                } else {
                    state = .failed(error.localizedDescription)
                    reconnect(after: reconnectDelay)
                    reconnectDelay = min(reconnectDelay * 2, .seconds(30))
                }
            }
        }
    }

    private static func isRejectedPairing(_ error: Error) -> Bool {
        switch error {
        case PairingError.unexpectedDevice, PairingError.badSignature: return true
        case PairingError.deviceError(let code): return code == 0x02
        default: return false
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        client?.disconnect()
        client = nil
        nowPlaying.stop()
        textSession = nil
        mediaControls = []
        volume = nil
        powerState = .unknown
        apps = []
    }

    private func reconnect(after delay: Duration) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if client == nil { connect() }
        }
    }

    private func handle(_ event: CompanionEvent) {
        switch event {
        case .powerState(let power):
            powerState = power
        case .mediaControls(let flags):
            mediaControls = flags
            if !flags.contains(.volume) { volume = nil }
        case .volume(let level):
            volume = level
        case .textInputStarted(let session):
            let isNewField = textSession?.sessionUUID != session.sessionUUID
            textSession = session
            if isNewField { NotificationCenter.default.post(name: .textInputDidStart, object: nil) }
        case .textInputStopped:
            textSession = nil
        case .disconnected:
            client = nil
            textSession = nil
            nowPlaying.stop()
            state = .connecting
            reconnect(after: .seconds(1))
        }
    }

    // MARK: Pairing

    func startPairing() {
        guard let device = selectedDevice else { return }
        disconnect()
        pairing = PairingFlow(device: device, displayName: store.identity.name) { [weak self] credentials in
            self?.pairingSucceeded(credentials, device: device)
        }
    }

    private func pairingSucceeded(_ credentials: HAPCredentials, device: AppleTVDevice) {
        store.credentials[device.id] = credentials.stringValue
        persist()
        pairing = nil
        connect()
    }

    func forgetPairing(of device: AppleTVDevice) {
        if device.id == selectedDeviceID { disconnect() }
        store.credentials[device.id] = nil
        store.airPlayCredentials[device.id] = nil
        persist()
        if device.id == selectedDeviceID { state = .needsPairing }
    }

    func storeAirPlayCredentials(_ credentials: HAPCredentials?, for deviceID: String) {
        store.airPlayCredentials[deviceID] = credentials?.stringValue
        persist()
    }

    private func persist() {
        do {
            try store.save(to: Self.storeURL)
        } catch {
            showToast("Impossible d'enregistrer le jumelage : \(error.localizedDescription)")
        }
    }

    // MARK: Commands

    /// Presses (`pressed == true`) or releases a button; used for press-and-hold.
    func button(_ command: HIDCommand, pressed: Bool) {
        guard let client else { return notConnected() }
        client.send(command, pressed: pressed)
    }

    func tap(_ command: HIDCommand) {
        guard let client else { return notConnected() }
        client.send(command, pressed: true)
        client.send(command, pressed: false)
    }

    func touch(x: Double, y: Double, phase: TouchPhase) {
        client?.touch(x: x, y: y, phase: phase)
    }

    func skip(_ seconds: Double) {
        guard let client else { return notConnected() }
        client.send(.skipBy, [("_skpS", .float(seconds))])
    }

    func mediaCommand(_ command: MediaCommand) {
        guard let client else { return notConnected() }
        client.send(command)
    }

    func setVolume(_ level: Double) {
        volume = level
        client?.send(.setVolume, [("_vol", .float(level))])
    }

    func togglePower() {
        guard let client else { return notConnected() }
        if powerState == .off {
            client.send(.wake, pressed: false)
        } else {
            client.send(.sleep, pressed: false)
        }
    }

    func launch(_ app: LaunchableApp) {
        guard let client else { return notConnected() }
        Task {
            do {
                try await client.launch(bundleID: app.bundleID)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func openSearch() {
        launch(LaunchableApp(bundleID: "com.apple.TVSearch", name: "Rechercher"))
    }

    func loadApps() {
        guard let client, !isLoadingApps else { return }
        isLoadingApps = true
        Task {
            defer { isLoadingApps = false }
            do {
                apps = try await client.launchableApps()
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: Text input

    /// Asks the Apple TV which text field is focused, if any.
    func refreshTextInput() {
        guard let client else { return notConnected() }
        Task {
            let session = try? await client.restartTextInput()
            if session == nil { showToast("Aucun champ de texte n'est actif sur l'Apple TV.") }
        }
    }

    /// Mirrors the Mac text field into the focused Apple TV field.
    func updateText(_ text: String) {
        guard let client, textSession != nil, textSession?.text != text else { return }
        textSession?.text = text
        Task {
            try? await client.setText(text)
        }
    }

    /// Inserts the Mac clipboard into the focused Apple TV field.
    func pasteClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else {
            showToast("Le presse-papiers ne contient pas de texte.")
            NSSound.beep()
            return
        }
        guard let client else { return notConnected() }
        Task {
            do {
                try await client.appendText(string, refresh: textSession == nil)
                if textSession != nil { textSession?.text += string }
                showToast("Texte collé sur l'Apple TV")
            } catch {
                NSSound.beep()
                showToast(error.localizedDescription)
            }
        }
    }

    func clearText() {
        guard let client else { return notConnected() }
        textSession?.text = ""
        Task { try? await client.setText("") }
    }

    // MARK: Feedback

    private func notConnected() {
        NSSound.beep()
        showToast("Apple TV non connectée")
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }
}

extension Notification.Name {
    static let textInputDidStart = Notification.Name("RemoteTextInputDidStart")
}

/// State of the PIN pairing sheet.
@MainActor
@Observable
final class PairingFlow: Identifiable {
    enum Step: Equatable {
        case starting
        case waitingForPIN
        case verifying
        case failed(String)
    }

    let id = UUID()
    let device: AppleTVDevice
    private(set) var step: Step = .starting
    var pin = ""

    private let displayName: String
    private let onSuccess: (HAPCredentials) -> Void
    private var pairing: CompanionPairing?

    init(device: AppleTVDevice, displayName: String, onSuccess: @escaping (HAPCredentials) -> Void) {
        self.device = device
        self.displayName = displayName
        self.onSuccess = onSuccess
        begin()
    }

    func begin() {
        pairing?.cancel()
        pin = ""
        step = .starting
        let pairing = CompanionPairing(endpoint: device.endpoint)
        self.pairing = pairing
        Task {
            do {
                try await pairing.begin()
                guard self.pairing === pairing else { return }
                step = .waitingForPIN
            } catch {
                guard self.pairing === pairing else { return }
                step = .failed(error.localizedDescription)
            }
        }
    }

    func submit() {
        guard let pairing, step == .waitingForPIN, pin.count == 4 else { return }
        step = .verifying
        Task {
            do {
                let credentials = try await pairing.finish(pin: pin, displayName: displayName)
                onSuccess(credentials)
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        pairing?.cancel()
        pairing = nil
    }
}
