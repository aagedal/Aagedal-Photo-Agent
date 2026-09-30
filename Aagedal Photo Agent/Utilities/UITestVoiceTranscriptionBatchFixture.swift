import Foundation

/// Explicit native-test seam: real input admission, retained execution and create-only
/// persistence; synthetic readiness/recognition. Never reads or installs host assets.
enum UITestVoiceTranscriptionBatchFixture {
    static func currentTranscriptService() -> VoiceMemoTranscriptionService? {
        let configuration = UITestLaunchConfiguration.current
        guard configuration.isEnabled, configuration.transcriptionBatchMode != nil else { return nil }
        let locale = Locale(identifier: "en-US")
        return VoiceMemoTranscriptionService(runtime: .init(isAvailable: { true }, supportedLocales: { [locale] },
            resolveLocale: { _ in locale }, assetStatus: { _ in .installed }, installAssets: { _ in
                throw VoiceMemoTranscriptionError.languageDownloadFailed
            }, transcribe: { _, _ in throw VoiceMemoTranscriptionError.recognitionFailed }))
    }

    static func currentDependenciesForModel() -> CaptionVoiceMemoBatchTranscriptionModel.Dependencies? {
        let configuration = UITestLaunchConfiguration.current
        guard configuration.isEnabled, let mode = configuration.transcriptionBatchMode else { return nil }
        let worker = Worker(folder: configuration.folderURL, mode: mode)
        return .init(prepare: { try await worker.prepare($0) },
            validateProvider: { try await worker.validateProvider($0) },
            hasExistingReview: { try await worker.hasExistingReview($0) },
            submit: { try await worker.submit($0, provider: $1) },
            inspect: { try await worker.inspect($0) },
            wait: { try await worker.wait($0) },
            cancel: { try await worker.cancel($0) })
    }

    private actor Worker {
        let folder: URL?
        let mode: String
        private var batch: AutomationVoiceTranscriptionBatchService?
        private var registry: AutomationOperationRegistry?
        private var transcription: VoiceMemoTranscriptionService?

        init(folder: URL?, mode: String) { self.folder = folder; self.mode = mode }

        private func services() throws -> (AutomationVoiceTranscriptionBatchService, AutomationOperationRegistry, VoiceMemoTranscriptionService) {
            if let batch, let registry, let transcription { return (batch, registry, transcription) }
            guard let folder else { throw AutomationVoiceTranscriptionBatchService.Failure.invalidPhotos }
            let root = folder.resolvingSymlinksInPath()
            let mode = mode
            let locale = Locale(identifier: "en-US")
            let runtime = VoiceMemoTranscriptionRuntime(isAvailable: { true }, supportedLocales: { [locale] },
                resolveLocale: { _ in locale }, assetStatus: { _ in .installed }, installAssets: { _ in
                    throw VoiceMemoTranscriptionError.languageDownloadFailed
                }, transcribe: { audio, _ in
                    guard audio.deletingLastPathComponent().resolvingSymlinksInPath() == root else {
                        throw VoiceMemoTranscriptionError.relationshipUnavailable
                    }
                    if mode == "blockSecond", audio.lastPathComponent == "voice-batch-2.WAV" {
                        try Data("synthetic recognition active".utf8).write(to: root.appendingPathComponent("batch-second-active.txt"))
                        while true { try await Task.sleep(for: .milliseconds(50)) }
                    }
                    return "Synthetic batch transcript \(audio.lastPathComponent)"
                })
            let transcription = VoiceMemoTranscriptionService(runtime: runtime)
            let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("batch-operations"))
            let batch = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: .live(service: transcription))
            self.batch = batch; self.registry = registry; self.transcription = transcription
            return (batch, registry, transcription)
        }

        func prepare(_ photos: [URL]) async throws -> AutomationVoiceTranscriptionBatchService.PreparedBatch {
            guard let folder, photos.allSatisfy({ $0.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() }) else {
                throw AutomationVoiceTranscriptionBatchService.Failure.invalidPhotos
            }
            return try await services().0.prepare(imageURLs: photos)
        }
        func validateProvider(_ provider: AutomationVoiceTranscriptionBatchService.Provider) throws {
            guard case .apple = provider else { throw VoiceMemoTranscriptionError.unavailable }
        }
        func hasExistingReview(_ image: URL) async throws -> Bool {
            try await services().2.loadPersistedDraft(imageURL: image) != nil
        }
        func submit(_ prepared: AutomationVoiceTranscriptionBatchService.PreparedBatch,
                    provider: AutomationVoiceTranscriptionBatchService.Provider) async throws -> AutomationOperationRegistry.Record {
            try await services().0.submit(prepared: prepared, provider: provider)
        }
        func inspect(_ id: UUID) throws -> AutomationOperationRegistry.Record { try services().1.inspect(id) }
        func wait(_ id: UUID) async throws -> AutomationOperationRegistry.Record { try await services().0.waitForCompletion(id) }
        func cancel(_ id: UUID) throws -> AutomationOperationRegistry.Record { try services().1.requestCancellation(id) }
    }
}
