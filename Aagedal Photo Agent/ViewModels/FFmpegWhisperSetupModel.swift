import Foundation
import Observation

nonisolated enum VoiceMemoTranscriptionProviderChoice: String, CaseIterable, Sendable {
    case appleSpeech, customWhisper
    var title: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .customWhisper: return "Custom FFmpeg Whisper"
        }
    }
}

/// File grants survive both setup and an in-flight inference, including cancellation teardown.
private nonisolated final class WhisperArtifactAccess: @unchecked Sendable {
    let url: URL
    private let accessed: Bool
    init(_ url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

@MainActor @Observable
final class FFmpegWhisperSetupModel {
    static let preferenceKey = "voiceMemo.transcriptionProvider"
    var choice: VoiceMemoTranscriptionProviderChoice {
        didSet { defaults.set(choice.rawValue, forKey: Self.preferenceKey) }
    }
    private(set) var executableURL: URL?
    private(set) var modelURL: URL?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?
    private(set) var isReady = false
    var executionConsent = false {
        didSet { if !executionConsent { invalidate() } }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let admission: FFmpegWhisperArtifactAdmissionService
    @ObservationIgnored private var executableAccess: WhisperArtifactAccess?
    @ObservationIgnored private var modelAccess: WhisperArtifactAccess?
    @ObservationIgnored private var receipt: FFmpegWhisperArtifactAdmissionService.Receipt?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(defaults: UserDefaults = .standard,
         admission: FFmpegWhisperArtifactAdmissionService = FFmpegWhisperArtifactAdmissionService()) {
        self.defaults = defaults
        self.admission = admission
        choice = defaults.string(forKey: Self.preferenceKey)
            .flatMap(VoiceMemoTranscriptionProviderChoice.init(rawValue:)) ?? .appleSpeech
    }

    func select(_ url: URL, executable: Bool) {
        invalidate()
        executionConsent = false
        if executable {
            executableAccess = WhisperArtifactAccess(url)
            executableURL = url
        } else {
            modelAccess = WhisperArtifactAccess(url)
            modelURL = url
        }
        errorMessage = nil
    }

    func prepare() async {
        guard !Task.isCancelled, executionConsent, let executableAccess, let modelAccess, !isPreparing else { return }
        invalidate()
        let requested = generation
        isPreparing = true
        errorMessage = nil
        let work = Task { [admission] in
            do {
                let value = try await admission.admitCustom(
                    executableURL: executableAccess.url, modelURL: modelAccess.url)
                guard !Task.isCancelled, self.generation == requested else {
                    await admission.revoke(value)
                    if self.generation == requested { self.isPreparing = false }
                    return
                }
                self.receipt = value
                self.isReady = true
                self.isPreparing = false
            } catch {
                guard self.generation == requested else { return }
                self.isPreparing = false
                if !(error is CancellationError) {
                    self.errorMessage = "Cannot admit these custom files. Select readable, nonempty regular files without symbolic links; FFmpeg must be executable. No file was executed."
                }
            }
        }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    func provider() -> FFmpegWhisperTranscriptionProvider? {
        guard executionConsent, isReady, let receipt, let executableAccess, let modelAccess else { return nil }
        let authorize = admission.authorizer(for: receipt)
        return FFmpegWhisperTranscriptionProvider(configuration: receipt.configuration(),
            authorizeArtifacts: { configuration in
                // Strong captures keep sandbox grants alive until the provider's run completes.
                _ = executableAccess.url
                _ = modelAccess.url
                try await authorize(configuration)
            })
    }

    func reportPickerError(_ error: Error) {
        if (error as? CocoaError)?.code != .userCancelled { errorMessage = error.localizedDescription }
    }

    func cancelPreparation() { invalidate() }

    func clear() {
        invalidate()
        executionConsent = false
        executableAccess = nil
        modelAccess = nil
        executableURL = nil
        modelURL = nil
        errorMessage = nil
    }

    private func invalidate() {
        task?.cancel()
        task = nil
        generation = UUID()
        isPreparing = false
        isReady = false
        if let receipt {
            self.receipt = nil
            Task { [admission] in await admission.revoke(receipt) }
        }
    }
}
