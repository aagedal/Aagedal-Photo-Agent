import CryptoKit
import Foundation

nonisolated enum DevelopTemplateBatchAdmissionFailure: Error, Equatable, Sendable {
    case invalidEvidence, changedEvidence, unavailableReview, alreadyConsumed, corruptJournal, unsupportedEmbeddedAdmission
}

/// Durable review evidence is deliberately not a deserializable write request. Restart
/// inspection can explain a captured batch, but cannot manufacture native consent.
nonisolated struct DevelopTemplateBatchAdmissionEvidence: Codable, Sendable {
    struct Photo: Codable, Sendable {
        let requestID: UUID
        let url: URL
        let rootID: UUID
        let targetIdentity: MCPFileIdentity
        let sourceRevision: String
        let xmpRevision: String
        let appRevision: String
        let isRAW: Bool
        let neutralTemperature: Double?
        let neutralTint: Double?
        let sourceHasHDRHeadroom: Bool?
    }
    let formatVersion: Int
    let batchID: UUID
    let template: DevelopTemplate
    let templateRevision: String
    let authorizationConfiguration: MCPAuthorizationConfiguration
    /// Native caller fingerprints the concrete writer policy and decoder configuration.
    /// A protocol preview or an editor selection is never this capability.
    let configurationRevision: String
    let photos: [Photo]
    let originalIntentData: Data

    init(capture: DevelopTemplateBatchCapture, configurationRevision: String) throws {
        guard !configurationRevision.isEmpty, configurationRevision.utf8.count <= 4_096,
              capture.template.id == capture.intent.templateID,
              capture.photos.count == capture.intent.requests.count,
              zip(capture.photos, capture.intent.requests).allSatisfy({ $0.requestID == $1.id }) else {
            throw DevelopTemplateBatchAdmissionFailure.invalidEvidence
        }
        formatVersion = 1; batchID = capture.intent.id; template = capture.template
        templateRevision = capture.intent.templateRevision
        authorizationConfiguration = capture.authorizationConfiguration
        self.configurationRevision = configurationRevision
        photos = zip(capture.photos, capture.intent.requests).map { witness, request in
            Photo(requestID: witness.requestID, url: request.imageURL, rootID: witness.rootID,
                targetIdentity: witness.targetIdentity, sourceRevision: witness.sourceRevision,
                xmpRevision: witness.xmpSidecarRevision, appRevision: witness.appSidecarRevision,
                isRAW: witness.decoder.isRAW, neutralTemperature: witness.decoder.neutralTemperature,
                neutralTint: witness.decoder.neutralTint, sourceHasHDRHeadroom: witness.decoder.sourceHasHDRHeadroom)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        originalIntentData = try encoder.encode(DevelopTemplateBatchExecutionResult(intent: capture.intent,
            results: Array(repeating: nil, count: capture.intent.requests.count)).recoveryPayload)
    }
}

nonisolated struct DevelopTemplateBatchAdmissionJournal: Codable, Sendable {
    enum State: String, Codable, Sendable { case awaitingReview, consumed, cancelled }
    let formatVersion: Int
    let batchID: UUID
    let evidenceData: Data
    let evidenceSHA256: String
    let state: State
}

/// Separate from physical checkpoints so a cancelled review can never be mistaken for
/// an execution receipt. Anchored, locked transactions make consumption cross-instance.
actor DevelopTemplateBatchAdmissionStore {
    static let maximumEvidenceBytes = 16_777_216
    static let maximumStorageBytes = 67_108_864
    static let maximumEntries = 128
    private struct Registry: Codable {
        let formatVersion: Int
        var journals: [DevelopTemplateBatchAdmissionJournal]
    }
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func retain(_ evidence: DevelopTemplateBatchAdmissionEvidence) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        guard data.count <= Self.maximumEvidenceBytes else {
            throw DevelopTemplateBatchFailure.retentionLimit
        }
        let digest = Self.hash(data)
        try persistence().transaction { existing in
            var registry = try Self.registry(existing)
            if let journal = registry.journals.first(where: { $0.batchID == evidence.batchID }) {
                guard journal.evidenceData == data else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
                guard journal.state == .awaitingReview else { throw DevelopTemplateBatchAdmissionFailure.alreadyConsumed }
                return ((), try Self.encode(registry))
            }
            guard registry.journals.count < Self.maximumEntries else { throw DevelopTemplateBatchFailure.retentionLimit }
            let journal = DevelopTemplateBatchAdmissionJournal(formatVersion: 1, batchID: evidence.batchID,
                evidenceData: data, evidenceSHA256: digest, state: .awaitingReview)
            registry.journals.append(journal)
            return ((), try Self.encode(registry))
        }
        return digest
    }

    func load(_ id: UUID) throws -> DevelopTemplateBatchAdmissionJournal {
        try persistence().transaction(readOnly: true) { existing in
            let registry = try Self.registry(existing)
            guard let existing, let journal = registry.journals.first(where: { $0.batchID == id }) else {
                throw DevelopTemplateBatchAdmissionFailure.corruptJournal
            }
            return (journal, existing)
        }
    }

    func finishReview(_ id: UUID, digest: String, cancelled: Bool) throws {
        try persistence().transaction { existing in
            var registry = try Self.registry(existing)
            guard let index = registry.journals.firstIndex(where: { $0.batchID == id }) else {
                throw DevelopTemplateBatchAdmissionFailure.corruptJournal
            }
            let journal = registry.journals[index]
            guard journal.evidenceSHA256 == digest else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
            guard journal.state == .awaitingReview else { throw DevelopTemplateBatchAdmissionFailure.alreadyConsumed }
            let next = DevelopTemplateBatchAdmissionJournal(formatVersion: 1, batchID: id,
                evidenceData: journal.evidenceData, evidenceSHA256: digest,
                state: cancelled ? .cancelled : .consumed)
            registry.journals[index] = next
            return ((), try Self.encode(registry))
        }
    }

    private func persistence() -> AutomationOperationPersistence {
        .init(directory: directory, maximumBytes: Self.maximumStorageBytes)
    }
    private static func encode(_ registry: Registry) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        guard data.count <= maximumStorageBytes else { throw DevelopTemplateBatchFailure.retentionLimit }
        return data
    }
    private static func registry(_ data: Data?) throws -> Registry {
        guard let data else { return Registry(formatVersion: 1, journals: []) }
        guard data.count <= maximumStorageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "journals"],
              let values = object["journals"] as? [[String: Any]],
              values.allSatisfy({ Set($0.keys) == ["formatVersion", "batchID", "evidenceData", "evidenceSHA256", "state"] }),
              let registry = try? JSONDecoder().decode(Registry.self, from: data),
              registry.formatVersion == 1, registry.journals.count <= maximumEntries,
              Set(registry.journals.map(\.batchID)).count == registry.journals.count else {
            throw DevelopTemplateBatchAdmissionFailure.corruptJournal
        }
        for journal in registry.journals { try validate(journal) }
        return registry
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validate(_ journal: DevelopTemplateBatchAdmissionJournal) throws {
        let evidenceKeys: Set<String> = ["formatVersion", "batchID", "template", "templateRevision",
            "authorizationConfiguration", "configurationRevision", "photos", "originalIntentData"]
        let photoKeys: Set<String> = ["requestID", "url", "rootID", "targetIdentity", "sourceRevision",
            "xmpRevision", "appRevision", "isRAW", "neutralTemperature", "neutralTint", "sourceHasHDRHeadroom"]
        guard journal.formatVersion == 1,
              journal.evidenceData.count <= maximumEvidenceBytes,
              journal.evidenceSHA256 == hash(journal.evidenceData),
              let object = try? JSONSerialization.jsonObject(with: journal.evidenceData) as? [String: Any],
              Set(object.keys) == evidenceKeys,
              let photos = object["photos"] as? [[String: Any]],
              photos.allSatisfy({ Set($0.keys).isSubset(of: photoKeys) }),
              let evidence = try? JSONDecoder().decode(DevelopTemplateBatchAdmissionEvidence.self, from: journal.evidenceData),
              evidence.formatVersion == 1, evidence.batchID == journal.batchID,
              !evidence.photos.isEmpty, evidence.photos.count <= DevelopTemplateBatchIntent.maximumPhotos,
              Set(evidence.photos.map(\.requestID)).count == evidence.photos.count,
              !evidence.configurationRevision.isEmpty else {
            throw DevelopTemplateBatchAdmissionFailure.corruptJournal
        }
    }
}

/// Only this process's independent capture can become a native review. Tokens are opaque,
/// tied to the service instance, and removed before any await that can reenter the actor.
actor DevelopTemplateBatchAdmissionService {
    struct Review: Sendable, Identifiable {
        let id: UUID
        let evidence: DevelopTemplateBatchAdmissionEvidence
        fileprivate let token: UUID
    }
    typealias ConfigurationRevision = @Sendable () throws -> String
    typealias NativeConsent = @Sendable (DevelopTemplateBatchAdmissionEvidence) async throws -> Void
    typealias SessionValidation = @Sendable (DevelopTemplateBatchAdmissionEvidence) throws -> Void
    private struct Pending: Sendable {
        let capture: DevelopTemplateBatchCapture
        let digest: String
        let token: UUID
    }
    private var pending: [UUID: Pending] = [:]
    private let captureService: DevelopTemplateBatchCaptureService
    private let store: DevelopTemplateBatchAdmissionStore
    private let configurationRevision: ConfigurationRevision
    private let validateSession: SessionValidation

    init(captureService: DevelopTemplateBatchCaptureService, store: DevelopTemplateBatchAdmissionStore,
         configurationRevision: @escaping ConfigurationRevision,
         validateSession: @escaping SessionValidation) {
        self.captureService = captureService; self.store = store
        self.configurationRevision = configurationRevision
        self.validateSession = validateSession
    }

    func review(_ capture: DevelopTemplateBatchCapture) async throws -> Review {
        try Task.checkCancellation()
        // Embedded workers need an explicit owned-effect stage before their original
        // inode can be retired. Until that is wired, native admission is sidecar-only.
        guard capture.intent.requests.allSatisfy({
            !DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: $0.imageURL,
                requestedMode: $0.mode).writesEmbedded
        }) else { throw DevelopTemplateBatchAdmissionFailure.unsupportedEmbeddedAdmission }
        guard pending.count < 16, pending[capture.intent.id] == nil else {
            throw DevelopTemplateBatchAdmissionFailure.unavailableReview
        }
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: capture,
            configurationRevision: configurationRevision())
        try validateAuthority(capture, evidence: evidence)
        try validateCarriers(capture)
        let token = UUID()
        // Reserve actor ownership before durable retention yields.
        pending[capture.intent.id] = Pending(capture: capture, digest: "", token: token)
        do {
            let digest = try await store.retain(evidence)
            try Task.checkCancellation()
            pending[capture.intent.id] = Pending(capture: capture, digest: digest, token: token)
            return Review(id: capture.intent.id, evidence: evidence, token: token)
        } catch {
            pending.removeValue(forKey: capture.intent.id)
            throw error
        }
    }

    func cancel(_ review: Review) async throws {
        let entry = try take(review)
        try await store.finishReview(review.id, digest: entry.digest, cancelled: true)
    }

    func execute(_ review: Review, consent: @escaping NativeConsent,
                 executionService: DevelopTemplateBatchExecutionService,
                 checkpointStore: DevelopTemplateBatchCheckpointStore) async throws -> DevelopTemplateBatchExecutionResult {
        let entry = try take(review)
        // Consume first: cancelled consent, drift and process teardown cannot replay this
        // reviewed capture. A new attempt requires an independent capture and review.
        try await store.finishReview(review.id, digest: entry.digest, cancelled: false)
        try Task.checkCancellation()
        try validateAuthority(entry.capture, evidence: review.evidence)
        try validateCarriers(entry.capture)
        try await consent(review.evidence)
        try Task.checkCancellation()
        try validateAuthority(entry.capture, evidence: review.evidence)
        let service = captureService
        let revision = configurationRevision
        let session = validateSession
        return await executionService.execute(entry.capture.intent, validateAuthority: { _ in
            try Self.validateAuthority(entry.capture, evidence: review.evidence,
                captureService: service, configurationRevision: revision, validateSession: session)
        }, checkpointStore: checkpointStore, validateCapture: { _, reservations, requestIDs in
            try Self.validateCarriers(entry.capture, captureService: service, reservations: reservations,
                requestIDs: requestIDs)
        })
    }

    private func take(_ review: Review) throws -> Pending {
        guard let entry = pending[review.id], entry.token == review.token, !entry.digest.isEmpty else {
            throw DevelopTemplateBatchAdmissionFailure.unavailableReview
        }
        pending.removeValue(forKey: review.id)
        return entry
    }
    private func validateCarriers(_ capture: DevelopTemplateBatchCapture) throws {
        try Self.validateCarriers(capture, captureService: captureService, reservations: [:],
            requestIDs: Set(capture.intent.requests.map(\.id)))
    }
    private static func validateCarriers(_ capture: DevelopTemplateBatchCapture,
        captureService: DevelopTemplateBatchCaptureService, reservations: [UUID: MCPProcessReservationLease],
        requestIDs: Set<UUID>) throws {
        // Keep earlier anchored snapshots open until the entire ordered set is checked.
        func validate(_ index: Int) throws {
            try Task.checkCancellation()
            guard index < capture.intent.requests.count else { return }
            let request = capture.intent.requests[index], witness = capture.photos[index]
            guard requestIDs.contains(request.id) else { try validate(index + 1); return }
            try captureService.facade.withPhotoSnapshot(path: request.imageURL.path,
                reservation: reservations[request.id]) { current in
                guard current.target.rootID == witness.rootID, current.target.identity == witness.targetIdentity,
                      current.sourceRevision == witness.sourceRevision,
                      current.xmpSidecarRevision == witness.xmpSidecarRevision,
                      current.appSidecarRevision == witness.appSidecarRevision else {
                    throw DevelopTemplateBatchAdmissionFailure.changedEvidence
                }
                let decoder = try captureService.resolveDecoder(current.sourceBytes, current.target.url)
                guard decoder.isRAW == witness.decoder.isRAW,
                      decoder.neutralTemperature == witness.decoder.neutralTemperature,
                      decoder.neutralTint == witness.decoder.neutralTint,
                      decoder.sourceHasHDRHeadroom == witness.decoder.sourceHasHDRHeadroom else {
                    throw DevelopTemplateBatchAdmissionFailure.changedEvidence
                }
                try validate(index + 1)
            }
        }
        try validate(0)
    }
    private func validateAuthority(_ capture: DevelopTemplateBatchCapture,
                                   evidence: DevelopTemplateBatchAdmissionEvidence) throws {
        try Self.validateAuthority(capture, evidence: evidence, captureService: captureService,
            configurationRevision: configurationRevision, validateSession: validateSession)
    }
    private static func validateAuthority(_ capture: DevelopTemplateBatchCapture,
        evidence: DevelopTemplateBatchAdmissionEvidence, captureService: DevelopTemplateBatchCaptureService,
        configurationRevision: ConfigurationRevision, validateSession: SessionValidation) throws {
        try validateSession(evidence)
        guard try captureService.facade.authorizationStore.load() == capture.authorizationConfiguration,
              evidence.authorizationConfiguration == capture.authorizationConfiguration else {
            throw DevelopTemplateBatchAdmissionFailure.changedEvidence
        }
        guard try configurationRevision() == evidence.configurationRevision else {
            throw DevelopTemplateBatchAdmissionFailure.changedEvidence
        }
        try captureService.discovery.withDevelopTemplate(id: capture.intent.templateID,
            revision: capture.intent.templateRevision) { template in
            guard template == capture.template else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
        }
        for (request, witness) in zip(capture.intent.requests, capture.photos) {
            let target = try captureService.facade.authorizationStore.authorizeExistingPath(request.imageURL.path)
            guard target.url == request.imageURL, target.rootID == witness.rootID else {
                throw DevelopTemplateBatchAdmissionFailure.changedEvidence
            }
        }
        guard try captureService.facade.authorizationStore.load() == capture.authorizationConfiguration else {
            throw DevelopTemplateBatchAdmissionFailure.changedEvidence
        }
        try validateSession(evidence)
    }
}
