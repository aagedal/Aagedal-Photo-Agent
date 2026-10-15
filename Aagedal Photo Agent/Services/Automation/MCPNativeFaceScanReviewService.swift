import Foundation

/// Native process/session-only consent. Neither review nor approval is serializable or
/// exposed to the helper. Physical scanner publication remains path based; this service
/// binds consent and authority but does not claim descriptor-anchored mutation.
nonisolated final class MCPNativeFaceScanReviewService: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case changedReview, acknowledgementRequired, unavailableApproval, expiredApproval, invalidClock
    }

    struct Review: Sendable {
        let intent: MCPFaceScanIntentStore.Intent
        let consequences: [String]
        fileprivate let generation: UUID
        fileprivate let preparedAt: ContinuousClock.Instant
        fileprivate let deadline: ContinuousClock.Instant
    }

    struct Approval: Sendable, Equatable {
        let id: UUID
        let intentID: UUID
        let expiresAt: Date
        fileprivate let generation: UUID
        fileprivate let approvedAt: Date
    }

    private struct Entry {
        let approval: Approval
        let intent: MCPFaceScanIntentStore.Intent
        let approvedAt: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        var consumed: Bool
    }

    private let lock = NSRecursiveLock()
    private let intents: MCPFaceScanIntentStore
    private let operations: MCPFaceScanOperationService
    /// Must refuse when the app's native review session or authorization is withdrawn.
    /// Supply a current session validator, never a helper-provided confirmation value.
    private let validateSession: @Sendable () throws -> Void
    private let clock: @Sendable () -> Date
    private let monotonicClock: @Sendable () -> ContinuousClock.Instant
    private var generation = UUID()
    private var currentReview: UUID?
    private var entry: Entry?

    init(intents: MCPFaceScanIntentStore, operations: MCPFaceScanOperationService,
         validateSession: @escaping @Sendable () throws -> Void,
         clock: @escaping @Sendable () -> Date = Date.init,
         monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.intents = intents; self.operations = operations
        self.validateSession = validateSession; self.clock = clock
        self.monotonicClock = monotonicClock
    }

    /// Replacing the visible review revokes all prior session capabilities, including
    /// active effect permission. Preparation does not grant consent or schedule work.
    func prepare(arguments: [String: MCPJSONValue]) throws -> Review {
        try prepare { try self.intents.prepare(arguments: arguments) }
    }

    /// Review the exact retained request, never a replacement captured from its path
    /// or options. This grants no consent and does not renew the original intent lifetime.
    func prepare(intentID: UUID) throws -> Review {
        try prepare { try self.intents.inspect(id: intentID) }
    }

    private func prepare(intent: () throws -> MCPFaceScanIntentStore.Intent) throws -> Review {
        let preparationGeneration = lock.withLock { revokeLocked(); return generation }
        // Inventory I/O must not hold the capability lock: dismissal and withdrawal
        // remain immediate while the caller prepares on its background executor.
        try validateSession()
        let preparedAt = monotonicClock()
        let deadline = preparedAt.advanced(by: .seconds(MCPFaceScanIntentStore.lifetime))
        let intent = try intent()
        _ = try intents.inspect(id: intent.id)
        try validateSession()
        let checkedAt = monotonicClock()
        guard checkedAt >= preparedAt, checkedAt < deadline else { throw Failure.expiredApproval }
        var consequences = [
            "Scans every listed immediate photo locally for faces; optional jersey recognition uses the exact reviewed options.",
            "Execution can create face thumbnails, embeddings and folder face data. Cancellation does not undo committed effects.",
            "Physical scanner writes currently use paths. This consent does not establish descriptor-anchored publication."
        ]
        if intent.prepared.forceFullScan {
            consequences.append("A full scan resets existing folder face results and may delete their thumbnails before replacing results.")
        }
        return try lock.withLock {
            guard generation == preparationGeneration else { throw Failure.changedReview }
            try validateSession()
            currentReview = intent.id
            return Review(intent: intent, consequences: consequences, generation: generation,
                          preparedAt: preparedAt, deadline: deadline)
        }
    }

    /// Only an explicit native action after showing the exact review may invoke this.
    /// Reset acknowledgement is mandatory for full/jersey scans. Reapproval replaces
    /// the previous token; a consumed token cannot be reapproved or replayed.
    func approve(_ review: Review, acknowledgesScan: Bool, acknowledgesReset: Bool) throws -> Approval {
        try lock.withLock {
            guard review.generation == generation, currentReview == review.intent.id,
                  entry?.consumed != true else { throw Failure.changedReview }
            guard acknowledgesScan, !review.intent.prepared.forceFullScan || acknowledgesReset else {
                entry = nil
                throw Failure.acknowledgementRequired
            }
        }
        do {
            try validateSession()
            let beforeInspection = monotonicClock()
            guard beforeInspection >= review.preparedAt, beforeInspection < review.deadline else {
                throw Failure.expiredApproval
            }
            let current = try intents.inspect(id: review.intent.id)
            guard current.prepared.snapshotRevision == review.intent.prepared.snapshotRevision else {
                throw Failure.changedReview
            }
            let now = try checkedNow()
            guard now >= current.createdAt, now < current.expiresAt else { throw Failure.expiredApproval }
            let monotonicNow = monotonicClock()
            guard monotonicNow >= beforeInspection, monotonicNow < review.deadline else {
                throw Failure.expiredApproval
            }
            return try lock.withLock {
                guard review.generation == generation, currentReview == review.intent.id,
                      entry?.consumed != true else { throw Failure.changedReview }
                try validateSession()
                let approval = Approval(id: UUID(), intentID: current.id, expiresAt: current.expiresAt,
                                        generation: generation, approvedAt: now)
                entry = Entry(approval: approval, intent: current, approvedAt: monotonicNow,
                              deadline: review.deadline, consumed: false)
                return approval
            }
        } catch {
            lock.withLock { if generation == review.generation { revokeLocked() } }
            throw error
        }
    }

    /// Admission consumes exactly once, even if durable admission later fails. The
    /// retained capability remains checked through scanner read/effect boundaries until
    /// its actual task drains. Preview expiry no longer interrupts admitted work.
    @concurrent
    func submit(_ approval: Approval) async throws -> AutomationOperationRegistry.Record {
        // Consume atomically before inventory I/O or any suspension. Neither a
        // competing submit nor failed recapture can replay this approval.
        let intent = try lock.withLock {
            guard let current = entry, current.approval == approval, !current.consumed else {
                throw Failure.unavailableApproval
            }
            entry?.consumed = true
            return current.intent
        }
        do {
            _ = try validateApproval(approval, admission: true)
            _ = try intents.inspect(id: approval.intentID)
            _ = try validateApproval(approval, admission: true)
            return try await operations.submit(intentID: intent.id, nativeAdmission: { [self] candidate in
                let current = try validateApproval(approval, admission: false)
                guard candidate.id == current.id,
                      candidate.prepared.snapshotRevision == current.prepared.snapshotRevision else {
                    throw Failure.unavailableApproval
                }
            }, nativeCompletion: { [self] in revoke(approval) })
        } catch { revoke(approval); throw error }
    }

    /// Filesystem/configuration checks happen outside the capability lock. Check
    /// process-session state on both sides so withdrawal never waits for path I/O
    /// and stale checks cannot restore authority.
    private func validateApproval(_ approval: Approval, admission: Bool) throws -> MCPFaceScanIntentStore.Intent {
        do {
            let intent = try lock.withLock {
                guard let current = entry, current.approval == approval, current.consumed else {
                    throw Failure.unavailableApproval
                }
                try requireCurrent(current, admission: admission)
                return current.intent
            }
            try intents.checkAuthority(intent)
            return try lock.withLock {
                guard let current = entry, current.approval == approval, current.consumed else {
                    throw Failure.unavailableApproval
                }
                try requireCurrent(current, admission: admission)
                return current.intent
            }
        } catch { revoke(approval); throw error }
    }

    func revoke(_ approval: Approval) {
        lock.withLock { if entry?.approval == approval { revokeLocked() } }
    }

    /// Call on dismissal, native session change, authorization change or withdrawal.
    func revokeAll() { lock.withLock { revokeLocked() } }

    private func requireCurrent(_ current: Entry, admission: Bool) throws {
        guard current.approval.generation == generation else { throw Failure.unavailableApproval }
        let now = try checkedNow()
        guard now >= current.approval.approvedAt else { throw Failure.expiredApproval }
        if admission {
            let monotonicNow = monotonicClock()
            guard now < current.approval.expiresAt, monotonicNow >= current.approvedAt,
                  monotonicNow < current.deadline else { throw Failure.expiredApproval }
        }
        try validateSession()
    }

    private func checkedNow() throws -> Date {
        let now = clock()
        guard now.timeIntervalSince1970.isFinite else { throw Failure.invalidClock }
        return now
    }

    private func revokeLocked() {
        entry = nil; currentReview = nil; generation = UUID()
    }
}
