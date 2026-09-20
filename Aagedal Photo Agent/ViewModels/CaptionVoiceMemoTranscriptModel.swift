import Foundation
import Observation

@MainActor @Observable
final class CaptionVoiceMemoTranscriptModel {
    private(set) var availability: VoiceMemoTranscriptionAvailability?
    private(set) var draft: VoiceMemoTranscriptDraft?
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var isTranscribing = false
    private(set) var isSavingReview = false
    private(set) var errorMessage: String?
    var selectedLocaleIdentifier = Locale.current.identifier

    @ObservationIgnored private let service: VoiceMemoTranscriptionService
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var reviewPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var queuedReviewDraft: VoiceMemoTranscriptDraft?
    @ObservationIgnored private var lastPersistedReviewDraft: VoiceMemoTranscriptDraft?
    @ObservationIgnored private var reviewPersistenceGeneration: UInt64?
    @ObservationIgnored private var persistsReviewEdits = false
    @ObservationIgnored private var imageURL: URL?

    init(service: VoiceMemoTranscriptionService = VoiceMemoTranscriptionService()) {
        self.service = service
    }

    func load(_ imageURL: URL?) async {
        cancel(resetDraft: true)
        // Approval revocation is a durability boundary, not disposable presentation work.
        // Finish any queued TextEditor changes before loading another photo or locale so a
        // relaunch cannot restore only the first incremental edit.
        await reviewPersistenceTask?.value
        persistsReviewEdits = false
        lastPersistedReviewDraft = nil
        self.imageURL = imageURL?.standardizedFileURL
        guard let imageURL = self.imageURL else { return }
        generation &+= 1
        let requested = generation
        isChecking = true
        errorMessage = nil
        let work = Task { [service, selectedLocaleIdentifier] in
            var saved: VoiceMemoTranscriptDraft?
            var loadError: String?
            do { saved = try await service.loadPersistedDraft(imageURL: imageURL) }
            catch is CancellationError { return }
            catch { loadError = error.localizedDescription }
            let result = await service.availability(
                preferredLocale: Locale(identifier: selectedLocaleIdentifier)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.generation == requested else { return }
                self.draft = saved
                self.availability = result
                self.errorMessage = loadError
                if let selected = result.selectedLocale {
                    self.selectedLocaleIdentifier = selected.identifier
                }
                self.isChecking = false
            }
        }
        task = work
        await work.value
    }

    func selectLocale(identifier: String) async {
        selectedLocaleIdentifier = identifier
        guard let imageURL else { return }
        await load(imageURL)
    }

    func downloadLanguage() async {
        guard !isDownloading, !isTranscribing else { return }
        startOperation()
        let requested = generation
        isDownloading = true
        errorMessage = nil
        let locale = Locale(identifier: selectedLocaleIdentifier)
        let work = Task { [service] in
            do {
                let result = try await service.downloadLanguage(locale)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.generation == requested else { return }
                    self.availability = result
                    self.isDownloading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.generation == requested { self.isDownloading = false }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == requested else { return }
                    self.errorMessage = error.localizedDescription
                    self.isDownloading = false
                }
            }
        }
        task = work
        await work.value
    }

    func releaseLanguage(identifier: String) async {
        guard !isDownloading, !isTranscribing else { return }
        startOperation()
        let requested = generation
        isChecking = true
        errorMessage = nil
        let locale = Locale(identifier: identifier)
        let preferred = Locale(identifier: selectedLocaleIdentifier)
        let work = Task { [service] in
            let result = await service.releaseLanguage(locale, preferredLocale: preferred)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.generation == requested else { return }
                self.availability = result
                self.isChecking = false
            }
        }
        task = work
        await work.value
    }

    func transcribe(provider: FFmpegWhisperTranscriptionProvider? = nil) async {
        guard let imageURL, !isDownloading, !isTranscribing, !isSavingReview else { return }
        startOperation()
        let requested = generation
        isTranscribing = true
        errorMessage = nil
        let locale = Locale(identifier: selectedLocaleIdentifier)
        let work = Task { [service] in
            do {
                let result: VoiceMemoTranscriptDraft
                if let provider {
                    result = try await service.transcribe(imageURL: imageURL, provider: provider)
                } else {
                    result = try await service.transcribe(imageURL: imageURL, locale: locale)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.generation == requested, self.imageURL == result.imageURL else { return }
                    self.draft = result
                    self.persistsReviewEdits = false
                    self.lastPersistedReviewDraft = nil
                    self.isTranscribing = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.generation == requested { self.isTranscribing = false }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == requested else { return }
                    self.errorMessage = error.localizedDescription
                        + (provider == nil ? "" : (self.draft == nil
                            ? " Apple Speech was not used."
                            : " The existing review was kept. Apple Speech was not used."))
                    self.isTranscribing = false
                }
            }
        }
        task = work
        await work.value
    }

    func updateReviewedText(_ text: String) {
        guard var draft else { return }
        let previous = draft
        if draft.isApproved {
            persistsReviewEdits = true
            lastPersistedReviewDraft = draft
        }
        draft.reviewedText = text
        if persistsReviewEdits { draft.approvedAt = nil }
        self.draft = draft
        guard persistsReviewEdits else { return }

        if lastPersistedReviewDraft == nil { lastPersistedReviewDraft = previous }
        queuedReviewDraft = draft
        isSavingReview = true
        errorMessage = nil
        guard reviewPersistenceTask == nil else { return }
        reviewPersistenceGeneration = generation
        reviewPersistenceTask = Task { [weak self] in
            await self?.drainReviewPersistence()
        }
    }

    private func drainReviewPersistence() async {
        let requested = reviewPersistenceGeneration
        while let pending = queuedReviewDraft {
            queuedReviewDraft = nil
            do {
                let saved = try await service.revokeApproval(pending)
                lastPersistedReviewDraft = saved
                guard queuedReviewDraft == nil else { continue }
                if generation == requested,
                   imageURL == saved.imageURL,
                   draft?.reviewedText == saved.reviewedText {
                    draft = saved
                }
                finishReviewPersistence(generationMatches: generation == requested)
                return
            } catch is CancellationError {
                finishReviewPersistence(generationMatches: generation == requested)
                return
            } catch {
                let fallback = lastPersistedReviewDraft
                if generation == requested {
                    draft = fallback
                    errorMessage = "The edit was not kept because the transcript review could not be saved. "
                        + error.localizedDescription
                }
                persistsReviewEdits = fallback?.isApproved == false
                finishReviewPersistence(generationMatches: generation == requested)
                return
            }
        }
        finishReviewPersistence(generationMatches: generation == requested)
    }

    private func finishReviewPersistence(generationMatches: Bool) {
        queuedReviewDraft = nil
        reviewPersistenceTask = nil
        reviewPersistenceGeneration = nil
        isSavingReview = false
        if !generationMatches {
            persistsReviewEdits = false
            lastPersistedReviewDraft = nil
        }
    }

    func approve() async {
        guard let draft, !isSavingReview, !isDownloading, !isTranscribing else { return }
        startOperation()
        let requested = generation
        isSavingReview = true
        errorMessage = nil
        let work = Task { [service] in
            do {
                let saved = try await service.approve(draft)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.generation == requested else { return }
                    self.draft = saved
                    self.persistsReviewEdits = false
                    self.lastPersistedReviewDraft = saved
                    self.isSavingReview = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.generation == requested { self.isSavingReview = false }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == requested else { return }
                    self.errorMessage = error.localizedDescription
                    self.isSavingReview = false
                }
            }
        }
        task = work
        await work.value
    }

    func cancel(resetDraft: Bool = false) {
        task?.cancel()
        task = nil
        generation &+= 1
        isChecking = false
        isDownloading = false
        isTranscribing = false
        isSavingReview = reviewPersistenceTask != nil
        errorMessage = nil
        if resetDraft {
            availability = nil
            draft = nil
        }
    }

    private func startOperation() {
        task?.cancel()
        task = nil
        generation &+= 1
    }
}
