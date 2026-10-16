import Foundation

/// Authenticated presentation of immutable durable face intent only. This service
/// has no scanner, model loader, approval, operation admission or execution API.
nonisolated struct AutomationNativeFaceScanReviewInvocationService: Sendable {
    struct Presentation: Equatable, Sendable {
        let record: MCPFaceScanReviewRequestStore.Record
        let imageURLs: [URL]
    }

    private let requests: MCPFaceScanReviewRequestStore
    private let admission: MCPFaceScanAdmissionService

    init(requests: MCPFaceScanReviewRequestStore, admission: MCPFaceScanAdmissionService) {
        self.requests = requests; self.admission = admission
    }

    func invoke(requestID: UUID, requestEpoch: UUID) throws -> Presentation {
        try Task.checkCancellation()
        let record = try requests.inspect(requestID, requestEpoch: requestEpoch)
        let prepared = try requests.revalidate(record, admission: admission)
        try admission.checkAuthority(prepared)
        try Task.checkCancellation()
        return Presentation(record: record, imageURLs: prepared.imageURLs)
    }

    /// Repeat after the UI handoff. No preparation date or monotonic witness is
    /// replaced, including when an app or helper process has restarted.
    func revalidate(_ expected: Presentation) throws -> Presentation {
        guard let id = UUID(uuidString: expected.record.requestID),
              let epoch = UUID(uuidString: expected.record.requestEpoch) else {
            throw MCPFaceScanReviewRequestStore.Failure.invalidStorage
        }
        let current = try invoke(requestID: id, requestEpoch: epoch)
        guard current == expected else { throw MCPFaceScanReviewRequestStore.Failure.conflictingRequest }
        return current
    }

    /// A final clock/witness-only publication fence. Filesystem validation has
    /// already run off-main; waiting for the main actor cannot renew its deadline.
    /// This creates no lease and makes no claim that external files stay frozen.
    func requireFreshForPublication(_ presentation: Presentation) throws {
        try requests.checkLifetime(presentation.record)
    }
}
