import AppKit

/// Right-click (or Control-click) on the menu bar icon shows a menu to open the remote,
/// the settings, check for updates or quit; a left click still opens the remote. SwiftUI's
/// MenuBarExtra has no such menu, so the click is caught on its status bar window.
@MainActor
final class StatusItemMenu: NSObject {
    static let shared = StatusItemMenu()

    private var monitor: Any?

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = event.window, window.className.contains("StatusBarWindow"),
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            self.showMenu(in: window)
            return nil
        }
    }

    private func showMenu(in window: NSWindow) {
        guard let view = window.contentView else { return }
        let menu = NSMenu()
        menu.addItem(item("Ouvrir la télécommande", #selector(openRemote)))
        menu.addItem(item("Réglages…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Rechercher les mises à jour…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quitter Remote", #selector(quit), key: "q"))

        // Keep the icon highlighted while the menu is open, like other menu bar items.
        let button = view as? NSButton ?? view.subviews.compactMap { $0 as? NSButton }.first
        button?.highlight(true)
        let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4)
        menu.popUp(positioning: nil, at: origin, in: view)
        button?.highlight(false)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openRemote() {
        MainWindow.show()
    }

    @objc private func openSettings() {
        MainWindow.openSettingsAction?()
        NSApp.activate()
    }

    @objc private func checkForUpdates() {
        Updater.shared.check(userInitiated: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
