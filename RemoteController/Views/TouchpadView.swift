import AppKit
import AppleTVKit
import SwiftUI

/// The touch surface: drag with the mouse or swipe with two fingers on a trackpad to
/// navigate, click to select, click and hold for a long press.
struct TouchpadView: View {
    let model: RemoteModel
    @State private var isTouching = false

    var body: some View {
        TouchSurface(
            onTouch: { x, y, phase in
                model.touch(x: x, y: y, phase: phase)
                isTouching = phase != .release
            },
            onSelect: { pressed in model.button(.select, pressed: pressed) },
            onArrow: { command in model.tap(command) }
        )
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .overlay {
            VStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 22, weight: .light))
                Text("Glissez pour naviguer\nCliquez pour sélectionner")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.tertiary)
            .opacity(isTouching ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: isTouching)
            .allowsHitTesting(false)
        }
        .accessibilityElement()
        .accessibilityLabel("Pavé tactile")
        .accessibilityHint("Utilisez les flèches du clavier pour naviguer")
    }
}

private struct TouchSurface: NSViewRepresentable {
    let onTouch: (Double, Double, TouchPhase) -> Void
    let onSelect: (Bool) -> Void
    let onArrow: (HIDCommand) -> Void

    func makeNSView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ view: TouchSurfaceView, context: Context) {
        update(view)
    }

    private func update(_ view: TouchSurfaceView) {
        view.onTouch = onTouch
        view.onSelect = onSelect
        view.onArrow = onArrow
    }
}

final class TouchSurfaceView: NSView {
    var onTouch: (Double, Double, TouchPhase) -> Void = { _, _, _ in }
    var onSelect: (Bool) -> Void = { _ in }
    var onArrow: (HIDCommand) -> Void = { _ in }

    private static let size = CompanionClient.touchpadSize
    private static let dragThreshold: CGFloat = 5
    private static let longPressDelay: TimeInterval = 0.5

    private var mouseStart: CGPoint?
    private var isDragging = false
    private var isHolding = false
    private var holdTimer: Timer?
    private var lastTouchTime: TimeInterval = 0

    private var scrollPosition = CGPoint(x: size / 2, y: size / 2)
    private var isScrolling = false
    private var wheelAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func touchPoint(_ event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(location.x / max(bounds.width, 1), 0), 1) * Self.size,
            y: min(max(location.y / max(bounds.height, 1), 0), 1) * Self.size
        )
    }

    // MARK: Mouse: drag to swipe, click to select

    override func mouseDown(with event: NSEvent) {
        mouseStart = convert(event.locationInWindow, from: nil)
        isDragging = false
        isHolding = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDragging else { return }
                self.isHolding = true
                self.onSelect(true)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStart, !isHolding else { return }
        let location = convert(event.locationInWindow, from: nil)
        if !isDragging, hypot(location.x - start.x, location.y - start.y) > Self.dragThreshold {
            isDragging = true
            holdTimer?.invalidate()
            onTouch(
                min(max(start.x / max(bounds.width, 1), 0), 1) * Self.size,
                min(max(start.y / max(bounds.height, 1), 0), 1) * Self.size,
                .press
            )
        }
        guard isDragging else { return }
        // Roughly 60 events per second is what the iOS remote sends.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTouchTime >= 0.014 else { return }
        lastTouchTime = now
        let point = touchPoint(event)
        onTouch(point.x, point.y, .hold)
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if isDragging {
            let point = touchPoint(event)
            onTouch(point.x, point.y, .release)
        } else if isHolding {
            onSelect(false)
        } else if mouseStart != nil {
            onSelect(true)
            onSelect(false)
        }
        mouseStart = nil
        isDragging = false
        isHolding = false
    }

    // MARK: Trackpad: two-finger swipes become touches; mouse wheels become arrows

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.phase != [] || event.momentumPhase != [] else {
            scrollWithWheel(event)
            return
        }
        // Inertia would keep the focus moving after the fingers left the trackpad.
        guard event.momentumPhase == [] else { return }

        if event.phase.contains(.began) {
            scrollPosition = CGPoint(x: Self.size / 2, y: Self.size / 2)
            isScrolling = true
            onTouch(scrollPosition.x, scrollPosition.y, .press)
        } else if event.phase.contains(.changed), isScrolling {
            // Follow the fingers whatever the "natural scrolling" setting.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let gain: CGFloat = 2.5
            scrollPosition.x = min(max(scrollPosition.x + sign * event.scrollingDeltaX * gain, 0), Self.size)
            scrollPosition.y = min(max(scrollPosition.y + sign * event.scrollingDeltaY * gain, 0), Self.size)
            onTouch(scrollPosition.x, scrollPosition.y, .hold)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled), isScrolling {
            isScrolling = false
            onTouch(scrollPosition.x, scrollPosition.y, .release)
        }
    }

    private func scrollWithWheel(_ event: NSEvent) {
        wheelAccumulator += event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        while abs(wheelAccumulator) >= step {
            onArrow(wheelAccumulator > 0 ? .up : .down)
            wheelAccumulator -= wheelAccumulator > 0 ? step : -step
        }
    }
}
