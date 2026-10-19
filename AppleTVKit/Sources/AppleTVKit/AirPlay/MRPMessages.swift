import Foundation

/// Builders for the MediaRemote protocol messages we send (field numbers come from
/// pyatv's .proto definitions).
enum MRPMessages {
    enum Kind {
        static let sendCommand = 1
        static let setState = 4
        static let deviceInfo = 15
        static let clientUpdatesConfig = 16
        static let getKeyboardSession = 24
        static let playbackQueueRequest = 32
        static let setConnectionState = 38
        static let setNowPlayingClient = 46
        static let setNowPlayingPlayer = 47
        static let removeClient = 53
        static let removePlayer = 54
        static let updateClient = 55
        static let updateContentItem = 56
        static let updateContentItemArtwork = 57
        static let setDefaultSupportedCommands = 72
    }

    /// Field holding the inner message for each message type.
    enum Extension {
        static let sendCommand = 6
        static let setState = 9
        static let deviceInfo = 20
        static let clientUpdatesConfig = 21
        static let playbackQueueRequest = 37
        static let setConnectionState = 42
        static let setNowPlayingClient = 50
        static let setNowPlayingPlayer = 51
        static let removeClient = 57
        static let removePlayer = 58
        static let updateClient = 59
        static let updateContentItem = 60
        static let updateContentItemArtwork = 61
        static let setDefaultSupportedCommands = 75
    }

    /// Values of pyatv's `Command` enum (CommandInfo.proto).
    enum Command {
        static let seekToPlaybackPosition = 45
    }

    private static func message(type: Int, inner: (field: Int, build: (inout ProtoWriter) -> Void)? = nil) -> Data {
        var writer = ProtoWriter()
        writer.uint(1, UInt64(type))
        writer.string(2, UUID().uuidString)
        writer.uint(4, 0)
        if let inner { writer.message(inner.field, inner.build) }
        writer.string(85, UUID().uuidString)
        return writer.data
    }

    static func deviceInfo(identity: ClientIdentity, clientID: String) -> Data {
        message(type: Kind.deviceInfo, inner: (Extension.deviceInfo, { info in
            info.string(1, clientID)
            info.string(2, identity.name)
            info.string(3, "iPhone")
            info.string(4, "18G82")
            info.string(5, "com.apple.TVRemote")
            info.string(6, "344.28")
            info.int(7, 1)
            info.uint(8, 108)
            info.bool(9, true)
            info.bool(10, true)
            info.string(12, "com.apple.TVMusic")
            info.bool(13, true)
            info.bool(14, true)
            info.bool(15, true)
            info.uint(17, 2)
            info.uint(21, 1) // iPhone
            info.uint(22, 1)
        }))
    }

    static func setConnectionState() -> Data {
        message(type: Kind.setConnectionState, inner: (Extension.setConnectionState, { $0.uint(1, 2) }))
    }

    static func clientUpdatesConfig() -> Data {
        message(type: Kind.clientUpdatesConfig, inner: (Extension.clientUpdatesConfig, { config in
            config.bool(1, true)  // artwork
            config.bool(2, false) // now playing (legacy)
            config.bool(3, true)  // volume
            config.bool(4, true)  // keyboard
            config.bool(5, true)  // output devices
        }))
    }

    static func getKeyboardSession() -> Data {
        message(type: Kind.getKeyboardSession)
    }

    static func seek(to position: Double) -> Data {
        message(type: Kind.sendCommand, inner: (Extension.sendCommand, { command in
            command.uint(1, UInt64(Command.seekToPlaybackPosition))
            command.message(2) { $0.double(9, position) } // options.playbackPosition
        }))
    }

    static func playbackQueueRequest(location: Int) -> Data {
        message(type: Kind.playbackQueueRequest, inner: (Extension.playbackQueueRequest, { request in
            request.int(1, Int64(location))
            request.int(2, 1)
            request.double(4, -1)
            request.double(5, 600)
            request.bool(13, true)
        }))
    }
}

/// What the Apple TV is playing.
public struct NowPlayingInfo: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var appBundleID: String?
    public var appName: String?
    public var duration: Double?
    public var elapsedTime: Double?
    /// When `elapsedTime` was measured on the device.
    public var elapsedTimestamp: Date?
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Identifies the item, so artwork can be cached per item.
    public var itemIdentifier: String?
    public var artworkURL: URL?
    public var artworkData: Data?
    /// Whether the playing app accepts `NowPlayingSession.seek(to:)`.
    public var canSeek: Bool
}

/// Tracks clients (apps), their players and play queues from MRP messages, like
/// pyatv's PlayerStateManager.
final class NowPlayingTracker {
    private final class Player {
        var playbackState: Int?
        /// Command number → enabled; nil until the player announced its commands.
        var supportedCommands: [Int: Bool]?
        var items: [(identifier: String, metadata: ProtoMessage, artwork: Data?)] = []
        var location = 0
    }

    private final class Client {
        var displayName: String?
        var activePlayerID: String?
        var players: [String: Player] = [:]
        /// Commands of players that did not announce their own.
        var defaultCommands: [Int: Bool] = [:]

        var activePlayer: Player? {
            players[activePlayerID ?? ""] ?? players["MediaRemote-DefaultPlayer"]
        }
    }

    private var clients: [String: Client] = [:]
    private var activeClientID: String?
    private var artworkRequested: Set<String> = []
    private(set) var current: NowPlayingInfo?

    /// Asks the session to fetch artwork for the item at a queue location.
    var requestArtwork: ((Int) -> Void)?

    private func client(_ bundleID: String) -> Client {
        if let client = clients[bundleID] { return client }
        let client = Client()
        clients[bundleID] = client
        return client
    }

    private func player(at path: ProtoMessage?) -> Player {
        let client = client(path?.message(2)?.string(2) ?? "")
        if let name = path?.message(2)?.string(7) { client.displayName = name }
        let playerID = path?.message(3)?.string(1) ?? "MediaRemote-DefaultPlayer"
        if let player = client.players[playerID] { return player }
        let player = Player()
        client.players[playerID] = player
        return player
    }

    /// Applies a message; returns true when `current` changed.
    func handle(_ message: ProtoMessage, type: Int) -> Bool {
        typealias K = MRPMessages.Kind
        typealias E = MRPMessages.Extension
        switch type {
        case K.setState:
            guard let state = message.message(E.setState) else { return false }
            let player = player(at: state.message(9))
            if let playbackState = state.uint(6) { player.playbackState = Int(playbackState) }
            if let commands = state.message(2) { player.supportedCommands = Self.commands(commands) }
            if let queue = state.message(3) {
                let items = queue.messages(2).map { item in
                    (identifier: item.string(1) ?? "", metadata: item.message(2) ?? ProtoMessage(), artwork: item.bytes(3))
                }
                // A queue answering our artwork request only carries artwork: merge it.
                if state.has(10) || items.allSatisfy({ $0.artwork != nil && $0.metadata.fields.isEmpty }) {
                    merge(items, into: player)
                } else {
                    player.items = items
                    player.location = Int(queue.int(1) ?? 0)
                }
            }
        case K.updateContentItem, K.updateContentItemArtwork:
            let field = type == K.updateContentItem ? E.updateContentItem : E.updateContentItemArtwork
            guard let update = message.message(field) else { return false }
            let items = update.messages(1).map { item in
                (identifier: item.string(1) ?? "", metadata: item.message(2) ?? ProtoMessage(), artwork: item.bytes(3))
            }
            merge(items, into: player(at: update.message(2)))
        case K.setDefaultSupportedCommands:
            guard let inner = message.message(E.setDefaultSupportedCommands) else { return false }
            client(inner.message(9)?.message(2)?.string(2) ?? "").defaultCommands = Self.commands(inner.message(2))
        case K.setNowPlayingClient:
            guard let inner = message.message(E.setNowPlayingClient) else { return false }
            let bundleID = inner.message(1)?.string(2) ?? ""
            activeClientID = bundleID
            if let name = inner.message(1)?.string(7) { client(bundleID).displayName = name }
        case K.setNowPlayingPlayer:
            guard let path = message.message(E.setNowPlayingPlayer)?.message(1) else { return false }
            _ = player(at: path)
            client(path.message(2)?.string(2) ?? "").activePlayerID = path.message(3)?.string(1)
        case K.updateClient:
            guard let inner = message.message(E.updateClient)?.message(1) else { return false }
            if let name = inner.string(7) { client(inner.string(2) ?? "").displayName = name }
        case K.removeClient:
            guard let bundleID = message.message(E.removeClient)?.message(1)?.string(2) else { return false }
            clients[bundleID] = nil
            if activeClientID == bundleID { activeClientID = nil }
        case K.removePlayer:
            guard let path = message.message(E.removePlayer)?.message(1) else { return false }
            let client = client(path.message(2)?.string(2) ?? "")
            let playerID = path.message(3)?.string(1) ?? ""
            client.players[playerID] = nil
            if client.activePlayerID == playerID { client.activePlayerID = nil }
        default:
            return false
        }
        return recompute()
    }

    /// Reads a SupportedCommands message.
    private static func commands(_ message: ProtoMessage?) -> [Int: Bool] {
        var commands: [Int: Bool] = [:]
        for info in message?.messages(1) ?? [] {
            if let command = info.uint(1) { commands[Int(command)] = info.bool(2) ?? false }
        }
        return commands
    }

    private func merge(_ updates: [(identifier: String, metadata: ProtoMessage, artwork: Data?)], into player: Player) {
        for update in updates {
            guard let index = player.items.firstIndex(where: { $0.identifier == update.identifier }) else { continue }
            player.items[index].metadata.merge(update.metadata)
            if let artwork = update.artwork { player.items[index].artwork = artwork }
        }
    }

    private func recompute() -> Bool {
        let info = makeInfo()
        guard info != current else { return false }
        current = info
        return true
    }

    private func makeInfo() -> NowPlayingInfo? {
        guard let clientID = activeClientID, let client = clients[clientID],
              let player = client.activePlayer, player.items.indices.contains(player.location) else { return nil }
        // Playing or paused only; stopped players have nothing to show.
        guard let state = player.playbackState, state == 1 || state == 2 else { return nil }
        let item = player.items[player.location]
        let metadata = item.metadata

        let appName = client.displayName
        guard let title = metadata.string(1) ?? appName else { return nil }

        var subtitle = metadata.string(7) ?? metadata.string(2)
        if let series = metadata.string(63) {
            let season = metadata.int(10).map { "S\($0)" }
            let episode = metadata.int(11).map { "E\($0)" }
            let numbering = [season, episode].compactMap { $0 }.joined(separator: " ")
            subtitle = numbering.isEmpty ? series : "\(series) · \(numbering)"
        }
        if subtitle == nil { subtitle = metadata.string(6) }

        let rate = Double(metadata.float(39) ?? (state == 1 ? 1 : 0))
        let timestamp = metadata.double(74).map { Date(timeIntervalSinceReferenceDate: $0) }

        var artworkURL: URL?
        if let template = metadata.string(80), template.contains("{w}") {
            let url = template
                .replacingOccurrences(of: "{w}", with: "600")
                .replacingOccurrences(of: "{h}", with: "600")
                .replacingOccurrences(of: "{c}", with: "bb")
                .replacingOccurrences(of: "{f}", with: "jpg")
            artworkURL = URL(string: url)
        }
        if artworkURL == nil, let url = metadata.string(70) { artworkURL = URL(string: url) }

        let seek = MRPMessages.Command.seekToPlaybackPosition
        let canSeek = player.supportedCommands?[seek] ?? client.defaultCommands[seek] ?? false

        // Artwork without a URL has to be requested through the playback queue.
        if artworkURL == nil, item.artwork == nil, metadata.bool(19) == true, !artworkRequested.contains(item.identifier) {
            artworkRequested.insert(item.identifier)
            requestArtwork?(player.location)
        }

        return NowPlayingInfo(
            title: title,
            subtitle: subtitle == title ? nil : subtitle,
            appBundleID: clientID,
            appName: appName,
            duration: metadata.double(14).flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            elapsedTime: metadata.double(35),
            elapsedTimestamp: timestamp,
            playbackRate: state == 2 ? 0 : rate,
            isPlaying: state == 1 && rate != 0,
            itemIdentifier: item.identifier,
            artworkURL: artworkURL,
            artworkData: item.artwork,
            canSeek: canSeek
        )
    }
}
