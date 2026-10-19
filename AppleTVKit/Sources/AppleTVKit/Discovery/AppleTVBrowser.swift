import Foundation
import Network

/// An Apple TV advertising the Companion link service on the local network.
public struct AppleTVDevice: Identifiable, Hashable, Sendable {
    /// Stable identifier: the MediaRemote route id when advertised, otherwise the name.
    public let id: String
    public let name: String
    public let model: String?
    public let endpoint: NWEndpoint
    public let properties: [String: String]

    /// The same Apple TV's AirPlay service (used for what is playing).
    public var airPlayEndpoint: NWEndpoint {
        .service(name: name, type: "_airplay._tcp", domain: "local.", interface: nil)
    }

    public var modelDescription: String {
        guard let model else { return "Apple TV" }
        switch model {
        case "AppleTV5,3": return "Apple TV HD"
        case "AppleTV6,2": return "Apple TV 4K"
        case "AppleTV11,1": return "Apple TV 4K (2e génération)"
        case "AppleTV14,1": return "Apple TV 4K (3e génération)"
        default: return "Apple TV"
        }
    }

    public init(name: String, model: String?, endpoint: NWEndpoint, properties: [String: String]) {
        self.id = properties["rpMRtID"] ?? name
        self.name = name
        self.model = model
        self.endpoint = endpoint
        self.properties = properties
    }

    public static func == (lhs: AppleTVDevice, rhs: AppleTVDevice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.model == rhs.model
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Browses `_companion-link._tcp` and reports the Apple TVs found.
public final class AppleTVBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "AppleTVKit.browser")

    /// Called on the main queue with the current list of devices.
    public var devicesHandler: (([AppleTVDevice]) -> Void)?
    /// Called on the main queue when browsing fails (e.g. local network access denied).
    public var errorHandler: ((String) -> Void)?

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_companion-link._tcp", domain: "local."), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                DispatchQueue.main.async { self?.errorHandler?(error.localizedDescription) }
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var devices: [String: AppleTVDevice] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var properties: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                properties = record.dictionary
            }
            let model = properties["rpMd"]
            // Only Apple TVs accept PIN pairing; Macs, iPads and HomePods also advertise the service.
            guard model?.hasPrefix("AppleTV") == true else { continue }
            let device = AppleTVDevice(name: name, model: model, endpoint: result.endpoint, properties: properties)
            devices[device.id] = device
        }
        let sorted = devices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.devicesHandler?(sorted) }
    }
}
