import AppleTVKit
import SwiftUI

/// Title, artwork and progress of what is playing on the Apple TV.
struct NowPlayingCard: View {
    let item: NowPlayingModel.Item
    let model: RemoteModel

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
                    VStack(spacing: 2) {
                        ProgressView(value: min(elapsed, duration), total: duration)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                        HStack {
                            Text(Self.format(elapsed))
                            Spacer()
                            Text("-" + Self.format(max(duration - elapsed, 0)))
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
