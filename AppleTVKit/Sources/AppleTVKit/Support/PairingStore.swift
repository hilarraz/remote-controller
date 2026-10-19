import Foundation

/// Our identity and the credentials obtained for each paired device, persisted as JSON
/// in a file only readable by the current user.
public struct PairingStore: Codable, Sendable {
    public var identity: ClientIdentity
    /// Companion credentials keyed by `AppleTVDevice.id`.
    public var credentials: [String: String]
    /// AirPlay credentials keyed by `AppleTVDevice.id`.
    public var airPlayCredentials: [String: String]
    public var lastDeviceID: String?

    public init(identity: ClientIdentity) {
        self.identity = identity
        credentials = [:]
        airPlayCredentials = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(ClientIdentity.self, forKey: .identity)
        credentials = try container.decodeIfPresent([String: String].self, forKey: .credentials) ?? [:]
        airPlayCredentials = try container.decodeIfPresent([String: String].self, forKey: .airPlayCredentials) ?? [:]
        lastDeviceID = try container.decodeIfPresent(String.self, forKey: .lastDeviceID)
    }

    public func companionCredentials(for deviceID: String) -> HAPCredentials? {
        credentials[deviceID].flatMap(HAPCredentials.init(string:))
    }

    public func airPlayCredentials(for deviceID: String) -> HAPCredentials? {
        airPlayCredentials[deviceID].flatMap(HAPCredentials.init(string:))
    }

    public static func load(from url: URL, defaultName: String) -> PairingStore {
        if let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(PairingStore.self, from: data) {
            return store
        }
        return PairingStore(identity: .generate(name: defaultName))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
