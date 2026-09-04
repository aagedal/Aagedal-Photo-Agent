import Testing
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
                condition.wait()
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
        let service = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: probe.load)
        )

        let result = await service.load(imageURLs: [first, second], requestID: requestID)
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
        let service = FTPUploadSidecarLoadService(
            access: FTPUploadSidecarAccess(load: probe.load)
        )

        let result = await Task {
            await service.load(imageURLs: [first, second], requestID: UUID())
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
                condition.wait()
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

    @Test("new profiles default to verified SFTP")
    func newProfileSafeDefault() {
        let connection = FTPConnection.secureDefault
        #expect(connection.useSFTP)
        #expect(connection.port == 22)
        #expect(connection.transportSecurity == DeliveryTransportSecurity(
            protocolKind: .sftp,
            verificationEnabled: true
        ))
        #expect(!connection.transportSecurity.isInsecure)
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

        viewModel.uploadFiles(
            [URL(fileURLWithPath: "/private/tmp/should-not-upload.jpg")],
            to: connection
        )

        #expect(viewModel.errorMessages == [
            "Acknowledge this insecure delivery connection before its first upload."
        ])
        #expect(!viewModel.isUploading)
        #expect(viewModel.uploadHistory.entries.isEmpty)
    }

    @Test("rendering upload fails closed before rendering or credential lookup")
    func renderedUploadFailsClosed() {
        let viewModel = FTPViewModel()
        let url = URL(fileURLWithPath: "/private/tmp/should-not-render.jpg")
        let connection = FTPConnection(name: "Desk", host: "example.invalid")

        viewModel.uploadFiles(
            [url],
            renderURLs: [url],
            to: connection,
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            inMemoryCameraRaw: { _ in nil }
        )

        #expect(viewModel.errorMessages == [
            "Acknowledge this insecure delivery connection before its first upload."
        ])
        #expect(!viewModel.isUploading)
        #expect(!viewModel.isRendering)
        #expect(viewModel.uploadHistory.entries.isEmpty)
    }
}
