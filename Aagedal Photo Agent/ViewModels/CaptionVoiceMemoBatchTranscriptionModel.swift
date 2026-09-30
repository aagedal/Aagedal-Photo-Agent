import Foundation
import Observation

/// Native consent owns one immutable photo/provider snapshot. The retained executor
/// owns persistence; dismissing a view never cancels or replaces admitted work.
@MainActor @Observable
final class CaptionVoiceMemoBatchTranscriptionModel {
    nonisolated struct Dependencies: Sendable {
        let prepare: @Sendable ([URL]) async throws -> AutomationVoiceTranscriptionBatchService.PreparedBatch
        let validateProvider: @Sendable (AutomationVoiceTranscriptionBatchService.Provider) async throws -> Void
        let hasExistingReview: @Sendable (URL) async throws -> Bool
        let submit: @Sendable (AutomationVoiceTranscriptionBatchService.PreparedBatch,
                               AutomationVoiceTranscriptionBatchService.Provider) async throws -> AutomationOperationRegistry.Record
        let inspect: @Sendable (UUID) async throws -> AutomationOperationRegistry.Record
        let wait: @Sendable (UUID) async throws -> AutomationOperationRegistry.Record
        let cancel: @Sendable (UUID) async throws -> AutomationOperationRegistry.Record

        static func live() -> Self {
            let worker = CaptionVoiceMemoBatchWorker()
            return Self(prepare: { try await worker.prepare($0) },
                        validateProvider: { try await worker.validateProvider($0) },
                        hasExistingReview: { try await worker.hasExistingReview($0) },
                        submit: { try await worker.submit($0, provider: $1) },
                        inspect: { try await worker.inspect($0) },
                        wait: { try await worker.wait($0) },
                        cancel: { try await worker.cancel($0) })
        }
    }

    nonisolated struct Snapshot: Sendable {
        let imageURLs: [URL]
        let providerTitle: String
        let languageTitle: String
        fileprivate let prepared: AutomationVoiceTranscriptionBatchService.PreparedBatch
        fileprivate let provider: AutomationVoiceTranscriptionBatchService.Provider
    }

    private(set) var snapshot: Snapshot?
    private(set) var activeImageURLs: [URL] = []
    private(set) var activeProviderTitle: String?
    private(set) var activeLanguageTitle: String?
    private(set) var record: AutomationOperationRegistry.Record?
    private(set) var isChecking = false
    private(set) var isRunning = false
    private(set) var isRequestingCancellation = false
    private(set) var errorMessage: String?
    private(set) var completionToken: UInt64 = 0

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let beginExecution: @MainActor () -> Bool
    @ObservationIgnored private let endExecution: @MainActor () -> Void
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationRequested = false
    @ObservationIgnored private var cancelledBeforeSubmission = false

    init(dependencies: Dependencies? = nil,
         beginExecution: @escaping @MainActor () -> Bool = { FFmpegWhisperSetupModel.shared.beginTranscription() },
         endExecution: @escaping @MainActor () -> Void = { FFmpegWhisperSetupModel.shared.finishTranscription() }) {
        self.dependencies = dependencies ?? UITestVoiceTranscriptionBatchFixture.currentDependenciesForModel() ?? .live()
        self.beginExecution = beginExecution
        self.endExecution = endExecution
    }

    var savedDraftImageURLs: [URL] {
        (record?.batchProgress?.items ?? []).compactMap { item in
            guard item.outcome == .draftSaved, activeImageURLs.indices.contains(item.index) else { return nil }
            return activeImageURLs[item.index]
        }
    }

    var statusMessage: String {
        let saved = savedDraftImageURLs.count
        let suffix = "\(saved) of \(activeImageURLs.count) editable drafts saved. Existing reviews are kept."
        if isRequestingCancellation || (isRunning && cancellationRequested) {
            return "Cancellation requested. Waiting for the current item to stop safely. " + suffix
        }
        if isRunning { return "Transcribing the confirmed photos. " + suffix }
        if cancelledBeforeSubmission { return "Batch cancelled before transcription started. No drafts were saved." }
        switch record?.outcome {
        case .verified: return suffix + " Review and approve each draft in Caption."
        case .cancelled: return "Batch cancelled. " + suffix + " Saved drafts remain available; unfinished photos were not restarted."
        case .recoveryRequired, .partialUncertain:
            return "Batch stopped with an uncertain save. " + suffix + " Check the affected photo before trying again."
        case .failed, .stale: return "Batch finished with failed or changed photos. " + suffix
        case nil:
            if !activeImageURLs.isEmpty, errorMessage != nil {
                return "Batch was not admitted. No drafts were saved. Prepare the batch again after resolving the issue."
            }
            return "Confirm the selected photos to save editable transcript drafts."
        }
    }

    func prepare(imageURLs: [URL], provider: AutomationVoiceTranscriptionBatchService.Provider?,
                 providerTitle: String, languageTitle: String,
                 reviewOrSaveBusy: Bool, providerBusy: Bool) async {
        guard !isRunning, !isChecking else { return }
        generation &+= 1
        let requested = generation
        snapshot = nil
        errorMessage = nil
        guard !reviewOrSaveBusy, !providerBusy else {
            errorMessage = "Finish the current review, save, or transcription before preparing a batch."
            return
        }
        let urls = imageURLs.map(\.standardizedFileURL)
        guard (1...AutomationVoiceTranscriptionBatchService.maximumPhotos).contains(urls.count),
              urls.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
              Set(urls).count == urls.count else {
            errorMessage = "Select 1–8 different photos with separate voice-memo sidecars."
            return
        }
        guard let provider else {
            errorMessage = "The selected transcription provider is not ready. Complete its setup in Settings."
            return
        }
        isChecking = true
        defer { if generation == requested { isChecking = false } }
        do {
            try await dependencies.validateProvider(provider)
            let prepared = try await dependencies.prepare(urls)
            guard prepared.imageURLs == urls else { throw AutomationVoiceTranscriptionBatchService.Failure.invalidPhotos }
            for url in urls {
                if try await dependencies.hasExistingReview(url) { throw VoiceMemoTranscriptionError.existingTranscript }
            }
            try Task.checkCancellation()
            guard generation == requested else { return }
            snapshot = Snapshot(imageURLs: urls, providerTitle: providerTitle, languageTitle: languageTitle,
                                prepared: prepared, provider: provider)
        } catch {
            guard generation == requested else { return }
            if !(error is CancellationError) { errorMessage = Self.message(for: error) }
        }
    }

    func dismissConfirmation() {
        guard !isRunning else { return }
        generation &+= 1
        snapshot = nil
        isChecking = false
    }

    /// The unstructured task deliberately survives SwiftUI task cancellation. Capacity
    /// remains held until the retained executor acknowledges a drained terminal result.
    func confirm(consent: Bool, reviewOrSaveBusy: Bool, providerBusy: Bool) async {
        guard consent, !isRunning, let snapshot else { return }
        guard !reviewOrSaveBusy, !providerBusy, beginExecution() else {
            errorMessage = "Finish the current review, save, or transcription before starting this batch."
            return
        }
        self.snapshot = nil
        activeImageURLs = snapshot.imageURLs
        activeProviderTitle = snapshot.providerTitle
        activeLanguageTitle = snapshot.languageTitle
        record = nil
        errorMessage = nil
        cancellationRequested = false
        cancelledBeforeSubmission = false
        isRequestingCancellation = false
        isRunning = true
        let work = Task { [self] in await execute(snapshot) }
        executionTask = work
        await work.value
    }

    func requestCancellation() async {
        guard isRunning, !isRequestingCancellation else { return }
        cancellationRequested = true
        isRequestingCancellation = true
        guard let record, !record.isTerminal else { return }
        do { self.record = try await dependencies.cancel(record.id) }
        catch {
            isRequestingCancellation = false
            errorMessage = "The cancellation request could not be saved. Transcription remains active. " + error.localizedDescription
        }
    }

    private func execute(_ snapshot: Snapshot) async {
        do {
            try await dependencies.validateProvider(snapshot.provider)
            for url in snapshot.imageURLs {
                if try await dependencies.hasExistingReview(url) { throw VoiceMemoTranscriptionError.existingTranscript }
            }
            if cancellationRequested {
                cancelledBeforeSubmission = true
                finishExecution()
                return
            }
            let admitted = try await dependencies.submit(snapshot.prepared, snapshot.provider)
            record = admitted
            let id = admitted.id
            if cancellationRequested {
                do { record = try await dependencies.cancel(id) }
                catch {
                    isRequestingCancellation = false
                    errorMessage = "The cancellation request could not be saved. Transcription remains active. " + error.localizedDescription
                }
            }
            let polling = Task { [self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                        let current = try await dependencies.inspect(id)
                        guard !Task.isCancelled else { return }
                        record = current
                    } catch is CancellationError { return }
                    catch { /* The owning wait remains authoritative; never infer rollback. */ }
                }
            }
            // A transient wait/history failure cannot prove provider teardown. Retain
            // global capacity and retry the owner's wait instead of reporting completion.
            while true {
                do {
                    let completed = try await dependencies.wait(id)
                    guard completed.isTerminal else { throw AutomationOperationRegistry.Failure.invalidTransition }
                    polling.cancel()
                    await polling.value
                    record = completed
                    errorMessage = nil
                    completionToken &+= 1
                    finishExecution()
                    return
                } catch {
                    errorMessage = "Batch status could not be confirmed. Waiting for transcription to finish safely. " + error.localizedDescription
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        } catch {
            errorMessage = Self.message(for: error)
            finishExecution()
        }
    }

    private func finishExecution() {
        isRunning = false
        isRequestingCancellation = false
        executionTask = nil
        endExecution()
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? AutomationVoiceTranscriptionBatchService.Failure {
            switch failure {
            case .invalidPhotos: return "Select 1–8 different photos with supported WAV voice memos and separate sidecars."
            case .sourceChanged: return "A photo or voice memo changed after confirmation. Prepare the batch again."
            case .invalidDraft: return "The generated transcript could not be validated."
            }
        }
        return error.localizedDescription
    }
}

/// Registry construction and synchronous filesystem transactions run on this actor's
/// utility executor. No native UI callback performs registry work on the main thread.
private actor CaptionVoiceMemoBatchWorker {
    nonisolated let filesystemQueue = DispatchSerialQueue(label: "com.aagedal.photo-agent.caption-transcription-batch", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
    private var registry: AutomationOperationRegistry?
    private var service: AutomationVoiceTranscriptionBatchService?
    private let transcripts = VoiceMemoTranscriptionService()

    private func executor() throws -> AutomationVoiceTranscriptionBatchService {
        if let service { return service }
        let registry = AutomationOperationRegistry(storageDirectory: try AutomationOperationRegistry.defaultStorageDirectory())
        let service = AutomationVoiceTranscriptionBatchService(registry: registry)
        self.registry = registry
        self.service = service
        return service
    }

    func prepare(_ urls: [URL]) async throws -> AutomationVoiceTranscriptionBatchService.PreparedBatch {
        try await executor().prepare(imageURLs: urls)
    }
    func validateProvider(_ provider: AutomationVoiceTranscriptionBatchService.Provider) async throws {
        switch provider {
        case .apple(let locale):
            let availability = await transcripts.availability(preferredLocale: locale)
            guard let selected = availability.selectedLocale,
                  Self.localeKey(selected) == Self.localeKey(locale) else { throw VoiceMemoTranscriptionError.unsupportedLanguage }
            switch availability.status {
            case .installed: break
            case .unsupported: throw VoiceMemoTranscriptionError.unsupportedLanguage
            case .needsDownload, .downloading: throw VoiceMemoTranscriptionError.languageDownloadRequired
            case .reservationLimitReached:
                throw VoiceMemoTranscriptionError.languageReservationLimitReached(maximum: availability.maximumReservedLocales)
            }
        case .whisper(let provider): try await provider.validateReadiness()
        }
    }
    private nonisolated static func localeKey(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    func hasExistingReview(_ url: URL) async throws -> Bool {
        try await transcripts.loadPersistedDraft(imageURL: url) != nil
    }
    func submit(_ prepared: AutomationVoiceTranscriptionBatchService.PreparedBatch,
                provider: AutomationVoiceTranscriptionBatchService.Provider) async throws -> AutomationOperationRegistry.Record {
        try await executor().submit(prepared: prepared, provider: provider)
    }
    func inspect(_ id: UUID) throws -> AutomationOperationRegistry.Record {
        guard let registry else { throw AutomationOperationRegistry.Failure.unknownOperation }
        return try registry.inspect(id)
    }
    func wait(_ id: UUID) async throws -> AutomationOperationRegistry.Record {
        try await executor().waitForCompletion(id)
    }
    func cancel(_ id: UUID) throws -> AutomationOperationRegistry.Record {
        guard let registry else { throw AutomationOperationRegistry.Failure.unknownOperation }
        return try registry.requestCancellation(id)
    }
}
