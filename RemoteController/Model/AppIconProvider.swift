import AppKit
import Observation

/// Fetches app icons from the public App Store lookup API (most tvOS apps share their
/// bundle identifier with the iOS version) and caches them on disk.
@MainActor
@Observable
final class AppIconProvider {
    static let shared = AppIconProvider()

    private(set) var icons: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let cacheDirectory = URL.cachesDirectory.appendingPathComponent("Remote/Icons", isDirectory: true)

    /// Symbols for Apple's built-in tvOS apps, which are not on the App Store.
    static let builtInSymbols: [String: String] = [
        "com.apple.TVWatchList": "tv",
        "com.apple.TVMusic": "music.note",
        "com.apple.TVPhotos": "photo.on.rectangle",
        "com.apple.TVSettings": "gearshape.fill",
        "com.apple.TVAppStore": "bag.fill",
        "com.apple.TVSearch": "magnifyingglass",
        "com.apple.Arcade": "gamecontroller.fill",
        "com.apple.Fitness": "figure.run",
        "com.apple.podcasts": "mic.fill",
        "com.apple.facetime": "video.fill",
        "com.apple.TVHomeSharing": "desktopcomputer",
        "com.apple.Sing": "music.mic",
        "com.apple.TVMovies": "film.fill",
        "com.apple.TVShows": "play.tv.fill",
    ]

    func icon(for bundleID: String) -> NSImage? {
        icons[bundleID]
    }

    /// Loads the icon from the disk cache or the App Store; call outside of view updates.
    func load(_ bundleID: String) {
        guard Self.builtInSymbols[bundleID] == nil, requested.insert(bundleID).inserted else { return }
        let file = cacheDirectory.appendingPathComponent("\(bundleID).png")
        if let image = NSImage(contentsOf: file) {
            icons[bundleID] = image
            return
        }
        Task {
            guard let image = await Self.fetch(bundleID) else { return }
            icons[bundleID] = image
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
            }
        }
    }

    private nonisolated static func fetch(_ bundleID: String) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "fr"),
        ]
        struct Response: Decodable {
            struct Result: Decodable { let artworkUrl512: String? }
            let results: [Result]
        }
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let artwork = response.results.first?.artworkUrl512.flatMap(URL.init(string:)),
              let (imageData, _) = try? await URLSession.shared.data(from: artwork) else { return nil }
        return NSImage(data: imageData)
    }
}
