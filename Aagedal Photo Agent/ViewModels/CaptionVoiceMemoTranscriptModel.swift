import Foundation
import Observation

@MainActor @Observable
final class CaptionVoiceMemoTranscriptModel {
    private(set) var availability: VoiceMemoTranscriptionAvailability?
    private(set) var draft: VoiceMemoTranscriptDraft?
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var isTranscribing = false
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
        guard imageURL != nil else { return }
        generation &+= 1
        let requested = generation
        isChecking = true
        errorMessage = nil
        let work = Task { [service, selectedLocaleIdentifier] in
            let result = await service.availability(
                preferredLocale: Locale(identifier: selectedLocaleIdentifier)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.generation == requested else { return }
                self.availability = result
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

    func transcribe() async {
        guard let imageURL, !isDownloading, !isTranscribing else { return }
        startOperation()
        let requested = generation
        isTranscribing = true
        errorMessage = nil
        let locale = Locale(identifier: selectedLocaleIdentifier)
        let work = Task { [service] in
            do {
                let result = try await service.transcribe(imageURL: imageURL, locale: locale)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.generation == requested, self.imageURL == result.imageURL else { return }
                    self.draft = result
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
                    self.isTranscribing = false
                }
            }
        }
        task = work
        await work.value
    }

    func updateReviewedText(_ text: String) {
        guard var draft else { return }
        draft.reviewedText = text
        self.draft = draft
    }

    func cancel(resetDraft: Bool = false) {
        task?.cancel()
        task = nil
        generation &+= 1
        isChecking = false
        isDownloading = false
        isTranscribing = false
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
