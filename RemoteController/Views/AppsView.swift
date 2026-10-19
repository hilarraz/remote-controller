import AppleTVKit
import SwiftUI

/// Grid of the apps installed on the Apple TV; clicking one opens it.
struct AppsView: View {
    let model: RemoteModel
    var onLaunch: () -> Void = {}

    @State private var filter = ""
    @AppStorage("fetchAppIcons") private var fetchAppIcons = true

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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 12) {
                        ForEach(filteredApps) { app in
                            Button {
                                model.launch(app)
                                onLaunch()
                            } label: {
                                VStack(spacing: 6) {
                                    AppIcon(bundleID: app.bundleID, fetch: fetchAppIcons)
                                        .frame(width: 52, height: 52)
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
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 400)
        .onAppear { model.loadApps() }
    }
}

private struct AppIcon: View {
    let bundleID: String
    let fetch: Bool
    private let provider = AppIconProvider.shared

    var body: some View {
        icon
            .task(id: bundleID) {
                if fetch { provider.load(bundleID) }
            }
    }

    @ViewBuilder private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
        }
    }
}
