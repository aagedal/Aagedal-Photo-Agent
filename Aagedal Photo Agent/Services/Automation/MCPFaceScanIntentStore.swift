import Foundation

/// Bounded app-session intent only. A retained entry authenticates neither native
/// consent nor durable execution; restarting the process discards every intent.
nonisolated final class MCPFaceScanIntentStore: @unchecked Sendable {
    enum Failure: String, LocalizedError {
        case unknownIntent = "unknown_face_scan_intent"
        case expiredIntent = "expired_face_scan_intent"
        case capacity = "face_scan_intent_capacity"
        case invalidClock = "invalid_face_scan_intent_clock"
        var errorDescription: String? {
            switch self {
            case .unknownIntent: "The face scan intent is unavailable. Prepare a new intent."
            case .expiredIntent: "The face scan intent expired or the clock moved backwards. Prepare a new intent."
            case .capacity: "The bounded face scan intent store is full. Wait for intents to expire."
            case .invalidClock: "The face scan intent clock is invalid."
            }
        }
    }

    struct Intent: Sendable {
        let id: UUID
        let createdAt: Date
        let expiresAt: Date
        let prepared: MCPFaceScanAdmissionService.PreparedFolder
    }

    static let lifetime: TimeInterval = 300
    private let lock = NSLock()
    private let admission: MCPFaceScanAdmissionService
    private let maximumIntents: Int
    private let maximumRetainedPhotos: Int
    private let clock: @Sendable () -> Date
    private var intents: [UUID: Intent] = [:]

    init(admission: MCPFaceScanAdmissionService, maximumIntents: Int = 16,
         maximumRetainedPhotos: Int = 20_000, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.admission = admission
        self.maximumIntents = min(max(0, maximumIntents), 16)
        self.maximumRetainedPhotos = min(max(0, maximumRetainedPhotos), 20_000)
        self.clock = clock
    }

    func prepare(arguments: [String: MCPJSONValue]) throws -> Intent {
        let start = try now()
        let prepared = try admission.prepare(arguments: arguments)
        let end = try now()
        guard end >= start, end < start.addingTimeInterval(Self.lifetime) else { throw Failure.expiredIntent }
        let intent = Intent(id: UUID(), createdAt: start, expiresAt: start.addingTimeInterval(Self.lifetime), prepared: prepared)
        return try lock.withLock {
            intents = intents.filter { $0.value.expiresAt > end }
            let count = intents.values.reduce(0) { $0 + $1.prepared.imageURLs.count }
            guard intents.count < maximumIntents, count + prepared.imageURLs.count <= maximumRetainedPhotos else {
                throw Failure.capacity
            }
            intents[intent.id] = intent
            return intent
        }
    }

    /// Inspection recaptures the whole set; successful inspection creates no lease
    /// beyond its return and grants no mutation permission.
    func inspect(id: UUID) throws -> Intent {
        let intent = try lookup(id)
        _ = try admission.revalidate(intent.prepared)
        _ = try lookup(id)
        return intent
    }

    /// Future native consent/durable admission can hold this reservation across
    /// suspension. Admission expiry is rechecked after acquiring its complete set;
    /// already retained work checks authority independently of intent expiry.
    func retain(id: UUID) throws -> MCPFaceScanAdmissionService.RetainedFolder {
        let intent = try lookup(id)
        let retained = try admission.retain(intent.prepared)
        do { _ = try lookup(id); return retained }
        catch { retained.release(); throw error }
    }

    func checkAuthority(_ intent: Intent) throws { try admission.checkAuthority(intent.prepared) }

    private func now() throws -> Date {
        let value = clock()
        guard value.timeIntervalSince1970.isFinite else { throw Failure.invalidClock }
        return value
    }

    private func lookup(_ id: UUID) throws -> Intent {
        let time = try now()
        return try lock.withLock {
            guard let intent = intents[id] else { throw Failure.unknownIntent }
            guard time >= intent.createdAt, time < intent.expiresAt else { throw Failure.expiredIntent }
            return intent
        }
    }
}
