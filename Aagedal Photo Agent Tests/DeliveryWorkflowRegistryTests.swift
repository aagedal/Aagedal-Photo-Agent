import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery workflow registry")
struct DeliveryWorkflowRegistryTests {
    @Test("concurrent creation atomically claims one canonical UUID directory without overwrite")
    func concurrentAtomicCreationAndNoOverwrite() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let first = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let second = DeliveryWorkflowRegistry(rootURL: fixture.root)

        async let a = capture {
            try await first.createWorkflow(
                plan: fixture.plan,
                workflowIdentifier: fixture.workflowID,
                createdAt: fixture.createdAt
            )
        }
        async let b = capture {
            try await second.createWorkflow(
                plan: fixture.plan,
                workflowIdentifier: fixture.workflowID,
                createdAt: fixture.createdAt
            )
        }
        let results = await [a, b]
        #expect(results.filter(\.isSuccess).count == 1)
        #expect(results.filter { result in
            guard case let .failure(error) = result else { return false }
            return error as? DeliveryWorkflowRegistryError == .workflowAlreadyExists
        }.count == 1)

        let locations = try await first.locations(for: fixture.workflowID)
        #expect(locations.workflowRootURL.lastPathComponent
            == fixture.workflowID.uuidString.lowercased())
        #expect(try DeliveryPlanIO().importPlan(from: locations.planDocumentURL) == fixture.plan)
        #expect(try permissions(locations.workflowRootURL) & 0o777 == 0o700)
        #expect(try permissions(locations.stagingRootURL) & 0o777 == 0o700)
        #expect(try permissions(locations.planDocumentURL) & 0o777 == 0o600)
        #expect(try permissions(locations.manifestDocumentURL) & 0o777 == 0o600)

        await #expect(throws: DeliveryWorkflowRegistryError.workflowAlreadyExists) {
            try await first.createWorkflow(
                plan: fixture.plan,
                workflowIdentifier: fixture.workflowID
            )
        }
        #expect(try DeliveryPlanIO().importPlan(from: locations.planDocumentURL) == fixture.plan)
    }

    @Test("relaunch reconstructs the exact plan, profile, staging root, and coordinator factories")
    func relaunchReconstruction() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID,
            remoteStatPolicy: .attemptIfAvailable,
            createdAt: fixture.createdAt
        )
        let staging = try fixture.installStaging(at: locations)
        try await fixture.reference(staging: staging, at: locations)
        #expect(try permissions(locations.manifestDocumentURL) & 0o777 == 0o600)
        #expect(try permissions(locations.stagingEvidenceDocumentURL) & 0o777 == 0o600)

        let relaunched = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let record = try await relaunched.resumeRecord(for: fixture.workflowID)
        #expect(record.plan == fixture.plan)
        #expect(record.currentProfile == fixture.plan.profile)
        #expect(record.stagingRootURL == locations.stagingRootURL)
        #expect(record.stagingResult == staging)
        #expect(record.request.workflowIdentifier == fixture.workflowID)
        #expect(record.request.plan == fixture.plan)
        #expect(record.request.currentProfile == fixture.plan.profile)
        #expect(record.request.remoteStatPolicy == .attemptIfAvailable)
        #expect(try await record.locations.manifestPersistence.load() != nil)
        #expect(try await record.locations.stagingEvidencePersistence.load()?.stagingResult == staging)
    }

    @Test("discovery repairs only the intentional evidence-before-manifest crash window")
    func crashWindowAndPartialDiscovery() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID,
            createdAt: fixture.createdAt
        )
        let staging = try fixture.installStaging(at: locations)
        try await locations.stagingEvidencePersistence.save(
            DeliveryWorkflowStagingEvidenceDocument(
                workflowIdentifier: fixture.workflowID,
                planFingerprint: fixture.plan.fingerprint,
                stagingResult: staging
            )
        )
        var manifest = try #require(await locations.manifestPersistence.load())
        manifest.stage = .preservationVerifying
        manifest.updatedAt = fixture.createdAt.addingTimeInterval(1)
        try await locations.manifestPersistence.save(manifest)

        #expect(try await registry.resumeRecord(for: fixture.workflowID).stagingResult == staging)

        let incompleteFixture = try await RegistryFixture()
        defer { incompleteFixture.cleanup() }
        let incompleteRegistry = DeliveryWorkflowRegistry(rootURL: incompleteFixture.root)
        let incompleteLocations = try await incompleteRegistry.createWorkflow(
            plan: incompleteFixture.plan,
            workflowIdentifier: incompleteFixture.workflowID
        )
        try FileManager.default.removeItem(at: incompleteLocations.planDocumentURL)
        await #expect(throws: DeliveryWorkflowRegistryError.incompleteWorkflow) {
            _ = try await incompleteRegistry.catalog()
        }
    }

    @Test("catalog is credential-free state/count data and never serializes private plan values")
    func privacySafeCatalog() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        _ = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID,
            createdAt: fixture.createdAt
        )

        let catalog = try await registry.catalog()
        #expect(catalog.workflowCount == 1)
        #expect(catalog.workflows == [DeliveryWorkflowRegistrySummary(
            workflowIdentifier: fixture.workflowID,
            stage: .queued,
            completedItemCount: 0,
            itemCount: 1,
            hasRetainedStaging: false,
            failureCode: nil
        )])
        let text = String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self).lowercased()
        for forbidden in [
            "private registry caption", "private-source-name", "incoming/private-desk",
            fixture.plan.fingerprint.lowercased(), fixture.plan.items[0].sourceRevision.sha256,
            fixture.plan.profile.name.lowercased(), "password", fixture.root.path.lowercased(),
        ] {
            #expect(!text.contains(forbidden))
        }
        #expect(!DeliveryWorkflowRegistryError.invalidStoredPlan.localizedDescription
            .contains(fixture.root.path))
    }

    @Test("retention removes only expired terminal states and manual cleanup is exact")
    func retentionAndManualCleanup() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let oldID = fixture.workflowID
        let activeID = UUID(uuidString: "82000000-0000-0000-0000-000000000008")!
        let recentID = UUID(uuidString: "83000000-0000-0000-0000-000000000008")!
        let old = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: oldID,
            createdAt: fixture.createdAt
        )
        _ = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: activeID,
            createdAt: fixture.createdAt
        )
        let recent = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: recentID,
            createdAt: fixture.createdAt
        )

        var oldManifest = try #require(await old.manifestPersistence.load())
        oldManifest.stage = .sent
        oldManifest.completedReceiptIdentifier = UUID()
        oldManifest.updatedAt = fixture.createdAt
        try await old.manifestPersistence.save(oldManifest)
        var recentManifest = try #require(await recent.manifestPersistence.load())
        recentManifest.stage = .failed
        recentManifest.failureCode = .uploadFailed
        recentManifest.updatedAt = fixture.createdAt.addingTimeInterval(95)
        try await recent.manifestPersistence.save(recentManifest)

        let result = try await registry.applyRetention(
            DeliveryWorkflowRetentionPolicy(
                sentLifetime: 10,
                failedOrCancelledLifetime: 10
            ),
            now: fixture.createdAt.addingTimeInterval(100)
        )
        #expect(result == DeliveryWorkflowCleanupResult(removedCount: 1, retainedCount: 2))
        #expect(!FileManager.default.fileExists(atPath: old.workflowRootURL.path))
        #expect((try await registry.catalog()).workflowCount == 2)

        try await registry.removeWorkflow(activeID)
        #expect((try await registry.catalog()).workflows.map(\.workflowIdentifier) == [recentID])
        await #expect(throws: DeliveryWorkflowRegistryError.workflowNotFound) {
            try await registry.removeWorkflow(activeID)
        }
    }

    @Test("staged-byte symlinks fail closed")
    func stagedSymlinkContainment() async throws {
        try await assertStagedSymlinkRejected()
    }

    @Test("duplicate manifest identities fail closed")
    func duplicateIdentity() async throws {
        try await assertDuplicateIdentityRejected()
    }

    @Test("newer plan and manifest schemas fail closed")
    func newerSchemas() async throws {
        try await assertNewerPlanSchemaRejected()
        try await assertNewerManifestSchemaRejected()
    }

    @Test("plan/profile drift and missing staged bytes fail closed")
    func driftAndMissingBytes() async throws {
        try await assertPlanAndProfileMismatchRejected()
        try await assertMissingStagedBytesRejected()
    }

    private func assertStagedSymlinkRejected() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID
        )
        let staging = try fixture.installStaging(at: locations)
        try await fixture.reference(staging: staging, at: locations)
        let stagedFile = staging.stagingDirectoryURL.appendingPathComponent(
            fixture.plan.items[0].stagedRelativePath
        )
        try FileManager.default.removeItem(at: stagedFile)
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "outside-\(UUID().uuidString).jpg"
        )
        try fixture.stagedBytes.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: stagedFile, withDestinationURL: outside)

        await #expect(throws: DeliveryWorkflowRegistryError.unsafeStoredPath) {
            _ = try await registry.resumeRecord(for: fixture.workflowID)
        }
    }

    private func assertDuplicateIdentityRejected() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let first = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID
        )
        let secondID = UUID(uuidString: "84000000-0000-0000-0000-000000000008")!
        let second = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: secondID
        )
        var manifest = try #require(await second.manifestPersistence.load())
        let firstManifest = try #require(await first.manifestPersistence.load())
        manifest = DeliveryWorkflowManifest(
            workflowIdentifier: firstManifest.workflowIdentifier,
            planFingerprint: manifest.planFingerprint,
            profileIdentifier: manifest.profileIdentifier,
            itemCount: manifest.itemCount,
            startedAt: manifest.startedAt,
            remoteStatPolicy: manifest.remoteStatPolicy
        )
        try await second.manifestPersistence.save(manifest)
        await #expect(throws: DeliveryWorkflowRegistryError.duplicateWorkflowIdentity) {
            _ = try await registry.catalog()
        }
    }

    private func assertNewerPlanSchemaRejected() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: locations.planDocumentURL))
                as? [String: Any]
        )
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: locations.planDocumentURL, options: .atomic)
        await #expect(throws: DeliveryWorkflowRegistryError.newerSchema) {
            _ = try await registry.catalog()
        }
    }

    private func assertNewerManifestSchemaRejected() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: locations.manifestDocumentURL))
                as? [String: Any]
        )
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: locations.manifestDocumentURL, options: .atomic)
        await #expect(throws: DeliveryWorkflowRegistryError.newerSchema) {
            _ = try await registry.catalog()
        }
    }

    private func assertPlanAndProfileMismatchRejected() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID
        )
        let stored = try #require(await locations.manifestPersistence.load())
        let drifted = DeliveryWorkflowManifest(
            workflowIdentifier: stored.workflowIdentifier,
            planFingerprint: String(repeating: "0", count: 64),
            profileIdentifier: UUID(),
            itemCount: stored.itemCount,
            startedAt: stored.startedAt,
            remoteStatPolicy: stored.remoteStatPolicy
        )
        try await locations.manifestPersistence.save(drifted)
        await #expect(throws: DeliveryWorkflowRegistryError.invalidStoredManifest) {
            _ = try await registry.catalog()
        }
    }

    private func assertMissingStagedBytesRejected() async throws {
        let fixture = try await RegistryFixture()
        defer { fixture.cleanup() }
        let registry = DeliveryWorkflowRegistry(rootURL: fixture.root)
        let locations = try await registry.createWorkflow(
            plan: fixture.plan,
            workflowIdentifier: fixture.workflowID
        )
        let staging = try fixture.installStaging(at: locations)
        try await fixture.reference(staging: staging, at: locations)
        try FileManager.default.removeItem(at: staging.stagingDirectoryURL.appendingPathComponent(
            fixture.plan.items[0].stagedRelativePath
        ))
        await #expect(throws: DeliveryWorkflowRegistryError.incompleteWorkflow) {
            _ = try await registry.catalog()
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func capture<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}

private struct RegistryFixture: Sendable {
    let root: URL
    let workflowID = UUID(uuidString: "81000000-0000-0000-0000-000000000008")!
    let createdAt = Date(timeIntervalSince1970: 10_000)
    let stagedBytes = Data("exact verified staged bytes".utf8)
    let plan: DeliveryPlan

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-workflow-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.85,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000
        )
        let connectionID = UUID(uuidString: "85000000-0000-0000-0000-000000000008")!
        let profile = DeadlineProfile(
            id: UUID(uuidString: "86000000-0000-0000-0000-000000000008")!,
            name: "Private Registry Desk",
            validationProfile: .snapshot(MetadataValidationProfile(
                id: UUID(uuidString: "87000000-0000-0000-0000-000000000008")!,
                name: "No required fields",
                rules: []
            )),
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: connectionID.uuidString.lowercased(),
                remotePathTemplate: "/incoming/private-desk"
            ),
            gpsPolicy: .retain,
            metadataWriteStrategy: .stagedCopies
        )
        let sourceURL = URL(fileURLWithPath: "/private/tmp/private-source-name.jpg")
            .standardizedFileURL.resolvingSymlinksInPath()
        let revision = SourceImageRevision(
            canonicalURL: sourceURL,
            fileResourceIdentifier: nil,
            filenameAtCreation: sourceURL.lastPathComponent,
            byteCount: 25,
            contentModificationDate: createdAt,
            pixelWidth: 6_000,
            pixelHeight: 4_000,
            exifOrientation: 1,
            sha256: String(repeating: "a", count: 64),
            hashCompletedAt: createdAt.addingTimeInterval(1)
        )
        let metadata = IPTCMetadata(title: "Private Registry Caption")
        let request = DeadlinePreflightRequest(
            profile: profile,
            items: [DeadlinePreflightItemSnapshot(
                sourceURL: sourceURL,
                metadata: metadata,
                source: DeadlineSourceSnapshot(
                    byteCount: 25,
                    pixelWidth: 6_000,
                    pixelHeight: 4_000
                )
            )],
            renameEnvironment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [],
                isComplete: true
            ),
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: 100_000,
                estimatedRequiredBytes: 1_000,
                stagingState: .ready,
                connections: [connectionID.uuidString.lowercased(): .reachable],
                remotePathState: .valid(resolvedPath: "/incoming/private-desk")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(request)
        let token = DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: 1,
            profileRevision: 1,
            resourceRevision: 1,
            renameEnvironmentRevision: 1,
            exportCapabilityRevision: 1,
            deliverySnapshotRevision: 1
        )
        plan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: request,
            publication: DeadlinePreflightPublication(token: token, report: report, wasCached: false),
            currentRevision: token,
            currentProfile: profile,
            items: [DeliveryPlanningItemInput(
                sourceRevision: revision,
                resolvedMetadata: metadata
            )]
        ))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func installStaging(
        at locations: DeliveryWorkflowRegistryLocations
    ) throws -> DeliveryStagingBatchResult {
        let batchID = UUID(uuidString: "88000000-0000-0000-0000-000000000008")!
        let batch = locations.stagingRootURL.appendingPathComponent(
            "deadline-\(batchID.uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: false)
        let item = plan.items[0]
        try stagedBytes.write(to: batch.appendingPathComponent(item.stagedRelativePath))
        let hash = SHA256.hash(data: stagedBytes).map { String(format: "%02x", $0) }.joined()
        let preservation = MetadataPreservationVerificationReport(
            sourceFormatIdentifier: "jpeg",
            stagedFormatIdentifier: "jpeg",
            domains: MetadataPreservationDomain.allCases.map {
                MetadataPreservationDomainResult(
                    domain: $0,
                    status: .unsupported,
                    sourceIdentity: nil,
                    stagedIdentity: nil
                )
            },
            c2paConsequence: .absentFromBoth
        )
        return DeliveryStagingBatchResult(
            batchID: batchID,
            planFingerprint: plan.fingerprint,
            stagingDirectoryURL: batch,
            requiredBytes: Int64(stagedBytes.count),
            status: .completed,
            items: [DeliveryStagingItemResult(
                itemIndex: 0,
                stageInputFingerprint: item.stageInputFingerprint,
                stagedRelativePath: item.stagedRelativePath,
                stage: .verified,
                stagedByteCount: stagedBytes.count,
                stagedSHA256: hash,
                renderSettings: DeliveryRenderSettings(
                    formatIdentifier: "jpeg",
                    colorSpaceIdentifier: "srgb",
                    pixelWidth: 100,
                    pixelHeight: 100,
                    bitDepth: 8,
                    quality: 90
                ),
                metadataPreservation: preservation,
                checkedFields: plan.renderAndWrite.verificationFields,
                mismatchedFields: [],
                failure: nil
            )],
            cleanupToken: DeliveryStagingCleanupToken(
                batchID: batchID,
                planFingerprint: plan.fingerprint,
                stagingRootURL: locations.stagingRootURL,
                stagingDirectoryURL: batch
            )
        )
    }

    func reference(
        staging: DeliveryStagingBatchResult,
        at locations: DeliveryWorkflowRegistryLocations
    ) async throws {
        try await locations.stagingEvidencePersistence.save(
            DeliveryWorkflowStagingEvidenceDocument(
                workflowIdentifier: workflowID,
                planFingerprint: plan.fingerprint,
                stagingResult: staging
            )
        )
        var manifest = try #require(await locations.manifestPersistence.load())
        manifest.stagingEvidence = DeliveryWorkflowStagingEvidence(
            batchIdentifier: staging.batchID,
            evidenceFingerprint: try stagingFingerprint(staging),
            verifiedItemCount: staging.items.count
        )
        manifest.updatedAt = manifest.startedAt.addingTimeInterval(1)
        try await locations.manifestPersistence.save(manifest)
    }

    private func stagingFingerprint(_ result: DeliveryStagingBatchResult) throws -> String {
        let payload = RegistryTestStagingFingerprintPayload(
            batchIdentifier: result.batchID,
            planFingerprint: result.planFingerprint,
            requiredBytes: result.requiredBytes,
            items: result.items.map {
                RegistryTestStagingItemFingerprintPayload(
                    itemIndex: $0.itemIndex,
                    stageInputFingerprint: $0.stageInputFingerprint,
                    stagedByteCount: $0.stagedByteCount,
                    stagedSHA256: $0.stagedSHA256,
                    renderSettings: $0.renderSettings,
                    metadataPreservation: $0.metadataPreservation,
                    checkedFields: $0.checkedFields
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }.joined()
    }
}

private struct RegistryTestStagingFingerprintPayload: Codable {
    let batchIdentifier: UUID
    let planFingerprint: String
    let requiredBytes: Int64
    let items: [RegistryTestStagingItemFingerprintPayload]
}

private struct RegistryTestStagingItemFingerprintPayload: Codable {
    let itemIndex: Int
    let stageInputFingerprint: String
    let stagedByteCount: Int?
    let stagedSHA256: String?
    let renderSettings: DeliveryRenderSettings?
    let metadataPreservation: MetadataPreservationVerificationReport?
    let checkedFields: [IPTCMetadataVerificationField]
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
