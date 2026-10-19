import AppKit
import AppleTVKit
import Carbon.HIToolbox

/// Turns Mac keystrokes into remote buttons while one of our windows is key and no
/// text field is being edited.
@MainActor
final class KeyboardController {
    private var monitor: Any?
    /// Buttons currently held down, by key code, so releases match presses.
    private var heldKeys: [UInt16: HIDCommand] = [:]
    private let model: RemoteModel

    init(model: RemoteModel) {
        self.model = model
    }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func isEditingText(_ window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, RemoteWindows.contains(window) else { return false }

        if isEditingText(window) {
            // While typing into the TV field, up/down still navigate (e.g. from a search
            // field to its results) and Escape hands the arrow keys back to the remote.
            guard event.type == .keyDown else { return false }
            switch Int(event.keyCode) {
            case kVK_UpArrow: model.tap(.up)
            case kVK_DownArrow: model.tap(.down)
            case kVK_Escape: window.makeFirstResponder(nil)
            default: return false
            }
            return true
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if event.type == .keyUp {
            guard let command = heldKeys.removeValue(forKey: event.keyCode) else { return false }
            model.button(command, pressed: false)
            return true
        }

        if modifiers == .command, event.charactersIgnoringModifiers == "v" {
            model.pasteClipboard()
            return true
        }
        guard modifiers.subtracting(.shift).isEmpty else { return false }

        if let command = Self.heldCommand(for: event) {
            // Key repeat is left to the Apple TV, which handles a held button itself.
            if !event.isARepeat {
                heldKeys[event.keyCode] = command
                model.button(command, pressed: true)
            }
            return true
        }

        let actions: [String: () -> Void] = [
            " ": { self.model.tap(.playPause) },
            "j": { self.model.skip(-10) },
            "l": { self.model.skip(10) },
            "/": { self.model.openSearch() },
            "k": { NotificationCenter.default.post(name: .showKeyboardRequested, object: nil) },
            "a": { NotificationCenter.default.post(name: .showAppsRequested, object: nil) },
        ]
        guard let key = event.charactersIgnoringModifiers, let action = actions[key] else { return false }
        // Only skipping makes sense on key repeat.
        if !event.isARepeat || key == "j" || key == "l" { action() }
        return true
    }

    private static func heldCommand(for event: NSEvent) -> HIDCommand? {
        switch Int(event.keyCode) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_Return, kVK_ANSI_KeypadEnter: return .select
        case kVK_Escape, kVK_Delete: return .menu
        case kVK_Home: return .home
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "h": return .home
        case "+", "=": return .volumeUp
        case "-": return .volumeDown
        default: return nil
        }
    }
}

/// Windows hosting a remote, which receive keyboard control.
@MainActor
enum RemoteWindows {
    private static var windows: [WeakWindow] = []

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    static func register(_ window: NSWindow) {
        windows.removeAll { $0.window == nil }
        if !contains(window) { windows.append(WeakWindow(window: window)) }
    }

    static func contains(_ window: NSWindow) -> Bool {
        windows.contains { $0.window === window }
    }

    /// Whether the user is looking at a remote: the app is active and one is on screen.
    static var isOnScreen: Bool {
        NSApp.isActive && windows.contains { $0.window?.occlusionState.contains(.visible) == true }
    }
}

extension Notification.Name {
    static let showKeyboardRequested = Notification.Name("RemoteShowKeyboardRequested")
    static let showAppsRequested = Notification.Name("RemoteShowAppsRequested")
}
