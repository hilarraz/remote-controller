import AppKit
import AppleTVKit
import SwiftUI
import UserNotifications

/// Like the keyboard notification on iPhone: when a text field gets focus on the Apple
/// TV while no remote is in front, posts a notification that can be answered to type
/// into the field, or clicked to open the remote with its keyboard.
@MainActor
final class TextInputNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TextInputNotifier()

    static let enabledKey = "notifyTextInput"

    private enum Identifier {
        static let category = "textInput"
        static let notification = "textInput"
        static let reply = "reply"
        static let paste = "paste"
    }

    private var center: UNUserNotificationCenter { .current() }
    /// Field the notification is for, so a field that closes quickly does not leave one behind.
    private var pendingSession: Data?

    func start() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Identifier.reply,
            title: "Écrire…",
            options: [],
            textInputButtonTitle: "Envoyer",
            textInputPlaceholder: "Texte pour l'Apple TV"
        )
        let paste = UNNotificationAction(identifier: Identifier.paste, title: "Coller le presse-papiers")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Identifier.category, actions: [reply, paste], intentIdentifiers: []),
        ])
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The remote now shows the keyboard itself.
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func textInputStarted(_ session: TextInputSession, deviceName: String) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey, default: true), !RemoteWindows.isOnScreen else { return }
        pendingSession = session.sessionUUID

        let content = UNMutableNotificationContent()
        content.title = "\(deviceName) attend du texte"
        let field = [session.title, session.placeholder].compactMap { $0 }.filter { !$0.isEmpty }
        content.body = field.isEmpty ? "Répondez pour écrire dans le champ actif." : field.joined(separator: " · ")
        content.categoryIdentifier = Identifier.category
        let request = UNNotificationRequest(identifier: Identifier.notification, content: content, trigger: nil)

        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true,
                  pendingSession == session.sessionUUID else { return }
            try? await center.add(request)
        }
    }

    func dismiss() {
        pendingSession = nil
        center.removeDeliveredNotifications(withIdentifiers: [Identifier.notification])
    }

    private func handle(action: String, text: String?) {
        let model = RemoteModel.shared
        switch action {
        case Identifier.reply:
            if let text, !text.isEmpty { model.insertText(text) }
        case Identifier.paste:
            model.pasteClipboard()
        case UNNotificationDefaultActionIdentifier:
            MainWindow.show()
            NotificationCenter.default.post(name: .showKeyboardRequested, object: nil)
        default:
            break
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in self.handle(action: action, text: text) }
        completionHandler()
    }
}

/// Opens the main window (or the settings) from code without a SwiftUI environment:
/// notifications, Shortcuts, the menu bar icon's menu. Remote views hand over their
/// environment actions when they appear.
@MainActor
enum MainWindow {
    static var openAction: OpenWindowAction?
    static var openSettingsAction: OpenSettingsAction?

    static func show() {
        if let openAction {
            openAction(id: "remote")
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("remote") == true }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}
