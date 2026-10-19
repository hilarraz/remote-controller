import AppleTVKit
import SwiftUI

/// Title, artwork and progress of what is playing on the Apple TV.
struct NowPlayingCard: View {
    let item: NowPlayingModel.Item
    let model: RemoteModel

    /// Position under the pointer while dragging the progress bar.
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let appName = item.appName, appName != item.title {
                        Text(appName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                transportControls
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let duration = item.duration, let elapsed = item.elapsed(at: context.date) {
                    let position = scrubPosition ?? elapsed
                    VStack(spacing: 2) {
                        ScrubBar(value: elapsed, total: duration, canSeek: item.canSeek, dragValue: $scrubPosition) {
                            model.nowPlaying.seek(to: $0)
                        }
                        HStack {
                            Text(Self.format(position))
                            Spacer()
                            Text("-" + Self.format(max(duration - position, 0)))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lecture en cours")
    }

    @ViewBuilder private var transportControls: some View {
        let controls = model.mediaControls
        HStack(spacing: 2) {
            if controls.contains(.previousTrack) {
                Button("Précédent", systemImage: "backward.fill") {
                    model.mediaCommand(.previousTrack)
                }
            }
            Button(item.isPlaying ? "Pause" : "Lecture", systemImage: item.isPlaying ? "pause.fill" : "play.fill") {
                model.tap(.playPause)
            }
            if controls.contains(.nextTrack) {
                Button("Suivant", systemImage: "forward.fill") {
                    model.mediaCommand(.nextTrack)
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
    }

    @ViewBuilder private var artwork: some View {
        if let image = item.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note.tv")
                        .foregroundStyle(.secondary)
                }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Thin progress bar; when the app allows it, clicking or dragging jumps to a position.
private struct ScrubBar: View {
    let value: Double
    let total: Double
    let canSeek: Bool
    @Binding var dragValue: Double?
    var onSeek: (Double) -> Void

    @State private var isHovering = false

    private var isActive: Bool { canSeek && (isHovering || dragValue != nil) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = min(max((dragValue ?? value) / total, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: width * fraction)
            }
            .frame(height: isActive ? 7 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in dragValue = position(at: drag.location.x, width: width) }
                    .onEnded { drag in
                        onSeek(position(at: drag.location.x, width: width))
                        dragValue = nil
                    },
                isEnabled: canSeek
            )
        }
        .frame(height: 12)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isActive)
        .help(canSeek ? "Cliquer ou glisser pour changer de position" : "")
        .accessibilityElement()
        .accessibilityLabel("Position de lecture")
        .accessibilityValue(NowPlayingCard.format(value))
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            switch direction {
            case .increment: onSeek(min(value + 10, total))
            case .decrement: onSeek(max(value - 10, 0))
            @unknown default: break
            }
        }
    }

    private func position(at x: Double, width: Double) -> Double {
        guard width > 0 else { return value }
        return min(max(x / width, 0), 1) * total
    }
}
