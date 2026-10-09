import AVFoundation
import CryptoKit
import Foundation
import Observation

/// Microphone audio is temporary and never becomes a photo sidecar. The transcript is a
/// reviewable draft applied by the standalone description transcription dialog.
@MainActor @Observable
final class DescriptionDictationModel {
    private(set) var isRecording = false
    private(set) var isWorking = false
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private(set) var availability: VoiceMemoTranscriptionAvailability?
    var localeIdentifier = Locale.current.identifier
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let speech = VoiceMemoTranscriptionService()
    @ObservationIgnored private var availabilityRequest = UUID()
    @ObservationIgnored private let checkAvailability: (@Sendable (Locale) async -> VoiceMemoTranscriptionAvailability)?

    init(checkAvailability: (@Sendable (Locale) async -> VoiceMemoTranscriptionAvailability)? = nil) {
        self.checkAvailability = checkAvailability
    }

    func refresh() async {
        let request = UUID()
        availabilityRequest = request
        let requestedLocale = localeIdentifier
        let locale = Locale(identifier: requestedLocale)
        let result: VoiceMemoTranscriptionAvailability
        if let checkAvailability { result = await checkAvailability(locale) }
        else { result = await speech.availability(preferredLocale: locale) }
        guard !Task.isCancelled, availabilityRequest == request, localeIdentifier == requestedLocale else { return }
        availability = result
        if let locale = result.selectedLocale { localeIdentifier = locale.identifier }
    }

    func downloadLanguage() {
        guard !isWorking, !isRecording else { return }
        availabilityRequest = UUID()
        isWorking = true
        errorMessage = nil
        task = Task {
            defer { isWorking = false; task = nil }
            do { availability = try await speech.downloadLanguage(Locale(identifier: localeIdentifier)) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func start() {
        guard !isWorking, !isRecording else { return }
        errorMessage = nil
        transcript = ""
        isWorking = true
        task = Task {
            defer { isWorking = false; task = nil }
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey:
                        "Microphone access is disabled. Enable it for Photo Agent in System Settings → Privacy & Security → Microphone."])
                }
                try Task.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                folder = directory
                let recording = try AVAudioRecorder(url: directory.appendingPathComponent("dictation.wav"), settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ])
                guard recording.prepareToRecord(), recording.record() else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not start microphone recording."])
                }
                recorder = recording
                isRecording = true
            } catch is CancellationError { cleanup() }
            catch { errorMessage = error.localizedDescription; cleanup() }
        }
    }

    func stopAndTranscribe() {
        guard isRecording, let recorder else { return }
        recorder.stop()
        let audioURL = recorder.url
        self.recorder = nil
        isRecording = false
        isWorking = true
        errorMessage = nil
        let setup = FFmpegWhisperSetupModel.shared
        let choice = setup.choice
        let provider = choice == .whisper
            ? ManagedWhisperSetupModel.shared.provider(language: setup.language, useGPU: setup.useGPU, translate: setup.translate)
            : setup.provider()
        let locale = Locale(identifier: localeIdentifier)
        task = Task {
            defer { cleanup(); isWorking = false; task = nil }
            do {
                if choice == .appleSpeech {
                    let runtime = VoiceMemoTranscriptionRuntime.appleOnDevice
                    guard await runtime.isAvailable() else { throw VoiceMemoTranscriptionError.unavailable }
                    guard let resolved = await runtime.resolveLocale(locale) else { throw VoiceMemoTranscriptionError.unsupportedLanguage }
                    guard await runtime.assetStatus(resolved) == .installed else { throw VoiceMemoTranscriptionError.languageDownloadRequired }
                    let session = try await runtime.makeRecognitionSession(audioURL, resolved)
                    transcript = try await VoiceMemoRecognitionPipeline.transcribe(session: session)
                } else {
                    guard let provider else {
                        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Set up the selected Whisper provider in Transcription Settings first."])
                    }
                    guard setup.beginTranscription() else { throw DescriptionAssistantError.busy }
                    defer { setup.finishTranscription() }
                    let input = try await Task.detached {
                        let data = try Data(contentsOf: audioURL)
                        return FFmpegWhisperJobInput(url: audioURL, byteCount: Int64(data.count),
                            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                    }.value
                    transcript = try await provider.transcribe(audio: input).text
                }
                try Task.checkCancellation()
            } catch is CancellationError { transcript = "" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func cancel() {
        availabilityRequest = UUID()
        task?.cancel()
        recorder?.stop()
        recorder = nil
        isRecording = false
        // A transcription may still be reading the file. Its task removes it after teardown.
        if !isWorking { cleanup() }
        transcript = ""
    }

    private func cleanup() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}
