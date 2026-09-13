import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Frozen delivery planning")
struct DeliveryPlanningServiceTests {
    @Test("freezes complete deterministic stage inputs and applies GPS policy")
    func deterministicFrozenPlan() async throws {
        let context = try await makeContext(
            metadata: IPTCMetadata(
                title: "Final caption",
                keywords: ["wire", "news"],
                latitude: 59.9139,
                longitude: 10.7522
            )
        )

        let first = try DeliveryPlanningService().makePlan(context.planningRequest())
        let second = try DeliveryPlanningService().makePlan(context.planningRequest())

        #expect(first == second)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint.count == 64)
        #expect(first.items.count == 1)
        #expect(first.items[0].outputFilename == "source.jpg")
        #expect(first.items[0].stagedRelativePath == "source.jpg")
        #expect(first.items[0].stageInputFingerprint.count == 64)
        #expect(first.items[0].resolvedMetadata.title == "Final caption")
        #expect(first.items[0].resolvedMetadata.latitude == nil)
        #expect(first.items[0].resolvedMetadata.longitude == nil)
        #expect(first.destination.connectionIdentifier == Self.connectionID.uuidString.lowercased())
        #expect(first.destination.resolvedRemotePath == "/incoming/desk")
        #expect(first.preflight.revision == context.token)
        #expect(first.preflight.blockerCount == 0)
        #expect(first.preflight.warningIDs.isEmpty)
    }

    @Test("blockers, stale revisions, and unaccepted warnings refuse a plan")
    func readinessRefusals() async throws {
        let blocked = try await makeContext(sourceAvailable: false)
        #expect(throws: DeliveryPlanningError.preflightBlocked(
            count: blocked.publication.report.blockerCount
        )) {
            try DeliveryPlanningService().makePlan(blocked.planningRequest())
        }

        let stale = try await makeContext()
        let staleToken = token(metadata: stale.token.metadataRevision + 1)
        #expect(throws: DeliveryPlanningError.stalePreflight) {
            try DeliveryPlanningService().makePlan(
                stale.planningRequest(currentRevision: staleToken)
            )
        }

        let warning = try await makeContext(includeSpaceWarning: true)
        let warningIDs = warning.publication.report.issues
            .filter { $0.severity == .warning }
            .map(\.id)
            .sorted()
        #expect(!warningIDs.isEmpty)
        #expect(throws: DeliveryPlanningError.unacceptedWarnings(warningIDs)) {
            try DeliveryPlanningService().makePlan(warning.planningRequest())
        }
        let accepted = try DeliveryPlanningService().makePlan(
            warning.planningRequest(acceptedWarningIDs: Set(warningIDs))
        )
        #expect(accepted.acceptedWarningIDs == warningIDs)
    }

    @Test("source, metadata, profile, and Develop edits invalidate preflight")
    func editsInvalidatePreflight() async throws {
        let context = try await makeContext()
        let changedRevision = sourceRevision(hash: String(repeating: "b", count: 64))
        let changedSource = DeliveryPlanningItemInput(
            preflightSourceRevision: context.sourceRevision,
            currentSourceRevision: changedRevision,
            resolvedMetadata: context.metadata,
            preflightDevelopSnapshot: nil,
            currentDevelopSnapshot: nil
        )
        #expect(throws: DeliveryPlanningError.sourceChangedAfterPreflight(itemIndex: 0)) {
            try DeliveryPlanningService().makePlan(
                context.planningRequest(items: [changedSource])
            )
        }

        var changedMetadata = context.metadata
        changedMetadata.title = "Edited after preflight"
        let metadataInput = DeliveryPlanningItemInput(
            sourceRevision: context.sourceRevision,
            resolvedMetadata: changedMetadata
        )
        #expect(throws: DeliveryPlanningError.metadataChangedAfterPreflight(itemIndex: 0)) {
            try DeliveryPlanningService().makePlan(
                context.planningRequest(items: [metadataInput])
            )
        }

        var changedProfile = context.profile
        changedProfile.name = "Changed profile"
        #expect(throws: DeliveryPlanningError.profileChangedAfterPreflight) {
            try DeliveryPlanningService().makePlan(
                context.planningRequest(currentProfile: changedProfile)
            )
        }

        var changedSettings = CameraRawSettings()
        changedSettings.exposure2012 = 0.5
        let changedDevelop = DevelopVersionSnapshot(settings: changedSettings)
        let developInput = DeliveryPlanningItemInput(
            preflightSourceRevision: context.sourceRevision,
            currentSourceRevision: context.sourceRevision,
            resolvedMetadata: context.metadata,
            preflightDevelopSnapshot: nil,
            currentDevelopSnapshot: changedDevelop
        )
        #expect(throws: DeliveryPlanningError.developSettingsChangedAfterPreflight(itemIndex: 0)) {
            try DeliveryPlanningService().makePlan(
                context.planningRequest(items: [developInput])
            )
        }
    }

    @Test("changed bytes are rejected even when the UI revision token is unchanged")
    func exactSourceRevisionClosesCachedFactGap() async throws {
        let context = try await makeContext()
        let currentBytes = sourceRevision(hash: String(repeating: "c", count: 64))
        let input = DeliveryPlanningItemInput(
            preflightSourceRevision: context.sourceRevision,
            currentSourceRevision: currentBytes,
            resolvedMetadata: context.metadata,
            preflightDevelopSnapshot: nil,
            currentDevelopSnapshot: nil
        )

        #expect(throws: DeliveryPlanningError.sourceChangedAfterPreflight(itemIndex: 0)) {
            // planningRequest deliberately keeps context.token unchanged, modeling a stale
            // ImageFile cache whose size/date token did not observe replacement bytes.
            try DeliveryPlanningService().makePlan(context.planningRequest(items: [input]))
        }
    }

    @Test("fresh metadata, source, and profile revisions change the plan fingerprint")
    func fingerprintInvalidation() async throws {
        let original = try await makeContext(metadata: IPTCMetadata(title: "Original"))
        let metadataEdit = try await makeContext(metadata: IPTCMetadata(title: "Edited"))
        let sourceEdit = try await makeContext(sourceHash: String(repeating: "c", count: 64))
        let profileEdit = try await makeContext(
            metadata: IPTCMetadata(title: "Original"),
            profileName: "Night desk"
        )

        let plans = try [original, metadataEdit, sourceEdit, profileEdit].map {
            try DeliveryPlanningService().makePlan($0.planningRequest())
        }
        #expect(Set(plans.map(\.fingerprint)).count == plans.count)
        #expect(plans[0].items[0].stageInputFingerprint != plans[1].items[0].stageInputFingerprint)
        #expect(plans[0].items[0].stageInputFingerprint != plans[2].items[0].stageInputFingerprint)
        // A profile label edit changes the confirmation contract but not the bytes staged.
        #expect(plans[0].items[0].stageInputFingerprint == plans[3].items[0].stageInputFingerprint)
    }

    @Test("A per-output byte ceiling is frozen into planning and stage fingerprints")
    func maximumOutputLimitIsFrozen() async throws {
        let unlimited = try await makeContext(maximumOutputByteCount: nil)
        let limited = try await makeContext(maximumOutputByteCount: 2_000_000)
        let unlimitedPlan = try DeliveryPlanningService().makePlan(unlimited.planningRequest())
        let limitedPlan = try DeliveryPlanningService().makePlan(limited.planningRequest())

        #expect(unlimitedPlan.renderAndWrite.export.maximumOutputByteCount == nil)
        #expect(limitedPlan.renderAndWrite.export.maximumOutputByteCount == 2_000_000)
        #expect(unlimitedPlan.fingerprint != limitedPlan.fingerprint)
        #expect(unlimitedPlan.items[0].stageInputFingerprint != limitedPlan.items[0].stageInputFingerprint)
    }

    @Test("A proven voice memo is frozen beside the renamed output and source drift is refused")
    func voiceMemoIsFrozen() async throws {
        let context = try await makeContext(voiceMemoPolicy: .includeWhenAvailable)
        let plan = try DeliveryPlanningService().makePlan(context.planningRequest())

        #expect(plan.profile.voiceMemoDeliveryPolicy == .includeWhenAvailable)
        #expect(plan.items[0].voiceMemo?.outputFilename == "source.WAV")
        #expect(plan.items[0].voiceMemo?.sourceRevision == context.voiceMemoRevision)
        #expect(plan.items[0].stageInputFingerprint.count == 64)

        let changedMemo = context.voiceMemoRevision.map {
            SourceImageRevision(
                canonicalURL: $0.canonicalURL,
                fileResourceIdentifier: $0.fileResourceIdentifier,
                filenameAtCreation: $0.filenameAtCreation,
                byteCount: $0.byteCount,
                contentModificationDate: $0.contentModificationDate,
                pixelWidth: nil,
                pixelHeight: nil,
                exifOrientation: nil,
                sha256: String(repeating: "d", count: 64),
                hashCompletedAt: $0.hashCompletedAt
            )
        }
        let input = DeliveryPlanningItemInput(
            sourceRevision: context.sourceRevision,
            resolvedMetadata: context.metadata,
            voiceMemoRevision: changedMemo
        )
        #expect(throws: DeliveryPlanningError.preflightResultMismatch) {
            try DeliveryPlanningService().makePlan(context.planningRequest(items: [input]))
        }
    }

    @Test("rename output and export extension are frozen from the preflight plan")
    func renameOutputFrozen() async throws {
        let recipe = BatchRenameRecipe(
            name: "Wire",
            components: [.token(.originalStem), .literal("_wire.jpg")]
        )
        let context = try await makeContext(renameRecipe: recipe)
        let plan = try DeliveryPlanningService().makePlan(context.planningRequest())

        #expect(plan.preflight.renamePlan?.entries[0].plannedDestinationImageURL?.lastPathComponent
            == "source_wire.jpg")
        #expect(plan.items[0].outputFilename == "source_wire.jpg")
    }

    @Test("strict JSON round-trip is privacy-safe and detects tampering")
    func jsonRoundTripAndTamperDetection() async throws {
        let context = try await makeContext()
        let plan = try DeliveryPlanningService().makePlan(context.planningRequest())
        let io = DeliveryPlanIO()
        let data = try io.encode(plan)
        let text = String(decoding: data, as: UTF8.self)

        #expect(try io.decode(data) == plan)
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("privateKey"))
        #expect(!text.localizedCaseInsensitiveContains("securityScopedBookmark"))

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["fingerprint"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: DeliveryPlanningError.invalidFingerprint) {
            try io.decode(tampered)
        }
    }

    @Test("schema-one retained plans remain resumable only with implicit WAV exclusion")
    func legacyPlanFingerprintCompatibility() async throws {
        let context = try await makeContext()
        let current = try DeliveryPlanningService().makePlan(context.planningRequest())
        let legacyDraft = DeliveryPlan(
            schemaVersion: 1,
            fingerprint: "",
            profile: current.profile,
            preflight: current.preflight,
            renderAndWrite: current.renderAndWrite,
            destination: current.destination,
            acceptedWarningIDs: current.acceptedWarningIDs,
            items: current.items
        )
        let legacyFingerprint = try DeliveryPlanningService.legacyPlanFingerprint(for: legacyDraft)
        #expect(legacyFingerprint != current.fingerprint)
        let legacy = DeliveryPlan(
            schemaVersion: 1,
            fingerprint: legacyFingerprint,
            profile: legacyDraft.profile,
            preflight: legacyDraft.preflight,
            renderAndWrite: legacyDraft.renderAndWrite,
            destination: legacyDraft.destination,
            acceptedWarningIDs: legacyDraft.acceptedWarningIDs,
            items: legacyDraft.items
        )
        let io = DeliveryPlanIO()
        var object = try #require(
            JSONSerialization.jsonObject(with: try io.encode(legacy)) as? [String: Any]
        )
        var profile = try #require(object["profile"] as? [String: Any])
        profile["schemaVersion"] = 1
        profile.removeValue(forKey: "voiceMemoDeliveryPolicy")
        object["profile"] = profile
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let restored = try io.decode(legacyData)

        #expect(restored.profile.voiceMemoDeliveryPolicy == .exclude)
        #expect(restored.items.allSatisfy { $0.voiceMemo == nil })
        #expect(restored.fingerprint == legacyFingerprint)
        try restored.validateForPersistence()
    }

    @Test("future schemas and existing export files are never overwritten")
    func schemaAndNoOverwriteBoundary() async throws {
        let context = try await makeContext()
        let plan = try DeliveryPlanningService().makePlan(context.planningRequest())
        let io = DeliveryPlanIO()
        var object = try #require(
            JSONSerialization.jsonObject(with: io.encode(plan)) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "delivery plan",
            found: 99,
            supported: DeliveryPlan.currentSchemaVersion
        )) {
            try io.decode(future)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-delivery-plan-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("plan.json")
        let sentinel = Data("keep me".utf8)
        try sentinel.write(to: destination)

        #expect(throws: DeliveryPlanIOError.destinationAlreadyExists(destination)) {
            try io.export(plan, to: destination)
        }
        #expect(try Data(contentsOf: destination) == sentinel)
    }

    @Test("frozen-plan validation directly rejects a non-UUID connection identifier")
    func connectionIdentifierIsStrict() async throws {
        let context = try await makeContext()
        let plan = try DeliveryPlanningService().makePlan(context.planningRequest())
        let unsafe = DeliveryPlan(
            fingerprint: plan.fingerprint,
            profile: plan.profile,
            preflight: plan.preflight,
            renderAndWrite: plan.renderAndWrite,
            destination: DeliveryDestinationSnapshot(
                connectionIdentifier: "ftp://reporter:secret@example.test",
                resolvedRemotePath: plan.destination.resolvedRemotePath
            ),
            acceptedWarningIDs: plan.acceptedWarningIDs,
            items: plan.items
        )

        #expect(throws: DeliveryPlanningError.destinationMismatch) {
            try unsafe.validateForPersistence()
        }

        for unsafePath in ["incoming/desk", "//server/share", "/incoming/./desk", "/incoming\\desk"] {
            let unsafeDestination = DeliveryPlan(
                fingerprint: plan.fingerprint,
                profile: plan.profile,
                preflight: plan.preflight,
                renderAndWrite: plan.renderAndWrite,
                destination: DeliveryDestinationSnapshot(
                    connectionIdentifier: plan.destination.connectionIdentifier,
                    resolvedRemotePath: unsafePath
                ),
                acceptedWarningIDs: plan.acceptedWarningIDs,
                items: plan.items
            )
            #expect(throws: DeliveryPlanningError.destinationMismatch) {
                try unsafeDestination.validateForPersistence()
            }
        }
    }

    private static let connectionID = UUID(
        uuidString: "50000000-0000-0000-0000-000000000005"
    )!

    private func makeContext(
        metadata: IPTCMetadata = IPTCMetadata(title: "Caption"),
        sourceHash: String = String(repeating: "a", count: 64),
        profileName: String = "Wire desk",
        sourceAvailable: Bool = true,
        includeSpaceWarning: Bool = false,
        renameRecipe: BatchRenameRecipe? = nil,
        maximumOutputByteCount: Int64? = nil,
        voiceMemoPolicy: DeadlineVoiceMemoDeliveryPolicy = .exclude
    ) async throws -> PlanningContext {
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.85,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000,
            maximumOutputByteCount: maximumOutputByteCount
        )
        let profile = DeadlineProfile(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            name: profileName,
            validationProfile: .snapshot(MetadataValidationProfile(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "No required fields",
                rules: []
            )),
            rename: renameRecipe.map {
                DeadlineRenameConfiguration(recipe: .snapshot($0), collisionPolicy: .block)
            },
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: Self.connectionID.uuidString.lowercased(),
                remotePathTemplate: "/incoming/{desk}"
            ),
            gpsPolicy: .remove,
            metadataWriteStrategy: .stagedCopies,
            voiceMemoDeliveryPolicy: voiceMemoPolicy
        )
        let sourceURL = URL(fileURLWithPath: "/private/tmp/source.jpg")
        let revision = sourceRevision(hash: sourceHash)
        let memoRevision = voiceMemoPolicy == .exclude ? nil : voiceMemoRevision()
        let item = DeadlinePreflightItemSnapshot(
            sourceURL: sourceURL,
            metadata: metadata,
            source: DeadlineSourceSnapshot(
                isAvailable: sourceAvailable,
                byteCount: 3,
                pixelWidth: 6000,
                pixelHeight: 4000
            ),
            estimatedOutputByteCount: maximumOutputByteCount.map { min($0, 1_000) },
            voiceMemo: memoRevision.map {
                .available(revision: $0, profileIdentifier: "sony-ilce1-v4")
            } ?? .none
        )
        let request = DeadlinePreflightRequest(
            profile: profile,
            items: [item],
            renameEnvironment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [],
                isComplete: true
            ),
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: includeSpaceWarning ? nil : 10_000,
                estimatedRequiredBytes: 1_000,
                stagingState: .ready,
                connections: [profile.destination!.connectionIdentifier: .reachable],
                remotePathState: .valid(resolvedPath: "/incoming/desk")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(request)
        let revisionToken = token(metadata: 1)
        let publication = DeadlinePreflightPublication(
            token: revisionToken,
            report: report,
            wasCached: false
        )
        return PlanningContext(
            preflightRequest: request,
            publication: publication,
            token: revisionToken,
            profile: profile,
            sourceRevision: revision,
            metadata: metadata,
            voiceMemoRevision: memoRevision
        )
    }

    private func sourceRevision(hash: String) -> SourceImageRevision {
        let sourceURL = URL(fileURLWithPath: "/private/tmp/source.jpg")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        return SourceImageRevision(
            canonicalURL: sourceURL,
            fileResourceIdentifier: nil,
            filenameAtCreation: sourceURL.lastPathComponent,
            byteCount: 3,
            contentModificationDate: modificationDate,
            pixelWidth: 6000,
            pixelHeight: 4000,
            exifOrientation: 1,
            sha256: hash,
            hashCompletedAt: modificationDate.addingTimeInterval(1)
        )
    }

    private func voiceMemoRevision() -> SourceImageRevision {
        let url = URL(fileURLWithPath: "/private/tmp/source.WAV")
            .standardizedFileURL.resolvingSymlinksInPath()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return SourceImageRevision(
            canonicalURL: url,
            fileResourceIdentifier: nil,
            filenameAtCreation: url.lastPathComponent,
            byteCount: 9,
            contentModificationDate: date,
            pixelWidth: nil,
            pixelHeight: nil,
            exifOrientation: nil,
            sha256: String(repeating: "e", count: 64),
            hashCompletedAt: date.addingTimeInterval(1)
        )
    }

    private func token(metadata: UInt64 = 1) -> DeadlinePreflightRevisionToken {
        DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: metadata,
            profileRevision: 1,
            resourceRevision: 1,
            renameEnvironmentRevision: 1,
            exportCapabilityRevision: 1,
            deliverySnapshotRevision: 1
        )
    }
}

private struct PlanningContext {
    let preflightRequest: DeadlinePreflightRequest
    let publication: DeadlinePreflightPublication
    let token: DeadlinePreflightRevisionToken
    let profile: DeadlineProfile
    let sourceRevision: SourceImageRevision
    let metadata: IPTCMetadata
    let voiceMemoRevision: SourceImageRevision?

    func planningRequest(
        currentRevision: DeadlinePreflightRevisionToken? = nil,
        currentProfile: DeadlineProfile? = nil,
        items: [DeliveryPlanningItemInput]? = nil,
        acceptedWarningIDs: Set<String> = []
    ) -> DeliveryPlanningRequest {
        DeliveryPlanningRequest(
            preflightRequest: preflightRequest,
            publication: publication,
            currentRevision: currentRevision ?? token,
            currentProfile: currentProfile ?? profile,
            items: items ?? [DeliveryPlanningItemInput(
                sourceRevision: sourceRevision,
                resolvedMetadata: metadata,
                voiceMemoRevision: voiceMemoRevision
            )],
            acceptedWarningIDs: acceptedWarningIDs
        )
    }
}
