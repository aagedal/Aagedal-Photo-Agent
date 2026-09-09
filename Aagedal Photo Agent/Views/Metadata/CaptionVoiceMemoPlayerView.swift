import SwiftUI

/// Playback is explicit and separate from Caption's metadata editing/flush path.
struct CaptionVoiceMemoPlayerView: View {
    let imageURL: URL?
    @State private var model = CaptionVoiceMemoPlaybackModel()
    @State private var refreshID = UUID()

    private struct Request: Equatable {
        let imageURL: URL?
        let refreshID: UUID
    }

    private var isPlaying: Bool {
        if case .available(let playback) = model.state { return playback.isPlaying }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Voice memo", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Refresh voice memo", systemImage: "arrow.clockwise") {
                    refreshID = UUID()
                }
                .labelStyle(.iconOnly)
                .help("Reload the saved voice-memo relationship for this photo")
                .accessibilityIdentifier("caption.voiceMemo.refresh")
                .disabled(imageURL == nil)
            }
            switch model.state {
            case .idle, .loading:
                Text("Checking voice memo…").foregroundStyle(.secondary)
            case .none:
                Text("No associated voice memo").foregroundStyle(.secondary)
            case .missing(let filename):
                Text("Voice memo missing: \(filename). Restore the WAV and refresh.")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case .unavailable(let message):
                Text(message).foregroundStyle(.orange)
            case .available(let playback):
                HStack(spacing: 10) {
                    Button(playback.isPlaying ? "Pause voice memo" : "Play voice memo",
                           systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        Task { await model.toggle() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isChangingPlayback)
                    .accessibilityIdentifier("caption.voiceMemo.playPause")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.association.memoURL.lastPathComponent)
                            .lineLimit(1)
                            .help(playback.association.memoURL.path)
                        Text("\(time(playback.position)) / \(time(playback.duration))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Voice memo playback time")
                            .accessibilityValue("\(time(playback.position)) of \(time(playback.duration))")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caption.voiceMemo")
        .task(id: Request(imageURL: imageURL, refreshID: refreshID)) {
            await model.load(imageURL)
        }
        .task(id: isPlaying) { await model.pollWhilePlaying() }
        .onDisappear { model.stop() }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(0, seconds), 86_400 * 365))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
