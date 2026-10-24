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

    @Test("The import ledger recognizes a copy that changed, was renamed, or sits in another day's folder")
    func ledgerRecognizesChangedRenamedAndOtherDayCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previous-import-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        let olderImport = photos.appendingPathComponent("2020-01-01 – Earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: olderImport, withIntermediateDirectories: true)

        let captioned = card.appendingPathComponent("DSC_0001.JPG")
        let renamed = card.appendingPathComponent("DSC_0002.JPG")
        let removed = card.appendingPathComponent("DSC_0003.JPG")
        let neverImported = card.appendingPathComponent("DSC_0004.JPG")
        for (index, url) in [captioned, renamed, removed, neverImported].enumerated() {
            try Data((0..<9_000).map { UInt8(($0 + index * 7) % 251) }).write(to: url)
        }

        // Copies as an import leaves them: one got an embedded caption (bytes changed), one was
        // renamed for a conflict, and one has since been deleted from the library.
        let captionedCopy = olderImport.appendingPathComponent("DSC_0001.JPG")
        let renamedCopy = olderImport.appendingPathComponent("DSC_0002-1.JPG")
        let removedCopy = olderImport.appendingPathComponent("DSC_0003.JPG")
        try FileManager.default.copyItem(at: captioned, to: captionedCopy)
        try FileManager.default.copyItem(at: renamed, to: renamedCopy)
        try FileManager.default.copyItem(at: removed, to: removedCopy)
        let entries = try [
            (captioned, captionedCopy), (renamed, renamedCopy), (removed, removedCopy),
        ].map { try ImportLedger.entry(source: $0.0, destination: $0.1, root: photos, captureDate: nil) }
        try ImportLedger.append(entries, root: photos)
        try Data("caption-embedded".utf8).write(to: captionedCopy)
        try FileManager.default.removeItem(at: removedCopy)

        // Today's flat import looks for today's date only; the ledger is date independent.
        let duplicates = try PreviousImportDetector.duplicateSources(
            among: [captioned, renamed, removed, neverImported].map {
                .init(source: $0, dateFolderName: "2026-10-24")
            },
            destinationBaseURL: photos
        )

        #expect(duplicates == Set([captioned, renamed]))
    }

    @Test("A torn ledger line is skipped and later appends stay readable")
    func ledgerSurvivesTornLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previous-import-ledger-torn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"v":1,"name":"torn"#.utf8).write(to: ImportLedger.url(forRoot: root))
        let entry = ImportLedger.Entry(
            name: "IMG_1.CR3", size: 10, captureDate: nil, quickHash: "ab",
            destination: "2026-10-24/IMG_1.CR3", importedAt: "2026-10-24T10:00:00Z"
        )
        try ImportLedger.append([entry], root: root)
        try ImportLedger.append([entry], root: root)

        #expect(ImportLedger.load(root: root) == [entry, entry])
    }

    @Test("Legacy scan recognizes renamed copies, and a matched RAW vouches for its JPEG partner")
    func legacyScanRenamedCopiesAndRawPartner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previous-import-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        let shoot = photos.appendingPathComponent("2026-07-21 – Cup", isDirectory: true)
        let rawFolder = shoot.appendingPathComponent("RAW", isDirectory: true)
        let jpegFolder = shoot.appendingPathComponent("JPEG", isDirectory: true)
        for folder in [card, rawFolder, jpegFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let raw = card.appendingPathComponent("IMG_0001.CR3")
        let jpeg = card.appendingPathComponent("IMG_0001.JPG")
        let loneRaw = card.appendingPathComponent("IMG_0002.CR3")
        let loneJPEG = card.appendingPathComponent("IMG_0002.JPG")
        try Data(repeating: 0x11, count: 4_000).write(to: raw)
        try Data(repeating: 0x22, count: 4_000).write(to: jpeg)
        try Data(repeating: 0x33, count: 4_000).write(to: loneRaw)
        try Data(repeating: 0x44, count: 4_000).write(to: loneJPEG)

        // Imported before the ledger existed, renamed for a conflict; the JPEG copy has since
        // had metadata embedded. IMG_0002's JPEG was never imported.
        try FileManager.default.copyItem(at: raw, to: rawFolder.appendingPathComponent("IMG_0001-1.CR3"))
        try Data("embedded".utf8).write(to: jpegFolder.appendingPathComponent("IMG_0001-1.JPG"))
        try FileManager.default.copyItem(at: loneRaw, to: rawFolder.appendingPathComponent("IMG_0002.CR3"))

        let duplicates = try PreviousImportDetector.duplicateSources(
            among: [raw, jpeg, loneRaw, loneJPEG].map { .init(source: $0, dateFolderName: "2026-07-21") },
            destinationBaseURL: photos
        )

        #expect(duplicates == Set([raw, jpeg, loneRaw]))
    }
}
