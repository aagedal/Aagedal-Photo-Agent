import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Deadline preflight coordinator and workspace state")
struct DeadlinePreflightCoordinatorTests {
    @Test("Send gating requires a fresh exact source identity and staged-copy strategy")
    @MainActor
    func sendGatingRequiresExactSourceIdentity() {
        let token = DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: 1,
            profileRevision: 1,
            resourceRevision: 1,
            renameEnvironmentRevision: 1,
            exportCapabilityRevision: 1,
            deliverySnapshotRevision: 1
        )
        let url = URL(fileURLWithPath: "/private/tmp/deadline-source.jpg")
        let profile = DeadlineProfile(name: "Wire", metadataWriteStrategy: .stagedCopies)
        let request = DeadlinePreflightRequest(
            profile: profile,
            items: [DeadlinePreflightItemSnapshot(sourceURL: url)]
        )
        let report = DeadlinePreflightReport(
            issues: [],
            imageReports: [.init(imageIndex: 0, imageURL: url, issues: [])],
            renamePlan: nil
        )
        let publication = DeadlinePreflightPublication(token: token, report: report, wasCached: false)
        let revision = SourceImageRevision(
            canonicalURL: url,
            fileResourceIdentifier: nil,
            filenameAtCreation: url.lastPathComponent,
            byteCount: 3,
            contentModificationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 1,
            pixelHeight: 1,
            exifOrientation: 1,
            sha256: String(repeating: "a", count: 64),
            hashCompletedAt: Date(timeIntervalSince1970: 2)
        )
        let dependencies = DeadlineDeliveryExecutionDependencies(
            prepare: { _ in throw DeadlineDeliveryExecutionError.preparationFailed },
            start: { _, _ in throw DeadlineDeliveryExecutionError.executionFailed },
            resume: { _, _ in throw DeadlineDeliveryExecutionError.resumeUnavailable },
            cancel: {},
            recover: { nil },
            reloadReceipts: {}
        )
        let model = DeadlineDeliveryExecutionModel(dependencies: dependencies)
        let missing = DeadlineWorkspaceInput(
            request: request,
            revisionToken: token,
            developSnapshots: [nil],
            sourceRevisions: [nil]
        )
        let exact = DeadlineWorkspaceInput(
            request: request,
            revisionToken: token,
            developSnapshots: [nil],
            sourceRevisions: [revision]
        )

        #expect(model.sendAvailability(
            input: missing,
            publication: publication,
            isEvaluating: false
        ) == .sourceIdentityUnavailable)
        #expect(model.sendAvailability(
            input: exact,
            publication: publication,
            isEvaluating: false
        ) == .ready(warningCount: 0))
        #expect(model.sendAvailability(
            input: exact,
            publication: publication,
            isEvaluating: true
        ) == .evaluating)
        #expect(model.sendIsEnabled(input: exact, publication: publication, isEvaluating: false))
        let unsupported = DeadlineWorkspaceInput(
            request: DeadlinePreflightRequest(
                profile: DeadlineProfile(
                    name: "Legacy",
                    metadataWriteStrategy: .xmpSidecars
                ),
                items: request.items
            ),
            revisionToken: token,
            developSnapshots: [nil],
            sourceRevisions: [revision]
        )
        #expect(model.sendAvailability(
            input: unsupported,
            publication: publication,
            isEvaluating: false
        ) == .unsupportedWriteStrategy)
        let stalePublication = DeadlinePreflightPublication(
            token: DeadlinePreflightRevisionToken(
                selectionSourceRevision: 2,
                metadataRevision: 1,
                profileRevision: 1,
                resourceRevision: 1,
                renameEnvironmentRevision: 1,
                exportCapabilityRevision: 1,
                deliverySnapshotRevision: 1
            ),
            report: report,
            wasCached: false
        )
        #expect(model.sendAvailability(
            input: exact,
            publication: stalePublication,
            isEvaluating: false
        ) == .stalePreflight)
        #expect(model.sendAvailability(
            input: nil,
            publication: nil,
            isEvaluating: false
        ) == .missingPreflight)
    }

    @Test("Delivery confirmation exposes every frozen output and consequence exactly")
    func exactDeliveryConfirmationProjection() {
        let profile = DeadlineProfile(
            name: "Wire",
            destination: .init(
                connectionIdentifier: "40000000-0000-0000-0000-000000000004",
                remotePathTemplate: "/incoming"
            ),
            metadataWriteStrategy: .stagedCopies
        )
        let token = DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: 1,
            profileRevision: 1,
            resourceRevision: 1,
            renameEnvironmentRevision: 1,
            exportCapabilityRevision: 1,
            deliverySnapshotRevision: 1
        )
        let sourceURL = URL(fileURLWithPath: "/private/tmp/source.jpg")
        let source = SourceImageRevision(
            canonicalURL: sourceURL,
            fileResourceIdentifier: nil,
            filenameAtCreation: sourceURL.lastPathComponent,
            byteCount: 3,
            contentModificationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 6000,
            pixelHeight: 4000,
            exifOrientation: 1,
            sha256: String(repeating: "a", count: 64),
            hashCompletedAt: Date(timeIntervalSince1970: 2)
        )
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.91,
            sdrGamut: .displayP3,
            hdrFormat: .tiff16bit,
            hdrQuality: 0.8,
            hdrGamut: .rec2020,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000,
            maximumOutputByteCount: 2_500_000
        )
        let plan = DeliveryPlan(
            fingerprint: String(repeating: "b", count: 64),
            profile: profile,
            preflight: DeliveryPreflightResultSnapshot(publication: .init(
                token: token,
                report: .init(issues: [], imageReports: [], renamePlan: nil),
                wasCached: false
            )),
            renderAndWrite: .init(
                export: export,
                metadataWriteStrategy: .stagedCopies,
                gpsPolicy: .retain,
                verificationFields: []
            ),
            destination: .init(
                connectionIdentifier: "40000000-0000-0000-0000-000000000004",
                resolvedRemotePath: "/incoming/desk"
            ),
            acceptedWarningIDs: ["warning-1"],
            items: [.init(
                itemIndex: 0,
                sourceRevision: source,
                resolvedMetadata: IPTCMetadata(),
                outputFilename: "wire-001.jpg",
                stagedRelativePath: "wire-001.jpg",
                isHDR: false,
                developSnapshot: nil,
                stageInputFingerprint: String(repeating: "c", count: 64)
            )]
        )
        let confirmation = DeadlineDeliveryConfirmation(prepared: .init(
            workflowIdentifier: UUID(),
            plan: plan,
            stagingRootURL: URL(fileURLWithPath: "/private/tmp/staging"),
            c2paConsequences: [.derivedOutputDropsManifest],
            transportSecurity: DeliveryTransportSecurity(
                protocolKind: .explicitFTPS,
                verificationEnabled: false
            ),
            requiresFirstInsecureTransportAcknowledgement: true
        ))

        #expect(confirmation.items.map(\.outputFilename) == ["wire-001.jpg"])
        #expect(confirmation.items[0].format == "jpeg")
        #expect(confirmation.items[0].gamut == .displayP3)
        #expect(confirmation.items[0].qualityPercent == 91)
        #expect(confirmation.items[0].resolution == .pixels4000)
        #expect(confirmation.items[0].c2paConsequence == .derivedOutputDropsManifest)
        #expect(confirmation.destinationConnectionIdentifier == "40000000-0000-0000-0000-000000000004")
        #expect(confirmation.destinationPath == "/incoming/desk")
        #expect(confirmation.metadataWriteStrategy == .stagedCopies)
        #expect(confirmation.maximumOutputByteCount == 2_500_000)
        #expect(confirmation.transportSecurity == DeliveryTransportSecurity(
            protocolKind: .explicitFTPS,
            verificationEnabled: false
        ))
        #expect(confirmation.requiresFirstInsecureTransportAcknowledgement)
    }

    @Test("Deadline confirmation acknowledges the exact insecure state before execution")
    @MainActor
    func deadlineInsecureTransportAcknowledgement() async throws {
        let fixture = try await makeDeadlineExecutionFixture()
        let security = DeliveryTransportSecurity(protocolKind: .ftp, verificationEnabled: false)
        let prepared = DeadlinePreparedDeliveryBatch(
            workflowIdentifier: fixture.prepared.workflowIdentifier,
            plan: fixture.prepared.plan,
            stagingRootURL: fixture.prepared.stagingRootURL,
            c2paConsequences: fixture.prepared.c2paConsequences,
            transportSecurity: security,
            requiresFirstInsecureTransportAcknowledgement: true
        )
        var acknowledgement: (String, DeliveryTransportSecurity)?
        var didStart = false
        let model = DeadlineDeliveryExecutionModel(dependencies: .init(
            prepare: { _ in prepared },
            start: { _, _ in
                didStart = true
                throw DeadlineDeliveryExecutionError.executionFailed
            },
            resume: { _, _ in throw DeadlineDeliveryExecutionError.resumeUnavailable },
            cancel: {},
            recover: { nil },
            reloadReceipts: {},
            acknowledgeInsecureTransport: { identifier, confirmedSecurity in
                acknowledgement = (identifier, confirmedSecurity)
                return true
            }
        ))
        model.synchronizePreflight(fixture.publication)
        model.requestSend(input: fixture.input, publication: fixture.publication)
        #expect(await waitForDeadlineExecutionState(model, timeout: .seconds(2)) {
            if case .awaitingConfirmation = $0 { true } else { false }
        })

        guard case let .awaitingConfirmation(confirmation) = model.state else {
            Issue.record("Expected insecure transport confirmation")
            return
        }
        #expect(confirmation.transportSecurity == security)
        #expect(confirmation.requiresFirstInsecureTransportAcknowledgement)
        model.confirmAndStart()

        #expect(acknowledgement?.0 == prepared.plan.destination.connectionIdentifier)
        #expect(acknowledgement?.1 == security)
        #expect(await waitForDeadlineExecutionState(model, timeout: .seconds(2)) {
            if case .failed = $0 { true } else { false }
        })
        #expect(didStart)
    }

    @Test("Deadline refuses execution when the exact insecure acknowledgement cannot persist")
    @MainActor
    func deadlineInsecureTransportAcknowledgementFailure() async throws {
        let fixture = try await makeDeadlineExecutionFixture()
        let prepared = DeadlinePreparedDeliveryBatch(
            workflowIdentifier: fixture.prepared.workflowIdentifier,
            plan: fixture.prepared.plan,
            stagingRootURL: fixture.prepared.stagingRootURL,
            c2paConsequences: fixture.prepared.c2paConsequences,
            transportSecurity: DeliveryTransportSecurity(
                protocolKind: .sftp,
                verificationEnabled: false
            ),
            requiresFirstInsecureTransportAcknowledgement: true
        )
        var didStart = false
        let model = DeadlineDeliveryExecutionModel(dependencies: .init(
            prepare: { _ in prepared },
            start: { _, _ in
                didStart = true
                throw DeadlineDeliveryExecutionError.executionFailed
            },
            resume: { _, _ in throw DeadlineDeliveryExecutionError.resumeUnavailable },
            cancel: {},
            recover: { nil },
            reloadReceipts: {},
            acknowledgeInsecureTransport: { _, _ in false }
        ))
        model.synchronizePreflight(fixture.publication)
        model.requestSend(input: fixture.input, publication: fixture.publication)
        #expect(await waitForDeadlineExecutionState(model, timeout: .seconds(2)) {
            if case .awaitingConfirmation = $0 { true } else { false }
        })
        model.confirmAndStart()

        #expect(!didStart)
        #expect(model.error == .insecureTransportAcknowledgementFailed)
        guard case .awaitingConfirmation = model.state else {
            Issue.record("Failed acknowledgement must keep the exact confirmation open")
            return
        }
    }

    @Test("Warning acceptance is batch-scoped and resets on token change")
    @MainActor
    func warningAcceptanceResetsOnTokenChange() async throws {
        let fixture = try await makeDeadlineExecutionFixture(downscale: true)
        #expect(fixture.publication.report.warningCount > 0)
        let model = DeadlineDeliveryExecutionModel(dependencies: executionDependencies(
            prepared: fixture.prepared
        ))
        model.synchronizePreflight(fixture.publication)
        #expect(model.sendAvailability(
            input: fixture.input,
            publication: fixture.publication,
            isEvaluating: false
        ) == .ready(warningCount: fixture.publication.report.warningCount))
        model.requestSend(input: fixture.input, publication: fixture.publication)
        guard case .awaitingWarningAcceptance = model.state else {
            Issue.record("Expected explicit warning acceptance")
            return
        }
        #expect(model.sendAvailability(
            input: fixture.input,
            publication: fixture.publication,
            isEvaluating: false
        ) == .awaitingUserAction)
        model.acceptWarningsAndPrepare(input: fixture.input, publication: fixture.publication)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.acceptedWarningIDs.isEmpty)
        guard case .awaitingConfirmation = model.state else {
            Issue.record("Expected an exact confirmation after accepting warnings")
            return
        }

        model.cancelConfirmation()
        #expect(model.acceptedWarningIDs.isEmpty)
        model.requestSend(input: fixture.input, publication: fixture.publication)
        guard case .awaitingWarningAcceptance = model.state else {
            Issue.record("A cancelled batch must require a new warning acceptance")
            return
        }
        model.acceptWarningsAndPrepare(input: fixture.input, publication: fixture.publication)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!model.acceptedWarningIDs.isEmpty)

        let replacement = DeadlinePreflightPublication(
            token: deadlineTestToken(selection: 2),
            report: fixture.publication.report,
            wasCached: false
        )
        model.synchronizePreflight(replacement)
        #expect(model.acceptedWarningIDs.isEmpty)
        #expect(model.state == .idle)
    }

    @Test("Cancel during staging cancels the owner task and forwards to production")
    @MainActor
    func cancelDuringStaging() async throws {
        let fixture = try await makeDeadlineExecutionFixture()
        let cancellation = DeadlineExecutionProbe()
        let dependencies = DeadlineDeliveryExecutionDependencies(
            prepare: { _ in fixture.prepared },
            start: { batch, progress in
                await progress(DeliveryWorkflowProgress(
                    workflowIdentifier: batch.workflowIdentifier,
                    planFingerprint: batch.plan.fingerprint,
                    stage: .staging,
                    completedItemCount: 0,
                    itemCount: batch.plan.items.count,
                    failureCode: nil
                ))
                try await Task.sleep(for: .seconds(2))
                throw CancellationError()
            },
            resume: { _, _ in throw DeadlineDeliveryExecutionError.resumeUnavailable },
            cancel: { await cancellation.markCancelled() },
            recover: { nil },
            reloadReceipts: {}
        )
        let model = DeadlineDeliveryExecutionModel(dependencies: dependencies)
        model.synchronizePreflight(fixture.publication)
        model.requestSend(input: fixture.input, publication: fixture.publication)
        let confirmationReady = await waitForDeadlineExecutionState(model, timeout: .seconds(2)) {
            if case .awaitingConfirmation = $0 { true } else { false }
        }
        #expect(confirmationReady)
        guard confirmationReady else { return }

        model.confirmAndStart()
        let stagingStarted = await waitForDeadlineExecutionState(model, timeout: .seconds(2)) {
            if case .executing(let progress) = $0 { progress.stage == .staging } else { false }
        }
        #expect(stagingStarted)
        guard stagingStarted else { return }

        model.requestCancellation()

        #expect(await cancellation.waitUntilCancelled(timeout: .seconds(2)))
        #expect(await waitForDeadlineExecutionState(model, timeout: .seconds(2)) {
            $0 == .cancelled
        })
    }

    @Test("Relaunch recovery accepts one exact record and refuses ambiguity")
    @MainActor
    func relaunchRecoveryRequiresUnambiguousExactRecord() async throws {
        let fixture = try await makeDeadlineExecutionFixture()
        let exact = DeadlineDeliveryExecutionModel(dependencies: executionDependencies(
            prepared: fixture.prepared,
            recover: { fixture.prepared }
        ))
        await exact.recoverAfterRelaunch()
        #expect(exact.canResume)

        let ambiguous = DeadlineDeliveryExecutionModel(dependencies: executionDependencies(
            prepared: fixture.prepared,
            recover: { throw DeadlineDeliveryExecutionError.resumeUnavailable }
        ))
        await ambiguous.recoverAfterRelaunch()
        #expect(!ambiguous.canResume)
        #expect(ambiguous.error == .resumeUnavailable)
    }

    @Test("Activity recovery routes only the explicitly selected workflow UUID")
    @MainActor
    func explicitActivityRecoverySelection() async throws {
        let fixture = try await makeDeadlineExecutionFixture()
        let selectedID = UUID(uuidString: "44000000-0000-0000-0000-000000000004")!
        let selected = DeadlinePreparedDeliveryBatch(
            workflowIdentifier: selectedID,
            plan: fixture.prepared.plan,
            stagingRootURL: fixture.prepared.stagingRootURL,
            c2paConsequences: fixture.prepared.c2paConsequences
        )
        var requested: [UUID] = []
        let model = DeadlineDeliveryExecutionModel(dependencies: executionDependencies(
            prepared: fixture.prepared,
            recoverWorkflow: { identifier in
                requested.append(identifier)
                return selected
            }
        ))

        await model.recover(workflowIdentifier: selectedID)

        #expect(requested == [selectedID])
        #expect(model.canResume)
        #expect(model.error == nil)

        await model.recover(workflowIdentifier: UUID())
        #expect(!model.canResume)
        #expect(model.error == .resumeUnavailable)
    }

    @Test("Production session derives every workflow location from the private registry")
    @MainActor
    func productionSessionUsesRegistryLocations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deadline-session-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        let workflowID = UUID(uuidString: "45000000-0000-0000-0000-000000000004")!
        let session = DeadlineDeliveryProductionSession(registryRootURL: root)

        let locations = try await session.locations(for: workflowID)

        #expect(locations.workflowRootURL.deletingLastPathComponent() == root.standardizedFileURL)
        #expect(locations.workflowRootURL.lastPathComponent == workflowID.uuidString.lowercased())
        #expect(locations.planDocumentURL.lastPathComponent == "plan.json")
        #expect(locations.manifestDocumentURL.lastPathComponent == "manifest.json")
        #expect(locations.stagingEvidenceDocumentURL.lastPathComponent == "staging-evidence.json")
        #expect(locations.stagingRootURL.lastPathComponent == "staging")
    }

    @Test("Sent lifecycle reloads Activity receipts exactly once")
    @MainActor
    func sentReloadsReceipts() async throws {
        let fixture = try await makeDeadlineExecutionFixture()
        let receiptID = UUID()
        let reload = DeadlineExecutionProbe()
        let dependencies = DeadlineDeliveryExecutionDependencies(
            prepare: { _ in fixture.prepared },
            start: { batch, _ in
                var manifest = DeliveryWorkflowManifest(
                    workflowIdentifier: batch.workflowIdentifier,
                    planFingerprint: batch.plan.fingerprint,
                    profileIdentifier: batch.plan.profile.id,
                    itemCount: batch.plan.items.count,
                    startedAt: Date(timeIntervalSince1970: 1),
                    remoteStatPolicy: .attemptIfAvailable
                )
                manifest.updatedAt = Date(timeIntervalSince1970: 2)
                manifest.stage = .sent
                manifest.completedReceiptIdentifier = receiptID
                return DeliveryWorkflowResult(
                    manifest: manifest,
                    stagingResult: nil,
                    uploadResult: nil,
                    receipt: nil
                )
            },
            resume: { _, _ in throw DeadlineDeliveryExecutionError.resumeUnavailable },
            cancel: {},
            recover: { nil },
            reloadReceipts: { await reload.increment() }
        )
        let model = DeadlineDeliveryExecutionModel(dependencies: dependencies)
        model.synchronizePreflight(fixture.publication)
        model.requestSend(input: fixture.input, publication: fixture.publication)
        try await Task.sleep(for: .milliseconds(20))
        model.confirmAndStart()
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.state == .sent(receiptIdentifier: receiptID))
        #expect(await reload.count == 1)
    }

    private let root = URL(fileURLWithPath: "/deadline-coordinator", isDirectory: true)

    @Test("Matching composite revisions reuse the cached report")
    func exactRevisionCacheHit() async throws {
        let counter = EvaluationCounter()
        let coordinator = DeadlinePreflightCoordinator { request in
            await counter.increment()
            return try await DeadlinePreflightService().evaluate(request)
        }
        let request = request(named: "Cache")
        let token = revision(metadata: 1)

        let firstPublication = try await coordinator.evaluate(request: request, token: token)
        let secondPublication = try await coordinator.evaluate(request: request, token: token)
        let first = try #require(firstPublication)
        let second = try #require(secondPublication)

        #expect(first.wasCached == false)
        #expect(second.wasCached)
        #expect(first.report == second.report)
        let evaluationCount = await counter.value
        #expect(evaluationCount == 1)
    }

    @Test("Bypass policy neither reads nor writes the revision cache")
    func bypassPolicyAlwaysReevaluates() async throws {
        let counter = EvaluationCounter()
        let coordinator = DeadlinePreflightCoordinator { request in
            await counter.increment()
            return try await DeadlinePreflightService().evaluate(request)
        }
        let request = request(named: "Unrevisioned live input")
        let token = revision(metadata: 1)

        let firstPublication = try await coordinator.evaluate(
            request: request,
            token: token,
            cachePolicy: .bypass
        )
        let secondPublication = try await coordinator.evaluate(
            request: request,
            token: token,
            cachePolicy: .bypass
        )
        let first = try #require(firstPublication)
        let second = try #require(secondPublication)

        #expect(first.wasCached == false)
        #expect(second.wasCached == false)
        #expect(await coordinator.cachedReport(for: token) == nil)
        let evaluationCount = await counter.value
        #expect(evaluationCount == 2)
    }

    @Test("Changing one input revision publishes a fresh report")
    func inputRevisionChangePublishesFreshResult() async throws {
        let counter = EvaluationCounter()
        let coordinator = DeadlinePreflightCoordinator { request in
            await counter.increment()
            return try await DeadlinePreflightService().evaluate(request)
        }
        let request = request(named: "Metadata changed")

        let firstPublication = try await coordinator.evaluate(
            request: request,
            token: revision(metadata: 1)
        )
        let secondPublication = try await coordinator.evaluate(
            request: request,
            token: revision(metadata: 2)
        )
        let first = try #require(firstPublication)
        let second = try #require(secondPublication)

        #expect(first.token != second.token)
        #expect(second.wasCached == false)
        let evaluationCount = await counter.value
        #expect(evaluationCount == 2)
    }

    @Test("Invalidation clears cache and forces reevaluation")
    func invalidation() async throws {
        let counter = EvaluationCounter()
        let coordinator = DeadlinePreflightCoordinator { request in
            await counter.increment()
            return try await DeadlinePreflightService().evaluate(request)
        }
        let request = request(named: "Invalidate")
        let token = revision(metadata: 4)

        _ = try await coordinator.evaluate(request: request, token: token)
        await coordinator.invalidateAll()
        let result = try await coordinator.evaluate(request: request, token: token)
        let publication = try #require(result)

        #expect(publication.wasCached == false)
        let evaluationCount = await counter.value
        #expect(evaluationCount == 2)
    }

    @Test("A superseded evaluator cannot publish stale output even if it ignores cancellation")
    func latestEvaluationWins() async throws {
        let gate = ControlledEvaluation()
        let coordinator = DeadlinePreflightCoordinator { request in
            await gate.evaluate(request)
        }
        let slowRequest = request(named: "Slow")
        let latestRequest = request(named: "Latest")
        let slowToken = revision(metadata: 10)
        let latestToken = revision(metadata: 11)

        let slow = Task {
            try await coordinator.evaluate(request: slowRequest, token: slowToken)
        }
        await gate.waitUntilSlowStarted()
        let latestPublication = try await coordinator.evaluate(
            request: latestRequest,
            token: latestToken
        )
        let latest = try #require(latestPublication)
        await gate.releaseSlow()

        #expect(latest.token == latestToken)
        let stalePublication = try await slow.value
        let staleCachedReport = await coordinator.cachedReport(for: slowToken)
        let latestCachedReport = await coordinator.cachedReport(for: latestToken)
        #expect(stalePublication == nil)
        #expect(staleCachedReport == nil)
        #expect(latestCachedReport != nil)
    }

    @Test("A superseded progressive evaluator cannot publish late stale snapshots")
    func latestProgressWins() async throws {
        let gate = ControlledProgressiveEvaluation()
        let recorder = DeadlineProgressPublicationRecorder()
        let coordinator = DeadlinePreflightCoordinator(progressiveEvaluator: { request, progress in
            await gate.evaluate(request, progress: progress)
        })
        let slowRequest = request(named: "Slow progress")
        let latestRequest = request(named: "Latest progress")
        let slowToken = revision(metadata: 20)
        let latestToken = revision(metadata: 21)

        let slow = Task {
            try await coordinator.evaluate(
                request: slowRequest,
                token: slowToken,
                onProgress: { await recorder.append($0) }
            )
        }
        await gate.waitUntilSlowStarted()
        let latest = try await coordinator.evaluate(
            request: latestRequest,
            token: latestToken,
            onProgress: { await recorder.append($0) }
        )
        await gate.releaseSlow()
        _ = try await slow.value

        let publications = await recorder.values
        #expect(latest?.token == latestToken)
        #expect(publications.contains {
            $0.token == slowToken && $0.progress.stage == .resolvingDependencies
        })
        #expect(publications.contains {
            $0.token == latestToken && $0.progress.stage == .resolvingDependencies
        })
        #expect(!publications.contains {
            $0.token == slowToken && $0.progress.stage == .checkingDelivery
        })
    }

    @Test("Progress UI projection contains only completed immutable image results")
    func progressUIProjection() async throws {
        let progressRecorder = DeadlineProgressRecorderForCoordinatorTests()
        var metadata = IPTCMetadata()
        metadata.description = "{filename}"
        let request = DeadlinePreflightRequest(
            profile: DeadlineProfile(name: "Projection"),
            items: [
                DeadlinePreflightItemSnapshot(sourceURL: root.appendingPathComponent("a.jpg")),
                DeadlinePreflightItemSnapshot(
                    sourceURL: root.appendingPathComponent("b.jpg"),
                    metadata: metadata
                ),
                DeadlinePreflightItemSnapshot(sourceURL: root.appendingPathComponent("c.jpg")),
            ]
        )
        _ = try await DeadlinePreflightService().evaluate(request) {
            await progressRecorder.append($0)
        }
        let progress = try #require(await progressRecorder.values.first {
            $0.stage == .checkingImages && $0.completedImageCount == 2
        })

        let projection = DeadlineWorkspaceProgressState(request: request, progress: progress)
        #expect(projection.stageTitle == "Checking images")
        #expect(projection.completedImageCount == 2)
        #expect(projection.totalImageCount == 3)
        #expect(projection.workspaceState.rows.map(\.imageURL.lastPathComponent) == ["a.jpg", "b.jpg"])
        #expect(projection.workspaceState.blockerCount == 1)
    }

    @Test("Workspace projection filters readiness and preserves exact planned names")
    func workspaceProjection() async throws {
        var blockedMetadata = IPTCMetadata()
        blockedMetadata.description = "{filename}"
        let items = [
            DeadlinePreflightItemSnapshot(
                sourceURL: root.appendingPathComponent("a.jpg"),
                metadata: blockedMetadata
            ),
            DeadlinePreflightItemSnapshot(
                sourceURL: root.appendingPathComponent("b.jpg"),
                c2paConsequence: .derivedOutputDropsManifest
            ),
            DeadlinePreflightItemSnapshot(sourceURL: root.appendingPathComponent("c.jpg")),
        ]
        let profile = DeadlineProfile(
            name: "Wire",
            rename: .init(
                recipe: .snapshot(BatchRenameRecipe(
                    name: "Wire names",
                    components: [.literal("wire_"), .token(.originalFilename)]
                )),
                collisionPolicy: .block
            ),
            destination: .init(connectionIdentifier: "desk", remotePathTemplate: "/wire/{date}"),
            metadataWriteStrategy: .xmpSidecars
        )
        let request = DeadlinePreflightRequest(
            profile: profile,
            items: items,
            delivery: .init(
                connections: ["desk": .reachable],
                remotePathState: .valid(resolvedPath: "/wire/2026-08-21")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(request)
        let state = DeadlineWorkspaceState(request: request, report: report)

        #expect(state.readyCount == 1)
        #expect(state.rows(matching: .blockers).map(\.imageURL.lastPathComponent) == ["a.jpg"])
        #expect(state.rows(matching: .warnings).map(\.imageURL.lastPathComponent) == ["b.jpg"])
        #expect(state.rows(matching: .ready).map(\.imageURL.lastPathComponent) == ["c.jpg"])
        #expect(state.rows.map(\.plannedOutputFilename) == ["wire_a.jpg", "wire_b.jpg", "wire_c.jpg"])
        #expect(state.writeStrategySummary == "Write metadata to XMP sidecars")
        #expect(state.destinationSummary == "desk: /wire/{date}")
        #expect(state.status(for: .caption) == .current)
        #expect(state.status(for: .verify) == .locked)
        #expect(state.status(for: .send) == .locked)
        #expect(state.selectedImageCount == 3)
        #expect(state.readinessSummary == "1 of 3 ready")
        #expect(state.currentStage == .caption)
        #expect(DeadlineWorkspaceStage.allCases.count {
            state.status(for: $0) == .current
        } == 1)
        #expect(state.nextRequiredAction == state.nextIssue?.message)
        #expect(state.nextIssue?.imageURL?.lastPathComponent == "a.jpg")
        #expect(state.nextRemediation == .caption(
            imageURL: root.appendingPathComponent("a.jpg"),
            field: .description
        ))
    }

    @Test("Every typed preflight issue resolves to an actionable remediation target")
    func remediationTargetsAreExhaustive() throws {
        let imageURL = root.appendingPathComponent("target.jpg")
        let codes: [DeadlinePreflightIssueCode] = [
            .missingValidationProfile(reference: "validation"),
            .missingMetadataTemplate(reference: "template"),
            .missingRequiredList(reference: "list"),
            .metadataValidation(ruleID: "headline", field: .headline),
            .unresolvedVariable(field: .description),
            .unresolvedStructuredVariable(field: .creatorContact(field: .email)),
            .sidecarPending,
            .sidecarFailed,
            .missingRenameRecipe(reference: "rename"),
            .renameEnvironmentUnavailable,
            .rename(.duplicateTarget),
            .sourceUnavailable,
            .sourceUnreadable,
            .sourceWritabilityUnknown,
            .sourceNotWritable,
            .unsupportedSourceFormat,
            .sourceCannotDecode,
            .staleDescriptiveMetadataConflict,
            .c2pa(.originalWriteInvalidatesManifest),
            .missingExportConfiguration(reference: "export"),
            .exportCapabilitiesUnknown,
            .unavailableSDRExportFormat(.jpeg),
            .unavailableHDRExportFormat(.jpegGainMap),
            .unavailableSDRExportGamut(.sRGB),
            .unavailableHDRExportGamut(.displayP3),
            .invalidExportQuality,
            .invalidMaximumOutputByteCount,
            .invalidSourceDimensions,
            .exportWillDownscale(maximumDimension: 2048),
            .outputSizeEstimateUnknown(maximumBytes: 1_000_000),
            .estimatedOutputExceedsMaximum(estimatedBytes: 1_000_001, maximumBytes: 1_000_000),
            .deliverySizeUnknown,
            .destinationSpaceUnknown,
            .insufficientDestinationSpace(requiredBytes: 2, availableBytes: 1),
            .stagingUnavailable,
            .stagingInsufficientSpace(requiredBytes: 2, availableBytes: 1),
            .unsupportedDeliveryWriteStrategy(.originals),
            .connectionNotConfigured(identifier: "desk"),
            .connectionReachabilityUnknown(identifier: "desk"),
            .connectionUnreachable(identifier: "desk"),
            .remotePathInvalid,
            .remotePathHasUnresolvedVariables(["date"]),
        ]

        for code in codes {
            #expect(
                DeadlineRemediationDestination.resolve(code: code, imageURL: imageURL) != nil,
                "Missing remediation for \(String(describing: code))"
            )
        }

        #expect(DeadlineRemediationDestination.resolve(
            code: .metadataValidation(ruleID: "headline", field: .headline),
            imageURL: imageURL
        ) == .caption(imageURL: imageURL, field: .headline))
        for field in MetadataFieldID.allCases {
            #expect(DeadlineRemediationDestination.resolve(
                code: .metadataValidation(ruleID: field.rawValue, field: field),
                imageURL: imageURL
            ) == .caption(imageURL: imageURL, field: field))
        }
        #expect(DeadlineRemediationDestination.resolve(
            code: .unresolvedVariable(field: .dateCreated),
            imageURL: imageURL
        ) == .caption(imageURL: imageURL, field: .dateCreated))
        let renameKinds: [RenamePlanIssue.Kind] = [
            .missingValue,
            .recipeProblem,
            .invalidFilename,
            .duplicateTarget,
            .existingDestination,
            .caseInsensitiveCollision,
            .caseOnlyRename,
            .deterministicSuffixApplied,
            .deterministicSuffixExhausted,
        ]
        for kind in renameKinds {
            #expect(DeadlineRemediationDestination.resolve(
                code: .rename(kind),
                imageURL: imageURL
            ) == .renameSettings(imageURL: imageURL))
        }
        let actionableC2PAConsequences: [DeadlineC2PAConsequence] = [
            .originalWriteInvalidatesManifest,
            .derivedOutputDropsManifest,
            .requiresResigning,
            .unsupportedProtectedSource,
        ]
        for consequence in actionableC2PAConsequences {
            #expect(DeadlineRemediationDestination.resolve(
                code: .c2pa(consequence),
                imageURL: imageURL
            ) == .profileSettings)
        }
        #expect(DeadlineRemediationDestination.resolve(
            code: .connectionUnreachable(identifier: "desk"),
            imageURL: nil
        ) == .connectionSettings(identifier: "desk"))
        #expect(DeadlineRemediationDestination.resolve(
            code: .stagingUnavailable,
            imageURL: nil
        ) == .stagingSettings)
    }

    @Test("Per-image remediation fails closed without exact image identity")
    func remediationRequiresExactImageIdentity() {
        #expect(DeadlineRemediationDestination.resolve(
            code: .metadataValidation(ruleID: "headline", field: .headline),
            imageURL: nil
        ) == nil)
        #expect(DeadlineRemediationDestination.resolve(
            code: .sourceUnreadable,
            imageURL: nil
        ) == nil)
        #expect(DeadlineWorkspaceFilter.allCases == [.blockers, .warnings, .ready])
        #expect(DeadlineWorkspaceState.filterScopeExplanation.contains("batch-level in Activity"))
    }

    private func request(named name: String) -> DeadlinePreflightRequest {
        DeadlinePreflightRequest(
            profile: DeadlineProfile(name: name),
            items: [.init(sourceURL: root.appendingPathComponent("a.jpg"))]
        )
    }

    private func revision(metadata: UInt64) -> DeadlinePreflightRevisionToken {
        DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: metadata,
            profileRevision: 3,
            resourceRevision: 4,
            renameEnvironmentRevision: 5,
            exportCapabilityRevision: 6,
            deliverySnapshotRevision: 7
        )
    }
}

private actor EvaluationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct DeadlineExecutionFixture {
    let input: DeadlineWorkspaceInput
    let publication: DeadlinePreflightPublication
    let prepared: DeadlinePreparedDeliveryBatch
}

private func deadlineTestToken(selection: UInt64 = 1) -> DeadlinePreflightRevisionToken {
    DeadlinePreflightRevisionToken(
        selectionSourceRevision: selection,
        metadataRevision: 1,
        profileRevision: 1,
        resourceRevision: 1,
        renameEnvironmentRevision: 1,
        exportCapabilityRevision: 1,
        deliverySnapshotRevision: 1
    )
}

private func makeDeadlineExecutionFixture(
    downscale: Bool = false
) async throws -> DeadlineExecutionFixture {
    let connectionID = "40000000-0000-0000-0000-000000000004"
    let export = DeadlineExportSnapshot(
        sdrFormat: .jpeg,
        sdrQuality: 0.9,
        sdrGamut: .sRGB,
        hdrFormat: .jpegGainMap,
        hdrQuality: 0.85,
        hdrGamut: .displayP3,
        tiffCompression: .lzw,
        resolutionLimit: downscale ? .pixels4000 : .original
    )
    let profile = DeadlineProfile(
        name: "Wire",
        export: .snapshot(export),
        destination: .init(connectionIdentifier: connectionID, remotePathTemplate: "/incoming"),
        metadataWriteStrategy: .stagedCopies
    )
    let sourceURL = URL(fileURLWithPath: "/private/tmp/deadline-execution-source.jpg")
    let metadata = IPTCMetadata()
    let request = DeadlinePreflightRequest(
        profile: profile,
        items: [.init(
            sourceURL: sourceURL,
            metadata: metadata,
            source: .init(
                byteCount: 3,
                pixelWidth: 6000,
                pixelHeight: 4000
            ),
            c2paConsequence: downscale ? .derivedOutputDropsManifest : .none
        )],
        delivery: .init(
            destinationAvailableBytes: 1_000_000,
            estimatedRequiredBytes: 3,
            stagingState: .ready,
            connections: [connectionID: .reachable],
            remotePathState: .valid(resolvedPath: "/incoming"),
            stagingRootURL: URL(fileURLWithPath: "/private/tmp/deadline-staging"),
            stagingAvailableBytes: 1_000_000,
            supportedMetadataWriteStrategies: [.stagedCopies]
        )
    )
    let report = try await DeadlinePreflightService().evaluate(request)
    let token = deadlineTestToken()
    let publication = DeadlinePreflightPublication(token: token, report: report, wasCached: false)
    let revision = SourceImageRevision(
        canonicalURL: sourceURL,
        fileResourceIdentifier: nil,
        filenameAtCreation: sourceURL.lastPathComponent,
        byteCount: 3,
        contentModificationDate: Date(timeIntervalSince1970: 1),
        pixelWidth: 6000,
        pixelHeight: 4000,
        exifOrientation: 1,
        sha256: String(repeating: "a", count: 64),
        hashCompletedAt: Date(timeIntervalSince1970: 2)
    )
    let plan = try DeliveryPlanningService().makePlan(.init(
        preflightRequest: request,
        publication: publication,
        currentRevision: token,
        currentProfile: profile,
        items: [.init(sourceRevision: revision, resolvedMetadata: metadata)],
        acceptedWarningIDs: Set(report.issues.filter { $0.severity == .warning }.map(\.id))
    ))
    return DeadlineExecutionFixture(
        input: DeadlineWorkspaceInput(
            request: request,
            revisionToken: token,
            developSnapshots: [nil],
            sourceRevisions: [revision]
        ),
        publication: publication,
        prepared: DeadlinePreparedDeliveryBatch(
            workflowIdentifier: UUID(),
            plan: plan,
            stagingRootURL: URL(fileURLWithPath: "/private/tmp/deadline-staging/workflow"),
            c2paConsequences: [downscale ? .derivedOutputDropsManifest : .none]
        )
    )
}

@MainActor
private func executionDependencies(
    prepared: DeadlinePreparedDeliveryBatch,
    recover: @escaping () async throws -> DeadlinePreparedDeliveryBatch? = { nil },
    recoverWorkflow: @escaping (UUID) async throws -> DeadlinePreparedDeliveryBatch = { _ in
        throw DeadlineDeliveryExecutionError.resumeUnavailable
    }
) -> DeadlineDeliveryExecutionDependencies {
    DeadlineDeliveryExecutionDependencies(
        prepare: { _ in prepared },
        start: { _, _ in throw DeadlineDeliveryExecutionError.executionFailed },
        resume: { _, _ in throw DeadlineDeliveryExecutionError.resumeUnavailable },
        cancel: {},
        recover: recover,
        reloadReceipts: {},
        recoverWorkflow: recoverWorkflow
    )
}

private actor DeadlineExecutionProbe {
    private(set) var cancelled = false
    private(set) var count = 0

    func markCancelled() { cancelled = true }
    func increment() { count += 1 }

    func waitUntilCancelled(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !cancelled, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cancelled
    }
}

@MainActor
private func waitForDeadlineExecutionState(
    _ model: DeadlineDeliveryExecutionModel,
    timeout: Duration,
    matching predicate: (DeadlineDeliveryExecutionModel.State) -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate(model.state), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate(model.state)
}

private actor ControlledEvaluation {
    private var slowStarted = false
    private var slowStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var slowContinuation: CheckedContinuation<Void, Never>?

    func evaluate(_ request: DeadlinePreflightRequest) async -> DeadlinePreflightReport {
        if request.profile.name == "Slow" {
            slowStarted = true
            slowStartWaiters.forEach { $0.resume() }
            slowStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                slowContinuation = continuation
            }
        }
        return DeadlinePreflightReport(
            issues: [],
            imageReports: request.items.enumerated().map { index, item in
                DeadlinePreflightImageReport(
                    imageIndex: index,
                    imageURL: item.sourceURL,
                    issues: []
                )
            },
            renamePlan: nil
        )
    }

    func waitUntilSlowStarted() async {
        guard !slowStarted else { return }
        await withCheckedContinuation { continuation in
            slowStartWaiters.append(continuation)
        }
    }

    func releaseSlow() {
        slowContinuation?.resume()
        slowContinuation = nil
    }
}

private actor DeadlineProgressPublicationRecorder {
    private(set) var values: [DeadlinePreflightProgressPublication] = []

    func append(_ publication: DeadlinePreflightProgressPublication) {
        values.append(publication)
    }
}

private actor DeadlineProgressRecorderForCoordinatorTests {
    private(set) var values: [DeadlinePreflightProgress] = []

    func append(_ progress: DeadlinePreflightProgress) {
        values.append(progress)
    }
}

private actor ControlledProgressiveEvaluation {
    private var slowStarted = false
    private var slowStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var slowContinuation: CheckedContinuation<Void, Never>?

    func evaluate(
        _ request: DeadlinePreflightRequest,
        progress: DeadlinePreflightService.ProgressHandler
    ) async -> DeadlinePreflightReport {
        await progress(makeProgress(.resolvingDependencies, request: request))
        if request.profile.name == "Slow progress" {
            slowStarted = true
            slowStartWaiters.forEach { $0.resume() }
            slowStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                slowContinuation = continuation
            }
            // Deliberately ignore cancellation. The coordinator generation gate must suppress it.
            await progress(makeProgress(.checkingDelivery, request: request))
        }
        return makeReport(request)
    }

    func waitUntilSlowStarted() async {
        guard !slowStarted else { return }
        await withCheckedContinuation { continuation in
            slowStartWaiters.append(continuation)
        }
    }

    func releaseSlow() {
        slowContinuation?.resume()
        slowContinuation = nil
    }

    private func makeProgress(
        _ stage: DeadlinePreflightProgress.Stage,
        request: DeadlinePreflightRequest
    ) -> DeadlinePreflightProgress {
        DeadlinePreflightProgress(
            stage: stage,
            completedImageCount: stage == .checkingDelivery ? request.items.count : 0,
            totalImageCount: request.items.count,
            reportSnapshot: makeReport(request)
        )
    }

    private func makeReport(_ request: DeadlinePreflightRequest) -> DeadlinePreflightReport {
        DeadlinePreflightReport(
            issues: [],
            imageReports: request.items.enumerated().map { index, item in
                DeadlinePreflightImageReport(
                    imageIndex: index,
                    imageURL: item.sourceURL,
                    issues: []
                )
            },
            renamePlan: nil
        )
    }
}
