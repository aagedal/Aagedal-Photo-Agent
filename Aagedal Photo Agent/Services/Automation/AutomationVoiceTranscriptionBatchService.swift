import Foundation

/// App-side executor. Callers supply explicit photos and an explicitly selected provider;
/// this service grants no helper/root authority, downloads no assets and approves no text.
/// Each generated draft is create-only. Saved drafts survive a later failed/cancelled item.
actor AutomationVoiceTranscriptionBatchService {
    enum Failure: Error, Equatable { case invalidPhotos, sourceChanged, invalidDraft }
    enum Provider: Sendable {
        case apple(Locale)
        case whisper(FFmpegWhisperTranscriptionProvider)
    }

    nonisolated struct Input: Sendable {
        let imageURL: URL
        let sourceRevision: SourceImageRevision
        let association: VoiceMemoAssociation
        let memoRevision: SourceImageRevision
    }

    nonisolated struct Dependencies: Sendable {
        let capture: @Sendable (URL) async throws -> Input
        let generate: @Sendable (URL, Provider) async throws -> VoiceMemoTranscriptDraft
        let save: @Sendable (VoiceMemoTranscriptDraft, SourceImageRevision) async throws -> VoiceMemoTranscriptDraft

        static func live(service: VoiceMemoTranscriptionService) -> Self {
            let admission = VoiceTranscriptionBatchInputReader()
            return Self(capture: { try await admission.capture($0) }, generate: { image, provider in
                switch provider {
                case .apple(let locale): try await service.transcribe(imageURL: image, locale: locale)
                case .whisper(let provider): try await service.transcribe(imageURL: image, provider: provider)
                }
            }, save: { try await service.persistGeneratedDraft($0, expectedSourceRevision: $1) })
        }
    }

    static let maximumPhotos = 8
    private let registry: AutomationOperationRegistry
    private let coordinator: AutomationOperationExecutionCoordinator
    private let dependencies: Dependencies

    init(registry: AutomationOperationRegistry, dependencies: Dependencies? = nil) {
        self.registry = registry
        coordinator = AutomationOperationExecutionCoordinator(registry: registry, maximumConcurrentOperations: 1)
        self.dependencies = dependencies ?? .live(service: VoiceMemoTranscriptionService())
    }

    /// Capture the entire ordered set before durable admission. Missing relationships or
    /// duplicate sidecar ownership reject admission without running inference or saving.
    func submit(imageURLs: [URL], provider: Provider) async throws -> AutomationOperationRegistry.Record {
        try Task.checkCancellation()
        guard !imageURLs.isEmpty, imageURLs.count <= Self.maximumPhotos,
              imageURLs.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else { throw Failure.invalidPhotos }
        let urls = imageURLs.map(\.standardizedFileURL)
        var inputs: [Input] = []
        var identities = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            let input = try await dependencies.capture(url)
            guard input.imageURL.standardizedFileURL == url,
                  identities.insert(MetadataIOKey.key(for: input.sourceRevision.canonicalURL)).inserted else {
                throw Failure.invalidPhotos
            }
            inputs.append(input)
        }
        try Task.checkCancellation()
        let retained = inputs
        let registry = registry, dependencies = dependencies
        let owner = await coordinator.ownerID
        return try await coordinator.submit(kind: .voiceTranscription, didEnqueue: { record in
            _ = try registry.configureBatch(record.id, ownerID: owner, itemCount: retained.count)
        }) { context in
            try await Self.execute(retained, provider: provider, dependencies: dependencies,
                                   context: context, registry: registry, owner: owner)
        }
    }

    func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record {
        try await coordinator.waitForCompletion(id)
    }

    func shutdown() async throws { _ = try await coordinator.shutdown() }

    private nonisolated static func matches(_ expected: Input, _ current: Input) -> Bool {
        expected.imageURL == current.imageURL && expected.association == current.association
            && expected.sourceRevision.relationship(to: current.sourceRevision) == .exactRevision
            && expected.memoRevision.relationship(to: current.memoRevision) == .exactRevision
    }

    private nonisolated static func validate(_ draft: VoiceMemoTranscriptDraft, input: Input) throws {
        guard draft.imageURL == input.imageURL, draft.memoURL == input.association.memoURL,
              draft.memoByteCount == input.memoRevision.byteCount, draft.memoSHA256 == input.memoRevision.sha256,
              draft.associationProfileIdentifier == input.association.profileIdentifier,
              draft.approvedAt == nil, !draft.generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.reviewedText == draft.generatedText else { throw Failure.invalidDraft }
    }

    private nonisolated static func execute(_ inputs: [Input], provider: Provider, dependencies: Dependencies,
        context: AutomationOperationExecutionCoordinator.Context, registry: AutomationOperationRegistry,
        owner: UUID) async throws -> AutomationOperationRegistry.Outcome {
        var hadFailure = false
        for (index, input) in inputs.enumerated() {
            // A clean cancellation after a verified prefix leaves saved drafts intact.
            do { try await context.checkCancellation() }
            catch is CancellationError { return .cancelled }
            do { _ = try registry.startBatchItem(context.operationID, ownerID: owner, index: index) }
            catch {
                // The durable request can arrive after the safe-boundary check and
                // before item admission. No item started; the known prefix stays valid.
                do { try await context.checkCancellation() }
                catch is CancellationError { return .cancelled }
                throw error
            }
            var saving = false
            do {
                guard matches(input, try await dependencies.capture(input.imageURL)) else { throw Failure.sourceChanged }
                let draft = try await generateWithCancellation(input.imageURL, provider: provider,
                                                               dependencies: dependencies, context: context)
                try validate(draft, input: input)
                guard matches(input, try await dependencies.capture(input.imageURL)) else { throw Failure.sourceChanged }
                try await context.markEffectsMayHaveOccurred()
                saving = true
                let saved = try await dependencies.save(draft, input.sourceRevision)
                // Durable semantic read-back must match the entire unapproved draft.
                try validate(saved, input: input)
                let dates = ISO8601DateFormatter()
                guard saved.generatedText == draft.generatedText, saved.reviewedText == draft.reviewedText,
                      saved.localeIdentifier == draft.localeIdentifier, saved.provider == draft.provider,
                      saved.providerModel == draft.providerModel, saved.whisperProvenance == draft.whisperProvenance,
                      dates.string(from: saved.generatedAt) == dates.string(from: draft.generatedAt) else {
                    throw Failure.invalidDraft
                }
                _ = try registry.finishBatchItem(context.operationID, ownerID: owner, index: index, outcome: .draftSaved)
            } catch {
                let definitelyRefused = error as? VoiceMemoTranscriptionError == .existingTranscript
                    || error as? VoiceMemoTranscriptionError == .invalidGeneratedDraft
                    || error as? VoiceMemoTranscriptionError == .sourceChanged
                if saving && !definitelyRefused {
                    // A failed/late-cancelled save may have installed bytes. Do not infer
                    // rollback or replay inference; stop and retain uncertain evidence.
                    _ = try registry.finishBatchItem(context.operationID, ownerID: owner, index: index, outcome: .recoveryRequired)
                    return .recoveryRequired
                }
                if error is CancellationError {
                    let requested = try registry.inspect(context.operationID).cancellationRequestedAt != nil
                    _ = try registry.finishBatchItem(context.operationID, ownerID: owner, index: index,
                                                     outcome: requested ? .cancelled : .failed)
                    return requested ? .cancelled : .failed
                }
                let stale = error as? Failure == .sourceChanged || error as? VoiceMemoTranscriptionError == .sourceChanged
                _ = try registry.finishBatchItem(context.operationID, ownerID: owner, index: index,
                                                 outcome: stale ? .stale : .failed)
                hadFailure = true
            }
        }
        return hadFailure ? .failed : .verified
    }

    /// Poll durable helper/native cancellation during recognition and drain provider
    /// teardown before the batch can acknowledge cancellation or release its capacity.
    private nonisolated static func generateWithCancellation(_ image: URL, provider: Provider,
        dependencies: Dependencies, context: AutomationOperationExecutionCoordinator.Context) async throws -> VoiceMemoTranscriptDraft {
        try await context.checkCancellation()
        return try await withThrowingTaskGroup(of: VoiceMemoTranscriptDraft.self) { group in
            group.addTask { try await dependencies.generate(image, provider) }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    try await context.checkCancellation()
                }
            }
            defer { group.cancelAll() }
            guard let draft = try await group.next() else { throw Failure.invalidDraft }
            return draft
        }
    }
}

/// Native filesystem admission, deliberately separate from MCP root authority. Security
/// scope covers the complete stat/hash/relationship capture on an off-main serial worker.
private actor VoiceTranscriptionBatchInputReader {
    nonisolated let filesystemQueue = DispatchSerialQueue(label: "com.aagedal.photo-agent.transcription-batch-input", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    func capture(_ image: URL) async throws -> AutomationVoiceTranscriptionBatchService.Input {
        try Task.checkCancellation()
        let folder = image.deletingLastPathComponent()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard case .available(let association) = try VoiceMemoTranscriptionService.lookupRegularAssociation(for: image),
              association.memoURL.pathExtension.lowercased() == "wav" else {
            throw VoiceMemoTranscriptionError.relationshipUnavailable
        }
        let source = try await SourceImageRevision.capture(at: image)
        let memo = try await SourceImageRevision.capture(at: association.memoURL)
        try Task.checkCancellation()
        guard try VoiceMemoTranscriptionService.lookupRegularAssociation(for: image) == .available(association) else {
            throw AutomationVoiceTranscriptionBatchService.Failure.sourceChanged
        }
        return .init(imageURL: image, sourceRevision: source, association: association, memoRevision: memo)
    }
}
