import AppleTVKit
import Foundation
import Observation

/// Favorite apps and the last app list received from the Apple TV, kept in the user
/// defaults so the remote and Shortcuts can offer them before the list is fetched again.
@MainActor
@Observable
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var favorites: [LaunchableApp]
    private(set) var knownApps: [LaunchableApp]

    private static let favoritesKey = "favoriteApps"
    private static let knownAppsKey = "knownApps"

    private init() {
        favorites = Self.load(Self.favoritesKey)
        knownApps = Self.load(Self.knownAppsKey)
    }

    func isFavorite(_ app: LaunchableApp) -> Bool {
        favorites.contains { $0.bundleID == app.bundleID }
    }

    func toggleFavorite(_ app: LaunchableApp) {
        if isFavorite(app) {
            favorites.removeAll { $0.bundleID == app.bundleID }
        } else {
            favorites.append(app)
        }
        Self.save(favorites, Self.favoritesKey)
    }

    /// Moves a favorite one place earlier (`offset` -1) or later (+1).
    func moveFavorite(_ app: LaunchableApp, by offset: Int) {
        guard let index = favorites.firstIndex(where: { $0.bundleID == app.bundleID }),
              favorites.indices.contains(index + offset) else { return }
        favorites.swapAt(index, index + offset)
        Self.save(favorites, Self.favoritesKey)
    }

    /// Remembers the apps installed on the Apple TV.
    func update(_ apps: [LaunchableApp]) {
        guard apps != knownApps else { return }
        knownApps = apps
        Self.save(apps, Self.knownAppsKey)
        RemoteShortcuts.updateAppShortcutParameters()
    }

    private static func load(_ key: String) -> [LaunchableApp] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LaunchableApp].self, from: data)) ?? []
    }

    private static func save(_ apps: [LaunchableApp], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(apps), forKey: key)
    }
}
