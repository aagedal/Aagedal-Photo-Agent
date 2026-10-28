import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

private actor ImportSourceDiscoveryProgressRecorder {
    private var snapshots: [ImportSourceDiscoveryProgress] = []

    func append(_ snapshot: ImportSourceDiscoveryProgress) {
        snapshots.append(snapshot)
    }

    func recordedSnapshots() -> [ImportSourceDiscoveryProgress] {
        snapshots
    }
}

private nonisolated final class ImportPreflightTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if hasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func suspend() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            if !condition.waitBounded() { break }
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }
}

private nonisolated final class ImportPreflightProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock {
            count += 1
        }
    }

    var recordedCount: Int {
        lock.withLock { count }
    }
}

private nonisolated final class ImportPreflightSerializationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeProbeCount = 0
    private var maximumProbeCount = 0
    private var firstProbeStarted = false
    private var released = false

    func probe(_ path: String) -> Bool {
        condition.lock()
        activeProbeCount += 1
        maximumProbeCount = max(maximumProbeCount, activeProbeCount)
        let shouldSuspend = path == "/photos/first.jpg"
        if shouldSuspend {
            firstProbeStarted = true
            condition.broadcast()
            while !released {
                if !condition.waitBounded() { break }
            }
        }
        activeProbeCount -= 1
        condition.unlock()
        return false
    }

    func waitForFirstProbe() async -> Bool {
        for _ in 0..<200 {
            if hasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    var maximumConcurrentProbeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumProbeCount
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return firstProbeStarted
    }
}

private nonisolated enum ImportBookmarkOperation: Sendable, Equatable {
    case resolve
    case start
    case stop
    case create
}

private nonisolated final class ImportBookmarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operationStorage: [ImportBookmarkOperation] = []
    private var threadStorage: [Bool] = []

    var operations: [ImportBookmarkOperation] {
        lock.withLock { operationStorage }
    }

    var observedMainThread: [Bool] {
        lock.withLock { threadStorage }
    }

    func record(_ operation: ImportBookmarkOperation) {
        lock.withLock {
            operationStorage.append(operation)
            threadStorage.append(Thread.isMainThread)
        }
    }
}

private nonisolated final class ImportBookmarkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func suspend() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            if !condition.waitBounded() { break }
        }
        condition.unlock()
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if hasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }
}

private nonisolated final class ImportBookmarkCancellationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.withLock {
            values.isEmpty ? false : values.removeFirst()
        }
    }
}

@Suite("Import duplicate and collision preflight")
struct ImportPreflightServiceTests {
    @Test("Preflight freezes duplicate skips and complete collision evidence")
    func freezesDuplicateAndCollisionEvidence() async throws {
        let source = URL(fileURLWithPath: "/card/photo.jpg")
        let memo = URL(fileURLWithPath: "/card/photo.wav")
        let primary = URL(fileURLWithPath: "/photos/photo.jpg")
        let memoPrimary = URL(fileURLWithPath: "/photos/photo.wav")
        let backup = URL(fileURLWithPath: "/backup/photo.jpg")
        let otherSource = URL(fileURLWithPath: "/card/other.jpg")
        let sharedDestination = URL(fileURLWithPath: "/photos/shared.jpg")
        let jobs = [
            ImportCopyService.CopyJob(
                source: source,
                desiredPrimaryDest: primary,
                desiredBackupDest: backup
            ),
            ImportCopyService.CopyJob(
                source: memo,
                desiredPrimaryDest: memoPrimary,
                desiredBackupDest: nil
            ),
            ImportCopyService.CopyJob(
                source: otherSource,
                desiredPrimaryDest: sharedDestination,
                desiredBackupDest: backup
            ),
            ImportCopyService.CopyJob(
                source: URL(fileURLWithPath: "/card/final.jpg"),
                desiredPrimaryDest: sharedDestination,
                desiredBackupDest: nil
            ),
        ]
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in [source: URL(fileURLWithPath: "/library/earlier/final.jpg")] },
            fileExists: { $0 == backup.standardizedFileURL.path }
        )

        let result = try await service.prepare(ImportPreflightService.Request(
            jobs: jobs,
            previousImportCandidates: [
                PreviousImportDetector.Candidate(
                    source: source,
                    dateFolderName: "2026-08-29"
                ),
            ],
            companionParentBySource: [memo: source],
            destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
            skipPreviouslyImported: true,
            freezeOverwriteCollisions: true
        ))

        #expect(result.jobs[0].preflightSkipReason == .previouslyImported)
        #expect(result.jobs[1].preflightSkipReason == .previouslyImported)
        #expect(result.jobs[2].expectedPrimaryCollision == false)
        #expect(result.jobs[2].expectedBackupCollision == true)
        #expect(result.jobs[3].expectedPrimaryCollision == true)
        #expect(result.overwrite?.primaryCollisionCount == 1)
        #expect(result.overwrite?.backupCollisionCount == 1)
        #expect(result.overwrite?.signature.map(\.isSkipped) == [true, true, false, false])
    }

    @Test("Overwrite re-copies a photo previously imported to this same path, but not one imported elsewhere")
    func overwriteRefreshesSamePathPreviousImport() async throws {
        let folder = URL(fileURLWithPath: "/photos/2026-08-29 – Match", isDirectory: true)
        let refreshed = URL(fileURLWithPath: "/card/A.ARW")
        let refreshedMemo = URL(fileURLWithPath: "/card/A.WAV")
        let elsewhere = URL(fileURLWithPath: "/card/B.ARW")
        let jobs = [
            ImportCopyService.CopyJob(
                source: refreshed,
                desiredPrimaryDest: folder.appendingPathComponent("A.ARW"),
                desiredBackupDest: nil
            ),
            ImportCopyService.CopyJob(
                source: refreshedMemo,
                desiredPrimaryDest: folder.appendingPathComponent("A.WAV"),
                desiredBackupDest: nil
            ),
            ImportCopyService.CopyJob(
                source: elsewhere,
                desiredPrimaryDest: folder.appendingPathComponent("B.ARW"),
                desiredBackupDest: nil
            ),
        ]
        let existing: Set<String> = [
            folder.appendingPathComponent("A.ARW").path,
            folder.appendingPathComponent("A.WAV").path,
        ]
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in [
                // Case differs from the planned path: the volume is case-insensitive.
                refreshed: URL(fileURLWithPath: "/photos/2026-08-29 – Match/a.arw"),
                elsewhere: URL(fileURLWithPath: "/photos/2026-08-28 – Earlier/B.ARW"),
            ] },
            fileExists: { existing.contains($0) }
        )

        func prepare(overwrite: Bool) async throws -> ImportPreflightService.Result {
            try await service.prepare(ImportPreflightService.Request(
                jobs: jobs,
                previousImportCandidates: [refreshed, elsewhere].map {
                    PreviousImportDetector.Candidate(source: $0, dateFolderName: "2026-08-29")
                },
                companionParentBySource: [refreshedMemo: refreshed],
                destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
                skipPreviouslyImported: true,
                freezeOverwriteCollisions: overwrite
            ))
        }

        let overwrite = try await prepare(overwrite: true)
        #expect(overwrite.jobs.map(\.preflightSkipReason) == [nil, nil, .previouslyImported])
        #expect(overwrite.overwrite?.primaryCollisionCount == 2)

        let skipping = try await prepare(overwrite: false)
        #expect(skipping.jobs.map(\.preflightSkipReason) == [.previouslyImported, .previouslyImported, .previouslyImported])
    }

    @Test("Pre-cancelled preflight performs no filesystem probes")
    func preCancelledPreflightIsExplicit() async {
        let probes = ImportPreflightProbeRecorder()
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in
                probes.record()
                return [:]
            },
            fileExists: { _ in
                probes.record()
                return false
            }
        )
        let task = Task {
            try await service.prepare(ImportPreflightService.Request(
                jobs: [],
                previousImportCandidates: [],
                companionParentBySource: [:],
                destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
                skipPreviouslyImported: true,
                freezeOverwriteCollisions: true
            ))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected preflight cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        #expect(probes.recordedCount == 0)
    }

    @Test("Actor serializes overlapping collision preflights")
    func serializesOverlappingPreflights() async throws {
        let gate = ImportPreflightSerializationGate()
        let service = ImportPreflightService(fileExists: { gate.probe($0) })
        let first = ImportPreflightService.Request(
            jobs: [ImportCopyService.CopyJob(
                source: URL(fileURLWithPath: "/card/first.jpg"),
                desiredPrimaryDest: URL(fileURLWithPath: "/photos/first.jpg"),
                desiredBackupDest: nil
            )],
            previousImportCandidates: [],
            companionParentBySource: [:],
            destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
            skipPreviouslyImported: false,
            freezeOverwriteCollisions: true
        )
        let second = ImportPreflightService.Request(
            jobs: [ImportCopyService.CopyJob(
                source: URL(fileURLWithPath: "/card/second.jpg"),
                desiredPrimaryDest: URL(fileURLWithPath: "/photos/second.jpg"),
                desiredBackupDest: nil
            )],
            previousImportCandidates: [],
            companionParentBySource: [:],
            destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
            skipPreviouslyImported: false,
            freezeOverwriteCollisions: true
        )

        let firstTask = Task { try await service.prepare(first) }
        defer { gate.release() }
        let firstProbeDidStart = await gate.waitForFirstProbe()
        #expect(firstProbeDidStart)
        let secondTask = Task { try await service.prepare(second) }
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.maximumConcurrentProbeCount == 1)
        gate.release()

        _ = try await firstTask.value
        _ = try await secondTask.value
        #expect(gate.maximumConcurrentProbeCount == 1)
    }

    @Test("Voice-memo bundle planning freezes one suffix across primary and backup destinations")
    func bundlePlanningUsesOneSharedSuffix() async throws {
        let photos = URL(fileURLWithPath: "/photos", isDirectory: true)
        let backup = URL(fileURLWithPath: "/backup", isDirectory: true)
        let request = ImportPreflightService.BundleDestinationRequest(
            stem: "TRA00001",
            files: [
                .init(source: URL(fileURLWithPath: "/card/TRA00001.ARW"), role: .image,
                      primaryFolder: photos, backupFolder: backup),
                .init(source: URL(fileURLWithPath: "/card/TRA00001.WAV"), role: .memo,
                      primaryFolder: photos, backupFolder: backup),
            ]
        )
        let service = ImportPreflightService(fileExists: { path in
            path == "/photos/TRA00001.ARW"
        })

        let result = await service.resolveBundleDestinations(
            [request],
            policy: .renameWithSuffix
        )
        let evidence: ImportPreflightService.BundlePlanningEvidence
        switch result {
        case .complete(let completed):
            evidence = completed
        case .cancelled:
            Issue.record("An uncancelled bundle plan must complete")
            return
        }

        #expect(evidence.requestedBundleCount == 1)
        #expect(evidence.completedBundleCount == 1)
        let destination = try #require(evidence.destinations.first)
        #expect(destination.id == request.id)
        #expect(destination.files.map(\.primary.path) == ["/photos/TRA00001-1.ARW", "/photos/TRA00001-1.WAV"])
        #expect(destination.files.map(\.backup?.path) == ["/backup/TRA00001-1.ARW", "/backup/TRA00001-1.WAV"])
        #expect(destination.files.allSatisfy { $0.skipReason == nil })
        #expect(destination.wasRenamed)
    }

    @Test("Pre-cancelled voice-memo planning returns explicit immutable partial evidence")
    func preCancelledBundlePlanningReturnsEvidence() async {
        let probes = ImportPreflightProbeRecorder()
        let service = ImportPreflightService(fileExists: { _ in
            probes.record()
            return false
        })
        let request = ImportPreflightService.BundleDestinationRequest(
            stem: "TRA00002",
            files: [
                .init(source: URL(fileURLWithPath: "/card/TRA00002.ARW"), role: .image,
                      primaryFolder: URL(fileURLWithPath: "/photos"), backupFolder: nil),
                .init(source: URL(fileURLWithPath: "/card/TRA00002.WAV"), role: .memo,
                      primaryFolder: URL(fileURLWithPath: "/photos"), backupFolder: nil),
            ]
        )
        let task = Task {
            await service.resolveBundleDestinations([request], policy: .renameWithSuffix)
        }
        task.cancel()

        let result = await task.value
        switch result {
        case .complete:
            Issue.record("A pre-cancelled bundle plan must not publish complete evidence")
        case .cancelled(let evidence):
            #expect(evidence.requestedBundleCount == 1)
            #expect(evidence.completedBundleCount == 0)
            #expect(evidence.destinations.isEmpty)
        }
        #expect(probes.recordedCount == 0)
    }
}

@Suite("Import execution security scopes")
struct ImportExecutionSecurityScopeServiceTests {
    @MainActor
    @Test("Import execution scopes are deduplicated, balanced, and off MainActor")
    func scopesAreBalancedOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/Volumes/Source", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Volumes/Destination", isDirectory: true)
        let probe = ImportExecutionSecurityScopeProbe(unavailableURL: destination)
        let service = ImportExecutionSecurityScopeService(
            access: ImportExecutionSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            ),
            cancellationRequested: { false }
        )
        let request = ImportExecutionSecurityScopeRequest(
            roots: [source, destination, source]
        )

        let acquisition = await service.acquire(request)
        let claim: ImportExecutionSecurityScopeClaim
        if case .acquired(let acquiredClaim) = acquisition {
            claim = acquiredClaim
        } else {
            Issue.record("Expected a complete import security-scope acquisition")
            return
        }

        #expect(claim.roots == [source, destination])
        #expect(claim.startedRoots == [source])
        let release = await service.release(claim)
        #expect(release.releasedRoots == [source])
        #expect(probe.startedURLs == [source, destination])
        #expect(probe.stoppedURLs == [source])
        #expect(!probe.ranOnMainThread)
    }

    @Test("Cancellation during import scope acquisition releases the successful prefix")
    func cancellationReleasesSuccessfulPrefix() async {
        let source = URL(fileURLWithPath: "/Volumes/Source", isDirectory: true)
        let voiceMemos = URL(fileURLWithPath: "/Volumes/VoiceMemos", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Volumes/Destination", isDirectory: true)
        let probe = ImportExecutionSecurityScopeProbe(cancelAfterFirstStart: true)
        let service = ImportExecutionSecurityScopeService(
            access: ImportExecutionSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            ),
            cancellationRequested: { probe.isCancellationRequested }
        )
        let request = ImportExecutionSecurityScopeRequest(
            roots: [source, voiceMemos, destination]
        )

        let result = await service.acquire(request)

        #expect(result == .cancelledAfterAccess(
            requestID: request.requestID,
            inspectedRootCount: 1,
            releasedStartedRoots: [source]
        ))
        #expect(probe.startedURLs == [source])
        #expect(probe.stoppedURLs == [source])
    }

    @Test("Import scope operation releases successful claims in reverse order")
    func operationReleasesInReverseOrder() async throws {
        let source = URL(fileURLWithPath: "/Volumes/Source", isDirectory: true)
        let voiceMemos = URL(fileURLWithPath: "/Volumes/VoiceMemos", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Volumes/Destination", isDirectory: true)
        let probe = ImportExecutionSecurityScopeProbe()
        let service = ImportExecutionSecurityScopeService(
            access: ImportExecutionSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            ),
            cancellationRequested: { false }
        )

        let value = try await service.withAccess(ImportExecutionSecurityScopeRequest(
            roots: [source, voiceMemos, destination]
        )) {
            42
        }

        #expect(value == 42)
        #expect(probe.startedURLs == [source, voiceMemos, destination])
        #expect(probe.stoppedURLs == [destination, voiceMemos, source])
    }

    @Test("Import scope operation releases claims when its work throws")
    func operationFailureStillReleases() async {
        let source = URL(fileURLWithPath: "/Volumes/Source", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Volumes/Destination", isDirectory: true)
        let probe = ImportExecutionSecurityScopeProbe()
        let service = ImportExecutionSecurityScopeService(
            access: ImportExecutionSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            ),
            cancellationRequested: { false }
        )

        do {
            let _: Int = try await service.withAccess(ImportExecutionSecurityScopeRequest(
                roots: [source, destination]
            )) {
                throw CancellationError()
            }
            Issue.record("Expected the import operation to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }

        #expect(probe.stoppedURLs == [destination, source])
    }

    @Test("Import execution delegates all security-scope ownership to the actor")
    func sourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/ImportViewModel.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "    func startImport()"))
        let functionEnd = try #require(source.range(
            of: "    /// Cancel a running import.",
            range: functionStart.upperBound..<source.endIndex
        ))
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(functionSource.contains(
            "executionSecurityScopeService.withAccess(initialSecurityScopeRequest)"
        ))
        #expect(functionSource.contains(
            "executionSecurityScopeService.withAccess(backupSecurityScopeRequest)"
        ))
        #expect(!functionSource.contains("startAccessingSecurityScopedResource"))
        #expect(!functionSource.contains("stopAccessingSecurityScopedResource"))
    }
}

private nonisolated final class ImportExecutionSecurityScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let unavailableURL: URL?
    private let cancelAfterFirstStart: Bool
    private var starts: [URL] = []
    private var stops: [URL] = []
    private var observedMainThread = false
    private var cancellationRequested = false

    init(unavailableURL: URL? = nil, cancelAfterFirstStart: Bool = false) {
        self.unavailableURL = unavailableURL
        self.cancelAfterFirstStart = cancelAfterFirstStart
    }

    func start(_ url: URL) -> Bool {
        lock.withLock {
            starts.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
            if cancelAfterFirstStart, starts.count == 1 {
                cancellationRequested = true
            }
        }
        return url != unavailableURL
    }

    func stop(_ url: URL) {
        lock.withLock {
            stops.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }

    var startedURLs: [URL] { lock.withLock { starts } }
    var stoppedURLs: [URL] { lock.withLock { stops } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var isCancellationRequested: Bool { lock.withLock { cancellationRequested } }
}

@Suite("Import source discovery")
struct ImportSourceDiscoveryServiceTests {
    @Test("Discovery progress uses a five-second production cadence")
    func progressCadence() {
        #expect(ImportSourceDiscoveryService.defaultProgressUpdateInterval == .seconds(5))
    }

    @Test("Voice-memo scan delegates security-scope ownership to discovery")
    func voiceMemoScanSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/ImportViewModel.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "    private func scanVoiceMemoSource(url: URL)"))
        let functionEnd = try #require(source.range(
            of: "    // MARK: - Destination Selection",
            range: functionStart.upperBound..<source.endIndex
        ))
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(functionSource.contains("sourceDiscoveryService.discoverFiles(at: url)"))
        #expect(!functionSource.contains("startAccessingSecurityScopedResource"))
        #expect(!functionSource.contains("stopAccessingSecurityScopedResource"))
    }

    @Test("Security scope is balanced and never touched on MainActor")
    @MainActor
    func securityScopeRunsOffMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = ImportSourceSecurityScopeProbe(startResult: true)
        let service = ImportSourceDiscoveryService(
            securityScopeAccess: ImportSourceSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            )
        )

        _ = try await service.discoverFiles(at: root)

        #expect(probe.startedURLs == [root])
        #expect(probe.stoppedURLs == [root])
        #expect(!probe.ranOnMainThread)
    }

    @Test("An unavailable security scope is not stopped")
    func unavailableSecurityScopeIsNotStopped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceUnavailableScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = ImportSourceSecurityScopeProbe(startResult: false)
        let service = ImportSourceDiscoveryService(
            securityScopeAccess: ImportSourceSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            )
        )

        _ = try await service.discoverFiles(at: root)

        #expect(probe.startedURLs == [root])
        #expect(probe.stoppedURLs.isEmpty)
    }

    @Test("Cancellation during security-scope acquisition still balances access")
    func cancellationAfterAccessIsBalanced() async {
        let root = URL(fileURLWithPath: "/source-cancelled-during-security-scope")
        let probe = ImportSourceBlockingSecurityScopeProbe()
        let service = ImportSourceDiscoveryService(
            securityScopeAccess: ImportSourceSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            )
        )
        let task = Task {
            try await service.discoverFiles(at: root)
        }

        #expect(await probe.waitUntilStarted())
        task.cancel()
        probe.release()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation after security-scope acquisition")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        #expect(probe.stoppedURLs == [root])
    }

    @Test("Discovery recursively returns regular files while skipping hidden and package contents")
    func discoversRegularFilesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let package = root.appendingPathComponent("ignored.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let visible = nested.appendingPathComponent("visible.jpg")
        let hidden = root.appendingPathComponent(".hidden.jpg")
        let packaged = package.appendingPathComponent("packaged.jpg")
        try Data("visible".utf8).write(to: visible)
        try Data("hidden".utf8).write(to: hidden)
        try Data("packaged".utf8).write(to: packaged)

        let files = try await ImportSourceDiscoveryService().discoverFiles(at: root)

        #expect(
            files.map { $0.resolvingSymlinksInPath().path }
                == [visible.resolvingSymlinksInPath().path]
        )
    }

    @Test("Discovery surfaces cancellation before touching the source")
    func cancellationIsExplicit() async {
        let probe = ImportSourceSecurityScopeProbe(startResult: true)
        let service = ImportSourceDiscoveryService(
            securityScopeAccess: ImportSourceSecurityScopeAccess(
                start: probe.start,
                stop: probe.stop
            )
        )
        let task = Task {
            try await service.discoverFiles(at: URL(fileURLWithPath: "/source-is-never-read"))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected source discovery to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        #expect(probe.startedURLs.isEmpty)
        #expect(probe.stoppedURLs.isEmpty)
    }

    @Test("Discovery progress reports files, supported images, and WAV files")
    func reportsDiscoveryProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceProgressTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("photo.jpg"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        try Data().write(to: root.appendingPathComponent("memo.wav"))

        let recorder = ImportSourceDiscoveryProgressRecorder()
        let files = try await ImportSourceDiscoveryService().discoverFiles(
            at: root,
            progressUpdateInterval: .zero
        ) { snapshot in
            await recorder.append(snapshot)
        }
        let snapshots = await recorder.recordedSnapshots()

        #expect(files.count == 3)
        #expect(snapshots.last == ImportSourceDiscoveryProgress(
            discoveredFileCount: 3,
            supportedImageCount: 1,
            wavFileCount: 1
        ))
    }
}

private nonisolated final class ImportSourceSecurityScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let startResult: Bool
    private var starts: [URL] = []
    private var stops: [URL] = []
    private var observedMainThread = false

    init(startResult: Bool) {
        self.startResult = startResult
    }

    func start(_ url: URL) -> Bool {
        lock.withLock {
            starts.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return startResult
    }

    func stop(_ url: URL) {
        lock.withLock {
            stops.append(url)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }

    var startedURLs: [URL] { lock.withLock { starts } }
    var stoppedURLs: [URL] { lock.withLock { stops } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class ImportSourceBlockingSecurityScopeProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var stops: [URL] = []

    func start(_ url: URL) -> Bool {
        _ = url
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            if !condition.waitBounded() { break }
        }
        condition.unlock()
        return true
    }

    func stop(_ url: URL) {
        condition.withLock { stops.append(url) }
    }

    func waitUntilStarted(timeout: TimeInterval = 30) async -> Bool {
        await Task.detached { [self] in
            waitUntilStartedSynchronously(timeout: timeout)
        }.value
    }

    private func waitUntilStartedSynchronously(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !started {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    var stoppedURLs: [URL] { condition.withLock { stops } }
}

@Suite("ImportViewModel", .serialized)
@MainActor
struct ImportViewModelTests {
    @Test("Destination bookmarks restore and refresh away from MainActor")
    func destinationBookmarksRestoreOffMainActor() async throws {
        let standardDefaults = AppDefaults.store
        let originalVerifyAfterWrite = standardDefaults.object(
            forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
        )
        defer {
            if let originalVerifyAfterWrite {
                standardDefaults.set(
                    originalVerifyAfterWrite,
                    forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
                )
            } else {
                standardDefaults.removeObject(forKey: UserDefaultsKeys.importBackupVerifyAfterWrite)
            }
        }
        let suiteName = "ImportDestinationBookmarks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let destinationData = Data([0x11])
        let backupData = Data([0x12])
        let refreshedDestinationData = Data([0x21])
        let refreshedBackupData = Data([0x22])
        let destinationURL = URL(fileURLWithPath: "/tmp/import-destination", isDirectory: true)
        let backupURL = URL(fileURLWithPath: "/tmp/import-backup", isDirectory: true)
        defaults.set(destinationData, forKey: UserDefaultsKeys.importDestinationBookmark)
        defaults.set(backupData, forKey: UserDefaultsKeys.importBackupBookmark)
        defaults.set(false, forKey: UserDefaultsKeys.importBackupVerifyAfterWrite)
        let recorder = ImportBookmarkRecorder()
        let service = ImportDestinationBookmarkService(access: ImportDestinationBookmarkAccess(
            resolve: { data in
                recorder.record(.resolve)
                return ImportDestinationBookmarkResolution(
                    url: data == destinationData ? destinationURL : backupURL,
                    isStale: true
                )
            },
            startAccessing: { _ in
                recorder.record(.start)
                return true
            },
            stopAccessing: { _ in recorder.record(.stop) },
            create: { url in
                recorder.record(.create)
                return url == destinationURL ? refreshedDestinationData : refreshedBackupData
            }
        ))
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            bookmarkDefaults: defaults,
            destinationBookmarkService: service
        )

        await viewModel.waitForDestinationBookmarkRestoration()

        #expect(viewModel.configuration.destinationBaseURL == destinationURL)
        #expect(viewModel.configuration.backupDestination == BackupDestination(
            url: backupURL,
            verifyAfterWrite: false
        ))
        #expect(defaults.data(forKey: UserDefaultsKeys.importDestinationBookmark) == refreshedDestinationData)
        #expect(defaults.data(forKey: UserDefaultsKeys.importBackupBookmark) == refreshedBackupData)
        #expect(recorder.operations.filter { $0 == .resolve }.count == 2)
        #expect(recorder.operations.filter { $0 == .start }.count == 2)
        #expect(recorder.operations.filter { $0 == .create }.count == 2)
        #expect(recorder.operations.filter { $0 == .stop }.count == 2)
        #expect(recorder.observedMainThread.allSatisfy { !$0 })
    }

    @Test("Selected destinations publish and persist complete bookmark work")
    func selectedDestinationsPublishCompleteBookmarkWork() async throws {
        let standardDefaults = AppDefaults.store
        let originalVerifyAfterWrite = standardDefaults.object(
            forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
        )
        defer {
            if let originalVerifyAfterWrite {
                standardDefaults.set(
                    originalVerifyAfterWrite,
                    forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
                )
            } else {
                standardDefaults.removeObject(forKey: UserDefaultsKeys.importBackupVerifyAfterWrite)
            }
        }
        let suiteName = "ImportSelectedDestinationBookmarks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let destinationURL = URL(fileURLWithPath: "/tmp/selected-import-destination", isDirectory: true)
        let backupURL = URL(fileURLWithPath: "/tmp/selected-import-backup", isDirectory: true)
        let destinationData = Data([0x31])
        let backupData = Data([0x32])
        let recorder = ImportBookmarkRecorder()
        let service = ImportDestinationBookmarkService(access: ImportDestinationBookmarkAccess(
            startAccessing: { _ in
                recorder.record(.start)
                return true
            },
            stopAccessing: { _ in recorder.record(.stop) },
            create: { url in
                recorder.record(.create)
                return url == destinationURL ? destinationData : backupData
            }
        ))
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            bookmarkDefaults: defaults,
            destinationBookmarkService: service
        )

        await viewModel.setDestinationBaseURL(destinationURL)
        await viewModel.setBackupDestinationURL(backupURL)

        #expect(viewModel.configuration.destinationBaseURL == destinationURL)
        #expect(viewModel.configuration.backupDestination?.url == backupURL)
        #expect(defaults.data(forKey: UserDefaultsKeys.importDestinationBookmark) == destinationData)
        #expect(defaults.data(forKey: UserDefaultsKeys.importBackupBookmark) == backupData)
        #expect(recorder.operations == [.start, .create, .stop, .start, .create, .stop])
        #expect(recorder.observedMainThread.allSatisfy { !$0 })

        viewModel.clearBackupDestination()
        #expect(viewModel.configuration.backupDestination == nil)
        #expect(defaults.data(forKey: UserDefaultsKeys.importBackupBookmark) == nil)
    }

    @Test("Clearing backup rejects a bookmark completion already in flight")
    func clearingBackupRejectsLateBookmarkCompletion() async throws {
        let standardDefaults = AppDefaults.store
        let originalVerifyAfterWrite = standardDefaults.object(
            forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
        )
        defer {
            if let originalVerifyAfterWrite {
                standardDefaults.set(
                    originalVerifyAfterWrite,
                    forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
                )
            } else {
                standardDefaults.removeObject(forKey: UserDefaultsKeys.importBackupVerifyAfterWrite)
            }
        }
        let suiteName = "ImportClearedBackupBookmark.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gate = ImportBookmarkGate()
        let service = ImportDestinationBookmarkService(access: ImportDestinationBookmarkAccess(
            create: { _ in
                gate.suspend()
                return Data([0x41])
            }
        ))
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            bookmarkDefaults: defaults,
            destinationBookmarkService: service
        )
        let selectionTask = Task {
            await viewModel.setBackupDestinationURL(
                URL(fileURLWithPath: "/tmp/late-import-backup", isDirectory: true)
            )
        }
        #expect(await gate.waitUntilStarted())

        viewModel.clearBackupDestination()
        gate.release()
        await selectionTask.value

        #expect(viewModel.configuration.backupDestination == nil)
        #expect(defaults.data(forKey: UserDefaultsKeys.importBackupBookmark) == nil)
    }

    @Test("Destination bookmark cancellation is explicit around synchronous access")
    func destinationBookmarkCancellationIsExplicit() async {
        let recorder = ImportBookmarkRecorder()
        let preAccessService = ImportDestinationBookmarkService(
            access: ImportDestinationBookmarkAccess(resolve: { _ in
                recorder.record(.resolve)
                return ImportDestinationBookmarkResolution(
                    url: URL(fileURLWithPath: "/tmp/unexpected"),
                    isStale: false
                )
            }),
            cancellationRequested: { true }
        )
        let preAccessRequestID = UUID()

        let preAccessResult = await preAccessService.resolve(
            Data([0x51]),
            requestID: preAccessRequestID
        )

        #expect(preAccessResult == .cancelledBeforeAccess(requestID: preAccessRequestID))
        #expect(recorder.operations.isEmpty)

        let cancellation = ImportBookmarkCancellationSequence([false, true])
        let postAccessURL = URL(fileURLWithPath: "/tmp/post-access-import-bookmark", isDirectory: true)
        let postAccessService = ImportDestinationBookmarkService(
            access: ImportDestinationBookmarkAccess(create: { _ in Data([0x52]) }),
            cancellationRequested: cancellation.next
        )
        let postAccessRequestID = UUID()

        let postAccessResult = await postAccessService.createBookmark(
            for: postAccessURL,
            requestID: postAccessRequestID
        )

        #expect(postAccessResult == .completed(ImportDestinationBookmarkCommit(
            requestID: postAccessRequestID,
            bookmarkData: Data([0x52]),
            cancellationRequestedAfterAccess: true
        )))
    }

    @Test("RAW and JPEG filters include images from both selected cards")
    func fileTypeFilterSpansBothSources() {
        let defaults = AppDefaults.store
        let original = defaults.object(forKey: UserDefaultsKeys.importFileTypeFilter)
        defer {
            if let original {
                defaults.set(original, forKey: UserDefaultsKeys.importFileTypeFilter)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.importFileTypeFilter)
            }
        }

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        let raw = URL(fileURLWithPath: "/card-1/TRA08908.ARW")
        let jpeg = URL(fileURLWithPath: "/card-2/TRA08908.JPG")
        let wav = URL(fileURLWithPath: "/card-2/TRA08908.WAV")
        viewModel.sourceFiles = [raw]
        viewModel.voiceMemoSourceFiles = [jpeg, wav]

        viewModel.configuration.fileTypeFilter = .rawOnly
        #expect(viewModel.filteredSourceFiles == [raw])
        viewModel.configuration.fileTypeFilter = .jpegOnly
        #expect(viewModel.filteredSourceFiles == [jpeg])
        viewModel.configuration.fileTypeFilter = .both
        #expect(viewModel.filteredSourceFiles == [raw, jpeg])
    }

    @Test("Import template preserves ordered creators and exact Date Created")
    func orderedCreatorAndDateTemplate() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        let creatorTransport = IPTCMetadata(
            creators: ["First Reporter", "Second Reporter"]
        ).creatorTransportValue!
        let template = MetadataTemplate(
            name: "Desk",
            fields: [
                TemplateField(fieldKey: "creator", templateValue: creatorTransport),
                TemplateField(
                    fieldKey: "dateCreated",
                    templateValue: "2026-08-21T10:15:30.120+02:30"
                ),
            ]
        )

        viewModel.applyTemplate(template)

        #expect(viewModel.configuration.metadata.creators == ["First Reporter", "Second Reporter"])
        #expect(viewModel.configuration.metadata.editorialDateCreated?.precision == .fractionalSecond)
        #expect(viewModel.configuration.metadata.editorialDateCreated?.timeZoneOffsetMinutes == 150)
        let fields = ImportViewModel.buildMetadataFields(from: viewModel.configuration.metadata)
        #expect(fields[.creator] == creatorTransport)
        #expect(fields[.dateCreated] == "2026-08-21T10:15:30.120+02:30")
    }

    @Test("Import readiness explains each blocked setup state")
    func importReadinessExplainsBlockedStates() {
        let defaults = AppDefaults.store
        let keys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importSortByDate,
        ]
        var originals: [String: Any] = [:]
        for key in keys {
            originals[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let original = originals[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.fileTypeFilter = .both
        viewModel.sortByDate = false

        #expect(viewModel.importBlockingReason == "Choose a memory card or folder to import from.")

        let source = URL(fileURLWithPath: "/Volumes/Card", isDirectory: true)
        let image = source.appendingPathComponent("photo.jpg")
        viewModel.configuration.sourceURL = source
        viewModel.importPhase = .scanning
        #expect(viewModel.importBlockingReason == "Scanning the source folder…")

        viewModel.importPhase = .idle
        #expect(viewModel.importBlockingReason == "No supported images were found in the source folder.")

        viewModel.sourceFiles = [image]
        #expect(viewModel.importBlockingReason == "Enter an import title.")

        viewModel.configuration.importTitle = "Cup Final"
        #expect(viewModel.importBlockingReason == nil)

        viewModel.configuration.fileTypeFilter = .rawOnly
        #expect(viewModel.importBlockingReason == "No images match the RAW Only filter.")

        viewModel.configuration.fileTypeFilter = .both
        viewModel.sortByDate = true
        viewModel.isScanningDates = true
        #expect(viewModel.importBlockingReason == "Scanning capture dates…")

        viewModel.isScanningDates = false
        #expect(viewModel.importBlockingReason == "Scan capture dates before importing.")

        viewModel.dateGroups = [
            ImportDateGroup(
                dateString: "2026:07:26",
                folderName: "2026-07-26 – Cup Final",
                shootFolderName: nil,
                yearFolder: "2026",
                files: [image]
            )
        ]
        #expect(viewModel.importBlockingReason == nil)

        viewModel.dateGroups[0].isIncluded = false
        #expect(viewModel.importBlockingReason == "Select at least one date folder to import.")
    }

    @Test("Import behavior settings restore from defaults and survive reset")
    func importBehaviorSettingsRestoreFromDefaultsAndSurviveReset() {
        let defaults = AppDefaults.store
        let keys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
            UserDefaultsKeys.importDateFolderGrouping,
            UserDefaultsKeys.importSplitShootsIntoSubfolders,
        ]
        var originals: [String: Any] = [:]
        for key in keys {
            if let original = defaults.object(forKey: key) {
                originals[key] = original
            }
        }
        defer {
            for key in keys {
                if let original = originals[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(ImportFileTypeFilter.rawOnly.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter)
        defaults.set(ImportConflictPolicy.skipExisting.rawValue, forKey: UserDefaultsKeys.importConflictPolicy)
        defaults.set(false, forKey: UserDefaultsKeys.importCreateSubFolders)
        defaults.set(CopyVerificationMode.off.rawValue, forKey: UserDefaultsKeys.importVerificationMode)
        defaults.set(false, forKey: UserDefaultsKeys.importSkipPreviouslyImported)
        defaults.set(true, forKey: UserDefaultsKeys.importSortByDate)
        defaults.set(ImportDateFolderGrouping.month.rawValue, forKey: UserDefaultsKeys.importDateFolderGrouping)
        defaults.set(true, forKey: UserDefaultsKeys.importSplitShootsIntoSubfolders)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )

        #expect(viewModel.configuration.fileTypeFilter == .rawOnly)
        #expect(viewModel.configuration.conflictPolicy == .skipExisting)
        #expect(viewModel.configuration.createSubFolders == false)
        #expect(viewModel.configuration.verificationMode == .off)
        #expect(viewModel.configuration.skipPreviouslyImported == false)
        #expect(viewModel.sortByDate == true)
        #expect(viewModel.dateFolderGrouping == .month)
        #expect(viewModel.splitShootsIntoSubfolders == true)

        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = true
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = true
        viewModel.sortByDate = false
        viewModel.dateFolderGrouping = .year
        viewModel.splitShootsIntoSubfolders = false
        viewModel.reset()

        #expect(viewModel.configuration.fileTypeFilter == .jpegOnly)
        #expect(viewModel.configuration.conflictPolicy == .overwrite)
        #expect(viewModel.configuration.createSubFolders == true)
        #expect(viewModel.configuration.verificationMode == .on)
        #expect(viewModel.configuration.skipPreviouslyImported == true)
        #expect(viewModel.sortByDate == false)
        #expect(viewModel.dateFolderGrouping == .year)
        #expect(viewModel.splitShootsIntoSubfolders == false)
    }

    @Test("Split-shoot folder preview updates when subfolder layout toggles")
    func splitShootFolderPreviewUpdatesWhenSubfolderLayoutToggles() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.destinationBaseURL = URL(fileURLWithPath: "/Volumes/Photos")
        viewModel.configuration.importTitle = "Cup Final"
        viewModel.sortByDate = true
        viewModel.dateFolderGrouping = .year
        viewModel.splitShootsIntoSubfolders = false
        viewModel.dateGroups = [
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "2026-07-08 \u{2013} Cup Final \u{2013} Shoot 1",
                shootFolderName: nil,
                yearFolder: "2026",
                monthFolder: "07",
                files: [URL(fileURLWithPath: "/card/one.jpg")]
            ),
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "2026-07-08 \u{2013} Cup Final \u{2013} Shoot 2",
                shootFolderName: nil,
                yearFolder: "2026",
                monthFolder: "07",
                files: [URL(fileURLWithPath: "/card/two.jpg")]
            ),
        ]

        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[0]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final \u{2013} Shoot 1")

        viewModel.splitShootsIntoSubfolders = true

        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[0]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final / Shoot 1")
        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[1]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final / Shoot 2")

        viewModel.splitShootsIntoSubfolders = false

        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[0]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final \u{2013} Shoot 1")
        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[1]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final \u{2013} Shoot 2")
    }

    @Test("Split-shoot subfolder layout preserves a manually edited parent folder name")
    func splitShootSubfolderLayoutPreservesManualParentName() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.importTitle = "Cup Final"
        viewModel.sortByDate = true
        viewModel.splitShootsIntoSubfolders = true
        viewModel.dateGroups = [
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "My written folder title",
                shootFolderName: "Shoot 1",
                yearFolder: "2026",
                files: [URL(fileURLWithPath: "/card/one.jpg")]
            ),
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "My written folder title",
                shootFolderName: "Shoot 2",
                yearFolder: "2026",
                files: [URL(fileURLWithPath: "/card/two.jpg")]
            ),
        ]

        viewModel.splitShootsIntoSubfolders = false
        #expect(viewModel.dateGroups[0].folderName == "My written folder title \u{2013} Shoot 1")
        #expect(viewModel.dateGroups[1].folderName == "My written folder title \u{2013} Shoot 2")

        viewModel.splitShootsIntoSubfolders = true
        #expect(viewModel.dateGroups[0].folderName == "My written folder title")
        #expect(viewModel.dateGroups[1].folderName == "My written folder title")
    }

    @Test("Capture-date scan uses an import title entered while the scan is running")
    func captureDateScanUsesLatestImportTitle() async throws {
        let defaults = AppDefaults.store
        let originalFilter = defaults.object(forKey: UserDefaultsKeys.importFileTypeFilter)
        defer {
            if let originalFilter { defaults.set(originalFilter, forKey: UserDefaultsKeys.importFileTypeFilter) }
            else { defaults.removeObject(forKey: UserDefaultsKeys.importFileTypeFilter) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportDateTitleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.jpg")
        try Data().write(to: image)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        // This title test must admit its JPEG regardless of persisted Import settings.
        viewModel.configuration.fileTypeFilter = .both
        viewModel.sourceFiles = [image]
        viewModel.configuration.importTitle = ""
        #expect(viewModel.filteredSourceFiles == [image])

        viewModel.scanCaptureDates()
        viewModel.configuration.importTitle = "Title entered during scan"

        for _ in 0..<500 where viewModel.isScanningDates {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isScanningDates)
        #expect(viewModel.dateGroups.count == 1)
        let group = try #require(viewModel.dateGroups.first)
        #expect(group.folderName.hasSuffix(" \u{2013} Title entered during scan"))
    }

    @Test("Month date grouping previews use the month folder")
    func monthDateGroupingPreviewUsesMonthFolder() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.destinationBaseURL = URL(fileURLWithPath: "/Volumes/Photos")
        viewModel.sortByDate = true
        viewModel.dateFolderGrouping = .month
        let group = ImportDateGroup(
            dateString: "2026:07:08",
            folderName: "2026-07-08",
            shootFolderName: nil,
            yearFolder: "2026",
            monthFolder: "07",
            files: [URL(fileURLWithPath: "/card/one.jpg")]
        )

        #expect(viewModel.folderPathGroupingPrefix(for: group) == "2026/07")
        #expect(viewModel.folderPathPreview(for: group) == "Photos / 2026 / 07 / 2026-07-08")
    }

    @Test("Common ancestor chooses the nearest shared import folder")
    func commonAncestorChoosesNearestSharedImportFolder() {
        let shootFolders = [
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-08/Shoot 1"),
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-08/Shoot 2"),
        ]
        let dayFolders = [
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-08"),
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-09"),
        ]
        let monthFolders = [
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-31"),
            URL(fileURLWithPath: "/Volumes/Photos/2026/08/2026-08-01"),
        ]

        #expect(ImportViewModel.commonAncestor(of: shootFolders)?.path == "/Volumes/Photos/2026/07/2026-07-08")
        #expect(ImportViewModel.commonAncestor(of: dayFolders)?.path == "/Volumes/Photos/2026/07")
        #expect(ImportViewModel.commonAncestor(of: monthFolders)?.path == "/Volumes/Photos/2026")
    }

    @Test("Import opens its reveal folder only after the directory exists")
    func importStartedFollowsRevealFolderCreation() async throws {
        let defaults = AppDefaults.store
        let preferenceKeys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys {
            originalPreferences[key] = defaults.object(forKey: key)
        }
        defer {
            for key in preferenceKeys {
                if let original = originalPreferences[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFolderHandoffTests-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("card", isDirectory: true)
        let destinationBase = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sourceFolder.appendingPathComponent("photo.jpg")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: source)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = sourceFolder
        viewModel.configuration.destinationBaseURL = destinationBase
        viewModel.configuration.importTitle = "Folder Handoff"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .skipExisting
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .off
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        viewModel.sourceFiles = [source]

        let notificationTask = Task { @MainActor () -> (URL, Bool)? in
            for await notification in NotificationCenter.default.notifications(named: .importStarted) {
                guard let folder = notification.object as? URL else { continue }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: folder.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
                return (folder, exists)
            }
            return nil
        }
        await Task.yield()

        viewModel.startImport()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            notificationTask.cancel()
        }
        let observed = await notificationTask.value
        timeoutTask.cancel()

        #expect(
            observed?.0.standardizedFileURL.path
                == viewModel.configuration.destinationFolderURL.standardizedFileURL.path
        )
        #expect(observed?.1 == true)

        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!viewModel.isImporting)
        // The test host contains the real browser notification consumer. Let its small-folder
        // scan finish before the temporary tree is removed by `defer`.
        try await Task.sleep(for: .milliseconds(500))
    }

    @Test("Dual-card import copies a matched WAV with the image conflict suffix")
    func dualCardImportKeepsMemoBesideRenamedImage() async throws {
        let defaults = AppDefaults.store
        let preferenceKeys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys { originalPreferences[key] = defaults.object(forKey: key) }
        defer {
            for key in preferenceKeys {
                if let original = originalPreferences[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCardImportTests-\(UUID().uuidString)", isDirectory: true)
        let rawCard = root.appendingPathComponent("card-1", isDirectory: true)
        let memoCard = root.appendingPathComponent("card-2", isDirectory: true)
        let destinationBase = root.appendingPathComponent("photos", isDirectory: true)
        for folder in [rawCard, memoCard, destinationBase] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = rawCard.appendingPathComponent("TRA08908.ARW")
        try Data("synthetic-primary-raw".utf8).write(to: raw)
        let image = memoCard.appendingPathComponent("TRA08908.JPG")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: image)
        let memo = memoCard.appendingPathComponent("TRA08908.WAV")
        let memoBytes = Data("sony-voice-memo-bytes".utf8)
        try memoBytes.write(to: memo)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = rawCard
        viewModel.configuration.voiceMemoSourceURL = memoCard
        viewModel.configuration.destinationBaseURL = destinationBase
        viewModel.configuration.importTitle = "Dual Card"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .renameWithSuffix
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        viewModel.sourceFiles = [raw]
        viewModel.voiceMemoSourceFiles = [image, memo]
        viewModel.voiceMemoAssociationReport = VoiceMemoAssociationReport(
            profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
            associations: [raw, image].map {
                VoiceMemoAssociation(
                    profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                    imageURL: $0,
                    memoURL: memo
                )
            },
            imagesWithoutMemo: [],
            ambiguous: [],
            orphanMemoURLs: []
        )

        let destinationFolder = viewModel.configuration.destinationFolderURL
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try jpeg.write(
            to: destinationFolder.appendingPathComponent("TRA08908.JPG")
        )

        viewModel.startImport()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        let importedImage = destinationFolder.appendingPathComponent("TRA08908-1.JPG")
        let importedMemo = destinationFolder.appendingPathComponent("TRA08908-1.WAV")
        #expect(!viewModel.isImporting)
        #expect(FileManager.default.fileExists(atPath: importedImage.path))
        #expect(try Data(contentsOf: importedMemo) == memoBytes)
        #expect(viewModel.copiedFiles == 2)
        #expect(viewModel.voiceMemoCopiedFiles == 1)
        #expect(viewModel.importSummary.contains("Imported 1 photo"))
        #expect(viewModel.importSummary.contains("voice memos 1"))

        try await Task.sleep(for: .milliseconds(500))
    }

    @Test("One-card import can keep RAW, JPEG, and their voice memo")
    func oneCardImportKeepsBothImageVariantsAndMemo() async throws {
        let defaults = AppDefaults.store
        let preferenceKeys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys { originalPreferences[key] = defaults.object(forKey: key) }
        defer {
            for key in preferenceKeys {
                if let original = originalPreferences[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneCardVoiceMemoImportTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let destinationBase = root.appendingPathComponent("photos", isDirectory: true)
        for folder in [card, destinationBase] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = card.appendingPathComponent("TRA08912.ARW")
        let jpeg = card.appendingPathComponent("TRA08912.JPG")
        let memo = card.appendingPathComponent("TRA08912.WAV")
        let rawBytes = Data("synthetic-raw-copy-fixture".utf8)
        let jpegBytes = Data("synthetic-jpeg-copy-fixture".utf8)
        let memoBytes = Data("single-card-voice-memo".utf8)
        try rawBytes.write(to: raw)
        try jpegBytes.write(to: jpeg)
        try memoBytes.write(to: memo)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = destinationBase
        viewModel.configuration.importTitle = "One Card"
        viewModel.configuration.fileTypeFilter = .both
        viewModel.configuration.conflictPolicy = .renameWithSuffix
        viewModel.configuration.createSubFolders = true
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        viewModel.sourceFiles = [raw, jpeg]
        viewModel.sourceVoiceMemoFiles = [memo]
        viewModel.voiceMemoAssociationReport = VoiceMemoAssociationReport(
            profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
            associations: [raw, jpeg].map {
                VoiceMemoAssociation(
                    profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                    imageURL: $0,
                    memoURL: memo
                )
            },
            imagesWithoutMemo: [],
            ambiguous: [],
            orphanMemoURLs: []
        )

        viewModel.startImport()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        let destination = viewModel.configuration.destinationFolderURL
        #expect(try Data(contentsOf: destination.appendingPathComponent("RAW/TRA08912.ARW")) == rawBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("RAW/TRA08912.WAV")) == memoBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("JPEG/TRA08912.JPG")) == jpegBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("JPEG/TRA08912.WAV")) == memoBytes)
        #expect(viewModel.copiedFiles == 4)
        #expect(viewModel.voiceMemoCopiedFiles == 2)

        try await Task.sleep(for: .milliseconds(500))
    }

    @Test("overwrite preflight counts both legs, cancellation writes nothing, and results persist exact counts")
    func overwritePreflightIsExactAndDurable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwritePreflightTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        for folder in [card, photos, backup] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let source = card.appendingPathComponent("photo.jpg")
        let replacement = Data("new-photo".utf8)
        let originalPrimary = Data("old-primary".utf8)
        let originalBackup = Data("old-backup".utf8)
        try replacement.write(to: source)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Overwrite Audit"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.configuration.backupDestination = BackupDestination(url: backup)
        viewModel.sortByDate = false
        viewModel.sourceFiles = [source]

        let primary = viewModel.configuration.destinationFolderURL.appendingPathComponent(source.lastPathComponent)
        let relative = try #require(ImportViewModel.relativePath(of: primary, under: photos))
        let backupFile = backup.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: primary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: backupFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalPrimary.write(to: primary)
        try originalBackup.write(to: backupFile)

        viewModel.startImport()

        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let preflight = try #require(viewModel.overwritePreflight)
        #expect(preflight.primaryCollisionCount == 1)
        #expect(preflight.backupCollisionCount == 1)
        #expect(preflight.totalCollisionCount == 2)
        #expect(preflight.primaryRoot.standardizedFileURL == photos.standardizedFileURL)
        #expect(preflight.backupRoot?.standardizedFileURL == backup.standardizedFileURL)
        #expect(viewModel.importPhase == .idle)
        #expect(try Data(contentsOf: primary) == originalPrimary)
        #expect(try Data(contentsOf: backupFile) == originalBackup)

        viewModel.cancelOverwritePreflight()
        #expect(viewModel.overwritePreflight == nil)
        #expect(try Data(contentsOf: primary) == originalPrimary)
        #expect(try Data(contentsOf: backupFile) == originalBackup)

        viewModel.startImport()
        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        viewModel.confirmOverwritePreflight()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try Data(contentsOf: primary) == replacement)
        #expect(try Data(contentsOf: backupFile) == replacement)
        #expect(viewModel.replacedFiles == 1)
        #expect(viewModel.backupReplacedFiles == 1)
        #expect(viewModel.lastCompletionEntry?.importResultCounts == ActivityImportResultCounts(
            replaced: 1,
            backupReplaced: 1,
            skipped: 0,
            renamed: 0
        ))
        let encoded = try JSONEncoder().encode(try #require(viewModel.lastCompletionEntry))
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: encoded)
        #expect(decoded.importResultCounts == viewModel.lastCompletionEntry?.importResultCounts)
    }

    @Test("overwrite confirmation is invalidated when the collision set changes")
    func overwriteConfirmationCannotBeReusedAfterCollisionChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteSignatureTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = card.appendingPathComponent("photo-1.jpg")
        let second = card.appendingPathComponent("photo-2.jpg")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Changing Set"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [first, second]

        let folder = viewModel.configuration.destinationFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("photo-1.jpg")
        try Data("existing".utf8).write(to: existing)

        viewModel.startImport()
        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.overwritePreflight?.primaryCollisionCount == 1)

        let intervening = Data("arrived-after-preflight".utf8)
        let destination = folder.appendingPathComponent("photo-2.jpg")
        try intervening.write(to: destination)

        viewModel.confirmOverwritePreflight()

        for _ in 0..<500 where viewModel.overwritePreflight?.primaryCollisionCount != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.importPhase == .idle)
        #expect(viewModel.overwritePreflight?.primaryCollisionCount == 2)
        #expect(try Data(contentsOf: destination) == intervening)
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    }

    @Test("Overwrite imports straight away when nothing would be replaced")
    func overwriteWithoutCollisionsDoesNotAsk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteNoCollisionTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = card.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Nothing To Replace"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [source]

        viewModel.startImport()
        let destination = viewModel.configuration.destinationFolderURL.appendingPathComponent("photo.jpg")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: destination.path) || viewModel.isImporting {
            #expect(viewModel.overwritePreflight == nil)
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.overwritePreflight == nil)
        #expect(try Data(contentsOf: destination) == Data("source".utf8))
        #expect(viewModel.replacedFiles == 0)
    }

    @Test("Same-named sources in one overwrite import get unique names instead of replacing each other")
    func overwriteImportKeepsSameNamedBatchFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteBatchCollisionTests-\(UUID().uuidString)", isDirectory: true)
        let firstCard = root.appendingPathComponent("card-1", isDirectory: true)
        let secondCard = root.appendingPathComponent("card-2", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        for folder in [firstCard, secondCard, photos] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let first = firstCard.appendingPathComponent("photo.jpg")
        let second = secondCard.appendingPathComponent("photo.jpg")
        let firstBytes = Data("first".utf8)
        try firstBytes.write(to: first)
        let secondBytes = Data("second".utf8)
        try secondBytes.write(to: second)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = firstCard
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Same Names"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [first, second]

        let destinationFolder = viewModel.configuration.destinationFolderURL
        // Nothing on disk would be replaced, so Overwrite starts without asking.
        viewModel.startImport()
        for _ in 0..<500 where viewModel.isImporting || viewModel.lastCompletionEntry == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try Data(contentsOf: destinationFolder.appendingPathComponent("photo.jpg")) == firstBytes)
        #expect(try Data(contentsOf: destinationFolder.appendingPathComponent("photo-1.jpg")) == secondBytes)
        #expect(viewModel.replacedFiles == 0)
        #expect(viewModel.renamedFiles == 1)
        #expect(viewModel.lastCompletionEntry?.importResultCounts?.replaced == 0)
        #expect(viewModel.lastCompletionEntry?.importResultCounts?.renamed == 1)
    }

    @Test("Reset rejects a late duplicate and collision preflight result")
    func resetRejectsStalePreflightResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleImportPreflightTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = card.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let gate = ImportPreflightTestGate()
        defer { gate.release() }
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in
                gate.suspend()
                return [:]
            }
        )
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            preflightService: service
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Stale Preflight"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = true
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [source]

        viewModel.startImport()
        let preflightDidStart = await gate.waitUntilStarted()
        #expect(preflightDidStart)
        viewModel.reset()
        gate.release()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(viewModel.importPhase == .idle)
        #expect(viewModel.overwritePreflight == nil)
        #expect(viewModel.sourceFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: photos.appendingPathComponent("Stale Preflight").path))
    }

    @Test("Reset rejects late voice-memo bundle planning evidence")
    func resetRejectsStaleBundlePlanningEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleImportBundlePlanningTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = card.appendingPathComponent("TRA00003.JPG")
        let memo = card.appendingPathComponent("TRA00003.WAV")
        try Data("image".utf8).write(to: image)
        try Data("memo".utf8).write(to: memo)

        let gate = ImportPreflightTestGate()
        defer { gate.release() }
        let service = ImportPreflightService(fileExists: { _ in
            gate.suspend()
            return false
        })
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            preflightService: service
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Stale Bundle Planning"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .renameWithSuffix
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [image]
        viewModel.sourceVoiceMemoFiles = [memo]
        viewModel.voiceMemoAssociationReport = VoiceMemoAssociationReport(
            profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
            associations: [VoiceMemoAssociation(
                profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                imageURL: image,
                memoURL: memo
            )],
            imagesWithoutMemo: [],
            ambiguous: [],
            orphanMemoURLs: []
        )

        viewModel.startImport()
        let planningDidStart = await gate.waitUntilStarted()
        #expect(planningDidStart)
        viewModel.reset()
        gate.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(viewModel.importPhase == .idle)
        #expect(viewModel.sourceFiles.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: photos.appendingPathComponent("Stale Bundle Planning").path
        ))
    }
}

@Suite("Safe import paths")
struct SafeImportPathTests {
    @Test("folder components reject separators and traversal")
    func rejectsUnsafeComponents() throws {
        #expect(throws: SafePathComponent.ValidationError.self) {
            try SafePathComponent.validate("../Outside")
        }
        #expect(throws: SafePathComponent.ValidationError.self) {
            try SafePathComponent.validate("nested/folder")
        }
        #expect(throws: SafePathComponent.ValidationError.self) {
            try SafePathComponent.validate("..")
        }
        #expect(try SafePathComponent.validate(" Cup Final ") == "Cup Final")
    }

    @Test("containment compares standardized path components")
    func containmentUsesCanonicalComponents() {
        let root = URL(fileURLWithPath: "/tmp/import-root", isDirectory: true)
        #expect(SafePathComponent.isContained(root.appendingPathComponent("day/photo.jpg"), in: root))
        #expect(!SafePathComponent.isContained(root.appendingPathComponent("../outside.jpg"), in: root))
    }

    @Test("containment rejects an existing symlink that escapes the root")
    func containmentResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafePathTests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = destination.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!SafePathComponent.isContained(link.appendingPathComponent("photo.jpg"), in: destination))
    }

    @Test("serialized containment returns immutable escape evidence off the main actor")
    @MainActor
    func serializedContainmentRunsOffMainActor() async {
        let probe = SafePathContainmentProbe()
        let service = SafePathContainmentService(contains: probe.contains)
        let root = URL(fileURLWithPath: "/virtual/import", isDirectory: true)
        let request = SafePathContainmentRequest(
            requestID: UUID(),
            root: root,
            candidates: [
                root.appendingPathComponent("one.jpg"),
                root.appendingPathComponent("escape.jpg"),
                root.appendingPathComponent("unreached.jpg"),
            ]
        )

        let result = await service.inspect(request)
        guard case .complete(let evidence) = result else {
            Issue.record("Expected complete escape evidence")
            return
        }

        #expect(evidence.requestID == request.requestID)
        #expect(evidence.root == root)
        #expect(evidence.requestedCandidateCount == 3)
        #expect(evidence.checkedCandidateCount == 2)
        #expect(evidence.escapingCandidate == request.candidates[1])
        #expect(probe.callCount == 2)
        #expect(!probe.observedMainThread)
    }

    @Test("pre-cancelled containment performs no filesystem projection")
    func preCancelledContainmentPerformsNoProbe() async {
        let probe = SafePathContainmentProbe()
        let service = SafePathContainmentService(contains: probe.contains)
        let request = SafePathContainmentRequest(
            requestID: UUID(),
            root: URL(fileURLWithPath: "/virtual/import", isDirectory: true),
            candidates: [URL(fileURLWithPath: "/virtual/import/one.jpg")]
        )

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.inspect(request)
        }.value

        guard case .cancelled(let evidence) = result else {
            Issue.record("Expected cancelled evidence")
            return
        }
        #expect(evidence.checkedCandidateCount == 0)
        #expect(evidence.escapingCandidate == nil)
        #expect(probe.callCount == 0)
    }

    @Test("cancellation after a non-preemptible containment probe excludes that probe")
    func postProbeCancellationReturnsExactPrefix() async {
        let probe = SafePathContainmentProbe(blockFirstCall: true)
        let service = SafePathContainmentService(contains: probe.contains)
        let root = URL(fileURLWithPath: "/virtual/import", isDirectory: true)
        let request = SafePathContainmentRequest(
            requestID: UUID(),
            root: root,
            candidates: [root.appendingPathComponent("one.jpg")]
        )
        let task = Task { await service.inspect(request) }
        #expect(await probe.waitUntilBlocked())
        task.cancel()
        probe.release()

        guard case .cancelled(let evidence) = await task.value else {
            Issue.record("Expected cancelled evidence")
            return
        }
        #expect(evidence.checkedCandidateCount == 0)
        #expect(evidence.escapingCandidate == nil)
        #expect(probe.callCount == 1)
    }

    @Test("Import and Browser route containment through the serialized boundary")
    func ownerSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let importSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/ImportViewModel.swift"
            ),
            encoding: .utf8
        )
        let browserSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/BrowserViewModel.swift"
            ),
            encoding: .utf8
        )

        #expect(importSource.contains("await pathContainmentService.inspect("))
        #expect(importSource.contains("let plannedPrimaryDestinations = primaryDestinations"))
        #expect(importSource.contains("candidates: plannedPrimaryDestinations"))
        // Every resolved exposure destination (images and voice memos) is re-checked after
        // preflight chose the final shared suffix.
        #expect(importSource.contains("candidates: resolvedDestinations"))
        #expect(!importSource.contains("SafePathComponent.isContained(primaryURL"))
        #expect(!importSource.contains("SafePathComponent.isContained(bundle.memo"))
        #expect(importSource.contains("canonicalVoiceMemoImageURLBySource[source]"))
        #expect(!importSource.contains("selectedSourceFiles.map(VoiceMemoAssociationService.canonicalURL)"))
        #expect(!importSource.contains("let canonicalImage = VoiceMemoAssociationService.canonicalURL(file)"))

        let renameStart = try #require(browserSource.range(of: "func renamePendingSubfolder()"))
        let renameSuffix = browserSource[renameStart.lowerBound...]
        let renameEnd = try #require(renameSuffix.range(of: "// MARK: - New Subfolder"))
        let renameSource = renameSuffix[..<renameEnd.lowerBound]
        #expect(renameSource.contains("await pathContainmentService.inspect("))
        #expect(!renameSource.contains("SafePathComponent.isContained("))
    }
}

private nonisolated final class SafePathContainmentProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockFirstCall: Bool
    private var storedCallCount = 0
    private var storedObservedMainThread = false
    private var blocked = false
    private var released = false

    init(blockFirstCall: Bool = false) {
        self.blockFirstCall = blockFirstCall
    }

    var callCount: Int {
        condition.withLock { storedCallCount }
    }

    var observedMainThread: Bool {
        condition.withLock { storedObservedMainThread }
    }

    func contains(_ candidate: URL, _ root: URL) -> Bool {
        condition.lock()
        storedCallCount += 1
        storedObservedMainThread = storedObservedMainThread || Thread.isMainThread
        if blockFirstCall, storedCallCount == 1 {
            blocked = true
            condition.broadcast()
            while !released {
                if !condition.waitBounded() { break }
            }
        }
        condition.unlock()
        return candidate.lastPathComponent != "escape.jpg"
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<300 {
            let isBlocked = condition.withLock { blocked }
            if isBlocked { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

@Suite("Import copy transaction", .serialized)
struct ImportCopyServiceTests {
    @Test("overwrite keeps the existing destination when the source cannot be opened")
    func overwritePreservesExistingFileOnSourceFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingSource = root.appendingPathComponent("missing.jpg")
        let destination = root.appendingPathComponent("existing.jpg")
        let original = Data("existing-good-copy".utf8)
        try original.write(to: destination)

        let service = ImportCopyService()
        let results = try await service.run(
            jobs: [.init(source: missingSource, desiredPrimaryDest: destination, desiredBackupDest: nil)],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results.count == 1)
        #expect(try Data(contentsOf: destination) == original)
        if case .failed = results[0].primary {
            // Expected.
        } else {
            Issue.record("A missing source must fail without replacing the destination")
        }
    }

    @Test("verified overwrite atomically promotes the replacement and leaves no staging file")
    func verifiedOverwritePromotesReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.jpg")
        let destination = root.appendingPathComponent("destination.jpg")
        let replacement = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        try replacement.write(to: source)
        try Data("old".utf8).write(to: destination)

        let service = ImportCopyService()
        let results = try await service.run(
            jobs: [.init(source: source, desiredPrimaryDest: destination, desiredBackupDest: nil)],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results.first?.primaryVerification == .verified)
        #expect(try Data(contentsOf: destination) == replacement)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test("source and destination identity is rejected without touching the file")
    func sameSourceAndDestinationIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("photo.jpg")
        let contents = Data("only-copy".utf8)
        try contents.write(to: file)

        let service = ImportCopyService()
        let results = try await service.run(
            jobs: [.init(source: file, desiredPrimaryDest: file, desiredBackupDest: nil)],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(try Data(contentsOf: file) == contents)
        if case .failed = results[0].primary {
            // Expected.
        } else {
            Issue.record("Copying a file onto itself must be rejected")
        }
    }

    @Test("the primary is announced before it goes live, ahead of its backup leg and progress")
    func announcesPrimaryBeforePlacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ARW")
        let primary = root.appendingPathComponent("primary/DSC0001.ARW")
        let backup = root.appendingPathComponent("backup/DSC0001.ARW")
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw bytes".utf8).write(to: source)
        let job = ImportCopyService.CopyJob(source: source, desiredPrimaryDest: primary, desiredBackupDest: backup)
        let unfinished = ImportUnfinishedCopies()
        let events = ImportPlacementEventLog()

        _ = try await ImportCopyService().run(
            jobs: [job],
            conflictPolicy: .skipExisting,
            verificationMode: .on,
            verifyBackup: true,
            willPlacePrimary: { placedJob, url in
                events.append("place exists=\(FileManager.default.fileExists(atPath: url.path))")
                unfinished.insert(url, for: placedJob.id)
            },
            progress: { result in
                events.append("progress backup=\(FileManager.default.fileExists(atPath: backup.path))")
                #expect(unfinished.destinations == [primary.standardizedFileURL])
                unfinished.remove(jobID: result.id)
            }
        )

        #expect(events.entries == ["place exists=false", "progress backup=true"])
        #expect(unfinished.destinations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: primary.path))
    }

    @Test("a companion is skipped when its image copy fails")
    func companionRequiresSuccessfulImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingImage = root.appendingPathComponent("missing.ARW")
        let memo = root.appendingPathComponent("source.WAV")
        let imageDestination = root.appendingPathComponent("destination.ARW")
        let memoDestination = root.appendingPathComponent("destination.WAV")
        try Data("memo".utf8).write(to: memo)
        let imageJob = ImportCopyService.CopyJob(
            source: missingImage,
            desiredPrimaryDest: imageDestination,
            desiredBackupDest: nil
        )
        let memoJob = ImportCopyService.CopyJob(
            source: memo,
            desiredPrimaryDest: memoDestination,
            desiredBackupDest: nil,
            prerequisiteJobID: imageJob.id
        )

        let results = try await ImportCopyService().run(
            jobs: [imageJob, memoJob],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results.count == 2)
        if case .failed = results[0].primary {
            // Expected.
        } else {
            Issue.record("The missing image source should fail")
        }
        #expect(results[1].primary == .skipped(.associatedImageFailed))
        #expect(!FileManager.default.fileExists(atPath: memoDestination.path))
    }
}

private nonisolated final class ImportPlacementEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var entries: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
}

/// Records embedded writes so tests can see which files the import routed into the file itself.
private nonisolated final class ImportRecordingWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var fields: [MetadataFieldKey: String] = [:]
    private let failingNamePrefix: String?

    init(failingNamePrefix: String? = nil) {
        self.failingNamePrefix = failingNamePrefix
    }

    var writtenURLs: [URL] { lock.withLock { urls } }
    var lastFields: [MetadataFieldKey: String] { lock.withLock { fields } }

    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        lock.withLock {
            self.urls.append(contentsOf: urls)
            self.fields = fields
        }
        if let failingNamePrefix, urls.contains(where: { $0.lastPathComponent.hasPrefix(failingNamePrefix) }) {
            throw NSError(domain: "ImportRecordingWriteEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Injected write failure"])
        }
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}

/// Holds every metadata write until released (bounded, so a failing test cannot hang).
private nonisolated final class ImportGatedWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }
    func release() { lock.withLock { released = true } }

    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        for _ in 0..<1000 where !lock.withLock({ released }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        lock.withLock { writes += 1 }
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}

private nonisolated final class ImportProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@Suite("Import workflow regressions", .serialized)
@MainActor
struct ImportWorkflowRegressionTests {
    private static let preferenceKeys = [
        UserDefaultsKeys.importFileTypeFilter,
        UserDefaultsKeys.importConflictPolicy,
        UserDefaultsKeys.importCreateSubFolders,
        UserDefaultsKeys.importVerificationMode,
        UserDefaultsKeys.importSkipPreviouslyImported,
        UserDefaultsKeys.importSortByDate,
        UserDefaultsKeys.metadataWritePreset,
    ]

    /// Runs `body` and restores every import/preset default it may have changed.
    private func withRestoredDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = AppDefaults.store
        var originals: [String: Any] = [:]
        for key in Self.preferenceKeys { originals[key] = defaults.object(forKey: key) }
        defer {
            for key in Self.preferenceKeys {
                if let original = originals[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try await body()
    }

    private func writeJPEG(to url: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
    }

    private func waitForCompletion(_ viewModel: ImportViewModel) async throws {
        for _ in 0..<1000 where viewModel.isImporting || viewModel.lastCompletionEntry == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Reopening the import sheet keeps the chosen destination root")
    func resetKeepsDestination() async {
        await withRestoredDefaults {
            let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            let destination = URL(fileURLWithPath: "/Volumes/Archive/Photos", isDirectory: true)
            viewModel.configuration.destinationBaseURL = destination
            viewModel.configuration.importTitle = "Old title"
            viewModel.prepareForNewSession()
            #expect(viewModel.configuration.destinationBaseURL == destination)
            #expect(viewModel.configuration.importTitle.isEmpty)
            viewModel.reset()
            #expect(viewModel.configuration.destinationBaseURL == destination)
        }
    }

    @Test("Batch planning gives same-named sources unique names and keeps memos on the image suffix")
    func batchNamePlanning() {
        var planner = ImportBatchNamePlanner()
        let folder = URL(fileURLWithPath: "/photos/2026-10-24 – Cup", isDirectory: true)
        let bodyA = URL(fileURLWithPath: "/cardA/DCIM/100MSDCF")
        let bodyB = URL(fileURLWithPath: "/cardB/DCIM/100MSDCF")
        let memoB = bodyB.appendingPathComponent("DSC00001.WAV")

        let rawA = planner.plan(source: bodyA.appendingPathComponent("DSC00001.ARW"), folder: folder,
                                exposureFolder: folder, memoSource: nil, memoExtension: nil)
        let rawB = planner.plan(source: bodyB.appendingPathComponent("DSC00001.ARW"), folder: folder,
                                exposureFolder: folder, memoSource: memoB, memoExtension: "WAV")
        // Case-insensitive volumes: a differently-cased twin from another folder still collides.
        let twin = planner.plan(source: URL(fileURLWithPath: "/cardC/dsc00001.arw"), folder: folder,
                                exposureFolder: folder, memoSource: nil, memoExtension: nil)
        let jpegB = planner.plan(source: bodyB.appendingPathComponent("DSC00001.JPG"), folder: folder,
                                 exposureFolder: folder, memoSource: memoB, memoExtension: "WAV")
        let jpegA = planner.plan(source: bodyA.appendingPathComponent("DSC00001.JPG"), folder: folder,
                                 exposureFolder: folder, memoSource: nil, memoExtension: nil)

        #expect(rawA == .init(image: folder.appendingPathComponent("DSC00001.ARW"), memo: nil, wasRenamed: false))
        #expect(rawB.image.lastPathComponent == "DSC00001-1.ARW")
        #expect(rawB.memo?.lastPathComponent == "DSC00001-1.WAV")
        #expect(rawB.wasRenamed)
        #expect(twin.image.lastPathComponent == "dsc00001-2.arw")
        // Body B's JPEG follows its RAW's suffix and shares that exposure's memo name.
        #expect(jpegB.image.lastPathComponent == "DSC00001-1.JPG")
        #expect(jpegB.memo?.lastPathComponent == "DSC00001-1.WAV")
        // Body A's JPEG pairs with body A's unsuffixed RAW.
        #expect(jpegA.image.lastPathComponent == "DSC00001.JPG")
        #expect(!jpegA.wasRenamed)
    }

    @Test("Batch planning never pairs one exposure's RAW with another exposure's JPEG")
    func batchNamePlanningKeepsPairsTogether() {
        var planner = ImportBatchNamePlanner()
        let folder = URL(fileURLWithPath: "/photos/2026-10-24", isDirectory: true)
        let jpegOnlyBody = URL(fileURLWithPath: "/cardA/DCIM/100CANON")
        let rawPlusJPEGBody = URL(fileURLWithPath: "/cardB/DCIM/100CANON")

        let jpegA = planner.plan(source: jpegOnlyBody.appendingPathComponent("IMG_0001.JPG"), folder: folder,
                                 exposureFolder: folder, memoSource: nil, memoExtension: nil)
        let rawB = planner.plan(source: rawPlusJPEGBody.appendingPathComponent("IMG_0001.CR3"), folder: folder,
                                exposureFolder: folder, memoSource: nil, memoExtension: nil)
        let jpegB = planner.plan(source: rawPlusJPEGBody.appendingPathComponent("IMG_0001.JPG"), folder: folder,
                                 exposureFolder: folder, memoSource: nil, memoExtension: nil)

        #expect(jpegA.image.lastPathComponent == "IMG_0001.JPG")
        // The free name IMG_0001.CR3 would sit beside the other body's JPEG; take a new stem.
        #expect(rawB.image.lastPathComponent == "IMG_0001-1.CR3")
        #expect(jpegB.image.lastPathComponent == "IMG_0001-1.JPG")
    }

    @Test("Import brings a photo's XMP sidecar along under its final name without replacing one")
    func importCopiesXMPSidecars() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSidecarCopy-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = card.appendingPathComponent("IMG_0001.CR3")
        let jpeg = card.appendingPathComponent("IMG_0001.JPG")
        let other = card.appendingPathComponent("IMG_0002.CR3")
        for url in [raw, jpeg, other] { try Data("image".utf8).write(to: url) }
        try Data("<x:xmpmeta>edits</x:xmpmeta>".utf8).write(to: card.appendingPathComponent("IMG_0001.xmp"))
        try Data("<x:xmpmeta>card</x:xmpmeta>".utf8).write(to: card.appendingPathComponent("IMG_0002.xmp"))
        // A sidecar already at the destination belongs to an earlier photo and must stay.
        try Data("<x:xmpmeta>existing</x:xmpmeta>".utf8).write(to: photos.appendingPathComponent("IMG_0002.xmp"))

        func copied(_ source: URL, to name: String) throws -> ImportCopyService.CopyResult {
            let destination = photos.appendingPathComponent(name)
            try Data("image".utf8).write(to: destination)
            return ImportCopyService.CopyResult(
                id: UUID(), source: source,
                primary: .copied(destination, wasRenamed: name != source.lastPathComponent,
                                 wasReplaced: false, hash: Data()),
                primaryVerification: .skipped, backup: nil, backupVerification: nil)
        }
        let results = [
            try copied(raw, to: "IMG_0001-1.CR3"),
            try copied(jpeg, to: "IMG_0001-1.JPG"),
            try copied(other, to: "IMG_0002.CR3"),
        ]

        let failures = ImportViewModel.copyXMPSidecars(for: results, imageSources: [raw, jpeg, other])

        #expect(failures.isEmpty)
        #expect(try String(contentsOf: photos.appendingPathComponent("IMG_0001-1.xmp"), encoding: .utf8)
            == "<x:xmpmeta>edits</x:xmpmeta>")
        #expect(try String(contentsOf: photos.appendingPathComponent("IMG_0002.xmp"), encoding: .utf8)
            == "<x:xmpmeta>existing</x:xmpmeta>")
        #expect(!FileManager.default.fileExists(atPath: photos.appendingPathComponent("IMG_0001.xmp").path))
    }

    @Test("Skip Existing imports both same-named sources from two cards")
    func skipExistingKeepsSameNamedBatchFiles() async throws {
        try await withRestoredDefaults {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImportSameNameSkip-\(UUID().uuidString)", isDirectory: true)
            let cardA = root.appendingPathComponent("card-a", isDirectory: true)
            let cardB = root.appendingPathComponent("card-b", isDirectory: true)
            let photos = root.appendingPathComponent("photos", isDirectory: true)
            for folder in [cardA, cardB, photos] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let first = cardA.appendingPathComponent("photo.jpg")
            let second = cardB.appendingPathComponent("photo.jpg")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)

            let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            viewModel.configuration.sourceURL = cardA
            viewModel.configuration.destinationBaseURL = photos
            viewModel.configuration.importTitle = "Two Bodies"
            viewModel.configuration.fileTypeFilter = .jpegOnly
            viewModel.configuration.conflictPolicy = .skipExisting
            viewModel.configuration.createSubFolders = false
            viewModel.configuration.verificationMode = .on
            viewModel.configuration.skipPreviouslyImported = false
            viewModel.configuration.applyMetadata = false
            viewModel.sortByDate = false
            viewModel.sourceFiles = [first, second]
            let folder = viewModel.configuration.destinationFolderURL

            viewModel.startImport()
            try await waitForCompletion(viewModel)

            #expect(try Data(contentsOf: folder.appendingPathComponent("photo.jpg")) == Data("first".utf8))
            #expect(try Data(contentsOf: folder.appendingPathComponent("photo-1.jpg")) == Data("second".utf8))
            #expect(viewModel.copiedFiles == 2)
            #expect(viewModel.skippedFiles == 0)
            #expect(viewModel.lastCompletionEntry?.isClean == true)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test("Skipped files are not failures; backup and metadata failures are")
    func completionCountsAndStatuses() throws {
        let skippedOnly = ActivityEntry(
            kind: .importJob, date: Date(), title: nil, successCount: 8, totalCount: 10,
            verificationEnabled: true,
            importResultCounts: ActivityImportResultCounts(replaced: 0, backupReplaced: 0, skipped: 2, renamed: 0),
            files: []
        )
        #expect(skippedOnly.failureCount == 0)
        #expect(skippedOnly.isClean)
        #expect(skippedOnly.summary == "Import of 8 files completed with copy verification (2 skipped)")

        let deadBackup = ActivityEntry(
            kind: .importJob, date: Date(), title: nil, successCount: 10, totalCount: 10,
            verificationEnabled: true,
            importResultCounts: ActivityImportResultCounts(
                replaced: 0, backupReplaced: 0, skipped: 0, renamed: 0, backupFailed: 10, metadataFailed: 1
            ),
            files: []
        )
        #expect(!deadBackup.isClean)
        #expect(!deadBackup.summary.contains("with copy verification"))
        #expect(deadBackup.summary.contains("backup failed for 10"))
        #expect(deadBackup.summary.contains("metadata failed for 1"))

        let stopped = ActivityEntry(
            kind: .importJob, date: Date(), title: nil, successCount: 3, totalCount: 10,
            importResultCounts: ActivityImportResultCounts(replaced: 0, backupReplaced: 0, skipped: 0, renamed: 0),
            persistenceError: "Disk full", files: []
        )
        #expect(!stopped.isClean)
        #expect(stopped.summary.contains("stopped early"))

        // History written before the new counters existed still decodes.
        let legacy = Data(#"{"replaced":1,"backupReplaced":0,"skipped":2,"renamed":3}"#.utf8)
        #expect(try JSONDecoder().decode(ActivityImportResultCounts.self, from: legacy)
            == ActivityImportResultCounts(replaced: 1, backupReplaced: 0, skipped: 2, renamed: 3))
    }

    @Test("Import template applies Extended Description and Job ID")
    func templateExtendedDescriptionAndJobID() {
        let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        viewModel.applyTemplate(MetadataTemplate(name: "Desk", fields: [
            TemplateField(fieldKey: "extendedDescription", templateValue: "Long caption"),
            TemplateField(fieldKey: "jobId", templateValue: "JOB-42"),
        ]))
        #expect(viewModel.configuration.metadata.extendedDescription == "Long caption")
        #expect(viewModel.configuration.metadata.jobId == "JOB-42")
    }

    @Test("Import templates replace, fill only empty fields, or append")
    func templateApplyModes() {
        let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        let template = MetadataTemplate(name: "Desk", fields: [
            TemplateField(fieldKey: "description", templateValue: "Template caption"),
            TemplateField(fieldKey: "city", templateValue: "Oslo"),
            TemplateField(fieldKey: "keywords", templateValue: "sport, football"),
            TemplateField(fieldKey: "credit", templateValue: ""),
        ])
        func reset() {
            viewModel.configuration.metadata = IPTCMetadata()
            viewModel.configuration.metadata.description = "Typed caption"
            viewModel.configuration.metadata.keywords = ["football"]
            viewModel.configuration.metadata.credit = "NTB"
        }

        reset()
        viewModel.applyTemplate(template)
        #expect(viewModel.configuration.metadata.description == "Template caption")
        #expect(viewModel.configuration.metadata.city == "Oslo")
        #expect(viewModel.configuration.metadata.keywords == ["sport", "football"])
        #expect(viewModel.configuration.metadata.credit == "")

        reset()
        viewModel.applyTemplate(template, mode: .fillEmpty)
        #expect(viewModel.configuration.metadata.description == "Typed caption")
        #expect(viewModel.configuration.metadata.city == "Oslo")
        #expect(viewModel.configuration.metadata.keywords == ["football"])
        #expect(viewModel.configuration.metadata.credit == "NTB")

        reset()
        viewModel.applyTemplate(template, mode: .append)
        #expect(viewModel.configuration.metadata.description == "Typed caption Template caption")
        #expect(viewModel.configuration.metadata.city == "Oslo")
        #expect(viewModel.configuration.metadata.keywords == ["football", "sport"])
        #expect(viewModel.configuration.metadata.credit == "NTB")
    }

    @Test("Template mode follows the modifier keys: Option fills empty fields, Shift appends")
    func templateApplyModeModifiers() {
        #expect(TemplateApplyMode.from(modifiers: []) == .replace)
        #expect(TemplateApplyMode.from(modifiers: .option) == .fillEmpty)
        #expect(TemplateApplyMode.from(modifiers: .shift) == .append)
        #expect(TemplateApplyMode.from(modifiers: .command) == .replace)
    }

    @Test("A second card's copy of a first-card file is found by name, size and content")
    func crossSourceDuplicateDetection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossSourceDuplicateTests-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("card-1", isDirectory: true)
        let second = root.appendingPathComponent("card-2", isDirectory: true)
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var large = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        try large.write(to: first.appendingPathComponent("DSC0001.ARW"))
        try large.write(to: second.appendingPathComponent("dsc0001.arw"))
        // Same name and size, differing only in the last byte.
        try large.write(to: first.appendingPathComponent("DSC0002.ARW"))
        large[large.count - 1] ^= 0xFF
        try large.write(to: second.appendingPathComponent("DSC0002.ARW"))
        // Same content under a different name is a different photo for import purposes.
        try Data("small".utf8).write(to: first.appendingPathComponent("DSC0003.JPG"))
        try Data("small".utf8).write(to: second.appendingPathComponent("DSC0004.JPG"))
        // Same name, different size.
        try Data("small".utf8).write(to: first.appendingPathComponent("DSC0005.JPG"))
        try Data("smaller".utf8).write(to: second.appendingPathComponent("DSC0005.JPG"))
        try Data("memo".utf8).write(to: first.appendingPathComponent("DSC0001.WAV"))
        try Data("memo".utf8).write(to: second.appendingPathComponent("DSC0001.WAV"))

        func files(_ folder: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        let duplicates = await ImportCrossSourceDuplicateDetector.duplicates(
            companionFiles: try files(second),
            primaryFiles: try files(first),
            primaryRoot: nil,
            companionRoot: nil
        )
        #expect(duplicates.map { Set($0.map(\.lastPathComponent)) } == ["dsc0001.arw", "DSC0001.WAV"])

        let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        let raw = first.appendingPathComponent("DSC0001.ARW")
        let copy = second.appendingPathComponent("dsc0001.arw")
        let other = second.appendingPathComponent("DSC0002.ARW")
        viewModel.sourceFiles = [raw]
        viewModel.voiceMemoSourceFiles = [copy, other]
        #expect(viewModel.allSourceImages.count == 3)
        viewModel.crossSourceDuplicateFiles = [copy]
        #expect(viewModel.allSourceImages.map(\.lastPathComponent) == ["DSC0001.ARW", "DSC0002.ARW"])
        #expect(viewModel.crossSourceDuplicatesNotice != nil)
    }

    @Test("Write preset routes RAW and C2PA to sidecars under Professional, probing C2PA only when it matters")
    func presetWriteModes() async {
        await withRestoredDefaults {
            let probes = ImportProbeCounter()
            let detector: @Sendable (URL) async -> Bool = { url in
                probes.increment()
                return url.lastPathComponent.hasPrefix("C2PA")
            }
            AppDefaults.store.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            let professional = ImportMetadataWriteModes.current
            #expect(await professional.mode(for: URL(fileURLWithPath: "/p/DSC1.ARW"), hasC2PA: detector) == .writeToXMPSidecar)
            #expect(probes.count == 0)
            #expect(await professional.mode(for: URL(fileURLWithPath: "/p/C2PA_1.JPG"), hasC2PA: detector) == .writeToXMPSidecar)
            #expect(await professional.mode(for: URL(fileURLWithPath: "/p/PLAIN.JPG"), hasC2PA: detector) == .writeToFile)

            AppDefaults.store.set(MetadataWritePreset.simple.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            let simple = ImportMetadataWriteModes.current
            let before = probes.count
            #expect(await simple.mode(for: URL(fileURLWithPath: "/p/C2PA_1.JPG"), hasC2PA: detector) == .writeToFile)
            #expect(await simple.mode(for: URL(fileURLWithPath: "/p/DSC1.ARW"), hasC2PA: detector) == .writeToXMPSidecar)
            #expect(probes.count == before)
        }
    }

    @Test("Import metadata honors the write preset and one failing file doesn't stop the rest")
    func importMetadataRoutingAndPerFileFailures() async throws {
        try await withRestoredDefaults {
            AppDefaults.store.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImportPresetRouting-\(UUID().uuidString)", isDirectory: true)
            let card = root.appendingPathComponent("card", isDirectory: true)
            let photos = root.appendingPathComponent("photos", isDirectory: true)
            for folder in [card, photos] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }

            let failing = card.appendingPathComponent("A_FAIL.JPG")
            let c2pa = card.appendingPathComponent("C2PA_1.JPG")
            let plain = card.appendingPathComponent("PLAIN_1.JPG")
            let raw = card.appendingPathComponent("RAW_1.ARW")
            for jpeg in [failing, c2pa, plain] { try writeJPEG(to: jpeg) }
            try Data("synthetic-raw".utf8).write(to: raw)

            let writer = ImportRecordingWriteEngine(failingNamePrefix: "A_FAIL")
            let viewModel = ImportViewModel(
                readService: SwiftExifReadService(),
                writeEngine: writer,
                c2paDetector: { $0.lastPathComponent.hasPrefix("C2PA") }
            )
            viewModel.configuration.sourceURL = card
            viewModel.configuration.destinationBaseURL = photos
            viewModel.configuration.importTitle = "Preset Routing"
            viewModel.configuration.fileTypeFilter = .both
            viewModel.configuration.conflictPolicy = .renameWithSuffix
            viewModel.configuration.createSubFolders = false
            viewModel.configuration.verificationMode = .on
            viewModel.configuration.skipPreviouslyImported = false
            viewModel.configuration.applyMetadata = true
            viewModel.configuration.metadata.jobId = "JOB-7"
            viewModel.sortByDate = false
            viewModel.sourceFiles = [failing, c2pa, plain, raw]
            let folder = viewModel.configuration.destinationFolderURL

            viewModel.startImport()
            try await waitForCompletion(viewModel)

            let sidecars = XMPSidecarService()
            let embedded = Set(writer.writtenURLs.map(\.lastPathComponent))
            #expect(embedded == ["A_FAIL.JPG", "PLAIN_1.JPG"])
            #expect(writer.lastFields[.transmissionReference] == "JOB-7")
            #expect(sidecars.sidecarExists(for: folder.appendingPathComponent("RAW_1.ARW")))
            #expect(sidecars.sidecarExists(for: folder.appendingPathComponent("C2PA_1.JPG")))
            #expect(!sidecars.sidecarExists(for: folder.appendingPathComponent("PLAIN_1.JPG")))
            #expect(sidecars.loadSidecar(for: folder.appendingPathComponent("C2PA_1.JPG"))?.jobId == "JOB-7")
            // The RAW container itself is never rewritten.
            #expect(try Data(contentsOf: folder.appendingPathComponent("RAW_1.ARW")) == Data("synthetic-raw".utf8))

            #expect(viewModel.importPhase == .complete)
            #expect(viewModel.metadataProcessedFiles == 4)
            #expect(viewModel.metadataFailedFiles == 1)
            #expect(viewModel.failureRecords.contains { $0.kind == .metadataFailed && $0.source == failing })
            let entry = try #require(viewModel.lastCompletionEntry)
            #expect(!entry.isClean)
            #expect(entry.importResultCounts?.metadataFailed == 1)
            #expect(entry.summary.contains("metadata failed for 1"))
            #expect(entry.files.first { $0.fileName == "A_FAIL.JPG" }?.statusDetail?.contains("Metadata not written") == true)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test("Unsupported card files are announced instead of silently dropped")
    func ignoredFilesNotice() {
        #expect(ImportViewModel.ignoredFilesNotice(for: []) == nil)
        let notice = ImportViewModel.ignoredFilesNotice(for: [
            URL(fileURLWithPath: "/card/C0001.MP4"),
            URL(fileURLWithPath: "/card/DSC1.xmp"),
        ])
        #expect(notice == "2 other files won’t be imported (videos, sidecars).")
    }

    @Test("Re-scanning capture dates keeps unchecked and renamed date folders")
    func rescanPreservesDateGroupChoices() async throws {
        try await withRestoredDefaults {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImportRescanChoices-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let image = root.appendingPathComponent("photo.jpg")
            try writeJPEG(to: image)

            let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            viewModel.configuration.fileTypeFilter = .both
            viewModel.sortByDate = true
            viewModel.sourceFiles = [image]
            viewModel.scanCaptureDates()
            for _ in 0..<500 where viewModel.isScanningDates {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(viewModel.dateGroups.count == 1)
            viewModel.dateGroups[0].isIncluded = false
            viewModel.dateGroups[0].folderName = "My Folder"
            #expect(viewModel.selectedSourceFiles.isEmpty)

            viewModel.scanCaptureDates()
            for _ in 0..<500 where viewModel.isScanningDates {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(viewModel.dateGroups.first?.isIncluded == false)
            #expect(viewModel.dateGroups.first?.folderName == "My Folder")
        }
    }
}

@Suite("Import data safety", .serialized)
@MainActor
struct ImportDataSafetyTests {
    private static let preferenceKeys = [
        UserDefaultsKeys.importFileTypeFilter,
        UserDefaultsKeys.importConflictPolicy,
        UserDefaultsKeys.importCreateSubFolders,
        UserDefaultsKeys.importVerificationMode,
        UserDefaultsKeys.importSkipPreviouslyImported,
        UserDefaultsKeys.importSortByDate,
        UserDefaultsKeys.metadataWritePreset,
    ]

    private func withRestoredDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = AppDefaults.store
        var originals: [String: Any] = [:]
        for key in Self.preferenceKeys { originals[key] = defaults.object(forKey: key) }
        defer {
            for key in Self.preferenceKeys {
                if let original = originals[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try await body()
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func folder(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJPEG(to url: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
    }

    private func makeViewModel(
        card: URL,
        photos: URL,
        title: String,
        policy: ImportConflictPolicy,
        filter: ImportFileTypeFilter = .jpegOnly,
        writeEngine: any MetadataWriteEngine = SwiftExifWriteEngine(),
        c2paDetector: (@Sendable (URL) async -> Bool)? = nil
    ) -> ImportViewModel {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: writeEngine,
            c2paDetector: c2paDetector
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = title
        viewModel.configuration.fileTypeFilter = filter
        viewModel.configuration.conflictPolicy = policy
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        return viewModel
    }

    private func waitForCompletion(_ viewModel: ImportViewModel) async throws {
        for _ in 0..<1000 where viewModel.isImporting || viewModel.lastCompletionEntry == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func resolve(
        _ service: ImportPreflightService,
        _ requests: [ImportPreflightService.BundleDestinationRequest],
        policy: ImportConflictPolicy
    ) async throws -> [ImportPreflightService.BundleDestination] {
        guard case .complete(let evidence) = await service.resolveBundleDestinations(requests, policy: policy) else {
            Issue.record("Planning must complete")
            return []
        }
        return evidence.destinations
    }

    // MARK: - Exposure-level destination planning

    @Test("Rename moves a whole exposure off any stem a different photo or its sidecar uses")
    func renameMovesWholeExposure() async throws {
        let root = try makeRoot("ExposurePlanning")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try folder(root, "card")
        let photos = try folder(root, "photos")
        // Photo A's JPEG, an orphan sidecar, and a RAW another body left on disk.
        try Data("A".utf8).write(to: photos.appendingPathComponent("DSC00001.JPG"))
        try Data("xmp".utf8).write(to: photos.appendingPathComponent("DSC00002.xmp"))
        try Data("X".utf8).write(to: photos.appendingPathComponent("DSC00003.ARW"))

        func image(_ name: String) -> ImportPreflightService.BundleDestinationRequest.File {
            .init(source: card.appendingPathComponent(name), role: .image, primaryFolder: photos, backupFolder: nil)
        }
        let pair = ImportPreflightService.BundleDestinationRequest(
            stem: "DSC00001", files: [image("DSC00001.ARW"), image("DSC00001.JPG")]
        )
        let orphanSidecar = ImportPreflightService.BundleDestinationRequest(
            stem: "DSC00002", files: [image("DSC00002.ARW")]
        )
        let first = ImportPreflightService.BundleDestinationRequest(
            stem: "DSC00003", files: [image("DSC00003.JPG")]
        )
        // The batch planner already gave a same-named exposure from another card suffix 1.
        let second = ImportPreflightService.BundleDestinationRequest(
            stem: "DSC00003", plannedSuffix: 1, files: [image("DSC00003.JPG")]
        )

        let destinations = try await resolve(
            ImportPreflightService(), [pair, orphanSidecar, first, second], policy: .renameWithSuffix
        )

        #expect(destinations[0].files.map(\.primary.lastPathComponent) == ["DSC00001-1.ARW", "DSC00001-1.JPG"])
        #expect(destinations[1].files.map(\.primary.lastPathComponent) == ["DSC00002-1.ARW"])
        // Never onto the name the later exposure was planned to use.
        #expect(destinations[2].files.map(\.primary.lastPathComponent) == ["DSC00003-2.JPG"])
        #expect(destinations[3].files.map(\.primary.lastPathComponent) == ["DSC00003-1.JPG"])
        #expect(destinations.allSatisfy { !$0.renamedAwayFromDifferentPhoto })
    }

    @Test("Skip Existing skips only this exposure's own files and renames when any file differs")
    func skipExistingSkipsOnlyTrueDuplicates() async throws {
        let root = try makeRoot("SkipExistingPlanning")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try folder(root, "card")
        let photos = try folder(root, "photos")
        let backup = try folder(root, "backup")
        for name in ["same.ARW", "diff.JPG", "half.ARW", "export.ARW", "backed.ARW"] {
            try Data("card-\(name)".utf8).write(to: card.appendingPathComponent(name))
        }
        for (index, name) in ["same.JPG", "half.JPG", "export.JPG"].enumerated() {
            try writeIdentityJPEG(to: card.appendingPathComponent(name), subSecond: "5\(index)")
        }
        try FileManager.default.copyItem(at: card.appendingPathComponent("same.ARW"), to: photos.appendingPathComponent("same.ARW"))
        // The JPEG copy got an embedded caption after import; it is still the same camera file.
        try writeIdentityJPEG(to: photos.appendingPathComponent("same.JPG"), subSecond: "50", caption: "Caption")
        try Data("another body".utf8).write(to: photos.appendingPathComponent("diff.JPG"))
        try FileManager.default.copyItem(at: card.appendingPathComponent("half.ARW"), to: photos.appendingPathComponent("half.ARW"))
        // An export saved beside the RAW under the original name is not the camera JPEG.
        try FileManager.default.copyItem(at: card.appendingPathComponent("export.ARW"), to: photos.appendingPathComponent("export.ARW"))
        try writeIdentityJPEG(to: photos.appendingPathComponent("export.JPG"), subSecond: "52", width: 8, software: "Adobe Lightroom")
        // The primary copy is there, but the backup path holds a different file.
        try FileManager.default.copyItem(at: card.appendingPathComponent("backed.ARW"), to: photos.appendingPathComponent("backed.ARW"))
        try Data("someone else".utf8).write(to: backup.appendingPathComponent("backed.ARW"))

        func image(_ name: String, backupFolder: URL? = nil) -> ImportPreflightService.BundleDestinationRequest.File {
            .init(source: card.appendingPathComponent(name), role: .image, primaryFolder: photos, backupFolder: backupFolder)
        }
        let destinations = try await resolve(ImportPreflightService(), [
            .init(stem: "same", files: [image("same.ARW"), image("same.JPG")]),
            .init(stem: "diff", files: [image("diff.JPG")]),
            .init(stem: "half", files: [image("half.ARW"), image("half.JPG")]),
            .init(stem: "export", files: [image("export.ARW"), image("export.JPG")]),
            .init(stem: "backed", files: [image("backed.ARW", backupFolder: backup)]),
        ], policy: .skipExisting)

        #expect(destinations[0].files.map(\.skipReason) == [.destinationExists, .destinationExists])
        #expect(destinations[1].files.map(\.primary.lastPathComponent) == ["diff-1.JPG"])
        #expect(destinations[1].files.map(\.skipReason) == [nil])
        #expect(destinations[1].renamedAwayFromDifferentPhoto)
        // The missing JPEG joins its RAW twin instead of landing on another stem.
        #expect(destinations[2].files.map(\.primary.lastPathComponent) == ["half.ARW", "half.JPG"])
        #expect(destinations[2].files.map(\.skipReason) == [.destinationExists, nil])
        // The export must not hide the camera JPEG: the whole exposure is copied renamed.
        #expect(destinations[3].files.map(\.primary.lastPathComponent) == ["export-1.ARW", "export-1.JPG"])
        #expect(destinations[3].files.map(\.skipReason) == [nil, nil])
        #expect(destinations[3].renamedAwayFromDifferentPhoto)
        // A different file at the backup path never silently skips: renamed on both legs.
        #expect(destinations[4].files.map(\.primary.lastPathComponent) == ["backed-1.ARW"])
        #expect(destinations[4].files.map(\.backup?.lastPathComponent) == ["backed-1.ARW"])
        #expect(destinations[4].files.map(\.skipReason) == [nil])
        #expect(destinations[4].files.map(\.backupSkipReason) == [nil])
        #expect(destinations[4].renamedAwayFromDifferentPhoto)
    }

    @Test("Skip Existing fills a missing primary or backup leg instead of renaming or skipping it")
    func skipExistingFillsMissingLegs() async throws {
        let root = try makeRoot("SkipExistingLegs")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try folder(root, "card")
        let photos = try folder(root, "photos")
        let backup = try folder(root, "backup")
        for name in ["primaryOnly.ARW", "backupOnly.ARW"] {
            try Data("card-\(name)".utf8).write(to: card.appendingPathComponent(name))
        }
        // Imported before the backup drive was added.
        try FileManager.default.copyItem(at: card.appendingPathComponent("primaryOnly.ARW"), to: photos.appendingPathComponent("primaryOnly.ARW"))
        // The primary drive is new; the backup still holds the earlier copy.
        try FileManager.default.copyItem(at: card.appendingPathComponent("backupOnly.ARW"), to: backup.appendingPathComponent("backupOnly.ARW"))

        func image(_ name: String) -> ImportPreflightService.BundleDestinationRequest.File {
            .init(source: card.appendingPathComponent(name), role: .image, primaryFolder: photos, backupFolder: backup)
        }
        let destinations = try await resolve(ImportPreflightService(), [
            .init(stem: "primaryOnly", files: [image("primaryOnly.ARW")]),
            .init(stem: "backupOnly", files: [image("backupOnly.ARW")]),
        ], policy: .skipExisting)

        #expect(destinations[0].files.map(\.primary.lastPathComponent) == ["primaryOnly.ARW"])
        #expect(destinations[0].files.map(\.skipReason) == [.destinationExists])
        #expect(destinations[0].files.map(\.backupSkipReason) == [nil])
        #expect(destinations[1].files.map(\.primary.lastPathComponent) == ["backupOnly.ARW"])
        #expect(destinations[1].files.map(\.skipReason) == [nil])
        #expect(destinations[1].files.map(\.backupSkipReason) == [.destinationExists])
        #expect(destinations.allSatisfy { !$0.renamedAwayFromDifferentPhoto })
    }

    @Test("A frozen primary skip still copies the missing backup leg from the card")
    func copyServiceFillsBackupForSkippedPrimary() async throws {
        let root = try makeRoot("CopyFillBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try folder(root, "card")
        let photos = try folder(root, "photos")
        let backup = try folder(root, "backup")
        let source = card.appendingPathComponent("photo.ARW")
        try Data("card".utf8).write(to: source)
        try Data("card".utf8).write(to: photos.appendingPathComponent("photo.ARW"))

        var job = ImportCopyService.CopyJob(
            source: source,
            desiredPrimaryDest: photos.appendingPathComponent("photo.ARW"),
            desiredBackupDest: backup.appendingPathComponent("photo.ARW"),
            preflightSkipReason: .destinationExists
        )
        job.frozenDestination = true
        let results = try await ImportCopyService().run(
            jobs: [job],
            conflictPolicy: .skipExisting,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results[0].primary == .skipped(.destinationExists))
        #expect(results[0].backupVerification == .verified)
        #expect(try Data(contentsOf: backup.appendingPathComponent("photo.ARW")) == Data("card".utf8))
    }

    @Test("Unfrozen Skip Existing copies a different same-named file under a new name")
    func copyServiceSkipExistingKeepsDifferentFiles() async throws {
        let root = try makeRoot("CopySkipExisting")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try folder(root, "card")
        let photos = try folder(root, "photos")
        let duplicate = card.appendingPathComponent("dup.jpg")
        let different = card.appendingPathComponent("photo.jpg")
        try Data("dup".utf8).write(to: duplicate)
        try Data("card B".utf8).write(to: different)
        try Data("dup".utf8).write(to: photos.appendingPathComponent("dup.jpg"))
        try Data("card A".utf8).write(to: photos.appendingPathComponent("photo.jpg"))

        let results = try await ImportCopyService().run(
            jobs: [
                .init(source: duplicate, desiredPrimaryDest: photos.appendingPathComponent("dup.jpg"), desiredBackupDest: nil),
                .init(source: different, desiredPrimaryDest: photos.appendingPathComponent("photo.jpg"), desiredBackupDest: nil),
            ],
            conflictPolicy: .skipExisting,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results[0].primary == .skipped(.destinationExists))
        #expect(results[1].primaryURL?.lastPathComponent == "photo-1.jpg")
        #expect(results[1].renamedAwayFromDifferentFile)
        #expect(try Data(contentsOf: photos.appendingPathComponent("photo.jpg")) == Data("card A".utf8))
        #expect(try Data(contentsOf: photos.appendingPathComponent("photo-1.jpg")) == Data("card B".utf8))
    }

    @Test("Skip Existing never drops card B's photos that share card A's names")
    func skipExistingImportKeepsDifferentPhotos() async throws {
        try await withRestoredDefaults {
            let root = try makeRoot("SkipExistingImport")
            defer { try? FileManager.default.removeItem(at: root) }
            let card = try folder(root, "card-b")
            let photos = try folder(root, "photos")
            let source = card.appendingPathComponent("photo.jpg")
            try Data("card B".utf8).write(to: source)

            let viewModel = makeViewModel(card: card, photos: photos, title: "Two Bodies", policy: .skipExisting)
            viewModel.sourceFiles = [source]
            let destination = viewModel.configuration.destinationFolderURL
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("card A".utf8).write(to: destination.appendingPathComponent("photo.jpg"))

            viewModel.startImport()
            try await waitForCompletion(viewModel)

            #expect(try Data(contentsOf: destination.appendingPathComponent("photo.jpg")) == Data("card A".utf8))
            #expect(try Data(contentsOf: destination.appendingPathComponent("photo-1.jpg")) == Data("card B".utf8))
            #expect(viewModel.copiedFiles == 1)
            #expect(viewModel.skippedFiles == 0)
            #expect(viewModel.conflictRenamedFiles == 1)
            #expect(viewModel.failureRecords.map(\.kind) == [.renamedConflict])
            #expect(viewModel.lastCompletionEntry?.isClean == true)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    @Test("A renamed RAW+JPEG pair moves together and never inherits another photo's sidecar")
    func pairMovesTogetherWithoutInheritingSidecar() async throws {
        try await withRestoredDefaults {
            let root = try makeRoot("PairCollision")
            defer { try? FileManager.default.removeItem(at: root) }
            let card = try folder(root, "card-b")
            let photos = try folder(root, "photos")
            let raw = card.appendingPathComponent("DSC00001.ARW")
            let jpeg = card.appendingPathComponent("DSC00001.JPG")
            try Data("raw B".utf8).write(to: raw)
            try Data("jpeg B".utf8).write(to: jpeg)

            let viewModel = makeViewModel(card: card, photos: photos, title: "Pair", policy: .renameWithSuffix, filter: .both)
            viewModel.sourceFiles = [raw, jpeg]
            let destination = viewModel.configuration.destinationFolderURL
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // Photo A (RAW only) and its captions are already here.
            try Data("raw A".utf8).write(to: destination.appendingPathComponent("DSC00001.ARW"))
            try Data("<x:xmpmeta>A</x:xmpmeta>".utf8).write(to: destination.appendingPathComponent("DSC00001.xmp"))

            viewModel.startImport()
            try await waitForCompletion(viewModel)

            #expect(try Data(contentsOf: destination.appendingPathComponent("DSC00001-1.ARW")) == Data("raw B".utf8))
            #expect(try Data(contentsOf: destination.appendingPathComponent("DSC00001-1.JPG")) == Data("jpeg B".utf8))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC00001.JPG").path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("DSC00001-1.xmp").path))
            #expect(try String(contentsOf: destination.appendingPathComponent("DSC00001.xmp"), encoding: .utf8)
                == "<x:xmpmeta>A</x:xmpmeta>")
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    @Test("Overwrite replaces the old sidecar with the card's, or detaches it from a different photo")
    func overwriteNeverLeavesStaleSidecar() async throws {
        try await withRestoredDefaults {
            let root = try makeRoot("OverwriteSidecar")
            defer { try? FileManager.default.removeItem(at: root) }
            let card = try folder(root, "card")
            let photos = try folder(root, "photos")
            let bare = card.appendingPathComponent("bare.jpg")
            let withSidecar = card.appendingPathComponent("edited.jpg")
            try Data("new bare".utf8).write(to: bare)
            try Data("new edited".utf8).write(to: withSidecar)
            try Data("<x:xmpmeta>card</x:xmpmeta>".utf8).write(to: card.appendingPathComponent("edited.xmp"))

            let viewModel = makeViewModel(card: card, photos: photos, title: "Overwrite", policy: .overwrite)
            viewModel.sourceFiles = [bare, withSidecar]
            let destination = viewModel.configuration.destinationFolderURL
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["bare", "edited"] {
                try Data("old \(name)".utf8).write(to: destination.appendingPathComponent("\(name).jpg"))
                try Data("<x:xmpmeta>old</x:xmpmeta>".utf8).write(to: destination.appendingPathComponent("\(name).xmp"))
            }

            viewModel.startImport()
            for _ in 0..<500 where viewModel.overwritePreflight == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            viewModel.confirmOverwritePreflight()
            try await waitForCompletion(viewModel)

            #expect(try Data(contentsOf: destination.appendingPathComponent("bare.jpg")) == Data("new bare".utf8))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("bare.xmp").path))
            let detached = try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0.hasPrefix("bare.xmp.replaced-") }
            #expect(detached.count == 1)
            #expect(try String(contentsOf: destination.appendingPathComponent("edited.xmp"), encoding: .utf8)
                == "<x:xmpmeta>card</x:xmpmeta>")
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: - Import new only

    @Test("Import new only skips copies that got an embedded caption, were renamed, or came earlier")
    func reimportSkipsCaptionedAndRenamedCopies() async throws {
        try await withRestoredDefaults {
            AppDefaults.store.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            let root = try makeRoot("ReimportLedger")
            defer { try? FileManager.default.removeItem(at: root) }
            let card = try folder(root, "card")
            let photos = try folder(root, "photos")
            let captioned = card.appendingPathComponent("photo.jpg")
            let clashing = card.appendingPathComponent("clash.jpg")
            try writeIdentityJPEG(to: captioned, subSecond: "61")
            try writeIdentityJPEG(to: clashing, subSecond: "62")

            let first = makeViewModel(card: card, photos: photos, title: "Ledger", policy: .renameWithSuffix)
            first.configuration.applyMetadata = true
            first.configuration.metadata.description = "Embedded caption"
            first.sourceFiles = [captioned, clashing]
            let destination = first.configuration.destinationFolderURL
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("someone else's clash.jpg".utf8).write(to: destination.appendingPathComponent("clash.jpg"))

            first.startImport()
            try await waitForCompletion(first)
            #expect(first.copiedFiles == 2)
            #expect(first.metadataFailedFiles == 0)
            // Professional embeds into the JPEG: the copy no longer matches the card bytes.
            #expect(try Data(contentsOf: destination.appendingPathComponent("photo.jpg")) != Data(contentsOf: captioned))
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("clash-1.jpg").path))
            // Each copy is recorded unfinished at once and marked finished after its template
            // (copying runs ahead of finishing, so files interleave).
            let ledgerByFile = Dictionary(grouping: ImportLedger.load(root: photos), by: \.name)
            #expect(ledgerByFile.count == 2)
            #expect(ledgerByFile.values.allSatisfy { $0.map(\.finished) == [false, true] })
            try await Task.sleep(for: .milliseconds(300))

            let second = makeViewModel(card: card, photos: photos, title: "Ledger", policy: .renameWithSuffix)
            second.configuration.skipPreviouslyImported = true
            second.sourceFiles = [captioned, clashing]
            second.startImport()
            try await waitForCompletion(second)

            #expect(second.duplicateSkippedFiles == 2)
            #expect(second.copiedFiles == 0)
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("photo-1.jpg").path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("clash-2.jpg").path))
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: - Cancellation and finishing

    @Test("Cancel stops copying but every copied photo still gets its sidecar, metadata and ledger mark")
    func cancelFinishesCopiedFiles() async throws {
        try await withRestoredDefaults {
            AppDefaults.store.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            let root = try makeRoot("ImportCancel")
            defer { try? FileManager.default.removeItem(at: root) }
            let card = try folder(root, "card")
            let photos = try folder(root, "photos")
            let sources = ["A_1.JPG", "B_2.JPG", "C_3.JPG"].map { card.appendingPathComponent($0) }
            for source in sources { try writeJPEG(to: source) }
            try Data("<x:xmpmeta>card</x:xmpmeta>".utf8).write(to: card.appendingPathComponent("A_1.xmp"))

            // The copy is cancelled while the second file is verified.
            let verifications = ImportProbeCounter()
            let copyService = ImportCopyService(verificationHasher: { url in
                verifications.increment()
                if verifications.count >= 2 { throw CancellationError() }
                return try HashStream.hashFileSynchronously(at: url, bypassingCache: true)
            })
            let writer = ImportRecordingWriteEngine()
            let viewModel = ImportViewModel(
                readService: SwiftExifReadService(),
                writeEngine: writer,
                copyService: copyService,
                c2paDetector: { _ in false }
            )
            viewModel.configuration.sourceURL = card
            viewModel.configuration.destinationBaseURL = photos
            viewModel.configuration.importTitle = "Cancel"
            viewModel.configuration.fileTypeFilter = .jpegOnly
            viewModel.configuration.conflictPolicy = .renameWithSuffix
            viewModel.configuration.createSubFolders = false
            viewModel.configuration.verificationMode = .on
            viewModel.configuration.skipPreviouslyImported = false
            viewModel.configuration.applyMetadata = true
            viewModel.configuration.metadata.jobId = "JOB-9"
            viewModel.sortByDate = false
            viewModel.sourceFiles = sources
            let destination = viewModel.configuration.destinationFolderURL

            viewModel.startImport()
            try await waitForCompletion(viewModel)

            #expect(viewModel.importPhase == .cancelled)
            #expect(viewModel.copiedFiles == 1)
            #expect(writer.writtenURLs.map(\.lastPathComponent) == ["A_1.JPG"])
            #expect(writer.lastFields[.transmissionReference] == "JOB-9")
            #expect(viewModel.metadataProcessedFiles == 1)
            #expect(viewModel.metadataFailedFiles == 0)
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A_1.xmp").path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("B_2.JPG").path))
            #expect(ImportLedger.load(root: photos).map(\.finished) == [false, true])
            #expect(viewModel.lastCompletionEntry?.wasCancelled == true)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    @Test("Copying never waits on finishing, and the import completes only after finishing drains")
    func copyingRunsAheadOfFinishing() async throws {
        try await withRestoredDefaults {
            AppDefaults.store.set(MetadataWritePreset.professional.rawValue, forKey: UserDefaultsKeys.metadataWritePreset)
            let root = try makeRoot("ImportFinisher")
            defer { try? FileManager.default.removeItem(at: root) }
            let card = try folder(root, "card")
            let photos = try folder(root, "photos")
            let sources = ["A_1.JPG", "B_2.JPG", "C_3.JPG"].map { card.appendingPathComponent($0) }
            for source in sources { try writeJPEG(to: source) }

            let writer = ImportGatedWriteEngine()
            defer { writer.release() }
            let viewModel = makeViewModel(
                card: card, photos: photos, title: "Finisher", policy: .renameWithSuffix,
                writeEngine: writer, c2paDetector: { _ in false }
            )
            viewModel.configuration.applyMetadata = true
            viewModel.configuration.metadata.jobId = "JOB-3"
            viewModel.sourceFiles = sources

            viewModel.startImport()
            // Every file is copied while the first metadata write is still held.
            for _ in 0..<1000 where viewModel.copiedFiles < 3 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(viewModel.copiedFiles == 3)
            #expect(viewModel.metadataProcessedFiles == 0)
            for _ in 0..<500 where viewModel.importPhase != .applyingMetadata {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(viewModel.importPhase == .applyingMetadata)
            #expect(viewModel.lastCompletionEntry == nil)

            writer.release()
            try await waitForCompletion(viewModel)
            #expect(viewModel.importPhase == .complete)
            #expect(viewModel.metadataProcessedFiles == 3)
            #expect(writer.writeCount == 3)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    @Test("Place lookups are cached per ~100 m and bounded by a timeout")
    func placeLookupCacheAndTimeout() async {
        let calls = ImportProbeCounter()
        let cache = ImportPlaceLookupCache(timeout: .seconds(5)) { _, _ in
            calls.increment()
            return GeocodingResult(city: "Oslo", country: "Norway")
        }
        let first = await cache.place(latitude: 59.91271, longitude: 10.74561)
        let nearby = await cache.place(latitude: 59.91268, longitude: 10.74559)
        let elsewhere = await cache.place(latitude: 60.39299, longitude: 5.32415)
        #expect(first == .init(city: "Oslo", country: "Norway"))
        #expect(nearby == first)
        #expect(elsewhere == first)
        #expect(calls.count == 2)

        let slowCalls = ImportProbeCounter()
        let slow = ImportPlaceLookupCache(timeout: .milliseconds(200)) { _, _ in
            slowCalls.increment()
            try await Task.sleep(for: .seconds(30))
            return GeocodingResult(city: "Late", country: "Late")
        }
        let started = Date()
        let timedOut = await slow.place(latitude: 1, longitude: 1)
        let again = await slow.place(latitude: 1, longitude: 1)
        #expect(timedOut == nil)
        #expect(again == nil)
        #expect(slowCalls.count == 1)
        #expect(Date().timeIntervalSince(started) < 5)

        // The interpolator leaves the tokens for a later retry when the lookup gives up.
        var metadata = IPTCMetadata()
        metadata.city = "{gps:city}"
        metadata.latitude = 1
        metadata.longitude = 1
        let unresolved = await PresetVariableInterpolator().resolvingGPSPlaceVariables(
            in: metadata, placeLookup: slow.lookup
        )
        #expect(unresolved.city == "{gps:city}")
        let resolved = await PresetVariableInterpolator().resolvingGPSPlaceVariables(
            in: { var m = metadata; m.latitude = 59.91271; m.longitude = 10.74561; return m }(),
            placeLookup: cache.lookup
        )
        #expect(resolved.city == "Oslo")
    }

    // MARK: - Counting, staging files, sequencing, splitting

    @Test("A verification mismatch is counted once")
    func mismatchCountedOnce() {
        let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        viewModel.applyProgress(ImportCopyService.CopyResult(
            id: UUID(),
            source: URL(fileURLWithPath: "/card/photo.jpg"),
            primary: .failed("The copy didn't match the original. Check the card and card reader, then import this file again."),
            primaryVerification: .mismatch(expected: Data([1]), got: Data([2])),
            backup: nil,
            backupVerification: nil
        ))
        #expect(viewModel.failedFiles == 0)
        #expect(viewModel.mismatchedFiles == 1)
        #expect(viewModel.processedFiles == 1)
        #expect(viewModel.failureRecords.map(\.kind) == [.verificationMismatch])

        let entry = ActivityEntry(
            kind: .importJob, date: Date(), title: nil, successCount: 0, totalCount: 1,
            verificationFailures: 1, verificationEnabled: true,
            importResultCounts: ActivityImportResultCounts(replaced: 0, backupReplaced: 0, skipped: 0, renamed: 0),
            files: []
        )
        #expect(!entry.summary.contains("failed"))
        #expect(entry.summary.contains("1 verification issue"))
    }

    @Test("Only stale files with the exact staging name are swept")
    func staleStagingSweep() throws {
        let root = try makeRoot("StagingSweep")
        defer { try? FileManager.default.removeItem(at: root) }
        let staleName = ImportCopyService.stagingFileName(for: "DSC00001.ARW")
        let freshName = ImportCopyService.stagingFileName(for: "DSC00002.ARW")
        let keepNames = [
            ".DSC00003.ARW.partial",
            ".DSC00004.ARW.not-a-uuid.partial",
            "DSC00005.ARW.\(UUID().uuidString).partial",
            ".\(UUID().uuidString).partial",
            "photo.jpg",
        ]
        let old = Date().addingTimeInterval(-7200)
        for name in [staleName, freshName] + keepNames {
            let url = root.appendingPathComponent(name)
            try Data("bytes".utf8).write(to: url)
            if name != freshName {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
        }
        #expect(ImportCopyService.isStagingFileName(staleName))

        let removed = ImportCopyService.sweepStaleStagingFiles(in: [root])

        #expect(removed.map(\.lastPathComponent) == [staleName])
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(remaining == Set([freshName] + keepNames))
    }

    @Test("Folder watching ignores import staging files inside subfolders")
    func stagingFilesDoNotRefreshBrowser() {
        let root = URL(fileURLWithPath: "/photos/2026-10-24 – Cup", isDirectory: true)
        let staging = root.appendingPathComponent("RAW")
            .appendingPathComponent(ImportCopyService.stagingFileName(for: "DSC00001.ARW"))
        #expect(BrowserFolderChangeImpact.classify(
            FolderChangeBatch(paths: [staging], requiresFullRescan: false),
            monitoredRoot: root
        ).isEmpty)
        #expect(BrowserFolderChangeImpact.classify(
            FolderChangeBatch(paths: [root.appendingPathComponent("RAW/DSC00001.ARW")], requiresFullRescan: false),
            monitoredRoot: root
        ) == .browserContent)
    }

    @Test("{seq} numbers exposures in capture order and a RAW+JPEG pair shares one number")
    func sequenceNumbersPerExposure() {
        let pairID = UUID()
        let earlierID = UUID()
        let skippedID = UUID()
        func job(_ name: String) -> ImportCopyService.CopyJob {
            .init(source: URL(fileURLWithPath: "/card/\(name)"), desiredPrimaryDest: URL(fileURLWithPath: "/p/\(name)"), desiredBackupDest: nil)
        }
        let pairRaw = job("A.ARW")
        let pairJPEG = job("A.JPG")
        let earlier = job("Z.JPG")
        var skipped = job("M.JPG")
        skipped.preflightSkipReason = .previouslyImported
        let contexts: [UUID: ImportJobContext] = [
            pairRaw.id: .init(exposureID: pairID, isImage: true, replacesDifferentPhoto: false, captureDate: nil),
            pairJPEG.id: .init(exposureID: pairID, isImage: true, replacesDifferentPhoto: false, captureDate: nil),
            earlier.id: .init(exposureID: earlierID, isImage: true, replacesDifferentPhoto: false, captureDate: nil),
            skipped.id: .init(exposureID: skippedID, isImage: true, replacesDifferentPhoto: false, captureDate: nil),
        ]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let numbers = ImportViewModel.sequenceNumbersByExposure(
            jobs: [pairRaw, pairJPEG, skipped, earlier],
            contexts: contexts,
            captureTimes: [
                pairRaw.source: base.addingTimeInterval(60),
                pairJPEG.source: base.addingTimeInterval(60),
                skipped.source: base.addingTimeInterval(30),
                earlier.source: base,
            ]
        )
        #expect(numbers == [earlierID: 1, pairID: 2])
    }

    @Test("Shoot splits and moves keep both files of an exposure together")
    func splitsKeepPairsTogether() {
        let viewModel = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        let card = URL(fileURLWithPath: "/card/DCIM", isDirectory: true)
        let files = ["A.ARW", "A.JPG", "B.ARW", "B.JPG", "C.JPG"].map { card.appendingPathComponent($0) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let times: [URL: Date] = [
            files[0]: base, files[1]: base,
            files[2]: base.addingTimeInterval(60), files[3]: base.addingTimeInterval(60),
            files[4]: base.addingTimeInterval(120),
        ]
        func freshGroup() -> ImportDateGroup {
            ImportDateGroup(dateString: "2026:10:24", folderName: "2026-10-24", files: files, captureTimes: times)
        }

        viewModel.dateGroups = [freshGroup()]
        // Boundaries on A.JPG (index 1) and B.JPG (index 3) must not separate them from their
        // RAWs: each JPEG follows its RAW's shoot, and C.JPG still starts the third shoot.
        viewModel.splitGroup(viewModel.dateGroups[0].id, boundaries: [1, 3])
        #expect(viewModel.dateGroups.map { Set($0.files.map(\.lastPathComponent)) } == [
            ["A.ARW", "A.JPG"], ["B.ARW", "B.JPG"], ["C.JPG"],
        ])

        viewModel.dateGroups = [freshGroup()]
        viewModel.splitOff(viewModel.dateGroups[0].id, fileURLs: [files[3]])
        #expect(viewModel.dateGroups.map { Set($0.files.map(\.lastPathComponent)) } == [
            ["A.ARW", "A.JPG", "C.JPG"], ["B.ARW", "B.JPG"],
        ])
        #expect(ImportViewModel.exposures(inChronologicalFiles: files).count == 3)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

struct EjectableVolumeTests {
    @Test("The startup disk and its temporary folders are never offered for ejecting")
    func internalDiskIsNotEjectable() {
        #expect(EjectableVolume(containing: FileManager.default.temporaryDirectory) == nil)
        #expect(EjectableVolume(containing: URL(fileURLWithPath: NSHomeDirectory())) == nil)
    }

    @Test("A finished import from the internal disk offers no Eject and ignores eject requests")
    @MainActor func internalSourceOffersNoEject() {
        let model = ImportViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.configuration.sourceURL = FileManager.default.temporaryDirectory
        #expect(model.ejectableSourceVolume == nil)
        model.ejectSourceVolume()
        #expect(model.sourceVolumeEjectState == SourceVolumeEjectState.idle)
    }
}

struct ImportTimeEstimateTests {
    @Test("No estimate until three files and five seconds have passed")
    func waitsForEnoughData() {
        #expect(ImportTimeEstimate.secondsLeft(elapsed: 10, done: 2, remaining: 98) == nil)
        #expect(ImportTimeEstimate.secondsLeft(elapsed: 4, done: 10, remaining: 90) == nil)
        #expect(ImportTimeEstimate.secondsLeft(elapsed: 10, done: 100, remaining: 0) == nil)
    }

    @Test("The estimate follows the average rate so far")
    func averageRate() {
        #expect(ImportTimeEstimate.secondsLeft(elapsed: 20, done: 10, remaining: 30) == 60)
        // 800 previously imported files skipped instantly don't make the copy look fast.
        #expect(ImportTimeEstimate.secondsLeft(elapsed: 10, done: 0, remaining: 200) == nil)
    }

    @Test("Time left reads in minutes and hours")
    func text() {
        #expect(ImportTimeEstimate.text(forSecondsLeft: 30) == "Less than a minute left")
        #expect(ImportTimeEstimate.text(forSecondsLeft: 250) == "About 4 min left")
        #expect(ImportTimeEstimate.text(forSecondsLeft: 3600) == "About 1 h left")
        #expect(ImportTimeEstimate.text(forSecondsLeft: 5400) == "About 1 h 30 min left")
    }
}
