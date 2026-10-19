import AppKit
import SwiftUI

@main
struct RemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    private let model = RemoteModel.shared

    var body: some Scene {
        Window("Remote", id: "remote") {
            RemoteView(model: model)
                .frame(minWidth: 300, idealWidth: 320, minHeight: 640, idealHeight: 700)
                .containerBackground(.thinMaterial, for: .window)
                .sheet(item: Bindable(model).pairing) { flow in
                    PairingView(flow: flow) { model.pairing = nil }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 320, height: 700)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Apple TV") {
                Button("Coller sur l'Apple TV") { model.pasteClipboard() }
                Button("Afficher le clavier") {
                    NotificationCenter.default.post(name: .showKeyboardRequested, object: nil)
                }
                Button("Apps…") {
                    NotificationCenter.default.post(name: .showAppsRequested, object: nil)
                }
                Divider()
                Button("Mettre en veille / Réveiller") { model.togglePower() }
                Button("Jumeler à nouveau…") { model.startPairing() }
                    .disabled(model.selectedDevice == nil)
            }
        }

        MenuBarExtra("Remote", systemImage: "appletvremote.gen4.fill", isInserted: $showMenuBarExtra) {
            RemoteView(model: model, compact: true)
                .frame(width: 300)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyboard: KeyboardController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let keyboard = KeyboardController(model: RemoteModel.shared)
            keyboard.start()
            self.keyboard = keyboard
            HotKeyManager.shared.update()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar.
        !UserDefaults.standard.bool(forKey: "showMenuBarExtra", default: true)
    }
}

/// Registers the global "paste on Apple TV" shortcut according to the settings.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKey: GlobalHotKey?

    func update() {
        hotKey = nil
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "pasteHotKeyEnabled", default: true) else { return }
        let preset = defaults.string(forKey: "pasteHotKey").flatMap(GlobalHotKey.Preset.init(rawValue:)) ?? .controlOptionV
        hotKey = GlobalHotKey(preset: preset) {
            MainActor.assumeIsolated { RemoteModel.shared.pasteClipboard() }
        }
        if hotKey == nil {
            RemoteModel.shared.showToast("Le raccourci \(preset.title) est déjà utilisé par une autre app.")
        }
    }
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
