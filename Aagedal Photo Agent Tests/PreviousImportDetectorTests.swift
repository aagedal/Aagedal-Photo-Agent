import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("PreviousImportDetector")
struct PreviousImportDetectorTests {
    @Test("Date folder matching accepts titles but not longer dates")
    func dateFolderMatching() {
        #expect(PreviousImportDetector.folderName("2026-07-21", matchesDate: "2026-07-21"))
        #expect(PreviousImportDetector.folderName("2026-07-21 – Cup Final", matchesDate: "2026-07-21"))
        #expect(PreviousImportDetector.folderName("2026-07-21 Morning", matchesDate: "2026-07-21"))
        #expect(!PreviousImportDetector.folderName("2026-07-210", matchesDate: "2026-07-21"))
        #expect(!PreviousImportDetector.folderName("2026-07-20 – Training", matchesDate: "2026-07-21"))
        #expect(!PreviousImportDetector.folderName("Unknown Date", matchesDate: "Unknown Date"))
    }

    @Test("Standard import folder titles can be reused exactly")
    func standardImportFolderTitleExtraction() {
        #expect(
            PreviousImportDetector.importTitle(
                from: "2026-07-21 – Cup Final",
                matchingDate: "2026-07-21"
            ) == "Cup Final"
        )
        #expect(
            PreviousImportDetector.importTitle(
                from: "2026-07-21 Morning",
                matchingDate: "2026-07-21"
            ) == nil
        )
        #expect(
            PreviousImportDetector.importTitle(
                from: "2026-07-20 – Training",
                matchingDate: "2026-07-21"
            ) == nil
        )
    }

    @Test("Duplicate detection requires date filename size and quick checksum matches")
    func duplicateDetectionRequiresEveryMatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previous-import-detector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceRoot = root.appendingPathComponent("card/DCIM", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("photos", isDirectory: true)
        let matchingFolder = destinationRoot
            .appendingPathComponent("2026/07/2026-07-21 – Morning/RAW", isDirectory: true)
        let wrongDateFolder = destinationRoot
            .appendingPathComponent("2026/07/2026-07-20 – Evening/RAW", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: matchingFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrongDateFolder, withIntermediateDirectories: true)

        let duplicateSource = sourceRoot.appendingPathComponent("img_0001.cr3")
        let changedSource = sourceRoot.appendingPathComponent("IMG_0002.CR3")
        let wrongDateSource = sourceRoot.appendingPathComponent("IMG_0003.CR3")
        let content = Data(repeating: 0x2A, count: 300_000)
        var changedContent = content
        changedContent[150_000] = 0x7F

        try content.write(to: duplicateSource)
        try content.write(to: changedSource)
        try content.write(to: wrongDateSource)
        try content.write(to: matchingFolder.appendingPathComponent("IMG_0001.CR3"))
        try changedContent.write(to: matchingFolder.appendingPathComponent("IMG_0002.CR3"))
        try content.write(to: wrongDateFolder.appendingPathComponent("IMG_0003.CR3"))

        let duplicates = try PreviousImportDetector.duplicateSources(
            among: [
                .init(source: duplicateSource, dateFolderName: "2026-07-21"),
                .init(source: changedSource, dateFolderName: "2026-07-21"),
                .init(source: wrongDateSource, dateFolderName: "2026-07-21"),
            ],
            destinationBaseURL: destinationRoot
        )

        #expect(duplicates == Set([duplicateSource]))
    }

    @Test("Duplicate detection supports flat date folders and nested JPEG folders")
    func duplicateDetectionSupportsFlatFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previous-import-flat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFolder = root.appendingPathComponent("card", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("photos", isDirectory: true)
        let previousJPEGFolder = destinationRoot
            .appendingPathComponent("2026-07-21 – First import/JPEG", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousJPEGFolder, withIntermediateDirectories: true)

        let source = sourceFolder.appendingPathComponent("DSC_0042.JPG")
        let content = Data((0..<8_192).map { UInt8($0 % 251) })
        try content.write(to: source)
        try content.write(to: previousJPEGFolder.appendingPathComponent(source.lastPathComponent))

        let duplicates = try PreviousImportDetector.duplicateSources(
            among: [.init(source: source, dateFolderName: "2026-07-21")],
            destinationBaseURL: destinationRoot
        )

        #expect(duplicates.contains(source))
    }
}
