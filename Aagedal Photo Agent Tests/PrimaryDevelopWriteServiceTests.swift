import AppKit
import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

private actor PrimaryTestFailureGate {
    private var remaining = 1
    func failOnce() throws {
        if remaining > 0 { remaining -= 1; throw CocoaError(.fileWriteNoPermission) }
    }
}

private actor PrimaryTestCallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private nonisolated final class PrimaryTestCommitAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var revoked = false
    let refuseAt: Int
    init(refuseAt: Int) { self.refuseAt = refuseAt }
    func validate() throws {
        try lock.withLock {
            calls += 1
            if revoked || calls == refuseAt { throw CocoaError(.fileWriteNoPermission) }
        }
    }
    var count: Int { lock.withLock { calls } }
    func revoke() { lock.withLock { revoked = true } }
}

private nonisolated final class PrimaryTestReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func pauseIfArmed() {
        let pause = lock.withLock { if armed { armed = false; return true }; return false }
        if pause { entered.signal(); _ = release.wait(timeout: .now() + 10) }
    }
}

@Suite("Retained Primary Develop writes and recovery", .serialized)
@MainActor
struct PrimaryDevelopWriteServiceTests {
    private func fixture() throws -> (URL, URL) {
        let folder = URL(fileURLWithPath: "/private/tmp/PrimaryDevelop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        return (folder, image)
    }
    private func settings(_ exposure: Double) -> CameraRawSettings {
        var settings = CameraRawSettings(); settings.exposure2012 = exposure
        settings.localAdjustments = [MaskAdjustment(name: "Retained mask", geometry: EllipseMaskGeometry())]
        return settings
    }
    private func request(_ image: URL, mode: MetadataWriteMode = .writeToXMPSidecar,
                         reset: Bool = false, predecessor: PrimaryDevelopWriteRequest? = nil,
                         dependencies: [PrimaryDevelopWatermarkDependency] = []) async throws -> PrimaryDevelopWriteRequest {
        let folder = image.deletingLastPathComponent()
        let service = MetadataSidecarService()
        let current = service.loadSidecar(for: image, in: folder)
        let xmp = try await PendingMetadataWriteService.strictXMP(for: image)
        let source = try await SourceImageRevision.capture(at: image)
        let original = current?.metadata ?? xmp.metadata ?? IPTCMetadata()
        var edited = original; edited.title = "Primary result"; edited.cameraRaw = reset ? nil : settings(1.25)
        let changes = MetadataHistoryEntry.changes(from: original, to: edited, timestamp: Date())
        var history = current?.history ?? []; history.append(contentsOf: changes); history.trimToHistoryLimit()
        let record = MetadataSidecar(sourceFile: image.lastPathComponent, pendingChanges: false,
            metadata: edited, imageMetadataSnapshot: edited, history: history)
        var fields = edited.toOverwriteFields()
        if let settings = edited.cameraRaw { fields.merge(settings.developWriteFields()) { _, new in new } }
        else { fields[.crsVersion] = ""; fields[.crsHasSettings] = "" }
        let structured = StructuredWriteData(masks: edited.cameraRaw?.localAdjustments,
            editorial: .init(metadata: edited), replaceCameraRawBlock: true)
        return .init(imageURL: image, folderURL: folder, loadID: UUID(), mode: mode,
            edited: edited, previous: original, original: original, expectedRecord: current,
            expectedXMP: xmp.snapshot, sourceRevision: source, captureFailure: nil, sidecar: record,
            changes: changes, fields: fields, structured: structured, replaceDevelop: true,
            replaceOrientation: false, predecessor: predecessor, watermarkDependencies: dependencies)
    }
    private func load(_ model: MetadataViewModel, image: URL, folder: URL) async throws {
        model.loadMetadata(for: [ImageFile(url: image)], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        #expect(model.metadata != nil)
    }

    @Test("A RAW+JPEG pair's JPEG saves Develop into its own file; the RAW's crs stays; a C2PA pair is refused unretained")
    func pairedJPEGDevelopUsesEmbeddedDestination() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/PrimaryDevelopPair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("IMG_1.ARW")
        try Data("placeholder raw".utf8).write(to: raw)
        let jpeg = folder.appendingPathComponent("IMG_1.jpg")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: jpeg)
        // The JPEG's own embedded caption differs from the shared sidecar record.
        try await SwiftExifWriteEngine().writeFields([.description: "JPEG own caption"], to: [jpeg])
        var rawCRS = CameraRawSettings(); rawCRS.temperature = 5500; rawCRS.exposure2012 = 1.25
        try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "Shared caption", cameraRaw: rawCRS), for: raw)

        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator())
        try await load(model, image: jpeg, folder: folder)
        #expect(model.editingMetadata.title == "Shared caption")
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == nil)

        var jpegCRS = CameraRawSettings(); jpegCRS.exposure2012 = -0.5
        model.editingMetadata.cameraRaw = jpegCRS
        // An unsaved panel edit rides along in the editor buffer; it must not be embedded.
        model.editingMetadata.title = "Unsaved panel headline"
        model.markChanged()
        var outcome: MetadataCommitResult?
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar) { outcome = $0 }
        await model.waitForPrimaryDevelopWrites()
        if case .succeeded = outcome {} else { Issue.record("Paired JPEG Develop save did not succeed: \(String(describing: outcome)) \(model.saveError ?? "")") }
        #expect(!model.hasRetainedPrimaryDevelopWrites)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [jpeg])[jpeg])
        #expect(physical.cameraRaw?.exposure2012 == -0.5)
        // Develop-only embed: the JPEG's own descriptive record is untouched.
        #expect(physical.description == "JPEG own caption")
        #expect(physical.title == nil)
        let shared = try #require(XMPSidecarService().loadSidecar(for: raw))
        #expect(shared.cameraRaw?.exposure2012 == 1.25)
        #expect(shared.cameraRaw?.temperature == 5500)

        // Reload reads the JPEG's own embedded develop, not the RAW's sidecar block.
        let other = folder.appendingPathComponent("other.jpg")
        try FileManager.default.copyItem(at: jpeg, to: other)
        try await load(model, image: other, folder: folder)
        try await load(model, image: jpeg, folder: folder)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == -0.5)

        // A paired JPEG with Content Credentials has no destination: refused, nothing retained.
        var credentialed = ImageFile(url: jpeg); credentialed.hasC2PA = true
        model.loadMetadata(for: [credentialed], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.primaryDevelopRefusal(for: jpeg) != nil)
        model.editingMetadata.cameraRaw?.exposure2012 = 2
        model.markChanged()
        outcome = nil
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar) { outcome = $0 }
        if case .failed = outcome {} else { Issue.record("A C2PA paired JPEG must be refused") }
        #expect(model.retainedPrimaryDevelopWrites.isEmpty && !model.hasRetainedPrimaryDevelopWrites)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == -0.5)
        #expect(!model.hasUncapturedPrimaryDevelopEdits(mode: .writeToXMPSidecar))
        let unchanged = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [jpeg])[jpeg])
        #expect(unchanged.cameraRaw?.exposure2012 == -0.5)
        #expect(XMPSidecarService().loadSidecar(for: raw)?.cameraRaw?.exposure2012 == 1.25)
    }

    @Test("Named Develop versions follow a paired JPEG's metadata-only Primary rewrite")
    func developVersionsFollowMetadataOnlyRewrite() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/PrimaryDevelopVersions-\(UUID().uuidString)", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("placeholder raw".utf8).write(to: folder.appendingPathComponent("IMG_9.ARW"))
        let jpeg = folder.appendingPathComponent("IMG_9.jpg")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: jpeg)
        let factory: DevelopVersionSessionCoordinator.RepositoryFactory = {
            DevelopVersionCatalogRepository(sourceFolderURL: $0, applicationSupportURL: support)
        }

        func openSession() async throws -> DevelopVersionSessionCoordinator {
            let session = DevelopVersionSessionCoordinator(repositoryFactory: factory)
            session.beginLoading(imageURL: jpeg, orientation: 1, onCatalogReady: {})
            let deadline = ContinuousClock.now + .seconds(10)
            while session.persistenceState == .loading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return session
        }

        let session = try await openSession()
        var catalog = try #require(session.catalog)
        var look = CameraRawSettings(); look.exposure2012 = 0.75
        try catalog.createVersion(name: "Look", settings: look)
        session.storage = try await DevelopVersionCatalogRepository(sourceFolderURL: folder,
            applicationSupportURL: support).save(catalog)
        session.catalog = catalog

        // The paired JPEG's Develop save: a metadata-only rewrite of the source.
        var crs = CameraRawSettings(); crs.exposure2012 = -1
        try await SwiftExifWriteEngine().writeFields(crs.developWriteFields(), to: [jpeg])
        let rewritten = try await SourceImageRevision.capture(at: jpeg)
        #expect(rewritten.sha256 != catalog.source.sha256)
        await session.followMetadataOnlyRewrite(of: jpeg)
        #expect(session.revision?.sha256 == rewritten.sha256)
        #expect(session.catalog?.source.sha256 == rewritten.sha256)
        #expect(session.notice == nil)

        let reopened = try await openSession()
        #expect(reopened.notice == nil)
        #expect(reopened.catalog?.versions.map(\.name) == ["Look"])
    }

    @Test("XMP Primary save preserves pixels and actual mask/settings receipt")
    func xmpCompletion() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured)
        #expect(result.completed)
        #expect(!result.wroteEmbedded && result.completion?.wroteXMPSidecar == true)
        #expect(try Data(contentsOf: image) == original)
        let actual = try #require(XMPSidecarService().loadSidecar(for: image))
        #expect(actual.cameraRaw?.exposure2012 == 1.25)
        #expect(actual.cameraRaw?.localAdjustments?.count == 1)
        #expect(result.completion?.writtenXMPSnapshot?.data == (try Data(contentsOf: XMPSidecarService().sidecarURL(for: image))))
    }

    @Test("Commit authority refusal preserves physical evidence at each XMP/JSON boundary", arguments: [1, 2, 3])
    func commitAuthorityRefusal(boundary: Int) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image)
        let authority = PrimaryTestCommitAuthority(refuseAt: boundary)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured,
            validateCommitAuthority: { try authority.validate() })
        #expect(!result.completed)
        #expect(authority.count == boundary)
        #expect(try Data(contentsOf: image) == original)
        #expect(result.completion?.wroteXMPSidecar == (boundary > 1))
        #expect(result.requiresRecovery == (boundary > 1))
        let json = MetadataSidecarService().loadSidecar(for: image, in: folder)
        #expect((json != nil) == (boundary == 3))
        if boundary == 3 {
            #expect(result.completion?.committedButUnverifiedSidecarURL != nil)
            // JSON intentionally retains the editorial projection; CRS lives in XMP.
            #expect(json?.metadata.title == captured.sidecar.metadata.title)
            #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == 1.25)
        }
    }

    @Test("Authority revoked after async admission refuses the next physical carrier", arguments: [true, false])
    func authorityRevokedAfterAdmission(beforeXMP: Bool) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(image)
        let authority = PrimaryTestCommitAuthority(refuseAt: Int.max)
        var hooks = PrimaryDevelopWriteHooks()
        if beforeXMP { hooks.beforeXMP = { authority.revoke() } }
        else { hooks.beforeJSON = { authority.revoke() } }
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine(), hooks: hooks)
            .execute(captured, validateCommitAuthority: { try authority.validate() })
        #expect(!result.completed)
        #expect(result.completion?.wroteXMPSidecar == !beforeXMP)
        #expect(result.requiresRecovery == !beforeXMP)
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder) == nil)
    }

    @Test("Embedded authority refusal distinguishes untouched source from committed physical evidence", arguments: [1, 2, 3])
    func embeddedCommitAuthorityRefusal(boundary: Int) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        let authority = PrimaryTestCommitAuthority(refuseAt: boundary)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured,
            validateCommitAuthority: { try authority.validate() })
        #expect(!result.completed && result.failure != nil && !result.wasCancelled)
        #expect(authority.count == boundary)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .allSatisfy { !$0.hasPrefix(".aagedal_primary_") })
        #expect(!result.wroteEmbedded)
        #expect(result.embeddedMayHaveBeenWritten == (boundary == 3))
        #expect(result.requiresRecovery == (boundary == 3))
        #expect(result.completion == nil)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: image).path))
        #expect(MetadataSidecarService().loadSidecar(for: image, in: folder) == nil)
        if boundary < 3 {
            #expect(try Data(contentsOf: image) == original)
            #expect(result.sourceRevision == nil)
        } else {
            #expect(try Data(contentsOf: image) != original)
            let actualRevision = try await SourceImageRevision.capture(at: image)
            #expect(result.sourceRevision?.canonicalURL == actualRevision.canonicalURL)
            #expect(result.sourceRevision?.sha256 == actualRevision.sha256)
            let actual = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
            #expect(actual.title == captured.edited.title)
            #expect(actual.cameraRaw?.exposure2012 == 1.25)
            #expect(actual.cameraRaw?.localAdjustments?.count == 1)
            let payload = PrimaryDevelopRecoveryPayload(captured, result: result)
            #expect(payload.embeddedMayHaveBeenWritten)
            #expect(payload.writtenSourceRevision?.sha256 == actualRevision.sha256)
        }
    }

    @Test("Embedded publication rechecks authority revoked during awaited admission")
    func embeddedAuthorityRevokedDuringAdmission() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        let authority = PrimaryTestCommitAuthority(refuseAt: Int.max)
        do {
            _ = try await SwiftExifWriteEngine().writePrimaryDevelop(captured,
                validatePreparedIntent: {
                    await Task.yield()
                    authority.revoke()
                }, validateCommitAuthority: { try authority.validate() })
            Issue.record("Revoked embedded authority unexpectedly published")
        } catch let error as PrimaryDevelopPhysicalError {
            #expect(!error.mayHaveWritten && error.sourceRevision == nil && !error.wasCancelled)
        }
        #expect(authority.count == 1)
        #expect(try Data(contentsOf: image) == original)
    }

    @Test("Embedded authority runs after serialization with source intact and cleans refused staging")
    func embeddedAuthorityAfterStaging() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        do {
            _ = try await SwiftExifWriteEngine().writePrimaryDevelop(captured,
                validatePreparedIntent: {}, validateCommitAuthority: {
                    #expect(try Data(contentsOf: image) == original)
                    let staged = try FileManager.default.contentsOfDirectory(at: folder,
                        includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".aagedal_primary_") }
                    #expect(staged.count == 1)
                    let stagedDirectory = try #require(staged.first)
                    let permissions = try FileManager.default.attributesOfItem(atPath: stagedDirectory.path)[.posixPermissions] as? NSNumber
                    #expect(permissions?.intValue == 0o700)
                    let actual = try readMetadata(from: stagedDirectory.appendingPathComponent(image.lastPathComponent))
                    let exposure = actual.xmp?.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/",
                        property: "Exposure2012").flatMap(Double.init)
                    #expect(exposure == 1.25)
                    throw CocoaError(.fileWriteNoPermission)
                })
            Issue.record("Refused staging unexpectedly replaced the source")
        } catch let error as PrimaryDevelopPhysicalError {
            #expect(!error.mayHaveWritten && error.sourceRevision == nil)
        }
        #expect(try Data(contentsOf: image) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [image.lastPathComponent])
    }

    @Test("Embedded source drift after serialization is preserved without a write receipt")
    func embeddedSourceDriftBeforePublication() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        let external = Data("External replacement during serialization".utf8)
        do {
            _ = try await SwiftExifWriteEngine().writePrimaryDevelop(captured,
                validatePreparedIntent: {}, validateCommitAuthority: {
                    try external.write(to: image)
                })
            Issue.record("Changed source unexpectedly overwritten")
        } catch let error as PrimaryDevelopPhysicalError {
            #expect(!error.mayHaveWritten && error.sourceRevision == nil && !error.wasCancelled)
        }
        #expect(try Data(contentsOf: image) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [image.lastPathComponent])
    }

    @Test("Embedded publication cancellation is refused before writing")
    func embeddedCancellationDuringAdmission() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: image)
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        let operation = Task {
            try await SwiftExifWriteEngine().writePrimaryDevelop(captured, validatePreparedIntent: {
                withUnsafeCurrentTask { $0?.cancel() }
                await Task.yield()
            })
        }
        do {
            _ = try await operation.value
            Issue.record("Cancelled embedded admission unexpectedly published")
        } catch let error as PrimaryDevelopPhysicalError {
            #expect(!error.mayHaveWritten && error.sourceRevision == nil && error.wasCancelled)
        }
        #expect(try Data(contentsOf: image) == original)
    }

    @Test("Embedded synchronous authority preserves native completion and exact physical receipt")
    func embeddedCommitAuthorityCompletion() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640,
            .creationDate: Date(timeIntervalSince1970: 1234567890)], ofItemAtPath: image.path)
        let originalValues = try image.resourceValues(forKeys: [.creationDateKey, .isHiddenKey])
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        let authority = PrimaryTestCommitAuthority(refuseAt: Int.max)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured,
            validateCommitAuthority: { try authority.validate() })
        let installedValues = try image.resourceValues(forKeys: [.creationDateKey, .isHiddenKey])
        #expect(installedValues.creationDate == originalValues.creationDate)
        #expect(installedValues.isHidden == originalValues.isHidden)
        let permissions = try FileManager.default.attributesOfItem(atPath: image.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .allSatisfy { !$0.hasPrefix(".aagedal_primary_") })
        #expect(result.completed && result.wroteEmbedded && !result.embeddedMayHaveBeenWritten)
        #expect(authority.count == 6) // Embedded staging/hash/receipt, then XMP/JSON publication/receipt.
        let actual = try await SourceImageRevision.capture(at: image)
        #expect(result.sourceRevision?.sha256 == actual.sha256)
        #expect(result.completion?.wroteXMPSidecar == true)
    }

    @Test("Original source and companion changes refuse physical writes", arguments: [0, 1, 2])
    func independentChanges(kind: Int) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(image, mode: .writeToFileAndXMPSidecar)
        if kind == 0 { try Data("External image".utf8).write(to: image) }
        if kind == 1 { try XMPSidecarService().saveSidecar(metadata: .init(title: "External XMP"), for: image) }
        if kind == 2 { try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: .init(title: "External JSON")), for: image, in: folder) }
        let before = try Data(contentsOf: image)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(captured)
        #expect(!result.completed && !result.wroteEmbedded && !result.embeddedMayHaveBeenWritten)
        #expect(result.completion?.wroteXMPSidecar != true)
        #expect(try Data(contentsOf: image) == before)
    }

    @Test("Prephysical failure retries only the original request and its original evidence")
    func safeRetry() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let captured = try await request(image)
        let gate = PrimaryTestFailureGate()
        var hooks = PrimaryDevelopWriteHooks(); hooks.beforeAdmission = { try await gate.failOnce() }
        let worker = PrimaryDevelopWriteService(engine: SwiftExifWriteEngine(), hooks: hooks)
        let first = await worker.execute(captured)
        #expect(!first.completed && !first.requiresRecovery)
        let second = await worker.execute(captured)
        #expect(second.completed && second.requestID == captured.id)
    }

    @Test("Partial XMP commit retains exact original and partial receipt for export")
    func partialReceiptExport() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try MetadataSidecarService().saveSidecar(.init(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: .init(description: "Pending caption"), imageMetadataSnapshot: nil), for: image, in: folder)
        let captured = try await request(image)
        var hooks = PrimaryDevelopWriteHooks(); hooks.beforeJSON = { throw CocoaError(.fileWriteNoPermission) }
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine(), hooks: hooks).execute(captured)
        #expect(!result.completed && result.requiresRecovery)
        #expect(result.completion?.wroteXMPSidecar == true)
        let payload = try JSONEncoder().encode(PrimaryDevelopRecoveryPayload(captured, result: result))
        let graph = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect((graph["expectedRecord"] as? [String: Any])?["originalSnapshotKnown"] as? Bool == false)
        #expect(((graph["edited"] as? [String: Any])?["cameraRaw"] as? [String: Any]) != nil)
        #expect(graph["writtenXMPData"] != nil)
        let entry = VariableConflictEntry(id: captured.id, imageURL: image, folderURL: folder, admissionPayload: payload)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Retained Primary Develop", generation: 1, entries: [entry])
        let receipt = try await VariableConflictRecovery.export(snapshot, to: folder.appendingPathComponent("primary.json"), currentEntries: [entry], generation: 1, protectedPhotoURLs: [image])
        #expect(try await VariableConflictRecovery.verifyDiscard(snapshot, receipt: receipt, currentEntries: [entry], generation: 1, protectedPhotoURLs: [image]) == [captured.id])
    }

    @Test("Embedded plus XMP reset removes actual CRS while retaining editorial metadata")
    func dualReset() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let initial = try await request(image, mode: .writeToFileAndXMPSidecar)
        #expect(await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(initial).completed)
        let reset = try await request(image, mode: .writeToFileAndXMPSidecar, reset: true)
        let result = await PrimaryDevelopWriteService(engine: SwiftExifWriteEngine()).execute(reset)
        #expect(result.completed && result.wroteEmbedded)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
        #expect(physical.cameraRaw?.exposure2012 == nil)
        #expect(physical.cameraRaw?.localAdjustments?.isEmpty != false)
        #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == nil)
        #expect(physical.title == "Primary result")
    }

    @Test("Rapid dual edits and delayed Undo use exact predecessor completion evidence", arguments: [0, 1, 2])
    func rapidUndo(scenario: Int) async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var initial = IPTCMetadata(); initial.cameraRaw = settings(0)
        try XMPSidecarService().saveSidecar(metadata: initial, for: image)
        let lifecycle = DevelopPrimaryLifecycleCoordinator()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(), primaryDevelopLifecycle: lifecycle)
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw?.exposure2012 = 1
        model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        model.editingMetadata.cameraRaw?.exposure2012 = scenario == 1 ? 2 : 0
        model.markChanged()
        if scenario == 2 { await model.waitForPrimaryDevelopWrites() }
        model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        if scenario == 1 {
            model.editingMetadata.cameraRaw?.exposure2012 = 1
            model.markChanged()
            #expect(model.hasUncapturedPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar))
            model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        }
        if scenario != 2 { #expect(model.retainedPrimaryDevelopWrites.count == (scenario == 1 ? 3 : 2)) }
        await model.waitForPrimaryDevelopWrites()
        #expect(!model.hasRetainedPrimaryDevelopWrites)
        #expect(!lifecycle.hasPendingWork)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
        #expect(physical.cameraRaw?.exposure2012 == (scenario == 1 ? 1 : 0))
        #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == (scenario == 1 ? 1 : 0))
    }

    @Test("Dismissal and generic save cannot lose a retained Primary edit; verified scoped export is required")
    func retainedFailureLifecycleAndDiscard() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let lifecycle = DevelopPrimaryLifecycleCoordinator()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: lifecycle, primaryDevelopExecutor: { request in
                .init(requestID: request.id, failure: "Injected Primary failure")
            })
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(2); model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        await model.waitForPrimaryDevelopWrites()
        model.saveError = nil
        #expect(model.hasRetainedPrimaryDevelopWrites && lifecycle.hasPendingWork)
        #expect(!model.hasUncapturedPrimaryDevelopEdits(mode: .writeToXMPSidecar))
        var refused = false
        do { try await lifecycle.flush() } catch { refused = true }
        #expect(refused)
        model.commitEditsReportingResult(mode: .writeToXMPSidecar) { result in
            if case .succeeded = result { Issue.record("Generic save bypassed retained Primary work") }
        }
        #expect(!FileManager.default.fileExists(atPath: XMPSidecarService().sidecarURL(for: image).path))
        let snapshot = try await model.beginPrimaryDevelopRecovery(for: image)
        let receipt = try await model.exportPrimaryDevelopRecovery(snapshot, to: folder.appendingPathComponent("retained.json"))
        refused = false
        do { try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt) } catch { refused = true }
        #expect(refused && model.hasRetainedPrimaryDevelopWrites)
        model.registerPrimaryDevelopRecoveryEditorBarrier(owner: UUID(), handler: {})
        try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt)
        #expect(!model.hasRetainedPrimaryDevelopWrites && !lifecycle.hasPendingWork)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == nil)
    }
    @Test("Partial outcome never auto-retries; scoped discard preserves another photo's new editor")
    func partialRetentionAcrossSelection() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("other.png")
        try FileManager.default.copyItem(at: image, to: other)
        let calls = PrimaryTestCallCounter()
        let lifecycle = DevelopPrimaryLifecycleCoordinator()
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: lifecycle, primaryDevelopExecutor: { request in
                await calls.record()
                return .init(requestID: request.id, completion: .init(installedSidecar: nil, wroteXMPSidecar: true,
                    wasCancelled: false, failure: .init(stage: .metadataSidecar, message: "Injected partial JSON failure")),
                    failure: "Injected partial JSON failure")
            })
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(1); model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        await model.waitForPrimaryDevelopWrites()
        let id = try #require(model.retainedPrimaryDevelopWrites.first?.id)
        try await load(model, image: other, folder: folder)
        model.editingMetadata.cameraRaw = settings(5); model.markChanged()
        do { try await model.retryPrimaryDevelopWrites() } catch { }
        #expect(await calls.count == 1)
        #expect(model.retainedPrimaryDevelopWrites.first?.id == id)
        let snapshot = try await model.beginPrimaryDevelopRecovery(for: image)
        let receipt = try await model.exportPrimaryDevelopRecovery(snapshot, to: folder.appendingPathComponent("partial.json"))
        try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt)
        #expect(model.selectedURLs == [other])
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 5)
        #expect(model.hasUnpersistedEditorChanges)
        #expect(!model.hasRetainedPrimaryDevelopWrites)
    }

    @Test("Recovery reload never overwrites a newer same-photo editor while its read is held")
    func recoveryReadRace() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let gate = PrimaryTestReadGate()
        let reader = MetadataEditorReadService(access: .init(read: { image, folder, embedded, reconciles in
            gate.pauseIfArmed()
            return MetadataEditorReadAccess.systemRead(imageURL: image, folderURL: folder,
                embedded: embedded, reconciles: reconciles)
        }))
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            editorReadService: reader, primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator(),
            primaryDevelopExecutor: { .init(requestID: $0.id, failure: "Injected failure") })
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(2); model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        await model.waitForPrimaryDevelopWrites()
        model.registerPrimaryDevelopRecoveryEditorBarrier(owner: UUID(), handler: {})
        let snapshot = try await model.beginPrimaryDevelopRecovery(for: image)
        let receipt = try await model.exportPrimaryDevelopRecovery(snapshot, to: folder.appendingPathComponent("race.json"))
        gate.arm()
        let discard = Task { try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt) }
        let didEnter = await Task.detached { gate.waitForEntry() }.value
        #expect(didEnter)
        model.editingMetadata.cameraRaw?.exposure2012 = 7
        model.markChanged()
        gate.release.signal()
        var refused = false
        do { try await discard.value } catch { refused = true }
        #expect(refused && model.hasRetainedPrimaryDevelopWrites)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 7)
        try await model.discardPrimaryDevelopRecovery(snapshot, receipt: receipt)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 7)
    }

    @Test("Recovery protects watermark metadata retained only by a completed ancestor")
    func protectsAncestorDependencyDestination() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let dependencyFolder = folder.appendingPathComponent("watermark", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyFolder, withIntermediateDirectories: true)
        let metadataURL = dependencyFolder.appendingPathComponent("meta.json")
        let originalBytes = Data("{\"name\":\"Ancestor watermark\"}".utf8)
        try originalBytes.write(to: metadataURL)
        let dependency = PrimaryDevelopWatermarkDependency(id: UUID(), asset: nil, imageData: nil,
            imageURL: dependencyFolder.appendingPathComponent("image.png"), metadataURL: metadataURL,
            unavailableAtAdmission: true)
        let first = try await request(image, dependencies: [dependency])
        let child = try await request(image, predecessor: first)
        #expect(child.watermarkDependencies.isEmpty)
        let ancestry = PrimaryDevelopWriteRequest.ancestry(of: [child, first])
        #expect(ancestry.map(\.id) == [child.id, first.id])
        let payloads = ancestry.map { PrimaryDevelopRecoveryPayload($0, result: nil) }
        let graph = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payloads))
        let payload = try JSONSerialization.data(withJSONObject: ["requestAndPredecessors": graph])
        let entry = VariableConflictEntry(id: child.id, imageURL: image, folderURL: folder, admissionPayload: payload)
        let snapshot = try await VariableConflictRecovery.makeSnapshot(photoURL: image, reason: "Primary recovery", generation: 1, entries: [entry])
        var refused = false
        do {
            _ = try await VariableConflictRecovery.export(snapshot, to: metadataURL,
                currentEntries: [entry], generation: 1,
                protectedPhotoURLs: PrimaryDevelopWriteRequest.protectedURLs(for: [child]))
        } catch { refused = true }
        #expect(refused)
        #expect(try Data(contentsOf: metadataURL) == originalBytes)
    }

    @Test("Explicit same-value XMP then dual save still writes the embedded destination")
    func sameValueDifferentDestination() async throws {
        let (folder, image) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            primaryDevelopLifecycle: DevelopPrimaryLifecycleCoordinator())
        try await load(model, image: image, folder: folder)
        model.editingMetadata.cameraRaw = settings(1)
        model.markChanged()
        model.commitPrimaryDevelopEdits(mode: .writeToXMPSidecar, onComplete: { _ in })
        #expect(!model.hasUncapturedPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar))
        model.commitPrimaryDevelopEdits(mode: .writeToFileAndXMPSidecar, onComplete: { _ in })
        #expect(model.retainedPrimaryDevelopWrites.count == 2)
        #expect(model.retainedPrimaryDevelopWrites.last?.replaceDevelop == true)
        await model.waitForPrimaryDevelopWrites()
        #expect(!model.hasRetainedPrimaryDevelopWrites)
        let physical = try #require(try await SwiftExifReadService().readBatchFullMetadata(urls: [image])[image])
        #expect(physical.cameraRaw?.exposure2012 == 1)
        #expect(physical.cameraRaw?.localAdjustments?.count == 1)
        #expect(XMPSidecarService().loadSidecar(for: image)?.cameraRaw?.exposure2012 == 1)
    }

}

@Suite("Immutable Primary Develop request capture")
@MainActor
struct PrimaryDevelopWriteRequestBuilderTests {
    private let folder = URL(fileURLWithPath: "/private/tmp/DevelopCapture", isDirectory: true)
    private let loadID = UUID()
    private let timestamp = Date(timeIntervalSince1970: 1234)

    private func metadata(exposure: Double, orientation: Int = 1) -> IPTCMetadata {
        var value = IPTCMetadata(title: "Saved caption")
        var settings = CameraRawSettings()
        settings.exposure2012 = exposure
        value.cameraRaw = settings
        value.exifOrientation = orientation
        return value
    }

    private func build(edited: IPTCMetadata, baseline: IPTCMetadata? = nil,
        embedded: IPTCMetadata? = nil, original: IPTCMetadata? = nil,
        mode: MetadataWriteMode = .writeToXMPSidecar, predecessor: PrimaryDevelopWriteRequest? = nil,
        failure: String? = nil, imageName: String = "photo.jpg",
        dependencies: [PrimaryDevelopWatermarkDependency] = [],
        source: SourceImageRevision? = nil, xmp: XMPSidecarWriteSnapshot? = .init(data: nil),
        captureLoadID: UUID? = nil, captureFolder: URL? = nil) -> PrimaryDevelopWriteRequest {
        let captureFolder = captureFolder ?? folder
        return PrimaryDevelopWriteRequestBuilder.build(.init(imageURL: captureFolder.appendingPathComponent(imageName),
            folderURL: captureFolder, loadID: captureLoadID ?? loadID, mode: mode, edited: edited, previous: baseline,
            original: original, xmpBaseline: baseline, embeddedBaseline: embedded,
            expectedRecord: nil, expectedXMP: xmp, sourceRevision: source,
            captureFailure: failure, history: [], timestamp: timestamp,
            predecessor: predecessor, watermarkDependencies: dependencies))
    }

    @Test("Caption saves ignore render-only state and preserve foreign CRS")
    func captionAndRenderOnlyFields() {
        let baseline = metadata(exposure: 1.25)
        var edited = baseline
        edited.title = "New caption"
        edited.cameraRaw?.asShotNeutralTemperature = 5600
        edited.cameraRaw?.asShotNeutralTint = 12
        edited.cameraRaw?.sourceHasHDRHeadroom = true
        let request = build(edited: edited, baseline: baseline, embedded: baseline,
            mode: .writeToFileAndXMPSidecar)
        #expect(!request.replaceDevelop && !request.replaceOrientation)
        #expect(!request.structured.replaceCameraRawBlock)
        #expect(request.fields[.crsExposure2012] == nil)
        #expect(request.fields[.headline] == "New caption")
        #expect(request.structured.editorial != nil)
    }

    @Test("Reset clears all scalar CRS and structured block without borrowing original state")
    func reset() {
        let baseline = metadata(exposure: 1.25)
        let request = build(edited: IPTCMetadata(), baseline: baseline)
        #expect(request.replaceDevelop && request.structured.replaceCameraRawBlock)
        #expect(request.fields[.crsExposure2012] == "")
        #expect(request.fields[.crsCropTop] == "")
        #expect(request.fields[.crsWhiteBalance] == "")
        #expect(request.fields[.crsHasSettings] == "False")
        #expect(request.structured.masks == nil && request.structured.watermarkLayers == nil)
    }

    @Test("XMP-only predecessor cannot acknowledge embedded develop or orientation")
    func independentEmbeddedBaseline() {
        let embedded = metadata(exposure: 0, orientation: 1)
        let edited = metadata(exposure: 1.25, orientation: 6)
        let predecessor = build(edited: edited, baseline: embedded)
        let xmp = build(edited: edited, baseline: embedded, embedded: embedded, predecessor: predecessor)
        #expect(!xmp.replaceDevelop && !xmp.replaceOrientation)
        let both = build(edited: edited, baseline: embedded, embedded: embedded,
            mode: .writeToFileAndXMPSidecar, predecessor: predecessor)
        #expect(both.replaceDevelop && both.replaceOrientation)
        #expect(both.embeddedBaseline == embedded)
    }

    @Test("Embedded ancestry supplies the correct destination baseline through XMP saves")
    func embeddedAncestryAndHistory() {
        let initial = metadata(exposure: 0)
        let edited = metadata(exposure: 1.25)
        let embedded = build(edited: edited, baseline: initial, embedded: initial,
            mode: .writeToFileAndXMPSidecar)
        var caption = edited; caption.title = "Next caption"
        let xmp = build(edited: caption, predecessor: embedded)
        let result = build(edited: caption, embedded: initial,
            mode: .writeToFileAndXMPSidecar, predecessor: xmp)
        #expect(!result.replaceDevelop && !result.replaceOrientation)
        #expect(result.embeddedBaseline == edited)
        #expect(result.previous == caption)
        #expect(result.predecessor === xmp)
        #expect(result.changes.isEmpty)
        #expect(result.sidecar.history == xmp.sidecar.history)
        #expect(result.sidecar.lastModified == timestamp)
        #expect(result.sidecar.imageMetadataSnapshot == caption)
        #expect(!result.sidecar.pendingChanges)
    }

    @Test("Proprietary RAW target never treats file mode as embedded admission")
    func rawDestination() {
        let edited = metadata(exposure: 1.25, orientation: 6)
        let request = build(edited: edited, baseline: edited,
            embedded: metadata(exposure: 0), mode: .writeToFileAndXMPSidecar, imageName: "photo.nef")
        #expect(!request.replaceDevelop && !request.replaceOrientation)
    }

    @Test("Admission failure remains captured and original dependency bytes survive reset")
    func evidenceAndDependencyCapture() {
        let id = UUID()
        var original = metadata(exposure: 1)
        original.cameraRaw?.watermarkLayers = [WatermarkLayer(libraryAssetID: id)]
        #expect(PrimaryDevelopWriteRequestBuilder.watermarkDependencyIDs(
            edited: IPTCMetadata(), previous: original, original: original) == [id])
        let image = folder.appendingPathComponent("watermark.png")
        let dependency = PrimaryDevelopWatermarkDependency(id: id, asset: nil,
            imageData: Data([1, 2, 3]), imageURL: image,
            metadataURL: folder.appendingPathComponent("meta.json"), unavailableAtAdmission: true)
        let result = build(edited: IPTCMetadata(), baseline: original, original: original,
            failure: "Original XMP evidence failed", dependencies: [dependency])
        #expect(result.captureFailure == "Original XMP evidence failed")
        #expect(result.watermarkDependencies.first?.imageData == Data([1, 2, 3]))
        #expect(result.original == original)
        #expect(result.expectedXMP == .init(data: nil))
        let missingSource = build(edited: original)
        #expect(missingSource.captureFailure?.contains("source revision is unavailable") == true)
        #expect(missingSource.edited == original)
        // Editor overwrite semantics deliberately clear absent GPS rather than export's additive GPS.
        #expect(result.fields[.gpsLatitude] == "" && result.fields[.gpsLongitude] == "")
    }
    @Test("Foreign photo, folder, load and hidden ancestor cannot supply baselines", arguments: [0, 1, 2, 3])
    func foreignPredecessor(kind: Int) {
        let initial = metadata(exposure: 0)
        let edited = metadata(exposure: 1.25)
        let foreign = build(edited: edited, baseline: initial,
            imageName: kind == 0 ? "other.jpg" : "photo.jpg",
            captureLoadID: kind == 2 ? UUID() : nil,
            captureFolder: kind == 1 ? folder.appendingPathComponent("other") : nil)
        // Build a deliberately inconsistent request directly to exercise deep ancestry validation.
        let predecessor: PrimaryDevelopWriteRequest
        if kind == 3 {
            let matching = build(edited: edited, baseline: initial)
            let other = build(edited: edited, baseline: initial, captureLoadID: UUID())
            predecessor = PrimaryDevelopWriteRequest(imageURL: matching.imageURL, folderURL: folder,
                loadID: loadID, mode: matching.mode, edited: edited, previous: initial, original: nil,
                expectedRecord: nil, expectedXMP: matching.expectedXMP, sourceRevision: nil,
                captureFailure: nil, sidecar: matching.sidecar, changes: matching.changes,
                fields: matching.fields, structured: matching.structured, replaceDevelop: true,
                replaceOrientation: false, predecessor: other)
        } else { predecessor = foreign }
        let result = build(edited: edited, baseline: initial, predecessor: predecessor)
        #expect(result.captureFailure?.contains("another photo or editor load") == true)
        #expect(result.predecessor == nil)
        #expect(result.previous == initial)
        #expect(result.replaceDevelop)
        #expect(result.sidecar.history == result.changes)
    }

    @Test("Missing XMP evidence cannot become usable capture authority")
    func missingXMPEvidence() {
        let source = SourceImageRevision(canonicalURL: folder.appendingPathComponent("photo.jpg"),
            fileResourceIdentifier: nil, filenameAtCreation: "photo.jpg", byteCount: 1,
            contentModificationDate: timestamp, pixelWidth: nil, pixelHeight: nil,
            exifOrientation: nil, sha256: String(repeating: "a", count: 64), hashCompletedAt: timestamp)
        let result = build(edited: metadata(exposure: 1), source: source, xmp: nil)
        #expect(result.captureFailure?.contains("XMP revision is unavailable") == true)
        #expect(result.sourceRevision == source)
        #expect(result.expectedXMP == nil)
        let absentSidecar = build(edited: metadata(exposure: 1), source: source)
        #expect(absentSidecar.captureFailure == nil)
        #expect(absentSidecar.expectedXMP == .init(data: nil))
    }

}
