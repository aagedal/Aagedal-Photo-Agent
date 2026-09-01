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
