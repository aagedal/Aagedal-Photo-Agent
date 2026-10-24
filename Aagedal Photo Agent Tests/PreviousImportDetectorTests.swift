import Foundation
import ImageIO
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
            try writeIdentityJPEG(to: url, subSecond: "1\(index)")
        }

        // Copies as an import leaves them: one got an embedded caption (bytes changed, capture
        // identity kept), one was renamed for a conflict, one was deleted from the library.
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
        try writeIdentityJPEG(to: captionedCopy, subSecond: "10", caption: "Embedded caption")
        #expect(try Data(contentsOf: captionedCopy) != Data(contentsOf: captioned))
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

    @Test("A ledger path now holding another file, or an unfinished copy, is not skipped")
    func ledgerRejectsReplacedPathsAndUnfinishedCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previous-import-ledger-replaced-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cardA = root.appendingPathComponent("card-a", isDirectory: true)
        let cardB = root.appendingPathComponent("card-b", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        let shoot = photos.appendingPathComponent("2026-10-24 – Cup", isDirectory: true)
        for folder in [cardA, cardB, shoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func importFile(_ source: URL, as name: String, finished: Bool = true) throws {
            let copy = shoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: source, to: copy)
            try ImportLedger.append(
                [try ImportLedger.entry(source: source, destination: copy, root: photos, captureDate: nil, finished: finished)],
                root: photos
            )
        }

        // 1. Overwrite: card B's same-named photo replaced card A's at the same path.
        let overwrittenA = cardA.appendingPathComponent("DSC_0001.JPG")
        let overwritingB = cardB.appendingPathComponent("DSC_0001.JPG")
        try writeIdentityJPEG(to: overwrittenA, subSecond: "11", serial: "A-BODY")
        try writeIdentityJPEG(to: overwritingB, subSecond: "22", serial: "B-BODY")
        try importFile(overwrittenA, as: "DSC_0001.JPG")
        try importFile(overwritingB, as: "DSC_0001.JPG")

        // 2. Deleted, then the name reused by another import.
        let deletedA = cardA.appendingPathComponent("DSC_0002.ARW")
        let reusedB = cardB.appendingPathComponent("DSC_0002.ARW")
        try Data(repeating: 0xA1, count: 5_000).write(to: deletedA)
        try Data(repeating: 0xB2, count: 5_000).write(to: reusedB)
        try importFile(deletedA, as: "DSC_0002.ARW")
        try FileManager.default.removeItem(at: shoot.appendingPathComponent("DSC_0002.ARW"))
        try importFile(reusedB, as: "DSC_0002.ARW")

        // 3. A RAW swapped in place outside the importer: no ledger entry, different bytes.
        let swappedA = cardA.appendingPathComponent("DSC_0003.ARW")
        try Data(repeating: 0xC3, count: 5_000).write(to: swappedA)
        try importFile(swappedA, as: "DSC_0003.ARW")
        try Data(repeating: 0xD4, count: 5_000).write(to: shoot.appendingPathComponent("DSC_0003.ARW"))

        // 4. Copied, but the import stopped before its sidecar and template were finished.
        let unfinishedA = cardA.appendingPathComponent("DSC_0004.ARW")
        try Data(repeating: 0xE5, count: 5_000).write(to: unfinishedA)
        try importFile(unfinishedA, as: "DSC_0004.ARW", finished: false)

        let duplicates = try PreviousImportDetector.duplicateSources(
            among: [overwrittenA, overwritingB, deletedA, reusedB, swappedA, unfinishedA].map {
                .init(source: $0, dateFolderName: "2026-10-24")
            },
            destinationBaseURL: photos
        )

        #expect(duplicates == Set([overwritingB, reusedB]))
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

    @Test("Legacy scan recognizes renamed copies, and a matched RAW vouches only for its own JPEG")
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
        let exportedRaw = card.appendingPathComponent("IMG_0002.CR3")
        let exportedJPEG = card.appendingPathComponent("IMG_0002.JPG")
        let loneRaw = card.appendingPathComponent("IMG_0003.CR3")
        let loneJPEG = card.appendingPathComponent("IMG_0003.JPG")
        try Data(repeating: 0x11, count: 4_000).write(to: raw)
        try Data(repeating: 0x33, count: 4_000).write(to: exportedRaw)
        try Data(repeating: 0x55, count: 4_000).write(to: loneRaw)
        try writeIdentityJPEG(to: jpeg, subSecond: "01")
        try writeIdentityJPEG(to: exportedJPEG, subSecond: "02")
        try writeIdentityJPEG(to: loneJPEG, subSecond: "03")

        // Imported before the ledger existed, renamed for a conflict; the JPEG copy has since
        // had metadata embedded (same capture identity).
        try FileManager.default.copyItem(at: raw, to: rawFolder.appendingPathComponent("IMG_0001-1.CR3"))
        try writeIdentityJPEG(to: jpegFolder.appendingPathComponent("IMG_0001-1.JPG"), subSecond: "01", caption: "Embedded")
        // IMG_0002's JPEG slot holds an export saved under the original name (resized, other
        // software): the camera JPEG was never imported.
        try FileManager.default.copyItem(at: exportedRaw, to: rawFolder.appendingPathComponent("IMG_0002.CR3"))
        try writeIdentityJPEG(
            to: jpegFolder.appendingPathComponent("IMG_0002.JPG"),
            subSecond: "02", width: 8, software: "Adobe Lightroom"
        )
        // IMG_0003's JPEG was never imported.
        try FileManager.default.copyItem(at: loneRaw, to: rawFolder.appendingPathComponent("IMG_0003.CR3"))

        let duplicates = try PreviousImportDetector.duplicateSources(
            among: [raw, jpeg, exportedRaw, exportedJPEG, loneRaw, loneJPEG].map {
                .init(source: $0, dateFolderName: "2026-07-21")
            },
            destinationBaseURL: photos
        )

        #expect(duplicates == Set([raw, jpeg, exportedRaw, loneRaw]))
    }

    @Test("EXIF capture identity separates edits, exports and other bodies")
    func imageIdentityRule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-image-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }

        try writeIdentityJPEG(to: file("camera.jpg"), subSecond: "42")
        try writeIdentityJPEG(to: file("captioned.jpg"), subSecond: "42", caption: "Caption")
        try writeIdentityJPEG(to: file("resized.jpg"), subSecond: "42", width: 8)
        try writeIdentityJPEG(to: file("otherbody.jpg"), subSecond: "42", serial: "OTHER")
        try writeIdentityJPEG(to: file("othershot.jpg"), subSecond: "43")

        #expect(ImportImageIdentity.sameExposure(file("camera.jpg"), file("captioned.jpg")))
        for different in ["resized.jpg", "otherbody.jpg", "othershot.jpg"] {
            #expect(!ImportImageIdentity.sameExposure(file("camera.jpg"), file(different)), "\(different)")
        }

        // Software must match exactly (an editor stamps its own); fields one side lacks only
        // pass when a fine discriminator is present on both.
        let camera = ImportImageIdentity(
            captured: "2026:10:24 12:00:00", subSecond: "42", serial: "1234567", uniqueID: nil,
            pixelWidth: 6000, pixelHeight: 4000, software: "Ver.1.00"
        )
        func variant(subSecond: String? = "42", serial: String? = "1234567", software: String? = "Ver.1.00") -> ImportImageIdentity {
            ImportImageIdentity(
                captured: camera.captured, subSecond: subSecond, serial: serial, uniqueID: nil,
                pixelWidth: 6000, pixelHeight: 4000, software: software
            )
        }
        #expect(camera.isSameExposure(as: variant()))
        #expect(!camera.isSameExposure(as: variant(software: "Adobe Lightroom Classic")))
        #expect(!camera.isSameExposure(as: variant(software: nil)))
        #expect(!variant(subSecond: nil, serial: nil).isSameExposure(as: variant(subSecond: nil, serial: nil)))
    }
}

/// Writes a small JPEG carrying EXIF capture identity (DateTimeOriginal, SubSecTimeOriginal,
/// body serial), optionally with a different width, Software tag or IPTC caption.
nonisolated func writeIdentityJPEG(
    to url: URL,
    captured: String = "2026:10:24 12:00:00",
    subSecond: String = "42",
    serial: String = "1234567",
    width: Int = 16,
    software: String? = nil,
    caption: String? = nil
) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: captured,
            kCGImagePropertyExifSubsecTimeOriginal: subSecond,
            kCGImagePropertyExifBodySerialNumber: serial,
        ] as [CFString: Any],
    ]
    if let software {
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFSoftware: software] as [CFString: Any]
    }
    if let caption {
        properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCaptionAbstract: caption] as [CFString: Any]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
