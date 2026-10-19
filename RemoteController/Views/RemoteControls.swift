import AppleTVKit
import SwiftUI

/// A round remote button that reports presses and releases separately, so holding it
/// behaves like holding the physical button (e.g. holding TV opens Control Center).
struct RemoteKey: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 54
    var tint: Color?
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(tint ?? .primary)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(duration: 0.18), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onRelease()
                    }
            )
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onPress()
                onRelease()
            }
    }
}

extension RemoteKey {
    /// A key mirroring an Apple TV button, including press-and-hold.
    init(_ command: HIDCommand, systemImage: String, label: String, size: CGFloat = 54, model: RemoteModel) {
        self.init(
            systemImage: systemImage, label: label, size: size,
            onPress: { model.button(command, pressed: true) },
            onRelease: { model.button(command, pressed: false) }
        )
    }

    /// A key performing a single action on release.
    init(systemImage: String, label: String, size: CGFloat = 54, tint: Color? = nil, action: @escaping () -> Void) {
        self.init(systemImage: systemImage, label: label, size: size, tint: tint, onPress: {}, onRelease: action)
    }
}

/// Volume up/down in a single capsule, like the Siri Remote.
struct VolumeRocker: View {
    let model: RemoteModel
    var width: CGFloat = 54
    var halfHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 0) {
            half(.volumeUp, systemImage: "plus", label: "Volume +")
            Divider().frame(width: width * 0.5).opacity(0.5)
            half(.volumeDown, systemImage: "minus", label: "Volume −")
        }
        .frame(width: width)
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
    }

    private func half(_ command: HIDCommand, systemImage: String, label: String) -> some View {
        PressableArea(
            onPress: { model.button(command, pressed: true) },
            onRelease: { model.button(command, pressed: false) }
        ) { isPressed in
            Image(systemName: systemImage)
                .font(.system(size: width * 0.32, weight: .bold))
                .frame(width: width, height: halfHeight)
                .background(isPressed ? Color.primary.opacity(0.12) : .clear)
                .contentShape(Rectangle())
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Generic press/release gesture wrapper.
struct PressableArea<Content: View>: View {
    let onPress: () -> Void
    let onRelease: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var isPressed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content(isPressed)
            .opacity(isEnabled ? 1 : 0.45)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onRelease()
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onPress()
                onRelease()
            }
    }
}
