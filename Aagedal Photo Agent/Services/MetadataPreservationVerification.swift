import Foundation
import SwiftMediaMetadata

/// Source-vs-staged injection seam for the delivery coordinator. Implementations always return a
/// report: inability to parse is `.unknown`, allowing the coordinator to fail closed with typed
/// evidence instead of collapsing inspection failure into an unrelated operational exception.
nonisolated struct DeliveryStageMetadataPreservationVerifier: Sendable {
    let verify: @Sendable (
        _ sourceURL: URL,
        _ stagedBytes: Data,
        _ stagedURL: URL
    ) async -> MetadataPreservationVerificationReport

    static let liveRenderedDelivery = Self { sourceURL, stagedBytes, _ in
        await Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let source = try ImageMetadata.read(from: sourceURL)
                try Task.checkCancellation()
                let staged = try ImageMetadata.read(from: stagedBytes)
                let sourceSnapshot = MetadataPreservationSnapshotBuilder.makeSnapshot(
                    from: source,
                    policy: .renderedDelivery
                )
                let stagedSnapshot = MetadataPreservationSnapshotBuilder.makeSnapshot(
                    from: staged,
                    policy: .renderedDelivery
                )
                return MetadataPreservationComparator.compare(
                    source: sourceSnapshot,
                    staged: stagedSnapshot
                )
            } catch {
                return .unknown()
            }
        }.value
    }
}
