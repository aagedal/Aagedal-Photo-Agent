import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Activity History")
@MainActor
struct ActivityHistoryTests {
    @Test("Upload Activity persists privacy-safe transport evidence and reads legacy entries")
    func uploadTransportEvidenceCodable() throws {
        let transport = DeliveryTransportSecurity(
            protocolKind: .sftp,
            verificationEnabled: false
        )
        let entry = ActivityEntry(
            kind: .upload,
            date: Date(timeIntervalSince1970: 100),
            title: "Desk",
            successCount: 1,
            totalCount: 1,
            deliveryTransportSecurity: transport,
            files: []
        )
        let data = try JSONEncoder().encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("sftp"))
        #expect(json.contains("verificationEnabled"))
        #expect(!json.localizedCaseInsensitiveContains("password"))
        #expect(try JSONDecoder().decode(ActivityEntry.self, from: data)
            .deliveryTransportSecurity == transport)

        let legacy = dataRemovingKey("deliveryTransportSecurity", from: data)
        #expect(try JSONDecoder().decode(ActivityEntry.self, from: legacy)
            .deliveryTransportSecurity == nil)
    }

    @Test("Stored per-file rows keep every failure but a bounded number of successes")
    func perFileRecordsAreCapped() throws {
        let limit = ActivityHistoryStore.maxSuccessfulFileRecordsPerEntry
        let successes = (0 ..< limit + 25).map {
            ActivityFileRecord(fileName: "ok-\($0).jpg", destination: "/Volumes/Photos/2026/\($0)",
                               succeeded: true, verification: .verified)
        }
        let failures = (0 ..< 30).map {
            ActivityFileRecord(fileName: "bad-\($0).jpg", destination: "/Volumes/Photos/2026",
                               succeeded: false, verification: .failed)
        }
        let entry = ActivityEntry(
            kind: .importJob,
            date: Date(),
            title: "Card",
            successCount: successes.count,
            totalCount: successes.count + failures.count,
            files: successes + failures
        )

        let store = ActivityHistoryStore()
        store.clear()
        store.record(entry)
        let stored = try #require(store.entries.first)

        #expect(stored.files.filter(\.succeeded).count == limit)
        #expect(stored.files.filter { !$0.succeeded }.count == failures.count)
        #expect(stored.omittedSuccessfulFileCount == 25)
        #expect(stored.successCount == successes.count)
        #expect(stored.totalCount == successes.count + failures.count)
        #expect(stored.failureCount == failures.count)

        // Survives persistence; legacy entries without the field decode as complete.
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(ActivityEntry.self, from: data).omittedSuccessfulFileCount == 25)
        let legacy = dataRemovingKey("omittedSuccessfulFileCount", from: data)
        #expect(try JSONDecoder().decode(ActivityEntry.self, from: legacy).omittedSuccessfulFileCount == nil)

        // Small entries are untouched.
        let small = ActivityEntry(kind: .upload, date: Date(), title: "Desk", successCount: 1,
                                  totalCount: 1, files: Array(successes.prefix(1)))
        #expect(small.cappingSuccessfulFiles(to: limit).omittedSuccessfulFileCount == nil)

        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test("Partial face results remain available in the expanded manager")
    func partialFaceResultsCanBeManaged() {
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )

        #expect(!viewModel.canShowExpandedFaceManagement)

        let folderURL = URL(fileURLWithPath: "/tmp/PartialFaceScan")
        let face = DetectedFace(
            id: UUID(),
            imageURL: folderURL.appendingPathComponent("photo.jpg"),
            faceRect: .zero,
            featurePrintData: Data([1]),
            detectedAt: Date()
        )
        viewModel.faceData = FolderFaceData(
            folderURL: folderURL,
            faces: [face],
            groups: [],
            lastScanDate: Date(),
            scanComplete: false
        )

        #expect(!viewModel.scanComplete)
        #expect(viewModel.canShowExpandedFaceManagement)
    }

    @Test("Face scan entries use photo-specific completion and cancellation summaries")
    func faceScanSummaries() {
        let completed = ActivityEntry(
            kind: .faceScan,
            date: Date(),
            title: "Cup Final",
            successCount: 24,
            totalCount: 25,
            files: []
        )
        let cancelled = ActivityEntry(
            kind: .faceScan,
            date: Date(),
            title: "Cup Final",
            successCount: 7,
            totalCount: 25,
            wasCancelled: true,
            files: []
        )

        #expect(completed.summary == "Face scan of 24 photos completed (1 failed)")
        #expect(completed.isClean == false)
        #expect(cancelled.summary == "Face scan cancelled — 7 of 25 photos")
    }

    @Test("Typed folder scan refuses an incomplete inventory before full reset", arguments: ["subset", "duplicate", "outside", "symlink", "placeholder"], [false, true])
    func typedFaceScanInventoryRefusalPreservesData(kind: String, forceFullScan: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceScope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.jpg")
        let second = folder.appendingPathComponent("second.jpg")
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: .distantPast, scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let document = folder.appendingPathComponent(".face_data/face_data.json")
        let originalBytes = try Data(contentsOf: document)
        var inputs: [URL]
        switch kind {
        case "duplicate": inputs = [first, second, first]
        case "outside": inputs = [first, second, folder.deletingLastPathComponent().appendingPathComponent("outside.jpg")]
        case "placeholder":
            try Data([3]).write(to: folder.appendingPathComponent(".remote.jpg.icloud"))
            inputs = [first, second]
        case "symlink":
            let link = folder.appendingPathComponent("linked.jpg")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            inputs = [first, second]
        default: inputs = [first]
        }
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available)
        let admission = viewModel.scanFolder(imageURLs: inputs, folderURL: folder, forceFullScan: forceFullScan)
        guard case .scheduled(let request) = admission else { Issue.record("Expected scheduled scope validation"); return }
        #expect(request.forceFullScan == forceFullScan)
        let completion = try #require(await viewModel.waitForCurrentScan())
        guard case .refused(.invalidInventory) = completion.outcome else {
            Issue.record("Expected inventory refusal, got \(completion.outcome)"); return
        }
        #expect(!completion.succeeded)
        #expect(try Data(contentsOf: document) == originalBytes)
        #expect(!viewModel.isScanning)
        let lease = try MCPProcessReservation.acquireFolder(folder)
        lease.release()
    }

    @Test("Exact scan submission survives completion and a subsequent scheduled refusal")
    func exactFaceScanSubmissionRetainsCompletion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceSubmission-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("invalid.jpg")
        try Data("invalid image".utf8).write(to: photo)
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available)
        let first = viewModel.scheduleFolderScan(imageURLs: [photo], folderURL: folder)
        guard case .scheduled = first.admission else { Issue.record("Expected scheduled scan"); return }
        let refused = viewModel.scheduleFolderScan(imageURLs: [photo], folderURL: folder)
        #expect(refused.admission == .refused(.scanAlreadyRunning))
        #expect(await refused.completion() == nil)
        let original = try #require(await first.completion())
        #expect(original.outcome == .partial)
        #expect(await viewModel.waitForCurrentScan() == nil)
        let second = viewModel.scheduleFolderScan(imageURLs: [], folderURL: folder)
        let next = try #require(await second.completion())
        guard case .refused(.invalidInventory) = next.outcome else {
            Issue.record("Expected distinct inventory refusal"); return
        }
        #expect(await first.completion() == original)
        #expect(!viewModel.isScanning)
    }

    @Test("Detection failures have a typed partial outcome and remain resumable")
    func typedPartialFaceScanOutcome() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceOutcome-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("invalid.jpg")
        try Data("invalid image".utf8).write(to: photo)
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available)
        viewModel.scanFolder(imageURLs: [photo], folderURL: folder)
        #expect(viewModel.scanFolder(imageURLs: [photo], folderURL: folder) == .refused(.scanAlreadyRunning))
        let completion = try #require(await viewModel.waitForCurrentScan())
        #expect(completion.outcome == .partial)
        #expect(completion.processedCount == 1)
        #expect(completion.failureCount == 1)
        #expect(completion.unsignedFileCount == 1)
        #expect(completion.persistenceError == nil)
        #expect(!completion.succeeded)
        #expect(FaceDataStorageService().loadFaceData(for: folder)?.scanComplete == false)
    }

    @Test("Thumbnail write failures remain partial, unsigned and resumable", arguments: [false, true])
    func faceThumbnailPersistenceFailure(failDocument: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceThumbFailure-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: photo)
        let face = DetectedFace(id: UUID(), imageURL: photo, faceRect: .zero,
            featurePrintData: Data(), detectedAt: Date())
        let failure = CocoaError(.fileWriteNoPermission)
        let history = ActivityHistoryStore()
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), activityHistory: history,
            faceModelAvailability: .available,
            folderLoadService: FaceDataFolderLoadService(saveFaceData: { data in
                if failDocument { throw CocoaError(.fileWriteUnknown) }
                try FaceDataStorageService().saveFaceData(data)
            }, saveThumbnail: { _, _, _ in throw failure }),
            scanDetector: { _, _ in .init(faces: [(face, Data([1, 2]))]) })
        let submission = viewModel.scheduleFolderScan(imageURLs: [photo], folderURL: folder)
        let completion = try #require(await submission.completion())
        #expect(completion.outcome == .partial)
        #expect(completion.processedCount == 1)
        #expect(completion.failureCount == 1)
        #expect(completion.thumbnailFailureCount == 1)
        #expect(completion.cancelledThumbnailCount == 0)
        #expect(completion.unsignedFileCount == 1)
        #expect(completion.persistenceError?.contains(failure.localizedDescription) == true)
        #expect(!completion.succeeded)
        let entry = try #require(history.entries.first)
        #expect(!entry.isClean)
        #expect(entry.successCount == 0)
        #expect(entry.persistenceError == completion.persistenceError)
        #expect(entry.summary.contains("save failed"))
        let storage = FaceDataStorageService()
        if failDocument {
            #expect(!storage.faceDataExists(for: folder))
        } else {
            let saved = try #require(storage.loadFaceData(for: folder))
            #expect(!saved.scanComplete)
            #expect(saved.faces.isEmpty)
            #expect(saved.groups.isEmpty)
            #expect(saved.scannedFiles[photo.path] == nil)
        }

        // The failed image must be detected again rather than accepted as unchanged.
        let retry = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in .init(faces: []) })
        let retried = try #require(await retry.scheduleFolderScan(imageURLs: [photo], folderURL: folder).completion())
        #expect(retried.processedCount == 1)
        #expect(retried.succeeded)
        #expect(storage.loadFaceData(for: folder)?.scanComplete == true)
    }

    @Test("A mixed thumbnail result retries the entire photo without retaining stale groups")
    func mixedFaceThumbnailRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceThumbMixed-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: photo)
        let faces = (0..<2).map { _ in DetectedFace(id: UUID(), imageURL: photo,
            faceRect: .zero, featurePrintData: Data(), detectedAt: Date()) }
        let storage = FaceDataStorageService()
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            folderLoadService: FaceDataFolderLoadService(saveThumbnail: { bytes, id, folder in
                if id == faces[1].id { throw CocoaError(.fileWriteNoPermission) }
                try storage.saveThumbnail(bytes, for: id, folderURL: folder)
            }), scanDetector: { _, _ in .init(faces: faces.map { ($0, Data([1])) }) })
        let completion = try #require(await viewModel.scheduleFolderScan(imageURLs: [photo], folderURL: folder).completion())
        #expect(completion.failureCount == 1)
        #expect(completion.thumbnailFailureCount == 1)
        #expect(viewModel.errorMessage?.contains("Failed to save face scan results") == true)
        let partial = try #require(storage.loadFaceData(for: folder))
        #expect(partial.faces.map(\.id) == [faces[0].id])
        #expect(partial.groups.flatMap(\.faceIDs) == [faces[0].id])
        #expect(partial.scannedFiles[photo.path] == nil)

        let retry = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in .init(faces: []) })
        let retried = try #require(await retry.scheduleFolderScan(imageURLs: [photo], folderURL: folder).completion())
        #expect(retried.succeeded)
        let final = try #require(storage.loadFaceData(for: folder))
        #expect(final.faces.isEmpty)
        #expect(final.groups.isEmpty)
    }

    @Test("Historical thumbnail recreation uses a stored face crop without a recognition model")
    func historicalThumbnailRecreationFromImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoricalCrop-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        let context = try #require(CGContext(data: nil, width: 200, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let source = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL,
            "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        let face = DetectedFace(id: UUID(), imageURL: photo,
            faceRect: CGRect(x: 0.25, y: 0.2, width: 0.3, height: 0.4),
            featurePrintData: Data([1]), detectedAt: .distantPast)
        let bytes = try FaceDetectionService().regenerateThumbnail(for: face)
        let recreated = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(recreated, 0, nil))
        // AppKit draws in points; a Retina host encodes twice as many pixels.
        #expect(image.width == image.height)
        #expect(image.width >= 120)
    }

    @Test("Historical missing thumbnails repair without losing signed faces or named groups",
          arguments: ["success", "generationFailure", "saveFailure", "cancelled", "cancellationError", "sourceDrift"])
    func historicalThumbnailRepair(outcome: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoricalFaceThumb-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        let signature = FileSignature(modificationDate: .distantPast, fileSize: 1)
        let faces = (0..<2).map { _ in DetectedFace(id: UUID(), imageURL: photo,
            faceRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            featurePrintData: Data([4]), detectedAt: .distantPast) }
        let group = FaceGroup(id: UUID(), name: "Retained person", representativeFaceID: faces[1].id,
            faceIDs: faces.map(\.id))
        let numbers = [NumberDetection(imageURL: photo, number: 7, numberConfidence: 1, boundingBox: .zero)]
        let original = FolderFaceData(folderURL: folder, faces: faces, groups: [group],
            lastScanDate: .distantPast, scanComplete: true, scannedFiles: [photo.path: signature],
            embeddingVersion: FaceRecognitionDefaults.embeddingVersion, numberDetections: numbers)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        try Data([1]).write(to: photo)
        // One crop survives; the missing representative must be repaired under its exact ID.
        try storage.saveThumbnail(Data([8]), for: faces[0].id, folderURL: folder)
        let gate = FaceThumbnailCancellationGate()
        let signatures = FaceScanFileSignatureService { url in
            (try? Data(contentsOf: url)) == Data([1]) ? signature
                : FileSignature(modificationDate: .distantPast, fileSize: 2)
        }
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            folderLoadService: FaceDataFolderLoadService(saveThumbnail: { bytes, id, folder in
                if outcome == "saveFailure" { throw CocoaError(.fileWriteNoPermission) }
                try storage.saveThumbnail(bytes, for: id, folderURL: folder)
            }), fileSignatureService: signatures,
            scanDetector: { _, _ in
                Issue.record("Unchanged historical faces must not be detected again")
                return .init(faces: [])
            }, thumbnailRegenerator: { face in
                #expect(face.id == faces[1].id)
                #expect(throws: MCPProcessReservationError.busy) {
                    _ = try MCPProcessReservation.acquirePhoto(photo)
                }
                if outcome == "cancelled" { await gate.pauseDetection() }
                if outcome == "generationFailure" { throw CocoaError(.fileReadCorruptFile) }
                if outcome == "cancellationError" { throw CancellationError() }
                if outcome == "sourceDrift" { try Data([1, 2]).write(to: photo) }
                return Data([9])
            })
        let originalBytes = try Data(contentsOf: folder.appendingPathComponent(".face_data/face_data.json"))
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(!viewModel.scanComplete)
        #expect(viewModel.faceData?.groups.first?.id == group.id)
        #expect(try Data(contentsOf: folder.appendingPathComponent(".face_data/face_data.json")) == originalBytes)
        let submission = viewModel.scheduleFolderScan(imageURLs: [photo], folderURL: folder)
        if outcome == "cancelled" {
            await gate.waitUntilEntered()
            viewModel.cancelScan()
            await gate.release()
        }
        let completion = try #require(await submission.completion())
        #expect(completion.processedCount == 1)
        #expect(completion.succeeded == (outcome == "success"))
        #expect(completion.unsignedFileCount == (outcome == "success" ? 0 : 1))
        #expect(completion.thumbnailFailureCount == (["generationFailure", "saveFailure"].contains(outcome) ? 1 : 0))
        #expect(completion.cancelledThumbnailCount == (["cancelled", "cancellationError"].contains(outcome) ? 1 : 0))
        let saved = try #require(storage.loadFaceData(for: folder))
        #expect(saved.scanComplete == (outcome == "success"))
        #expect(saved.faces.map(\.id) == faces.map(\.id))
        #expect(saved.faces.map(\.featurePrintData) == faces.map(\.featurePrintData))
        #expect(saved.groups.first?.id == group.id)
        #expect(saved.groups.first?.name == group.name)
        #expect(saved.groups.first?.faceIDs == group.faceIDs)
        #expect(saved.groups.first?.representativeFaceID == group.representativeFaceID)
        #expect(saved.numberDetections?.map(\.number) == [7])
        #expect(storage.loadThumbnail(for: faces[0].id, folderURL: folder) == Data([8]))
        #expect(saved.scannedFiles[photo.path] == (outcome == "sourceDrift" ? nil : signature))

        if outcome != "sourceDrift" {
            let retry = FaceRecognitionViewModel(readService: SwiftExifReadService(),
                writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
                fileSignatureService: signatures,
                scanDetector: { _, _ in Issue.record("Repair retry must preserve identity"); return .init(faces: []) },
                thumbnailRegenerator: { face in
                    #expect(face.id == faces[1].id)
                    return Data([9])
                })
            let retried = try #require(await retry.scheduleFolderScan(imageURLs: [photo], folderURL: folder).completion())
            #expect(retried.succeeded)
            #expect(retried.processedCount == (outcome == "success" ? 0 : 1))
            let final = try #require(storage.loadFaceData(for: folder))
            #expect(final.scanComplete)
            #expect(final.groups.first?.id == group.id)
            #expect(final.faces.map(\.id) == faces.map(\.id))
            #expect(storage.loadThumbnail(for: faces[1].id, folderURL: folder) == Data([9]))
        }
    }

    @Test("Cancellation before thumbnail commit preserves a resumable document without unsaved face references")
    func faceThumbnailCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceThumbCancel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: photo)
        let face = DetectedFace(id: UUID(), imageURL: photo, faceRect: .zero,
            featurePrintData: Data(), detectedAt: Date())
        let gate = FaceThumbnailCancellationGate()
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            folderLoadService: FaceDataFolderLoadService(saveThumbnail: { _, _, _ in
                Issue.record("A cancelled thumbnail must not enter the saver")
            }), scanDetector: { _, _ in
                await gate.pauseDetection()
                return .init(faces: [(face, Data([1]))])
            })
        let submission = viewModel.scheduleFolderScan(imageURLs: [photo], folderURL: folder)
        await gate.waitUntilEntered()
        viewModel.cancelScan()
        await gate.release()
        let completion = try #require(await submission.completion())
        #expect(completion.outcome == .cancelled)
        #expect(completion.cancelledThumbnailCount == 1)
        #expect(completion.thumbnailFailureCount == 0)
        #expect(completion.persistenceError == nil)
        #expect(!completion.succeeded)
        let saved = try #require(FaceDataStorageService().loadFaceData(for: folder))
        #expect(!saved.scanComplete)
        #expect(saved.faces.isEmpty)
        #expect(saved.groups.isEmpty)
        #expect(saved.scannedFiles[photo.path] == nil)
    }

    @Test("Activity retains document save failures and reads history without that field")
    func activityPersistenceFailureCodable() throws {
        let entry = ActivityEntry(kind: .faceScan, date: Date(), title: "Scan",
            successCount: 1, totalCount: 1, persistenceError: "disk write failed", files: [])
        #expect(!entry.isClean)
        #expect(entry.summary == "Face scan of 1 photo completed (save failed)")
        let bytes = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(ActivityEntry.self, from: bytes).persistenceError == entry.persistenceError)
        let legacy = try JSONDecoder().decode(ActivityEntry.self,
            from: dataRemovingKey("persistenceError", from: bytes))
        #expect(legacy.persistenceError == nil)
        #expect(legacy.isClean)
    }

    @Test("An incomplete signed snapshot is durably completed instead of only changing presentation", arguments: [false, true])
    func typedFaceScanCompletesSignedSnapshot(failSave: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceSignedPartial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("signed.jpg")
        let signature = FileSignature(modificationDate: .distantPast, fileSize: 1)
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [], lastScanDate: .distantPast,
            scanComplete: false, scannedFiles: [photo.path: signature],
            embeddingVersion: FaceRecognitionDefaults.embeddingVersion)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        try Data([1]).write(to: photo)
        let document = folder.appendingPathComponent(".face_data/face_data.json")
        let originalBytes = try Data(contentsOf: document)
        let history = ActivityHistoryStore()
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), activityHistory: history, faceModelAvailability: .available,
            folderLoadService: FaceDataFolderLoadService(saveFaceData: { data in
                if failSave { throw CocoaError(.fileWriteNoPermission) }
                try FaceDataStorageService().saveFaceData(data)
            }),
            fileSignatureService: FaceScanFileSignatureService { _ in signature })
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        viewModel.scanFolder(imageURLs: [photo], folderURL: folder)
        let completion = try #require(await viewModel.waitForCurrentScan())
        #expect(completion.outcome == .completed)
        #expect(completion.processedCount == 0)
        #expect(completion.succeeded == !failSave)
        #expect((completion.persistenceError != nil) == failSave)
        let entry = try #require(history.entries.first)
        #expect(entry.isClean == !failSave)
        #expect((entry.persistenceError != nil) == failSave)
        #expect(entry.summary.contains("save failed") == failSave)
        #expect(viewModel.scanComplete == !failSave)
        #expect(storage.loadFaceData(for: folder)?.scanComplete == !failSave)
        if failSave { #expect(try Data(contentsOf: document) == originalBytes) }
    }

    @Test("A background face scan does not replace the newly displayed folder")
    func backgroundScanPreservesDisplayedFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanNavigationTests-\(UUID().uuidString)")
        let scannedFolder = root.appendingPathComponent("Scanning")
        let displayedFolder = root.appendingPathComponent("Current")
        try FileManager.default.createDirectory(at: scannedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: displayedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A readable but invalid image exercises the real background/error path without a model run.
        let invalidImage = scannedFolder.appendingPathComponent("not-an-image.jpg")
        try Data("not an image".utf8).write(to: invalidImage)

        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .available
        )
        viewModel.loadFaceData(for: scannedFolder, cleanupPolicy: .never)
        viewModel.scanFolder(imageURLs: [invalidImage], folderURL: scannedFolder)
        viewModel.loadFaceData(for: displayedFolder, cleanupPolicy: .never)

        #expect(viewModel.isScanning)
        #expect(viewModel.isScanning(folderURL: scannedFolder))
        #expect(!viewModel.isScanning(folderURL: displayedFolder))
        #expect(viewModel.displayedFolderURL == displayedFolder.standardizedFileURL)

        await viewModel.waitForCurrentScan()

        #expect(!viewModel.isScanning)
        #expect(viewModel.displayedFolderURL == displayedFolder.standardizedFileURL)
        #expect(viewModel.faceData == nil)
        #expect(!viewModel.scanComplete)
    }

    @Test("Busy face scan admission preserves existing results and durable data", arguments: [false, true])
    func busyScanPreservesResults(folderReservation: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanAdmission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.jpg")
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(timeIntervalSince1970: 100), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .available)
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        let lease = try folderReservation
            ? MCPProcessReservation.acquireFolder(folder)
            : MCPProcessReservation.acquirePhoto(photo)
        defer { lease.release() }
        viewModel.scanFolder(imageURLs: [photo], folderURL: folder, forceFullScan: true)
        let completion = try #require(await viewModel.waitForCurrentScan())
        #expect(completion.outcome == .refused(.reservationFailed(MCPProcessReservationError.busy.localizedDescription)))
        #expect(!completion.succeeded)

        #expect(!viewModel.isScanning)
        #expect(!viewModel.isCancellingScan)
        #expect(viewModel.scanningFolderURL == nil)
        #expect(viewModel.errorMessage == MCPProcessReservationError.busy.localizedDescription)
        #expect(viewModel.faceData?.lastScanDate == original.lastScanDate)
        #expect(storage.loadFaceData(for: folder)?.lastScanDate == original.lastScanDate)
        lease.release()
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
    }

    @Test("Failed full-scan reset preserves results and allows explicit retry", arguments: [false, true])
    func fullScanResetFailure(cancelImmediately: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceResetFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("invalid.jpg")
        let face = DetectedFace(id: UUID(), imageURL: photo, faceRect: .zero,
            featurePrintData: Data([1]), detectedAt: Date())
        let original = FolderFaceData(folderURL: folder, faces: [face], groups: [],
            lastScanDate: Date(timeIntervalSince1970: 100), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        try storage.saveThumbnail(Data([1, 2]), for: face.id, folderURL: folder)
        try Data("not an image".utf8).write(to: photo)
        let documentURL = folder.appendingPathComponent(".face_data/face_data.json")
        let originalBytes = try Data(contentsOf: documentURL)
        let allowReset = MCPServerCoreTests.DataBox()
        let saved = MCPServerCoreTests.DataBox()
        let failure = CocoaError(.fileWriteNoPermission)
        let service = FaceDataFolderLoadService(deleteFaceData: { url in
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(photo)
            }
            guard allowReset.read() != nil else { throw failure }
            try FaceDataStorageService().deleteFaceData(for: url)
        }, saveFaceData: { document in
            saved.write(Data([1]))
            try FaceDataStorageService().saveFaceData(document)
        })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            folderLoadService: service)
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        viewModel.scanFolder(imageURLs: [photo], folderURL: folder, forceFullScan: true)
        if cancelImmediately { viewModel.cancelScan() }
        await viewModel.waitForCurrentScan()

        #expect(!viewModel.isScanning)
        #expect(!viewModel.isCancellingScan)
        #expect(viewModel.scanningFolderURL == nil)
        #expect(viewModel.scanProgress.isEmpty)
        #expect(viewModel.scanProcessedCount == 0)
        #expect(viewModel.scanTotalCount == 0)
        #expect(viewModel.faceData?.faces.map(\.id) == [face.id])
        #expect(viewModel.scanComplete)
        #expect(viewModel.errorMessage == "Failed to remove previous face data: \(failure.localizedDescription)")
        #expect(saved.read() == nil)
        #expect(try Data(contentsOf: documentURL) == originalBytes)
        #expect(storage.loadThumbnail(for: face.id, folderURL: folder) == Data([1, 2]))
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()

        allowReset.write(Data([1]))
        viewModel.scanFolder(imageURLs: [photo], folderURL: folder, forceFullScan: true)
        await viewModel.waitForCurrentScan()
        #expect(!viewModel.isScanning)
        #expect(saved.read() != nil)
        #expect(storage.loadFaceData(for: folder)?.faces.isEmpty == true)
        #expect(storage.loadThumbnail(for: face.id, folderURL: folder) == nil)
    }

    @Test("Face scan holds admission through final persistence and releases on every exit",
          arguments: ["complete", "cancelled", "failed", "unchanged"])
    func scanReservationLifetime(outcome: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanLifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("invalid.jpg")
        if outcome != "unchanged" { try Data("not an image".utf8).write(to: photo) }
        let persistenceObserved = MCPServerCoreTests.DataBox()
        let service = FaceDataFolderLoadService(loadFaceData: { _ in
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(photo)
            }
            return nil
        }, saveFaceData: { data in
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquireFolder(folder)
            }
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(photo)
            }
            persistenceObserved.write(Data([data.scanComplete ? 1 : 0]))
            if outcome == "failed" { throw CocoaError(.fileWriteUnknown) }
            try FaceDataStorageService().saveFaceData(data)
        })
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .available, folderLoadService: service)
        viewModel.scanFolder(imageURLs: outcome == "unchanged" ? [] : [photo], folderURL: folder)
        if outcome == "cancelled" { viewModel.cancelScan() }
        let completion = try #require(await viewModel.waitForCurrentScan())
        if outcome == "unchanged" {
            #expect(completion.outcome == .unchanged)
            #expect(completion.succeeded)
        } else if outcome == "cancelled" {
            #expect(completion.outcome == .cancelled)
            #expect(!completion.succeeded)
        } else {
            #expect(completion.outcome == .partial)
            #expect(completion.failureCount == 1)
            #expect(!completion.succeeded)
        }
        #expect((completion.persistenceError != nil) == (outcome == "failed"))

        #expect(!viewModel.isScanning)
        if outcome == "unchanged" {
            #expect(persistenceObserved.read() == nil)
        } else {
            #expect(persistenceObserved.read() == Data([0]))
        }
        if outcome == "failed" {
            #expect(viewModel.errorMessage?.contains("Failed to save") == true)
            #expect(!viewModel.scanComplete)
        }
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
    }

    @Test("Removal-only incremental scans persist pruned results under admission",
          arguments: [false, true], [false, true])
    func removalOnlyScanPersistence(keepSurvivor: Bool, failSave: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceRemovalOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let removed = folder.appendingPathComponent("removed.jpg")
        let survivor = folder.appendingPathComponent("survivor.jpg")
        let removedFace = DetectedFace(id: UUID(), imageURL: removed, faceRect: .zero,
            featurePrintData: Data([1]), detectedAt: Date())
        let survivingFace = DetectedFace(id: UUID(), imageURL: survivor, faceRect: .zero,
            featurePrintData: Data([2]), detectedAt: Date())
        let faces = keepSurvivor ? [removedFace, survivingFace] : [removedFace]
        let group = FaceGroup(id: UUID(), name: "Preserved name",
            representativeFaceID: removedFace.id, faceIDs: faces.map(\.id))
        let signature = FileSignature(modificationDate: .distantPast, fileSize: 1)
        let numbers = faces.map { NumberDetection(imageURL: $0.imageURL, number: 7,
            numberConfidence: 1, boundingBox: .zero) }
        let original = FolderFaceData(folderURL: folder, faces: faces, groups: [group],
            lastScanDate: .distantPast, scanComplete: true,
            scannedFiles: Dictionary(uniqueKeysWithValues: faces.map { ($0.imageURL.path, signature) }),
            embeddingVersion: FaceRecognitionDefaults.embeddingVersion, numberDetections: numbers)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        if keepSurvivor {
            try Data([1]).write(to: survivor)
            try storage.saveThumbnail(Data([1]), for: survivingFace.id, folderURL: folder)
        }
        let document = folder.appendingPathComponent(".face_data/face_data.json")
        let originalBytes = try Data(contentsOf: document)
        let saved = MCPServerCoreTests.DataBox()
        let service = FaceDataFolderLoadService(saveFaceData: { data in
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(removed)
            }
            saved.write(try JSONEncoder().encode(data))
            if failSave { throw CocoaError(.fileWriteNoPermission) }
            try FaceDataStorageService().saveFaceData(data)
        })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            folderLoadService: service,
            fileSignatureService: FaceScanFileSignatureService { _ in signature })
        viewModel.scanFolder(imageURLs: keepSurvivor ? [survivor] : [], folderURL: folder)
        await viewModel.waitForCurrentScan()

        let proposed = try JSONDecoder().decode(FolderFaceData.self, from: #require(saved.read()))
        #expect(proposed.faces.map(\.id) == (keepSurvivor ? [survivingFace.id] : []))
        #expect(proposed.groups.count == (keepSurvivor ? 1 : 0))
        #expect(proposed.groups.first?.name == (keepSurvivor ? "Preserved name" : nil))
        #expect(proposed.groups.first?.representativeFaceID == (keepSurvivor ? survivingFace.id : nil))
        #expect(proposed.numberDetections?.map(\.imageURL) == (keepSurvivor ? [survivor] : []))
        #expect(Set(proposed.scannedFiles.keys) == (keepSurvivor ? [survivor.path] : []))
        #expect(proposed.scanComplete)
        if failSave {
            #expect(viewModel.errorMessage?.contains("Failed to save") == true)
            #expect(try Data(contentsOf: document) == originalBytes)
        } else {
            #expect(storage.loadFaceData(for: folder)?.faces.map(\.id) == proposed.faces.map(\.id))
            #expect(storage.loadFaceData(for: folder)?.scannedFiles == proposed.scannedFiles)
        }
        #expect(!viewModel.isScanning)
        let lease = try MCPProcessReservation.acquireFolder(folder)
        lease.release()
    }

    @Test("Interactive face writes refuse busy folders before document or thumbnail mutation",
          arguments: [false, true])
    func interactiveFaceWriteAdmission(folderReservation: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceWriteAdmission-\(UUID().uuidString)")
        let photo = folder.appendingPathComponent("photo.jpg")
        let lease = try folderReservation
            ? MCPProcessReservation.acquireFolder(folder)
            : MCPProcessReservation.acquirePhoto(photo)
        defer { lease.release() }
        let service = FaceDataFolderLoadService(deleteFaceData: { _ in
            Issue.record("Busy deletion reached storage")
        }, saveFaceData: { _ in
            Issue.record("Busy write reached storage")
        }, deleteThumbnail: { _, _ in
            Issue.record("Busy thumbnail cleanup reached storage")
        })
        let document = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(), scanComplete: true)
        #expect(await service.persistWithFolderReservation(document, deletingThumbnailIDs: [UUID()])
            == .failedBeforeCommit(folderURL: folder.standardizedFileURL,
                message: MCPProcessReservationError.busy.localizedDescription))
        #expect(await service.deleteAllWithFolderReservation(for: folder)
            == .failed(folderURL: folder.standardizedFileURL,
                message: MCPProcessReservationError.busy.localizedDescription))
    }

    @Test("Interactive face writes hold admission through cleanup and release after failure or cancellation",
          arguments: ["success", "saveFailure", "cleanupFailure", "deleteFailure", "cancelAfterCommit", "cancelBeforeCommit"])
    func interactiveFaceWriteLifetime(outcome: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceWriteLifetime-\(UUID().uuidString)")
        let photo = folder.appendingPathComponent("photo.jpg")
        let check: @Sendable () -> Void = {
            #expect(outcome != "cancelBeforeCommit")
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(photo)
            }
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquireFolder(folder)
            }
        }
        let service = FaceDataFolderLoadService(deleteFaceData: { _ in
            check()
            if outcome == "deleteFailure" { throw CocoaError(.fileWriteUnknown) }
        }, saveFaceData: { _ in
            check()
            if outcome == "saveFailure" { throw CocoaError(.fileWriteUnknown) }
            if outcome == "cancelAfterCommit" { withUnsafeCurrentTask { $0?.cancel() } }
        }, deleteThumbnail: { _, _ in
            check()
            #expect(outcome != "cancelAfterCommit")
            if outcome == "cleanupFailure" { throw CocoaError(.fileWriteUnknown) }
        })
        let document = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(), scanComplete: true)
        let faceID = UUID()
        let result = await Task {
            if outcome == "cancelBeforeCommit" { withUnsafeCurrentTask { $0?.cancel() } }
            return await service.persistWithFolderReservation(document, deletingThumbnailIDs: [faceID])
        }.value
        switch result {
        case .committed(let evidence):
            #expect(outcome != "saveFailure" && outcome != "cancelBeforeCommit")
            #expect(evidence.deletedThumbnailIDs ==
                (["cleanupFailure", "cancelAfterCommit"].contains(outcome) ? [] : [faceID]))
            #expect(evidence.thumbnailFailures.count == (outcome == "cleanupFailure" ? 1 : 0))
            #expect(evidence.cancellationRequestedAfterCommit == (outcome == "cancelAfterCommit"))
        case .failedBeforeCommit:
            #expect(outcome == "saveFailure")
        case .cancelledBeforeCommit:
            #expect(outcome == "cancelBeforeCommit")
        }
        let deletion = await Task {
            if outcome == "cancelBeforeCommit" { withUnsafeCurrentTask { $0?.cancel() } }
            return await service.deleteAllWithFolderReservation(for: folder)
        }.value
        switch deletion {
        case .committed: #expect(outcome != "deleteFailure" && outcome != "cancelBeforeCommit")
        case .anchored: Issue.record("Native deletion unexpectedly used retained reset")
        case .committedButUnverified: Issue.record("Native deletion unexpectedly required authority verification")
        case .failed: #expect(outcome == "deleteFailure")
        case .cancelledBeforeCommit: #expect(outcome == "cancelBeforeCommit")
        }
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
    }

    @Test("Folder loads refuse competing operations before cleanup or recovery", arguments: [false, true])
    func faceLoadAdmission(folderReservation: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lease = try folderReservation ? MCPProcessReservation.acquireFolder(folder)
            : MCPProcessReservation.acquirePhoto(folder.appendingPathComponent("photo.jpg"))
        defer { lease.release() }
        let service = FaceDataFolderLoadService(loadFaceData: { _ in
            Issue.record("A refused load must not read or relocate the document")
            return nil
        }, deleteFaceData: { _ in Issue.record("A refused load must not delete data") })
        do {
            _ = try await service.loadWithFolderReservation(folderURL: folder, cleanupPolicy: .sevenDays)
            Issue.record("A competing operation must refuse loading")
        } catch {
            #expect(error as? MCPProcessReservationError == .busy)
        }
    }

    @Test("Folder load owns cleanup and thumbnails, and releases after cancellation or failure",
          arguments: ["success", "deleteFailure", "cancelBefore", "cancelAfterRead", "cancelAfterDelete"])
    func faceLoadReservationLifetime(outcome: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let photo = folder.appendingPathComponent("photo.jpg")
        let faceID = UUID()
        let document = FolderFaceData(folderURL: folder,
            faces: [DetectedFace(id: faceID, imageURL: photo, faceRect: .zero,
                featurePrintData: Data([1]), detectedAt: Date())], groups: [],
            lastScanDate: Date(timeIntervalSince1970: 100), scanComplete: true)
        let check: @Sendable () -> Void = {
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(photo)
            }
        }
        let service = FaceDataFolderLoadService(loadFaceData: { _ in
            #expect(outcome != "cancelBefore")
            check()
            if outcome == "cancelAfterRead" { withUnsafeCurrentTask { $0?.cancel() } }
            return document
        }, loadThumbnail: { _, _ in
            check()
            #expect(outcome == "success" || outcome == "deleteFailure")
            return Data([1])
        }, deleteFaceData: { _ in
            check()
            #expect(outcome == "deleteFailure" || outcome == "cancelAfterDelete")
            if outcome == "deleteFailure" { throw CocoaError(.fileWriteUnknown) }
            if outcome == "cancelAfterDelete" { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let result = try await Task {
            if outcome == "cancelBefore" { withUnsafeCurrentTask { $0?.cancel() } }
            return try await service.loadWithFolderReservation(folderURL: folder,
                cleanupPolicy: outcome == "success" ? .never : .sevenDays)
        }.value
        switch result {
        case .cancelled:
            #expect(outcome == "cancelBefore" || outcome == "cancelAfterRead")
        case .complete(let evidence):
            if outcome == "cancelAfterDelete" {
                #expect(evidence.cleanupDisposition == .deleted(cancellationRequestedAfterCommit: true))
                #expect(evidence.faceData == nil)
            } else {
                #expect(evidence.thumbnailData[faceID] == Data([1]))
                if outcome == "deleteFailure" {
                    guard case .deletionFailed = evidence.cleanupDisposition else {
                        Issue.record("Cleanup failure must remain visible in evidence")
                        return
                    }
                }
            }
        }
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
    }

    @Test("Document consumers preserve corrupt bytes; admitted folder recovery relocates them")
    func corruptFaceDocumentReadAndRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent(".face_data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("face_data.json")
        let bytes = Data("corrupt fixture".utf8)
        try bytes.write(to: file)
        let service = FaceDataFolderLoadService()
        guard case .complete(let evidence) = await service.loadDocument(folderURL: folder) else {
            Issue.record("Document read should complete with decode failure evidence")
            return
        }
        #expect(evidence.documentExisted && evidence.faceData == nil)
        #expect(try Data(contentsOf: file) == bytes)
        let lease = try MCPProcessReservation.acquireFolder(folder)
        defer { lease.release() }
        do {
            _ = try await service.loadWithFolderReservation(folderURL: folder, cleanupPolicy: .never)
            Issue.record("Busy recovery must refuse")
        } catch { #expect(error as? MCPProcessReservationError == .busy) }
        #expect(try Data(contentsOf: file) == bytes)
        lease.release()
        _ = try await service.loadWithFolderReservation(folderURL: folder, cleanupPolicy: .never)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == bytes)
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
    }

    @Test("Busy same-folder reload retains visible results and allows expiration on retry")
    func faceLoadRetryPreservesPresentation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = FaceDataStorageService()
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(timeIntervalSince1970: 100), scanComplete: true)
        try storage.saveFaceData(original)
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        let lease = try MCPProcessReservation.acquireFolder(folder)
        defer { lease.release() }
        viewModel.loadFaceData(for: folder, cleanupPolicy: .sevenDays)
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(viewModel.faceData?.lastScanDate == original.lastScanDate)
        #expect(viewModel.scanComplete)
        #expect(storage.faceDataExists(for: folder))
        #expect(viewModel.errorMessage?.contains(MCPProcessReservationError.busy.localizedDescription) == true)
        lease.release()
        viewModel.loadFaceData(for: folder, cleanupPolicy: .sevenDays)
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(viewModel.faceData == nil)
        #expect(!storage.faceDataExists(for: folder))
    }

    @Test("Lazy photo-face deletion refuses a busy folder before reading or recovering it",
          arguments: [false, true])
    func lazyFaceDeletionAdmission(folderReservation: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let photo = folder.appendingPathComponent("photo.jpg")
        let service = FaceDataFolderLoadService(loadFaceData: { _ in
            Issue.record("Refused deletion must not read or recover a document")
            return nil
        }, saveFaceData: { _ in Issue.record("Refused deletion must not save") })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        let lease = try folderReservation ? MCPProcessReservation.acquireFolder(folder)
            : MCPProcessReservation.acquirePhoto(photo)
        defer { lease.release() }
        viewModel.deleteFaces(forImageURLs: [photo])
        await viewModel.waitForCurrentFaceDataLoad()
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(viewModel.faceData == nil)
        #expect(viewModel.errorMessage?.contains(MCPProcessReservationError.busy.localizedDescription) == true)
    }

    @Test("Lazy photo-face deletion retries after contention and preserves other photos",
          arguments: [false, true])
    func lazyFaceDeletionRetry(directoryURL: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: directoryURL)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["removed.jpg", "retained.jpg"].map { folder.appendingPathComponent($0) }
        let groupID = UUID()
        let faces = photos.map { DetectedFace(id: UUID(), imageURL: $0, faceRect: .zero,
            featurePrintData: Data([1]), groupID: groupID, detectedAt: Date()) }
        let group = FaceGroup(id: groupID, name: "Person", representativeFaceID: faces[0].id,
            faceIDs: faces.map(\.id))
        let storage = FaceDataStorageService()
        try storage.saveFaceData(FolderFaceData(folderURL: folder, faces: faces, groups: [group],
            lastScanDate: Date(), scanComplete: true))
        for face in faces { try storage.saveThumbnail(Data([1]), for: face.id, folderURL: folder) }
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        let lease = try MCPProcessReservation.acquireFolder(folder)
        defer { lease.release() }
        viewModel.deleteFaces(forImageURLs: [photos[0]])
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(storage.loadFaceData(for: folder)?.faces.count == 2)
        lease.release()
        viewModel.deleteFaces(forImageURLs: [photos[0]])
        await viewModel.waitForCurrentFaceDataLoad()
        await viewModel.waitForCurrentFaceDataPersistence()
        let saved = try #require(storage.loadFaceData(for: folder))
        #expect(saved.faces.map(\.id) == [faces[1].id])
        #expect(saved.groups.first?.faceIDs == [faces[1].id])
        #expect(saved.groups.first?.representativeFaceID == faces[1].id)
        #expect(storage.loadThumbnail(for: faces[0].id, folderURL: folder) == nil)
        #expect(storage.loadThumbnail(for: faces[1].id, folderURL: folder) == Data([1]))
    }

    @Test("Loaded photo deletion preserves newer disk groups and faces", arguments: ["success", "busy", "queued", "overlappingEdit"], [false, true])
    func loadedPhotoDeletionReconcilesDisk(outcome: String, byID: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = ["removed.jpg", "survivor.jpg", "new.jpg"].map { folder.appendingPathComponent($0) }
        let groupID = UUID()
        let faces = photos.map { DetectedFace(id: UUID(), imageURL: $0, faceRect: .zero,
            featurePrintData: Data([1]), groupID: groupID, detectedAt: Date()) }
        let storage = FaceDataStorageService()
        let original = FolderFaceData(folderURL: folder, faces: Array(faces.prefix(2)),
            groups: [FaceGroup(id: groupID, name: "Original", representativeFaceID: faces[0].id,
                faceIDs: Array(faces.prefix(2)).map(\.id))], lastScanDate: Date(), scanComplete: true)
        try storage.saveFaceData(original)
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(viewModel.faceData?.faces.count == 2)
        var newer = original
        newer.faces = faces
        newer.groups[0].name = "External rename"
        newer.groups[0].faceIDs = faces.map(\.id)
        try storage.saveFaceData(newer)
        for face in faces { try storage.saveThumbnail(Data([1]), for: face.id, folderURL: folder) }
        let busy = outcome == "busy"
        let lease = try busy ? MCPProcessReservation.acquireFolder(folder) : nil
        defer { lease?.release() }
        if byID {
            viewModel.deleteFaces([faces[0].id])
            if outcome == "queued" { viewModel.deleteFaces([faces[1].id]) }
        } else {
            viewModel.deleteFaces(forImageURLs: [photos[0]])
            if outcome == "queued" { viewModel.deleteFaces(forImageURLs: [photos[1]]) }
        }
        if outcome == "overlappingEdit" { viewModel.nameGroup(groupID, name: "Unsaved local edit") }
        await viewModel.waitForCurrentFaceDataPersistence()
        let saved = try #require(storage.loadFaceData(for: folder))
        #expect(saved.groups.first?.name == "External rename")
        if busy {
            #expect(saved.faces.count == 3)
            #expect(viewModel.faceData?.faces.count == 2)
            #expect(viewModel.errorMessage?.contains(MCPProcessReservationError.busy.localizedDescription) == true)
        } else if outcome == "overlappingEdit" {
            #expect(saved.faces.map(\.id) == Array(faces.dropFirst()).map(\.id))
            #expect(viewModel.faceData?.groups.first?.name == "Unsaved local edit")
            #expect(viewModel.errorMessage?.contains("This edit was not saved") == true)
            viewModel.nameGroup(groupID, name: "Still stale")
            await viewModel.waitForCurrentFaceDataPersistence()
            #expect(storage.loadFaceData(for: folder)?.groups.first?.name == "External rename")
            #expect(storage.loadFaceData(for: folder)?.faces.count == 2)
            viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
            await viewModel.waitForCurrentFaceDataLoad()
            viewModel.nameGroup(groupID, name: "Reapplied after reload")
            await viewModel.waitForCurrentFaceDataPersistence()
            #expect(storage.loadFaceData(for: folder)?.groups.first?.name == "Reapplied after reload")
            #expect(storage.loadFaceData(for: folder)?.faces.count == 2)
        } else {
            #expect(saved.faces.map(\.id) == Array(faces.dropFirst(outcome == "queued" ? 2 : 1)).map(\.id))
            #expect(viewModel.faceData?.faces.map(\.id) == saved.faces.map(\.id))
            #expect(viewModel.faceData?.groups.first?.name == "External rename")
            #expect(saved.groups.first?.representativeFaceID == faces[outcome == "queued" ? 2 : 1].id)
            #expect(storage.loadThumbnail(for: faces[0].id, folderURL: folder) == nil)
            #expect(storage.loadThumbnail(for: faces[2].id, folderURL: folder) == Data([1]))
        }
    }

    @Test("Individual deletion preserves other faces in the same photo and unknown IDs are harmless")
    func individualDeletionKeepsPhotoPeers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("group-photo.jpg")
        let faces = (0..<2).map { _ in DetectedFace(id: UUID(), imageURL: photo,
            faceRect: .zero, featurePrintData: Data([1]), detectedAt: Date()) }
        let group = FaceGroup(id: UUID(), name: "People", representativeFaceID: faces[0].id,
            faceIDs: faces.map(\.id))
        let storage = FaceDataStorageService()
        try storage.saveFaceData(FolderFaceData(folderURL: folder, faces: faces, groups: [group],
            lastScanDate: Date(), scanComplete: true))
        for face in faces { try storage.saveThumbnail(Data([1]), for: face.id, folderURL: folder) }
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        viewModel.deleteFaces([faces[0].id, UUID()])
        await viewModel.waitForCurrentFaceDataPersistence()
        let saved = try #require(storage.loadFaceData(for: folder))
        #expect(saved.faces.map(\.id) == [faces[1].id])
        #expect(saved.groups.first?.faceIDs == [faces[1].id])
        #expect(saved.groups.first?.representativeFaceID == faces[1].id)
        #expect(viewModel.faceData?.faces.map(\.id) == [faces[1].id])
        #expect(storage.loadThumbnail(for: faces[0].id, folderURL: folder) == nil)
        #expect(storage.loadThumbnail(for: faces[1].id, folderURL: folder) == Data([1]))
        viewModel.deleteFaces([faces[0].id, UUID()])
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(storage.loadFaceData(for: folder)?.faces.map(\.id) == saved.faces.map(\.id))
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Lazy deletion owns one reservation through read, commit and cleanup",
          arguments: ["success", "saveFailure", "cleanupFailure", "cancelDuringRead", "cancelAfterCommit"])
    func lazyFaceDeletionTransaction(outcome: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("removed.jpg")
        let survivor = folder.appendingPathComponent("survivor.jpg")
        let faces = [photo, survivor].map { DetectedFace(id: UUID(), imageURL: $0,
            faceRect: .zero, featurePrintData: Data([1]), detectedAt: Date()) }
        // Group cleanup must also repair records whose face-side groupID is missing.
        let group = FaceGroup(id: UUID(), name: "Preserved name",
            representativeFaceID: faces[0].id, faceIDs: faces.map(\.id))
        let original = FolderFaceData(folderURL: folder, faces: faces, groups: [group],
            lastScanDate: Date(), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        for face in faces { try storage.saveThumbnail(Data([1]), for: face.id, folderURL: folder) }
        let check: @Sendable () -> Void = {
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(photo)
            }
        }
        let service = FaceDataFolderLoadService(loadFaceData: { url in
            check()
            if outcome == "cancelDuringRead" { withUnsafeCurrentTask { $0?.cancel() } }
            return storage.loadFaceData(for: url)
        }, loadThumbnail: { id, url in
            check()
            return storage.loadThumbnail(for: id, folderURL: url)
        }, saveFaceData: { data in
            check()
            if outcome == "saveFailure" { throw CocoaError(.fileWriteNoPermission) }
            try storage.saveFaceData(data)
            if outcome == "cancelAfterCommit" { withUnsafeCurrentTask { $0?.cancel() } }
        }, deleteThumbnail: { id, url in
            check()
            if outcome == "cleanupFailure" { throw CocoaError(.fileWriteNoPermission) }
            try storage.deleteThumbnail(for: id, folderURL: url)
        })
        let result = try await Task {
            try await service.deletePhotoFacesWithFolderReservation(folderURL: folder, imageURLs: [photo])
        }.value
        let saved = try #require(storage.loadFaceData(for: folder))
        if outcome == "cancelDuringRead" {
            guard case .cancelled = result.load else { Issue.record("Expected cancellation"); return }
            #expect(result.persistence == nil)
            #expect(saved.faces.count == 2)
        } else if outcome == "saveFailure" {
            #expect(result.persistence?.failureMessage != nil)
            #expect(saved.faces.count == 2)
            guard case .complete(let evidence) = result.load else { Issue.record("Missing original"); return }
            #expect(evidence.faceData?.faces.count == 2)
        } else {
            #expect(saved.faces.map(\.id) == [faces[1].id])
            #expect(saved.groups.first?.faceIDs == [faces[1].id])
            #expect(saved.groups.first?.representativeFaceID == faces[1].id)
            #expect(saved.groups.first?.name == "Preserved name")
            guard case .committed(let commit) = result.persistence,
                  case .complete(let evidence) = result.load else { Issue.record("Missing commit"); return }
            #expect(commit.cancellationRequestedAfterCommit == (outcome == "cancelAfterCommit"))
            #expect(commit.thumbnailFailures.isEmpty == (outcome != "cleanupFailure"))
            #expect(evidence.faceData?.faces.map(\.id) == [faces[1].id])
            #expect(evidence.thumbnailData[faces[0].id] == nil)
        }
        #expect(storage.loadThumbnail(for: faces[1].id, folderURL: folder) == Data([1]))
        #expect((storage.loadThumbnail(for: faces[0].id, folderURL: folder) == nil) == (outcome == "success"))
        let released = try MCPProcessReservation.acquireFolder(folder)
        released.release()
    }

    @Test("Photo deletion write failure preserves visible faces and reports the failure", arguments: ["lazyPhoto", "loadedPhoto", "faceID"])
    func lazyFaceDeletionWriteFailurePresentation(mode: String) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let photo = folder.appendingPathComponent("photo.jpg")
        let face = DetectedFace(id: UUID(), imageURL: photo, faceRect: .zero,
            featurePrintData: Data([1]), detectedAt: Date())
        let document = FolderFaceData(folderURL: folder, faces: [face], groups: [],
            lastScanDate: Date(), scanComplete: true)
        let failure = CocoaError(.fileWriteNoPermission)
        let service = FaceDataFolderLoadService(loadFaceData: { _ in document },
            loadThumbnail: { _, _ in Data([1]) },
            saveFaceData: { _ in throw failure },
            deleteThumbnail: { _, _ in Issue.record("A failed save must preserve thumbnails") })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        if mode != "lazyPhoto" {
            viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
            await viewModel.waitForCurrentFaceDataLoad()
        }
        if mode == "faceID" { viewModel.deleteFaces([face.id]) }
        else { viewModel.deleteFaces(forImageURLs: [photo]) }
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(viewModel.faceData?.faces.map(\.id) == [face.id])
        #expect(viewModel.scanComplete)
        #expect(viewModel.errorMessage == "Failed to delete face data: \(failure.localizedDescription)")
    }

    @Test("Lazy deletion rebases a moved folder's document and never writes outside the reserved folder")
    func lazyFaceDeletionWrongOwner() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = folder.appendingPathComponent("Other")
        let photo = folder.appendingPathComponent("photo.jpg")
        let face = DetectedFace(id: UUID(), imageURL: other.appendingPathComponent("photo.jpg"), faceRect: .zero,
            featurePrintData: Data([1]), detectedAt: Date())
        // The document still names the folder it was moved or copied from.
        let document = FolderFaceData(folderURL: other, faces: [face], groups: [],
            lastScanDate: Date(), scanComplete: true)
        let saved = FaceDataSavedFolders()
        let service = FaceDataFolderLoadService(loadFaceData: { _ in document },
            saveFaceData: { saved.record($0) }, deleteThumbnail: { _, _ in })
        let result = try await service.deletePhotoFacesWithFolderReservation(folderURL: folder, imageURLs: [photo])
        guard case .complete(let evidence) = result.load else { Issue.record("Deletion must complete"); return }
        #expect(evidence.faceData?.faces.isEmpty == true)
        #expect(evidence.faceData?.folderURL.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(!saved.folders.isEmpty)
        #expect(saved.folders.allSatisfy { $0.standardizedFileURL.path == folder.standardizedFileURL.path })
        let released = try MCPProcessReservation.acquireFolder(folder)
        released.release()
    }

    @Test("Superseded lazy deletion cannot recover data or publish a busy error")
    func lazyFaceDeletionSuperseded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nextFolder = folder.appendingPathComponent("Next")
        let service = FaceDataFolderLoadService(loadFaceData: { url in
            #expect(url == nextFolder)
            return nil
        })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        let lease = try MCPProcessReservation.acquireFolder(folder)
        defer { lease.release() }
        viewModel.deleteFaces(forImageURLs: [folder.appendingPathComponent("photo.jpg")])
        viewModel.loadFaceData(for: nextFolder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(viewModel.faceData == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Failed expiration cleanup retains results and reports the storage error")
    func faceExpirationFailurePresentation() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(timeIntervalSince1970: 100), scanComplete: true)
        let failure = CocoaError(.fileWriteNoPermission)
        let service = FaceDataFolderLoadService(loadFaceData: { _ in document },
            deleteFaceData: { _ in throw failure })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        viewModel.loadFaceData(for: folder, cleanupPolicy: .sevenDays)
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(viewModel.faceData?.lastScanDate == document.lastScanDate)
        #expect(viewModel.scanComplete)
        #expect(viewModel.errorMessage == "Failed to remove expired face data: \(failure.localizedDescription)")
    }

    @Test("Guarded interactive saves preserve changed, removed, corrupt and foreign documents",
          arguments: ["changed", "removed", "corrupt", "foreign"])
    func staleInteractiveSaveRefused(change: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceStale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = FaceDataStorageService()
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(), scanComplete: true)
        try storage.saveFaceData(original)
        let documentURL = folder.appendingPathComponent(".face_data/face_data.json")
        let thumbnailID = UUID()
        try storage.saveThumbnail(Data([1, 2]), for: thumbnailID, folderURL: folder)
        switch change {
        case "changed":
            var latest = original
            latest.scanComplete = false
            try storage.saveFaceData(latest)
        case "removed": try FileManager.default.removeItem(at: documentURL)
        case "corrupt": try Data("invalid".utf8).write(to: documentURL)
        default:
            var latest = original
            latest.folderURL = folder.appendingPathComponent("foreign")
            try JSONEncoder().encode(latest).write(to: documentURL)
        }
        let before = try? Data(contentsOf: documentURL)
        let service = FaceDataFolderLoadService(loadFaceData: { url in
            #expect(throws: MCPProcessReservationError.busy) {
                _ = try MCPProcessReservation.acquirePhoto(url.appendingPathComponent("photo.jpg"))
            }
            return storage.loadFaceData(for: url)
        })
        let result = await service.persistWithFolderReservation(original,
            deletingThumbnailIDs: [thumbnailID], expectedSnapshot: original)
        #expect(result.failureMessage?.contains("Reload the folder") == true)
        #expect((try? Data(contentsOf: documentURL)) == before)
        #expect(storage.loadThumbnail(for: thumbnailID, folderURL: folder) == Data([1, 2]))
        let lease = try MCPProcessReservation.acquireFolder(folder)
        lease.release()
    }

    @Test("Each face editor retains its own baseline and reload allows ordered edits")
    func independentInteractiveBaselines() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaceEditors-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = FaceGroup(id: UUID(), name: "Original", representativeFaceID: UUID(),
            faceIDs: [], userCreated: true, manualNumber: nil)
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [group],
            lastScanDate: Date(), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        let service = FaceDataFolderLoadService()
        let first = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        let second = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        first.loadFaceData(for: folder, cleanupPolicy: .never)
        await first.waitForCurrentFaceDataLoad()
        var latest = original
        latest.groups[0].name = "External"
        try storage.saveFaceData(latest)
        second.loadFaceData(for: folder, cleanupPolicy: .never)
        await second.waitForCurrentFaceDataLoad()
        first.nameGroup(group.id, name: "Stale")
        await first.waitForCurrentFaceDataPersistence()
        #expect(first.errorMessage?.contains("Reload the folder") == true)
        #expect(storage.loadFaceData(for: folder)?.groups[0].name == "External")
        first.loadFaceData(for: folder, cleanupPolicy: .never)
        await first.waitForCurrentFaceDataLoad()
        first.nameGroup(group.id, name: "Reapplied")
        first.setManualNumber(42, forGroup: group.id)
        await first.waitForCurrentFaceDataPersistence()
        #expect(storage.loadFaceData(for: folder)?.groups[0].name == "Reapplied")
        #expect(storage.loadFaceData(for: folder)?.groups[0].manualNumber == 42)
    }

    @Test("Interactive group edits retain their baseline after busy admission or failed saves",
          arguments: [false, true])
    func interactiveFaceEditRetry(saveFailure: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceEditRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = FaceGroup(id: UUID(), name: "Original", representativeFaceID: UUID(),
            faceIDs: [], userCreated: true, manualNumber: nil)
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [group],
            lastScanDate: Date(), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        let service = FaceDataFolderLoadService(saveFaceData: { data in
            if saveFailure, data.groups.first?.name == "Edited" { throw CocoaError(.fileWriteUnknown) }
            try storage.saveFaceData(data)
        })
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), folderLoadService: service)
        viewModel.faceData = original
        let lease = try MCPProcessReservation.acquirePhoto(folder.appendingPathComponent("photo.jpg"))
        defer { lease.release() }
        if saveFailure { lease.release() }
        viewModel.nameGroup(group.id, name: "Edited")
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(storage.loadFaceData(for: folder)?.groups.first?.name == "Original")
        let expectedError = saveFailure ? CocoaError(.fileWriteUnknown).localizedDescription
            : MCPProcessReservationError.busy.localizedDescription
        #expect(viewModel.errorMessage?.contains(expectedError) == true)
        lease.release()
        viewModel.nameGroup(group.id, name: "Retried")
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(storage.loadFaceData(for: folder)?.groups.first?.name == "Retried")
    }

    @Test("Busy interactive face deletion preserves visible and durable results, then permits retry")
    func interactiveFaceDeletionRetry() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceDeleteRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [],
            lastScanDate: Date(timeIntervalSince1970: 100), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        let lease = try MCPProcessReservation.acquireFolder(folder)
        defer { lease.release() }
        viewModel.deleteFaceData(for: folder)
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(viewModel.faceData?.lastScanDate == original.lastScanDate)
        #expect(viewModel.scanComplete)
        #expect(storage.faceDataExists(for: folder))
        #expect(viewModel.errorMessage?.contains(MCPProcessReservationError.busy.localizedDescription) == true)
        lease.release()
        viewModel.deleteFaceData(for: folder)
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(viewModel.faceData == nil)
        #expect(!viewModel.scanComplete)
        #expect(!storage.faceDataExists(for: folder))
    }

    @Test("Face deletion completion does not clear a newly displayed folder")
    func interactiveFaceDeletionNavigation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceDeleteNavigation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deletedFolder = root.appendingPathComponent("Deleted")
        let displayedFolder = root.appendingPathComponent("Displayed")
        let storage = FaceDataStorageService()
        for folder in [deletedFolder, displayedFolder] {
            try storage.saveFaceData(FolderFaceData(folderURL: folder, faces: [], groups: [],
                lastScanDate: Date(), scanComplete: true))
        }
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        viewModel.loadFaceData(for: deletedFolder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        viewModel.deleteFaceData(for: deletedFolder)
        viewModel.loadFaceData(for: displayedFolder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataPersistence()
        await viewModel.waitForCurrentFaceDataLoad()
        #expect(!storage.faceDataExists(for: deletedFolder))
        #expect(storage.faceDataExists(for: displayedFolder))
        #expect(viewModel.faceData?.folderURL == displayedFolder)
        #expect(viewModel.scanComplete)
    }

    @Test("rename quiescence cancels the exact target scan and awaits its final persistence")
    func renameQuiescenceAwaitsFacePersistence() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanRenameBarrier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURLs = try (0..<24).map { index in
            let url = folder.appendingPathComponent("invalid-\(index).jpg")
            try Data("not an image \(index)".utf8).write(to: url)
            return url
        }
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .available
        )
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folder)

        #expect(viewModel.isScanning(folderURL: folder))
        try await viewModel.quiesceScanForRename(in: folder)

        #expect(!viewModel.isScanning)
        #expect(!viewModel.isCancellingScan)
        let durableData = try #require(FaceDataStorageService().loadFaceData(for: folder))
        #expect(durableData.folderURL.path == folder.path)
        #expect(!durableData.scanComplete)

        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folder)
        #expect(!viewModel.isScanning)
        #expect(viewModel.errorMessage?.contains("paused") == true)

        viewModel.endRenameQuiescence(in: folder)
        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folder)
        #expect(viewModel.isScanning(folderURL: folder))
        viewModel.cancelScan()
        await viewModel.waitForCurrentScan()
    }
}

private func dataRemovingKey(_ key: String, from data: Data) -> Data {
    var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    object[key] = nil
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private actor FaceThumbnailCancellationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseDetection() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}


private nonisolated final class FaceDataSavedFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var folders: [URL] { lock.withLock { stored } }
    func record(_ data: FolderFaceData) { lock.withLock { stored.append(data.folderURL) } }
}
