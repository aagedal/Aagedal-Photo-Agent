import SwiftUI
import Combine
import AVKit
import ImageIO
import UniformTypeIdentifiers

struct ExtractionVideo: Identifiable {
    let id = UUID()
    let url: URL
}

/// A separate workspace keeps movie playback out of the photo editing pipeline.
struct VideoStillExtractionView: View {
    let url: URL
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var frames: [CMTime] = []
    @State private var timecode: VideoTimecode?
    @State private var duration = 0.0
    @State private var position = 0.0
    @State private var scrubbing = false
    @State private var isPlaying = false
    @State private var pendingMarkers = 0
    private let playbackClock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var format = "jpg"
    @State private var saving = false
    @State private var message: String?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extract still(s) from video").font(.title2)
            Text(url.lastPathComponent).foregroundStyle(.secondary)
            VideoStillPlayerSurface(player: player).frame(minWidth: 720, minHeight: 360)
            VideoStillTimeline(position: $position, duration: duration, markers: frames) { seconds, ended in
                scrubbing = true
                player.pause()
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    if ended && finished { Task { @MainActor in scrubbing = false } }
                }
            }.disabled(duration <= 0 || saving)
            HStack {
                Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                    if player.rate > 0 { player.pause(); isPlaying = false }
                    else { player.play(); isPlaying = true }
                }.keyboardShortcut(.space, modifiers: [])
                Button("Previous frame", systemImage: "backward.end") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next frame", systemImage: "forward.end") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Add marker", systemImage: "bookmark") { markCurrentFrame() }
                    .keyboardShortcut("m", modifiers: [])
                    .help("Press M to mark the current frame without stopping playback")
                Spacer()
                Text(timecode?.label(at: CMTime(seconds: position, preferredTimescale: 60000)) ?? "--:--:--:--")
                    .monospacedDigit()
                Text("\(frames.count) marker(s)")
                if pendingMarkers > 0 { ProgressView().controlSize(.small) }
            }.disabled(duration <= 0 || saving)
            Text(timecode?.hasSourceTimecode == true ? "Source timecode" : "Relative timecode (starts at 00:00:00:00)")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, time in
                        HStack(spacing: 4) {
                            Button(timecode?.label(at: time) ?? "--:--:--:--") { seek(time) }
                                .monospacedDigit().help("Go to this marker")
                            Button { frames.remove(at: index) } label: { Image(systemName: "xmark") }
                                .help("Remove this marker")
                        }

                    }
                }
            }.frame(height: 30).disabled(saving)
            if format == "jxl" {
                Text("16-bit lossless compression preserves source precision and HDR. 8-bit footage retains its original detail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Picker("Format", selection: $format) {
                    Text("JPEG").tag("jpg")
                    Text("TIFF").tag("tiff")
                    Text("JPEG XL (16-bit lossless)").tag("jxl")
                }.frame(width: 260).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.disabled(saving)
                Button("Extract marked frames…") { chooseDestination() }
                    .buttonStyle(.borderedProminent)
                    .disabled(frames.isEmpty || saving || loadFailed || pendingMarkers > 0)
            }
        }
        .padding(20)
        .task {
            do {
                let asset = AVURLAsset(url: url)
                let loadedDuration = try await asset.load(.duration)
                guard loadedDuration.seconds.isFinite, loadedDuration.seconds > 0,
                      let _ = try await asset.loadTracks(withMediaType: .video).first else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                timecode = try await VideoTimecode.load(url: url)
                duration = loadedDuration.seconds
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            } catch { loadFailed = true; message = "Cannot open this video: \(error.localizedDescription)" }
        }
        .onReceive(playbackClock) { _ in
            isPlaying = player.rate > 0
            let seconds = player.currentTime().seconds
            if !scrubbing, seconds.isFinite { position = min(max(seconds, 0), duration) }
        }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        .interactiveDismissDisabled(saving)
    }

    private func markCurrentFrame() {
        // Deliberately only read the transport: M must never pause or seek during playback.
        guard duration > 0, !saving else { return }
        let time = player.currentTime()
        guard time.seconds.isFinite, time.seconds >= 0, time.seconds < duration else { return }
        pendingMarkers += 1
        Task {
            defer { pendingMarkers -= 1 }
            do {
                // Resolve the actual presentation timestamp independently of the player.
                // This also keeps markers accurate for variable-frame-rate footage.
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.maximumSize = CGSize(width: 64, height: 64)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let result = try await generator.image(at: time)
                if !frames.contains(where: { CMTimeCompare($0, result.actualTime) == 0 }) {
                    frames.append(result.actualTime)
                    frames.sort { CMTimeCompare($0, $1) < 0 }
                }
            } catch { message = "Cannot mark this frame: \(error.localizedDescription)" }
        }
    }

    private func seek(_ time: CMTime) {
        player.pause()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func step(_ direction: Int) {
        player.pause()
        player.currentItem?.step(byCount: direction)
        // AVPlayerItem performs actual frame stepping, including variable-rate clips.
    }

    private func chooseDestination() {
        player.pause()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Save stills here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        saving = true
        message = nil
        let selectedFrames = frames
        let selectedFormat = format
        guard let timecode else { saving = false; return }
        Task {
            var saved = 0
            do {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                // SDR output gives HDR footage a display-referred still suitable for the photo workflow.
                generator.dynamicRangePolicy = .forceSDR
                for time in selectedFrames {
                    let result = try await generator.image(at: time)
                    let stem = url.deletingPathExtension().lastPathComponent
                    let frameTimecode = timecode.label(at: result.actualTime)
                    let timestamp = frameTimecode.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ";", with: "-")
                    var output = destination.appendingPathComponent("\(stem)_\(timestamp).\(selectedFormat)")
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: output.path) {
                        output = destination.appendingPathComponent("\(stem)_\(timestamp)_\(suffix).\(selectedFormat)")
                        suffix += 1
                    }
                    let sourceName = url.lastPathComponent
                    let outputURL = output
                    let description = "Still from \(sourceName) at timecode \(frameTimecode) (\(timecode.hasSourceTimecode ? "source" : "relative"))"
                    if selectedFormat == "jxl" {
                        try await VideoJXLStillExporter.export(source: url, seconds: result.actualTime.seconds,
                                                               destination: outputURL, description: description)
                    } else {
                        try await Task.detached(priority: .userInitiated) {
                            let type = selectedFormat == "jpg" ? UTType.jpeg : UTType.tiff
                            let data = NSMutableData()
                            guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                            let properties: [CFString: Any] = [
                                kCGImageDestinationLossyCompressionQuality: 0.95,
                                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description],
                                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: description]
                            ]
                            CGImageDestinationAddImage(writer, result.image, properties as CFDictionary)
                            guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
                            try (data as Data).write(to: outputURL, options: .withoutOverwriting)
                        }.value
                    }
                    saved += 1
                }
                frames.removeAll()
                message = "Saved \(saved) still(s) to \(destination.path)."
            } catch {
                frames.removeFirst(saved)
                message = "Saved \(saved) of \(selectedFrames.count) still(s). \(error.localizedDescription)"
            }
            if saved > 0 { onSaved() }
            saving = false
        }
    }
}
