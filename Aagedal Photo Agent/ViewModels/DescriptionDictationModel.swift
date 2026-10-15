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
    @ObservationIgnored private let storage: DescriptionDictationStorage
    @ObservationIgnored private let requestMicrophoneAccess: @Sendable () async -> Bool
    @ObservationIgnored private var availabilityRequest = UUID()
    @ObservationIgnored private let checkAvailability: (@Sendable (Locale) async -> VoiceMemoTranscriptionAvailability)?
    @ObservationIgnored private let installLanguage: (@Sendable (Locale) async throws -> VoiceMemoTranscriptionAvailability)?

    init(checkAvailability: (@Sendable (Locale) async -> VoiceMemoTranscriptionAvailability)? = nil,
         installLanguage: (@Sendable (Locale) async throws -> VoiceMemoTranscriptionAvailability)? = nil,
         storage: DescriptionDictationStorage = DescriptionDictationStorage(),
         requestMicrophoneAccess: @escaping @Sendable () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.checkAvailability = checkAvailability
        self.installLanguage = installLanguage
        self.storage = storage
        self.requestMicrophoneAccess = requestMicrophoneAccess
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
        let request = UUID()
        availabilityRequest = request
        let requestedLocale = localeIdentifier
        isWorking = true
        errorMessage = nil
        task = Task {
            defer { isWorking = false; task = nil }
            do {
                let locale = Locale(identifier: requestedLocale)
                let result: VoiceMemoTranscriptionAvailability
                if let installLanguage { result = try await installLanguage(locale) }
                else { result = try await speech.downloadLanguage(locale) }
                guard !Task.isCancelled, availabilityRequest == request,
                      localeIdentifier == requestedLocale else { return }
                availability = result
            }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled, availabilityRequest == request,
                      localeIdentifier == requestedLocale else { return }
                errorMessage = error.localizedDescription
            }
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
                guard await requestMicrophoneAccess() else {
                    throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey:
                        "Microphone access is disabled. Enable it for Photo Agent in System Settings → Privacy & Security → Microphone."])
                }
                try Task.checkCancellation()
                let directory = try await storage.createWorkspace()
                folder = directory
                try Task.checkCancellation()
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
            } catch is CancellationError { await cleanup() }
            catch { errorMessage = error.localizedDescription; await cleanup() }
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
            defer { isWorking = false; task = nil }
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
                    let input = try await storage.makeInput(audioURL)
                    transcript = try await provider.transcribe(audio: input).text
                }
                try Task.checkCancellation()
            } catch is CancellationError { transcript = "" }
            catch { errorMessage = error.localizedDescription }
            await cleanup()
        }
    }

    func cancel() {
        availabilityRequest = UUID()
        task?.cancel()
        recorder?.stop()
        recorder = nil
        isRecording = false
        // A transcription may still be reading the file. Its task removes it after teardown.
        if !isWorking, folder != nil {
            isWorking = true
            task = Task {
                await cleanup()
                isWorking = false
                task = nil
            }
        }
        transcript = ""
    }

    func waitForCurrentWork() async { await task?.value }

    private func cleanup() async {
        recorder?.stop()
        recorder = nil
        isRecording = false
        let directory = folder
        folder = nil
        if let directory { await storage.removeWorkspace(directory) }
    }
}

/// Temporary microphone bytes stay alive until recording/recognition has drained.
/// Blocking creation, streaming hashing and teardown use the original task on a
/// retained Dispatch executor, preserving cancellation without blocking the UI.
actor DescriptionDictationStorage {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    enum Operation: Sendable { case create, created, read, remove }
    private let beforeOperation: @Sendable (Operation) -> Void
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory,
         queue: DispatchSerialQueue = DispatchSerialQueue(label: "com.aagedal.photo-agent.dictation-storage", qos: .userInitiated),
         beforeOperation: @escaping @Sendable (Operation) -> Void = { _ in }) {
        self.temporaryRoot = temporaryRoot
        self.queue = queue
        self.beforeOperation = beforeOperation
    }

    func createWorkspace() throws -> URL {
        try Task.checkCancellation()
        beforeOperation(.create)
        try Task.checkCancellation()
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        beforeOperation(.created)
        // Return ownership even if cancelled during creation. The model installs
        // it before checking cancellation and drains cleanup before releasing busy.
        return directory
    }

    func makeInput(_ audioURL: URL) throws -> FFmpegWhisperJobInput {
        try Task.checkCancellation()
        beforeOperation(.read)
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: audioURL)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
            count += Int64(bytes.count)
        }
        try Task.checkCancellation()
        return .init(url: audioURL, byteCount: count,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Teardown deliberately runs even when its owning task was cancelled.
    func removeWorkspace(_ directory: URL) {
        beforeOperation(.remove)
        try? FileManager.default.removeItem(at: directory)
    }
}
