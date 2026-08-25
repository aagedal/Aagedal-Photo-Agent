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

    @Test("Known People disclosure and iCloud confirmation are versioned independently")
    func knownPeoplePrivacyAcknowledgements() throws {
        let suiteName = "KnownPeoplePrivacyLifecycleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!KnownPeoplePrivacyLifecycle.hasAcknowledgedDisclosure(in: defaults))
        #expect(!KnownPeoplePrivacyLifecycle.hasConfirmedICloudTransfer(in: defaults))
        #expect(KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: true,
            currentlyEnabled: false,
            defaults: defaults
        ))
        #expect(!KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: false,
            currentlyEnabled: true,
            defaults: defaults
        ))

        KnownPeoplePrivacyLifecycle.acknowledgeDisclosure(in: defaults)
        #expect(KnownPeoplePrivacyLifecycle.hasAcknowledgedDisclosure(in: defaults))
        #expect(KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: true,
            currentlyEnabled: false,
            defaults: defaults
        ))

        KnownPeoplePrivacyLifecycle.recordICloudTransferConfirmation(in: defaults)
        #expect(KnownPeoplePrivacyLifecycle.hasConfirmedICloudTransfer(in: defaults))
        #expect(!KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: true,
            currentlyEnabled: false,
            defaults: defaults
        ))
    }

    @Test("Known People Data Management summary counts nested storage and reports its destination")
    func knownPeopleDataSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownPeopleDataSummaryTests-\(UUID().uuidString)", isDirectory: true)
        let people = root.appendingPathComponent("people", isDirectory: true)
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 7).write(to: people.appendingPathComponent("person.json"))
        try Data(repeating: 2, count: 11).write(to: thumbnails.appendingPathComponent("sample.jpg"))

        let local = KnownPeopleDataSummary.make(
            peopleCount: 3,
            sampleCount: 8,
            storageURL: root,
            syncEnabled: false
        )
        #expect(local.peopleCount == 3)
        #expect(local.sampleCount == 8)
        #expect(local.storedBytes == 18)
        #expect(local.storageDestination.contains("This Mac"))

        let cloud = KnownPeopleDataSummary.make(
            peopleCount: 3,
            sampleCount: 8,
            storageURL: root,
            syncEnabled: true
        )
        #expect(cloud.storedBytes == 18)
        #expect(cloud.storageDestination.contains("iCloud Drive"))
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
