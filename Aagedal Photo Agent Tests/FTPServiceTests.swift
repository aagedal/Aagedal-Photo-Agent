import Testing
import AppKit
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("FTPService.curlArguments")
struct FTPCurlArgumentsTests {

    private func makeArgs(_ connection: FTPConnection) -> [String] {
        FTPService.curlArguments(
            localPath: "/tmp/photo.jpg",
            remoteURL: "ftp://example.com:21/incoming/photo.jpg",
            netrcPath: "/tmp/abc.netrc",
            connection: connection
        )
    }

    @Test("plain FTP carries no TLS or insecure flags")
    func plainFTPHasNoTLS() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: false))
        #expect(!args.contains("--ssl-reqd"))
        #expect(!args.contains("--ssl"))
        #expect(!args.contains("--insecure"))
        #expect(args.contains("--ftp-create-dirs"))
    }

    @Test("explicit FTPS requires TLS so a downgrade aborts instead of sending cleartext")
    func ftpsRequiresTLS() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: true))
        #expect(args.contains("--ssl-reqd"))
        #expect(!args.contains("--insecure")) // cert verification stays on by default
        #expect(args.contains("--ftp-create-dirs"))
    }

    @Test("FTPS with insecure cert verification adds --insecure but keeps --ssl-reqd")
    func ftpsInsecureCert() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: true, allowInsecureHostVerification: true))
        #expect(args.contains("--ssl-reqd"))
        #expect(args.contains("--insecure"))
    }

    @Test("SFTP uses neither TLS nor ftp-create-dirs flags")
    func sftpFlags() {
        let secure = makeArgs(FTPConnection(useSFTP: true))
        #expect(!secure.contains("--ssl-reqd"))
        #expect(!secure.contains("--ftp-create-dirs"))
        #expect(!secure.contains("--insecure"))

        let insecure = makeArgs(FTPConnection(useSFTP: true, allowInsecureHostVerification: true))
        #expect(insecure.contains("--insecure"))
    }

    @Test("globbing is disabled so filenames with [] or {} upload literally")
    func globbingDisabled() {
        // curl treats [], {} in URLs as glob patterns by default, which would abort
        // the upload of any file whose name contains those (legal) characters.
        for connection in [
            FTPConnection(useSFTP: false, useTLS: false),
            FTPConnection(useSFTP: false, useTLS: true),
            FTPConnection(useSFTP: true),
        ] {
            #expect(makeArgs(connection).contains("--globoff"))
        }
    }

    @Test("credentials are passed via netrc file, never on the command line")
    func credentialsViaNetrc() {
        let args = makeArgs(FTPConnection(useSFTP: false))
        #expect(args.contains("--netrc-file"))
        #expect(args.contains("/tmp/abc.netrc"))
        // The remote URL is the upload target and must be present.
        #expect(args.contains("ftp://example.com:21/incoming/photo.jpg"))
        // The local file is uploaded with -T.
        let tIndex = args.firstIndex(of: "-T")
        #expect(tIndex != nil)
        if let tIndex { #expect(args[args.index(after: tIndex)] == "/tmp/photo.jpg") }
    }

    @Test("uploads give up on a dead or stalled server instead of freezing")
    func uploadHasStallTimeouts() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: true))
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).map { args[args.index(after: $0)] }
        }
        #expect(value(after: "--connect-timeout") == "15")
        #expect(value(after: "--speed-limit") == "1")
        #expect(value(after: "--speed-time") == "60")
    }

    @Test("netrc login and password are quoted so spaces, '#', quotes and backslashes survive")
    func netrcQuoting() throws {
        let content = try FTPService.netrcContent(
            host: "ftp.example.com",
            username: "photo desk",
            password: "p a\"s#s\\w\td\nx"
        )
        #expect(content == "machine ftp.example.com login \"photo desk\" password \"p a\\\"s#s\\\\w\\td\\nx\"\n")
        // A quote or backslash followed by a combining mark is a single Character; it must still
        // be escaped, and a CRLF pair becomes two escapes.
        #expect(FTPService.netrcQuoted("a\"\u{0301}b\\\u{0301}c\r\n") == "\"a\\\"\u{0301}b\\\\\u{0301}c\\r\\n\"")
        #expect(throws: FTPService.FTPError.self) {
            try FTPService.netrcContent(host: "ftp.example.com", username: "u", password: "")
        }
        #expect(throws: FTPService.FTPError.self) {
            try FTPService.netrcContent(host: "bad host", username: "u", password: "p")
        }
    }

    @Test("credential, SFTP and unsupported-protocol failures stop the whole batch")
    func batchStoppingErrors() {
        #expect(FTPService.FTPError.invalidCredential("password", reason: "is empty").isServerLevel)
        #expect(FTPService.FTPError.sftpUnavailable.isServerLevel)
        #expect(FTPService.FTPError.uploadFailed(1, "curl: (1) Protocol \"sftp\" not supported").isServerLevel)
        #expect(FTPService.FTPError.uploadFailed(67, "").isServerLevel)
        #expect(!FTPService.FTPError.uploadFailed(26, "").isServerLevel)
        #expect(FTPService.FTPError.connectionTestFailed(7, "").localizedDescription
            .hasPrefix("Connection test failed"))
    }

    @Test("an SFTP profile is refused before curl runs")
    func sftpRefusedBeforeLaunch() async throws {
        let sftp = FTPConnection(name: "Legacy", host: "example.invalid", port: 22,
                                 username: "u", useSFTP: true)
        do {
            _ = try await FTPService().testConnection(connection: sftp, password: "p")
            Issue.record("SFTP test unexpectedly ran")
        } catch let error as FTPService.FTPError {
            #expect(error.localizedDescription == FTPConnection.sftpUnavailableMessage)
        }
        do {
            try await FTPService().uploadFile(
                localURL: URL(fileURLWithPath: "/private/tmp/never-read.jpg"),
                connection: sftp,
                password: "p",
                progressHandler: { _ in }
            )
            Issue.record("SFTP upload unexpectedly ran")
        } catch let error as FTPService.FTPError {
            #expect(error.isServerLevel)
        }
    }

    @Test("connection test has both connect and overall deadlines")
    func connectionTestHasOverallDeadline() {
        let args = FTPService.testConnectionArguments(
            remoteURL: "ftp://example.com:21/incoming/",
            netrcPath: "/tmp/abc.netrc",
            connection: FTPConnection(host: "example.com")
        )
        #expect(args.contains("--connect-timeout"))
        #expect(args.contains("--max-time"))
    }
}

@Suite("FTPService cancellation")
struct FTPServiceCancellationTests {
    @Test("a pre-cancelled upload exits without launching or crashing Process")
    func preCancelledUpload() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FTPCancel-\(UUID().uuidString).jpg")
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let task = Task {
            try await FTPService().uploadFile(
                localURL: file,
                connection: FTPConnection(host: "127.0.0.1", port: 1, username: "user"),
                password: "password",
                progressHandler: { _ in }
            )
        }
        task.cancel()

        do {
            try await task.value
            Issue.record("A pre-cancelled upload unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
    }
}

@Suite("FTP upload filesystem boundary")
struct FTPUploadFileSystemBoundaryTests {
    @Test("inventory returns immutable ordered facts and a stable fallback date")
    func inventory() async throws {
        let fixture = try FTPFileSystemFixture()
        defer { fixture.remove() }
        let first = try fixture.write("first.jpg", bytes: [1, 2, 3])
        let second = fixture.root.appendingPathComponent("missing.jpg")
        let fallback = Date(timeIntervalSince1970: 1_234)
        let boundary = FTPUploadFileSystemBoundary(temporaryRoot: fixture.root)

        let inventory = try await boundary.inventory(
            for: [first, second],
            fallbackDate: fallback
        )

        #expect(inventory.totalBytes == 3)
        #expect(inventory.records.map(\.fileName) == ["first.jpg", "missing.jpg"])
        #expect(inventory.records.map(\.fileSize) == [3, 0])
        #expect(inventory.records[1].modifiedDate == fallback)
    }

    @Test("history availability returns complete ordered immutable evidence")
    func historyAvailability() async throws {
        let fixture = try FTPFileSystemFixture()
        defer { fixture.remove() }
        let availableURL = try fixture.write("available.jpg", bytes: [1])
        let missingURL = fixture.root.appendingPathComponent("missing.jpg")
        let entryID = UUID()
        let boundary = FTPUploadFileSystemBoundary(temporaryRoot: fixture.root)

        let snapshot = await boundary.historyAvailability(
            for: entryID,
            files: [historyRecord(availableURL), historyRecord(missingURL)]
        )

        #expect(snapshot.entryID == entryID)
        #expect(snapshot.files == [
            FTPUploadHistoryFileAvailability(filePath: availableURL.path, isAvailable: true),
            FTPUploadHistoryFileAvailability(filePath: missingURL.path, isAvailable: false)
        ])
        #expect(snapshot.completion == .complete)
    }

    @Test("pre-cancelled history scan returns explicit empty partial evidence")
    func preCancelledHistoryAvailability() async {
        let probe = CancellingHistoryAvailabilityProbe()
        let boundary = FTPUploadFileSystemBoundary(fileExists: probe.fileExists)
        let entryID = UUID()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await boundary.historyAvailability(
                for: entryID,
                files: [historyRecord(URL(fileURLWithPath: "/never-probed.jpg"))]
            )
        }

        let snapshot = await task.value

        #expect(snapshot.entryID == entryID)
        #expect(snapshot.files.isEmpty)
        #expect(snapshot.completion == .cancelled(checkedFileCount: 0))
        #expect(probe.invocationCount == 0)
    }

    @Test("cancellation after a synchronous probe returns only the checked prefix")
    func cancellationAfterHistoryProbe() async {
        let probe = CancellingHistoryAvailabilityProbe()
        let boundary = FTPUploadFileSystemBoundary(fileExists: probe.fileExists)
        let first = URL(fileURLWithPath: "/first.jpg")
        let second = URL(fileURLWithPath: "/second.jpg")
        let task = Task {
            await boundary.historyAvailability(
                for: UUID(),
                files: [historyRecord(first), historyRecord(second)]
            )
        }

        let snapshot = await task.value

        #expect(snapshot.files == [
            FTPUploadHistoryFileAvailability(filePath: first.path, isAvailable: true)
        ])
        #expect(snapshot.completion == .cancelled(checkedFileCount: 1))
        #expect(probe.invocationCount == 1)
    }

    @MainActor
    @Test("blocked history probe stays off the main actor and queued cancellation is serialized")
    func blockedHistoryProbeDoesNotBlockMainActor() async throws {
        let probe = BlockingHistoryAvailabilityProbe()
        defer { probe.releaseFirstProbe() }
        let boundary = FTPUploadFileSystemBoundary(fileExists: probe.fileExists)
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            await boundary.historyAvailability(
                for: firstID,
                files: [historyRecord(URL(fileURLWithPath: "/first.jpg"))]
            )
        }
        try await probe.waitUntilFirstProbeStarts()

        // This main-actor assertion executes while the injected synchronous filesystem call is
        // blocked on the boundary actor, characterizing the UI-responsiveness guarantee.
        #expect(probe.invocationCount == 1)
        let second = Task {
            await boundary.historyAvailability(
                for: secondID,
                files: [historyRecord(URL(fileURLWithPath: "/second.jpg"))]
            )
        }
        second.cancel()
        probe.releaseFirstProbe()

        let firstSnapshot = await first.value
        let secondSnapshot = await second.value

        #expect(firstSnapshot.completion == .complete)
        #expect(secondSnapshot.files.isEmpty)
        #expect(secondSnapshot.completion == .cancelled(checkedFileCount: 0))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Recent Uploads publishes only complete snapshots for the still-expanded entry")
    func historyAvailabilityViewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/FTP/FTPUploadView.swift"
            ),
            encoding: .utf8
        )
        let detailStart = try #require(source.range(of: "private func historyDetailView("))
        let refreshStart = try #require(source.range(of: "private func refreshExpandedHistoryAvailability()"))
        let uploadLogicStart = try #require(source.range(
            of: "// MARK: - Upload Logic",
            range: refreshStart.lowerBound..<source.endIndex
        ))
        let detailSource = source[detailStart.lowerBound..<refreshStart.lowerBound]
        let refreshSource = source[refreshStart.lowerBound..<uploadLogicStart.lowerBound]

        #expect(source.contains(".task(id: expandedHistoryID)"))
        #expect(detailSource.contains("historyAvailabilityByEntryID[entry.id]"))
        #expect(!detailSource.contains("FileManager"))
        #expect(refreshSource.contains("guard !Task.isCancelled"))
        #expect(refreshSource.contains("expandedHistoryID == entryID"))
        #expect(refreshSource.contains("snapshot.completion == .complete"))
        #expect(refreshSource.contains("historyAvailabilityByEntryID[entryID] = snapshot"))
    }

    @Test("staging preserves the source and returns committed immutable evidence")
    func stageOriginal() async throws {
        let fixture = try FTPFileSystemFixture()
        defer { fixture.remove() }
        let source = try fixture.write("source.jpg", bytes: [4, 5, 6])
        let boundary = FTPUploadFileSystemBoundary(temporaryRoot: fixture.root)
        let workspace = try await boundary.createTemporaryDirectory()

        let prepared = try await boundary.stageOriginal(
            source,
            as: "source-2.jpg",
            in: workspace,
            index: 1
        )

        #expect(prepared.wasStaged)
        #expect(!prepared.cancellationRequestedAfterCommit)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: prepared.url) == Data([4, 5, 6]))
    }

    @Test("render sequencing skips disk and in-batch collisions before moving")
    func sequenceRenderedFile() async throws {
        let fixture = try FTPFileSystemFixture()
        defer { fixture.remove() }
        let source = try fixture.write("render.jpg", bytes: [7, 8])
        _ = try fixture.write("render_1.jpg", bytes: [1])
        let boundary = FTPUploadFileSystemBoundary(temporaryRoot: fixture.root)

        let prepared = try await boundary.sequenceRenderedFile(
            source,
            avoiding: ["render_2.jpg"]
        )

        #expect(prepared.url.lastPathComponent == "render_3.jpg")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: prepared.url) == Data([7, 8]))
    }

    @Test("pre-cancelled sequencing leaves the rendered file untouched")
    func preCancelledSequence() async throws {
        let fixture = try FTPFileSystemFixture()
        defer { fixture.remove() }
        let source = try fixture.write("render.jpg", bytes: [9])
        let boundary = FTPUploadFileSystemBoundary(temporaryRoot: fixture.root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await boundary.sequenceRenderedFile(source, avoiding: [])
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("render_1.jpg").path
        ))
    }

    private func historyRecord(_ url: URL) -> FTPUploadFileRecord {
        FTPUploadFileRecord(
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileSize: 0,
            modifiedDate: .distantPast
        )
    }
}

private nonisolated final class CancellingHistoryAvailabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func fileExists(_ path: String) -> Bool {
        _ = path
        lock.lock()
        count += 1
        lock.unlock()
        withUnsafeCurrentTask { $0?.cancel() }
        return true
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private enum HistoryAvailabilityProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingHistoryAvailabilityProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var firstProbeReleased = false
    private var observedMainThread = false

    func fileExists(_ path: String) -> Bool {
        _ = path
        condition.lock()
        count += 1
        observedMainThread = observedMainThread || Thread.isMainThread
        condition.broadcast()
        if count == 1 {
            while !firstProbeReleased {
                if !condition.waitBounded() { break }
            }
        }
        condition.unlock()
        return true
    }

    func waitUntilFirstProbeStarts() async throws {
        // Keep a bounded failure while allowing for scheduler starvation under the
        // unfiltered parallel suite; focused execution remains immediate.
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                // A test that gives up must not leave the probe holding a shared queue.
                releaseFirstProbe()
                throw HistoryAvailabilityProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstProbe() {
        condition.lock()
        firstProbeReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedMainThread
    }
}

@Suite("FTP upload sidecar boundary")
struct FTPUploadSidecarLoadServiceTests {
    @Test("sidecar metadata returns ordered complete immutable evidence")
    func completeSnapshot() async {
        let first = URL(fileURLWithPath: "/first.jpg")
        let second = URL(fileURLWithPath: "/second.jpg")
        let requestID = UUID()
        let probe = FTPSidecarLoadProbe(metadataByURL: [
            first: IPTCMetadata(title: "First")
        ])
        let queue = DispatchSerialQueue(label: "test.ftp.sidecar.completeSnapshot")
        let service = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: { url in
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(!Thread.isMainThread)
                #expect(FTPSidecarExecutorContext.marker == first)
                return probe.load(url)
            }), filesystemQueue: queue
        )

        let result = await FTPSidecarExecutorContext.$marker.withValue(first) {
            await service.load(imageURLs: [first, second], requestID: requestID)
        }
        guard case .complete(let snapshot) = result else {
            Issue.record("Expected a complete sidecar snapshot")
            return
        }

        #expect(snapshot.requestID == requestID)
        #expect(snapshot.requestedImageURLs == [first, second])
        #expect(snapshot.inspectedImageURLs == [first, second])
        #expect(snapshot.metadataByImageURL[first]?.title == "First")
        #expect(snapshot.metadataByImageURL[second] == nil)
        #expect(probe.loadedURLs == [first, second])
    }

    @Test("cancellation after a synchronous read returns the exact inspected prefix")
    func cancellationAfterRead() async {
        let first = URL(fileURLWithPath: "/first.jpg")
        let second = URL(fileURLWithPath: "/second.jpg")
        let probe = FTPSidecarLoadProbe(
            metadataByURL: [first: IPTCMetadata(title: "First")],
            cancelsAfterLoadCount: 1
        )
        let queue = DispatchSerialQueue(label: "test.ftp.sidecar.cancellationAfterRead")
        let service = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: { url in
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(!Thread.isMainThread)
                #expect(FTPSidecarExecutorContext.marker == first)
                return probe.load(url)
            }), filesystemQueue: queue
        )

        let result = await Task {
            await FTPSidecarExecutorContext.$marker.withValue(first) {
                await service.load(imageURLs: [first, second], requestID: UUID())
            }
        }.value

        guard case .cancelledAfterPartialRead(let snapshot) = result else {
            Issue.record("Expected cancellation after the first sidecar read")
            return
        }
        #expect(snapshot.inspectedImageURLs == [first])
        #expect(snapshot.metadataByImageURL[first]?.title == "First")
        #expect(probe.loadedURLs == [first])
    }

    @Test("pre-read and post-complete-read cancellation remain distinguishable")
    func cancellationEdgeStates() async {
        let url = URL(fileURLWithPath: "/only.jpg")
        let preReadProbe = FTPSidecarLoadProbe()
        let preReadService = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: preReadProbe.load)
        )
        let preReadRequestID = UUID()
        let preRead = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await preReadService.load(
                imageURLs: [url],
                requestID: preReadRequestID
            )
        }.value

        #expect(preRead == .cancelledBeforeRead(
            requestID: preReadRequestID,
            requestedImageURLs: [url]
        ))
        #expect(preReadProbe.loadedURLs.isEmpty)

        let completedProbe = FTPSidecarLoadProbe(cancelsAfterLoadCount: 1)
        let completedService = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: completedProbe.load)
        )
        let completed = await Task {
            await completedService.load(imageURLs: [url], requestID: UUID())
        }.value

        guard case .cancelledAfterCompleteRead(let snapshot) = completed else {
            Issue.record("Expected cancellation after the complete final read")
            return
        }
        #expect(snapshot.inspectedImageURLs == [url])
        #expect(snapshot.isComplete)
        #expect(completedProbe.loadedURLs == [url])
    }

    @MainActor
    @Test("blocked sidecar reads leave MainActor and serialize queued cancellation")
    func blockedReadStaysOffMainActor() async throws {
        let probe = FTPSidecarLoadProbe(blocksFirstLoad: true)
        defer { probe.releaseFirstLoad() }
        let service = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: probe.load)
        )
        let firstURL = URL(fileURLWithPath: "/first.jpg")
        let secondURL = URL(fileURLWithPath: "/second.jpg")
        let first = Task {
            await service.load(imageURLs: [firstURL], requestID: UUID())
        }
        try await probe.waitUntilFirstLoadStarts()

        #expect(probe.loadedURLs == [firstURL])
        let second = Task {
            await service.load(imageURLs: [secondURL], requestID: UUID())
        }
        second.cancel()
        probe.releaseFirstLoad()

        #expect((await first.value).completeSnapshot?.inspectedImageURLs == [firstURL])
        guard case .cancelledBeforeRead(_, let requestedImageURLs) = await second.value else {
            Issue.record("Expected the queued request to cancel before reading")
            return
        }
        #expect(requestedImageURLs == [secondURL])
        #expect(probe.loadedURLs == [firstURL])
        #expect(!probe.ranOnMainThread)
    }

    @Test("FTP preflight awaits actor sidecars and publishes only current complete inspection")
    func uploadViewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/FTP/FTPUploadView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(".task(id: inspectionRequestKey)"))
        #expect(source.contains("await sidecarLoadService.load("))
        #expect(source.contains("sidecarSnapshot.requestID == requestID"))
        #expect(source.contains("inspectionRequestID == requestID"))
        #expect(source.contains("isInspectingFiles"))
        #expect(source.contains("sidecarMergeTask?.cancel()"))
        #expect(source.contains("sidecarMergeRequestID == requestID"))
        #expect(source.contains("inspectionRequestKey == originatingInspectionKey"))
        #expect(source.contains(".onDisappear {\n            cancelSidecarMerge()"))
        #expect(!source.contains("Self.loadSidecars(for:"))
        #expect(!source.contains("XMPSidecarService().loadSidecar(for:"))

        let entryGuard = try #require(source.range(
            of: "guard !Task.isCancelled,\n              inspectionRequestKey == requestKey else { return }"
        ))
        let ownershipClaim = try #require(source.range(of: "inspectionRequestID = requestID"))
        #expect(entryGuard.lowerBound < ownershipClaim.lowerBound)
    }
}

private extension FTPUploadSidecarLoadResult {
    var completeSnapshot: FTPUploadSidecarSnapshot? {
        guard case .complete(let snapshot) = self else { return nil }
        return snapshot
    }
}

private enum FTPSidecarLoadProbeError: Error {
    case timedOut
}

private nonisolated final class FTPSidecarLoadProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let metadataByURL: [URL: IPTCMetadata]
    private let cancelsAfterLoadCount: Int?
    private let blocksFirstLoad: Bool
    private var urls: [URL] = []
    private var firstLoadReleased = false
    private var observedMainThread = false

    init(
        metadataByURL: [URL: IPTCMetadata] = [:],
        cancelsAfterLoadCount: Int? = nil,
        blocksFirstLoad: Bool = false
    ) {
        self.metadataByURL = metadataByURL
        self.cancelsAfterLoadCount = cancelsAfterLoadCount
        self.blocksFirstLoad = blocksFirstLoad
    }

    func load(_ url: URL) -> IPTCMetadata? {
        condition.lock()
        urls.append(url)
        observedMainThread = observedMainThread || Thread.isMainThread
        let loadCount = urls.count
        condition.broadcast()
        if blocksFirstLoad, loadCount == 1 {
            while !firstLoadReleased {
                if !condition.waitBounded() { break }
            }
        }
        condition.unlock()

        if cancelsAfterLoadCount == loadCount {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return metadataByURL[url]
    }

    func waitUntilFirstLoadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while loadedURLs.isEmpty {
            guard ContinuousClock.now < deadline else {
                // A test that gives up must not leave the probe holding a shared queue.
                releaseFirstLoad()
                throw FTPSidecarLoadProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstLoad() {
        condition.lock()
        firstLoadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var loadedURLs: [URL] {
        condition.lock()
        defer { condition.unlock() }
        return urls
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedMainThread
    }
}

private struct FTPFileSystemFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FTPFileSystemBoundaryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("FTPService.remoteUploadURL")
struct FTPRemoteURLTests {

    private func url(_ filename: String, _ connection: FTPConnection) -> String {
        FTPService.remoteUploadURL(for: filename, connection: connection)
    }

    @Test("# is encoded so the remote path is not truncated at the fragment")
    func encodesHash() {
        let conn = FTPConnection(host: "example.com", port: 21, remotePath: "/incoming/", useSFTP: false)
        #expect(url("Shot #3.jpg", conn) == "ftp://example.com:21/incoming/Shot%20%233.jpg")
    }

    @Test("? is encoded so it is not split off as a query")
    func encodesQuestionMark() {
        let conn = FTPConnection(host: "h", port: 21, remotePath: "/d/", useSFTP: false)
        #expect(url("a?b.jpg", conn).hasSuffix("/d/a%3Fb.jpg"))
    }

    @Test("brackets, spaces and percent are encoded and round-trip via curl's decode")
    func encodesGlobAndSpecials() {
        let conn = FTPConnection(host: "h", port: 21, remotePath: "/d/", useSFTP: false)
        #expect(url("IMG_[2].jpg", conn).hasSuffix("/d/IMG_%5B2%5D.jpg"))
        #expect(url("50% off {final}.jpg", conn).hasSuffix("/d/50%25%20off%20%7Bfinal%7D.jpg"))
    }

    @Test("scheme is sftp for SFTP connections; plain names are unchanged")
    func schemeAndPlainNames() {
        let sftp = FTPConnection(host: "h", port: 22, remotePath: "/d/", useSFTP: true)
        #expect(url("plain.jpg", sftp) == "sftp://h:22/d/plain.jpg")
    }

    @Test("a missing trailing slash on the remote path is added")
    func addsTrailingSlash() {
        let conn = FTPConnection(host: "h", port: 21, remotePath: "/d", useSFTP: false)
        #expect(url("a.jpg", conn) == "ftp://h:21/d/a.jpg")
    }

    @Test("remote directory specials are encoded while / separators stay intact")
    func encodesRemotePathSpecials() {
        // A space in a remote directory would break the URL, and a '#'/'?' would
        // truncate it at the fragment/query — the directory must be encoded like the
        // filename, but its '/' separators must survive.
        let spaced = FTPConnection(host: "h", port: 21, remotePath: "/My Photos/2026", useSFTP: false)
        #expect(url("a.jpg", spaced) == "ftp://h:21/My%20Photos/2026/a.jpg")

        let hashed = FTPConnection(host: "h", port: 21, remotePath: "/in#box/", useSFTP: false)
        #expect(url("a.jpg", hashed) == "ftp://h:21/in%23box/a.jpg")
    }
}

@Suite("FTPConnection Codable")
struct FTPConnectionCodableTests {

    @Test("new profiles default to verified FTPS, never SFTP (macOS curl has no sftp)")
    func newProfileSafeDefault() {
        let connection = FTPConnection.secureDefault
        #expect(!connection.useSFTP)
        #expect(connection.useTLS)
        #expect(!connection.allowInsecureHostVerification)
        #expect(connection.port == 21)
        #expect(connection.transportSecurity == DeliveryTransportSecurity(
            protocolKind: .explicitFTPS,
            verificationEnabled: true
        ))
        #expect(!connection.transportSecurity.isInsecure)
        #expect(!connection.requiresFirstInsecureUploadAcknowledgement)
    }

    @Test("Save validation requires a user name, a password and a usable host")
    func saveValidation() {
        var connection = FTPConnection.secureDefault
        connection.name = "Desk"
        connection.host = "ftp.example.com"
        connection.username = "user"
        #expect(connection.saveValidationMessage(password: "pa ss#1") == nil)
        #expect(connection.saveValidationMessage(password: "") != nil)
        connection.username = ""
        #expect(connection.saveValidationMessage(password: "secret") != nil)
        connection.username = "user"
        connection.host = "ftp example.com"
        #expect(connection.saveValidationMessage(password: "secret") != nil)
    }

    @Test("plain FTP and disabled server verification are classified as insecure")
    func insecureClassification() {
        let ftp = FTPConnection(useSFTP: false, useTLS: false)
        let ftps = FTPConnection(
            useSFTP: false,
            useTLS: true,
            allowInsecureHostVerification: true
        )
        let sftp = FTPConnection(useSFTP: true, allowInsecureHostVerification: true)

        #expect(ftp.transportSecurity.protocolKind == .ftp)
        #expect(ftp.transportSecurity.isInsecure)
        #expect(ftps.transportSecurity.protocolKind == .explicitFTPS)
        #expect(ftps.transportSecurity.isInsecure)
        #expect(sftp.transportSecurity.protocolKind == .sftp)
        #expect(sftp.transportSecurity.isInsecure)
    }

    @Test("first-upload acknowledgement is exact to the insecure transport state")
    func acknowledgementInvalidatesOnSecurityChange() throws {
        var connection = FTPConnection(useSFTP: false, useTLS: false)
        #expect(connection.requiresFirstInsecureUploadAcknowledgement)
        connection.acknowledgeFirstInsecureUpload()
        #expect(!connection.requiresFirstInsecureUploadAcknowledgement)

        connection.useTLS = true
        connection.normalizeTransportAcknowledgement()
        #expect(connection.firstUploadAcknowledgedSecurity == nil)
        #expect(!connection.requiresFirstInsecureUploadAcknowledgement)

        connection.allowInsecureHostVerification = true
        #expect(connection.requiresFirstInsecureUploadAcknowledgement)
        let decoded = try JSONDecoder().decode(
            FTPConnection.self,
            from: JSONEncoder().encode(connection)
        )
        #expect(decoded.requiresFirstInsecureUploadAcknowledgement)
    }

    @Test("legacy JSON without useTLS decodes to useTLS == false")
    func legacyDecodeDefaultsTLSOff() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"old","host":"h",\
        "port":21,"username":"u","remotePath":"/","useSFTP":false,\
        "allowInsecureHostVerification":false}
        """.data(using: .utf8)!
        let conn = try JSONDecoder().decode(FTPConnection.self, from: legacy)
        #expect(conn.useTLS == false)
        #expect(conn.host == "h")
        #expect(conn.requiresFirstInsecureUploadAcknowledgement)
    }

    @Test("useTLS survives an encode/decode roundtrip")
    func roundtripPreservesTLS() throws {
        let original = FTPConnection(name: "secure", host: "h", useSFTP: false, useTLS: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FTPConnection.self, from: data)
        #expect(decoded.useTLS == true)
        #expect(decoded == original)
    }
}

@MainActor
@Suite("FTPViewModel transport acknowledgement")
struct FTPViewModelTransportAcknowledgementTests {
    @Test("plain upload fails closed before credential lookup or history creation")
    func plainUploadFailsClosed() {
        let viewModel = FTPViewModel()
        let connection = FTPConnection(name: "Desk", host: "example.invalid")

        let started = viewModel.uploadFiles(
            [URL(fileURLWithPath: "/private/tmp/should-not-upload.jpg")],
            to: connection
        )

        #expect(!started)
        #expect(viewModel.uploadAdmissionError ==
            "Acknowledge this insecure delivery connection before its first upload.")
        #expect(viewModel.errorMessages.isEmpty)
        #expect(!viewModel.isUploading)
        #expect(viewModel.uploadHistory.entries.isEmpty)
    }

    @Test("SFTP profiles and a missing password are refused without starting a run")
    func refusedUploadsReportNotStarted() throws {
        let suite = "FTPAdmissionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lookups = FTPPasswordLookupCounter()
        var execution = FTPUploadExecutionAccess()
        execution.password = { _ in
            lookups.count += 1
            return nil
        }
        execution.upload = { _, _, _, _ in Issue.record("A refused upload reached the transport") }
        let viewModel = FTPViewModel(defaults: defaults, execution: execution)
        let file = URL(fileURLWithPath: "/private/tmp/should-not-upload.jpg")

        let sftp = FTPConnection(name: "Legacy", host: "example.invalid", port: 22, useSFTP: true)
        #expect(!viewModel.uploadFiles([file], to: sftp))
        #expect(viewModel.uploadAdmissionError == FTPConnection.sftpUnavailableMessage)
        #expect(lookups.count == 0)

        let ftps = FTPConnection(name: "Desk", host: "example.invalid", useTLS: true)
        #expect(!viewModel.uploadFiles([file], to: ftps))
        #expect(viewModel.uploadAdmissionError?.hasPrefix("No password found for Desk") == true)
        #expect(!viewModel.isUploading && !viewModel.uploadCompleted)
        #expect(viewModel.errorMessages.isEmpty)
        #expect(viewModel.uploadHistory.entries.isEmpty)
    }

    @Test("rendering upload fails closed before rendering or credential lookup")
    func renderedUploadFailsClosed() {
        let viewModel = FTPViewModel()
        let url = URL(fileURLWithPath: "/private/tmp/should-not-render.jpg")
        let connection = FTPConnection(name: "Desk", host: "example.invalid")

        let started = viewModel.uploadFiles(
            [url],
            renderURLs: [url],
            to: connection,
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            inMemoryCameraRaw: { _ in nil }
        )

        #expect(!started)
        #expect(viewModel.uploadAdmissionError ==
            "Acknowledge this insecure delivery connection before its first upload.")
        #expect(!viewModel.isUploading)
        #expect(!viewModel.isRendering)
        #expect(viewModel.uploadHistory.entries.isEmpty)
    }
}

@MainActor
private final class FTPPasswordLookupCounter {
    var count = 0
}

@MainActor
@Suite("FTPViewModel shared server list")
struct FTPViewModelConnectionSyncTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "FTPConnectionSyncTests.\(UUID())"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func store(_ connections: [FTPConnection], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(connections), forKey: UserDefaultsKeys.ftpConnections)
    }

    @Test("a mutation re-reads the stored list instead of saving a stale cache")
    func mutationPreservesOtherWindowsChanges() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = FTPConnection(name: "Plain", host: "a.invalid", username: "u")
        try store([plain], in: defaults)
        let settings = FTPViewModel(defaults: defaults)
        settings.loadConnections()

        // The other window adds a server; this instance's cache doesn't know about it yet.
        let added = FTPConnection(name: "Added", host: "b.invalid", username: "u", useTLS: true)
        try store([plain, added], in: defaults)

        #expect(settings.acknowledgeFirstInsecureUpload(connectionID: plain.id) != nil)
        let stored = try JSONDecoder().decode(
            [FTPConnection].self,
            from: try #require(defaults.data(forKey: UserDefaultsKeys.ftpConnections))
        )
        #expect(stored.map(\.id) == [plain.id, added.id])
        #expect(stored.first?.requiresFirstInsecureUploadAcknowledgement == false)
        #expect(settings.connections.map(\.id) == [plain.id, added.id])
    }

    @Test("the other instance sharing the store reloads after a save")
    func otherInstanceReloads() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = FTPConnection(name: "Plain", host: "a.invalid", username: "u")
        try store([plain], in: defaults)
        let settings = FTPViewModel(defaults: defaults)
        let main = FTPViewModel(defaults: defaults)
        settings.loadConnections()
        main.loadConnections()

        _ = settings.acknowledgeFirstInsecureUpload(connectionID: plain.id)
        for _ in 0..<200 where main.connections.first?.requiresFirstInsecureUploadAcknowledgement == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(main.connections.first?.requiresFirstInsecureUploadAcknowledgement == false)
    }
}

private nonisolated enum FTPSidecarExecutorContext {
    @TaskLocal static var marker: URL?
}

@Suite("FTP upload generation isolation")
@MainActor
struct FTPUploadGenerationIsolationTests {
    @Test("Late cancelled transfer results and progress cannot alter a restarted run", arguments: [false, true])
    func cancelledTransferCannotMutateRestart(fails: Bool) async throws {
        try await withFixture(blocked: ["upload:old.jpg", "upload:new.jpg"]) { fixture in
            let vm = fixture.model
            vm.uploadFiles([fixture.old], to: fixture.connection)
            try await fixture.gate.waitFor("upload:old.jpg")
            let waitOld = fixture.captureCompletion()
            vm.cancelUpload()
            vm.uploadFiles([fixture.new], to: fixture.connection)
            try await fixture.gate.waitFor("upload:new.jpg")
            let waitNew = fixture.captureCompletion()
            await fixture.gate.emit("upload:old.jpg", fileName: "old.jpg", fraction: 0.8)
            await fixture.gate.release("upload:old.jpg", fails: fails)
            await waitOld()
            await drainProgressCallbacks()
            #expect(vm.isUploading && !vm.isRendering && !vm.uploadCompleted)
            #expect(vm.completedCount == 0 && vm.overallProgress == 0)
            #expect(vm.errorMessages.isEmpty && vm.uploadProgress.isEmpty)
            #expect(vm.uploadHistory.entries.filter { $0.completedAt != nil }.isEmpty)
            await fixture.gate.release("upload:new.jpg")
            await waitNew()
            #expect(vm.uploadCompleted && vm.completedCount == 1)
            #expect(vm.uploadProgress["new.jpg"]?.isComplete == true)
            #expect(vm.uploadProgress["old.jpg"] == nil)
            #expect(vm.errorMessages.isEmpty)
        }
    }

    @Test("A late progress callback cannot regress an already completed file")
    func completedFileRejectsLateProgress() async throws {
        try await withFixture(blocked: ["upload:old.jpg", "upload:new.jpg"]) { fixture in
            fixture.model.uploadFiles([fixture.old, fixture.new], to: fixture.connection)
            try await fixture.gate.waitFor("upload:old.jpg")
            let completion = fixture.captureCompletion()
            await fixture.gate.release("upload:old.jpg")
            try await fixture.gate.waitFor("upload:new.jpg")
            await fixture.gate.emit("upload:old.jpg", fileName: "old.jpg", fraction: 0.2)
            await drainProgressCallbacks()
            #expect(fixture.model.isUploading && !fixture.model.uploadCompleted)
            #expect(fixture.model.completedCount == 1 && fixture.model.overallProgress == 0.5)
            #expect(fixture.model.uploadProgress["old.jpg"]?.isComplete == true)
            #expect(fixture.model.uploadProgress["old.jpg"]?.fractionCompleted == 1)
            await fixture.gate.release("upload:new.jpg")
            await completion()
            #expect(fixture.model.uploadCompleted && fixture.model.completedCount == 2)
            await fixture.gate.emit("upload:old.jpg", fileName: "old.jpg", fraction: 0.1)
            await drainProgressCallbacks()
            #expect(fixture.model.overallProgress == 1)
            #expect(fixture.model.uploadProgress["old.jpg"]?.isComplete == true)
        }
    }

    @Test("An obsolete render cannot sequence, sign or upload after restart")
    func obsoleteRenderCannotPublish() async throws {
        try await withFixture(blocked: ["render", "upload:new.jpg"]) { fixture in
            fixture.startRendered(signing: true)
            try await fixture.gate.waitFor("render")
            let waitOld = fixture.captureCompletion()
            fixture.model.cancelUpload()
            fixture.model.uploadFiles([fixture.new], to: fixture.connection)
            try await fixture.gate.waitFor("upload:new.jpg")
            let waitNew = fixture.captureCompletion()
            await fixture.gate.release("render")
            await waitOld()
            #expect(FileManager.default.fileExists(atPath: fixture.rendered.path))
            #expect(await fixture.gate.count("sign") == 0)
            #expect(await fixture.gate.totalUploadCalls == 1)
            #expect(fixture.model.isUploading && !fixture.model.isRendering)
            #expect(fixture.model.renderCompletedCount == 0)
            #expect(fixture.model.renderedUploadedFolders.isEmpty)
            #expect(fixture.model.errorMessages.isEmpty && !fixture.model.uploadCompleted)
            await fixture.gate.release("upload:new.jpg")
            await waitNew()
            #expect(fixture.model.uploadCompleted && fixture.model.completedCount == 1)
        }
    }

    @Test("Obsolete signing success or failure cannot clear or report into a restarted run", arguments: [false, true])
    func obsoleteSigningCannotMutateRestart(fails: Bool) async throws {
        try await withFixture(blocked: ["sign", "upload:new.jpg"]) { fixture in
            fixture.startRendered(signing: true)
            try await fixture.gate.waitFor("sign")
            let waitOld = fixture.captureCompletion()
            fixture.model.cancelUpload()
            fixture.model.uploadFiles([fixture.new], to: fixture.connection)
            try await fixture.gate.waitFor("upload:new.jpg")
            let waitNew = fixture.captureCompletion()
            await fixture.gate.release("sign", fails: fails)
            await waitOld()
            #expect(await fixture.gate.totalUploadCalls == 1)
            #expect(fixture.model.isUploading && !fixture.model.isRendering)
            #expect(fixture.model.errorMessages.isEmpty && !fixture.model.uploadCompleted)
            #expect(fixture.model.completedCount == 0 && fixture.model.overallProgress == 0)
            await fixture.gate.release("upload:new.jpg")
            await waitNew()
            #expect(fixture.model.uploadCompleted && fixture.model.completedCount == 1)
        }
    }

    @Test("An obsolete preparation cannot clear a newer rendering generation", arguments: ["render", "sign"])
    func obsoletePreparationCannotClearNewRender(oldPhase: String) async throws {
        try await withFixture(blocked: [oldPhase, "render:new.jpg"]) { fixture in
            fixture.startRendered(signing: true)
            try await fixture.gate.waitFor(oldPhase)
            let waitOld = fixture.captureCompletion()
            fixture.startRendered(signing: false, source: fixture.new)
            try await fixture.gate.waitFor("render:new.jpg")
            let waitNew = fixture.captureCompletion()
            await fixture.gate.release(oldPhase)
            await waitOld()
            #expect(fixture.model.isRendering && !fixture.model.isUploading)
            #expect(!fixture.model.uploadCompleted && fixture.model.errorMessages.isEmpty)
            #expect(fixture.model.renderCompletedCount == 0 && fixture.model.overallProgress == 0)
            #expect(await fixture.gate.totalUploadCalls == 0)
            await fixture.gate.release("render:new.jpg")
            await waitNew()
            #expect(fixture.model.uploadCompleted && fixture.model.completedCount == 1)
        }
    }

    @Test("A signing failure ends in a visible stopped state and records the files as failed")
    func signingFailureEndsStopped() async throws {
        try await withFixture(blocked: ["sign"]) { fixture in
            let history = ActivityHistoryStore()
            fixture.model.activityHistory = history
            fixture.startRendered(signing: true)
            try await fixture.gate.waitFor("sign")
            let completion = fixture.captureCompletion()
            await fixture.gate.release("sign", fails: true)
            await completion()
            #expect(fixture.model.uploadCompleted && fixture.model.uploadStopped)
            #expect(!fixture.model.isRendering && !fixture.model.isUploading)
            #expect(fixture.model.errorMessages.contains { $0.hasPrefix("Upload stopped") })
            #expect(await fixture.gate.totalUploadCalls == 0)
            let entry = try #require(history.entries.first)
            #expect(entry.successCount == 0 && entry.totalCount == 1)
            #expect(entry.files.map(\.succeeded) == [false])
        }
    }

    @Test("Cancelling an upload records a cancelled Activity entry with what completed")
    func cancelRecordsActivity() async throws {
        try await withFixture(blocked: ["upload:old.jpg", "upload:new.jpg"]) { fixture in
            let history = ActivityHistoryStore()
            history.clear()
            fixture.model.activityHistory = history
            fixture.model.uploadFiles([fixture.old, fixture.new], to: fixture.connection)
            try await fixture.gate.waitFor("upload:old.jpg")
            _ = fixture.captureCompletion()
            await fixture.gate.release("upload:old.jpg")
            try await fixture.gate.waitFor("upload:new.jpg")
            fixture.model.cancelUpload()
            let entry = try #require(history.entries.first)
            #expect(entry.wasCancelled)
            #expect(entry.kind == .upload)
            #expect(entry.successCount == 1 && entry.totalCount == 2)
            #expect(entry.files.map(\.fileName) == ["new.jpg", "old.jpg"])
            #expect(entry.files.map(\.succeeded) == [false, true])
            #expect(history.entries.count == 1)
            history.clear()
        }
    }

    @Test("Activity history keeps the selected count and lists files that failed to prepare")
    func activityHistoryIncludesUnpreparedFiles() async throws {
        try await withFixture(blocked: ["render:new.jpg"]) { fixture in
            let history = ActivityHistoryStore()
            fixture.model.activityHistory = history
            fixture.model.uploadFiles([fixture.old, fixture.new], renderURLs: [fixture.new],
                to: fixture.connection, readService: SwiftExifReadService(),
                writeEngine: SwiftExifWriteEngine(), inMemoryCameraRaw: { _ in nil })
            try await fixture.gate.waitFor("render:new.jpg")
            let completion = fixture.captureCompletion()
            await fixture.gate.release("render:new.jpg", fails: true)
            await completion()
            #expect(fixture.model.uploadCompleted && !fixture.model.uploadStopped)
            let entry = try #require(history.entries.first)
            #expect(entry.totalCount == 2 && entry.successCount == 1)
            #expect(entry.files.map(\.fileName) == ["new.jpg", "old.jpg"])
            #expect(entry.files.map(\.succeeded) == [false, true])
        }
    }

    private func withFixture(blocked: Set<String>,
                             operation: (FTPGenerationFixture) async throws -> Void) async throws {
        let fixture = try FTPGenerationFixture(blocked: blocked)
        do {
            try await operation(fixture)
        } catch {
            await fixture.finish()
            fixture.remove()
            throw error
        }
        await fixture.finish()
        fixture.remove()
    }

    private func drainProgressCallbacks() async {
        // The transport callback deliberately schedules MainActor work independently of
        // the awaited transfer. Yield so queued callback work can run before inspection.
        for _ in 0..<20 { await Task.yield() }
    }
}


@MainActor
private final class FTPGenerationFixture {
    let root: URL
    let old: URL
    let new: URL
    let rendered: URL
    let gate: FTPGenerationGate
    let model: FTPViewModel
    let connection = FTPConnection(name: "Isolated fixture", host: "fixture.invalid", port: 21, useTLS: true)
    private let defaults: UserDefaults
    private let suite: String
    private let watchdog: Task<Void, Never>
    private var completions: [@Sendable () async -> Void] = []
    private var finished = false

    init(blocked: Set<String>) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        old = root.appendingPathComponent("old.jpg")
        new = root.appendingPathComponent("new.jpg")
        rendered = root.appendingPathComponent("Uploaded/old-render.jpg")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: old)
        try jpeg.write(to: new)
        suite = "FTPGenerationTests.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        let probe = FTPGenerationGate(blocked: blocked)
        gate = probe
        var execution = FTPUploadExecutionAccess()
        execution.password = { _ in "fixture-only" }
        execution.upload = { url, _, _, progress in
            await probe.registerProgress(progress, for: "upload:\(url.lastPathComponent)")
            try await probe.block("upload:\(url.lastPathComponent)")
        }
        execution.render = { source, _, folder, _, _, _ in
            let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-render.jpg")
            try FileManager.default.copyItem(at: source, to: output)
            try await probe.block(source.lastPathComponent == "old.jpg" ? "render" : "render:\(source.lastPathComponent)")
            return output
        }
        execution.sign = { _, _ in try await probe.block("sign") }
        model = FTPViewModel(fileSystem: FTPUploadFileSystemBoundary(temporaryRoot: root),
                             defaults: defaults, execution: execution)
        watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            await probe.releaseAll(expired: true)
        }
    }

    func startRendered(signing: Bool, source: URL? = nil) {
        let source = source ?? old
        model.uploadFiles([source], renderURLs: [source], to: connection,
            readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            inMemoryCameraRaw: { _ in nil },
            signingConfiguration: signing ? C2PAUploadSigningConfiguration(certificatePath: "unused",
                privateKeyPEM: "unused", author: nil, usesTestCertificate: false) : nil)
    }

    func captureCompletion() -> @Sendable () async -> Void {
        let completion = model.currentUploadCompletion()
        completions.append(completion)
        return completion
    }

    func finish() async {
        await gate.releaseAll()
        let current = model.currentUploadCompletion()
        for completion in completions { await completion() }
        await current()
        #expect(await !gate.expired)
        watchdog.cancel()
        finished = true
    }

    func remove() {
        guard finished else {
            // Throwing test exits still release and join every captured generation;
            // retain the watchdog until all injected operations have been unwound.
            _ = captureCompletion()
            model.cancelUpload()
            Task { await finish(); remove() }
            return
        }
        model.cancelUpload()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FTPGenerationGate {
    private let blocked: Set<String>
    private var counts: [String: Int] = [:]
    private var callbacks: [String: @Sendable (FTPUploadProgress) -> Void] = [:]
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var failures: Set<String> = []
    private(set) var expired = false
    init(blocked: Set<String>) { self.blocked = blocked }
    func count(_ key: String) -> Int { counts[key, default: 0] }
    var totalUploadCalls: Int { counts.filter { $0.key.hasPrefix("upload:") }.values.reduce(0, +) }
    func registerProgress(_ callback: @escaping @Sendable (FTPUploadProgress) -> Void, for key: String) {
        callbacks[key] = callback
    }
    func block(_ key: String) async throws {
        counts[key, default: 0] += 1
        if blocked.contains(key), !released.contains(key) {
            await withCheckedContinuation { continuations[key] = $0 }
        }
        if failures.contains(key) { throw CocoaError(.fileWriteUnknown) }
    }
    func release(_ key: String, fails: Bool = false) {
        released.insert(key)
        if fails { failures.insert(key) }
        continuations.removeValue(forKey: key)?.resume()
    }
    func releaseAll(expired: Bool = false) {
        self.expired = self.expired || expired
        for key in blocked { release(key) }
    }
    func emit(_ key: String, fileName: String, fraction: Double) {
        callbacks[key]?(FTPUploadProgress(fileName: fileName, bytesUploaded: 20,
            totalBytes: 100, fractionCompleted: fraction, isComplete: false))
    }
    func waitFor(_ key: String) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while count(key) == 0 {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
