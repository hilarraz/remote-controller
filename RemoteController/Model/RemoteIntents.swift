import AppIntents
import AppKit
import AppleTVKit

// Actions offered to Shortcuts, Spotlight and Siri. They run in the app, which connects
// to the Apple TV on launch; actions wait a few seconds for that connection.

/// Reports failures with the remote's own (French) error messages.
struct RemoteIntentError: LocalizedError, CustomLocalizedStringResourceConvertible {
    let message: String

    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }

    static func run(_ action: @MainActor () async throws -> Void) async throws {
        do {
            try await action()
        } catch {
            throw RemoteIntentError(message: error.localizedDescription)
        }
    }
}

// MARK: Apps

struct TVAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "App de l'Apple TV")
    static let defaultQuery = TVAppQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ app: LaunchableApp) {
        id = app.bundleID
        name = app.name
    }
}

struct TVAppQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [TVAppEntity.ID]) async throws -> [TVAppEntity] {
        let apps = await Self.apps()
        return identifiers.compactMap { id in apps.first { $0.bundleID == id }.map(TVAppEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TVAppEntity] {
        await Self.apps().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(TVAppEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TVAppEntity] {
        await Self.apps().map(TVAppEntity.init)
    }

    /// Favorites first, then the other apps known from the last connection; asks the
    /// Apple TV when none are known yet.
    @MainActor
    private static func apps() async -> [LaunchableApp] {
        let catalog = AppCatalog.shared
        var known = catalog.knownApps
        if known.isEmpty, let fetched = try? await RemoteModel.shared.refreshApps() {
            known = fetched
        }
        let favoriteIDs = Set(catalog.favorites.map(\.bundleID))
        return catalog.favorites + known.filter { !favoriteIDs.contains($0.bundleID) }
    }
}

struct OpenTVAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir une app sur l'Apple TV"
    static let description = IntentDescription("Ouvre une app installée sur l'Apple TV.")

    @Parameter(title: "App")
    var app: TVAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Ouvrir \(\.$app) sur l'Apple TV")
    }

    func perform() async throws -> some IntentResult {
        let bundleID = app.id
        try await RemoteIntentError.run { try await RemoteModel.shared.launch(bundleID: bundleID) }
        return .result()
    }
}

// MARK: Playback and buttons

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Lecture/pause sur l'Apple TV"
    static let description = IntentDescription("Met en pause ou reprend la lecture sur l'Apple TV.")

    func perform() async throws -> some IntentResult {
        try await RemoteIntentError.run { try await RemoteModel.shared.press(.playPause) }
        return .result()
    }
}

enum TVButton: String, AppEnum {
    case up, down, left, right, select, menu, home, playPause, volumeUp, volumeDown

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bouton")
    static let caseDisplayRepresentations: [TVButton: DisplayRepresentation] = [
        .up: "Haut",
        .down: "Bas",
        .left: "Gauche",
        .right: "Droite",
        .select: "Sélection",
        .menu: "Retour",
        .home: "TV / Accueil",
        .playPause: "Lecture/Pause",
        .volumeUp: "Volume +",
        .volumeDown: "Volume −",
    ]

    var command: HIDCommand {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .select: .select
        case .menu: .menu
        case .home: .home
        case .playPause: .playPause
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        }
    }
}

struct PressTVButtonIntent: AppIntent {
    static let title: LocalizedStringResource = "Appuyer sur un bouton de l'Apple TV"
    static let description = IntentDescription("Appuie sur un bouton de la télécommande.")

    @Parameter(title: "Bouton")
    var button: TVButton

    static var parameterSummary: some ParameterSummary {
        Summary("Appuyer sur \(\.$button)")
    }

    func perform() async throws -> some IntentResult {
        let command = button.command
        try await RemoteIntentError.run { try await RemoteModel.shared.press(command) }
        return .result()
    }
}

enum TVPowerAction: String, AppEnum {
    case wake, sleep

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Action")
    static let caseDisplayRepresentations: [TVPowerAction: DisplayRepresentation] = [
        .wake: "Réveiller",
        .sleep: "Mettre en veille",
    ]
}

struct SetTVPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Réveiller ou mettre en veille l'Apple TV"
    static let description = IntentDescription("Réveille l'Apple TV ou la met en veille (avec le téléviseur si HDMI-CEC est activé).")

    @Parameter(title: "Action")
    var action: TVPowerAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) l'Apple TV")
    }

    func perform() async throws -> some IntentResult {
        let on = action == .wake
        try await RemoteIntentError.run { try await RemoteModel.shared.setPower(on: on) }
        return .result()
    }
}

// MARK: Text

struct PasteOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Coller sur l'Apple TV"
    static let description = IntentDescription("Envoie le texte du presse-papiers du Mac dans le champ actif de l'Apple TV.")

    func perform() async throws -> some IntentResult {
        try await RemoteIntentError.run {
            guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else {
                throw RemoteIntentError(message: "Le presse-papiers ne contient pas de texte.")
            }
            try await RemoteModel.shared.typeText(string)
        }
        return .result()
    }
}

struct TypeOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Écrire sur l'Apple TV"
    static let description = IntentDescription("Écrit un texte dans le champ actif de l'Apple TV, par exemple une recherche.")

    @Parameter(title: "Texte")
    var text: String

    @Parameter(title: "Remplacer le contenu du champ", default: true)
    var replace: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Écrire \(\.$text) sur l'Apple TV") {
            \.$replace
        }
    }

    func perform() async throws -> some IntentResult {
        let text = text
        let replace = replace
        try await RemoteIntentError.run { try await RemoteModel.shared.typeText(text, replacing: replace) }
        return .result()
    }
}

// MARK: App Shortcuts

/// Actions available in Spotlight and Siri without creating a shortcut first.
struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTVAppIntent(),
            phrases: [
                "Ouvrir \(\.$app) sur l'Apple TV avec \(.applicationName)",
                "Lancer \(\.$app) avec \(.applicationName)",
            ],
            shortTitle: "Ouvrir une app",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Mettre en pause l'Apple TV avec \(.applicationName)",
                "Reprendre la lecture avec \(.applicationName)",
            ],
            shortTitle: "Lecture/pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: PasteOnTVIntent(),
            phrases: ["Coller sur l'Apple TV avec \(.applicationName)"],
            shortTitle: "Coller sur l'Apple TV",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: TypeOnTVIntent(),
            phrases: ["Écrire sur l'Apple TV avec \(.applicationName)"],
            shortTitle: "Écrire sur l'Apple TV",
            systemImageName: "keyboard"
        )
        AppShortcut(
            intent: SetTVPowerIntent(),
            phrases: ["\(\.$action) l'Apple TV avec \(.applicationName)"],
            shortTitle: "Veille / réveil",
            systemImageName: "power"
        )
        AppShortcut(
            intent: PressTVButtonIntent(),
            phrases: ["Appuyer sur \(\.$button) avec \(.applicationName)"],
            shortTitle: "Appuyer sur un bouton",
            systemImageName: "appletvremote.gen4"
        )
    }
}
