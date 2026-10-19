import Foundation

/// An audio track or subtitle offered by the playing app (MRP `LanguageOption`).
public struct LanguageOption: Sendable, Hashable {
    public enum Kind: Sendable {
        case audio
        case subtitles
    }

    public let kind: Kind
    public let languageTag: String?
    public let displayName: String?
    public let characteristics: [String]
    public let identifier: String?
    /// The option as received, which is what the enable/disable commands carry.
    let encoded: Data

    init?(_ data: Data) {
        guard let message = ProtoMessage(data) else { return nil }
        characteristics = message.bytesList(3).compactMap { String(data: $0, encoding: .utf8) }
        // Types follow MPNowPlayingInfoLanguageOptionType: 0 audible, 1 legible.
        if characteristics.contains("public.legible") {
            kind = .subtitles
        } else if characteristics.contains("public.audible") {
            kind = .audio
        } else {
            kind = message.uint(1) == 1 ? .subtitles : .audio
        }
        languageTag = message.string(2)
        displayName = message.string(4)
        identifier = message.string(5)
        encoded = data
    }

    /// The app's name for the option, otherwise its language in the user's language.
    public var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let languageTag, let name = Locale.current.localizedString(forIdentifier: languageTag) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return languageTag ?? identifier ?? "Piste"
    }

    /// Whether both describe the same track; the current selection is not always
    /// encoded exactly like the available options.
    public func matches(_ other: LanguageOption) -> Bool {
        if let identifier, let otherIdentifier = other.identifier { return identifier == otherIdentifier }
        return kind == other.kind && languageTag == other.languageTag && displayName == other.displayName
            && characteristics == other.characteristics
    }
}

/// Mutually exclusive options, e.g. the audio tracks or the subtitles.
public struct LanguageOptionGroup: Sendable, Hashable {
    /// Whether nothing may be selected, which is how subtitles are turned off.
    public let allowsEmptySelection: Bool
    public let options: [LanguageOption]

    public var kind: LanguageOption.Kind? { options.first?.kind }

    init(_ message: ProtoMessage) {
        allowsEmptySelection = message.bool(1) ?? false
        options = message.bytesList(3).compactMap(LanguageOption.init)
    }
}
