import Foundation
import Observation

nonisolated enum VoiceMemoTranscriptionProviderChoice: String, CaseIterable, Sendable {
    case appleSpeech, whisper, customWhisper
    var title: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper: return "Whisper"
        case .customWhisper: return "Custom FFmpeg Whisper"
        }
    }
}

@MainActor @Observable
final class FFmpegWhisperSetupModel {
    /// Consent and admitted identities are shared by Settings and Caption until app quit or revocation.
    static let shared = FFmpegWhisperSetupModel()
    private(set) var isTranscribing = false

    func beginTranscription() -> Bool {
        guard !isTranscribing else { return false }
        isTranscribing = true
        return true
    }

    func finishTranscription() { isTranscribing = false }

    static let preferenceKey = "voiceMemo.transcriptionProvider"
    static let executableBookmarkKey = "voiceMemo.whisper.executableBookmark"
    static let modelBookmarkKey = "voiceMemo.whisper.modelBookmark"
    static let languageKey = "voiceMemo.whisper.language"
    static let translateKey = "voiceMemo.whisper.translate"
    static let useGPUKey = "voiceMemo.whisper.useGPU"
    var language: String {
        didSet {
            let normalized = String(language.prefix(16)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized != language { language = normalized }
            if isLanguageValid { defaults.set(language, forKey: Self.languageKey) }
        }
    }
    var translate: Bool {
        didSet { defaults.set(translate, forKey: Self.translateKey) }
    }
    var useGPU: Bool {
        didSet { defaults.set(useGPU, forKey: Self.useGPUKey) }
    }
    var isLanguageValid: Bool { Self.isValidLanguage(language) }

    private static func isValidLanguage(_ language: String) -> Bool {
        language == "auto" || (language.utf8.count == 2 && language.utf8.allSatisfy { (97...122).contains($0) })
    }

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
    @ObservationIgnored private let bookmarks: FFmpegWhisperBookmarkService
    @ObservationIgnored private var executableRequest = UUID()
    @ObservationIgnored private var modelRequest = UUID()
    @ObservationIgnored private let admission: FFmpegWhisperArtifactAdmissionService
    @ObservationIgnored private var executableAccess: WhisperArtifactAccess?
    @ObservationIgnored private var modelAccess: WhisperArtifactAccess?
    @ObservationIgnored private var receipt: FFmpegWhisperArtifactAdmissionService.Receipt?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    static let sessionDefaults: UserDefaults = {
        let configuration = UITestLaunchConfiguration.current
        guard configuration.isEnabled else { return AppDefaults.store }
        let identifier = configuration.whisperDefaultsSuite ?? UUID().uuidString
        return UserDefaults(suiteName: "com.aagedal.photo-agent.ui-tests.whisper.\(identifier)")!
    }()

    init(defaults: UserDefaults? = nil,
         admission: FFmpegWhisperArtifactAdmissionService = FFmpegWhisperArtifactAdmissionService(),
         bookmarks: FFmpegWhisperBookmarkService = FFmpegWhisperBookmarkService()) {
        let defaults = defaults ?? Self.sessionDefaults
        self.defaults = defaults
        self.admission = admission
        self.bookmarks = bookmarks
        let savedLanguage = defaults.string(forKey: Self.languageKey) ?? "auto"
        language = Self.isValidLanguage(savedLanguage) ? savedLanguage : "auto"
        translate = defaults.bool(forKey: Self.translateKey)
        useGPU = defaults.bool(forKey: Self.useGPUKey)
        choice = defaults.string(forKey: Self.preferenceKey)
            .flatMap(VoiceMemoTranscriptionProviderChoice.init(rawValue:)) ?? .appleSpeech
    }

    func restoreSelections() async {
        let executableRequest = executableRequest
        let modelRequest = modelRequest
        await restore(executable: true, request: executableRequest)
        await restore(executable: false, request: modelRequest)
    }

    private func restore(executable: Bool, request: UUID) async {
        let key = executable ? Self.executableBookmarkKey : Self.modelBookmarkKey
        guard !Task.isCancelled, request == (executable ? executableRequest : modelRequest),
              (executable ? executableURL : modelURL) == nil,
              let data = defaults.data(forKey: key) else { return }
        do {
            let selection = try await bookmarks.restore(data)
            guard !Task.isCancelled, request == (executable ? executableRequest : modelRequest) else { return }
            publish(selection, executable: executable)
        } catch {
            guard !Task.isCancelled, request == (executable ? executableRequest : modelRequest) else { return }
            // Keep recovery evidence until the user reselects or explicitly clears the files.
            errorMessage = "A saved custom file is unavailable. Reconnect its volume or choose the file again. No file was executed."
        }
    }

    func select(_ url: URL, executable: Bool) async {
        // A file panel can outlive the enabled Settings form while Caption starts work.
        guard !isTranscribing else {
            errorMessage = "Stop transcription in Caption before changing custom files."
            return
        }
        invalidate()
        executionConsent = false
        let request = UUID()
        if executable {
            executableRequest = request
            executableAccess = nil
            executableURL = nil
        } else {
            modelRequest = request
            modelAccess = nil
            modelURL = nil
        }
        defaults.removeObject(forKey: executable ? Self.executableBookmarkKey : Self.modelBookmarkKey)
        errorMessage = nil
        do {
            let selection = try await bookmarks.select(url)
            guard !Task.isCancelled, request == (executable ? executableRequest : modelRequest) else { return }
            publish(selection, executable: executable)
        } catch {
            guard !Task.isCancelled, request == (executable ? executableRequest : modelRequest) else { return }
            errorMessage = "Cannot retain access to this custom file. Choose a readable local file again. No file was executed."
        }
    }

    private func publish(_ selection: FFmpegWhisperBookmarkService.Selection, executable: Bool) {
        if executable {
            executableAccess = selection.access
            executableURL = selection.access.url
        } else {
            modelAccess = selection.access
            modelURL = selection.access.url
        }
        defaults.set(selection.bookmark, forKey: executable ? Self.executableBookmarkKey : Self.modelBookmarkKey)
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

    func provider(run: @escaping FFmpegWhisperTranscriptionProvider.Run = {
        try await FFmpegWhisperJobRunner().run($0)
    }) -> FFmpegWhisperTranscriptionProvider? {
        guard executionConsent, isReady, isLanguageValid, let receipt, let executableAccess, let modelAccess else { return nil }
        let authorize = admission.authorizer(for: receipt)
        return FFmpegWhisperTranscriptionProvider(configuration: receipt.configuration(language: language, useGPU: useGPU, translate: translate),
            authorizeArtifacts: { configuration in
                // Strong captures keep sandbox grants alive until the provider's run completes.
                _ = executableAccess.url
                _ = modelAccess.url
                try await authorize(configuration)
            }, run: run)
    }

    func reportPickerError(_ error: Error) {
        if (error as? CocoaError)?.code != .userCancelled { errorMessage = error.localizedDescription }
    }

    func cancelPreparation() { invalidate() }

    func clear() {
        defaults.removeObject(forKey: Self.executableBookmarkKey)
        defaults.removeObject(forKey: Self.modelBookmarkKey)
        endSession()
    }

    func endSession() {
        executableRequest = UUID()
        modelRequest = UUID()
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
