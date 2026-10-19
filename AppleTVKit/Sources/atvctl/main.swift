import AppleTVKit
import Foundation

// Small command line tool used to exercise AppleTVKit against a real device.

let storeURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/atvctl/store.json")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
func discover(timeout: TimeInterval = 4) async -> [AppleTVDevice] {
    let browser = AppleTVBrowser()
    var found: [AppleTVDevice] = []
    browser.devicesHandler = { found = $0 }
    browser.errorHandler = { print("browse error: \($0)") }
    browser.start()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 200_000_000)
        if !found.isEmpty && Date() > deadline.addingTimeInterval(-timeout + 1.5) { break }
    }
    browser.stop()
    return found
}

@MainActor
func device(named name: String?) async -> AppleTVDevice {
    let devices = await discover()
    if let name {
        guard let match = devices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            fail("No Apple TV named \(name). Found: \(devices.map(\.name))")
        }
        return match
    }
    guard let first = devices.first else { fail("No Apple TV found") }
    return first
}

@MainActor
func connectedClient(_ store: PairingStore, deviceName: String?) async -> (CompanionClient, AppleTVDevice) {
    let device = await device(named: deviceName)
    guard let string = store.credentials[device.id], let credentials = HAPCredentials(string: string) else {
        fail("Not paired with \(device.name). Run: atvctl pair")
    }
    let client = CompanionClient(endpoint: device.endpoint, credentials: credentials, identity: store.identity)
    client.eventHandler = { event in print("event: \(event)") }
    do {
        try await client.connect()
    } catch {
        fail("Connection failed: \(error.localizedDescription) (\(error))")
    }
    return (client, device)
}

let buttons: [String: HIDCommand] = [
    "up": .up, "down": .down, "left": .left, "right": .right, "select": .select, "menu": .menu,
    "home": .home, "playpause": .playPause, "volup": .volumeUp, "voldown": .volumeDown,
    "screensaver": .screensaver, "controlcenter": .pageDown,
]

@MainActor
func run() async {
    var args = Array(CommandLine.arguments.dropFirst())
    let deviceName = args.firstIndex(of: "--device").map { index -> String in
        let name = args[index + 1]
        args.removeSubrange(index...index + 1)
        return name
    }
    guard let command = args.first else {
        fail("usage: atvctl [--device NAME] scan|pair|watch|apps|launch ID|text STRING|settext STRING|tistate|swipe DIR|nowplaying|seek SECONDS|on|off|<button>")
    }
    var store = PairingStore.load(from: storeURL, defaultName: Host.current().localizedName ?? "Mac")

    switch command {
    case "scan":
        for device in await discover() {
            print("\(device.name)\t\(device.modelDescription)\t\(device.id)\t\(device.endpoint)")
            print("   \(device.properties)")
        }

    case "pair":
        let device = await device(named: deviceName)
        let pairing = CompanionPairing(endpoint: device.endpoint)
        do {
            try await pairing.begin()
            print("PIN displayed on \(device.name). Enter PIN:")
            fflush(stdout)
            guard let pin = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty else { fail("no PIN") }
            let credentials = try await pairing.finish(pin: pin, displayName: store.identity.name)
            store.credentials[device.id] = credentials.stringValue
            try store.save(to: storeURL)
            print("Paired with \(device.name)")
        } catch {
            fail("Pairing failed: \(error.localizedDescription) (\(error))")
        }

    case "watch":
        let (client, device) = await connectedClient(store, deviceName: deviceName)
        print("Connected to \(device.name); watching events for 60s")
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        client.disconnect()

    case "apps":
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        do {
            for app in try await client.launchableApps() { print("\(app.bundleID)\t\(app.name)") }
        } catch { fail("\(error)") }
        client.disconnect()

    case "launch":
        guard args.count > 1 else { fail("usage: atvctl launch BUNDLE_ID") }
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        do { try await client.launch(bundleID: args[1]) } catch { fail("\(error)") }
        client.disconnect()

    case "text", "settext":
        guard args.count > 1 else { fail("usage: atvctl \(command) STRING") }
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        do {
            if command == "text" {
                try await client.appendText(args[1], refresh: true)
            } else {
                try await client.setText(args[1], refresh: true)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("Text sent")
        } catch { fail("\(error.localizedDescription)") }
        client.disconnect()

    case "tistate":
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        print("Text session: \(String(describing: client.currentTextSession))")
        if args.contains("--dump"), let archive = try? await client.textInputArchive() {
            print(archive)
        }
        client.disconnect()

    case "post":
        // Fire-and-forget presses, like the app does.
        guard args.count > 1, let button = buttons[args[1]] else { fail("usage: atvctl post BUTTON") }
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        for _ in 0..<3 {
            client.send(button, pressed: true)
            try? await Task.sleep(nanoseconds: 100_000_000)
            client.send(button, pressed: false)
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        client.disconnect()

    case "airpair":
        let device = await device(named: deviceName)
        let pairing = AirPlayPairing(endpoint: device.airPlayEndpoint)
        do {
            try await pairing.begin()
            print("PIN displayed on \(device.name). Enter PIN:")
            fflush(stdout)
            guard let pin = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty else { fail("no PIN") }
            let credentials = try await pairing.finish(pin: pin, displayName: store.identity.name)
            store.airPlayCredentials[device.id] = credentials.stringValue
            try store.save(to: storeURL)
            print("AirPlay paired with \(device.name)")
        } catch {
            fail("AirPlay pairing failed: \(error.localizedDescription) (\(error))")
        }

    case "nowplaying", "seek":
        // Uses AirPlay credentials, or tries the Companion ones with --companion.
        // atvctl seek SECONDS jumps to that position once the playing item is known.
        var seekPosition: Double?
        if command == "seek" {
            guard args.count > 1, let position = Double(args[1]) else { fail("usage: atvctl seek SECONDS") }
            seekPosition = position
        }
        let device = await device(named: deviceName)
        let useCompanion = args.contains("--companion")
        guard let credentials = useCompanion ? store.companionCredentials(for: device.id) : store.airPlayCredentials(for: device.id) else {
            fail("No credentials (run atvctl airpair, or pass --companion)")
        }
        let session = NowPlayingSession(endpoint: device.airPlayEndpoint, credentials: credentials, identity: store.identity)
        session.updateHandler = { info in
            print("now playing: \(String(describing: info.map { ($0.title, $0.subtitle ?? "-", $0.appName ?? "-", $0.duration ?? -1, $0.elapsedTime ?? -1, $0.isPlaying, $0.canSeek, $0.artworkURL?.absoluteString ?? "-", $0.artworkData?.count ?? 0) }))")
        }
        session.closeHandler = { error in print("closed: \(String(describing: error))") }
        do {
            try await session.start()
            print("AirPlay session started")
        } catch {
            fail("AirPlay session failed: \(error.localizedDescription) (\(error))")
        }
        if let seekPosition {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print("seeking to \(seekPosition) s")
            session.seek(to: seekPosition)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            session.stop()
            return
        }
        try? await Task.sleep(nanoseconds: 40_000_000_000)
        session.stop()

    case "raw":
        // atvctl raw IDENTIFIER key=int ... : send a request and print the response.
        guard args.count > 1 else { fail("usage: atvctl raw IDENTIFIER [key=intvalue ...]") }
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        let pairs: [(OPACK, OPACK)] = args.dropFirst(2).compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (.string(parts[0]), Int64(parts[1]).map { .int($0) } ?? .string(parts[1]))
        }
        do { print(try await client.rawRequest(args[1], .dict(pairs))) } catch { print("error: \(error)") }
        client.disconnect()

    case "swipe":
        guard args.count > 1 else { fail("usage: atvctl swipe up|down|left|right") }
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        let (dx, dy): (Double, Double) = switch args[1] {
        case "up": (0, -1)
        case "down": (0, 1)
        case "left": (-1, 0)
        default: (1, 0)
        }
        var x = 500.0, y = 500.0
        client.touch(x: x, y: y, phase: .press)
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            x += dx * 25
            y += dy * 25
            client.touch(x: x, y: y, phase: .hold)
        }
        client.touch(x: x, y: y, phase: .release)
        try? await Task.sleep(nanoseconds: 300_000_000)
        client.disconnect()

    case "on", "off":
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        do { try await command == "on" ? client.turnOn() : client.turnOff() } catch { fail("\(error)") }
        client.disconnect()

    default:
        guard let button = buttons[command] else { fail("unknown command \(command)") }
        let (client, _) = await connectedClient(store, deviceName: deviceName)
        do { try await client.press(button) } catch { fail("\(error)") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        client.disconnect()
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
await run()
exit(0)
