import AppleTVKit
import SwiftUI

struct SettingsView: View {
    let model: RemoteModel

    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Apple TV", systemImage: "appletv") {
                DeviceSettings(model: model)
            }
            Tab("Raccourcis", systemImage: "keyboard") {
                ShortcutList()
            }
        }
        .frame(width: 480, height: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage("navigationStyle") private var navigationStyle = NavigationStyle.touchpad
    @AppStorage("pasteHotKeyEnabled") private var hotKeyEnabled = true
    @AppStorage("pasteHotKey") private var hotKey = GlobalHotKey.Preset.controlOptionV.rawValue
    @AppStorage("fetchAppIcons") private var fetchAppIcons = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage(TextInputNotifier.enabledKey) private var notifyTextInput = true

    var body: some View {
        Form {
            Picker("Navigation", selection: $navigationStyle) {
                ForEach(NavigationStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Section {
                Toggle("Coller sur l'Apple TV depuis n'importe quelle app", isOn: $hotKeyEnabled)
                Picker("Raccourci", selection: $hotKey) {
                    ForEach(GlobalHotKey.Preset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .disabled(!hotKeyEnabled)
            } footer: {
                Text("Envoie le texte du presse-papiers dans le champ actif de l'Apple TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Prévenir quand l'Apple TV attend du texte", isOn: $notifyTextInput)
            } footer: {
                Text("Une notification apparaît quand un champ de texte est sélectionné sur l'Apple TV et que la télécommande n'est pas à l'écran. Répondez-y pour écrire sur l'Apple TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Afficher dans la barre des menus", isOn: $showMenuBarExtra)
                Toggle("Icônes des apps depuis l'App Store", isOn: $fetchAppIcons)
            }
        }
        .formStyle(.grouped)
        .onChange(of: hotKeyEnabled) { HotKeyManager.shared.update() }
        .onChange(of: hotKey) { HotKeyManager.shared.update() }
    }
}

private struct DeviceSettings: View {
    let model: RemoteModel

    var body: some View {
        Form {
            Section {
                if model.devices.isEmpty {
                    Text("Aucune Apple TV trouvée sur le réseau.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.modelDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isPaired(device) {
                            Label("Jumelée", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                            Button("Oublier") { model.forgetPairing(of: device) }
                        } else {
                            Button("Jumeler…") {
                                model.select(device)
                                model.startPairing()
                            }
                        }
                    }
                }
            } header: {
                Text("Apple TV du réseau")
            } footer: {
                Text("Ce Mac apparaît sous le nom « \(model.identityName) » dans Réglages › Télécommandes et appareils de l'Apple TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutList: View {
    private let shortcuts: [(String, String)] = [
        ("← ↑ → ↓", "Naviguer"),
        ("↩", "Sélectionner (maintenir : menu contextuel)"),
        ("⎋ ou ⌫", "Retour"),
        ("H", "Accueil (maintenir : Centre de contrôle)"),
        ("Espace", "Lecture / Pause"),
        ("J / L", "Reculer / avancer de 10 s"),
        ("+ / −", "Volume"),
        ("/", "Rechercher"),
        ("K", "Clavier"),
        ("A", "Apps"),
        ("V", "Lire le lien copié avec VLC"),
        ("⌘V", "Coller le presse-papiers sur l'Apple TV"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(shortcuts, id: \.0) { key, action in
                    LabeledContent(action) {
                        Text(key)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Actifs quand la télécommande est au premier plan et qu'aucun champ de texte n'est en cours d'édition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
