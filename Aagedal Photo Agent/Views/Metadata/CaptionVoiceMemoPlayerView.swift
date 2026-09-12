import SwiftUI
import UniformTypeIdentifiers

/// Playback is explicit and separate from Caption's metadata editing/flush path.
struct CaptionVoiceMemoPlayerView: View {
    let imageURL: URL?
    @State private var model = CaptionVoiceMemoPlaybackModel()
    @State private var recoveryModel = CaptionVoiceMemoRecoveryModel()
    @State private var refreshID = UUID()
    @State private var isSelectingRecoveryMemo = false
    @State private var recoveryImageURL: URL?

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
                VStack(alignment: .leading, spacing: 5) {
                    Text("Voice memo missing: \(filename).")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Locate or replace voice memo…", systemImage: "waveform.badge.plus") {
                        recoveryImageURL = imageURL
                        isSelectingRecoveryMemo = true
                    }
                    .disabled(recoveryModel.isWorking || imageURL == nil)
                    .accessibilityIdentifier("caption.voiceMemo.recover")
                }
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
            if recoveryModel.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Verifying selected WAV…").foregroundStyle(.secondary)
                }
            } else if let error = recoveryModel.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
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
        .fileImporter(
            isPresented: $isSelectingRecoveryMemo,
            allowedContentTypes: [UTType(filenameExtension: "wav") ?? .audio],
            allowsMultipleSelection: false
        ) { result in
            guard let requestedImageURL = recoveryImageURL else { return }
            recoveryImageURL = nil
            switch result {
            case .success(let urls):
                guard let candidate = urls.first else { return }
                Task {
                    if await recoveryModel.select(candidateURL: candidate, for: requestedImageURL) {
                        refreshID = UUID()
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    recoveryModel.reportPickerError(error)
                }
            }
        }
        .alert(
            "Use replacement voice memo?",
            isPresented: Binding(
                get: { recoveryModel.pendingReplacement != nil },
                set: { if !$0 { recoveryModel.dismissReplacement() } }
            )
        ) {
            Button("Cancel", role: .cancel) { recoveryModel.dismissReplacement() }
            Button("Use Replacement", role: .destructive) {
                Task {
                    if await recoveryModel.confirmReplacement() {
                        refreshID = UUID()
                    }
                }
            }
        } message: {
            if case .explicitReplacement(let hadIdentity) = recoveryModel.pendingReplacement?.kind {
                Text(hadIdentity
                     ? "The current photo or selected WAV does not match the previously recorded bytes. Using it will create a new association and revoke any transcript approval tied to the old audio."
                     : "This older relationship has no historical content identity, so the selected WAV cannot be proven to be the original. Using it will record a new replacement association and revoke any audio-bound approval.")
            }
        }
        .onChange(of: imageURL) {
            recoveryModel.cancel()
            isSelectingRecoveryMemo = false
            recoveryImageURL = nil
        }
        .onDisappear {
            model.stop()
            recoveryModel.cancel()
            recoveryImageURL = nil
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(0, seconds), 86_400 * 365))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
