import Foundation

/// Presentation projections deliberately cannot reconstruct an executable write request.
nonisolated struct DevelopTemplateBatchRecoveryReview: Sendable, Identifiable {
    struct Photo: Sendable, Identifiable {
        let id: UUID
        let imageURL: URL
        let completed: Bool?
        let active: Bool
        let physicalEvidence: [String]
        let failure: String?
    }
    let id: String
    let issue: DevelopTemplateBatchCheckpointInventoryEntry.Issue?
    let outcome: DevelopTemplateBatchExecutionResult.Outcome?
    let sequence: UInt64?
    let templateID: UUID?
    let templateRevision: String?
    let needsReview: Bool
    let photos: [Photo]
    let failure: String?
    let unexpectedReceiptID: String?
    let unexpectedPhysicalEvidence: [String]
    let unexpectedFailure: String?
    let retentionFailure: String?
}

actor DevelopTemplateBatchRecoveryService {
    let store: DevelopTemplateBatchCheckpointStore

    init(store: DevelopTemplateBatchCheckpointStore) { self.store = store }

    func inspect() async throws -> [DevelopTemplateBatchRecoveryReview] {
        try await store.recoveryInventory().map { entry in
            do { return try project(entry) }
            catch { return .init(id: entry.id, issue: .corrupt, outcome: nil, sequence: nil,
                templateID: nil, templateRevision: nil, needsReview: true, photos: [],
                failure: nil, unexpectedReceiptID: nil, unexpectedPhysicalEvidence: [],
                unexpectedFailure: nil, retentionFailure: nil) }
        }
    }

    private func project(_ entry: DevelopTemplateBatchCheckpointInventoryEntry) throws -> DevelopTemplateBatchRecoveryReview {
        guard let checkpoint = entry.checkpoint else {
            return .init(id: entry.id, issue: entry.issue, outcome: nil, sequence: nil,
                templateID: nil, templateRevision: nil, needsReview: true, photos: [],
                failure: nil, unexpectedReceiptID: nil, unexpectedPhysicalEvidence: [],
                unexpectedFailure: nil, retentionFailure: nil)
        }
        guard let payload = try JSONSerialization.jsonObject(with: checkpoint.recoveryData) as? [String: Any],
              let template = payload["templateID"] as? String, let templateID = UUID(uuidString: template),
              let revision = payload["templateRevision"] as? String,
              let photos = payload["photos"] as? [[String: Any]],
              let completions = payload["resultCompletions"] as? [Any] else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        var projected: [DevelopTemplateBatchRecoveryReview.Photo] = []
        for (index, photo) in photos.enumerated() {
            guard let request = photo["requestID"] as? String, let id = UUID(uuidString: request),
                  let path = photo["imageURL"] as? String, let url = URL(string: path), url.isFileURL else {
                throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
            }
            projected.append(.init(id: id, imageURL: url, completed: completions[index] as? Bool,
                active: checkpoint.activeRequestID == id, physicalEvidence: physicalEvidence(photo),
                failure: photo["failure"] as? String))
        }
        let unexpected = payload["unexpectedReceipt"] as? [String: Any]
        let unexpectedEvidence = unexpected?["evidence"] as? [String: Any]
        return .init(id: entry.id, issue: nil, outcome: checkpoint.outcome, sequence: checkpoint.sequence,
            templateID: templateID, templateRevision: revision, needsReview: checkpoint.needsReview,
            photos: projected, failure: payload["failure"] as? String,
            unexpectedReceiptID: unexpected?["reportedRequestID"] as? String,
            unexpectedPhysicalEvidence: unexpectedEvidence.map(physicalEvidence) ?? [],
            unexpectedFailure: unexpectedEvidence?["failure"] as? String,
            retentionFailure: payload["retentionFailure"] as? String)
    }

    private func physicalEvidence(_ photo: [String: Any]) -> [String] {
        var evidence: [String] = []
        if photo["wroteEmbedded"] as? Bool == true { evidence.append("Embedded metadata written") }
        if photo["embeddedMayHaveBeenWritten"] as? Bool == true { evidence.append("Embedded metadata may have been written") }
        if photo["wroteXMP"] as? Bool == true { evidence.append("XMP written") }
        if photo["committedButUnverifiedJSON"] != nil { evidence.append("App metadata committed; verification incomplete") }
        if photo["installedRecord"] != nil { evidence.append("Verified app metadata receipt retained") }
        return evidence
    }
}
