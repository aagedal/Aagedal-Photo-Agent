import CryptoKit
import Darwin
import Foundation

/// Native session bridge. Retained helper intent is evidence to review; preparation
/// grants no consent. Only the explicit native-consent entry point admits work.
actor MCPNativeVoiceTranscriptionBindingService {
    enum Failure: Error, Equatable {
        case requestChanged
        case invalidRequestState
        case nativeInputChanged
        case providerUnavailable
        case consentRequired
    }

    nonisolated struct PreparedBinding: Sendable {
        let request: MCPVoiceTranscriptionReviewRequestStore.Record
        let batch: AutomationVoiceTranscriptionBatchService.PreparedBatch
        let providerBinding: AutomationVoiceTranscriptionProviderBinding
        fileprivate init(request: MCPVoiceTranscriptionReviewRequestStore.Record,
                         batch: AutomationVoiceTranscriptionBatchService.PreparedBatch,
                         providerBinding: AutomationVoiceTranscriptionProviderBinding) {
            self.request = request; self.batch = batch; self.providerBinding = providerBinding
        }
    }

    nonisolated let filesystemQueue = DispatchSerialQueue(label: "com.aagedal.photo-agent.native-transcription-binding", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    private let requests: MCPVoiceTranscriptionReviewRequestStore
    private let plans: MCPVoiceTranscriptionPlanStore
    private let facade: MCPAutomationFacade
    private let batches: AutomationVoiceTranscriptionBatchService
    /// Mandatory native dependency: validate current availability, authorization and
    /// selected runtime/model artifacts without downloading or requesting permission.
    private let readiness: @Sendable (AutomationVoiceTranscriptionProviderBinding) async throws -> Void
    private let now: @Sendable () -> Date

    init(requests: MCPVoiceTranscriptionReviewRequestStore, plans: MCPVoiceTranscriptionPlanStore,
         facade: MCPAutomationFacade, batches: AutomationVoiceTranscriptionBatchService,
         readiness: @escaping @Sendable (AutomationVoiceTranscriptionProviderBinding) async throws -> Void,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.requests = requests; self.plans = plans; self.facade = facade; self.batches = batches
        self.readiness = readiness; self.now = now
    }

    func prepare(requestID: UUID, requestEpoch: UUID, provider: AutomationVoiceTranscriptionBatchService.Provider,
                 whisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind? = nil) async throws -> PreparedBinding {
        try Task.checkCancellation()
        let request = try requests.inspect(requestID, requestEpoch: requestEpoch)
        try requireCurrent(request)
        try validateRooted(request, batch: nil)
        let binding = try AutomationVoiceTranscriptionProviderBinding.bind(intent: request.intent,
            provider: provider, whisperKind: whisperKind)
        let urls = try request.intent.photos.map { photo -> URL in
            guard let path = photo["path"]?.stringValue else { throw Failure.nativeInputChanged }
            return URL(fileURLWithPath: path)
        }
        let batch = try await batches.prepare(imageURLs: urls)
        try await requireReadiness(binding)
        try Task.checkCancellation()
        // Both awaits permit request, authority, metadata and source changes. Publish
        // only after the complete original set has been reserved and checked again.
        try validateRooted(request, batch: batch)
        return PreparedBinding(request: request, batch: batch, providerBinding: binding)
    }

    func revalidate(_ prepared: PreparedBinding) async throws {
        try Task.checkCancellation()
        try requireCurrent(prepared.request)
        try prepared.providerBinding.requireMatches(intent: prepared.request.intent)
        try await batches.revalidate(prepared: prepared.batch)
        try await requireReadiness(prepared.providerBinding)
        try Task.checkCancellation()
        try validateRooted(prepared.request, batch: prepared.batch)
    }

    /// Called only by the native provider-review flow after explicit consent to this
    /// retained request, ordered batch and concrete provider. The helper never calls
    /// this entry point or receives the session-only binding or rooted reservation.
    func submit(prepared: PreparedBinding, nativeConsent: Bool) async throws -> AutomationOperationRegistry.Record {
        guard nativeConsent else { throw Failure.consentRequired }
        try await revalidate(prepared)
        let reservation = try plans.retainExecutionPreview(planID: prepared.request.planID, facade: facade, now: now())
        var handedOff = false
        defer { if !handedOff { reservation.release() } }
        try Self.requireDraftAbsence(prepared, reservation: reservation)
        let id = UUID(), registry = batches.operationRegistry
        let requests = requests, now = now
        guard let requestID = UUID(uuidString: prepared.request.requestID),
              let epoch = UUID(uuidString: prepared.request.requestEpoch) else { throw Failure.requestChanged }
        let lifecycle = AutomationVoiceTranscriptionBatchService.LifecycleHooks(operationID: id, admission: { owner in
            try Task.checkCancellation()
            try reservation.withValidatedPreview(now: now()) { preview in
                try Self.requirePrepared(prepared, preview: preview)
                try Self.requireDraftAbsence(prepared, reservation: reservation)
                _ = try requests.admit(requestID, requestEpoch: epoch, expected: prepared.request,
                    operationID: id, ownerID: owner, registry: registry, now: now())
            }
        }, didEnqueue: { record in
            guard record.id == id else { throw Failure.requestChanged }
            try reservation.withValidatedPreview(now: now()) { preview in
                try Self.requirePrepared(prepared, preview: preview)
                _ = try requests.link(requestID, requestEpoch: epoch, operationID: id, registry: registry, now: now())
            }
        }, cancellationCheck: { operationID in
            guard operationID == id else { throw Failure.requestChanged }
            try Self.requireLinkedRequest(prepared.request, requests: requests, registry: registry, operationID: id)
        })
        let executionGuard = AutomationVoiceTranscriptionBatchService.ExecutionGuard(check: {
            try await self.checkExecution(prepared, reservation: reservation, operationID: id)
        }, poll: {
            try await self.pollExecution(prepared, reservation: reservation, operationID: id)
        }, save: { draft, input in
            try await self.saveRooted(draft, input: input, prepared: prepared, reservation: reservation, operationID: id)
        }, finish: { reservation.release() })
        let record = try await batches.submit(prepared: prepared.batch, provider: prepared.providerBinding.provider,
            lifecycle: lifecycle, executionGuard: executionGuard)
        handedOff = true
        return record
    }

    func waitForCompletion(_ operationID: UUID) async throws -> AutomationOperationRegistry.Record {
        try await batches.waitForCompletion(operationID)
    }

    func shutdown() async throws { try await batches.shutdown() }

    private func checkExecution(_ prepared: PreparedBinding,
        reservation: MCPVoiceTranscriptionPlanStore.ExecutionReservation, operationID: UUID) async throws {
        try requireExecutionRequest(prepared.request, operationID: operationID)
        try prepared.providerBinding.requireMatches(intent: prepared.request.intent)
        try reservation.validate()
        try await requireReadiness(prepared.providerBinding)
        // Readiness can suspend for native or artifact checks. Recheck the complete
        // retained rooted generation and exact cancellation link before inference.
        try requireExecutionRequest(prepared.request, operationID: operationID)
        try reservation.validate()
        try Task.checkCancellation()
    }

    private func pollExecution(_ prepared: PreparedBinding,
        reservation: MCPVoiceTranscriptionPlanStore.ExecutionReservation, operationID: UUID) throws {
        try requireExecutionRequest(prepared.request, operationID: operationID)
        try reservation.checkAuthority()
        try Task.checkCancellation()
    }

    private func requireExecutionRequest(_ expected: MCPVoiceTranscriptionReviewRequestStore.Record, operationID: UUID) throws {
        guard let id = UUID(uuidString: expected.requestID), let epoch = UUID(uuidString: expected.requestEpoch) else {
            throw Failure.requestChanged
        }
        let current = try requests.inspect(id, requestEpoch: epoch)
        if current.state == .awaitingReview { try requireCurrent(expected) }
        else { try Self.requireLinkedRequest(expected, requests: requests, registry: batches.operationRegistry, operationID: operationID) }
    }

    private nonisolated static func requireLinkedRequest(_ expected: MCPVoiceTranscriptionReviewRequestStore.Record,
        requests: MCPVoiceTranscriptionReviewRequestStore, registry: AutomationOperationRegistry, operationID: UUID) throws {
        guard let id = UUID(uuidString: expected.requestID), let epoch = UUID(uuidString: expected.requestEpoch) else {
            throw Failure.requestChanged
        }
        let current = try requests.inspect(id, requestEpoch: epoch)
        guard current.intent == expected.intent, current.intentSHA256 == expected.intentSHA256,
              current.batchIdentity == expected.batchIdentity, current.createdAt == expected.createdAt,
              current.state == .linked, current.operationID == operationID.uuidString.lowercased(),
              let admission = current.admission, admission.operationID == current.operationID else { throw Failure.requestChanged }
        let operation = try registry.inspect(operationID)
        guard operation.kind == .voiceTranscription, operation.ownerLeaseManaged == true,
              operation.ownerID.uuidString.lowercased() == admission.ownerID,
              operation.batchProgress?.itemCount == expected.intent.photoCount else { throw Failure.requestChanged }
        if current.cancellationRequestedAt != nil {
            // Only this exact durable link may project native/helper request cancellation
            // onto history. This allows truthful cancelled acknowledgement after teardown.
            if operation.cancellationRequestedAt == nil { _ = try registry.requestCancellation(operationID) }
            throw CancellationError()
        }
        try requests.checkCancellation(id, requestEpoch: epoch, operationID: operationID)
    }

    private nonisolated static func requirePrepared(_ prepared: PreparedBinding, preview: MCPJSONValue) throws {
        guard try MCPVoiceTranscriptionReviewRequestStore.Intent(preview: preview) == prepared.request.intent else {
            throw Failure.requestChanged
        }
        try prepared.providerBinding.requireMatches(intent: prepared.request.intent)
        guard prepared.batch.inputSnapshots.count == prepared.request.intent.photos.count else { throw Failure.nativeInputChanged }
        for (input, photo) in zip(prepared.batch.inputSnapshots, prepared.request.intent.photos) {
            try requireNativeMatches(input, photo: photo)
        }
    }

    private nonisolated static func requireDraftAbsence(_ prepared: PreparedBinding,
        reservation: MCPVoiceTranscriptionPlanStore.ExecutionReservation) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for input in prepared.batch.inputSnapshots {
            guard let data = try reservation.snapshot(for: input.imageURL).appSidecarBytes else { continue }
            let metadata = try decoder.decode(MetadataSidecar.self, from: data)
            guard metadata.sourceFile == input.imageURL.lastPathComponent,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VoiceMemoTranscriptionError.invalidGeneratedDraft
            }
            guard object[MetadataSidecarService.voiceMemoTranscriptFieldName] == nil else {
                throw VoiceMemoTranscriptionError.existingTranscript
            }
        }
    }

    private func saveRooted(_ draft: VoiceMemoTranscriptDraft, input: AutomationVoiceTranscriptionBatchService.Input,
        prepared: PreparedBinding, reservation: MCPVoiceTranscriptionPlanStore.ExecutionReservation,
        operationID: UUID) async throws -> VoiceMemoTranscriptDraft {
        // The ordinary live save acquires its own photo lease; use the exact retained
        // rooted installer here and the same in-process metadata serialization instead.
        try Self.requireProviderDraft(draft, binding: prepared.providerBinding)
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: input.imageURL)) {
            do { try await self.checkExecution(prepared, reservation: reservation, operationID: operationID) }
            catch is CancellationError { throw AutomationVoiceTranscriptionBatchService.Failure.cancelledBeforeSave }
            catch { throw AutomationVoiceTranscriptionBatchService.Failure.guardRefused }
            return try await self.installRooted(draft, input: input, prepared: prepared,
                reservation: reservation, operationID: operationID)
        }
    }

    private func installRooted(_ draft: VoiceMemoTranscriptDraft, input: AutomationVoiceTranscriptionBatchService.Input,
        prepared: PreparedBinding, reservation: MCPVoiceTranscriptionPlanStore.ExecutionReservation,
        operationID: UUID) throws -> VoiceMemoTranscriptDraft {
        do {
            try requireExecutionRequest(prepared.request, operationID: operationID)
            try Task.checkCancellation()
        } catch is CancellationError { throw AutomationVoiceTranscriptionBatchService.Failure.cancelledBeforeSave }
        do { try reservation.validate() }
        catch { throw AutomationVoiceTranscriptionBatchService.Failure.guardRefused }
        let snapshot = try reservation.snapshot(for: input.imageURL)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let original = try snapshot.appSidecarBytes ?? encoder.encode(MetadataSidecar(sourceFile: input.imageURL.lastPathComponent))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MetadataSidecar.self, from: original)
        guard metadata.sourceFile == input.imageURL.lastPathComponent,
              var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw VoiceMemoTranscriptionError.invalidGeneratedDraft
        }
        guard object[MetadataSidecarService.voiceMemoTranscriptFieldName] == nil else { throw VoiceMemoTranscriptionError.existingTranscript }
        let transcript = VoiceMemoTranscriptRecord(sourceImageFilename: input.imageURL.lastPathComponent,
            sourceMemoFilename: input.association.memoURL.lastPathComponent, memoByteCount: draft.memoByteCount,
            memoSHA256: draft.memoSHA256, associationProfileIdentifier: draft.associationProfileIdentifier,
            localeIdentifier: draft.localeIdentifier, provider: draft.provider, providerModel: draft.providerModel,
            generatedAt: draft.generatedAt, generatedText: draft.generatedText, reviewedText: draft.reviewedText,
            approvedAt: nil, whisperProvenance: draft.whisperProvenance)
        let encoded = try encoder.encode(transcript)
        object[MetadataSidecarService.voiceMemoTranscriptFieldName] = try JSONSerialization.jsonObject(with: encoded)
        let patched = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let requests = requests, registry = batches.operationRegistry
        try reservation.installDraft(data: patched, photoURL: input.imageURL, beforeInstall: {
            do {
                try Task.checkCancellation()
                try Self.requireLinkedRequest(prepared.request, requests: requests, registry: registry, operationID: operationID)
            } catch is CancellationError { throw AutomationVoiceTranscriptionBatchService.Failure.cancelledBeforeSave }
        })
        // Rooted installation verified these exact bytes and promoted only its own
        // app carrier generation. Decode the durable representation, including dates.
        let saved = try decoder.decode(VoiceMemoTranscriptRecord.self, from: encoded)
        return .init(imageURL: input.imageURL, memoURL: input.association.memoURL,
            memoByteCount: saved.memoByteCount, memoSHA256: saved.memoSHA256,
            associationProfileIdentifier: saved.associationProfileIdentifier, localeIdentifier: saved.localeIdentifier,
            provider: saved.provider, providerModel: saved.providerModel, generatedAt: saved.generatedAt,
            generatedText: saved.generatedText, reviewedText: saved.reviewedText, approvedAt: saved.approvedAt,
            whisperProvenance: saved.whisperProvenance)
    }

    private nonisolated static func requireProviderDraft(_ draft: VoiceMemoTranscriptDraft,
        binding: AutomationVoiceTranscriptionProviderBinding) throws {
        switch binding.identity {
        case .apple(let locale):
            guard draft.localeIdentifier.replacingOccurrences(of: "_", with: "-").lowercased() == locale,
                  draft.provider == "Apple on-device speech", draft.providerModel == "System managed; exact version unavailable",
                  draft.whisperProvenance == nil else { throw VoiceMemoTranscriptionError.invalidGeneratedDraft }
        case .whisper(_, let configuration):
            guard let provenance = draft.whisperProvenance else { throw VoiceMemoTranscriptionError.invalidGeneratedDraft }
            do { try provenance.validate() }
            catch { throw VoiceMemoTranscriptionError.invalidGeneratedDraft }
            let expected = FFmpegWhisperTranscriptProvenance(buildIdentifier: configuration.buildIdentifier,
                executableSHA256: configuration.executable.sha256, executableByteCount: configuration.executable.byteCount,
                modelIdentifier: configuration.modelIdentifier, modelSHA256: configuration.model.sha256,
                modelByteCount: configuration.model.byteCount, requestedLanguage: configuration.language,
                useGPU: configuration.useGPU, translate: configuration.translate, segments: provenance.segments)
            guard provenance == expected, draft.localeIdentifier == configuration.language,
                  draft.provider == "FFmpeg Whisper", draft.providerModel == configuration.modelIdentifier,
                  draft.generatedText == provenance.editableText.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw VoiceMemoTranscriptionError.invalidGeneratedDraft
            }
        }
    }

    /// Production Apple availability check. Supply this explicitly at construction;
    /// tests may inject deterministic readiness. Whisper artifact authorization is
    /// always checked by requireReadiness before invoking this dependency.
    nonisolated static func liveReadiness(_ binding: AutomationVoiceTranscriptionProviderBinding) async throws {
        try Task.checkCancellation()
        switch binding.provider {
        case .apple(let locale):
            let availability = await VoiceMemoTranscriptionService().availability(preferredLocale: locale)
            let expected = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            guard availability.status == .installed,
                  availability.selectedLocale?.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == expected else {
                throw Failure.providerUnavailable
            }
        case .whisper: break
        }
        try Task.checkCancellation()
    }

    private func requireReadiness(_ binding: AutomationVoiceTranscriptionProviderBinding) async throws {
        if case .whisper(let provider) = binding.provider { try await provider.validateReadiness() }
        try await readiness(binding)
        try Task.checkCancellation()
    }

    private func requireCurrent(_ expected: MCPVoiceTranscriptionReviewRequestStore.Record) throws {
        guard let id = UUID(uuidString: expected.requestID), let epoch = UUID(uuidString: expected.requestEpoch) else {
            throw Failure.requestChanged
        }
        guard try requests.inspect(id, requestEpoch: epoch) == expected else { throw Failure.requestChanged }
        guard expected.state == .awaitingReview, expected.cancellationRequestedAt == nil,
              expected.admission == nil, expected.operationID == nil else { throw Failure.invalidRequestState }
    }

    private func validateRooted(_ request: MCPVoiceTranscriptionReviewRequestStore.Record,
                                batch: AutomationVoiceTranscriptionBatchService.PreparedBatch?) throws {
        try Task.checkCancellation()
        try requireCurrent(request)
        try plans.withValidatedPreview(planID: request.planID, facade: facade, now: now()) { preview in
            try requireCurrent(request)
            guard try MCPVoiceTranscriptionReviewRequestStore.Intent(preview: preview) == request.intent else {
                throw Failure.requestChanged
            }
            if let batch {
                guard batch.inputSnapshots.count == request.intent.photos.count else { throw Failure.nativeInputChanged }
                for (input, photo) in zip(batch.inputSnapshots, request.intent.photos) {
                    try Task.checkCancellation()
                    try Self.requireNativeMatches(input, photo: photo)
                }
            }
            try requireCurrent(request)
        }
        try requireCurrent(request)
        try Task.checkCancellation()
    }

    /// Reproduce the rooted source/WAV identity tokens, then compare the native
    /// capture's resource identity and bytes against those exact retained files.
    /// Equal paths or equal-byte replacements alone cannot satisfy this bridge.
    private nonisolated static func requireNativeMatches(_ input: AutomationVoiceTranscriptionBatchService.Input,
                                                         photo: [String: MCPJSONValue]) throws {
        guard photo["path"] == .string(input.imageURL.path),
              input.imageURL == input.sourceRevision.canonicalURL,
              input.association.imageURL == input.imageURL,
              input.relationshipRevision.url == VoiceMemoCompanionRepository().recordURL(for: input.imageURL).standardizedFileURL,
              input.association.memoURL == input.memoRevision.canonicalURL,
              input.association.memoURL.deletingLastPathComponent() == input.imageURL.deletingLastPathComponent(),
              input.association.memoURL.pathExtension.lowercased() == "wav",
              try VoiceMemoTranscriptionService.lookupRegularAssociation(for: input.imageURL) == .available(input.association) else {
            throw Failure.nativeInputChanged
        }
        try input.relationshipRevision.requireUnchanged()
        try requireFile(input.sourceRevision, revision: photo["sourceRevision"], identity: photo["photoIdentity"],
                        domain: "source", identityDomain: "voice-photo-identity", maximumBytes: 268_435_456)
        try requireFile(input.memoRevision, revision: photo["audioRevision"], identity: photo["audioIdentity"],
                        domain: "voice-memo-audio", identityDomain: "voice-audio-identity", maximumBytes: MCPVoiceMemoAdmission.maximumAudioBytes)
        try input.relationshipRevision.requireUnchanged()
    }

    private nonisolated static func requireFile(_ native: SourceImageRevision, revision: MCPJSONValue?,
        identity: MCPJSONValue?, domain: String, identityDomain: String, maximumBytes: Int64) throws {
        let url = native.canonicalURL
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.nativeInputChanged }
        defer { Darwin.close(descriptor) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximumBytes else { throw Failure.nativeInputChanged }
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey])
        guard let resourceID = native.fileResourceIdentifier,
              resourceID == SourceImageRevision.FileResourceIdentifier(foundationValue: values.fileResourceIdentifier),
              native.contentModificationDate == values.contentModificationDate,
              native.byteCount == before.st_size, native.byteCount == values.fileSize.map(Int64.init) else {
            throw Failure.nativeInputChanged
        }
        var rootedHash = SHA256(), contentHash = SHA256()
        rootedHash.update(data: Data("apa-mcp-revision-v1:\(domain):\(before.st_dev):\(before.st_ino):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec):".utf8))
        var buffer = [UInt8](repeating: 0, count: 65_536), count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let read = Darwin.read(descriptor, &buffer, buffer.count)
            if read < 0, errno == EINTR { continue }
            guard read >= 0, Int64(read) <= before.st_size - count else { throw Failure.nativeInputChanged }
            if read == 0 { break }
            let bytes = Data(buffer.prefix(read)); rootedHash.update(data: bytes); contentHash.update(data: bytes)
            count += Int64(read)
        }
        guard fstat(descriptor, &after) == 0, lstat(url.path, &named) == 0,
              facts(before) == facts(after), facts(after) == facts(named), count == before.st_size,
              native.sha256 == digest(contentHash.finalize()),
              revision == .string(digest(rootedHash.finalize())),
              identity == .string(digest(SHA256.hash(data: Data("\(identityDomain):\(before.st_dev):\(before.st_ino)".utf8)))) else {
            throw Failure.nativeInputChanged
        }
    }

    private nonisolated static func digest(_ value: SHA256.Digest) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func facts(_ value: stat) -> [String] {
        [String(value.st_dev), String(value.st_ino), String(value.st_mode), String(value.st_nlink), String(value.st_size),
         String(value.st_mtimespec.tv_sec), String(value.st_mtimespec.tv_nsec), String(value.st_ctimespec.tv_sec), String(value.st_ctimespec.tv_nsec)]
    }
}
