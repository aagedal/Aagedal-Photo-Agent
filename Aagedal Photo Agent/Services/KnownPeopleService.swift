import Foundation
import Vision
import AppKit
import os
import os.log

private let knownPeopleLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "KnownPeopleService"
)

nonisolated struct KnownPeopleThumbnailLoadSnapshot: Sendable, Equatable {
    let requestID: UUID
    let fileURL: URL
    let data: Data?
}

nonisolated enum KnownPeopleThumbnailLoadResult: Sendable, Equatable {
    case loaded(KnownPeopleThumbnailLoadSnapshot)
    case cancelledBeforeRead(requestID: UUID, fileURL: URL)
    case cancelledAfterRead(requestID: UUID, fileURL: URL)
}

nonisolated struct KnownPeopleThumbnailFileAccess: Sendable {
    let readData: @Sendable (URL) -> Data?

    static let system = KnownPeopleThumbnailFileAccess { url in
        try? CloudCoordinatedIO.readData(at: url)
    }
}

/// Serializes coordinated Known People thumbnail reads away from MainActor. The underlying
/// Foundation/iCloud read cannot be interrupted once entered, so cancellation is sampled on both
/// sides and callers publish only a complete snapshot for their current storage revision.
actor KnownPeopleThumbnailLoadService {
    static let shared = KnownPeopleThumbnailLoadService()

    private let access: KnownPeopleThumbnailFileAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "KnownPeopleThumbnailLoad"
    )

    init(access: KnownPeopleThumbnailFileAccess = .system) {
        self.access = access
    }

    func load(fileURL: URL, requestID: UUID) -> KnownPeopleThumbnailLoadResult {
        let interval = signposter.beginInterval(
            "Read",
            id: signposter.makeSignpostID()
        )
        guard !Task.isCancelled else {
            signposter.endInterval("Read", interval, "result=cancelled stage=before-read")
            return .cancelledBeforeRead(requestID: requestID, fileURL: fileURL)
        }
        let data = access.readData(fileURL)
        guard !Task.isCancelled else {
            signposter.endInterval("Read", interval, "result=cancelled stage=after-read")
            return .cancelledAfterRead(requestID: requestID, fileURL: fileURL)
        }
        signposter.endInterval("Read", interval, "result=complete found=\(data != nil)")
        return .loaded(KnownPeopleThumbnailLoadSnapshot(
            requestID: requestID,
            fileURL: fileURL,
            data: data
        ))
    }
}

nonisolated struct KnownPeopleArchiveImportPayload: Sendable {
    let people: [KnownPerson]
    let personThumbnails: [UUID: Data]
    let embeddingThumbnails: [UUID: Data]
}

nonisolated struct KnownPeopleArchiveImportCommitRequest: Sendable {
    let requestID: UUID
    let storageRoot: URL
    let people: [KnownPerson]
    let personThumbnails: [UUID: Data]
    let embeddingThumbnails: [UUID: Data]
}

nonisolated struct KnownPeopleArchiveImportCommitEvidence: Sendable {
    let requestID: UUID
    let storageRoot: URL
    let requestedPersonCount: Int
    let committedPeople: [KnownPerson]
    let committedFileURLs: [URL]
    let committedThumbnailURLs: [URL]
    let failedThumbnailCount: Int
}

nonisolated enum KnownPeopleArchiveImportCommitResult: Sendable {
    case complete(KnownPeopleArchiveImportCommitEvidence)
    case cancelled(KnownPeopleArchiveImportCommitEvidence)
    case failed(KnownPeopleArchiveImportCommitEvidence, message: String)
}

nonisolated struct KnownPeopleArchiveFileAccess: Sendable {
    let temporaryDirectory: URL
    let createDirectory: @Sendable (URL) throws -> Void
    let removeItem: @Sendable (URL) throws -> Void
    let contentsOfDirectory: @Sendable (URL) throws -> [URL]
    let isDirectory: @Sendable (URL) -> Bool
    let itemExists: @Sendable (URL) -> Bool
    let readData: @Sendable (URL) throws -> Data
    let readCoordinatedData: @Sendable (URL) throws -> Data
    let writeData: @Sendable (Data, URL) throws -> Void
    let writeCoordinatedData: @Sendable (Data, URL) throws -> Void
    let runDitto: @Sendable ([String]) async throws -> Void

    static let system = KnownPeopleArchiveFileAccess(
        temporaryDirectory: FileManager.default.temporaryDirectory,
        createDirectory: {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        contentsOfDirectory: {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        },
        isDirectory: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        },
        itemExists: { FileManager.default.fileExists(atPath: $0.path) },
        readData: { try Data(contentsOf: $0) },
        readCoordinatedData: { try CloudCoordinatedIO.readData(at: $0) },
        writeData: { try $0.write(to: $1) },
        writeCoordinatedData: { try CloudCoordinatedIO.writeData($0, to: $1) },
        runDitto: { try await KnownPeopleArchiveProcess.run(arguments: $0) }
    )
}

nonisolated private enum KnownPeopleArchiveProcess {
    static func run(arguments: [String]) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "KnownPeopleService",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "The Known People archive command failed."]
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try Task.checkCancellation()
    }
}

/// Serializes ZIP preparation away from MainActor. The actor owns the temporary directory for
/// the complete operation, samples cancellation around every synchronous Foundation/iCloud read,
/// and returns an immutable import payload. Destination persistence is serialized by this actor;
/// the Known People state owner keeps duplicate filtering and in-memory publication on MainActor.
actor KnownPeopleArchiveService {
    static let shared = KnownPeopleArchiveService()

    private let access: KnownPeopleArchiveFileAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "KnownPeopleArchiveImportCommit"
    )
    private var hasExclusiveAccess = false
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []

    init(access: KnownPeopleArchiveFileAccess = .system) {
        self.access = access
    }

    func export(
        people: [KnownPerson],
        thumbnailsDirectory: URL,
        embeddingThumbnailsDirectory: URL,
        destinationURL: URL,
        exportedBy: String?
    ) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try Task.checkCancellation()
        let tempDirectory = access.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? access.removeItem(tempDirectory) }

        let temporaryThumbnails = tempDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        let temporaryEmbeddingThumbnails = tempDirectory.appendingPathComponent(
            "embedding_thumbnails",
            isDirectory: true
        )
        try access.createDirectory(temporaryThumbnails)
        try access.createDirectory(temporaryEmbeddingThumbnails)

        let embeddingCount = people.reduce(0) { $0 + $1.embeddings.count }
        let manifest = KnownPeopleManifest(
            exportedBy: exportedBy,
            peopleCount: people.count,
            embeddingCount: embeddingCount
        )
        try access.writeData(
            JSONEncoder().encode(manifest),
            tempDirectory.appendingPathComponent("manifest.json")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try access.writeData(
            encoder.encode(people),
            tempDirectory.appendingPathComponent("people.json")
        )

        for person in people {
            try Task.checkCancellation()
            let thumbnail = thumbnailsDirectory.appendingPathComponent("\(person.id.uuidString).jpg")
            if access.itemExists(thumbnail),
               let data = try? access.readCoordinatedData(thumbnail) {
                try access.writeData(
                    data,
                    temporaryThumbnails.appendingPathComponent("\(person.id.uuidString).jpg")
                )
            }
            try Task.checkCancellation()

            for embedding in person.embeddings {
                try Task.checkCancellation()
                let thumbnail = embeddingThumbnailsDirectory.appendingPathComponent(
                    "\(embedding.id.uuidString).jpg"
                )
                if access.itemExists(thumbnail),
                   let data = try? access.readCoordinatedData(thumbnail) {
                    try access.writeData(
                        data,
                        temporaryEmbeddingThumbnails.appendingPathComponent(
                            "\(embedding.id.uuidString).jpg"
                        )
                    )
                }
                try Task.checkCancellation()
            }
        }

        try await access.runDitto([
            "-c", "-k", "--keepParent", tempDirectory.path, destinationURL.path
        ])
        try Task.checkCancellation()
    }

    func prepareImport(sourceURL: URL) async throws -> KnownPeopleArchiveImportPayload {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try Task.checkCancellation()
        let tempDirectory = access.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? access.removeItem(tempDirectory) }
        try access.createDirectory(tempDirectory)

        try await access.runDitto(["-x", "-k", sourceURL.path, tempDirectory.path])
        try Task.checkCancellation()

        let contents = try access.contentsOfDirectory(tempDirectory)
        let extractedDirectory = contents.first(where: access.isDirectory) ?? tempDirectory
        let peopleURL = extractedDirectory.appendingPathComponent("people.json")
        guard access.itemExists(peopleURL) else {
            throw NSError(domain: "KnownPeopleService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid archive: missing people.json"
            ])
        }

        let peopleData = try access.readData(peopleURL)
        try Task.checkCancellation()
        let people = try JSONDecoder().decode([KnownPerson].self, from: peopleData)
        let thumbnailsDirectory = extractedDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        let embeddingThumbnailsDirectory = extractedDirectory.appendingPathComponent(
            "embedding_thumbnails",
            isDirectory: true
        )
        var personThumbnails: [UUID: Data] = [:]
        var embeddingThumbnails: [UUID: Data] = [:]

        for person in people {
            try Task.checkCancellation()
            let thumbnail = thumbnailsDirectory.appendingPathComponent("\(person.id.uuidString).jpg")
            if access.itemExists(thumbnail), let data = try? access.readData(thumbnail) {
                personThumbnails[person.id] = data
            }
            try Task.checkCancellation()

            for embedding in person.embeddings {
                try Task.checkCancellation()
                let thumbnail = embeddingThumbnailsDirectory.appendingPathComponent(
                    "\(embedding.id.uuidString).jpg"
                )
                if access.itemExists(thumbnail), let data = try? access.readData(thumbnail) {
                    embeddingThumbnails[embedding.id] = data
                }
                try Task.checkCancellation()
            }
        }

        return KnownPeopleArchiveImportPayload(
            people: people,
            personThumbnails: personThumbnails,
            embeddingThumbnails: embeddingThumbnails
        )
    }

    /// Persists the filtered archive payload on the actor after preparation. Each person file is
    /// the durable commit boundary; thumbnail failures retain the historical best-effort behavior,
    /// while cancellation and person-write failures return the exact committed prefix.
    func commitImport(
        _ request: KnownPeopleArchiveImportCommitRequest
    ) async -> KnownPeopleArchiveImportCommitResult {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        let interval = signposter.beginInterval(
            "Commit",
            id: signposter.makeSignpostID()
        )
        let peopleDirectory = request.storageRoot.appendingPathComponent("people", isDirectory: true)
        let thumbnailsDirectory = request.storageRoot.appendingPathComponent("thumbnails", isDirectory: true)
        let embeddingThumbnailsDirectory = request.storageRoot.appendingPathComponent(
            "embedding_thumbnails",
            isDirectory: true
        )
        var committedPeople: [KnownPerson] = []
        var committedFileURLs: [URL] = []
        var committedThumbnailURLs: [URL] = []
        var failedThumbnailCount = 0

        func evidence() -> KnownPeopleArchiveImportCommitEvidence {
            KnownPeopleArchiveImportCommitEvidence(
                requestID: request.requestID,
                storageRoot: request.storageRoot,
                requestedPersonCount: request.people.count,
                committedPeople: committedPeople,
                committedFileURLs: committedFileURLs,
                committedThumbnailURLs: committedThumbnailURLs,
                failedThumbnailCount: failedThumbnailCount
            )
        }

        func cancelled() -> KnownPeopleArchiveImportCommitResult {
            let snapshot = evidence()
            signposter.endInterval(
                "Commit",
                interval,
                "result=cancelled requested=\(snapshot.requestedPersonCount) committed=\(snapshot.committedPeople.count) thumbnails=\(snapshot.committedThumbnailURLs.count) thumbnailFailures=\(snapshot.failedThumbnailCount)"
            )
            return .cancelled(snapshot)
        }

        guard !Task.isCancelled else { return cancelled() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for person in request.people {
            guard !Task.isCancelled else { return cancelled() }

            if let data = request.personThumbnails[person.id] {
                let url = thumbnailsDirectory.appendingPathComponent("\(person.id.uuidString).jpg")
                do {
                    try access.writeCoordinatedData(data, url)
                    committedThumbnailURLs.append(url)
                } catch {
                    failedThumbnailCount += 1
                }
                guard !Task.isCancelled else { return cancelled() }
            }

            for embedding in person.embeddings {
                guard !Task.isCancelled else { return cancelled() }
                guard let data = request.embeddingThumbnails[embedding.id] else { continue }
                let url = embeddingThumbnailsDirectory.appendingPathComponent(
                    "\(embedding.id.uuidString).jpg"
                )
                do {
                    try access.writeCoordinatedData(data, url)
                    committedThumbnailURLs.append(url)
                } catch {
                    failedThumbnailCount += 1
                }
                guard !Task.isCancelled else { return cancelled() }
            }

            let personURL = peopleDirectory.appendingPathComponent("\(person.id.uuidString).json")
            do {
                try access.writeCoordinatedData(try encoder.encode(person), personURL)
            } catch {
                let snapshot = evidence()
                signposter.endInterval(
                    "Commit",
                    interval,
                    "result=failed requested=\(snapshot.requestedPersonCount) committed=\(snapshot.committedPeople.count) thumbnails=\(snapshot.committedThumbnailURLs.count) thumbnailFailures=\(snapshot.failedThumbnailCount)"
                )
                return .failed(snapshot, message: error.localizedDescription)
            }
            committedPeople.append(person)
            committedFileURLs.append(personURL)
            guard !Task.isCancelled else { return cancelled() }
        }

        let snapshot = evidence()
        signposter.endInterval(
            "Commit",
            interval,
            "result=complete requested=\(snapshot.requestedPersonCount) committed=\(snapshot.committedPeople.count) thumbnails=\(snapshot.committedThumbnailURLs.count) thumbnailFailures=\(snapshot.failedThumbnailCount)"
        )
        return .complete(snapshot)
    }

    private func beginExclusiveAccess() async {
        if !hasExclusiveAccess {
            hasExclusiveAccess = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
        }
    }

    private func endExclusiveAccess() {
        guard !accessWaiters.isEmpty else {
            hasExclusiveAccess = false
            return
        }
        accessWaiters.removeFirst().resume()
    }
}

/// File operations used by the one-shot embedding-space migration. Keeping the
/// whole transaction behind one seam lets tests prove that backup verification
/// and reset failures never advance the migration stamp.
struct KnownPeopleEmbeddingMigrationIO {
    var contentsOfDirectory: (URL) throws -> [URL]
    var mergeCopy: (URL, URL) throws -> Void
    var readData: (URL) throws -> Data
    var removeItem: (URL) throws -> Void
    var ensureDirectory: (URL) throws -> Void
    var backupURL: (URL, Int?, Int, Date) -> URL

    static let live = KnownPeopleEmbeddingMigrationIO(
        contentsOfDirectory: CloudCoordinatedIO.contentsOfDirectory,
        mergeCopy: CloudCoordinatedIO.mergeCopy,
        readData: CloudCoordinatedIO.readData,
        removeItem: CloudCoordinatedIO.removeItem,
        ensureDirectory: CloudCoordinatedIO.ensureDirectory,
        backupURL: { source, stored, _, date in
            let timestamp = ISO8601DateFormatter().string(from: date)
                .replacingOccurrences(of: ":", with: "-")
            return source.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(source.lastPathComponent).backup-embv\(stored.map(String.init) ?? "1")-\(timestamp)",
                    isDirectory: true
                )
        }
    )
}

private enum KnownPeopleEmbeddingMigrationError: LocalizedError {
    case backupDoesNotMatch(String)

    var errorDescription: String? {
        switch self {
        case .backupDoesNotMatch(let relativePath):
            return "The Known People backup could not be verified at \(relativePath)."
        }
    }
}

@MainActor
final class KnownPeopleService {

    // MARK: - Singleton

    static let shared = KnownPeopleService()

    // MARK: - Storage Paths

    /// Local fallback location: `<App Support>/Aagedal Photo Agent/KnownPeople`.
    nonisolated static var localKnownPeopleDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("KnownPeople", isDirectory: true)
    }

    /// Test-only seam: when set, overrides the resolved storage root so unit
    /// tests can point the singleton at a temp directory without touching the
    /// iCloud/local preference. Production code never sets this. After changing
    /// it, call `reloadAfterStorageChange()` to drop the cache.
    static var storageOverrideURL: URL?

    /// Process-wide fallback used by the test host whenever a focused test has
    /// not installed its own override. This prevents teardown/reload code and
    /// unrelated suites from ever resolving the user's live local or iCloud
    /// Known People store.
    private static let testProcessFallbackDirectory: URL? = {
        guard AppPaths.isTestProcess else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "KnownPeople-TestFallback-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    }()

    /// Test-only failure injection for the shared durable deletion transaction.
    /// Production always uses coordinated iCloud-safe file operations.
    static var deletionIO = DurableDeletionIO.live

    /// Test-only failure injection for the embedding-space migration.
    static var embeddingMigrationIO = KnownPeopleEmbeddingMigrationIO.live

    /// Embeddings must remain untouched until the corresponding model is present and
    /// verified. The on-demand installer re-triggers loading only after its atomic commit.
    static var embeddingMigrationModelReadiness: () -> Bool = {
        CoreMLFaceEmbedder.shared.availability.isAvailable
    }

    /// Injectable so focused migration tests do not mutate launch UI state.
    static var migrationRecoveryNotices = MigrationRecoveryNoticeCenter.shared

    /// How long a deletion tombstone is honored before it is garbage-collected.
    /// While present, a person's file is suppressed so a peer that still holds
    /// the person can't resurrect it; after the window a re-synced file could
    /// reappear (accepted as rare — a peer offline longer than this).
    private static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Resolved storage root, cached after first use. Resolving it does a
    /// ubiquity-container lookup plus coordinated `ensureDirectory` calls (root +
    /// people + both thumbnail subfolders), all of which are wasted if repeated
    /// on every access — and these accessors are hit per-cell in the face grids.
    /// Cleared by `reloadAfterStorageChange()` when the backing store toggles.
    private var cachedDirectory: URL?
    private var storageRevision: UInt64 = 0
    private let thumbnailLoader: KnownPeopleThumbnailLoadService
    private let archiveService: KnownPeopleArchiveService

    init(
        thumbnailLoader: KnownPeopleThumbnailLoadService = .shared,
        archiveService: KnownPeopleArchiveService = .shared
    ) {
        self.thumbnailLoader = thumbnailLoader
        self.archiveService = archiveService
    }

    private var knownPeopleDirectory: URL {
        if let cached = cachedDirectory { return cached }
        let url: URL
        if let override = Self.storageOverrideURL {
            url = override
        } else if let testFallback = Self.testProcessFallbackDirectory {
            url = testFallback
        } else if UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleICloudEnabled),
                  let cloud = AppPaths.iCloudKnownPeopleURL {
            url = cloud
        } else {
            url = Self.localKnownPeopleDirectory
        }
        // Ensure the root and all subfolders once, here, so the per-access
        // accessors below can stay coordination-free. (Writes additionally
        // ensure their own parent via CloudCoordinatedIO.writeData.)
        try? CloudCoordinatedIO.ensureDirectory(url)
        try? CloudCoordinatedIO.ensureDirectory(url.appendingPathComponent("people", isDirectory: true))
        try? CloudCoordinatedIO.ensureDirectory(url.appendingPathComponent("thumbnails", isDirectory: true))
        try? CloudCoordinatedIO.ensureDirectory(url.appendingPathComponent("embedding_thumbnails", isDirectory: true))
        cachedDirectory = url
        return url
    }

    /// Drops all in-memory state so the next access re-reads from disk. Called
    /// after the backing directory changes (iCloud sync toggled on/off).
    func reloadAfterStorageChange(resolvedStorageURL: URL? = nil) {
        storageRevision &+= 1
        cachedDirectory = resolvedStorageURL
        database = nil
        peopleIndex = [:]
        featurePrintCache.removeAllObjects()
        personThumbnailCache.removeAllObjects()
        embeddingThumbnailCache.removeAllObjects()
        _ = loadDatabase()
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    // MARK: - Per-person file layout

    /// Directory holding one `<uuid>.json` per person (and `<uuid>.deleted`
    /// tombstones). This is the source of truth; the "database" is its listing.
    private var peopleDirectory: URL {
        knownPeopleDirectory.appendingPathComponent("people", isDirectory: true)
    }

    private func personFileURL(for personID: UUID) -> URL {
        peopleDirectory.appendingPathComponent("\(personID.uuidString).json")
    }

    private func tombstoneURL(for personID: UUID) -> URL {
        peopleDirectory.appendingPathComponent("\(personID.uuidString).deleted")
    }

    /// Legacy single-file store, retired after the one-shot migration in
    /// `migrateLegacyDatabaseIfNeeded()`.
    private var legacyDatabaseFileURL: URL {
        knownPeopleDirectory.appendingPathComponent("database.json")
    }

    // MARK: - Self-write filtering

    /// Paths this device wrote recently, mapped to the write time. The remote
    /// watcher consults this so it doesn't react to our own saves. Entries are
    /// pruned by age (`selfWriteWindow`); the map only ever holds a handful.
    private var recentLocalWrites: [String: Date] = [:]
    private static let selfWriteWindow: TimeInterval = 10
    /// Tolerance between our recorded write time and the change date the
    /// metadata query reports for the same write.
    private static let selfWriteTolerance: TimeInterval = 3

    private func stampLocalWrite(_ url: URL) {
        let now = Date()
        recentLocalWrites[url.standardizedFileURL.path] = now
        // Opportunistic prune so the map can't grow unbounded.
        recentLocalWrites = recentLocalWrites.filter { now.timeIntervalSince($0.value) < Self.selfWriteWindow }
    }

    /// Whether a remote-change notification for `path` (with the file's reported
    /// `contentChangeDate`) is just an echo of a write this device made.
    func shouldSkipRemoteReload(path: String, contentChangeDate: Date?) -> Bool {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let stamped = recentLocalWrites[key] else { return false }
        let now = Date()
        if now.timeIntervalSince(stamped) >= Self.selfWriteWindow {
            recentLocalWrites[key] = nil
            return false
        }
        // If the watcher reports a change time at/just-after our write, treat it
        // as our echo. Without a change date, fall back to the recency window.
        guard let changeDate = contentChangeDate else { return true }
        return abs(changeDate.timeIntervalSince(stamped)) <= Self.selfWriteTolerance
    }

    private var thumbnailsDirectory: URL {
        knownPeopleDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    private func thumbnailURL(for personID: UUID) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(personID.uuidString).jpg")
    }

    // MARK: - Embedding Thumbnail Storage

    private var embeddingThumbnailsDirectory: URL {
        knownPeopleDirectory.appendingPathComponent("embedding_thumbnails", isDirectory: true)
    }

    private func embeddingThumbnailURL(for embeddingID: UUID) -> URL {
        embeddingThumbnailsDirectory.appendingPathComponent("\(embeddingID.uuidString).jpg")
    }

    // MARK: - In-Memory Cache

    private var database: KnownPeopleDatabase? {
        didSet { rebuildPeopleIndex() }
    }
    private var peopleIndex: [UUID: Int] = [:]
    /// Boxed decoded embedding for `NSCache` (which requires class values).
    private final class CachedEmbedding { let vector: [Float]; init(_ v: [Float]) { self.vector = v } }
    private let featurePrintCache: NSCache<NSUUID, CachedEmbedding> = {
        let cache = NSCache<NSUUID, CachedEmbedding>()
        cache.countLimit = 4000
        return cache
    }()

    private let embeddingThumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 5 * 1024 * 1024 // 5 MB
        return cache
    }()

    private let personThumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private func rebuildPeopleIndex() {
        guard let db = database else { peopleIndex = [:]; return }
        peopleIndex = Dictionary(uniqueKeysWithValues: db.people.enumerated().map { ($1.id, $0) })
    }

    // MARK: - Load

    /// Assembles the in-memory database from the per-person files in `people/`.
    /// The directory listing *is* the database — there is no single index file.
    /// Different people live in different files, so two devices editing unrelated
    /// people never clobber each other (the whole-file race this store had).
    func loadDatabase() -> KnownPeopleDatabase {
        if let cached = database {
            return cached
        }

        migrateLegacyDatabaseIfNeeded()
        migrateEmbeddingVersionIfNeeded()

        let entries = (try? CloudCoordinatedIO.contentsOfDirectory(at: peopleDirectory)) ?? []

        // Collect tombstones first so suppressed people are skipped on assembly.
        // GC expired markers in the same pass.
        let tombstoned = collectTombstones(in: entries)

        var people: [KnownPerson] = []
        for url in entries where url.pathExtension == "json" {
            guard let person = loadPersonFile(at: url) else { continue }

            if tombstoned.contains(person.id) {
                // A peer re-synced a person we deleted. Honor the delete and
                // clean up the stray file so it doesn't keep reappearing.
                try? CloudCoordinatedIO.removeItem(at: url)
                continue
            }
            people.append(person)
        }

        let loaded = KnownPeopleDatabase(
            people: people,
            lastModified: people.map(\.updatedAt).max() ?? Date()
        )
        database = loaded
        return loaded
    }

    /// Reads and decodes one person file, resolving any iCloud conflict versions
    /// first. Corrupt files are backed up and skipped (rather than aborting the
    /// whole load), mirroring `TemplateStorageService.loadAll`.
    private func loadPersonFile(at url: URL) -> KnownPerson? {
        if let resolved = resolveConflicts(at: url) {
            return resolved
        }
        do {
            let data = try CloudCoordinatedIO.readData(at: url)
            return try JSONDecoder().decode(KnownPerson.self, from: data)
        } catch {
            knownPeopleLog.error("Failed to load person file \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            backupCorruptFile(at: url)
            return nil
        }
    }

    private func backupCorruptFile(at url: URL) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt.\(timestamp)")
        if let corrupt = try? CloudCoordinatedIO.readData(at: url) {
            try? CloudCoordinatedIO.writeData(corrupt, to: backupURL)
            knownPeopleLog.warning("Backed up corrupted file to \(backupURL.lastPathComponent, privacy: .private(mask: .hash))")
        }
    }

    // MARK: - Write

    /// Encodes one person to its own file. The single entry point for persisting
    /// a person, so self-write stamping and change notification live here.
    private func writePerson(_ person: KnownPerson) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(person)
        let url = personFileURL(for: person.id)
        try CloudCoordinatedIO.writeData(data, to: url)
        stampLocalWrite(url)
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    /// Load → mutate one person → write that one file → update cache. Replaces
    /// the old whole-file `mutateDatabase`. The transform may no-op (e.g. the
    /// person vanished); in that case nothing is written.
    /// - Returns: whether a write happened.
    @discardableResult
    private func mutatePerson(id personID: UUID, _ transform: (inout KnownPerson) throws -> Bool) throws -> Bool {
        _ = loadDatabase()
        guard let index = peopleIndex[personID],
              var db = database,
              db.people.indices.contains(index) else {
            return false
        }
        var person = db.people[index]
        let changed = try transform(&person)
        guard changed else { return false }
        person.updatedAt = Date()
        try writePerson(person)
        db.people[index] = person
        db.lastModified = person.updatedAt
        database = db
        return true
    }

    // MARK: - Conflict resolution

    /// Deterministically merges several records of the *same* person (the local
    /// copy plus iCloud conflict versions): scalar fields come from the record
    /// with the highest `updatedAt`; `createdAt` keeps the earliest; embeddings
    /// are unioned by `id` and then deduped by `featurePrintData`.
    func mergePersonRecords(_ records: [KnownPerson]) -> KnownPerson {
        precondition(!records.isEmpty, "mergePersonRecords requires at least one record")
        let newest = records.max { $0.updatedAt < $1.updatedAt }!

        // Union embeddings by id (later-seen wins on id collision is irrelevant —
        // embeddings are immutable), preserving first-seen order, then dedup by
        // feature-print bytes.
        var byID: [UUID: PersonEmbedding] = [:]
        var orderedIDs: [UUID] = []
        for record in records {
            for embedding in record.embeddings where byID[embedding.id] == nil {
                byID[embedding.id] = embedding
                orderedIDs.append(embedding.id)
            }
        }
        let unioned = orderedIDs.compactMap { byID[$0] }
        let merged = dedupeEmbeddings(unioned)

        return KnownPerson(
            id: newest.id,
            name: newest.name,
            role: newest.role,
            notes: newest.notes,
            embeddings: merged,
            representativeThumbnailID: newest.representativeThumbnailID,
            createdAt: records.map(\.createdAt).min() ?? newest.createdAt,
            updatedAt: records.map(\.updatedAt).max() ?? newest.updatedAt
        )
    }

    /// Drops embeddings whose `featurePrintData` duplicates an earlier one,
    /// keeping first occurrence. Shared by merge and the dedup-add paths.
    private func dedupeEmbeddings(_ embeddings: [PersonEmbedding]) -> [PersonEmbedding] {
        var seenData = Set<Data>()
        var result: [PersonEmbedding] = []
        for embedding in embeddings where seenData.insert(embedding.featurePrintData).inserted {
            result.append(embedding)
        }
        return result
    }

    /// If the file has unresolved iCloud conflict versions, merge them all into
    /// one record, rewrite the file, and clear the conflict versions. Returns the
    /// merged person, or nil if there were no conflicts (caller decodes normally).
    /// No-op on local stores, which never have conflict versions.
    private func resolveConflicts(at url: URL) -> KnownPerson? {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return nil
        }

        let decoder = JSONDecoder()
        var records: [KnownPerson] = []
        if let currentData = try? CloudCoordinatedIO.readData(at: url),
           let current = try? decoder.decode(KnownPerson.self, from: currentData) {
            records.append(current)
        }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url),
               let person = try? decoder.decode(KnownPerson.self, from: data) {
                records.append(person)
            }
        }

        guard !records.isEmpty else {
            // Can't decode anything — give up but still clear versions so we
            // don't loop on this file forever.
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            return nil
        }

        let merged = mergePersonRecords(records)
        do {
            try writePerson(merged)
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
            knownPeopleLog.info("Resolved \(conflicts.count, privacy: .public) conflict version(s) for \(url.lastPathComponent, privacy: .private(mask: .hash))")
        } catch {
            knownPeopleLog.error("Failed to resolve conflicts for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
        return merged
    }

    // MARK: - Tombstones

    /// Returns the set of tombstoned person IDs, garbage-collecting any markers
    /// older than `tombstoneRetention` in the same pass.
    private func collectTombstones(in entries: [URL]) -> Set<UUID> {
        let decoder = JSONDecoder()
        let now = Date()
        var tombstoned = Set<UUID>()
        for url in entries where url.pathExtension == "deleted" {
            guard let data = try? CloudCoordinatedIO.readData(at: url),
                  let tombstone = try? decoder.decode(KnownPersonTombstone.self, from: data) else {
                // Unreadable marker — drop the id parsed from the filename if we
                // can, else just remove the junk file.
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                    tombstoned.insert(id)
                } else {
                    try? CloudCoordinatedIO.removeItem(at: url)
                }
                continue
            }
            if now.timeIntervalSince(tombstone.deletedAt) >= Self.tombstoneRetention {
                try? CloudCoordinatedIO.removeItem(at: url)
            } else {
                tombstoned.insert(tombstone.id)
            }
        }
        return tombstoned
    }

    private func deleteRecordDurably(for personID: UUID) throws {
        let tombstone = KnownPersonTombstone(id: personID)
        let url = tombstoneURL(for: personID)
        try DurableDeletionTransaction.execute(
            marker: tombstone,
            markerURL: url,
            recordURL: personFileURL(for: personID),
            markerMatches: { $0.id == personID },
            io: Self.deletionIO
        )
        stampLocalWrite(url)
    }

    // MARK: - Migration

    /// One-shot migration of the legacy single `database.json` into per-person
    /// files. Idempotent by construction: it returns immediately when no legacy
    /// file exists, writes each person only if its file isn't already present
    /// (so it never clobbers newer per-person data synced from a peer), then
    /// retires `database.json`. The file-existence guard is more robust than a
    /// UserDefaults version stamp here, because the legacy file can live in
    /// either the local or the iCloud root depending on the sync toggle.
    func migrateLegacyDatabaseIfNeeded() {
        let legacyURL = legacyDatabaseFileURL
        guard CloudCoordinatedIO.itemExists(at: legacyURL) else { return }

        do {
            let data = try CloudCoordinatedIO.readData(at: legacyURL)
            let legacy = try JSONDecoder().decode(KnownPeopleDatabase.self, from: data)
            for person in legacy.people where !CloudCoordinatedIO.itemExists(at: personFileURL(for: person.id)) {
                try writePerson(person)
            }
            try CloudCoordinatedIO.removeItem(at: legacyURL)
            knownPeopleLog.info("Migrated \(legacy.people.count, privacy: .public) people from legacy database.json to per-person files")
        } catch {
            knownPeopleLog.error("Legacy database migration failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Remote changes

    /// Applies remote changes to individual person files (from the iCloud
    /// metadata-query watcher) without dropping the whole in-memory database.
    /// Each entry is the changed file's URL and the change date the query
    /// reported (used to skip echoes of this device's own writes). For each file
    /// we resolve conflicts, re-read it, and update just that cache entry — or
    /// remove it for a tombstone / deleted file.
    func applyRemoteChanges(_ changes: [(url: URL, contentChangeDate: Date?)]) {
        // Nothing loaded yet → a full lazy load on next access is cheaper and
        // correct; no per-file patching needed.
        guard var db = database else { return }

        var didChange = false
        for change in changes {
            let url = change.url
            guard !shouldSkipRemoteReload(path: url.path, contentChangeDate: change.contentChangeDate) else { continue }
            guard let personID = personID(fromFileURL: url) else { continue }

            if url.pathExtension.lowercased() == "jpg" {
                switch url.deletingLastPathComponent().lastPathComponent {
                case "thumbnails":
                    personThumbnailCache.removeObject(forKey: personID as NSUUID)
                case "embedding_thumbnails":
                    embeddingThumbnailCache.removeObject(forKey: personID as NSUUID)
                default:
                    continue
                }
                // Reject a read that began against the previous thumbnail contents.
                storageRevision &+= 1
                didChange = true
                continue
            }

            if url.pathExtension == "deleted" {
                // A peer deleted this person — drop it and clean its file.
                if db.people.contains(where: { $0.id == personID }) {
                    db.people.removeAll { $0.id == personID }
                    didChange = true
                }
                try? CloudCoordinatedIO.removeItem(at: personFileURL(for: personID))
                featurePrintCache.removeAllObjects()
                continue
            }

            guard url.pathExtension == "json" else { continue }

            // Suppress a resurrected file if we hold a live tombstone for it.
            if CloudCoordinatedIO.itemExists(at: tombstoneURL(for: personID)) {
                try? CloudCoordinatedIO.removeItem(at: url)
                continue
            }

            if let person = loadPersonFile(at: url) {
                featurePrintCache.removeAllObjects()
                if let index = db.people.firstIndex(where: { $0.id == person.id }) {
                    db.people[index] = person
                } else {
                    db.people.append(person)
                }
                didChange = true
            } else if !CloudCoordinatedIO.itemExists(at: url) {
                // File vanished (deleted remotely without a tombstone reaching us yet).
                if db.people.contains(where: { $0.id == personID }) {
                    db.people.removeAll { $0.id == personID }
                    didChange = true
                }
            }
        }

        if didChange {
            db.lastModified = db.people.map(\.updatedAt).max() ?? Date()
            database = db
            NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
        }
    }

    private func personID(fromFileURL url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Thumbnails

    func cachedThumbnail(for personID: UUID) -> NSImage? {
        personThumbnailCache.object(forKey: personID as NSUUID)
    }

    func loadThumbnail(for personID: UUID) async -> NSImage? {
        if let cached = cachedThumbnail(for: personID) { return cached }
        guard let request = await thumbnailReadRequest(
            itemID: personID,
            directoryName: "thumbnails"
        ) else { return nil }
        guard case .loaded(let snapshot) = await thumbnailLoader.load(
            fileURL: request.fileURL,
            requestID: request.requestID
        ), request.storageRevision == storageRevision,
           snapshot.requestID == request.requestID,
           snapshot.fileURL == request.fileURL,
           let data = snapshot.data,
           let image = NSImage(data: data) else { return nil }
        personThumbnailCache.setObject(image, forKey: personID as NSUUID, cost: data.count)
        return image
    }

    func saveThumbnail(_ imageData: Data, for personID: UUID) throws {
        let url = thumbnailURL(for: personID)
        try CloudCoordinatedIO.writeData(imageData, to: url)
        if let image = NSImage(data: imageData) {
            personThumbnailCache.setObject(image, forKey: personID as NSUUID, cost: imageData.count)
        } else {
            personThumbnailCache.removeObject(forKey: personID as NSUUID)
        }
    }

    private func deleteThumbnail(for personID: UUID) {
        personThumbnailCache.removeObject(forKey: personID as NSUUID)
        let url = thumbnailURL(for: personID)
        do {
            try CloudCoordinatedIO.removeItem(at: url)
        } catch {
            knownPeopleLog.warning("Failed to delete thumbnail for \(personID, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Embedding Thumbnails

    func saveEmbeddingThumbnail(_ imageData: Data, for embeddingID: UUID) throws {
        let url = embeddingThumbnailURL(for: embeddingID)
        try CloudCoordinatedIO.writeData(imageData, to: url)
        if let image = NSImage(data: imageData) {
            embeddingThumbnailCache.setObject(image, forKey: embeddingID as NSUUID, cost: imageData.count)
        } else {
            embeddingThumbnailCache.removeObject(forKey: embeddingID as NSUUID)
        }
    }

    func saveEmbeddingThumbnails(_ thumbnails: [UUID: Data]) throws {
        for (embeddingID, data) in thumbnails {
            try saveEmbeddingThumbnail(data, for: embeddingID)
        }
    }

    func cachedEmbeddingThumbnail(for embeddingID: UUID) -> NSImage? {
        let key = embeddingID as NSUUID
        return embeddingThumbnailCache.object(forKey: key)
    }

    func loadEmbeddingThumbnail(for embeddingID: UUID) async -> NSImage? {
        let key = embeddingID as NSUUID
        if let cached = embeddingThumbnailCache.object(forKey: key) { return cached }
        guard let request = await thumbnailReadRequest(
            itemID: embeddingID,
            directoryName: "embedding_thumbnails"
        ) else { return nil }
        guard case .loaded(let snapshot) = await thumbnailLoader.load(
            fileURL: request.fileURL,
            requestID: request.requestID
        ), request.storageRevision == storageRevision,
           snapshot.requestID == request.requestID,
           snapshot.fileURL == request.fileURL,
           let data = snapshot.data,
           let image = NSImage(data: data) else { return nil }
        embeddingThumbnailCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    private struct ThumbnailReadRequest {
        let requestID: UUID
        let fileURL: URL
        let storageRevision: UInt64
    }

    private func thumbnailReadRequest(
        itemID: UUID,
        directoryName: String
    ) async -> ThumbnailReadRequest? {
        let revision = storageRevision
        let root: URL
        if let cachedDirectory {
            root = cachedDirectory
        } else if let override = Self.storageOverrideURL {
            root = override
        } else if let testFallback = Self.testProcessFallbackDirectory {
            root = testFallback
        } else {
            let syncEnabled = UserDefaults.standard.bool(
                forKey: UserDefaultsKeys.knownPeopleICloudEnabled
            )
            root = await KnownPeopleICloudRoutingService.shared.storageURL(
                syncEnabled: syncEnabled
            )
        }
        guard revision == storageRevision, !Task.isCancelled else { return nil }
        cachedDirectory = root
        let fileURL = root
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(itemID.uuidString).jpg")
        return ThumbnailReadRequest(
            requestID: UUID(),
            fileURL: fileURL,
            storageRevision: revision
        )
    }

    func deleteEmbeddingThumbnail(for embeddingID: UUID) {
        embeddingThumbnailCache.removeObject(forKey: embeddingID as NSUUID)
        let url = embeddingThumbnailURL(for: embeddingID)
        try? CloudCoordinatedIO.removeItem(at: url)
    }

    private func deleteAllEmbeddingThumbnails(for person: KnownPerson) {
        for embedding in person.embeddings {
            deleteEmbeddingThumbnail(for: embedding.id)
        }
    }

    // MARK: - CRUD Operations

    func addPerson(
        name: String,
        role: String? = nil,
        embeddings: [PersonEmbedding],
        thumbnailData: Data? = nil,
        embeddingThumbnails: [UUID: Data] = [:]
    ) throws -> KnownPerson {
        // Finish cold-cache assembly and any storage migrations before writing
        // new data. Loading after the write would discover this person on disk
        // and append it twice, or migrate away its newly written thumbnails.
        var db = loadDatabase()
        let person = KnownPerson(
            name: name,
            role: role,
            embeddings: embeddings,
            representativeThumbnailID: embeddings.first?.id
        )

        if let thumbData = thumbnailData {
            try saveThumbnail(thumbData, for: person.id)
        }

        if !embeddingThumbnails.isEmpty {
            try saveEmbeddingThumbnails(embeddingThumbnails)
        }

        try writePerson(person)
        db.people.append(person)
        db.lastModified = person.updatedAt
        database = db

        return person
    }

    func updatePerson(_ person: KnownPerson) throws {
        guard peopleIndex[person.id] != nil else {
            throw NSError(domain: "KnownPeopleService", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Person not found: \(person.name)"])
        }

        try mutatePerson(id: person.id) { existing in
            // Carry over the caller's edited fields, preserving identity/createdAt.
            existing.name = person.name
            existing.role = person.role
            existing.notes = person.notes
            existing.embeddings = person.embeddings
            existing.representativeThumbnailID = person.representativeThumbnailID
            return true
        }
    }

    func removePerson(id: UUID) throws {
        // Capture cache keys, but leave every derived file and in-memory entry
        // untouched until the marker + record transition has completed.
        let personToCleanUp = person(byID: id)

        // Tombstone first so the delete propagates and can't be resurrected by a
        // peer. The shared transaction verifies the installed marker and rolls it
        // back if record removal fails, preserving a usable original on failure.
        try deleteRecordDurably(for: id)
        if var db = database {
            db.people.removeAll { $0.id == id }
            database = db
        }

        // Derived caches are disposable, but only after the durable transition.
        if let personToCleanUp {
            deleteAllEmbeddingThumbnails(for: personToCleanUp)
            for embedding in personToCleanUp.embeddings {
                featurePrintCache.removeObject(forKey: embedding.id as NSUUID)
            }
        }
        deleteThumbnail(for: id)
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    func addEmbedding(_ embedding: PersonEmbedding, toPersonID personID: UUID, thumbnailData: Data? = nil) throws {
        guard peopleIndex[personID] != nil else {
            throw NSError(domain: "KnownPeopleService", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Person not found with ID: \(personID)"])
        }

        if let thumbData = thumbnailData {
            try saveEmbeddingThumbnail(thumbData, for: embedding.id)
        }

        try mutatePerson(id: personID) { person in
            person.embeddings.append(embedding)
            return true
        }
    }

    // MARK: - Duplicate Detection

    /// Result of checking for duplicate people before adding
    enum DuplicateCheckResult {
        /// No duplicate found - safe to create new person
        case noDuplicate
        /// Found person with matching name (case-insensitive)
        case nameMatch(person: KnownPerson)
        /// Found person with similar face embedding
        case faceMatch(person: KnownPerson, confidence: Float)
        /// Found both name and face match (same person)
        case bothMatch(person: KnownPerson, confidence: Float)
    }

    /// Check if a person with this name or similar face already exists.
    /// Set allowFaceMatch to false to only check name matches.
    /// Use this before adding to avoid duplicates.
    func checkForDuplicate(
        name: String,
        representativeFaceData: Data,
        threshold: Float = FaceRecognitionDefaults.knownPeopleMatchThreshold,
        allowFaceMatch: Bool = true
    ) -> DuplicateCheckResult {
        let db = loadDatabase()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        // Check for name match (case-insensitive)
        let nameMatch = db.people.first { person in
            person.name.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(trimmedName) == .orderedSame
        }

        // Check for face match if allowed
        let faceMatch: KnownPersonMatch?
        if allowFaceMatch {
            let faceMatches = matchFace(featurePrintData: representativeFaceData, threshold: threshold, maxResults: 1)
            faceMatch = faceMatches.first
        } else {
            faceMatch = nil
        }

        // Determine result
        if let nameMatch, let faceMatch, nameMatch.id == faceMatch.person.id {
            // Same person matched by both name and face
            return .bothMatch(person: nameMatch, confidence: faceMatch.confidence)
        } else if let nameMatch {
            return .nameMatch(person: nameMatch)
        } else if let faceMatch {
            return .faceMatch(person: faceMatch.person, confidence: faceMatch.confidence)
        }

        return .noDuplicate
    }

    /// Smart add that checks for duplicates and either creates new or adds to existing.
    /// Returns the person (new or existing) and whether embeddings were added to existing.
    @discardableResult
    func addOrMergePerson(
        name: String,
        role: String? = nil,
        embeddings: [PersonEmbedding],
        thumbnailData: Data?,
        embeddingThumbnails: [UUID: Data] = [:],
        duplicateCheck: DuplicateCheckResult
    ) throws -> (person: KnownPerson, addedToExisting: Bool) {
        switch duplicateCheck {
        case .noDuplicate:
            // Create new person
            let person = try addPerson(name: name, role: role, embeddings: embeddings, thumbnailData: thumbnailData, embeddingThumbnails: embeddingThumbnails)
            return (person, false)

        case .nameMatch(let existingPerson), .faceMatch(let existingPerson, _), .bothMatch(let existingPerson, _):
            // Add embeddings to existing person, avoiding duplicates
            try addEmbeddingsDeduped(embeddings, toPersonID: existingPerson.id, embeddingThumbnails: embeddingThumbnails)

            // Return updated person
            if let updatedPerson = person(byID: existingPerson.id) {
                return (updatedPerson, true)
            }
            return (existingPerson, true)
        }
    }

    /// Add embeddings to a person, skipping any that are duplicates (same featurePrintData).
    func addEmbeddingsDeduped(_ embeddings: [PersonEmbedding], toPersonID personID: UUID, embeddingThumbnails: [UUID: Data] = [:]) throws {
        guard peopleIndex[personID] != nil else {
            throw NSError(domain: "KnownPeopleService", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Person not found with ID: \(personID)"])
        }

        var addedEmbeddingIDs: Set<UUID> = []

        try mutatePerson(id: personID) { person in
            let existingData = Set(person.embeddings.map { $0.featurePrintData })
            let newEmbeddings = embeddings.filter { !existingData.contains($0.featurePrintData) }
            guard !newEmbeddings.isEmpty else { return false }

            addedEmbeddingIDs = Set(newEmbeddings.map(\.id))
            person.embeddings.append(contentsOf: newEmbeddings)
            return true
        }

        // Save thumbnails only for embeddings that were actually added
        if !embeddingThumbnails.isEmpty {
            let thumbnailsToSave = embeddingThumbnails.filter { addedEmbeddingIDs.contains($0.key) }
            if !thumbnailsToSave.isEmpty {
                try saveEmbeddingThumbnails(thumbnailsToSave)
            }
        }
    }

    /// Find a person by name (case-insensitive).
    func person(byName name: String) -> KnownPerson? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return loadDatabase().people.first { person in
            person.name.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// Merge people: combine embeddings from source into target, delete source.
    /// Deduplicates embeddings to avoid storing the same face data multiple times.
    ///
    /// Touches two person files (target update + source delete) with no portable
    /// cross-file atomic rename. The target is updated first so source data is
    /// never destroyed before its embeddings are durable. If marker creation or
    /// source removal then fails, the source stays usable while the target may
    /// already contain a deduplicated copy; retrying the merge is the documented
    /// recovery path and is idempotent by feature-print bytes.
    func mergePeople(sourceID: UUID, intoTargetID: UUID) throws {
        guard sourceID != intoTargetID else { return }

        guard peopleIndex[sourceID] != nil, peopleIndex[intoTargetID] != nil,
              let source = person(byID: sourceID) else {
            return
        }

        let sourceEmbeddings = source.embeddings
        var keptEmbeddingIDs: Set<UUID> = []

        // 1. Fold source embeddings into the target (one file write).
        try mutatePerson(id: intoTargetID) { target in
            let existingData = Set(target.embeddings.map { $0.featurePrintData })
            let newEmbeddings = sourceEmbeddings.filter { !existingData.contains($0.featurePrintData) }
            keptEmbeddingIDs = Set(newEmbeddings.map(\.id))
            guard !newEmbeddings.isEmpty else { return false }
            target.embeddings.append(contentsOf: newEmbeddings)
            return true
        }

        // 2. Tombstone and remove the source (so the delete propagates) and drop
        //    it from the cache.
        try deleteRecordDurably(for: sourceID)
        if var db = database {
            db.people.removeAll { $0.id == sourceID }
            database = db
        }
        deleteThumbnail(for: sourceID)

        for embedding in sourceEmbeddings where !keptEmbeddingIDs.contains(embedding.id) {
            featurePrintCache.removeObject(forKey: embedding.id as NSUUID)
            deleteEmbeddingThumbnail(for: embedding.id)
        }
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    /// Replace the thumbnail for a known person
    func replaceThumbnail(for personID: UUID, newThumbnailData: Data) throws {
        try saveThumbnail(newThumbnailData, for: personID)

        guard peopleIndex[personID] != nil else { return }
        // Bump updatedAt (writes the file) so the change syncs and wins on merge.
        try mutatePerson(id: personID) { _ in true }
    }

    /// Delete a single embedding from a person
    func removeEmbedding(_ embeddingID: UUID, fromPersonID personID: UUID) async throws {
        guard let currentPerson = person(byID: personID) else { return }
        let replacementThumbnail: (id: UUID, image: NSImage)?
        if currentPerson.representativeThumbnailID == embeddingID,
           let replacementID = currentPerson.embeddings.first(where: { $0.id != embeddingID })?.id {
            replacementThumbnail = await loadEmbeddingThumbnail(for: replacementID).map {
                (id: replacementID, image: $0)
            }
            try Task.checkCancellation()
        } else {
            replacementThumbnail = nil
        }
        guard peopleIndex[personID] != nil else { return }

        var wasRepresentative = false

        try mutatePerson(id: personID) { person in
            wasRepresentative = person.representativeThumbnailID == embeddingID
            person.embeddings.removeAll { $0.id == embeddingID }
            if wasRepresentative {
                person.representativeThumbnailID = person.embeddings.first?.id
            }
            return true
        }

        featurePrintCache.removeObject(forKey: embeddingID as NSUUID)
        deleteEmbeddingThumbnail(for: embeddingID)

        // If deleted embedding was the representative, update person thumbnail to new representative's
        if wasRepresentative, let replacementThumbnail,
           person(byID: personID)?.representativeThumbnailID == replacementThumbnail.id,
           let tiffData = replacementThumbnail.image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? saveThumbnail(jpegData, for: personID)
        }
    }

    /// Get a person by ID
    func person(byID personID: UUID) -> KnownPerson? {
        let db = loadDatabase()
        guard let index = peopleIndex[personID],
              db.people.indices.contains(index) else { return nil }
        return db.people[index]
    }

    /// First launch after the face-embedding model changed: embeddings stored by the previous
    /// model live in a different vector space and can't be compared to new ones. Per the rewrite
    /// decision the Known People database starts fresh — but the old store is backed up first, so
    /// nothing is silently destroyed. A no-op once the stored version matches the current one.
    private func migrateEmbeddingVersionIfNeeded() {
        let key = UserDefaultsKeys.knownPeopleEmbeddingVersion
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        let current = FaceRecognitionDefaults.embeddingVersion
        guard stored != current else {
            Self.migrationRecoveryNotices.clear(.knownPeople)
            return
        }
        guard Self.embeddingMigrationModelReadiness() else {
            knownPeopleLog.info("Known People embedding migration deferred until the current face model is verified")
            return
        }

        let hasExisting = ((try? CloudCoordinatedIO.contentsOfDirectory(at: peopleDirectory)) ?? [])
            .contains { $0.pathExtension == "json" }

        if hasExisting {
            let io = Self.embeddingMigrationIO
            let backup = io.backupURL(knownPeopleDirectory, stored, current, Date())
            do {
                try io.mergeCopy(knownPeopleDirectory, backup)
                try verifyEmbeddingMigrationBackup(
                    source: knownPeopleDirectory,
                    backup: backup,
                    io: io
                )
                knownPeopleLog.warning("Backed up pre-v\(current) Known People store to \(backup.lastPathComponent, privacy: .private(mask: .hash)) before reset")
                try resetDatabaseForEmbeddingMigration(io: io)
            } catch {
                knownPeopleLog.error("Known People embedding migration was not completed: \(error.localizedDescription, privacy: .private)")
                Self.migrationRecoveryNotices.recordFailure(in: .knownPeople)
                return
            }
        }

        UserDefaults.standard.set(current, forKey: key)
        Self.migrationRecoveryNotices.clear(.knownPeople)
    }

    private func verifyEmbeddingMigrationBackup(
        source: URL,
        backup: URL,
        io: KnownPeopleEmbeddingMigrationIO
    ) throws {
        let sourceFiles = try embeddingMigrationFileInventory(at: source, relativeTo: source, io: io)
        let backupFiles = try embeddingMigrationFileInventory(at: backup, relativeTo: backup, io: io)
        let sourcePaths = Set(sourceFiles.keys)
        let backupPaths = Set(backupFiles.keys)
        guard sourcePaths == backupPaths else {
            let mismatch = sourcePaths.symmetricDifference(backupPaths).sorted().first ?? "."
            throw KnownPeopleEmbeddingMigrationError.backupDoesNotMatch(mismatch)
        }
        for path in sourceFiles.keys.sorted() where sourceFiles[path] != backupFiles[path] {
            throw KnownPeopleEmbeddingMigrationError.backupDoesNotMatch(path)
        }
    }

    private func embeddingMigrationFileInventory(
        at directory: URL,
        relativeTo root: URL,
        io: KnownPeopleEmbeddingMigrationIO
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in try io.contentsOfDirectory(directory) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                result.merge(
                    try embeddingMigrationFileInventory(at: entry, relativeTo: root, io: io),
                    uniquingKeysWith: { _, rhs in rhs }
                )
            } else {
                let rootPath = root.standardizedFileURL.path
                let entryPath = entry.standardizedFileURL.path
                let relativePath = entryPath.hasPrefix(rootPath + "/")
                    ? String(entryPath.dropFirst(rootPath.count + 1))
                    : entry.lastPathComponent
                result[relativePath] = try io.readData(entry)
            }
        }
        return result
    }

    private func resetDatabaseForEmbeddingMigration(io: KnownPeopleEmbeddingMigrationIO) throws {
        try io.removeItem(knownPeopleDirectory)
        try io.ensureDirectory(peopleDirectory)
        try io.ensureDirectory(thumbnailsDirectory)
        try io.ensureDirectory(embeddingThumbnailsDirectory)

        featurePrintCache.removeAllObjects()
        personThumbnailCache.removeAllObjects()
        embeddingThumbnailCache.removeAllObjects()
        recentLocalWrites.removeAll()
        database = KnownPeopleDatabase()
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    func clearDatabase() throws {
        let emptyDB = KnownPeopleDatabase()
        featurePrintCache.removeAllObjects()
        personThumbnailCache.removeAllObjects()
        embeddingThumbnailCache.removeAllObjects()
        recentLocalWrites.removeAll()

        // Remove all files (people/, thumbnails, embedding thumbnails, any
        // tombstones). This is a local nuke — tombstones go with it.
        try CloudCoordinatedIO.removeItem(at: knownPeopleDirectory)

        // Recreate empty directory structure
        try CloudCoordinatedIO.ensureDirectory(peopleDirectory)
        try CloudCoordinatedIO.ensureDirectory(thumbnailsDirectory)
        try CloudCoordinatedIO.ensureDirectory(embeddingThumbnailsDirectory)
        database = emptyDB
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    // MARK: - Matching

    struct MatchPolicy: Sendable {
        let threshold: Float
        let minConfidence: Float
        let minConfidenceGap: Float
    }

    func currentAutoMatchPolicy() -> MatchPolicy {
        let minConfidence = Float(UserDefaults.standard.object(forKey: UserDefaultsKeys.knownPeopleMinConfidence) as? Double
            ?? Double(FaceRecognitionDefaults.knownPeopleMinConfidence))
        return MatchPolicy(
            threshold: FaceRecognitionDefaults.knownPeopleMatchThreshold,
            minConfidence: minConfidence,
            minConfidenceGap: FaceRecognitionDefaults.knownPeopleMinConfidenceGap
        )
    }

    private func clearFeaturePrintCache() {
        featurePrintCache.removeAllObjects()
    }

    private func getFeaturePrint(for embedding: PersonEmbedding) -> [Float]? {
        let key = embedding.id as NSUUID
        if let cached = featurePrintCache.object(forKey: key) {
            return cached.vector
        }
        guard let vector = EmbeddingCodec.decode(embedding.featurePrintData) else {
            return nil
        }
        featurePrintCache.setObject(CachedEmbedding(vector), forKey: key, cost: embedding.featurePrintData.count)
        return vector
    }

    /// Core matching loop: compare a query embedding against a pre-loaded database snapshot
    /// using cosine distance. Extracted so callers can load the database once and reuse it.
    private func matchFaceAgainstDatabase(
        queryFP: [Float],
        database: KnownPeopleDatabase,
        threshold: Float,
        maxResults: Int
    ) -> [KnownPersonMatch] {
        var matches: [KnownPersonMatch] = []
        var bestOverallDistance: Float = .infinity

        for person in database.people {
            var bestDistance: Float = .infinity
            var bestEmbeddingID: UUID?

            for embedding in person.embeddings {
                guard let personFP = getFeaturePrint(for: embedding),
                      let distance = EmbeddingCodec.cosineDistance(queryFP, personFP) else { continue }
                if distance < bestDistance {
                    bestDistance = distance
                    bestEmbeddingID = embedding.id
                    if bestDistance < 0.05 { break }
                }
            }

            if let embeddingID = bestEmbeddingID, bestDistance < threshold {
                let confidence = max(0, 1.0 - bestDistance)
                matches.append(KnownPersonMatch(
                    person: person,
                    confidence: confidence,
                    matchedEmbeddingID: embeddingID
                ))

                if bestDistance < bestOverallDistance {
                    bestOverallDistance = bestDistance
                }

                // Early termination: near-perfect match found and we have enough results
                if bestOverallDistance < 0.05 && matches.count >= maxResults {
                    break
                }
            }
        }

        return matches
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Match a face embedding against all known people.
    /// Returns matches sorted by confidence (highest first).
    ///
    /// **Important:** This always performs face-only matching using Vision feature prints.
    /// Clothing features are intentionally NOT used here to ensure consistent matching
    /// across different contexts (same person in different clothing).
    func matchFace(
        featurePrintData: Data,
        threshold: Float = FaceRecognitionDefaults.knownPeopleMatchThreshold,
        maxResults: Int = 5
    ) -> [KnownPersonMatch] {
        guard let queryFP = EmbeddingCodec.decode(featurePrintData) else {
            return []
        }

        return matchFaceAgainstDatabase(
            queryFP: queryFP,
            database: loadDatabase(),
            threshold: threshold,
            maxResults: maxResults
        )
    }

    /// Returns the best match only if it clears a stricter auto-match policy.
    /// This is intended for auto-naming flows and is more conservative than raw `matchFace`.
    func bestAutoMatch(
        featurePrintData: Data,
        policy: MatchPolicy? = nil
    ) -> KnownPersonMatch? {
        let policy = policy ?? currentAutoMatchPolicy()
        let matches = matchFace(
            featurePrintData: featurePrintData,
            threshold: policy.threshold,
            maxResults: 2
        )

        guard let best = matches.first, best.confidence >= policy.minConfidence else {
            return nil
        }

        if let second = matches.dropFirst().first,
           best.confidence - second.confidence < policy.minConfidenceGap {
            return nil
        }

        return best
    }

    /// Batch version of `bestAutoMatch` — loads the database once and applies
    /// the same confidence + gap filtering per face.
    /// Returns a map of face ID → best match for faces that pass the policy.
    func bestAutoMatches(
        _ faces: [(id: UUID, featurePrintData: Data)],
        policy: MatchPolicy? = nil
    ) -> [UUID: KnownPersonMatch] {
        let db = loadDatabase()
        guard !db.people.isEmpty else { return [:] }

        let policy = policy ?? currentAutoMatchPolicy()
        var results: [UUID: KnownPersonMatch] = [:]

        for face in faces {
            guard let queryFP = EmbeddingCodec.decode(face.featurePrintData) else { continue }

            let matches = matchFaceAgainstDatabase(
                queryFP: queryFP,
                database: db,
                threshold: policy.threshold,
                maxResults: 2
            )

            guard let best = matches.first, best.confidence >= policy.minConfidence else {
                continue
            }

            if let second = matches.dropFirst().first,
               best.confidence - second.confidence < policy.minConfidenceGap {
                continue
            }

            results[face.id] = best
        }

        return results
    }

    /// Match multiple faces at once for efficiency.
    /// Loads the database once and reuses it for all faces, avoiding N redundant loads.
    /// Returns a dictionary mapping face IDs to their best match (if any).
    func matchFaces(
        _ faces: [(id: UUID, featurePrintData: Data)],
        threshold: Float = FaceRecognitionDefaults.knownPeopleMatchThreshold
    ) -> [UUID: KnownPersonMatch] {
        let db = loadDatabase()
        var results: [UUID: KnownPersonMatch] = [:]

        for face in faces {
            guard let queryFP = EmbeddingCodec.decode(face.featurePrintData) else { continue }

            if let bestMatch = matchFaceAgainstDatabase(
                queryFP: queryFP,
                database: db,
                threshold: threshold,
                maxResults: 1
            ).first {
                results[face.id] = bestMatch
            }
        }

        return results
    }

    /// Match multiple faces per group against the Known People database for suggestion generation.
    /// Loads the database once, checks up to N faces per group, and aggregates results.
    /// Returns ALL matches within threshold (not just strict auto-matches), enabling the caller
    /// to separate auto-matches from suggestions.
    ///
    /// For each group, the result contains matches sorted by confidence, with vote counts
    /// indicating how many sampled faces agreed on each person.
    func matchGroupsForSuggestions(
        groups: [(groupID: UUID, faceEmbeddings: [(faceID: UUID, featurePrintData: Data)])],
        threshold: Float = FaceRecognitionDefaults.knownPeopleMatchThreshold,
        maxResultsPerFace: Int = 3
    ) -> [UUID: [(match: KnownPersonMatch, matchedFaceCount: Int)]] {
        let db = loadDatabase()
        guard !db.people.isEmpty else { return [:] }

        var results: [UUID: [(match: KnownPersonMatch, matchedFaceCount: Int)]] = [:]

        for group in groups {
            // Track per-person: best match and how many sampled faces matched
            var personAggregation: [UUID: (bestMatch: KnownPersonMatch, matchCount: Int)] = [:]

            for faceEmbedding in group.faceEmbeddings {
                guard let queryFP = EmbeddingCodec.decode(faceEmbedding.featurePrintData) else { continue }

                let faceMatches = matchFaceAgainstDatabase(
                    queryFP: queryFP,
                    database: db,
                    threshold: threshold,
                    maxResults: maxResultsPerFace
                )

                for match in faceMatches {
                    if let existing = personAggregation[match.person.id] {
                        let bestMatch = match.confidence > existing.bestMatch.confidence ? match : existing.bestMatch
                        personAggregation[match.person.id] = (bestMatch: bestMatch, matchCount: existing.matchCount + 1)
                    } else {
                        personAggregation[match.person.id] = (bestMatch: match, matchCount: 1)
                    }
                }
            }

            if !personAggregation.isEmpty {
                let sorted = personAggregation.values
                    .sorted { $0.bestMatch.confidence > $1.bestMatch.confidence }
                    .map { (match: $0.bestMatch, matchedFaceCount: $0.matchCount) }
                results[group.groupID] = sorted
            }
        }

        return results
    }

    // MARK: - Export

    func exportToZip(destinationURL: URL, exportedBy: String? = nil) async throws {
        let db = loadDatabase()
        try await archiveService.export(
            people: db.people,
            thumbnailsDirectory: thumbnailsDirectory,
            embeddingThumbnailsDirectory: embeddingThumbnailsDirectory,
            destinationURL: destinationURL,
            exportedBy: exportedBy
        )
    }

    // MARK: - Import

    func importFromZip(sourceURL: URL) async throws -> Int {
        let expectedStorageRevision = storageRevision
        let payload = try await archiveService.prepareImport(sourceURL: sourceURL)
        try Task.checkCancellation()
        guard storageRevision == expectedStorageRevision else {
            throw CancellationError()
        }

        // Filter out people whose UUIDs already exist to prevent duplicates on re-import
        let db = loadDatabase()
        var admittedIDs = Set(db.people.map(\.id))
        let newPeople = payload.people.filter { admittedIDs.insert($0.id).inserted }
        let requestID = UUID()
        let storageRoot = knownPeopleDirectory
        let result = await archiveService.commitImport(KnownPeopleArchiveImportCommitRequest(
            requestID: requestID,
            storageRoot: storageRoot,
            people: newPeople,
            personThumbnails: payload.personThumbnails,
            embeddingThumbnails: payload.embeddingThumbnails
        ))

        let evidence: KnownPeopleArchiveImportCommitEvidence
        let completionError: (any Error)?
        switch result {
        case .complete(let committed):
            evidence = committed
            completionError = nil
        case .cancelled(let committed):
            evidence = committed
            completionError = CancellationError()
        case .failed(let committed, let message):
            evidence = committed
            completionError = NSError(
                domain: "KnownPeopleService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard evidence.requestID == requestID,
              evidence.storageRoot.standardizedFileURL == storageRoot.standardizedFileURL,
              evidence.requestedPersonCount == newPeople.count else {
            throw CancellationError()
        }
        guard storageRevision == expectedStorageRevision else {
            throw CancellationError()
        }

        // Publish the durable import prefix into the latest cache. Local CRUD can run while
        // commitImport is suspended; its additions, edits and removals must not be replaced by
        // the pre-import snapshot. Existing IDs remain authoritative in the current cache.
        for url in evidence.committedFileURLs + evidence.committedThumbnailURLs {
            stampLocalWrite(url)
        }
        if !evidence.committedPeople.isEmpty {
            var current = loadDatabase()
            let currentIDs = Set(current.people.map(\.id))
            current.people.append(contentsOf: evidence.committedPeople.filter { !currentIDs.contains($0.id) })
            current.lastModified = max(
                current.lastModified,
                evidence.committedPeople.map(\.updatedAt).max() ?? current.lastModified
            )
            database = current
            clearFeaturePrintCache()
            NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
        }

        if let completionError { throw completionError }
        return evidence.committedPeople.count
    }

    // MARK: - Statistics

    func getStatistics() -> (peopleCount: Int, embeddingCount: Int) {
        let db = loadDatabase()
        let embeddingCount = db.people.reduce(0) { $0 + $1.embeddings.count }
        return (db.people.count, embeddingCount)
    }

    func getAllPeople() -> [KnownPerson] {
        return loadDatabase().people
    }
}
