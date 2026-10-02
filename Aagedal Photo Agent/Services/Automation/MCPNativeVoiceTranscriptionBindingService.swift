import CryptoKit
import Darwin
import Foundation

/// Read-only native session bridge. Retained helper intent is evidence to review;
/// preparing or revalidating this value never admits an operation or grants consent.
actor MCPNativeVoiceTranscriptionBindingService {
    enum Failure: Error, Equatable {
        case requestChanged
        case invalidRequestState
        case nativeInputChanged
        case providerUnavailable
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
