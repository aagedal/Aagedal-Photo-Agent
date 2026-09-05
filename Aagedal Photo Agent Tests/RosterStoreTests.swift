import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("RosterStore", .serialized)
@MainActor
struct RosterStoreTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func teardown(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeTeam(name: String = "Test Team") -> Team {
        Team(name: name, primaryColor: TeamKitColor(r: 0.2, g: 0.4, b: 0.6))
    }

    @Test("delete installs a decodable marker, removes the record, and prevents resurrection")
    func durableDeletePreventsResurrection() async throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        let store = RosterStore(storageRoot: dir)
        await store.loadIfNeeded()
        let team = makeTeam()
        try await store.upsert(team)

        try await store.delete(id: team.id)

        let record = dir.appendingPathComponent("teams/\(team.id.uuidString).json")
        let marker = dir.appendingPathComponent("teams/\(team.id.uuidString).deleted")
        #expect(!FileManager.default.fileExists(atPath: record.path))
        let decoded = try JSONDecoder().decode(TeamTombstone.self, from: Data(contentsOf: marker))
        #expect(decoded.id == team.id)

        // Simulate a stale peer returning the old record. Reload must honor the marker.
        try JSONEncoder().encode(team).write(to: record, options: .atomic)
        await store.reloadAfterStorageChange()
        #expect(store.allTeams().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test("failed marker persistence keeps the original team usable")
    func failedMarkerPersistencePreservesTeam() async throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        let team = makeTeam(name: "Preserved")
        let failingDeletionIO = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: { try CloudCoordinatedIO.readData(at: $0) },
            removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
        )
        let store = RosterStore(storageRoot: dir, deletionIO: failingDeletionIO)
        await store.loadIfNeeded()
        try await store.upsert(team)
        let record = dir.appendingPathComponent("teams/\(team.id.uuidString).json")
        let marker = dir.appendingPathComponent("teams/\(team.id.uuidString).deleted")

        do {
            try await store.delete(id: team.id)
            Issue.record("Expected deletion to fail")
        } catch {
            #expect(error is DurableDeletionError)
        }

        #expect(store.team(byID: team.id)?.name == "Preserved")
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

@Suite("Roster library persistence service")
struct RosterLibraryPersistenceServiceTests {
    private let root = URL(fileURLWithPath: "/tmp/roster-library-service-tests", isDirectory: true)

    @Test("pre-cancelled load performs no filesystem access")
    func preCancelledLoadDoesNoWork() async {
        let probe = RosterLibraryFileAccessProbe()
        let service = RosterLibraryPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.load(from: root, requestID: requestID)
        }.value

        guard case .cancelledBeforeAccess(let resultID) = result else {
            Issue.record("Expected cancellation before access")
            return
        }
        #expect(resultID == requestID)
        #expect(probe.invocationCount == 0)
    }

    @Test("load returns a sorted immutable snapshot away from the main actor")
    func loadReturnsSortedSnapshot() async throws {
        let alpha = makeTeam(name: "Alpha")
        let zulu = makeTeam(name: "Zulu")
        let probe = RosterLibraryFileAccessProbe(teams: [zulu, alpha])
        let service = RosterLibraryPersistenceService(access: probe.fileAccess)

        let result = await service.load(from: root, requestID: UUID())

        guard case .loaded(let snapshot) = result else {
            Issue.record("Expected a complete snapshot")
            return
        }
        #expect(snapshot.teams.map(\.name) == ["Alpha", "Zulu"])
        #expect(snapshot.inspectedEntryCount == 2)
        #expect(!probe.ranOnMainThread)
    }

    @Test("cancellation after a record read reports the exact inspected prefix")
    func cancellationReportsPrefix() async {
        let probe = RosterLibraryFileAccessProbe(
            teams: [makeTeam(name: "One"), makeTeam(name: "Two")],
            cancelDuringFirstRead: true
        )
        let service = RosterLibraryPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = await Task {
            await service.load(from: root, requestID: requestID)
        }.value

        guard case .cancelledAfterPrefix(let resultID, let count, let cleanupURLs) = result else {
            Issue.record("Expected explicit partial-prefix cancellation")
            return
        }
        #expect(resultID == requestID)
        #expect(count == 1)
        #expect(cleanupURLs.isEmpty)
        #expect(probe.readInvocationCount == 1)
    }

    @Test("upsert reports a durable commit when cancellation arrives during write")
    func upsertReportsDurablePostCancellationCommit() async throws {
        let probe = RosterLibraryFileAccessProbe(cancelDuringWrite: true)
        let service = RosterLibraryPersistenceService(access: probe.fileAccess)
        let team = makeTeam(name: "Committed")

        let result = try await Task {
            try await service.upsert(team, in: root, requestID: UUID())
        }.value

        guard case .committed(let commit) = result else {
            Issue.record("Expected durable commit evidence")
            return
        }
        #expect(commit.team.id == team.id)
        #expect(commit.cancellationRequestedAfterCommit)
        #expect(probe.writtenURLs.last?.lastPathComponent == "\(team.id.uuidString).json")
    }

    @Test("store source keeps coordinated file operations inside the serialized service")
    func sourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/RosterStore.swift"
            ),
            encoding: .utf8
        )
        let ownerStart = try #require(source.range(of: "final class RosterStore"))
        let ownerSource = source[ownerStart.lowerBound...]

        #expect(source.contains("actor RosterLibraryPersistenceService"))
        #expect(source.contains("case cancelledAfterPrefix"))
        #expect(source.contains("cancellationRequestedAfterCommit"))
        #expect(ownerSource.contains("await persistence.load("))
        #expect(ownerSource.contains("try await persistence.upsert("))
        #expect(ownerSource.contains("try await persistence.delete("))
        #expect(!ownerSource.contains("CloudCoordinatedIO."))
        #expect(!ownerSource.contains("Data(contentsOf:"))
        #expect(!ownerSource.contains("NSFileVersion."))
    }

    private func makeTeam(name: String) -> Team {
        Team(name: name, primaryColor: TeamKitColor(r: 0.2, g: 0.4, b: 0.6))
    }
}

private nonisolated final class RosterLibraryFileAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let teamData: [String: Data]
    private let cancelDuringFirstRead: Bool
    private let cancelDuringWrite: Bool
    private var count = 0
    private var readCount = 0
    private var observedMainThread = false
    private var committedURLs: [URL] = []

    init(
        teams: [Team] = [],
        cancelDuringFirstRead: Bool = false,
        cancelDuringWrite: Bool = false
    ) {
        teamData = Dictionary(uniqueKeysWithValues: teams.map { team in
            ("\(team.id.uuidString).json", try! JSONEncoder().encode(team))
        })
        self.cancelDuringFirstRead = cancelDuringFirstRead
        self.cancelDuringWrite = cancelDuringWrite
    }

    var fileAccess: RosterLibraryFileAccess {
        RosterLibraryFileAccess(
            ensureDirectory: { [self] _ in recordInvocation() },
            contentsOfDirectory: { [self] directory in
                recordInvocation()
                return teamData.keys.sorted().map { directory.appendingPathComponent($0) }
            },
            readData: { [self] url in
                recordInvocation()
                let readNumber = lock.withLock { () -> Int in
                    readCount += 1
                    return readCount
                }
                if cancelDuringFirstRead, readNumber == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                guard let data = teamData[url.lastPathComponent] else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return data
            },
            writeData: { [self] _, url in
                recordInvocation()
                lock.withLock { committedURLs.append(url) }
                if cancelDuringWrite {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            removeItem: { [self] _ in recordInvocation() }
        )
    }

    private func recordInvocation() {
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }

    var invocationCount: Int { lock.withLock { count } }
    var readInvocationCount: Int { lock.withLock { readCount } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var writtenURLs: [URL] { lock.withLock { committedURLs } }
}

@Suite("Shared cloud download filesystem boundary")
struct CloudDownloadServiceTests {
    @Test("download requests are ordered, deduplicated and run off MainActor despite failures")
    @MainActor
    func orderedDownloadRequests() async {
        let urls = [URL(fileURLWithPath: "/virtual/one.json"), URL(fileURLWithPath: "/virtual/two.json")]
        let probe = CloudDownloadProbe(failedURL: urls[0])
        let service = CloudDownloadService(startDownloading: probe.start)
        let result = await service.requestDownloads(for: [urls[0], urls[0], urls[1]])
        #expect(result.attemptedURLs == urls)
        #expect(result.failedURLs == [urls[0]])
        #expect(!result.wasCancelled)
        #expect(probe.urls == urls)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation touches no cloud files")
    func preCancellation() async {
        let probe = CloudDownloadProbe()
        let service = CloudDownloadService(startDownloading: probe.start)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.requestDownloads(for: [URL(fileURLWithPath: "/virtual/one.json")])
        }
        let result = await task.value
        #expect(result.wasCancelled)
        #expect(result.attemptedURLs.isEmpty)
        #expect(probe.urls.isEmpty)
    }

    @Test("cancellation during a non-preemptible request preserves its exact attempted prefix")
    func partialCancellation() async {
        let urls = [URL(fileURLWithPath: "/virtual/one.json"), URL(fileURLWithPath: "/virtual/two.json")]
        let probe = CloudDownloadProbe(cancelAtInvocation: 1)
        let service = CloudDownloadService(startDownloading: probe.start)
        let result = await Task { await service.requestDownloads(for: urls) }.value
        #expect(result.wasCancelled)
        #expect(result.attemptedURLs == [urls[0]])
        #expect(probe.urls == [urls[0]])
    }

    @Test("shared download boundary accepts all library file types without filtering")
    func libraryFileTypes() async {
        let urls = ["people/person.json", "teams/team.deleted", "items/watermark/image.png", "keywords.json"]
            .map { URL(fileURLWithPath: "/virtual/" + $0) }
        let probe = CloudDownloadProbe()
        let service = CloudDownloadService(startDownloading: probe.start)
        let result = await service.requestDownloads(for: urls)
        #expect(result.attemptedURLs == urls)
        #expect(result.failedURLs.isEmpty)
        #expect(probe.urls == urls)
    }

    @Test("cancellation during a failed request preserves both attempt and failure evidence")
    func failedRequestCancellation() async {
        let urls = [URL(fileURLWithPath: "/virtual/one.json"), URL(fileURLWithPath: "/virtual/two.json")]
        let probe = CloudDownloadProbe(failedURL: urls[0], cancelAtInvocation: 1)
        let service = CloudDownloadService(startDownloading: probe.start)
        let result = await Task { await service.requestDownloads(for: urls) }.value
        #expect(result.wasCancelled)
        #expect(result.attemptedURLs == [urls[0]])
        #expect(result.failedURLs == [urls[0]])
        #expect(probe.urls == [urls[0]])
    }

    @Test("overlapping cloud batches never enter filesystem access concurrently")
    func serializedBatches() async {
        let probe = CloudDownloadProbe(delay: 0.01)
        let service = CloudDownloadService(startDownloading: probe.start)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = await service.requestDownloads(for: [URL(fileURLWithPath: "/virtual/\(index).json")])
                }
            }
        }
        #expect(probe.urls.count == 8)
        #expect(probe.maximumConcurrentCalls == 1)
    }

    @Test("cloud coordinators own cancellation and submit immutable URL batches",
          arguments: ["Roster", "KnownPeople", "Watermark", "KeywordLists"])
    func coordinatorSourceContract(library: String) throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: workspace.appendingPathComponent(
            "Aagedal Photo Agent/Services/\(library)CloudCoordinator.swift"
        ), encoding: .utf8)
        let start = try #require(source.range(of: "@MainActor\nfinal class \(library)CloudCoordinator"))
        let coordinator = String(source[start.lowerBound...])
        #expect(!coordinator.contains("FileManager.default.startDownloadingUbiquitousItem"))
        #expect(coordinator.contains("await downloadService.requestDownloads(for: urls)"))
        #expect(coordinator.contains("for task in pendingDownloads.values { task.cancel() }"))
    }
}

/// Every mutable probe field is protected by `lock`; injected work may run on any actor executor.
private nonisolated final class CloudDownloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failedURL: URL?
    private let cancelAtInvocation: Int?
    private let delay: TimeInterval
    private var recordedURLs: [URL] = []
    private var observedMainThread = false
    private var activeCalls = 0
    private var maximumCalls = 0

    init(failedURL: URL? = nil, cancelAtInvocation: Int? = nil, delay: TimeInterval = 0) {
        self.failedURL = failedURL
        self.cancelAtInvocation = cancelAtInvocation
        self.delay = delay
    }

    func start(_ url: URL) throws {
        let shouldCancel = lock.withLock {
            recordedURLs.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
            activeCalls += 1
            maximumCalls = max(maximumCalls, activeCalls)
            return recordedURLs.count == cancelAtInvocation
        }
        defer { lock.withLock { activeCalls -= 1 } }
        if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if url == failedURL { throw CocoaError(.fileReadUnknown) }
    }

    var urls: [URL] { lock.withLock { recordedURLs } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var maximumConcurrentCalls: Int { lock.withLock { maximumCalls } }
}
