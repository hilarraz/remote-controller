import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut registered through Carbon, which unlike event taps
/// needs no accessibility permission.
final class GlobalHotKey {
    enum Preset: String, CaseIterable, Identifiable {
        case controlOptionV
        case optionCommandV
        case controlCommandV

        var id: String { rawValue }

        var title: String {
            switch self {
            case .controlOptionV: return "⌃⌥V"
            case .optionCommandV: return "⌥⌘V (remplace « Déplacer » du Finder)"
            case .controlCommandV: return "⌃⌘V"
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .controlOptionV: return UInt32(controlKey | optionKey)
            case .optionCommandV: return UInt32(optionKey | cmdKey)
            case .controlCommandV: return UInt32(controlKey | cmdKey)
            }
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(preset: Preset, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
        guard handlerStatus == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x524D_5443), id: 1) // 'RMTC'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V), preset.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
