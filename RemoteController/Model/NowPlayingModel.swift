import AppKit
import AppleTVKit
import Observation

/// What is currently playing on the Apple TV, read through an AirPlay (MediaRemote)
/// session that reuses the Companion pairing.
@MainActor
@Observable
final class NowPlayingModel {
    struct Item: Equatable {
        var title: String
        var subtitle: String?
        var appName: String?
        var artwork: NSImage?
        var duration: Double?
        var elapsedTime: Double?
        var playbackRate: Double = 0
        /// Moment `elapsedTime` was measured, to extrapolate progress while playing.
        var timestamp = Date()

        var isPlaying: Bool { playbackRate > 0 }

        func elapsed(at date: Date) -> Double? {
            guard let elapsedTime else { return nil }
            let value = elapsedTime + (isPlaying ? date.timeIntervalSince(timestamp) * playbackRate : 0)
            return duration.map { min(max(value, 0), $0) } ?? max(value, 0)
        }
    }

    private(set) var item: Item?

    private var session: NowPlayingSession?
    private var device: AppleTVDevice?
    private var store: PairingStore?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(3)
    private var artworkCache: [String: NSImage] = [:]
    private var artworkKey: String?

    func start(device: AppleTVDevice, store: PairingStore) {
        stop()
        self.device = device
        self.store = store
        open()
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        session?.stop()
        session = nil
        device = nil
        item = nil
    }

    private func open() {
        guard let device, let store,
              let credentials = store.airPlayCredentials(for: device.id) ?? store.companionCredentials(for: device.id) else { return }
        let session = NowPlayingSession(endpoint: device.airPlayEndpoint, credentials: credentials, identity: store.identity)
        session.updateHandler = { [weak self, weak session] info in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.update(info)
            }
        }
        session.closeHandler = { [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.sessionEnded()
            }
        }
        self.session = session
        Task {
            do {
                try await session.start()
                retryDelay = .seconds(3)
            } catch {
                guard self.session === session else { return }
                sessionEnded()
            }
        }
    }

    /// Reconnects with a growing delay: AirPlay sessions end when the Apple TV sleeps.
    private func sessionEnded() {
        session?.stop()
        session = nil
        item = nil
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(60))
        retryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, device != nil else { return }
            open()
        }
    }

    private func update(_ info: NowPlayingInfo?) {
        guard let info else {
            item = nil
            return
        }
        let key = info.artworkURL?.absoluteString ?? info.itemIdentifier.map { "item:\($0)" }
        var artwork = key.flatMap { artworkCache[$0] }
        if artwork == nil, let data = info.artworkData, let image = NSImage(data: data) {
            artwork = image
            if let key { artworkCache[key] = image }
        }
        if artwork == nil, key == artworkKey { artwork = item?.artwork }
        artworkKey = key

        item = Item(
            title: info.title,
            subtitle: info.subtitle,
            appName: info.appName,
            artwork: artwork,
            duration: info.duration,
            elapsedTime: info.elapsedTime,
            playbackRate: info.playbackRate,
            timestamp: info.elapsedTimestamp ?? Date()
        )

        if artwork == nil, let url = info.artworkURL, let key {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
                artworkCache[key] = image
                if artworkKey == key { item?.artwork = image }
            }
        }
    }
}
