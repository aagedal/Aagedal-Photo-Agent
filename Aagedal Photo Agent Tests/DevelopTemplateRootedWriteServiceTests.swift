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

    private func fixture(mode: MetadataWriteMode = .writeToXMPSidecar) throws -> Fixture {
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
            }, retainPreparedMutation: { _, _, _ in count.write((count.read() ?? Data()) + Data([1])) })
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
            }, retainPreparedMutation: { _, _, _ in })
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
            reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { stage, _, _ in
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
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
            }, retainPreparedMutation: { _, _, _ in })
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
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
            reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
        #expect(!result.writeResult.completed && !result.writeResult.requiresRecovery)
        #expect(try Data(contentsOf: XMPSidecarService().sidecarURL(for: f.request.imageURL)) == f.snapshot.xmpBytes)
    }

    @Test("Embedded policy remains unavailable to the rooted sidecar writer")
    func embeddedRefusal() async throws {
        let f = try fixture(mode: .writeToFileAndXMPSidecar)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.request.imageURL); defer { lease.release() }
        let result = await DevelopTemplateRootedWriteService(facade: f.facade).execute(f.request,
            expected: f.snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
                validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
            expected: snapshot, reservation: lease, validateCommitAuthority: { _, _ in }, retainPreparedMutation: { _, _, _ in })
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
            retainPreparedMutation: { stage, _, candidate in
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
            }, retainPreparedMutation: { _, _, _ in })
        #expect(!result.writeResult.completed && result.writeResult.requiresRecovery)
        #expect(result.installedXMP != nil && result.installedAppSidecar != nil)
        #expect(result.writeResult.completion?.installedSidecar == nil)
    }

}
