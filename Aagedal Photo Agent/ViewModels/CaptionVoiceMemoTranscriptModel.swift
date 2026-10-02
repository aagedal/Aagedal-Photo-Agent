import Foundation
import Observation

@MainActor @Observable
final class CaptionVoiceMemoTranscriptModel {
    private(set) var availability: VoiceMemoTranscriptionAvailability?
    private(set) var draft: VoiceMemoTranscriptDraft?
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var isTranscribing = false
    private(set) var isSavingTranscript = false
    private(set) var errorMessage: String?
    var selectedLocaleIdentifier = Locale.current.identifier

    @ObservationIgnored private let service: VoiceMemoTranscriptionService
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var imageURL: URL?

    init(service: VoiceMemoTranscriptionService = VoiceMemoTranscriptionService()) {
        self.service = service
    }

    func load(_ imageURL: URL?) async {
        cancel(resetDraft: true)
        self.imageURL = imageURL?.standardizedFileURL
        guard let imageURL = self.imageURL else { return }
        generation &+= 1
        let requested = generation
        isChecking = true
        errorMessage = nil
        let work = Task { [service, selectedLocaleIdentifier] in
            var saved: VoiceMemoTranscriptDraft?
            var loadError: String?
            do {
                saved = try await service.loadPersistedDraft(imageURL: imageURL)
            }
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

    func reloadPersistedDraftIfIdle(for requestedURL: URL) async {
        guard imageURL == requestedURL.standardizedFileURL, !isChecking, !isTranscribing,
              !isDownloading, !isSavingTranscript else { return }
        await load(requestedURL)
    }

    func resetTranscript(for requestedURL: URL) async {
        guard imageURL == requestedURL.standardizedFileURL, !isChecking, !isTranscribing,
              !isDownloading, !isSavingTranscript else { return }
        let requestedGeneration = generation
        isSavingTranscript = true
        errorMessage = nil
        do {
            try await MetadataSidecarService().resetVoiceMemoTranscriptSerialized(
                for: requestedURL, in: requestedURL.deletingLastPathComponent())
            guard generation == requestedGeneration else { return }
            draft = nil
            isSavingTranscript = false
        } catch {
            guard generation == requestedGeneration else { return }
            isSavingTranscript = false
            errorMessage = error.localizedDescription
        }
    }

    func selectLocale(identifier: String) async {
        selectedLocaleIdentifier = identifier
        guard let imageURL else { return }
        await load(imageURL)
    }

    /// Batch completion can arrive after navigation or a local edit. Refresh only an
    /// empty, idle review for the same photo, without cancelling any current work.
    func refreshPersistedDraftIfEmpty(for requestedURL: URL) async {
        let requestedURL = requestedURL.standardizedFileURL
        guard imageURL == requestedURL, draft == nil, !isChecking, !isDownloading,
              !isTranscribing, !isSavingTranscript else { return }
        let requestedGeneration = generation
        do {
            let saved = try await service.loadPersistedDraft(imageURL: requestedURL)
            guard !Task.isCancelled, generation == requestedGeneration, imageURL == requestedURL,
                  draft == nil, !isChecking, !isDownloading, !isTranscribing, !isSavingTranscript else { return }
            guard generation == requestedGeneration, imageURL == requestedURL, draft == nil else { return }
            draft = saved
        } catch is CancellationError { }
        catch {
            guard generation == requestedGeneration, imageURL == requestedURL, draft == nil else { return }
            errorMessage = error.localizedDescription
        }
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
        guard let imageURL, !isDownloading, !isTranscribing, !isSavingTranscript else { return }
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
                try Task.checkCancellation()
                let saved = try await service.save(result)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.generation == requested, self.imageURL == saved.imageURL else { return }
                    self.draft = saved
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

    func cancel(resetDraft: Bool = false) {
        task?.cancel()
        task = nil
        generation &+= 1
        isChecking = false
        isDownloading = false
        isTranscribing = false
        isSavingTranscript = false
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
