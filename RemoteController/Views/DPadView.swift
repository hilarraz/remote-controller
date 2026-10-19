import AppleTVKit
import SwiftUI

/// Directional pad alternative to the touch surface: four arrows around a select button.
struct DPadView: View {
    let model: RemoteModel

    @State private var pressed: HIDCommand?

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Circle()
                    .fill(.clear)
                    .glassEffect(.regular, in: Circle())
                    .frame(width: side, height: side)

                ForEach(Self.arrows, id: \.command.rawValue) { arrow in
                    Image(systemName: arrow.symbol)
                        .font(.system(size: side * 0.08, weight: .bold))
                        .foregroundStyle(pressed == arrow.command ? .primary : .secondary)
                        .offset(x: arrow.offset.width * side * 0.36, y: arrow.offset.height * side * 0.36)
                }

                Circle()
                    .fill(pressed == .select ? Color.primary.opacity(0.18) : Color.primary.opacity(0.06))
                    .frame(width: side * 0.4, height: side * 0.4)
                    .overlay(Text("OK").font(.headline).foregroundStyle(.secondary))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard pressed == nil else { return }
                        let command = Self.command(at: value.startLocation, center: center, radius: side / 2)
                        guard let command else { return }
                        pressed = command
                        model.button(command, pressed: true)
                    }
                    .onEnded { _ in
                        if let command = pressed { model.button(command, pressed: false) }
                        pressed = nil
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pavé directionnel")
        .accessibilityAction(named: "Haut") { model.tap(.up) }
        .accessibilityAction(named: "Bas") { model.tap(.down) }
        .accessibilityAction(named: "Gauche") { model.tap(.left) }
        .accessibilityAction(named: "Droite") { model.tap(.right) }
        .accessibilityAction(named: "Sélectionner") { model.tap(.select) }
    }

    private struct Arrow {
        let command: HIDCommand
        let symbol: String
        let offset: CGSize
    }

    private static let arrows = [
        Arrow(command: .up, symbol: "chevron.up", offset: CGSize(width: 0, height: -1)),
        Arrow(command: .down, symbol: "chevron.down", offset: CGSize(width: 0, height: 1)),
        Arrow(command: .left, symbol: "chevron.left", offset: CGSize(width: -1, height: 0)),
        Arrow(command: .right, symbol: "chevron.right", offset: CGSize(width: 1, height: 0)),
    ]

    private static func command(at point: CGPoint, center: CGPoint, radius: CGFloat) -> HIDCommand? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance <= radius else { return nil }
        if distance < radius * 0.4 { return .select }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }
}
