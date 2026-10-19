import AppleTVKit
import SwiftUI

enum NavigationStyle: String, CaseIterable, Identifiable {
    case touchpad
    case dpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .touchpad: return "Pavé tactile"
        case .dpad: return "Flèches"
        }
    }
}

/// The remote itself, shown in the main window and (compact) in the menu bar.
struct RemoteView: View {
    let model: RemoteModel
    var compact = false

    @AppStorage("navigationStyle") private var navigationStyle = NavigationStyle.touchpad
    @State private var showingApps = false
    @State private var keyboardDismissed = false
    @Environment(\.openWindow) private var openWindow

    private var keySize: CGFloat { compact ? 48 : 54 }

    var body: some View {
        VStack(spacing: compact ? 12 : 16) {
            header

            if let item = model.nowPlaying.item {
                NowPlayingCard(item: item, model: model)
            }

            if let session = model.textSession, !keyboardDismissed {
                KeyboardPanel(model: model, session: session) { keyboardDismissed = true }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if model.isConnected {
                navigationArea
                buttons
                favoritesBar
            } else {
                ConnectionStatusView(model: model, compact: compact) {
                    if compact { openMainWindow() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { toast }
        .animation(.snappy(duration: 0.25), value: model.textSession == nil || keyboardDismissed)
        .animation(.snappy(duration: 0.25), value: model.isConnected)
        .background(WindowRegistrar())
        .onAppear { MainWindow.openAction = openWindow }
        .onReceive(NotificationCenter.default.publisher(for: .textInputDidStart)) { _ in
            keyboardDismissed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .showKeyboardRequested)) { _ in
            keyboardDismissed = false
            if model.textSession == nil { model.refreshTextInput() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAppsRequested)) { _ in
            if model.isConnected { showingApps = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                if model.devices.isEmpty {
                    Text("Aucune Apple TV trouvée")
                }
                ForEach(model.devices) { device in
                    Button {
                        model.select(device)
                    } label: {
                        if device.id == model.selectedDeviceID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
                Divider()
                Button("Jumeler à nouveau…") {
                    if compact { openMainWindow() }
                    model.startPairing()
                }
                .disabled(model.selectedDevice == nil)
                if let device = model.selectedDevice, model.isPaired(device) {
                    Button("Oublier cette Apple TV", role: .destructive) {
                        model.forgetPairing(of: device)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "appletv.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedDevice?.name ?? "Apple TV")
                            .font(.headline)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()

            Spacer()

            if compact {
                RemoteKey(systemImage: "macwindow", label: "Ouvrir la fenêtre", size: 32) { openMainWindow() }
            }
            RemoteKey(systemImage: "power", label: model.powerState == .off ? "Réveiller l'Apple TV" : "Mettre en veille", size: 32) {
                model.togglePower()
            }
            .disabled(!model.isConnected)
        }
    }

    private var statusText: String {
        switch model.state {
        case .searching: return "Recherche…"
        case .needsPairing: return "Non jumelée"
        case .connecting: return "Connexion…"
        case .connected: return model.powerState == .off ? "En veille" : "Connectée"
        case .failed: return "Hors ligne"
        }
    }

    // MARK: Navigation

    @ViewBuilder private var navigationArea: some View {
        Group {
            switch navigationStyle {
            case .touchpad:
                TouchpadView(model: model)
            case .dpad:
                DPadView(model: model)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 200 : 220, maxHeight: compact ? 230 : .infinity)
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: compact ? 12 : 16) {
            HStack(alignment: .top, spacing: compact ? 36 : 44) {
                VStack(spacing: 14) {
                    RemoteKey(.menu, systemImage: "chevron.backward", label: "Retour (maintenir : écran d'accueil)", size: keySize, model: model)
                    RemoteKey(.playPause, systemImage: "playpause.fill", label: "Lecture / Pause", size: keySize, model: model)
                    RemoteKey(systemImage: "magnifyingglass", label: "Rechercher", size: keySize) { model.openSearch() }
                }
                VStack(spacing: 14) {
                    RemoteKey(.home, systemImage: "tv", label: "Accueil (maintenir : Centre de contrôle)", size: keySize, model: model)
                    VolumeRocker(model: model, width: keySize, halfHeight: keySize + 7)
                }
            }

            if let volume = model.volume, !compact {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { volume }, set: { model.setVolume($0) }), in: 0...1)
                        .controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }

            HStack(spacing: 14) {
                RemoteKey(systemImage: "gobackward.10", label: "Reculer de 10 s", size: 40) { model.skip(-10) }
                RemoteKey(systemImage: "keyboard", label: "Clavier (K)", size: 40) {
                    keyboardDismissed = false
                    if model.textSession == nil { model.refreshTextInput() }
                }
                RemoteKey(systemImage: "square.grid.2x2", label: "Apps (A)", size: 40) { showingApps = true }
                    .popover(isPresented: $showingApps, arrowEdge: .bottom) {
                        AppsView(model: model) { showingApps = false }
                    }
                RemoteKey(systemImage: "cone.fill", label: "Lire le lien copié avec VLC (V)", size: 40, tint: .orange) {
                    model.playClipboardInVLC()
                }
                RemoteKey(systemImage: "goforward.10", label: "Avancer de 10 s", size: 40) { model.skip(10) }
            }
        }
    }

    // MARK: Favorites

    /// One-click access to the favorite apps chosen in the app launcher.
    @ViewBuilder private var favoritesBar: some View {
        let favorites = AppCatalog.shared.favorites
        if !favorites.isEmpty {
            let icons = HStack(spacing: 10) {
                ForEach(favorites) { app in
                    Button {
                        model.launch(app)
                    } label: {
                        AppIcon(bundleID: app.bundleID, size: 36)
                    }
                    .buttonStyle(.plain)
                    .help("Ouvrir \(app.name)")
                    .contextMenu { FavoriteMenu(app: app, showsMoves: true) }
                }
            }
            ViewThatFits(in: .horizontal) {
                icons
                ScrollView(.horizontal) { icons }
                    .scrollIndicators(.never)
            }
        }
    }

    // MARK: Toast

    @ViewBuilder private var toast: some View {
        if let message = model.toast {
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 10)
                .padding(.horizontal, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func openMainWindow() {
        MainWindow.show()
    }
}

/// Placeholder shown instead of the controls while not connected.
private struct ConnectionStatusView: View {
    let model: RemoteModel
    let compact: Bool
    var onPair: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .searching:
                ProgressView()
                Text("Recherche d'Apple TV sur le réseau…")
                    .font(.headline)
                Text("Le Mac et l'Apple TV doivent être sur le même réseau, et l'accès au réseau local doit être autorisé dans Réglages Système › Confidentialité et sécurité › Réseau local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .needsPairing:
                Image(systemName: "appletv")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("« \(model.selectedDevice?.name ?? "Apple TV") » n'est pas encore jumelée")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Un code s'affichera sur le téléviseur.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Jumeler…") {
                    onPair()
                    model.startPairing()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            case .connecting:
                ProgressView()
                Text("Connexion à \(model.selectedDevice?.name ?? "l'Apple TV")…")
                    .font(.headline)
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("Réessayer", systemImage: "arrow.clockwise") { model.connect() }
                    .buttonStyle(.glass)
            case .connected:
                EmptyView()
            }
        }
        .padding(compact ? 14 : 24)
        .frame(maxWidth: .infinity, minHeight: compact ? 220 : 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// Registers the hosting window so keyboard shortcuts apply to it.
private struct WindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RegistrarView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RegistrarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { RemoteWindows.register(window) }
        }
    }
}
