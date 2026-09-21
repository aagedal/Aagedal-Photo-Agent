import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Native verified XMP publication consent")
struct MCPIPTCPatchXMPPublicationApprovalStoreTests {
    private typealias Fixture = MCPIPTCPatchXMPPreflightServiceTests.Fixture
    private typealias Store = MCPIPTCPatchXMPPublicationApprovalStore

    private func candidate(_ fixture: Fixture) async throws -> (MCPIPTCPatchXMPPreflightService.Report, Data) {
        let bytes = MCPServerCoreTests.DataBox()
        let service = MCPIPTCPatchXMPPreflightService(plans: fixture.plans, facade: fixture.facade,
            hooks: .init(afterStaging: { bytes.write(try Data(contentsOf: $0)) }))
        let report = try await service.inspect(planID: fixture.planID)
        return (report, try #require(bytes.read()))
    }

    @Test("C2PA and pending draft consequences require independent native acknowledgement")
    func consequences() async throws {
        let fixture = try Fixture(pending: true)
        let (report, bytes) = try await candidate(fixture)
        let store = Store(plans: fixture.plans)
        let review = try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        #expect(review.consequences.contains { $0.contains("outside this patch") })
        #expect(throws: Store.Failure.missingAcknowledgement) {
            try store.approve(review, acknowledgesC2PAConsequences: false,
                acknowledgesPendingDraftPromotion: true, facade: fixture.facade)
        }
        #expect(throws: Store.Failure.missingAcknowledgement) {
            try store.approve(review, acknowledgesC2PAConsequences: true,
                acknowledgesPendingDraftPromotion: false, facade: fixture.facade)
        }
        let approval = try store.approve(review, acknowledgesC2PAConsequences: true,
            acknowledgesPendingDraftPromotion: true, facade: fixture.facade)
        let before = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let reservation = try MCPProcessReservation.acquirePhoto(fixture.photo)
        defer { reservation.release() }
        try store.validate(approval, candidate: bytes, mode: .xmpSidecar, targetPath: report.targetPath,
            facade: fixture.facade, reservation: reservation)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: reservation) { $0 }
        #expect(before.xmpBytes == after.xmpBytes)
        #expect(before.appSidecarBytes == after.appSidecarBytes)
        #expect(before.sourceBytes == after.sourceBytes)
    }

    @Test("Hash, size, path, expiry and source drift permanently revoke consent",
          arguments: ["hash", "size", "path", "expiry", "source", "authority"])
    func drift(kind: String) async throws {
        let fixture = try Fixture()
        let (report, bytes) = try await candidate(fixture)
        let store = Store(plans: fixture.plans)
        let review = try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        let approval = try store.approve(review, acknowledgesC2PAConsequences: true,
            acknowledgesPendingDraftPromotion: false, facade: fixture.facade)
        let original = try Data(contentsOf: fixture.photo)
        var wrong = bytes
        if kind == "hash" { wrong[wrong.startIndex] ^= 1 }
        if kind == "size" { wrong.append(0) }
        if kind == "source" { try Data("changed".utf8).write(to: fixture.photo) }
        if kind == "authority" { try fixture.facade.authorizationStore.setEnabled(false) }
        let reservation = try MCPProcessReservation.acquirePhoto(fixture.photo)
        defer { reservation.release() }
        #expect(throws: (any Error).self) {
            try store.validate(approval, candidate: wrong, mode: .xmpSidecar,
                targetPath: kind == "path" ? report.targetPath + ".other" : report.targetPath,
                facade: fixture.facade, reservation: reservation,
                now: kind == "expiry" ? approval.expiresAt : Date())
        }
        if kind == "source" { try original.write(to: fixture.photo) }
        if kind == "authority" { try fixture.facade.authorizationStore.setEnabled(true) }
        #expect(throws: Store.Failure.unavailableApproval) {
            try store.validate(approval, candidate: bytes, mode: .xmpSidecar, targetPath: report.targetPath,
                facade: fixture.facade, reservation: reservation)
        }
    }

    @Test("Reviews and receipts are store-local; revocation invalidates open reviews")
    func storeScope() async throws {
        let fixture = try Fixture()
        let (report, _) = try await candidate(fixture)
        let store = Store(plans: fixture.plans)
        let other = Store(plans: fixture.plans)
        let review = try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        #expect(throws: Store.Failure.unavailableApproval) {
            try other.approve(review, acknowledgesC2PAConsequences: true,
                acknowledgesPendingDraftPromotion: false, facade: fixture.facade)
        }
        store.revokeAll()
        #expect(throws: Store.Failure.unavailableApproval) {
            try store.approve(review, acknowledgesC2PAConsequences: true,
                acknowledgesPendingDraftPromotion: false, facade: fixture.facade)
        }
    }

    @Test("Preflight reports cannot be reviewed after a carrier changes")
    func staleReport() async throws {
        let fixture = try Fixture()
        let (report, _) = try await candidate(fixture)
        try Data("changed".utf8).write(to: fixture.photo)
        let store = Store(plans: fixture.plans)
        #expect(throws: (any Error).self) {
            try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        }
    }

    @Test("Consent revalidates authority and all carriers after the native review opens",
          arguments: ["authority", "source", "xmp", "app"])
    func driftDuringReview(kind: String) async throws {
        let fixture = try Fixture(pending: true)
        let (report, _) = try await candidate(fixture)
        let store = Store(plans: fixture.plans)
        let review = try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        switch kind {
        case "authority":
            try fixture.facade.authorizationStore.setEnabled(false)
            try fixture.facade.authorizationStore.setEnabled(true)
        case "source":
            try Data("changed source".utf8).write(to: fixture.photo)
        case "xmp":
            try Data("changed sidecar".utf8).write(to: URL(fileURLWithPath: report.targetPath))
        default:
            var metadata = try #require(XMPSidecarService().loadSidecar(for: fixture.photo))
            metadata.credit = "Changed while review is open"
            _ = try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: fixture.photo.lastPathComponent,
                pendingChanges: true, metadata: metadata, imageMetadataSnapshot: metadata),
                for: fixture.photo, in: fixture.root)
        }
        #expect(throws: (any Error).self) {
            try store.approve(review, acknowledgesC2PAConsequences: true,
                acknowledgesPendingDraftPromotion: true, facade: fixture.facade)
        }
    }

    @Test("Fresh consent for the same plan supersedes the previous receipt")
    func supersededConsent() async throws {
        let fixture = try Fixture()
        let (report, bytes) = try await candidate(fixture)
        let store = Store(plans: fixture.plans)
        let review = try store.review(report, mode: .xmpSidecar, facade: fixture.facade)
        let old = try store.approve(review, acknowledgesC2PAConsequences: true,
            acknowledgesPendingDraftPromotion: false, facade: fixture.facade)
        let current = try store.approve(review, acknowledgesC2PAConsequences: true,
            acknowledgesPendingDraftPromotion: false, facade: fixture.facade)
        let reservation = try MCPProcessReservation.acquirePhoto(fixture.photo)
        defer { reservation.release() }
        #expect(throws: Store.Failure.unavailableApproval) {
            try store.validate(old, candidate: bytes, mode: .xmpSidecar, targetPath: report.targetPath,
                facade: fixture.facade, reservation: reservation)
        }
        try store.validate(current, candidate: bytes, mode: .xmpSidecar, targetPath: report.targetPath,
            facade: fixture.facade, reservation: reservation)
    }
}
