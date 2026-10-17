import CryptoKit
import Foundation

nonisolated enum DevelopTemplateBatchAdmissionFailure: Error, Equatable, Sendable {
    case invalidEvidence, changedEvidence, unavailableReview, alreadyConsumed, corruptJournal, unsupportedEmbeddedAdmission
    case cancellationCleanupRequired(UUID)
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

/// A read-only presentation record intentionally excludes serialized writer requests,
/// authority configuration and live review capabilities.
nonisolated struct DevelopTemplateBatchAdmissionInspection: Sendable, Identifiable {
    struct Photo: Sendable, Identifiable {
        let id: UUID
        let url: URL
        let sourceRevision: String
        let xmpRevision: String
        let appRevision: String
    }
    let id: UUID
    let state: DevelopTemplateBatchAdmissionJournal.State
    let templateName: String
    let templateID: UUID
    let templateRevision: String
    let photos: [Photo]
}

/// Exact cancelled records reviewed for retirement. Digests are retained permanently;
/// cleanup never grants authority or retires uncertain physical execution evidence.
nonisolated struct DevelopTemplateBatchAdmissionCleanupPreview: Sendable {
    fileprivate struct Record: Codable, Sendable, Equatable {
        let batchID: UUID
        let evidenceSHA256: String
    }
    fileprivate let records: [Record]
    let cancelledCaptures: [DevelopTemplateBatchAdmissionInspection]
    let tombstoneCount: Int
    var cancelledCount: Int { records.count }
    var availableTombstones: Int { DevelopTemplateBatchAdmissionStore.maximumTombstones - tombstoneCount }
}

/// Separate from physical checkpoints so a cancelled review can never be mistaken for
/// an execution receipt. Anchored, locked transactions make consumption cross-instance.
actor DevelopTemplateBatchAdmissionStore {
    nonisolated let queue = DispatchSerialQueue(label: "com.aagedal.photo-agent.develop-admission-storage", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    static let maximumEvidenceBytes = 16_777_216
    static let maximumStorageBytes = 67_108_864
    static let maximumEntries = 128
    static let maximumTombstones = 4_096
    private struct Registry: Codable {
        let formatVersion: Int
        var journals: [DevelopTemplateBatchAdmissionJournal]
        var tombstones: [DevelopTemplateBatchAdmissionCleanupPreview.Record]
    }
    private let directory: URL
    private let afterRetain: @Sendable () throws -> Void
    private let afterFinishReview: @Sendable () throws -> Void
    init(directory: URL, afterRetain: @escaping @Sendable () throws -> Void = {},
         afterFinishReview: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory
        self.afterRetain = afterRetain; self.afterFinishReview = afterFinishReview
    }

    nonisolated static func evidenceDigest(_ evidence: DevelopTemplateBatchAdmissionEvidence) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(evidence))
    }

    static func defaultStorageDirectory(applicationSupportDirectory: URL? = nil,
                                        arguments: [String] = ProcessInfo.processInfo.arguments) throws -> URL {
        if arguments.contains("--ui-testing") {
            guard let index = arguments.firstIndex(of: "--ui-test-develop-admission-root"),
                  arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/"),
                  !arguments[index + 1].contains("\0") else {
                throw AutomationOperationRegistry.Failure.storageUnavailable
            }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        guard let base = applicationSupportDirectory
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              base.isFileURL, base.path.hasPrefix("/") else {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        return base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("DevelopAdmissions", isDirectory: true)
    }

    /// Historical evidence only. No token, executable request or consent can be
    /// reconstructed from this projection. Missing storage is never created.
    func inspect() throws -> [DevelopTemplateBatchAdmissionInspection] {
        try persistence().transaction(readOnly: true) { existing in
            let registry = try Self.registry(existing)
            let reviews = try registry.journals.map(Self.inspection)
            return (reviews, existing ?? Data())
        }
    }

    func prepareCancelledCleanup() throws -> DevelopTemplateBatchAdmissionCleanupPreview {
        try persistence().transaction(readOnly: true) { existing in
            let registry = try Self.registry(existing)
            let captures = try registry.journals.filter { $0.state == .cancelled }.map(Self.inspection)
            return (.init(records: Self.cancelledRecords(registry), cancelledCaptures: captures,
                          tombstoneCount: registry.tombstones.count),
                    existing ?? Data())
        }
    }

    /// Atomically retires exactly the cancelled evidence displayed in the preview.
    /// New cancellations require a refreshed review; capacity never evicts tombstones.
    @discardableResult
    func cleanupCancelledReviews(_ preview: DevelopTemplateBatchAdmissionCleanupPreview) throws -> Int {
        try Task.checkCancellation()
        return try persistence().transaction(readOnly: preview.records.isEmpty) { existing in
            var registry = try Self.registry(existing)
            guard Self.cancelledRecords(registry) == preview.records,
                  registry.tombstones.count == preview.tombstoneCount else {
                throw DevelopTemplateBatchAdmissionFailure.changedEvidence
            }
            guard !preview.records.isEmpty else { return (0, existing ?? Data()) }
            guard registry.tombstones.count + preview.records.count <= Self.maximumTombstones else {
                throw DevelopTemplateBatchFailure.retentionLimit
            }
            try Task.checkCancellation()
            registry.tombstones.append(contentsOf: preview.records)
            registry.journals.removeAll { $0.state == .cancelled }
            return (preview.records.count, try Self.encode(registry))
        }
    }

    private static func inspection(_ journal: DevelopTemplateBatchAdmissionJournal) throws -> DevelopTemplateBatchAdmissionInspection {
        let evidence = try JSONDecoder().decode(DevelopTemplateBatchAdmissionEvidence.self, from: journal.evidenceData)
        return DevelopTemplateBatchAdmissionInspection(id: journal.batchID, state: journal.state,
            templateName: evidence.template.name, templateID: evidence.template.id,
            templateRevision: evidence.templateRevision,
            photos: evidence.photos.map { .init(id: $0.requestID, url: $0.url,
                sourceRevision: $0.sourceRevision, xmpRevision: $0.xmpRevision,
                appRevision: $0.appRevision) })
    }

    private static func cancelledRecords(_ registry: Registry) -> [DevelopTemplateBatchAdmissionCleanupPreview.Record] {
        registry.journals.filter { $0.state == .cancelled }.map {
            .init(batchID: $0.batchID, evidenceSHA256: $0.evidenceSHA256)
        }
    }

    func retain(_ evidence: DevelopTemplateBatchAdmissionEvidence) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        guard data.count <= Self.maximumEvidenceBytes else {
            throw DevelopTemplateBatchFailure.retentionLimit
        }
        let digest = Self.hash(data)
        try persistence().transaction { existing in
            var registry = try Self.registry(existing)
            guard !registry.tombstones.contains(where: { $0.batchID == evidence.batchID }) else {
                throw DevelopTemplateBatchAdmissionFailure.alreadyConsumed
            }
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
        try afterRetain()
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
            guard !registry.tombstones.contains(where: { $0.batchID == id }) else {
                throw DevelopTemplateBatchAdmissionFailure.alreadyConsumed
            }
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
        try afterFinishReview()
    }

    /// Cancellation owns no execution authority. Exact terminal evidence (including
    /// a consumed admission whose write returned an error) is preserved, never reset.
    /// Missing evidence means a failed retain did not leave a journal to retire.
    func retireReview(_ id: UUID, digest: String) throws {
        try persistence().transaction { existing in
            var registry = try Self.registry(existing)
            if let retired = registry.tombstones.first(where: { $0.batchID == id }) {
                guard retired.evidenceSHA256 == digest else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
                return ((), existing ?? Data())
            }
            guard let index = registry.journals.firstIndex(where: { $0.batchID == id }) else {
                return ((), try existing ?? Self.encode(registry))
            }
            let journal = registry.journals[index]
            guard journal.evidenceSHA256 == digest else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
            guard journal.state == .awaitingReview else { return ((), existing ?? Data()) }
            registry.journals[index] = .init(formatVersion: 1, batchID: id,
                evidenceData: journal.evidenceData, evidenceSHA256: digest, state: .cancelled)
            return ((), try Self.encode(registry))
        }
        try afterFinishReview()
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
        guard let data else { return Registry(formatVersion: 2, journals: [], tombstones: []) }
        struct Header: Decodable { let formatVersion: Int }
        guard data.count <= maximumStorageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = try? JSONDecoder().decode(Header.self, from: data).formatVersion,
              (version == 1 && Set(object.keys) == ["formatVersion", "journals"])
                || (version == 2 && Set(object.keys) == ["formatVersion", "journals", "tombstones"]),
              let values = object["journals"] as? [[String: Any]],
              values.count <= maximumEntries,
              values.allSatisfy({ Set($0.keys) == ["formatVersion", "batchID", "evidenceData", "evidenceSHA256", "state"] }),
              let journalData = try? JSONSerialization.data(withJSONObject: values),
              let journals = try? JSONDecoder().decode([DevelopTemplateBatchAdmissionJournal].self, from: journalData),
              Set(journals.map(\.batchID)).count == journals.count else {
            throw DevelopTemplateBatchAdmissionFailure.corruptJournal
        }
        var tombstones: [DevelopTemplateBatchAdmissionCleanupPreview.Record] = []
        if version == 2 {
            guard let values = object["tombstones"] as? [[String: Any]],
                  values.count <= maximumTombstones,
                  values.allSatisfy({ Set($0.keys) == ["batchID", "evidenceSHA256"] }),
                  let encoded = try? JSONSerialization.data(withJSONObject: values),
                  let decoded = try? JSONDecoder().decode([DevelopTemplateBatchAdmissionCleanupPreview.Record].self, from: encoded),
                  decoded.allSatisfy({ $0.evidenceSHA256.utf8.count == 64 && $0.evidenceSHA256.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  } }),
                  Set(decoded.map(\.batchID)).count == decoded.count,
                  Set(decoded.map(\.batchID)).isDisjoint(with: journals.map(\.batchID)) else {
                throw DevelopTemplateBatchAdmissionFailure.corruptJournal
            }
            tombstones = decoded
        }
        for journal in journals { try validate(journal) }
        // V1 is projected in memory; inspection never silently migrates stored bytes.
        return Registry(formatVersion: 2, journals: journals, tombstones: tombstones)
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
    nonisolated let queue = DispatchSerialQueue(label: "com.aagedal.photo-agent.develop-admission-review", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

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
    /// Failed compensation retains ownership, but never an executable review token.
    private var cancelledCleanup: [UUID: String] = [:]
    private var cleanupInFlight: Set<UUID> = []
    private var executionInFlight: Set<UUID> = []
    private let captureService: DevelopTemplateBatchCaptureService
    private let store: DevelopTemplateBatchAdmissionStore
    private let configurationRevision: ConfigurationRevision
    private let validateSession: SessionValidation
    private let afterRetention: @Sendable () async throws -> Void

    init(captureService: DevelopTemplateBatchCaptureService, store: DevelopTemplateBatchAdmissionStore,
         configurationRevision: @escaping ConfigurationRevision,
         validateSession: @escaping SessionValidation,
         afterRetention: @escaping @Sendable () async throws -> Void = {}) {
        self.captureService = captureService; self.store = store
        self.configurationRevision = configurationRevision
        self.validateSession = validateSession
        self.afterRetention = afterRetention
    }

    func review(_ capture: DevelopTemplateBatchCapture, expectedConfigurationRevision: String? = nil) async throws -> Review {
        try Task.checkCancellation()
        // Embedded workers need an explicit owned-effect stage before their original
        // inode can be retired. Until that is wired, native admission is sidecar-only.
        guard capture.intent.requests.allSatisfy({
            !DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: $0.imageURL,
                requestedMode: $0.mode).writesEmbedded
        }) else { throw DevelopTemplateBatchAdmissionFailure.unsupportedEmbeddedAdmission }
        guard pending.count + executionInFlight.count < 16,
              pending[capture.intent.id] == nil, !executionInFlight.contains(capture.intent.id) else {
            throw DevelopTemplateBatchAdmissionFailure.unavailableReview
        }
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: capture,
            configurationRevision: configurationRevision())
        guard expectedConfigurationRevision == nil || expectedConfigurationRevision == evidence.configurationRevision else {
            throw DevelopTemplateBatchAdmissionFailure.changedEvidence
        }
        try validateAuthority(capture, evidence: evidence)
        try validateCarriers(capture)
        let token = UUID()
        // Compute before suspension: retain can commit and still throw while syncing
        // or revalidating its directory. Cleanup must cover that uncertain return too.
        let retainedDigest = try DevelopTemplateBatchAdmissionStore.evidenceDigest(evidence)
        // Reserve actor ownership before durable retention yields.
        pending[capture.intent.id] = Pending(capture: capture, digest: "", token: token)
        var didRetain = false
        do {
            let digest = try await store.retain(evidence)
            didRetain = true
            try await afterRetention()
            // Retention suspends the actor. Never publish a capability from evidence
            // that changed while its journal was being committed.
            try validateAuthority(capture, evidence: evidence)
            try validateCarriers(capture)
            try Task.checkCancellation()
            pending[capture.intent.id] = Pending(capture: capture, digest: digest, token: token)
            return Review(id: capture.intent.id, evidence: evidence, token: token)
        } catch {
            // These are validation refusals before the persistence commit. They do
            // not entitle this attempt to retire somebody else's conflicting evidence.
            if !didRetain, error is DevelopTemplateBatchAdmissionFailure || error is DevelopTemplateBatchFailure {
                pending.removeValue(forKey: capture.intent.id)
                throw error
            }
            do {
                // Mandatory compensation also runs on a cancelled task. The store
                // changes only this exact awaiting-review digest, never physical receipts.
                try await store.retireReview(capture.intent.id, digest: retainedDigest)
            } catch {
                cancelledCleanup[capture.intent.id] = retainedDigest
                throw DevelopTemplateBatchAdmissionFailure.cancellationCleanupRequired(capture.intent.id)
            }
            pending.removeValue(forKey: capture.intent.id)
            throw error
        }
    }

    var cancelledReviewCleanupIDs: Set<UUID> { Set(cancelledCleanup.keys).union(cleanupInFlight) }

    /// Retries only failed review retirement. No Review or consent can be
    /// reconstructed from these entries. Capacity remains reserved until it succeeds.
    func retryCancelledReviewCleanup() async throws {
        for id in Array(cancelledCleanup.keys) {
            guard let digest = cancelledCleanup.removeValue(forKey: id) else { continue }
            cleanupInFlight.insert(id)
            do {
                try await store.retireReview(id, digest: digest)
                pending.removeValue(forKey: id)
                cleanupInFlight.remove(id)
            } catch {
                cleanupInFlight.remove(id)
                cancelledCleanup[id] = digest
                throw DevelopTemplateBatchAdmissionFailure.cancellationCleanupRequired(id)
            }
        }
    }

    func cancel(_ review: Review) async throws {
        guard let entry = pending[review.id], entry.token == review.token,
              !entry.digest.isEmpty, !cleanupInFlight.contains(review.id) else {
            throw DevelopTemplateBatchAdmissionFailure.unavailableReview
        }
        // Withdraw execution before storage suspends. A failed cancellation retains
        // only cleanup authority, so native dismissal can safely retry the same review.
        cleanupInFlight.insert(review.id)
        defer { cleanupInFlight.remove(review.id) }
        do {
            try await store.retireReview(review.id, digest: entry.digest)
            cancelledCleanup.removeValue(forKey: review.id)
            pending.removeValue(forKey: review.id)
        } catch {
            cancelledCleanup[review.id] = entry.digest
            throw DevelopTemplateBatchAdmissionFailure.cancellationCleanupRequired(review.id)
        }
    }

    func execute(_ review: Review, consent: @escaping NativeConsent,
                 executionService: DevelopTemplateBatchExecutionService,
                 checkpointStore: DevelopTemplateBatchCheckpointStore) async throws -> DevelopTemplateBatchExecutionResult {
        let entry = try take(review)
        executionInFlight.insert(review.id)
        defer { executionInFlight.remove(review.id) }
        // Consume first: cancelled consent, drift and process teardown cannot replay this
        // reviewed capture. A new attempt requires an independent capture and review.
        do {
            try await store.finishReview(review.id, digest: entry.digest, cancelled: false)
        } catch {
            // A refused/uncertain durable admission cannot restore Start authority.
            // Preserve the original digest for cleanup rather than orphaning an
            // awaiting-review journal when storage was temporarily unavailable.
            pending[review.id] = entry
            cancelledCleanup[review.id] = entry.digest
            throw DevelopTemplateBatchAdmissionFailure.cancellationCleanupRequired(review.id)
        }
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
        guard let entry = pending[review.id], entry.token == review.token, !entry.digest.isEmpty,
              cancelledCleanup[review.id] == nil, !cleanupInFlight.contains(review.id) else {
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
