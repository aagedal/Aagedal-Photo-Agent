import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("RejectMoveService")
struct RejectMoveServiceTests {
    @Test("Name collisions keep image and sidecars associated")
    func collisionRenamesWholeBundle() throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceImage = root.appendingPathComponent("photo.cr3")
        let sourceXMP = root.appendingPathComponent("photo.xmp")
        try Data("new image".utf8).write(to: sourceImage)
        try Data("new xmp".utf8).write(to: sourceXMP)

        let sidecarService = MetadataSidecarService()
        let sidecar = MetadataSidecar(
            sourceFile: sourceImage.lastPathComponent,
            pendingChanges: true,
            metadata: IPTCMetadata(title: "Incoming title")
        )
        try sidecarService.saveSidecar(sidecar, for: sourceImage, in: root)

        let rejected = root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try Data("existing image".utf8).write(to: rejected.appendingPathComponent("photo.cr3"))
        try Data("existing xmp".utf8).write(to: rejected.appendingPathComponent("photo.xmp"))

        let result = RejectMoveService.moveRejected(urls: [sourceImage], in: root)

        let movedImage = rejected.appendingPathComponent("photo-1.cr3")
        let movedXMP = rejected.appendingPathComponent("photo-1.xmp")
        let movedJSON = rejected
            .appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
            .appendingPathComponent("photo-1.cr3.meta.json")
        #expect(result.failedFiles.isEmpty)
        #expect(result.movedFiles == [movedImage])
        #expect(FileManager.default.fileExists(atPath: movedImage.path))
        #expect(try Data(contentsOf: movedXMP) == Data("new xmp".utf8))
        #expect(FileManager.default.fileExists(atPath: movedJSON.path))

        let loaded = try #require(sidecarService.loadSidecar(for: movedImage, in: rejected))
        #expect(loaded.sourceFile == "photo-1.cr3")
        #expect(loaded.metadata.title == "Incoming title")
        #expect(try Data(contentsOf: rejected.appendingPathComponent("photo.cr3")) == Data("existing image".utf8))
        #expect(try Data(contentsOf: rejected.appendingPathComponent("photo.xmp")) == Data("existing xmp".utf8))
    }

    @Test("Sidecar failure rolls image and XMP back")
    func sidecarFailureRollsBackBundle() throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceImage = root.appendingPathComponent("photo.cr3")
        let sourceXMP = root.appendingPathComponent("photo.xmp")
        try Data("image".utf8).write(to: sourceImage)
        try Data("xmp".utf8).write(to: sourceXMP)
        try MetadataSidecarService().saveSidecar(
            MetadataSidecar(sourceFile: "photo.cr3"),
            for: sourceImage,
            in: root
        )

        // A regular file at the metadata-directory path forces relocation to fail
        // after the image and XMP have moved, exercising transactional rollback.
        let rejected = root.appendingPathComponent(RejectMoveService.rejectedFolderName)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try Data("blocking file".utf8).write(
            to: rejected.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        )

        let result = RejectMoveService.moveRejected(urls: [sourceImage], in: root)

        #expect(result.movedFiles.isEmpty)
        #expect(result.failedFiles.count == 1)
        #expect(FileManager.default.fileExists(atPath: sourceImage.path))
        #expect(FileManager.default.fileExists(atPath: sourceXMP.path))
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathComponent("photo.cr3").path))
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathComponent("photo.xmp").path))
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reject-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
