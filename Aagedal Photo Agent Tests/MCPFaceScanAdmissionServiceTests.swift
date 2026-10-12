import Foundation
import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only rooted complete-folder face scan preparation")
struct MCPFaceScanAdmissionServiceTests {
    nonisolated private final class ConfigurationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
        func write(_ value: Data?) { lock.lock(); defer { lock.unlock() }; data = value }
    }

    private struct Fixture {
        let root: URL
        let authority: MCPAuthorizationStore
        let service: MCPFaceScanAdmissionService
        let photos: [URL]
        var arguments: [String: MCPJSONValue] { ["path": .string(root.path)] }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-scan-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = ConfigurationBox()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let photos = [root.appendingPathComponent("b-å.JPG"), root.appendingPathComponent("a.jpg")]
        for photo in photos { try Data("disposable image bytes".utf8).write(to: photo) }
        return Fixture(root: root, authority: authority, service: .init(authorizationStore: authority), photos: photos)
    }

    @Test("Preparation is deterministic, complete, and creates no scan or operation data")
    func completeReadOnlySnapshot() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("video".utf8).write(to: f.root.appendingPathComponent("clip.mp4"))
        try Data("hidden".utf8).write(to: f.root.appendingPathComponent(".hidden.jpg"))
        let nested = f.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("nested.jpg"))
        let before = try f.photos.map { try Data(contentsOf: $0) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        // Foundation standardizes /private/tmp to /tmp when authorizing the folder.
        // Compare the complete ordered paths using the same URL normalization.
        let expectedPhotos = f.photos.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.standardizedFileURL)
        #expect(prepared.imageURLs.map(\.standardizedFileURL) == expectedPhotos)
        #expect(prepared.folderURL == f.root.standardizedFileURL)
        #expect(prepared.snapshotRevision.hasPrefix("sha256:"))
        #expect(prepared.snapshotRevision.count == 71)
        #expect(try f.service.revalidate(prepared).snapshotRevision == prepared.snapshotRevision)
        #expect(prepared.protocolValue.objectValue?["photoCount"] == .integer(2))
        #expect(prepared.protocolValue.objectValue?["executionAvailable"] == .bool(false))
        #expect(prepared.protocolValue.objectValue?["mutationAuthorized"] == .bool(false))
        #expect(try f.photos.map { try Data(contentsOf: $0) } == before)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".face_data").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
        let serialized = try JSONEncoder().encode(prepared.protocolValue)
        #expect(prepared.protocolValue.objectValue?["canonicalPath"] == .string(f.root.standardizedFileURL.path))
        #expect(prepared.protocolValue.objectValue?["schemaVersion"] == .integer(1))
        #expect(!String(decoding: serialized, as: UTF8.self).contains(f.photos[0].lastPathComponent))
    }

    @Test("Jersey preparation preserves the scanner's full-reset option semantics")
    func normalizedOptions() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        arguments["includeJerseyNumbers"] = .bool(true); arguments["forceFullScan"] = .bool(false)
        let prepared = try f.service.prepare(arguments: arguments)
        #expect(prepared.forceFullScan)
        #expect(prepared.includeJerseyNumbers)
        #expect(prepared.snapshotRevision != (try f.service.prepare(arguments: f.arguments)).snapshotRevision)
    }

    @Test("Strict arguments refuse aliases, unknown fields, and nonboolean scan flags", arguments: [
        [String: MCPJSONValue](), ["path": .string("relative")], ["path": .string("/tmp"), "photos": .array([])],
        ["path": .string("/tmp"), "forceFullScan": .integer(1)], ["path": .string("/tmp"), "includeJerseyNumbers": .null]
    ])
    func malformedArguments(arguments: [String: MCPJSONValue]) {
        #expect(throws: MCPFaceScanAdmissionService.Failure.invalidArguments) {
            try MCPFaceScanAdmissionService.Request(arguments: arguments)
        }
    }

    @Test("Unavailable complete inventories refuse without scan state", arguments: ["symbolic", "hardlink", "placeholder", "empty", "file"])
    func invalidInventory(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        switch kind {
        case "symbolic": try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link.jpg"), withDestinationURL: f.photos[0])
        case "hardlink": try FileManager.default.linkItem(at: f.photos[0], to: f.root.appendingPathComponent("copy.jpg"))
        case "placeholder": try Data().write(to: f.root.appendingPathComponent(".pending.JPG.icloud"))
        case "empty": for photo in f.photos { try FileManager.default.removeItem(at: photo) }
        default: arguments["path"] = .string(f.photos[0].path)
        }
        #expect(throws: (any Error).self) { try f.service.prepare(arguments: arguments) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".face_data").path))
    }

    @Test("Captured sessions refuse inventory and authorization drift", arguments: ["add", "remove", "replace", "modify", "disabled", "regrant"])
    func staleSession(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        switch kind {
        case "add": try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        case "remove": try FileManager.default.removeItem(at: f.photos[0])
        case "replace": try Data("new inode".utf8).write(to: f.photos[0], options: .atomic)
        case "modify": try Data("different byte count".utf8).write(to: f.photos[0])
        case "disabled": try f.authority.setEnabled(false)
        default: try f.authority.setEnabled(false); try f.authority.setEnabled(true)
        }
        #expect(throws: (any Error).self) { try f.service.revalidate(prepared) }
    }

    @Test("Folder preparation cannot overlap a participating photo writer and releases its own reservation")
    func reservations() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPProcessReservation.acquirePhoto(f.photos[0])
        #expect(throws: MCPProcessReservationError.busy) { try f.service.prepare(arguments: f.arguments) }
        lease.release()
        _ = try f.service.prepare(arguments: f.arguments)
        let next = try MCPProcessReservation.acquirePhoto(f.photos[0]); next.release()
    }

    @Test("Enabled rooted authority is required even for read-only preparation", arguments: ["disabled", "outside", "traversal"])
    func missingAuthority(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var arguments = f.arguments
        switch kind {
        case "disabled": try f.authority.setEnabled(false)
        case "outside": arguments["path"] = .string(f.root.deletingLastPathComponent().path)
        default: arguments["path"] = .string(f.root.path + "/../" + f.root.lastPathComponent)
        }
        #expect(throws: (any Error).self) { try f.service.prepare(arguments: arguments) }
    }

    @Test("Root replacement or folder symlink cannot reuse authority")
    func rootedRefusal() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = f.root.appendingPathExtension("original")
        defer { try? FileManager.default.removeItem(at: original) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        try FileManager.default.moveItem(at: f.root, to: original)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: original)
        #expect(throws: (any Error).self) { try f.service.revalidate(prepared) }
    }

    @Test("Retained rooted inventory excludes participating writers across suspension")
    func retainedAcrossSuspension() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        let retained = try f.service.retain(prepared)
        defer { retained.release() }
        await Task.yield()
        try retained.validate()
        #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquirePhoto(f.photos[0]) }
        #expect(throws: MCPProcessReservationError.busy) { try MCPProcessReservation.acquireFolder(f.root) }
        #expect(try retained.withValidatedFolder { snapshot, descriptor in
            snapshot.snapshotRevision == prepared.snapshotRevision && descriptor >= 0
        })
        retained.release(); retained.release()
        #expect(throws: MCPFaceScanAdmissionService.Failure.releasedReservation) { try retained.validate() }
        #expect(throws: MCPFaceScanAdmissionService.Failure.releasedReservation) { try retained.checkAuthority() }
        let lease = try MCPProcessReservation.acquirePhoto(f.photos[0]); lease.release()
    }

    @Test("Retained complete inventory refuses drift before a boundary callback", arguments: ["add", "modify", "disabled", "replace-root"])
    func retainedDrift(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        let moved = f.root.appendingPathExtension("original")
        defer { try? FileManager.default.removeItem(at: moved) }
        switch kind {
        case "add": try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        case "modify": try Data("changed image".utf8).write(to: f.photos[0])
        case "disabled": try f.authority.setEnabled(false)
        default:
            try FileManager.default.moveItem(at: f.root, to: moved)
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
        }
        var invoked = false
        #expect(throws: (any Error).self) {
            try retained.withValidatedFolder { _, _ in invoked = true }
        }
        #expect(!invoked)
    }

    @Test("Boundary completion refuses external input changes instead of reporting success")
    func retainedPostBoundaryDrift() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        #expect(throws: MCPFaceScanAdmissionService.Failure.staleSnapshot) {
            try retained.withValidatedFolder { _, _ in
                try Data("changed input bytes".utf8).write(to: f.photos[0])
            }
        }
    }

    @Test("Failed retained admission and deinitialization release reservations")
    func retainedCleanup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try f.service.prepare(arguments: f.arguments)
        try Data("new".utf8).write(to: f.root.appendingPathComponent("new.jpg"))
        #expect(throws: MCPFaceScanAdmissionService.Failure.staleSnapshot) { try f.service.retain(prepared) }
        let next = try MCPProcessReservation.acquireFolder(f.root); next.release()
        var retained: MCPFaceScanAdmissionService.RetainedFolder? = try f.service.retain(f.service.prepare(arguments: f.arguments))
        #expect(retained != nil)
        retained = nil
        let last = try MCPProcessReservation.acquireFolder(f.root); last.release()
    }

    nonisolated private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        func read() -> Date { lock.withLock { date } }
        func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
    }

    @Test("Immutable session intents bind normalized options and expire without extending on inspection")
    func immutableIntent() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = ClockBox()
        let store = MCPFaceScanIntentStore(admission: f.service, clock: { clock.read() })
        var arguments = f.arguments; arguments["includeJerseyNumbers"] = .bool(true)
        let intent = try store.prepare(arguments: arguments)
        #expect(intent.prepared.forceFullScan)
        #expect(intent.prepared.includeJerseyNumbers)
        #expect(intent.expiresAt.timeIntervalSince(intent.createdAt) == 300)
        clock.advance(299)
        #expect(try store.inspect(id: intent.id).expiresAt == intent.expiresAt)
        let retained = try store.retain(id: intent.id)
        defer { retained.release() }
        clock.advance(1)
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try store.retain(id: intent.id) }
        // Expiry gates admission; original authority remains checked for retained work.
        try retained.validate()
        retained.release()
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try store.inspect(id: intent.id) }
        #expect(throws: MCPFaceScanIntentStore.Failure.unknownIntent) {
            try MCPFaceScanIntentStore(admission: f.service).inspect(id: intent.id)
        }
    }

    @Test("Intent stores bound both entries and total retained photos and prune expired capacity")
    func intentBounds() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = ClockBox()
        let store = MCPFaceScanIntentStore(admission: f.service, maximumIntents: 1, clock: { clock.read() })
        _ = try store.prepare(arguments: f.arguments)
        #expect(throws: MCPFaceScanIntentStore.Failure.capacity) { try store.prepare(arguments: f.arguments) }
        clock.advance(300)
        _ = try store.prepare(arguments: f.arguments)
        #expect(throws: MCPFaceScanIntentStore.Failure.capacity) {
            try MCPFaceScanIntentStore(admission: f.service, maximumRetainedPhotos: 1).prepare(arguments: f.arguments)
        }
        #expect(throws: MCPFaceScanIntentStore.Failure.capacity) {
            try MCPFaceScanIntentStore(admission: f.service, maximumIntents: 0).prepare(arguments: f.arguments)
        }
    }

    @Test("Intents refuse a backwards clock and changed authority before retention")
    func intentRefusals() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = ClockBox()
        let store = MCPFaceScanIntentStore(admission: f.service, clock: { clock.read() })
        let intent = try store.prepare(arguments: f.arguments)
        clock.advance(-1)
        #expect(throws: MCPFaceScanIntentStore.Failure.expiredIntent) { try store.inspect(id: intent.id) }
        clock.advance(1)
        try f.authority.setEnabled(false)
        #expect(throws: (any Error).self) { try store.retain(id: intent.id) }
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }


    @Test("Cancellation refuses retained boundaries and cleanup remains available")
    func retainedCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try retained.validate(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
        retained.release()
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Nonfinite intent clocks refuse without retaining a snapshot")
    func invalidIntentClock() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = MCPFaceScanIntentStore(admission: f.service, clock: { Date(timeIntervalSince1970: .nan) })
        #expect(throws: MCPFaceScanIntentStore.Failure.invalidClock) { try store.prepare(arguments: f.arguments) }
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Post-document authority refusal preserves commit evidence and prevents thumbnail cleanup")
    func committedDocumentAuthorityRefusal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        let document = FolderFaceData(folderURL: retained.prepared.folderURL, faces: [], groups: [],
            lastScanDate: Date(), scanComplete: true)
        let service = FaceDataFolderLoadService(saveFaceData: { data in
            try FaceDataStorageService().saveFaceData(data)
            try f.authority.setEnabled(false)
        }, deleteThumbnail: { _, _ in Issue.record("Refused authority reached thumbnail cleanup") })
        let result = await service.persist(document, deletingThumbnailIDs: [UUID()],
            effectAuthority: { try retained.validateForEffect(folderURL: $0) })
        guard case .committed(let evidence) = result else { Issue.record("Committed document receipt lost"); return }
        #expect(evidence.documentCommitted)
        #expect(evidence.authorityFailure != nil)
        #expect(!evidence.cancellationRequestedAfterCommit)
        #expect(evidence.deletedThumbnailIDs.isEmpty)
        #expect(FaceDataStorageService().loadFaceData(for: document.folderURL)?.scanComplete == true)
        try f.authority.setEnabled(true)
        #expect(throws: MCPFaceScanAdmissionService.Failure.authorizationChanged) {
            try retained.validateForEffect(folderURL: document.folderURL)
        }
    }

    @Test("Committed thumbnails and reset survive post-effect authority failure", arguments: [false, true])
    func committedEffectsAuthorityRefusal(reset: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        let folder = retained.prepared.folderURL
        let faceID = UUID()
        let bytes = Data("exact committed thumbnail".utf8)
        let service = FaceDataFolderLoadService(deleteFaceData: { url in
            try FaceDataStorageService().deleteFaceData(for: url)
            try f.authority.setEnabled(false)
        }, saveThumbnail: { data, id, url in
            try FaceDataStorageService().saveThumbnail(data, for: id, folderURL: url)
            try f.authority.setEnabled(false)
        })
        if reset {
            try FaceDataStorageService().saveThumbnail(bytes, for: faceID, folderURL: folder)
            let result = await service.deleteAll(for: folder,
                effectAuthority: { try retained.validateForEffect(folderURL: $0) })
            guard case .committedButUnverified(let committedFolder, _, let cancelled) = result else {
                Issue.record("Committed reset receipt lost"); return
            }
            #expect(committedFolder == folder)
            #expect(!cancelled)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".face_data").path))
        } else {
            let result = await service.persistThumbnail(bytes, faceID: faceID, folderURL: folder,
                effectAuthority: { try retained.validateForEffect(folderURL: $0) })
            guard case .committedButUnverified(let committedID, _, let cancelled) = result else {
                Issue.record("Committed thumbnail receipt lost"); return
            }
            #expect(committedID == faceID)
            #expect(!cancelled)
            #expect(FaceDataStorageService().loadThumbnail(for: faceID, folderURL: folder) == bytes)
        }
    }

    @Test("Pre-effect rooted refusal performs no document, thumbnail, or reset callback")
    func preEffectAuthorityRefusal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        defer { retained.release() }
        try f.authority.setEnabled(false)
        let folder = retained.prepared.folderURL
        let document = FolderFaceData(folderURL: folder, faces: [], groups: [], lastScanDate: Date(), scanComplete: false)
        let service = FaceDataFolderLoadService(deleteFaceData: { _ in Issue.record("Refused reset wrote") },
            saveFaceData: { _ in Issue.record("Refused document wrote") },
            saveThumbnail: { _, _, _ in Issue.record("Refused thumbnail wrote") })
        let check: FaceDataFolderLoadService.EffectAuthority = { try retained.validateForEffect(folderURL: $0) }
        if case .failedBeforeCommit = await service.persist(document, effectAuthority: check) {} else {
            Issue.record("Expected refused document")
        }
        if case .failed = await service.persistThumbnail(Data(), faceID: UUID(), folderURL: folder,
            effectAuthority: check) {} else { Issue.record("Expected refused thumbnail") }
        if case .failed = await service.deleteAll(for: folder, effectAuthority: check) {} else {
            Issue.record("Expected refused reset")
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".face_data").path))
    }

    @Test("Retained intent drives exact native scan scope and releases its lease") @MainActor
    func retainedIntentNativeScan() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = MCPFaceScanIntentStore(admission: f.service)
        let intent = try store.prepare(arguments: f.arguments)
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in FaceDetectionService.DetectionResult(faces: []) })
        let submission = try model.scheduleRetainedFolderScan(intents: store, id: intent.id)
        guard case .scheduled(let request) = submission.admission else { Issue.record("Retained scope refused"); return }
        #expect(request.imageURLs == intent.prepared.imageURLs)
        let completion = try #require(await submission.completion())
        #expect(completion.succeeded)
        #expect(completion.documentPersistenceResults.count == 1)
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Revocation during awaited detection refuses final publication and releases retained scan") @MainActor
    func retainedIntentRevocationDuringDetection() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = MCPFaceScanIntentStore(admission: f.service)
        let intent = try store.prepare(arguments: f.arguments)
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in
                await Task.yield()
                try f.authority.setEnabled(false)
                return FaceDetectionService.DetectionResult(faces: [])
            })
        let submission = try model.scheduleRetainedFolderScan(intents: store, id: intent.id)
        let completion = try #require(await submission.completion())
        #expect(!completion.succeeded)
        #expect(completion.persistenceError != nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".face_data").path))
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Failed initial asynchronous authority check releases even caller-retained lease") @MainActor
    func retainedScanInitialFailureReleasesLease() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retained = try f.service.retain(f.service.prepare(arguments: f.arguments))
        let prepared = retained.prepared
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in Issue.record("Refused scan reached detector"); return .init(faces: []) })
        let admission = model.scanFolder(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL,
            retainedAuthority: retained)
        guard case .scheduled = admission else { Issue.record("Initial admission unexpectedly refused"); return }
        try f.authority.setEnabled(false)
        let completion = try #require(await model.waitForCurrentScan())
        if case .refused = completion.outcome {} else { Issue.record("Initial authority drift must refuse") }
        #expect(throws: MCPFaceScanAdmissionService.Failure.releasedReservation) { try retained.validate() }
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Scanner retains physical thumbnail receipt after publication revokes authority") @MainActor
    func retainedScanThumbnailReceipt() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = MCPFaceScanIntentStore(admission: f.service)
        let intent = try store.prepare(arguments: f.arguments)
        let photo = intent.prepared.imageURLs[0]
        let face = DetectedFace(id: UUID(), imageURL: photo, faceRect: .zero,
            featurePrintData: Data(), detectedAt: Date())
        let bytes = Data("exact scanner thumbnail".utf8)
        let service = FaceDataFolderLoadService(saveThumbnail: { data, id, url in
            try FaceDataStorageService().saveThumbnail(data, for: id, folderURL: url)
            try f.authority.setEnabled(false)
        })
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            folderLoadService: service,
            scanDetector: { url, _ in .init(faces: url == photo ? [(face, bytes)] : []) })
        let submission = try model.scheduleRetainedFolderScan(intents: store, id: intent.id)
        let completion = try #require(await submission.completion())
        #expect(!completion.succeeded)
        #expect(completion.committedThumbnailIDs == [face.id])
        #expect(completion.persistenceError != nil)
        #expect(FaceDataStorageService().loadThumbnail(for: face.id, folderURL: intent.prepared.folderURL) == bytes)
        #expect(!FaceDataStorageService().faceDataExists(for: intent.prepared.folderURL))
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

    @Test("Unchanged scan refuses authority drift during classification without replacing saved data") @MainActor
    func retainedUnchangedScanRefusal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = MCPFaceScanIntentStore(admission: f.service)
        let intent = try store.prepare(arguments: f.arguments)
        let signature = FileSignature(modificationDate: Date(timeIntervalSince1970: 100), fileSize: 10)
        let saved = FolderFaceData(folderURL: intent.prepared.folderURL, faces: [], groups: [],
            lastScanDate: Date(), scanComplete: true,
            scannedFiles: Dictionary(uniqueKeysWithValues: intent.prepared.imageURLs.map { ($0.path, signature) }),
            embeddingVersion: FaceRecognitionDefaults.embeddingVersion)
        try FaceDataStorageService().saveFaceData(saved)
        let documentURL = intent.prepared.folderURL.appendingPathComponent(".face_data/face_data.json")
        let original = try Data(contentsOf: documentURL)
        let signatures = FaceScanFileSignatureService(readSignature: { _ in
            try? f.authority.setEnabled(false)
            return signature
        })
        let model = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            fileSignatureService: signatures,
            scanDetector: { _, _ in Issue.record("Unchanged scan reached detector"); return .init(faces: []) })
        let submission = try model.scheduleRetainedFolderScan(intents: store, id: intent.id)
        let completion = try #require(await submission.completion())
        #expect(!completion.succeeded)
        if case .refused = completion.outcome {} else { Issue.record("Unchanged drift must refuse") }
        #expect(try Data(contentsOf: documentURL) == original)
        let lease = try MCPProcessReservation.acquireFolder(f.root); lease.release()
    }

}
