import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Descriptor-rooted Develop sidecar publication", .serialized)
@MainActor
struct DevelopTemplateRootedWriteServiceTests {
    private struct Fixture: Sendable {
        let root: URL
        let facade: MCPAutomationFacade
        let capture: DevelopTemplateBatchCapture
        let snapshot: MCPPhotoCarrierSnapshot
        let later: MCPPhotoCarrierSnapshot
        nonisolated var request: PrimaryDevelopWriteRequest { capture.intent.requests[0] }
    }

    private func fixture(mode: MetadataWriteMode = .writeToXMPSidecar, legacyApp: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/DevelopRooted-\(UUID())", isDirectory: true)
        let templates = root.appendingPathComponent("Develop", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let photos = [root.appendingPathComponent("first.png"), root.appendingPathComponent("later.png")]
        for photo in photos { try bytes.write(to: photo) }
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:private="https://example.invalid/private" private:Evidence="preserve-me"
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/" tiff:Orientation="6"
        crs:Exposure2012="-0.5" crs:CropTop="0.1" crs:CropLeft="0.2" crs:CropBottom="0.9" crs:CropRight="0.8" crs:CropAngle="0" crs:HasCrop="True"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: photos[0].deletingPathExtension().appendingPathExtension("xmp"))
        let history = MetadataHistoryEntry(timestamp: Date(), fieldName: "Title", oldValue: nil, newValue: "Pending title")
        try MetadataSidecarService().saveSidecar(.init(sourceFile: photos[0].lastPathComponent,
            lastModified: Date(), pendingChanges: true, metadata: IPTCMetadata(title: "Pending title"),
            history: [history]), for: photos[0], in: root)
        let appURL = root.appendingPathComponent(".photo_metadata").appendingPathComponent("first.png.meta.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: appURL)) as? [String: Any])
        object["futurePrivateEvidence"] = ["value": "retain"]
        try JSONSerialization.data(withJSONObject: object).write(to: appURL)
        if legacyApp {
            try FileManager.default.moveItem(at: appURL, to: appURL.deletingLastPathComponent().appendingPathComponent("first.meta.json"))
        }
        var settings = CameraRawSettings(); settings.exposure2012 = 1.25
        let mask = MaskAdjustment(name: "Captured mask", exposure: 0.75)
        settings.localAdjustments = [mask]; settings.layerOrder = [.mask(mask.id), .global]
        let template = DevelopTemplate(name: "Rooted exposure", settings: settings, includesCrop: false)
        let data = try JSONEncoder().encode(template)
        try data.write(to: templates.appendingPathComponent("\(template.id).json"))
        let box = MCPServerCoreTests.DataBox()
        let authorization = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authorization.addRoot(root); try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        let discovery = MCPTemplateDiscovery(authorizationStore: authorization, resolveScope: { .init(directory: root, release: {}) })
        let capture = try DevelopTemplateBatchCaptureService(facade: facade, discovery: discovery).capture(
            templateID: template.id, templateRevision: "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            photos: photos, mode: mode)
        return .init(root: root, facade: facade, capture: capture,
            snapshot: try facade.capturePhotoSnapshot(path: photos[0].path),
            later: try facade.capturePhotoSnapshot(path: photos[1].path))
    }

    private nonisolated func validate(_ expected: MCPPhotoCarrierSnapshot, facade: MCPAutomationFacade,
                                     reservation: MCPProcessReservationLease) throws {
        try facade.withPhotoSnapshot(path: expected.target.url.path, reservation: reservation) { actual in
            guard actual.target == expected.target, actual.sourceRevision == expected.sourceRevision,
                  actual.xmpSidecarRevision == expected.xmpSidecarRevision,
                  actual.appSidecarRevision == expected.appSidecarRevision else {
                throw DevelopTemplateBatchAdmissionFailure.changedEvidence
            }
        }
    }

    @Test("Production staging preserves crop, mask order, editorial history and private fields")
    func productionPublication() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let count = MCPServerCoreTests.DataBox(); count.write(Data())
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request, expected: f.snapshot,
            reservation: lease, validateCommitAuthority: { _, expected in
                try validate(expected, facade: f.facade, reservation: lease)
            }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in count.write((count.read() ?? Data()) + Data([1])) })
        #expect(result.writeResult.completed)
        #expect(count.read()?.count == 2)
        #expect(result.preparedXMP != nil && result.preparedAppSidecar != nil)
        let installedXMP = try #require(result.installedXMP)
        let installedApp = try #require(result.installedAppSidecar)
        #expect(installedXMP.sourceRevision == f.snapshot.sourceRevision)
        #expect(installedXMP.appSidecarRevision == f.snapshot.appSidecarRevision)
        #expect(installedApp.xmpSidecarRevision == installedXMP.xmpSidecarRevision)
        #expect(installedApp.sourceBytes == f.snapshot.sourceBytes)
        let metadata = try #require(XMPSidecarService().loadSidecar(for: f.request.imageURL))
        #expect(metadata.title == "Pending title")
        #expect(metadata.cameraRaw?.exposure2012 == 1.25)
        #expect(metadata.exifOrientation == 6)
        #expect(metadata.cameraRaw?.crop == f.request.edited.cameraRaw?.crop)
        let mask = try #require(metadata.cameraRaw?.localAdjustments?.first)
        #expect(mask.name == "Captured mask" && mask.exposure == 0.75)
        #expect(metadata.cameraRaw?.layerOrder == [.mask(mask.id), .global])
        #expect(String(data: try #require(installedApp.xmpBytes), encoding: .utf8)?.contains("preserve-me") == true)
        let appBytes = try #require(installedApp.appSidecarBytes)
        let object = try #require(JSONSerialization.jsonObject(with: appBytes) as? [String: Any])
        #expect((object["futurePrivateEvidence"] as? [String: String])?["value"] == "retain")
        let saved = try #require(result.writeResult.completion?.installedSidecar)
        #expect(saved.history.map(\.persistentEventID) == f.request.sidecar.history.map(\.persistentEventID))
        #expect(!saved.pendingChanges)
    }

    @Test("Authority refusal at either carrier preserves exact partial outcome", arguments: [false, true])
    func authorityRefusal(afterXMP: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request, expected: f.snapshot,
            reservation: lease, validateCommitAuthority: { stage, _ in
                if stage == (afterXMP ? .appSidecar : .xmp) { throw CancellationError() }
            }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.wasCancelled)
        #expect(result.writeResult.requiresRecovery == afterXMP)
        #expect((result.installedXMP != nil) == afterXMP)
        let current = try f.facade.withPhotoSnapshot(path: f.request.imageURL.path, reservation: lease) { $0 }
        #expect(current.sourceRevision == f.snapshot.sourceRevision)
        #expect(current.appSidecarRevision == f.snapshot.appSidecarRevision)
        #expect((current.xmpSidecarRevision != f.snapshot.xmpSidecarRevision) == afterXMP)
    }

    @Test("Failed durable prepared receipt blocks its physical carrier", arguments: [false, true])
    func preparedReceiptFailure(afterXMP: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request, expected: f.snapshot,
            reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { stage, _, _, _ in
                if stage == (afterXMP ? .appSidecar : .xmp) { throw CocoaError(.fileWriteNoPermission) }
            })
        #expect(!result.writeResult.completed)
        #expect(result.writeResult.requiresRecovery == afterXMP)
        #expect((result.installedXMP != nil) == afterXMP)
        let current = try f.facade.withPhotoSnapshot(path: f.request.imageURL.path, reservation: lease) { $0 }
        #expect(current.appSidecarRevision == f.snapshot.appSidecarRevision)
    }

    @Test("Same-byte source replacement at rename boundary refuses without publication")
    func sameByteSourceReplacement() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        hooks.beforeXMP = { try f.snapshot.sourceBytes.write(to: f.request.imageURL, options: .atomic) }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && !result.writeResult.requiresRecovery)
        #expect(try Data(contentsOf: XMPSidecarService().sidecarURL(for: f.request.imageURL)) == f.snapshot.xmpBytes)
    }

    @Test("Caller validates later photos at both physical stages", arguments: [false, true])
    func changedLaterPhoto(afterXMP: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let laterLease = try MCPProcessReservation.acquirePhoto(f.later.target.url); defer { laterLease.release() }
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        let mutate: @Sendable () throws -> Void = { try f.later.sourceBytes.write(to: f.later.target.url, options: .atomic) }
        if afterXMP { hooks.beforeJSON = mutate } else { hooks.beforeXMP = mutate }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, expected in
                try validate(expected, facade: f.facade, reservation: lease)
                try validate(f.later, facade: f.facade, reservation: laterLease)
            }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery == afterXMP)
        #expect(result.installedAppSidecar == nil)
    }

    @Test("Failure after JSON publication retains committed evidence")
    func failedFinalVerification() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        hooks.afterJSON = { throw CocoaError(.fileReadCorruptFile) }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery)
        #expect(result.installedXMP != nil && result.installedAppSidecar != nil)
        #expect(result.writeResult.completion?.committedButUnverifiedSidecarURL != nil)
        #expect(result.writeResult.completion?.installedSidecar == nil)
    }

    @Test("Released reservation refuses before preparing mutation evidence")
    func releasedReservation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); lease.release()
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request, expected: f.snapshot,
            reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && !result.writeResult.requiresRecovery)
        #expect(result.preparedXMP == nil && result.preparedAppSidecar == nil)
    }
    @Test("Private directory substitution after XMP cannot redirect app metadata")
    func privateDirectorySubstitution() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("first.png.meta.json")
        let sentinelBytes = Data("unrelated destination".utf8)
        try sentinelBytes.write(to: sentinel)
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        hooks.beforeJSON = {
            let directory = f.request.folderURL.appendingPathComponent(".photo_metadata")
            try FileManager.default.moveItem(at: directory, to: f.root.appendingPathComponent("old-metadata"))
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery)
        #expect(result.installedXMP != nil && result.installedAppSidecar == nil)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
    }

    @Test("Withdrawn authorization at XMP boundary refuses before publication")
    func withdrawnAuthorization() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        hooks.beforeXMP = { try f.facade.authorizationStore.setEnabled(false) }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && !result.writeResult.requiresRecovery)
        #expect(try Data(contentsOf: XMPSidecarService().sidecarURL(for: f.request.imageURL)) == f.snapshot.xmpBytes)
    }

    @Test("Embedded policy remains unavailable to the rooted sidecar writer")
    func embeddedRefusal() async throws {
        let f = try fixture(mode: .writeToFileAndXMPSidecar)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && !result.writeResult.requiresRecovery)
        #expect(result.preparedXMP == nil && result.preparedAppSidecar == nil)
    }

    @Test("Caller cancellation crosses the retained transaction task", arguments: [false, true])
    func callerCancellation(afterXMP: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        let pause: @Sendable () throws -> Void = {
            continuation.yield(())
            guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
        }
        if afterXMP { hooks.afterXMP = pause } else { hooks.afterStaging = pause }
        let service = DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks)
        let task = Task {
            defer { continuation.finish() }
            return await service.execute(f.request, expected: f.snapshot, reservation: lease,
                validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel(); release.signal(); continuation.finish()
        let result = await task.value
        #expect(!result.writeResult.completed && result.writeResult.wasCancelled)
        #expect(result.writeResult.requiresRecovery == afterXMP)
        #expect(result.installedAppSidecar == nil)
    }

    @Test("Sole legacy JSON retains its filename and exact uncertain receipt")
    func legacyFilename() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let current = f.request.folderURL.appendingPathComponent(".photo_metadata").appendingPathComponent("first.png.meta.json")
        let legacy = current.deletingLastPathComponent().appendingPathComponent("first.meta.json")
        try FileManager.default.moveItem(at: current, to: legacy)
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let snapshot = try f.facade.withPhotoSnapshot(path: f.request.imageURL.path, reservation: lease) { $0 }
        var hooks = DevelopTemplateRootedWriteService.Hooks()
        hooks.afterJSON = { throw CocoaError(.fileReadCorruptFile) }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade, hooks: hooks).execute(f.request,
            expected: snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery)
        #expect(result.installedAppSidecar != nil)
        #expect(result.appSidecarURL == legacy)
        #expect(result.writeResult.completion?.committedButUnverifiedSidecarURL == legacy)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    @Test("Prepared inode and bytes are rechecked after durable receipt I/O",
          arguments: ["xmp-replace", "xmp-edit", "app-replace", "app-edit"])
    func stagedMutationDuringRetention(attack: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let attacksApp = attack.hasPrefix("app")
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in },
            retainInstalledMutation: { _, _ in }, retainPreparedMutation: { stage, _, candidate, _ in
                guard stage == (attacksApp ? .appSidecar : .xmp) else { return }
                let directory = attacksApp ? f.request.folderURL.appendingPathComponent(".photo_metadata") : f.request.folderURL
                let prefix = attacksApp ? ".automation-draft-" : ".automation-xmp-"
                let name = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(prefix) })
                let staged = directory.appendingPathComponent(name)
                if attack.hasSuffix("replace") {
                    // Identical bytes with an unjournaled inode must also refuse.
                    try candidate.write(to: staged, options: .atomic)
                } else {
                    try Data(repeating: 0x78, count: candidate.count).write(to: staged)
                }
            })
        #expect(!result.writeResult.completed)
        #expect(result.installedAppSidecar == nil)
        let final = try f.facade.withPhotoSnapshot(path: f.request.imageURL.path, reservation: lease) { $0 }
        #expect(final.sourceRevision == f.snapshot.sourceRevision)
        #expect(final.appSidecarRevision == f.snapshot.appSidecarRevision)
        if attacksApp {
            #expect(result.installedXMP != nil)
            #expect(final.xmpSidecarRevision == result.installedXMP?.xmpSidecarRevision)
        } else {
            #expect(result.installedXMP == nil)
            #expect(final.xmpSidecarRevision == f.snapshot.xmpSidecarRevision)
        }
    }

    @Test("Carrier drift during terminal authority validation cannot claim completion")
    func terminalAuthorityDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { stage, installed in
                if stage == .verification {
                    try #require(installed.xmpBytes).write(to: XMPSidecarService().sidecarURL(for: f.request.imageURL), options: .atomic)
                }
            }, retainInstalledMutation: { _, _ in }, retainPreparedMutation: { _, _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery)
        #expect(result.installedXMP != nil && result.installedAppSidecar != nil)
        #expect(result.writeResult.completion?.installedSidecar == nil)
    }

    @Test("Durable rooted journal retains exact ordered physical evidence across restart", arguments: [false, true])
    func durableJournal(legacyApp: Bool) async throws {
        let f = try fixture(legacyApp: legacyApp); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let directory = f.root.appendingPathComponent("journal")
        let store = DevelopTemplateRootedMutationStore(directory: directory)
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "sidecar-policy")
        let result = try await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, evidence: evidence, mutationStore: store,
            validateCommitAuthority: { _, expected in try validate(expected, facade: f.facade, reservation: lease) })
        #expect(result.writeResult.completed)
        let restarted = DevelopTemplateRootedMutationStore(directory: directory)
        let record = try #require(try restarted.load())
        #expect(record.material.batchID == f.capture.intent.id)
        #expect(record.material.requestID == f.request.id)
        #expect(record.material.originalXMP == f.snapshot.xmpBytes)
        #expect(record.material.originalApp == f.snapshot.appSidecarBytes)
        #expect(record.mutations.map(\.carrier) == [.xmp, .appSidecar])
        #expect(record.mutations[0].candidate == result.installedXMP?.xmpBytes)
        #expect(record.mutations[1].candidate == result.installedAppSidecar?.appSidecarBytes)
        #expect(record.mutations[0].identity == result.preparedXMP)
        #expect(record.mutations[1].identity == result.preparedAppSidecar)
        #expect(record.mutations[1].destination.lastPathComponent == (legacyApp ? "first.meta.json" : "first.png.meta.json"))
        #expect(record.mutations[1].installedRevision == result.installedAppSidecar?.appSidecarRevision)
        #expect(!record.hasUnresolvedPreparation)
        try restarted.retain(record.material)
        #expect(try restarted.load() == record)
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.invalidTransition) {
            try restarted.recordPrepared(record.material, carrier: .xmp,
                identity: record.mutations[0].identity, candidate: record.mutations[0].candidate, destination: record.mutations[0].destination)
        }
    }

    private func runningCheckpoint(_ f: Fixture) async throws -> (DevelopTemplateBatchCheckpointStore, DevelopTemplateBatchAdmissionEvidence, DevelopTemplateBatchExecutionResult) {
        let store = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("batches"))
        var state = DevelopTemplateBatchExecutionResult(intent: f.capture.intent, results: [nil, nil])
        try await store.retain(state)
        state.outcome = .running; state.activeRequestID = f.request.id
        try await store.retain(state)
        return (store, try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "policy"), state)
    }

    @Test("Checkpoint-owned journal survives restart without claiming batch completion")
    func checkpointJournalPublication() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (checkpoints, evidence, _) = try await runningCheckpoint(f)
        let journal = try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.request.id)
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let result = try await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, evidence: evidence, mutationStore: journal,
            validateCommitAuthority: { _, expected in try validate(expected, facade: f.facade, reservation: lease) })
        #expect(result.writeResult.completed)
        let before = try await checkpoints.load(f.capture.intent.id)
        let restarted = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("batches"))
        let inventory = try await restarted.recoveryInventory()
        #expect(inventory.count == 1 && inventory[0].issue == nil)
        #expect(inventory[0].rootedMutations.first?.mutations.count == 2)
        let reviews = try await DevelopTemplateBatchRecoveryService(store: restarted).inspect()
        #expect(reviews.first?.needsReview == true)
        #expect(reviews.first?.photos.first?.completed == nil)
        #expect(reviews.first?.photos.first?.physicalEvidence.count == 2)
        let after = try await restarted.load(f.capture.intent.id)
        #expect(after.formatVersion == 2)
        #expect(after.sequence == before.sequence && after.recoveryData == before.recoveryData)
        #expect(after.activeRequestID == f.request.id && after.completedCount == 0)
    }

    @Test("Checkpoint attachment refuses missing, prepared, wrong-active and substituted evidence")
    func checkpointJournalAdmission() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let missing = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("missing"))
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "policy")
        await #expect(throws: (any Error).self) { try await missing.rootedMutationStore(evidence: evidence, requestID: f.request.id) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("missing").path))
        let checkpoints = DevelopTemplateBatchCheckpointStore(directory: f.root.appendingPathComponent("batches"))
        var state = DevelopTemplateBatchExecutionResult(intent: f.capture.intent, results: [nil, nil])
        try await checkpoints.retain(state)
        await #expect(throws: (any Error).self) { try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.request.id) }
        state.outcome = .running; state.activeRequestID = f.request.id
        try await checkpoints.retain(state)
        await #expect(throws: (any Error).self) { try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.capture.intent.requests[1].id) }
        _ = try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.request.id)
        let changed = try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "changed-policy")
        await #expect(throws: (any Error).self) { try await checkpoints.rootedMutationStore(evidence: changed, requestID: f.request.id) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("batches/\(f.capture.intent.id.uuidString)/RootedMutations").path))
    }

    @Test("Bound review checksum detects corruption and preserves the retained checkpoint")
    func checkpointJournalBindingCorruption() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (checkpoints, evidence, _) = try await runningCheckpoint(f)
        _ = try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.request.id)
        let file = f.root.appendingPathComponent("batches/\(f.capture.intent.id.uuidString)/operations.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["rootedAdmissionEvidenceSHA256"] = "invalid"
        let changed = try JSONSerialization.data(withJSONObject: object)
        try changed.write(to: file)
        await #expect(throws: (any Error).self) { try await checkpoints.load(f.capture.intent.id) }
        let reviews = try await DevelopTemplateBatchRecoveryService(store: checkpoints).inspect()
        #expect(reviews.first?.issue == .corrupt && reviews.first?.needsReview == true)
        #expect(try Data(contentsOf: file) == changed)
    }

    @Test("Retained handles recheck terminal checkpoint before every journal mutation")
    func checkpointJournalStaleHandle() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (checkpoints, evidence, running) = try await runningCheckpoint(f)
        let journal = try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.request.id)
        let material = try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: f.request, original: f.snapshot)
        try journal.retain(material)
        var terminal = running; terminal.outcome = .recoveryRequired
        try await checkpoints.retain(terminal)
        #expect(try await checkpoints.load(f.capture.intent.id).formatVersion == 2)
        #expect(throws: (any Error).self) { try journal.retain(material) }
        #expect(throws: (any Error).self) {
            try journal.recordPrepared(material, carrier: .xmp,
                identity: .init(file: .init(device: 1, inode: 42), size: 3, modificationSeconds: 1, modificationNanoseconds: 0),
                candidate: Data("xmp".utf8), destination: f.request.imageURL.deletingPathExtension().appendingPathExtension("xmp"))
        }
        #expect(try journal.load()?.mutations.isEmpty == true)
    }

    @Test("Recovery preserves interrupted, corrupt, orphaned and symlink journal evidence", arguments: ["prepared", "corrupt", "orphan", "symlink", "missing-lock"])
    func checkpointJournalRecovery(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (checkpoints, evidence, _) = try await runningCheckpoint(f)
        let journal = try await checkpoints.rootedMutationStore(evidence: evidence, requestID: f.request.id)
        let material = try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: f.request, original: f.snapshot)
        try journal.retain(material)
        try journal.recordPrepared(material, carrier: .xmp,
            identity: .init(file: .init(device: 1, inode: 42), size: 3, modificationSeconds: 1, modificationNanoseconds: 0),
            candidate: Data("xmp".utf8), destination: f.request.imageURL.deletingPathExtension().appendingPathExtension("xmp"))
        let base = f.root.appendingPathComponent("batches/\(f.capture.intent.id.uuidString)/RootedMutations")
        let child = base.appendingPathComponent(f.request.id.uuidString)
        if kind == "corrupt" { try Data("broken".utf8).write(to: child.appendingPathComponent("operations.json")) }
        if kind == "missing-lock" { try FileManager.default.removeItem(at: child.appendingPathComponent("operations.lock")) }
        if kind == "orphan" { try FileManager.default.createDirectory(at: base.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false) }
        if kind == "symlink" {
            try FileManager.default.moveItem(at: child, to: f.root.appendingPathComponent("saved-journal"))
            try FileManager.default.createSymbolicLink(at: child, withDestinationURL: f.root.appendingPathComponent("saved-journal"))
        }
        let before = try await checkpoints.load(f.capture.intent.id)
        let reviews = try await DevelopTemplateBatchRecoveryService(store: checkpoints).inspect()
        #expect(reviews.first?.needsReview == true && reviews.first?.photos.count == 2)
        #expect((reviews.first?.issue != nil) == (kind != "prepared"))
        if kind == "prepared" {
            #expect(reviews.first?.photos.first?.physicalEvidence.count == 1)
            #expect(reviews.first?.photos.first?.completed == nil)
        }
        let after = try await checkpoints.load(f.capture.intent.id)
        #expect(after.sequence == before.sequence && after.recoveryData == before.recoveryData)
        if kind == "missing-lock" { #expect(!FileManager.default.fileExists(atPath: child.appendingPathComponent("operations.lock").path)) }
    }

    @Test("Failed installed retention stops the next carrier and returns physical evidence", arguments: [false, true])
    func installedRetentionFailure(afterApp: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let store = DevelopTemplateRootedMutationStore(directory: f.root.appendingPathComponent("journal"))
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "policy")
        let material = try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: f.request, original: f.snapshot)
        try store.retain(material)
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in },
            retainInstalledMutation: { stage, snapshot in
                if stage == (afterApp ? .appSidecar : .xmp) { throw CocoaError(.fileWriteNoPermission) }
                try store.recordInstalled(material, carrier: .xmp, snapshot: snapshot)
            }, retainPreparedMutation: { stage, identity, bytes, destination in
                try store.recordPrepared(material, carrier: stage == .xmp ? .xmp : .appSidecar, identity: identity, candidate: bytes, destination: destination)
            })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery)
        #expect(result.installedXMP != nil)
        #expect((result.installedAppSidecar != nil) == afterApp)
        let record = try #require(try store.load())
        #expect(record.hasUnresolvedPreparation)
        #expect(record.mutations.count == (afterApp ? 2 : 1))
        #expect(record.mutations.last?.installedRevision == nil)
    }

    @Test("Journal refuses reordered preparation, substituted review and installed identity")
    func journalRefusals() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = DevelopTemplateRootedMutationStore(directory: f.root.appendingPathComponent("journal"))
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "policy")
        let material = try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: f.request, original: f.snapshot)
        let identity = MCPPreparedXMPIdentity(file: .init(device: 1, inode: 42), size: 3,
            modificationSeconds: 1, modificationNanoseconds: 0)
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.invalidTransition) {
            try store.recordPrepared(material, carrier: .xmp, identity: identity, candidate: Data("xmp".utf8), destination: f.request.imageURL.deletingPathExtension().appendingPathExtension("xmp"))
        }
        try store.retain(material)
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.invalidTransition) {
            try store.recordPrepared(material, carrier: .appSidecar, identity: identity, candidate: Data("app".utf8), destination: f.request.folderURL.appendingPathComponent(".photo_metadata/first.png.meta.json"))
        }
        try store.recordPrepared(material, carrier: .xmp, identity: identity, candidate: Data("xmp".utf8), destination: f.request.imageURL.deletingPathExtension().appendingPathExtension("xmp"))
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.invalidTransition) {
            try store.recordInstalled(material, carrier: .xmp, snapshot: f.snapshot)
        }
        let changed = try DevelopTemplateRootedMutationStore.Material(evidence:
            DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "changed-policy"),
            request: f.request, original: f.snapshot)
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.changedMaterial) { try store.retain(changed) }
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.invalidMaterial) {
            try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: f.request, original: f.later)
        }
        #expect(try store.load()?.hasUnresolvedPreparation == true)
    }

    @Test("Checksummed invalid recovery material and prepared identities are refused",
          arguments: ["material", "app-bytes", "app-absent", "timestamp", "device", "destination", "order", "checksum"])
    func corruptJournal(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("journal")
        let store = DevelopTemplateRootedMutationStore(directory: directory)
        let evidence = try DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "policy")
        let material = try DevelopTemplateRootedMutationStore.Material(evidence: evidence, request: f.request, original: f.snapshot)
        try store.retain(material)
        try store.recordPrepared(material, carrier: .xmp,
            identity: .init(file: .init(device: 1, inode: 42), size: 3, modificationSeconds: 1, modificationNanoseconds: 0),
            candidate: Data("xmp".utf8), destination: f.request.imageURL.deletingPathExtension().appendingPathExtension("xmp"))
        let url = directory.appendingPathComponent("operations.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let payloadString = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: payloadString))
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        if kind == "material" || kind.hasPrefix("app-") {
            var binding = try #require(object["material"] as? [String: Any])
            if kind == "material" { binding["batchID"] = UUID().uuidString }
            else if kind == "app-absent" { binding.removeValue(forKey: "originalApp") }
            else { binding["originalApp"] = Data("invalid original app bytes".utf8).base64EncodedString() }
            object["material"] = binding
        } else if kind != "checksum" {
            var mutations = try #require(object["mutations"] as? [[String: Any]])
            if kind == "order" { mutations[0]["carrier"] = "appSidecar" }
            else if kind == "destination" { mutations[0]["destination"] = f.later.target.url.absoluteString }
            else {
                var identity = try #require(mutations[0]["identity"] as? [String: Any])
                if kind == "timestamp" { identity["modificationNanoseconds"] = -1 }
                else {
                    var file = try #require(identity["file"] as? [String: Any])
                    file["device"] = 0; identity["file"] = file
                }
                mutations[0]["identity"] = identity
            }
            object["mutations"] = mutations
        }
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        envelope["payload"] = changed.base64EncodedString()
        envelope["sha256"] = kind == "checksum" ? "invalid" : SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let restarted = DevelopTemplateRootedMutationStore(directory: directory)
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.corruptJournal) { try restarted.load() }
        #expect(throws: DevelopTemplateRootedMutationStore.Failure.corruptJournal) { try restarted.retain(material) }
    }

    @Test("Prepared journal survives refusal before rename without claiming installation", arguments: [false, true])
    func interruptedJournal(afterXMP: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let directory = f.root.appendingPathComponent("journal")
        let store = DevelopTemplateRootedMutationStore(directory: directory)
        let material = try DevelopTemplateRootedMutationStore.Material(evidence:
            DevelopTemplateBatchAdmissionEvidence(capture: f.capture, configurationRevision: "policy"),
            request: f.request, original: f.snapshot)
        try store.retain(material)
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in },
            retainInstalledMutation: { stage, snapshot in
                try store.recordInstalled(material, carrier: stage == .xmp ? .xmp : .appSidecar, snapshot: snapshot)
            }, retainPreparedMutation: { stage, identity, bytes, destination in
                try store.recordPrepared(material, carrier: stage == .xmp ? .xmp : .appSidecar, identity: identity, candidate: bytes, destination: destination)
                if stage == (afterXMP ? .appSidecar : .xmp) { throw CancellationError() }
            })
        #expect(!result.writeResult.completed)
        #expect(result.writeResult.requiresRecovery == afterXMP)
        let record = try #require(try DevelopTemplateRootedMutationStore(directory: directory).load())
        #expect(record.hasUnresolvedPreparation)
        #expect(record.mutations.count == (afterXMP ? 2 : 1))
        #expect(record.mutations.last?.installedRevision == nil)
        #expect(result.installedAppSidecar == nil)
    }

}
