import Foundation
import Observation

/// A visible native review owns this revocable session. It is never reconstructed
/// from retained receipts or helper arguments. Actual writes retain the scanner's
/// existing path-based publication limits.
@MainActor @Observable
final class MCPNativeFaceScanReviewModel {
    /// Model loading, inventory checks and receipt reads may block. Retain the
    /// caller's task on a serial Dispatch executor rather than detaching its work.
    actor ReviewWorker {
        nonisolated let queue = DispatchSerialQueue(label: "com.aagedal.photo-agent.native-face-review", qos: .utility)
        nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

        func run<Value: Sendable>(_ body: @Sendable () throws -> Value) throws -> Value {
            try Task.checkCancellation()
            let result = try body()
            try Task.checkCancellation()
            return result
        }
    }

    nonisolated enum Failure: LocalizedError {
        case sessionWithdrawn, modelChanged, operationInProgress, durableExecutionUnavailable
        var errorDescription: String? {
            switch self {
            case .sessionWithdrawn: "The native review was dismissed. Prepare a new review."
            case .modelChanged: "Face model readiness changed. Prepare a new review after the model is available."
            case .operationInProgress: "Wait for the retained face scan to finish before preparing another review."
            case .durableExecutionUnavailable: "Scanning from retained client requests is not available yet."
            }
        }
    }

    nonisolated private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        private var model: FaceRecognitionModelAvailability?
        private var validateModel: (@Sendable () throws -> Void)?
        private let readiness: @Sendable () -> FaceRecognitionModelAvailability
        init(readiness: @escaping @Sendable () -> FaceRecognitionModelAvailability) { self.readiness = readiness }
        func begin(validateModel: @escaping @Sendable () throws -> Void) throws {
            let current = readiness()
            try lock.withLock {
                active = false; model = nil
                guard current.isAvailable else { throw Failure.modelChanged }
                try validateModel()
                self.validateModel = validateModel
                model = current; active = true
            }
        }
        func validate() throws {
            let current = readiness()
            try lock.withLock {
                guard active else { throw Failure.sessionWithdrawn }
                guard current.isAvailable, current == model else { throw Failure.modelChanged }
                try validateModel?()
            }
        }
        func withdraw() { lock.withLock { active = false; model = nil; validateModel = nil } }
    }

    private(set) var review: MCPNativeFaceScanReviewService.Review?
    var acknowledgesScan = false
    var acknowledgesReset = false
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var operation: AutomationOperationRegistry.Record?
    private(set) var receipt: MCPFaceScanReceiptStore.Receipt?
    private(set) var message: String?
    @ObservationIgnored private let session: Session
    @ObservationIgnored private let service: MCPNativeFaceScanReviewService
    @ObservationIgnored private let operations: MCPFaceScanOperationService
    @ObservationIgnored private let worker = ReviewWorker()
    @ObservationIgnored private let readReceipt: @Sendable (UUID) throws -> MCPFaceScanReceiptStore.Receipt?
    @ObservationIgnored private let modelPreflight: @Sendable () throws -> (@Sendable () throws -> Void)
    @ObservationIgnored private var generation = UUID()

    init(intents: MCPFaceScanIntentStore, operations: MCPFaceScanOperationService,
         receipts: MCPFaceScanReceiptStore,
         readiness: @escaping @Sendable () -> FaceRecognitionModelAvailability = { CoreMLFaceEmbedder.shared.availability },
         modelPreflight: @escaping @Sendable () throws -> (@Sendable () throws -> Void),
         readReceipt: (@Sendable (UUID) throws -> MCPFaceScanReceiptStore.Receipt?)? = nil) {
        let session = Session(readiness: readiness)
        self.session = session; self.operations = operations
        self.readReceipt = readReceipt ?? { id in try receipts.receipts().first { $0.operationID == id } }
        self.modelPreflight = modelPreflight
        service = .init(intents: intents, operations: operations, validateSession: { try session.validate() })
    }

    static func native(scanner: FaceRecognitionViewModel, authorizationStore: MCPAuthorizationStore,
                       operationDirectory: URL, receiptDirectory: URL) -> MCPNativeFaceScanReviewModel {
        let intents = MCPFaceScanIntentStore(admission: .init(authorizationStore: authorizationStore))
        let receipts = MCPFaceScanReceiptStore(storageDirectory: receiptDirectory)
        let operations = MCPFaceScanOperationService.native(intents: intents,
            registry: .init(storageDirectory: operationDirectory), receipts: receipts, scanner: scanner)
        return .init(intents: intents, operations: operations, receipts: receipts, modelPreflight: {
            let embedder = CoreMLFaceEmbedder.shared
            let capability = try embedder.prepareNativeScanModel()
            return { try embedder.validateNativeScanModel(capability) }
        })
    }

    /// Settings may adopt authenticated client evidence for native review. This
    /// factory deliberately has no scanner until durable effects are anchored.
    static func retainedReview(authorizationStore: MCPAuthorizationStore,
                               operationDirectory: URL, receiptDirectory: URL) -> MCPNativeFaceScanReviewModel {
        let intents = MCPFaceScanIntentStore(admission: .init(authorizationStore: authorizationStore))
        let receipts = MCPFaceScanReceiptStore(storageDirectory: receiptDirectory)
        let operations = MCPFaceScanOperationService(intents: intents,
            registry: .init(storageDirectory: operationDirectory), receipts: receipts,
            schedule: { _, _, _ in throw Failure.durableExecutionUnavailable })
        return .init(intents: intents, operations: operations, receipts: receipts, modelPreflight: {
            let embedder = CoreMLFaceEmbedder.shared
            let capability = try embedder.prepareNativeScanModel()
            return { try embedder.validateNativeScanModel(capability) }
        })
    }

    var canStart: Bool {
        review != nil && review?.intent.durableRequest == nil && !isRunning && !isPreparing && acknowledgesScan
            && (review?.intent.prepared.forceFullScan != true || acknowledgesReset)
    }

    var canCancel: Bool { isRunning && operation?.isTerminal == false }

    func prepare(folder: URL, forceFullScan: Bool, includeJerseyNumbers: Bool) async {
        await prepare { service in
            try service.prepare(arguments: ["path": .string(folder.path),
                "forceFullScan": .bool(forceFullScan), "includeJerseyNumbers": .bool(includeJerseyNumbers)])
        }
    }

    /// App-internal handoff for an already retained request. The caller must still
    /// authenticate helper presentation; the ID itself supplies no native consent.
    func prepare(intentID: UUID) async {
        await prepare { service in try service.prepare(intentID: intentID) }
    }

    /// The authenticated presentation is selected by native UI, never by helper
    /// confirmation. Adoption preserves original evidence and grants no consent.
    func prepare(record: MCPFaceScanReviewRequestStore.Record, requests: MCPFaceScanReviewRequestStore) async {
        await prepare { service in try service.prepare(record: record, requests: requests) }
    }

    private func prepare(
        _ prepareReview: @escaping @Sendable (MCPNativeFaceScanReviewService) throws -> MCPNativeFaceScanReviewService.Review
    ) async {
        guard !isRunning && !isPreparing else { message = Failure.operationInProgress.localizedDescription; return }
        dismiss()
        operation = nil; receipt = nil; message = nil
        let current = generation, service = self.service, session = self.session
        isPreparing = true
        defer { isPreparing = false }
        do {
            let preflight = modelPreflight
            let validateModel = try await worker.run { try preflight() }
            try Task.checkCancellation()
            guard current == generation else { return }
            try session.begin(validateModel: validateModel)
            let prepared = try await withTaskCancellationHandler {
                try await worker.run { try prepareReview(service) }
            } onCancel: { session.withdraw(); service.revokeAll() }
            try Task.checkCancellation()
            guard current == generation else { service.revokeAll(); return }
            review = prepared
        } catch {
            guard current == generation else { return }
            session.withdraw(); service.revokeAll(); message = error.localizedDescription
        }
    }

    /// Called only by the native start action. No approval escapes this model.
    /// A dismissed view still drains the retained operation; stale completion cannot
    /// repopulate its replacement review or regrant consent.
    func start() async {
        guard canStart, let review else { return }
        let current = generation
        guard !Task.isCancelled else { dismiss(); return }
        isRunning = true; message = "Admitting the reviewed face scan…"
        defer { isRunning = false }
        do {
            let service = self.service, scan = acknowledgesScan, reset = acknowledgesReset
            let approval = try await worker.run {
                try service.approve(review, acknowledgesScan: scan, acknowledgesReset: reset)
            }
            guard current == generation, !Task.isCancelled else { service.revoke(approval); dismiss(); return }
            self.review = nil
            acknowledgesScan = false; acknowledgesReset = false
            let admitted = try await service.submit(approval)
            // Preserve the exact ID even if dismissal occurred during admission, so
            // cancellation can target the retained task rather than another slot.
            operation = admitted
            if current == generation { message = "Face scan running. Cancellation preserves already committed effects." }
            let completed = try await operations.waitForCompletion(admitted.id)
            guard current == generation else { return }
            operation = completed
            message = "Loading the completed face scan receipt…"
            let readReceipt = self.readReceipt
            let retainedReceipt = try await worker.run {
                guard let retainedReceipt = try readReceipt(completed.id) else {
                    throw MCPFaceScanOperationService.Failure.missingCompletion
                }
                try retainedReceipt.requireCompletion(intent: review.intent, operation: completed)
                return retainedReceipt
            }
            guard current == generation else { return }
            try Task.checkCancellation()
            receipt = retainedReceipt
            message = Self.completionMessage(completed.outcome)
        } catch {
            guard current == generation else { return }
            self.review = nil; session.withdraw(); service.revokeAll()
            if operation?.isTerminal == true {
                message = "The face scan has finished, but its receipt could not be loaded: \(error.localizedDescription). Inspect retained operation history before retrying."
            } else {
                message = "Face scan stopped or could not be admitted: \(error.localizedDescription). Inspect retained receipts before retrying."
            }
        }
    }

    func cancel() async {
        guard canCancel, let operation else { return }
        let current = generation
        do {
            _ = try await operations.requestCancellation(operation.id)
            guard current == generation, self.operation?.isTerminal == false else { return }
            message = "Cancellation requested. Waiting for the retained scanner to finish."
        } catch {
            guard current == generation, self.operation?.isTerminal == false else { return }
            message = "Cancellation could not be recorded: \(error.localizedDescription). The scan may still be running."
        }
    }

    func dismiss() {
        generation = UUID(); session.withdraw(); service.revokeAll()
        review = nil; acknowledgesScan = false; acknowledgesReset = false
        message = nil
    }

    private static func completionMessage(_ outcome: AutomationOperationRegistry.Outcome?) -> String {
        switch outcome {
        case .verified: "Face scan completed. The retained receipt records committed effects."
        case .cancelled: "Face scan cancelled before committed effects."
        case .recoveryRequired, .partialUncertain: "Face scan requires review. Preserve the receipt and inspect saved face data before another scan."
        default: "Face scan did not complete successfully. Inspect the retained receipt before another scan."
        }
    }
}
