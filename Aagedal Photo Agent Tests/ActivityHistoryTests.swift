import Foundation
import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Activity History")
@MainActor
struct ActivityHistoryTests {
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
            writeEngine: SwiftExifWriteEngine()
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
}
