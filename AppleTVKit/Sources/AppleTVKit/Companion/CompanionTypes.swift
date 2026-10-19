import Foundation

/// Buttons understood by the `_hidC` command.
public enum HIDCommand: Int64, Sendable, CaseIterable {
    case up = 1
    case down = 2
    case left = 3
    case right = 4
    case menu = 5
    case select = 6
    case home = 7
    case volumeUp = 8
    case volumeDown = 9
    case siri = 10
    case screensaver = 11
    case sleep = 12
    case wake = 13
    case playPause = 14
    case channelUp = 15
    case channelDown = 16
    case guide = 17
    case pageUp = 18
    case pageDown = 19
}

/// Commands understood by `_mcc` (media control).
public enum MediaCommand: Int64, Sendable {
    case play = 1
    case pause = 2
    case nextTrack = 3
    case previousTrack = 4
    case getVolume = 5
    case setVolume = 6
    case skipBy = 7
    case fastForwardBegin = 8
    case fastForwardEnd = 9
    case rewindBegin = 10
    case rewindEnd = 11
    case getCaptionSettings = 12
    case setCaptionSettings = 13
}

/// Phase of a touch on the virtual touch surface (coordinates are 0...1000).
public enum TouchPhase: Int64, Sendable {
    case press = 1
    case hold = 3
    case release = 4
    case click = 5
}

public enum PowerState: Sendable, Equatable {
    case unknown
    case on
    case off

    init(systemStatus: Int64) {
        switch systemStatus {
        case 1: self = .off
        case 2, 3, 4: self = .on
        default: self = .unknown
        }
    }
}

/// Media controls currently offered by the playing app (`_iMC` event).
public struct MediaControlFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    public static let play = MediaControlFlags(rawValue: 0x0001)
    public static let pause = MediaControlFlags(rawValue: 0x0002)
    public static let nextTrack = MediaControlFlags(rawValue: 0x0004)
    public static let previousTrack = MediaControlFlags(rawValue: 0x0008)
    public static let fastForward = MediaControlFlags(rawValue: 0x0010)
    public static let rewind = MediaControlFlags(rawValue: 0x0020)
    public static let volume = MediaControlFlags(rawValue: 0x0100)
    public static let skipForward = MediaControlFlags(rawValue: 0x0200)
    public static let skipBackward = MediaControlFlags(rawValue: 0x0400)
}

/// A text field focused on the Apple TV.
public struct TextInputSession: Sendable, Equatable {
    public let sessionUUID: Data
    public var text: String
    /// Short title of the field (e.g. "Rechercher").
    public var title: String?
    /// Longer hint shown in the empty field.
    public var placeholder: String?
}

public struct LaunchableApp: Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum CompanionEvent: Sendable {
    case powerState(PowerState)
    case mediaControls(MediaControlFlags)
    case volume(Double)
    case textInputStarted(TextInputSession)
    case textInputStopped
    case disconnected(String?)
}

/// How this Mac presents itself to the Apple TV.
public struct ClientIdentity: Codable, Sendable, Equatable {
    public var name: String
    public var model: String
    public var deviceID: String
    public var rpID: String

    public init(name: String, model: String, deviceID: String, rpID: String) {
        self.name = name
        self.model = model
        self.deviceID = deviceID
        self.rpID = rpID
    }

    public static func generate(name: String) -> ClientIdentity {
        var mac = [UInt8](Data.random(count: 6))
        mac[0] = (mac[0] & 0xFC) | 0x02 // locally administered, unicast
        return ClientIdentity(
            name: name,
            model: "iPhone10,6",
            deviceID: mac.map { String(format: "%02X", $0) }.joined(separator: ":"),
            rpID: Data.random(count: 6).hexString
        )
    }
}
