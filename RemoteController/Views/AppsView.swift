import AppleTVKit
import SwiftUI

/// Grid of the apps installed on the Apple TV, favorites first; clicking one opens it.
struct AppsView: View {
    let model: RemoteModel
    var onLaunch: () -> Void = {}

    @State private var filter = ""
    private let catalog = AppCatalog.shared

    private var filteredApps: [LaunchableApp] {
        guard !filter.isEmpty else { return model.apps }
        return model.apps.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Rechercher une app", text: $filter)
                .textFieldStyle(.roundedBorder)

            if model.isLoadingApps && model.apps.isEmpty {
                ProgressView("Chargement des apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                ContentUnavailableView(
                    model.apps.isEmpty ? "Aucune app" : "Aucun résultat",
                    systemImage: "square.grid.2x2"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if filter.isEmpty && !catalog.favorites.isEmpty {
                            sectionTitle("Favoris")
                            grid(catalog.favorites, inFavorites: true)
                            sectionTitle("Toutes les apps")
                        }
                        grid(filteredApps, inFavorites: false)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 400)
        .onAppear { model.loadApps() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func grid(_ apps: [LaunchableApp], inFavorites: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 12) {
            ForEach(apps) { app in
                Button {
                    model.launch(app)
                    onLaunch()
                } label: {
                    VStack(spacing: 6) {
                        AppIcon(bundleID: app.bundleID)
                        Text(app.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(app.name)
                .contextMenu { FavoriteMenu(app: app, showsMoves: inFavorites) }
            }
        }
    }
}

/// Context menu items to add, remove and order a favorite app.
struct FavoriteMenu: View {
    let app: LaunchableApp
    var showsMoves = false
    private let catalog = AppCatalog.shared

    var body: some View {
        if catalog.isFavorite(app) {
            Button("Retirer des favoris", systemImage: "star.slash") { catalog.toggleFavorite(app) }
            if showsMoves {
                Button("Déplacer avant", systemImage: "arrow.left") { catalog.moveFavorite(app, by: -1) }
                    .disabled(catalog.favorites.first == app)
                Button("Déplacer après", systemImage: "arrow.right") { catalog.moveFavorite(app, by: 1) }
                    .disabled(catalog.favorites.last == app)
            }
        } else {
            Button("Ajouter aux favoris", systemImage: "star") { catalog.toggleFavorite(app) }
        }
    }
}

/// Icon of a tvOS app, from the App Store when allowed, otherwise a symbol.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 52

    @AppStorage("fetchAppIcons") private var fetch = true
    private let provider = AppIconProvider.shared

    var body: some View {
        icon
            .frame(width: size, height: size)
            .task(id: bundleID) {
                if fetch { provider.load(bundleID) }
            }
    }

    @ViewBuilder private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
        if fetch, let image = provider.icon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(shape)
        } else {
            shape
                .fill(.quaternary)
                .overlay {
                    Image(systemName: AppIconProvider.builtInSymbols[bundleID] ?? "app.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                }
        }
    }
}
