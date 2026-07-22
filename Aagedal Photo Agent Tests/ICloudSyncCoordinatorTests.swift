import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("iCloud sync coordinator")
struct ICloudSyncCoordinatorTests {
    @Test("master sync includes every user-facing category")
    func masterCategoryCoverage() {
        #expect(ICloudSyncCoordinator.masterCategories == [
            .preferences,
            .keywordLists,
            .templates,
            .knownPeople,
            .teams,
            .watermarks,
        ])
    }


    @Test("store migration preserves a newer destination and accepts a newer source")
    func migrationUsesNewestFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudMergeTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = source.appendingPathComponent("record.json")
        let destinationFile = destination.appendingPathComponent("record.json")
        try Data("stale-local".utf8).write(to: sourceFile)
        try Data("new-cloud".utf8).write(to: destinationFile)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: sourceFile.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: destinationFile.path)

        try CloudCoordinatedIO.mergeCopyPreservingNewer(from: source, to: destination)
        #expect(try Data(contentsOf: destinationFile) == Data("new-cloud".utf8))

        try Data("newest-local".utf8).write(to: sourceFile)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: sourceFile.path)
        try CloudCoordinatedIO.mergeCopyPreservingNewer(from: source, to: destination)
        #expect(try Data(contentsOf: destinationFile) == Data("newest-local".utf8))
    }
}
