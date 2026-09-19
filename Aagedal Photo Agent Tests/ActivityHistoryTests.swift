import Foundation
import CoreGraphics
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
        let lease = try folderReservation
            ? MCPProcessReservation.acquireFolder(folder)
            : MCPProcessReservation.acquirePhoto(photo)
        defer { lease.release() }
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .available)
        viewModel.loadFaceData(for: folder, cleanupPolicy: .never)
        await viewModel.waitForCurrentFaceDataLoad()
        viewModel.scanFolder(imageURLs: [photo], folderURL: folder, forceFullScan: true)
        await viewModel.waitForCurrentScan()

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

    @Test("Face scan holds admission through final persistence and releases on every exit",
          arguments: ["complete", "cancelled", "failed", "unchanged"])
    func scanReservationLifetime(outcome: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanLifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: photo)
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
        await viewModel.waitForCurrentScan()

        #expect(!viewModel.isScanning)
        if outcome == "unchanged" {
            #expect(persistenceObserved.read() == nil)
        } else {
            #expect(persistenceObserved.read() == Data([outcome == "cancelled" ? 0 : 1]))
        }
        if outcome == "failed" { #expect(viewModel.errorMessage?.contains("Failed to save") == true) }
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
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
        case .failed: #expect(outcome == "deleteFailure")
        case .cancelledBeforeCommit: #expect(outcome == "cancelBeforeCommit")
        }
        let next = try MCPProcessReservation.acquireFolder(folder)
        next.release()
    }

    @Test("Interactive group edits report busy admission without overwriting durable names")
    func interactiveFaceEditRetry() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceEditRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = FaceGroup(id: UUID(), name: "Original", representativeFaceID: UUID(),
            faceIDs: [], userCreated: true, manualNumber: nil)
        let original = FolderFaceData(folderURL: folder, faces: [], groups: [group],
            lastScanDate: Date(), scanComplete: true)
        let storage = FaceDataStorageService()
        try storage.saveFaceData(original)
        let viewModel = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine())
        viewModel.faceData = original
        let lease = try MCPProcessReservation.acquirePhoto(folder.appendingPathComponent("photo.jpg"))
        defer { lease.release() }
        viewModel.nameGroup(group.id, name: "Edited")
        await viewModel.waitForCurrentFaceDataPersistence()
        #expect(storage.loadFaceData(for: folder)?.groups.first?.name == "Original")
        #expect(viewModel.errorMessage?.contains(MCPProcessReservationError.busy.localizedDescription) == true)
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
