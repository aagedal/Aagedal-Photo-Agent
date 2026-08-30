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
    func knownPeopleDataSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownPeopleDataSummaryTests-\(UUID().uuidString)", isDirectory: true)
        let people = root.appendingPathComponent("people", isDirectory: true)
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 7).write(to: people.appendingPathComponent("person.json"))
        try Data(repeating: 2, count: 11).write(to: thumbnails.appendingPathComponent("sample.jpg"))

        let localEvidence = await KnownPeopleDataSummaryService().summarize(
            peopleCount: 3,
            sampleCount: 8,
            storageURL: root,
            syncEnabled: false
        )
        let local = try #require(completeSummary(from: localEvidence))
        #expect(local.peopleCount == 3)
        #expect(local.sampleCount == 8)
        #expect(local.storedBytes == 18)
        #expect(local.storageDestination.contains("This Mac"))

        let cloudEvidence = await KnownPeopleDataSummaryService().summarize(
            peopleCount: 3,
            sampleCount: 8,
            storageURL: root,
            syncEnabled: true
        )
        let cloud = try #require(completeSummary(from: cloudEvidence))
        #expect(cloud.storedBytes == 18)
        #expect(cloud.storageDestination.contains("iCloud Drive"))
    }

    @Test("Known People storage measurement executes away from the main thread")
    @MainActor
    func knownPeopleDataSummaryRunsOffMainThread() async throws {
        let probe = KnownPeopleDataSummaryThreadProbe()
        let service = KnownPeopleDataSummaryService(measureDirectory: probe.measure)

        let evidence = await service.summarize(
            peopleCount: 1,
            sampleCount: 2,
            storageURL: URL(fileURLWithPath: "/simulated-known-people"),
            syncEnabled: false
        )

        let summary = try #require(completeSummary(from: evidence))
        #expect(summary.storedBytes == 23)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Known People storage scans serialize and a cancelled queued request performs no read")
    @MainActor
    func knownPeopleDataSummarySerializesAndCancels() async throws {
        let probe = BlockingKnownPeopleDataSummaryProbe()
        defer { probe.release() }
        let service = KnownPeopleDataSummaryService(measureDirectory: probe.measure)
        let firstURL = URL(fileURLWithPath: "/simulated-known-people/first")
        let cancelledURL = URL(fileURLWithPath: "/simulated-known-people/cancelled")

        let first = Task {
            await service.summarize(
                peopleCount: 1,
                sampleCount: 1,
                storageURL: firstURL,
                syncEnabled: false
            )
        }
        let didBlock = await probe.waitUntilBlocked()
        #expect(didBlock, "The simulated storage measurement did not start within 30 seconds")
        guard didBlock else { return }

        let queued = Task {
            await service.summarize(
                peopleCount: 2,
                sampleCount: 2,
                storageURL: cancelledURL,
                syncEnabled: false
            )
        }
        first.cancel()
        queued.cancel()
        probe.release()

        let firstEvidence = await first.value
        let queuedEvidence = await queued.value
        #expect(firstEvidence == .cancelled)
        #expect(queuedEvidence == .cancelled)
        #expect(probe.urls == [firstURL])
    }

    @Test("Known People settings publishes only the latest complete async summary")
    func knownPeopleDataSummarySourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let summarySource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Models/KnownPeoplePrivacyLifecycle.swift"
            ),
            encoding: .utf8
        )

        #expect(settingsSource.contains("knownPeopleDataSummaryTask?.cancel()"))
        #expect(settingsSource.contains("await KnownPeopleDataSummaryService.shared.summarize("))
        #expect(settingsSource.contains("knownPeopleDataSummaryRequestID == requestID"))
        #expect(settingsSource.contains("if case .complete(let summary) = evidence"))
        #expect(!summarySource.contains("FileManager.default.enumerator"))
        #expect(!summarySource.contains("static func make("))
    }

    private func completeSummary(
        from evidence: KnownPeopleDataSummaryEvidence
    ) -> KnownPeopleDataSummary? {
        guard case .complete(let summary) = evidence else { return nil }
        return summary
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

nonisolated private final class KnownPeopleDataSummaryThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    func measure(_ url: URL) -> KnownPeopleDataSummaryService.DirectorySizeEvidence {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return .complete(23)
    }
}

nonisolated private final class BlockingKnownPeopleDataSummaryProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false
    private var measuredURLs: [URL] = []

    var urls: [URL] {
        condition.withLock { measuredURLs }
    }

    func measure(_ url: URL) -> KnownPeopleDataSummaryService.DirectorySizeEvidence {
        condition.lock()
        measuredURLs.append(url)
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return .complete(31)
    }

    func waitUntilBlocked(timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                let deadline = Date().addingTimeInterval(timeout)
                condition.lock()
                defer { condition.unlock() }
                while !isBlocked {
                    guard condition.wait(until: deadline) else {
                        continuation.resume(returning: false)
                        return
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}
