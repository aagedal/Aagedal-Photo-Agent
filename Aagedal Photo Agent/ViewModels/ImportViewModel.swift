import AppKit
import Foundation
import SwiftMediaMetadata
import os

enum ImportPhase: Equatable {
    case idle
    case scanning
    case copying
    case applyingMetadata
    case complete
    case cancelled
    case failed(String)
}

/// Surfaced to the UI to render mismatch and backup-failure rows in the summary.
struct ImportFailureRecord: Identifiable, Sendable, Hashable {
    let id = UUID()
    let source: URL
    let kind: Kind
    let detail: String

    enum Kind: String, Sendable {
        case copyFailed
        case verificationMismatch
        case backupFailed
        /// The file was copied, but its template metadata or voice-memo link could not be saved.
        case metadataFailed
    }
}

struct ImportOverwriteExpectation: Sendable, Hashable {
    let primaryPath: String
    let primaryExists: Bool
    let backupPath: String?
    let backupExists: Bool?
    let isSkipped: Bool
}

struct ImportOverwritePreflight: Identifiable, Sendable, Equatable {
    let id = UUID()
    let primaryCollisionCount: Int
    let backupCollisionCount: Int
    let primaryRoot: URL
    let backupRoot: URL?
    let signature: [ImportOverwriteExpectation]

    var totalCollisionCount: Int { primaryCollisionCount + backupCollisionCount }
}

nonisolated struct ImportDestinationBookmarkResolution: Sendable, Equatable {
    let url: URL
    let isStale: Bool
}

nonisolated struct ImportDestinationBookmarkAccess: Sendable {
    let resolve: @Sendable (Data) throws -> ImportDestinationBookmarkResolution
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void
    let create: @Sendable (URL) throws -> Data

    init(
        resolve: @escaping @Sendable (Data) throws -> ImportDestinationBookmarkResolution = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ImportDestinationBookmarkResolution(url: url, isStale: isStale)
        },
        startAccessing: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        },
        create: @escaping @Sendable (URL) throws -> Data = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    ) {
        self.resolve = resolve
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.create = create
    }
}

nonisolated struct ImportDestinationBookmarkSnapshot: Sendable, Equatable {
    let requestID: UUID
    let url: URL
    let refreshedBookmarkData: Data?
}

nonisolated enum ImportDestinationBookmarkLoadResult: Sendable, Equatable {
    case loaded(ImportDestinationBookmarkSnapshot)
    case failed(requestID: UUID)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterAccess(requestID: UUID)
}

nonisolated struct ImportDestinationBookmarkCommit: Sendable, Equatable {
    let requestID: UUID
    let bookmarkData: Data?
    let cancellationRequestedAfterAccess: Bool
}

nonisolated enum ImportDestinationBookmarkCommitResult: Sendable, Equatable {
    case completed(ImportDestinationBookmarkCommit)
    case cancelledBeforeAccess(requestID: UUID)
}

/// Serializes Import destination bookmark APIs away from MainActor. Security-scoped bookmark
/// calls are synchronous and may consult a slow file provider, so callers publish only a complete
/// result carrying the identity of their still-current request.
actor ImportDestinationBookmarkService {
    static let shared = ImportDestinationBookmarkService()

    private let access: ImportDestinationBookmarkAccess
    private let cancellationRequested: @Sendable () -> Bool

    init(
        access: ImportDestinationBookmarkAccess = ImportDestinationBookmarkAccess(),
        cancellationRequested: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.access = access
        self.cancellationRequested = cancellationRequested
    }

    func resolve(_ bookmarkData: Data, requestID: UUID) -> ImportDestinationBookmarkLoadResult {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: requestID)
        }
        guard let resolution = try? access.resolve(bookmarkData) else {
            return .failed(requestID: requestID)
        }
        guard !cancellationRequested() else {
            return .cancelledAfterAccess(requestID: requestID)
        }

        var refreshedBookmarkData: Data?
        if resolution.isStale {
            refreshedBookmarkData = createBookmark(for: resolution.url)
            guard !cancellationRequested() else {
                return .cancelledAfterAccess(requestID: requestID)
            }
        }
        return .loaded(ImportDestinationBookmarkSnapshot(
            requestID: requestID,
            url: resolution.url,
            refreshedBookmarkData: refreshedBookmarkData
        ))
    }

    func createBookmark(
        for url: URL,
        requestID: UUID
    ) -> ImportDestinationBookmarkCommitResult {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: requestID)
        }
        let bookmarkData = createBookmark(for: url)
        return .completed(ImportDestinationBookmarkCommit(
            requestID: requestID,
            bookmarkData: bookmarkData,
            cancellationRequestedAfterAccess: cancellationRequested()
        ))
    }

    private func createBookmark(for url: URL) -> Data? {
        let didStartAccessing = access.startAccessing(url)
        defer {
            if didStartAccessing {
                access.stopAccessing(url)
            }
        }
        return try? access.create(url)
    }
}

nonisolated struct ImportExecutionSecurityScopeAccess: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    init(
        start: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stop: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.start = start
        self.stop = stop
    }
}

nonisolated struct ImportExecutionSecurityScopeRequest: Equatable, Sendable {
    let requestID: UUID
    let roots: [URL]

    init(requestID: UUID = UUID(), roots: [URL?]) {
        self.requestID = requestID
        var seenPaths: Set<String> = []
        self.roots = roots.compactMap { root in
            guard let root else { return nil }
            let standardized = root.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}

nonisolated struct ImportExecutionSecurityScopeClaim: Equatable, Sendable {
    let requestID: UUID
    let roots: [URL]
    let startedRoots: [URL]
}

nonisolated enum ImportExecutionSecurityScopeAcquisition: Equatable, Sendable {
    case acquired(ImportExecutionSecurityScopeClaim)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterAccess(
        requestID: UUID,
        inspectedRootCount: Int,
        releasedStartedRoots: [URL]
    )
}

nonisolated struct ImportExecutionSecurityScopeRelease: Equatable, Sendable {
    let requestID: UUID
    let releasedRoots: [URL]
}

/// Owns the synchronous file-provider access calls for an import lease. The operation may
/// suspend while the process-wide claims remain active; acquisition and release themselves stay
/// serialized on this actor, and every exit releases only the roots that actually started.
actor ImportExecutionSecurityScopeService {
    static let shared = ImportExecutionSecurityScopeService()

    private let access: ImportExecutionSecurityScopeAccess
    private let cancellationRequested: @Sendable () -> Bool
    private var activeStartedRoots: [UUID: [URL]] = [:]

    init(
        access: ImportExecutionSecurityScopeAccess = ImportExecutionSecurityScopeAccess(),
        cancellationRequested: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.access = access
        self.cancellationRequested = cancellationRequested
    }

    func acquire(
        _ request: ImportExecutionSecurityScopeRequest
    ) -> ImportExecutionSecurityScopeAcquisition {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: request.requestID)
        }

        var startedRoots: [URL] = []
        for (index, root) in request.roots.enumerated() {
            if access.start(root) {
                startedRoots.append(root)
            }
            guard !cancellationRequested() else {
                let releasedRoots = releaseStartedRoots(startedRoots)
                return .cancelledAfterAccess(
                    requestID: request.requestID,
                    inspectedRootCount: index + 1,
                    releasedStartedRoots: releasedRoots
                )
            }
        }

        activeStartedRoots[request.requestID] = startedRoots
        return .acquired(ImportExecutionSecurityScopeClaim(
            requestID: request.requestID,
            roots: request.roots,
            startedRoots: startedRoots
        ))
    }

    func release(
        _ claim: ImportExecutionSecurityScopeClaim
    ) -> ImportExecutionSecurityScopeRelease {
        let startedRoots = activeStartedRoots.removeValue(forKey: claim.requestID) ?? []
        return ImportExecutionSecurityScopeRelease(
            requestID: claim.requestID,
            releasedRoots: releaseStartedRoots(startedRoots)
        )
    }

    func withAccess<T: Sendable>(
        _ request: ImportExecutionSecurityScopeRequest,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let acquisition = acquire(request)
        guard case .acquired(let claim) = acquisition else {
            throw CancellationError()
        }

        do {
            let result = try await operation()
            _ = release(claim)
            return result
        } catch {
            _ = release(claim)
            throw error
        }
    }

    private func releaseStartedRoots(_ roots: [URL]) -> [URL] {
        let releasedRoots = Array(roots.reversed())
        for root in releasedRoots {
            access.stop(root)
        }
        return releasedRoots
    }
}

/// Per-date group for sorting source files into separate destination folders.
struct ImportDateGroup: Identifiable {
    let id = UUID()
    let dateString: String
    var folderName: String
    var shootFolderName: String?
    var isIncluded: Bool = true
    /// 4-digit year derived from the parsed capture date. `nil` when the date could
    /// not be parsed; such groups stay flat under the destination base even when
    /// "Group by year" is enabled, to avoid creating a bogus year folder.
    var yearFolder: String?
    /// Month folder derived from the parsed capture date. Used below `yearFolder`
    /// when month grouping is enabled.
    var monthFolder: String? = nil
    var files: [URL]
    /// Full per-file capture timestamps (EXIF `DateTimeOriginal`, or file mtime as a
    /// fallback). A file may be absent here when no timestamp could be read. Used for
    /// chronological ordering, evenly-spread thumbnail sampling, and gap detection —
    /// never persisted, so it is safe to anchor parsing to UTC.
    var captureTimes: [URL: Date] = [:]

    /// Files ordered by capture time. Files without a timestamp fall back to a stable
    /// filename ordering and sort after timestamped files of equal standing.
    var chronologicalFiles: [URL] {
        ImportViewModel.chronologicalOrder(of: files, captureTimes: captureTimes)
    }
}

/// The write destinations the current metadata-write preset chooses for imported files,
/// captured once per import on the main actor (the preset lives in app defaults).
nonisolated struct ImportMetadataWriteModes: Sendable, Equatable {
    let raw: MetadataWriteMode
    let c2pa: MetadataWriteMode
    let other: MetadataWriteMode

    @MainActor static var current: ImportMetadataWriteModes {
        ImportMetadataWriteModes(
            raw: .current(forC2PA: false, isRaw: true),
            c2pa: .current(forC2PA: true, isRaw: false),
            other: .current(forC2PA: false, isRaw: false)
        )
    }

    /// RAW never needs a C2PA probe (it always gets a sidecar), and neither does any file when
    /// the preset treats credentialed and plain files alike.
    func mode(for url: URL, hasC2PA: @Sendable (URL) async -> Bool) async -> MetadataWriteMode {
        if SupportedImageFormats.isRaw(url: url) { return raw }
        guard c2pa != other else { return other }
        return await hasC2PA(url) ? c2pa : other
    }
}

/// Plans destination names for one import batch so no two sources ever share a destination
/// file, whatever the conflict policy (which only governs files already on disk). Names are
/// compared case-insensitively, like the default APFS/HFS+ volumes. Destination stems are owned by
/// one exposure (same source folder and stem, e.g. RAW + JPEG): every file of an exposure shares one
/// suffix, and two exposures never share a stem — otherwise one camera's RAW could land beside
/// another camera's JPEG and be shown as a pair. A voice memo always takes its image's suffix.
nonisolated struct ImportBatchNamePlanner: Sendable {
    struct PlannedName: Sendable, Equatable {
        let image: URL
        let memo: URL?
        let wasRenamed: Bool
    }

    private var claimedImages: Set<String> = []
    /// Destination folder + stem (with suffix) → the exposure that owns it.
    private var stemOwners: [String: String] = [:]
    private var memoOwners: [String: URL] = [:]
    private var suffixByExposure: [String: Int] = [:]

    mutating func plan(
        source: URL,
        folder: URL,
        exposureFolder: URL,
        memoSource: URL?,
        memoExtension: String?
    ) -> PlannedName {
        let stem = source.deletingPathExtension().lastPathComponent
        let exposureKey = [
            Self.key(exposureFolder),
            Self.key(source.deletingLastPathComponent()),
            stem.lowercased(),
        ].joined(separator: "|")
        let memoOwner = memoSource?.standardizedFileURL

        func candidate(_ suffix: Int) -> PlannedName? {
            let name = suffix == 0 ? stem : "\(stem)-\(suffix)"
            let image = folder.appendingPathComponent(
                source.pathExtension.isEmpty ? name : "\(name).\(source.pathExtension)"
            )
            guard !claimedImages.contains(Self.key(image)) else { return nil }
            if let owner = stemOwners[Self.stemKey(folder: folder, name: name)], owner != exposureKey {
                return nil
            }
            var memo: URL?
            if memoOwner != nil {
                let memoURL = folder.appendingPathComponent(name)
                    .appendingPathExtension(memoExtension ?? "wav")
                if let owner = memoOwners[Self.key(memoURL)], owner != memoOwner { return nil }
                memo = memoURL
            }
            return PlannedName(image: image, memo: memo, wasRenamed: suffix > 0)
        }

        let result: PlannedName
        if let preferred = suffixByExposure[exposureKey].flatMap(candidate) {
            result = preferred
        } else {
            var suffix = 0
            var found = candidate(suffix)
            while found == nil {
                suffix += 1
                found = candidate(suffix)
            }
            // `candidate` only fails on names claimed earlier in this batch, which is finite.
            result = found ?? PlannedName(image: folder.appendingPathComponent(source.lastPathComponent), memo: nil, wasRenamed: false)
            if suffixByExposure[exposureKey] == nil {
                suffixByExposure[exposureKey] = suffix
            }
        }
        claimedImages.insert(Self.key(result.image))
        stemOwners[Self.stemKey(
            folder: folder,
            name: result.image.deletingPathExtension().lastPathComponent
        )] = exposureKey
        if let memo = result.memo, let memoOwner {
            memoOwners[Self.key(memo)] = memoOwner
        }
        return result
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private static func stemKey(folder: URL, name: String) -> String {
        key(folder) + "|" + name.lowercased()
    }
}

@Observable
final class ImportViewModel {
    var configuration = ImportConfiguration() {
        didSet {
            if oldValue.fileTypeFilter != configuration.fileTypeFilter {
                refreshFilteredSourceFiles()
            }
        }
    }
    var sourceFiles: [URL] = [] {
        didSet { refreshDerivedSourceLists() }
    }
    var sourceVoiceMemoFiles: [URL] = []
    var voiceMemoSourceFiles: [URL] = [] {
        didSet { refreshDerivedSourceLists() }
    }
    var voiceMemoAssociationReport: VoiceMemoAssociationReport?
    @ObservationIgnored private var canonicalVoiceMemoImageURLBySource: [URL: URL] = [:] {
        didSet { refreshDerivedSourceLists() }
    }
    /// Supported images across both sources, de-duplicated by exposure. Stored (not computed)
    /// because the import sheet reads these lists many times per render; they are rebuilt only
    /// when their inputs change.
    private(set) var allSourceImages: [URL] = []
    /// `allSourceImages` narrowed by the RAW/JPEG file-type filter.
    private(set) var filteredSourceFiles: [URL] = []
    /// `filteredSourceFiles` narrowed to the included capture-date groups when sorting by date.
    private(set) var selectedSourceFiles: [URL] = []
    /// Files found on the selected sources that this importer will not copy (videos, sidecars,
    /// other documents). Surfaced so nothing on the card is dropped silently.
    private(set) var ignoredSourceFiles: [URL] = []
    @ObservationIgnored private var ignoredPrimarySourceFiles: [URL] = []
    @ObservationIgnored private var ignoredSecondSourceFiles: [URL] = []
    var sourceScanProgress = ImportSourceDiscoveryProgress()
    var voiceMemoSourceScanProgress = ImportSourceDiscoveryProgress()
    var isDiscoveringVoiceMemoSource: Bool = false
    var isScanningVoiceMemoSource: Bool = false
    var importPhase: ImportPhase = .idle
    var copiedFiles: Int = 0
    var voiceMemoCopiedFiles: Int = 0
    var totalFiles: Int = 0
    var skippedFiles: Int = 0
    var duplicateSkippedFiles: Int = 0
    var renamedFiles: Int = 0
    var replacedFiles: Int = 0
    var backupReplacedFiles: Int = 0
    var failedFiles: Int = 0
    var verifiedFiles: Int = 0
    var mismatchedFiles: Int = 0
    var backupCopiedFiles: Int = 0
    var backupFailedFiles: Int = 0
    /// Copied photos whose template metadata or voice-memo link could not be saved.
    var metadataFailedFiles: Int = 0
    /// Metadata-phase progress: photos processed so far out of `metadataTotalFiles`.
    var metadataProcessedFiles: Int = 0
    var metadataTotalFiles: Int = 0
    var currentFile: String = ""
    var importSummary: String = ""
    var errorMessage: String?
    var failureRecords: [ImportFailureRecord] = []
    /// Non-nil only while Overwrite is waiting for explicit user confirmation.
    var overwritePreflight: ImportOverwritePreflight?

    /// Sticky completion banner shown in the inspector until the user confirms it.
    /// A new import clears any previous (un-dismissed) banner.
    var showCompletionBanner: Bool = false
    /// Backs the current completion banner (summary text + clean/problem state).
    private(set) var lastCompletionEntry: ActivityEntry?

    /// Capture-date groups detected from source files.
    var dateGroups: [ImportDateGroup] = [] {
        didSet { refreshSelectedSourceFiles() }
    }
    /// Whether the user wants to sort files into per-date folders.
    var sortByDate: Bool = false {
        didSet {
            AppDefaults.store.set(sortByDate, forKey: UserDefaultsKeys.importSortByDate)
            refreshSelectedSourceFiles()
        }
    }
    /// When `sortByDate` is on, optionally wrap date folders in a parent folder.
    var dateFolderGrouping: ImportDateFolderGrouping = .none {
        didSet {
            AppDefaults.store.set(dateFolderGrouping.rawValue, forKey: UserDefaultsKeys.importDateFolderGrouping)
            AppDefaults.store.set(dateFolderGrouping == .year, forKey: UserDefaultsKeys.importGroupByYear)
        }
    }
    /// When a single capture date is split into multiple shoots, import the shoots
    /// as subfolders inside that date folder instead of sibling date folders.
    var splitShootsIntoSubfolders: Bool = false {
        didSet {
            AppDefaults.store.set(splitShootsIntoSubfolders, forKey: UserDefaultsKeys.importSplitShootsIntoSubfolders)
            normalizeSplitFolderLayout()
        }
    }
    /// Whether date scanning is in progress.
    var isScanningDates: Bool = false
    /// Existing destination folders keyed by their `yyyy-MM-dd` prefix. Populated
    /// asynchronously so browsing a large photo destination never blocks the sheet.
    private(set) var previousImportFolderSuggestions: [String: [URL]] = [:]
    var isScanningPreviousImportFolders: Bool = false

    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    @ObservationIgnored private let activityHistory: ActivityHistoryStore?
    /// Per-file copy results accumulated during the current run, used to build the
    /// activity-history entry (per-file destination + verification) on finish.
    @ObservationIgnored private var copyResults: [ImportCopyService.CopyResult] = []
    /// Per-source detail for copied photos whose metadata or voice-memo link failed.
    @ObservationIgnored private var metadataFailureDetailBySource: [URL: String] = [:]
    /// Sources given a unique suffix at planning time because another file in the same import
    /// targeted the same destination name.
    @ObservationIgnored private var plannedRenamedSources: Set<URL> = []
    /// Set once destination folders exist and the sheet has handed off to the sidebar, so a
    /// later error is recorded in Activity instead of only in the (closed) sheet.
    @ObservationIgnored private var importDidStartCopying = false
    @ObservationIgnored private let c2paDetector: @Sendable (URL) async -> Bool
    private let interpolator = PresetVariableInterpolator()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var voiceMemoScanTask: Task<Void, Never>?
    @ObservationIgnored private var voiceMemoAssociationTask: Task<Void, Never>?
    @ObservationIgnored private var voiceMemoAssociationRequestID = UUID()
    @ObservationIgnored private var dateScanTask: Task<Void, Never>?
    @ObservationIgnored private var dateScanRequestID = UUID()
    @ObservationIgnored private var folderSuggestionTask: Task<Void, Never>?
    @ObservationIgnored private var folderSuggestionRequestID = UUID()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importRequestID = UUID()
    @ObservationIgnored private var confirmedOverwriteSignature: [ImportOverwriteExpectation]?
    @ObservationIgnored private let copyService = ImportCopyService()
    @ObservationIgnored private let sourceDiscoveryService = ImportSourceDiscoveryService()
    @ObservationIgnored private let preflightService: ImportPreflightService
    @ObservationIgnored private let directoryService: ExportDirectoryService
    @ObservationIgnored private let captureDateScanService: ImportCaptureDateScanService
    @ObservationIgnored private let folderSuggestionService: ImportFolderSuggestionService
    @ObservationIgnored private let voiceMemoAssociationScanService: ImportVoiceMemoAssociationScanService
    @ObservationIgnored private let pathContainmentService: SafePathContainmentService
    @ObservationIgnored private let executionSecurityScopeService: ImportExecutionSecurityScopeService
    @ObservationIgnored private let bookmarkDefaults: UserDefaults
    @ObservationIgnored private let destinationBookmarkService: ImportDestinationBookmarkService
    @ObservationIgnored private var destinationBookmarkTask: Task<Void, Never>?
    @ObservationIgnored private var destinationBookmarkRequestID: UUID?
    @ObservationIgnored private var backupBookmarkTask: Task<Void, Never>?
    @ObservationIgnored private var backupBookmarkRequestID: UUID?
    private let importLog = Logger(subsystem: "com.aagedal.photo-agent", category: "Import")

    init(
        readService: SwiftExifReadService,
        writeEngine: any MetadataWriteEngine,
        activityHistory: ActivityHistoryStore? = nil,
        preflightService: ImportPreflightService = ImportPreflightService(),
        directoryService: ExportDirectoryService = .shared,
        captureDateScanService: ImportCaptureDateScanService = ImportCaptureDateScanService(),
        folderSuggestionService: ImportFolderSuggestionService = ImportFolderSuggestionService(),
        voiceMemoAssociationScanService: ImportVoiceMemoAssociationScanService = ImportVoiceMemoAssociationScanService(),
        pathContainmentService: SafePathContainmentService = .shared,
        executionSecurityScopeService: ImportExecutionSecurityScopeService = .shared,
        bookmarkDefaults: UserDefaults = AppDefaults.store,
        destinationBookmarkService: ImportDestinationBookmarkService = .shared,
        c2paDetector: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.readService = readService
        self.c2paDetector = c2paDetector ?? { url in
            ((try? await readService.readTechnicalMetadata(url: url, includeNativeImageInfo: false))?.hasC2PA) ?? false
        }
        self.writeEngine = writeEngine
        self.activityHistory = activityHistory
        self.preflightService = preflightService
        self.directoryService = directoryService
        self.captureDateScanService = captureDateScanService
        self.folderSuggestionService = folderSuggestionService
        self.voiceMemoAssociationScanService = voiceMemoAssociationScanService
        self.pathContainmentService = pathContainmentService
        self.executionSecurityScopeService = executionSecurityScopeService
        self.bookmarkDefaults = bookmarkDefaults
        self.destinationBookmarkService = destinationBookmarkService

        // Restore last-used verification mode (default = .on).
        if let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.importVerificationMode),
           let mode = CopyVerificationMode(rawValue: raw) {
            self.configuration.verificationMode = mode
        }
        if let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.importFileTypeFilter),
           let filter = ImportFileTypeFilter(rawValue: raw) {
            self.configuration.fileTypeFilter = filter
        }
        if let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.importConflictPolicy),
           let policy = ImportConflictPolicy(rawValue: raw) {
            self.configuration.conflictPolicy = policy
        }
        if AppDefaults.store.object(forKey: UserDefaultsKeys.importCreateSubFolders) != nil {
            self.configuration.createSubFolders = AppDefaults.store.bool(forKey: UserDefaultsKeys.importCreateSubFolders)
        }
        // Restore last-used date-folder grouping. Fall back to the legacy year
        // toggle so existing installs keep their previous behavior.
        if AppDefaults.store.object(forKey: UserDefaultsKeys.importSortByDate) != nil {
            self.sortByDate = AppDefaults.store.bool(forKey: UserDefaultsKeys.importSortByDate)
        }
        if let rawGrouping = AppDefaults.store.string(forKey: UserDefaultsKeys.importDateFolderGrouping),
           let grouping = ImportDateFolderGrouping(rawValue: rawGrouping) {
            self.dateFolderGrouping = grouping
        } else {
            self.dateFolderGrouping = AppDefaults.store.bool(forKey: UserDefaultsKeys.importGroupByYear) ? .year : .none
        }
        self.splitShootsIntoSubfolders = AppDefaults.store.bool(forKey: UserDefaultsKeys.importSplitShootsIntoSubfolders)
        if AppDefaults.store.object(forKey: UserDefaultsKeys.importSkipPreviouslyImported) != nil {
            self.configuration.skipPreviouslyImported = AppDefaults.store.bool(forKey: UserDefaultsKeys.importSkipPreviouslyImported)
        }
        scheduleDestinationBookmarkLoad()
        scheduleBackupBookmarkLoad()
    }

    deinit {
        scanTask?.cancel()
        voiceMemoScanTask?.cancel()
        voiceMemoAssociationTask?.cancel()
        dateScanTask?.cancel()
        folderSuggestionTask?.cancel()
        importTask?.cancel()
        destinationBookmarkTask?.cancel()
        backupBookmarkTask?.cancel()
    }

    var isImporting: Bool {
        switch importPhase {
        case .copying, .applyingMetadata:
            return true
        default:
            return false
        }
    }

    private func refreshDerivedSourceLists() {
        let secondSourceImages = voiceMemoSourceFiles.filter {
            SupportedImageFormats.isSupported(url: $0)
        }
        var seen = Set<URL>()
        allSourceImages = (sourceFiles + secondSourceImages).filter {
            seen.insert(canonicalVoiceMemoImageURL(for: $0)).inserted
        }
        refreshFilteredSourceFiles()
    }

    private func refreshFilteredSourceFiles() {
        switch configuration.fileTypeFilter {
        case .rawOnly:
            filteredSourceFiles = allSourceImages.filter { SupportedImageFormats.isRaw(url: $0) }
        case .jpegOnly:
            filteredSourceFiles = allSourceImages.filter { SupportedImageFormats.isJPEG(url: $0) }
        case .both:
            filteredSourceFiles = allSourceImages
        }
        refreshSelectedSourceFiles()
    }

    private func refreshSelectedSourceFiles() {
        guard sortByDate else {
            selectedSourceFiles = filteredSourceFiles
            return
        }
        let includedFiles = Set(dateGroups.filter(\.isIncluded).flatMap(\.files))
        selectedSourceFiles = filteredSourceFiles.filter { includedFiles.contains($0) }
    }

    private func refreshIgnoredSourceFiles() {
        ignoredSourceFiles = ignoredPrimarySourceFiles + ignoredSecondSourceFiles
    }

    /// "N other files won't be imported (videos, sidecars…)" for the source section, or nil.
    var ignoredSourceFilesNotice: String? {
        Self.ignoredFilesNotice(for: ignoredSourceFiles)
    }

    nonisolated static func ignoredFilesNotice(for files: [URL]) -> String? {
        guard !files.isEmpty else { return nil }
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mts", "m2ts", "avi", "mxf", "3gp"]
        let sidecarExtensions: Set<String> = ["xmp", "thm", "xml", "lrv"]
        var kinds: [String] = []
        let extensions = Set(files.map { $0.pathExtension.lowercased() })
        if !extensions.isDisjoint(with: videoExtensions) { kinds.append("videos") }
        if !extensions.isDisjoint(with: sidecarExtensions) { kinds.append("sidecars") }
        if !extensions.subtracting(videoExtensions).subtracting(sidecarExtensions).isEmpty {
            kinds.append("other files")
        }
        let count = files.count
        return "\(count) other file\(count == 1 ? "" : "s") won’t be imported (\(kinds.joined(separator: ", ")))."
    }

    /// Copies each copied photo's stem-named `.xmp` sidecar next to its primary and backup copy,
    /// renamed with the photo. A RAW+JPEG pair shares one sidecar, so an existing destination
    /// sidecar (from the pair partner, or already on disk) is never replaced. Returns failures.
    nonisolated static func copyXMPSidecars(
        for results: [ImportCopyService.CopyResult],
        imageSources: Set<URL>
    ) -> [(source: URL, detail: String)] {
        let fileManager = FileManager.default
        let sidecars = XMPSidecarService()
        var failures: [(source: URL, detail: String)] = []
        for result in results where imageSources.contains(result.source) {
            let sourceSidecar = sidecars.sidecarURL(for: result.source)
            guard sourceSidecar != result.source,
                  fileManager.fileExists(atPath: sourceSidecar.path) else { continue }
            var destinations: [URL] = []
            if let primary = result.primaryURL { destinations.append(sidecars.sidecarURL(for: primary)) }
            if let backup = result.backup, case let .copied(backupURL, _, _, _) = backup {
                switch result.backupVerification {
                case .mismatch, .failed: break
                case .verified, .skipped, nil: destinations.append(sidecars.sidecarURL(for: backupURL))
                }
            }
            for destination in destinations where !fileManager.fileExists(atPath: destination.path) {
                do {
                    try PhotoSidecarOwnership.copyPreservingSource(from: sourceSidecar, to: destination)
                } catch {
                    failures.append((result.source, "XMP sidecar not copied: \(error.localizedDescription)"))
                }
            }
        }
        return failures
    }

    /// Discovered files that are neither supported images nor WAV voice memos. A stem-named
    /// `.xmp` beside a supported image travels with that image, so it is not reported.
    nonisolated private static func unsupportedFiles(in urls: [URL]) -> [URL] {
        let imageStems = Set(urls.filter { SupportedImageFormats.isSupported(url: $0) }.map {
            $0.deletingPathExtension().path.lowercased()
        })
        return urls.filter {
            !SupportedImageFormats.isSupported(url: $0)
                && $0.pathExtension.caseInsensitiveCompare("wav") != .orderedSame
                && !($0.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame
                    && imageStems.contains($0.deletingPathExtension().path.lowercased()))
        }
    }

    /// Files processed so far in the copy phase, including skips and failures, so the
    /// progress bar advances for every file rather than only successful copies.
    var processedFiles: Int {
        copiedFiles + skippedFiles + failedFiles
    }

    var selectedVoiceMemoAssociations: [VoiceMemoAssociation] {
        let selected = Set(selectedSourceFiles.map(canonicalVoiceMemoImageURL(for:)))
        return voiceMemoAssociationReport?.associations.filter {
            selected.contains($0.imageURL)
        } ?? []
    }

    var selectedVoiceMemoCount: Int {
        Set(selectedVoiceMemoAssociations.map(\.memoURL)).count
    }

    /// Explains why the import cannot start, in the same priority order the
    /// user encounters the setup steps. Keeping this validation in the view
    /// model ensures the button state, its explanation, and `startImport()`
    /// cannot drift apart.
    var importBlockingReason: String? {
        if importPhase == .scanning {
            return "Scanning the source folder…"
        }
        if isScanningVoiceMemoSource {
            return "Analyzing image and voice-memo matches…"
        }
        if configuration.sourceURL == nil {
            return "Choose a memory card or folder to import from."
        }
        if allSourceImages.isEmpty {
            return "No supported images were found in the source folder."
        }
        if filteredSourceFiles.isEmpty {
            return "No images match the \(configuration.fileTypeFilter.rawValue) filter."
        }

        if sortByDate {
            if isScanningDates {
                return "Scanning capture dates…"
            }
            if dateGroups.isEmpty {
                return "Scan capture dates before importing."
            }
            if selectedSourceFiles.isEmpty {
                return "Select at least one date folder to import."
            }
        } else if configuration.importTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an import title."
        }

        return nil
    }

    // MARK: - Source Selection

    func selectSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a memory card or folder to import photos from"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.sourceURL = url
        scanSource(url: url)
    }

    private func scanSource(url: URL) {
        scanTask?.cancel()
        // A new source folder invalidates any previously detected date groups
        // (and any manual shoot splits); clear them so the list never shows stale
        // entries from the old folder.
        dateScanTask?.cancel()
        dateScanRequestID = UUID()
        isScanningDates = false
        importPhase = .scanning
        sourceFiles = []
        sourceVoiceMemoFiles = []
        ignoredPrimarySourceFiles = []
        refreshIgnoredSourceFiles()
        voiceMemoAssociationReport = nil
        canonicalVoiceMemoImageURLBySource = [:]
        dateGroups = []
        sourceScanProgress = ImportSourceDiscoveryProgress()

        scanTask = Task(priority: .userInitiated) { [sourceDiscoveryService] in
            do {
                let allURLs = try await sourceDiscoveryService.discoverFiles(at: url) { progress in
                    await MainActor.run {
                        guard self.configuration.sourceURL == url,
                              self.importPhase == .scanning else { return }
                        self.sourceScanProgress = progress
                    }
                }
                try Task.checkCancellation()
                guard self.configuration.sourceURL == url else { return }
                self.sourceFiles = allURLs
                    .filter { SupportedImageFormats.isSupported(url: $0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                self.sourceVoiceMemoFiles = allURLs
                    .filter { $0.pathExtension.caseInsensitiveCompare("wav") == .orderedSame }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                self.ignoredPrimarySourceFiles = Self.unsupportedFiles(in: allURLs)
                self.refreshIgnoredSourceFiles()
                self.importPhase = .idle
                self.refreshVoiceMemoAssociations()
                // Re-detect capture dates for the new folder when date sorting is on.
                if self.sortByDate {
                    self.scanCaptureDates()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.configuration.sourceURL == url else { return }
                self.importPhase = .idle
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Selects an optional second media source. Its images follow the same RAW/JPEG import filter
    /// as the first source, and any Sony WAVs participate in exposure association.
    func selectVoiceMemoSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select an optional second memory card or media folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setVoiceMemoSource(url)
    }

    func setVoiceMemoSource(_ url: URL) {
        configuration.voiceMemoSourceURL = url
        scanVoiceMemoSource(url: url)
    }

    func clearVoiceMemoSource() {
        voiceMemoScanTask?.cancel()
        voiceMemoAssociationTask?.cancel()
        configuration.voiceMemoSourceURL = nil
        voiceMemoSourceFiles = []
        ignoredSecondSourceFiles = []
        refreshIgnoredSourceFiles()
        voiceMemoSourceScanProgress = ImportSourceDiscoveryProgress()
        isDiscoveringVoiceMemoSource = false
        refreshVoiceMemoAssociations()
        if sortByDate {
            scanCaptureDates()
        }
    }

    private func scanVoiceMemoSource(url: URL) {
        voiceMemoScanTask?.cancel()
        voiceMemoAssociationTask?.cancel()
        voiceMemoAssociationRequestID = UUID()
        voiceMemoSourceFiles = []
        ignoredSecondSourceFiles = []
        refreshIgnoredSourceFiles()
        voiceMemoAssociationReport = nil
        canonicalVoiceMemoImageURLBySource = [:]
        voiceMemoSourceScanProgress = ImportSourceDiscoveryProgress()
        isDiscoveringVoiceMemoSource = true
        isScanningVoiceMemoSource = true

        voiceMemoScanTask = Task(priority: .userInitiated) { [sourceDiscoveryService] in
            do {
                let allURLs = try await sourceDiscoveryService.discoverFiles(at: url) { progress in
                    await MainActor.run {
                        guard self.configuration.voiceMemoSourceURL == url,
                              self.isDiscoveringVoiceMemoSource else { return }
                        self.voiceMemoSourceScanProgress = progress
                    }
                }
                let files = allURLs.filter {
                    SupportedImageFormats.isSupported(url: $0)
                        || $0.pathExtension.caseInsensitiveCompare("wav") == .orderedSame
                }
                try Task.checkCancellation()
                guard self.configuration.voiceMemoSourceURL == url else { return }
                self.isDiscoveringVoiceMemoSource = false
                self.ignoredSecondSourceFiles = Self.unsupportedFiles(in: allURLs)
                self.refreshIgnoredSourceFiles()
                self.voiceMemoSourceFiles = files.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
                self.refreshVoiceMemoAssociations()
                if self.sortByDate {
                    self.scanCaptureDates()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.configuration.voiceMemoSourceURL == url else { return }
                self.isDiscoveringVoiceMemoSource = false
                self.isScanningVoiceMemoSource = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshVoiceMemoAssociations() {
        voiceMemoAssociationTask?.cancel()
        let requestID = UUID()
        voiceMemoAssociationRequestID = requestID
        let hasMemoCandidates = !sourceVoiceMemoFiles.isEmpty
            || voiceMemoSourceFiles.contains {
                $0.pathExtension.caseInsensitiveCompare("wav") == .orderedSame
            }
        guard !allSourceImages.isEmpty, hasMemoCandidates else {
            voiceMemoAssociationReport = nil
            canonicalVoiceMemoImageURLBySource = [:]
            isScanningVoiceMemoSource = false
            return
        }

        isScanningVoiceMemoSource = true
        let primaryFiles = sourceFiles
        let companionFiles = voiceMemoSourceFiles
        let primaryMemoFiles = sourceVoiceMemoFiles
        let primaryRoot = configuration.sourceURL
        let companionRoot = configuration.voiceMemoSourceURL
        voiceMemoAssociationTask = Task(priority: .userInitiated) { [voiceMemoAssociationScanService] in
            let result = await voiceMemoAssociationScanService.scan(
                primaryImages: primaryFiles,
                primaryMemos: primaryMemoFiles,
                companionFiles: companionFiles,
                primaryRoot: primaryRoot,
                companionRoot: companionRoot
            )
            guard self.voiceMemoAssociationRequestID == requestID else { return }
            switch result {
            case .complete(let evidence):
                self.voiceMemoAssociationReport = evidence.report
                self.canonicalVoiceMemoImageURLBySource = evidence.canonicalImageURLBySource
                self.isScanningVoiceMemoSource = false
            case .cancelled:
                self.isScanningVoiceMemoSource = false
            }
        }
    }

    // MARK: - Destination Selection

    func selectDestinationBase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the destination root folder for imports"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        scheduleDestinationBookmarkCreation(for: url)
    }

    func setDestinationBaseURL(_ url: URL) async {
        scheduleDestinationBookmarkCreation(for: url)
        await destinationBookmarkTask?.value
    }

    // MARK: - Existing Date-Folder Suggestions

    var currentImportDateFolderName: String {
        String(configuration.destinationFolderName.prefix(10))
    }

    /// Rebuilds the lightweight list of existing same-date folders. This only
    /// inspects the importer-supported folder levels; it does not enumerate or
    /// checksum their files until an import actually starts.
    func refreshPreviousImportFolderSuggestions() {
        folderSuggestionTask?.cancel()
        let requestID = UUID()
        folderSuggestionRequestID = requestID

        let dates: Set<String>
        if sortByDate {
            dates = Set(dateGroups.map { displayDate(for: $0) })
        } else {
            dates = [currentImportDateFolderName]
        }

        guard !dates.isEmpty else {
            previousImportFolderSuggestions = [:]
            isScanningPreviousImportFolders = false
            return
        }

        let destinationBaseURL = configuration.destinationBaseURL
        previousImportFolderSuggestions = [:]
        isScanningPreviousImportFolders = true

        folderSuggestionTask = Task(priority: .utility) { [weak self, folderSuggestionService] in
            let result = await folderSuggestionService.suggestions(
                for: dates,
                under: destinationBaseURL
            )
            guard let self, self.folderSuggestionRequestID == requestID else { return }
            switch result {
            case .complete(let evidence):
                self.previousImportFolderSuggestions = evidence.suggestions
                self.isScanningPreviousImportFolders = false
            case .cancelled:
                self.isScanningPreviousImportFolders = false
            }
        }
    }

    /// Standard flat-import folders directly below the current destination base.
    /// Only app-generated `<date> – <title>` names are selectable because those
    /// can be represented exactly by `ImportConfiguration.importTitle`.
    func suggestedFoldersForCurrentImportDate() -> [URL] {
        let date = currentImportDateFolderName
        let expectedParent = configuration.destinationBaseURL.standardizedFileURL
        return (previousImportFolderSuggestions[date] ?? []).filter { url in
            url.deletingLastPathComponent().standardizedFileURL == expectedParent
                && PreviousImportDetector.importTitle(
                    from: url.lastPathComponent,
                    matchingDate: date
                ) != nil
        }
    }

    /// Same-date folders at the exact grouping level currently selected for a
    /// capture-date group, so choosing one always targets the folder being shown.
    func suggestedFolders(for group: ImportDateGroup) -> [URL] {
        let date = displayDate(for: group)
        let expectedParent = Self.appendingPathComponents(
            folderGroupingComponents(for: group, grouping: dateFolderGrouping),
            to: configuration.destinationBaseURL
        ).standardizedFileURL
        return (previousImportFolderSuggestions[date] ?? []).filter {
            $0.deletingLastPathComponent().standardizedFileURL == expectedParent
        }
    }

    func useSuggestedFolderForCurrentImport(_ folder: URL) {
        let date = currentImportDateFolderName
        guard suggestedFoldersForCurrentImportDate().contains(folder),
              let title = PreviousImportDetector.importTitle(
                from: folder.lastPathComponent,
                matchingDate: date
              ) else { return }
        configuration.importTitle = title
    }

    func useSuggestedFolder(_ folder: URL, for groupID: UUID) {
        guard let index = dateGroups.firstIndex(where: { $0.id == groupID }),
              suggestedFolders(for: dateGroups[index]).contains(folder) else { return }
        dateGroups[index].folderName = folder.lastPathComponent
        ensureUniqueFolderNames()
    }

    // MARK: - Template Application

    func applyTemplate(_ template: MetadataTemplate) {
        for field in template.fields {
            let value = field.templateValue
            switch field.fieldKey {
            case "title": configuration.metadata.title = value
            case "description": configuration.metadata.description = value
            case "extendedDescription": configuration.metadata.extendedDescription = value
            case "keywords":
                configuration.metadata.keywords = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "personShown":
                configuration.metadata.personShown = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "organisationShownName":
                configuration.metadata.organisationsShownNames = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "organisationShownCode":
                configuration.metadata.organisationsShownCodes = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "digitalSourceType":
                configuration.metadata.digitalSourceType = DigitalSourceType(metadataValue: value)
            case "urgency":
                configuration.metadata.urgency = Int(value)
            case "sceneCode":
                configuration.metadata.sceneCodes = IPTCSceneCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
            case "subjectCode":
                configuration.metadata.subjectCodes = IPTCSubjectCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
            case "mediaTopic":
                configuration.metadata.mediaTopics = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
                )
            case "genre":
                configuration.metadata.genres = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
                )
            case "creator":
                configuration.metadata.creators = IPTCMetadata.creators(fromTransportValue: value)
            case "creatorJobTitle": configuration.metadata.creatorJobTitle = value
            case "descriptionWriter": configuration.metadata.descriptionWriter = value
            case "credit": configuration.metadata.credit = value
            case "copyright": configuration.metadata.copyright = value
            case "rightsUsageTerms": configuration.metadata.rightsUsageTerms = value
            case "webStatementOfRights": configuration.metadata.webStatementOfRights = value
            case "digitalImageGUID": configuration.metadata.digitalImageGUID = value
            case "imageSupplierImageID": configuration.metadata.imageSupplierImageID = value
            case "imageSupplier":
                if let values = EditorialImageSupplier.values(fromCanonicalJSONString: value) {
                    configuration.metadata.imageSuppliers = values
                }
            case "jobId": configuration.metadata.jobId = value
            case "dateCreated":
                if MetadataTemplatePlaceholderDetector.containsPlaceholder(value)
                    || (try? EditorialDateCreated(parsing: value)) != nil {
                    configuration.metadata.dateCreated = value
                }
            case "city": configuration.metadata.city = value
            case "sublocation": configuration.metadata.sublocation = value
            case "provinceState": configuration.metadata.provinceState = value
            case "country": configuration.metadata.country = value
            case "countryCode": configuration.metadata.countryCode = ISO3166Country.normalizedAlpha3(value)
            case "event": configuration.metadata.event = value
            case "instructions": configuration.metadata.instructions = value
            case "source": configuration.metadata.source = value
            default: break
            }
        }
    }

    // MARK: - Import Execution

    func startImport() {
        if let importBlockingReason {
            errorMessage = importBlockingReason
            return
        }

        let filesToCopy = selectedSourceFiles
        let voiceMemoByImage = Dictionary(
            uniqueKeysWithValues: selectedVoiceMemoAssociations.map { ($0.imageURL, $0.memoURL) }
        )

        // Guard against two date groups (e.g. split sub-shoots, or a manual rename)
        // resolving to the same destination folder, which would silently merge them.
        if sortByDate {
            ensureUniqueFolderNames()
        }

        let baseURL = configuration.destinationBaseURL.standardizedFileURL
        let destURL: URL
        do {
            destURL = try SafePathComponent.appending(
                configuration.destinationFolderName,
                label: "Import folder name",
                to: baseURL
            )
            if sortByDate {
                for group in dateGroups where group.isIncluded {
                    _ = try SafePathComponent.validate(group.folderName, label: "Date folder name")
                    if let shoot = group.shootFolderName,
                       !shoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try SafePathComponent.validate(shoot, label: "Shoot folder name")
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        importPhase = .copying
        copiedFiles = 0
        voiceMemoCopiedFiles = 0
        totalFiles = 0
        skippedFiles = 0
        duplicateSkippedFiles = 0
        renamedFiles = 0
        replacedFiles = 0
        backupReplacedFiles = 0
        failedFiles = 0
        verifiedFiles = 0
        mismatchedFiles = 0
        backupCopiedFiles = 0
        backupFailedFiles = 0
        metadataFailedFiles = 0
        metadataProcessedFiles = 0
        metadataTotalFiles = 0
        currentFile = ""
        importSummary = ""
        errorMessage = nil
        failureRecords = []
        // A fresh import replaces any previous (un-dismissed) completion banner.
        copyResults = []
        metadataFailureDetailBySource = [:]
        importDidStartCopying = false
        showCompletionBanner = false
        lastCompletionEntry = nil

        // Persist verification mode for next run.
        AppDefaults.store.set(configuration.verificationMode.rawValue, forKey: UserDefaultsKeys.importVerificationMode)
        AppDefaults.store.set(configuration.fileTypeFilter.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter)
        AppDefaults.store.set(configuration.skipPreviouslyImported, forKey: UserDefaultsKeys.importSkipPreviouslyImported)

        // Capture configuration values for the background copy.
        let createSubFolders = configuration.createSubFolders
        let conflictPolicy = configuration.conflictPolicy
        let verificationMode = configuration.verificationMode
        let backupDestination = configuration.backupDestination
        let applyMetadata = configuration.applyMetadata
        let processVariables = configuration.processVariables
        let sortByDate = self.sortByDate
        let dateFolderGrouping = self.dateFolderGrouping
        let dateGroups = self.dateGroups
        // Sync import title as metadata title before capturing.
        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            configuration.metadata.title = trimmedTitle
        }
        let metadata = configuration.metadata

        // Pre-compute file→date-group folder name (and optional year prefix) for O(1) lookup.
        var fileDateFolder: [URL: String] = [:]
        var fileDateGroupingFolders: [URL: [String]] = [:]
        var fileShootFolder: [URL: String] = [:]
        var fileImportDate: [URL: String] = [:]
        if sortByDate {
            for group in dateGroups where group.isIncluded {
                for file in group.files {
                    fileDateFolder[file] = group.folderName
                    fileDateGroupingFolders[file] = folderGroupingComponents(for: group, grouping: dateFolderGrouping)
                    fileImportDate[file] = displayDate(for: group)
                    if let shoot = group.shootFolderName?.trimmingCharacters(in: .whitespaces), !shoot.isEmpty {
                        fileShootFolder[file] = shoot
                    }
                }
            }
        }

        // Pre-compute file→target folder on main actor (SupportedImageFormats is MainActor).
        // Returns: (primaryFolder, backupFolder?). Backup mirrors the primary folder structure
        // under the chosen backup root.
        var jobDrafts: [ImportJobDraft] = []
        var bundleRequests: [ImportPreflightService.BundleDestinationRequest] = []
        var previousImportCandidates: [PreviousImportDetector.Candidate] = []
        var primaryDestinations: [URL] = []
        var allDestFolders: Set<URL> = []
        var allRevealFolders: Set<URL> = []
        var batchNamePlanner = ImportBatchNamePlanner()
        var renamedSources: Set<URL> = []
        let flatImportDate = String(destURL.lastPathComponent.prefix(10))
        for file in filesToCopy {
            let baseFolder: URL
            if sortByDate {
                if let folderName = fileDateFolder[file] {
                    baseFolder = Self.appendingPathComponents(fileDateGroupingFolders[file] ?? [], to: baseURL)
                        .appendingPathComponent(folderName)
                } else {
                    baseFolder = destURL
                }
            } else {
                baseFolder = destURL
            }
            let shootBaseFolder = fileShootFolder[file].map { baseFolder.appendingPathComponent($0) } ?? baseFolder

            let primaryFolder: URL
            if configuration.fileTypeFilter == .both && createSubFolders {
                if SupportedImageFormats.isRaw(url: file) {
                    primaryFolder = shootBaseFolder.appendingPathComponent("RAW")
                } else if SupportedImageFormats.isJPEG(url: file) {
                    primaryFolder = shootBaseFolder.appendingPathComponent("JPEG")
                } else {
                    primaryFolder = shootBaseFolder
                }
            } else {
                primaryFolder = shootBaseFolder
            }
            allRevealFolders.insert(shootBaseFolder)
            allDestFolders.insert(primaryFolder)

            let canonicalImage = canonicalVoiceMemoImageURL(for: file)
            let memoSource = voiceMemoByImage[canonicalImage]
            let memoExtension = memoSource.map { $0.pathExtension.isEmpty ? "wav" : $0.pathExtension }
            // Two sources with the same name (two bodies, a counter reset) must never target
            // the same file within one import, whatever the conflict policy: give the later one
            // a unique suffix now, and keep its voice memo on that same suffix.
            let plannedName = batchNamePlanner.plan(
                source: file,
                folder: primaryFolder,
                exposureFolder: shootBaseFolder,
                memoSource: memoSource,
                memoExtension: memoExtension
            )
            let primaryURL = plannedName.image
            if plannedName.wasRenamed {
                renamedSources.insert(file)
            }
            primaryDestinations.append(primaryURL)

            // Mirror the relative path (under destinationBaseURL) into the backup destination.
            var backupURL: URL?
            if let backupRoot = backupDestination?.url {
                if let relative = Self.relativePath(of: primaryURL, under: baseURL) {
                    let backupTarget = backupRoot.appendingPathComponent(relative)
                    backupURL = backupTarget
                    allDestFolders.insert(backupTarget.deletingLastPathComponent())
                }
            }

            var bundleRequestID: UUID?
            if memoSource != nil, let desiredMemo = plannedName.memo {
                let desiredMemoBackup: URL?
                if let backupRoot = backupDestination?.url,
                   let relative = Self.relativePath(of: desiredMemo, under: baseURL) {
                    desiredMemoBackup = backupRoot.appendingPathComponent(relative)
                } else {
                    desiredMemoBackup = nil
                }
                let bundleRequest = ImportPreflightService.BundleDestinationRequest(
                    image: primaryURL,
                    memo: desiredMemo,
                    imageBackup: backupURL,
                    memoBackup: desiredMemoBackup
                )
                bundleRequestID = bundleRequest.id
                bundleRequests.append(bundleRequest)
            }

            jobDrafts.append(ImportJobDraft(
                source: file,
                imageDestination: primaryURL,
                imageBackupDestination: backupURL,
                memoSource: memoSource,
                bundleRequestID: bundleRequestID
            ))
            previousImportCandidates.append(PreviousImportDetector.Candidate(
                source: file,
                dateFolderName: fileImportDate[file] ?? flatImportDate
            ))
        }

        plannedRenamedSources = renamedSources
        let initialFolders = allDestFolders
        let folderToOpen = Self.commonAncestor(of: Array(allRevealFolders)) ?? destURL
        let verifyBackup = backupDestination?.verifyAfterWrite ?? true
        let skipPreviouslyImported = configuration.skipPreviouslyImported
        let copyService = self.copyService
        let preflightService = self.preflightService
        let directoryService = self.directoryService
        let imageSources = Set(filesToCopy)
        let voiceMemoAssociationsToPersist = selectedVoiceMemoAssociations
        let primarySourceURL = configuration.sourceURL
        let voiceMemoSourceURL = configuration.voiceMemoSourceURL
        let plannedPrimaryDestinations = primaryDestinations
        let plannedBundleRequests = bundleRequests
        let plannedJobDrafts = jobDrafts
        let plannedPreviousImportCandidates = previousImportCandidates
        let requestID = UUID()
        let executionSecurityScopeService = self.executionSecurityScopeService
        let initialSecurityScopeRequest = ImportExecutionSecurityScopeRequest(
            requestID: requestID,
            roots: [primarySourceURL, voiceMemoSourceURL, baseURL]
        )
        importRequestID = requestID

        importTask = Task.detached(priority: .userInitiated) { [readService, interpolator, importLog, pathContainmentService, weak self] in
            guard let self else { return }
            _ = readService

            do {
                try await executionSecurityScopeService.withAccess(initialSecurityScopeRequest) {
                    let primaryContainment = await pathContainmentService.inspect(
                        SafePathContainmentRequest(
                            requestID: requestID,
                            root: baseURL,
                            candidates: plannedPrimaryDestinations
                        )
                    )
                    switch primaryContainment {
                    case .complete(let evidence):
                        guard evidence.requestID == requestID,
                              evidence.requestedCandidateCount == plannedPrimaryDestinations.count,
                              evidence.checkedCandidateCount == plannedPrimaryDestinations.count,
                              evidence.escapingCandidate == nil else {
                            throw ImportPlanningError.imageDestinationEscaped
                        }
                    case .cancelled:
                        throw CancellationError()
                    }
                    try Task.checkCancellation()

                    let bundlePlanning = await preflightService.resolveBundleDestinations(
                        plannedBundleRequests,
                        policy: conflictPolicy
                    )
                    let bundleEvidence: ImportPreflightService.BundlePlanningEvidence
                    switch bundlePlanning {
                    case .complete(let evidence):
                        bundleEvidence = evidence
                    case .cancelled:
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                    let isCurrentPlanningOperation = await MainActor.run {
                        self.importRequestID == requestID
                    }
                    guard isCurrentPlanningOperation else { return }
                    guard bundleEvidence.requestedBundleCount == plannedBundleRequests.count,
                          bundleEvidence.completedBundleCount == plannedBundleRequests.count else {
                        throw ImportPlanningError.incompleteBundleEvidence
                    }

                    let bundleDestinations = Dictionary(
                        uniqueKeysWithValues: bundleEvidence.destinations.map { ($0.id, $0) }
                    )
                    let memoDestinations = plannedJobDrafts.compactMap { draft in
                        draft.bundleRequestID.flatMap { bundleDestinations[$0]?.memo }
                    }
                    let memoContainment = await pathContainmentService.inspect(
                        SafePathContainmentRequest(
                            requestID: requestID,
                            root: baseURL,
                            candidates: memoDestinations
                        )
                    )
                    switch memoContainment {
                    case .complete(let evidence):
                        guard evidence.requestID == requestID,
                              evidence.requestedCandidateCount == memoDestinations.count,
                              evidence.checkedCandidateCount == memoDestinations.count,
                              evidence.escapingCandidate == nil else {
                            throw ImportPlanningError.voiceMemoDestinationEscaped
                        }
                    case .cancelled:
                        throw CancellationError()
                    }
                    try Task.checkCancellation()

                    var jobs: [ImportCopyService.CopyJob] = []
                    var companionParentBySource: [URL: URL] = [:]
                    var allFolders = initialFolders
                    var plannedMemoDestinations = Set<URL>()
                    for draft in plannedJobDrafts {
                        try Task.checkCancellation()
                        let bundle = draft.bundleRequestID.flatMap { bundleDestinations[$0] }
                        if draft.bundleRequestID != nil, bundle == nil {
                            throw ImportPlanningError.incompleteBundleEvidence
                        }
                        let imageJob = ImportCopyService.CopyJob(
                            source: draft.source,
                            desiredPrimaryDest: bundle?.image ?? draft.imageDestination,
                            desiredBackupDest: bundle?.imageBackup ?? draft.imageBackupDestination,
                            preflightSkipReason: bundle?.skipReason
                        )
                        jobs.append(imageJob)

                        if let memoSource = draft.memoSource, let bundle {
                            let canonicalMemoDestination = VoiceMemoAssociationService.canonicalURL(bundle.memo)
                            // RAW and JPEG can share a destination folder when format subfolders are off.
                            // In that layout one WAV represents the exposure; schedule its bytes once.
                            if plannedMemoDestinations.insert(canonicalMemoDestination).inserted {
                                jobs.append(ImportCopyService.CopyJob(
                                    source: memoSource,
                                    desiredPrimaryDest: bundle.memo,
                                    desiredBackupDest: bundle.memoBackup,
                                    preflightSkipReason: bundle.skipReason,
                                    prerequisiteJobID: imageJob.id
                                ))
                                companionParentBySource[memoSource] = draft.source
                                allFolders.insert(bundle.memo.deletingLastPathComponent())
                                if let memoBackup = bundle.memoBackup {
                                    allFolders.insert(memoBackup.deletingLastPathComponent())
                                }
                            }
                        }
                    }
                    let preflightRequest = ImportPreflightService.Request(
                        jobs: jobs,
                        previousImportCandidates: plannedPreviousImportCandidates,
                        companionParentBySource: companionParentBySource,
                        destinationBaseURL: baseURL,
                        skipPreviouslyImported: skipPreviouslyImported,
                        freezeOverwriteCollisions: conflictPolicy == .overwrite
                    )
                    if skipPreviouslyImported {
                        await MainActor.run {
                            guard self.importRequestID == requestID else { return }
                            self.currentFile = "Checking same-date folders for duplicates…"
                        }
                    }
                    let preflightResult = try await preflightService.prepare(preflightRequest)
                    let shouldBeginCopy = await MainActor.run {
                        guard self.importRequestID == requestID else { return false }
                        self.totalFiles = preflightResult.jobs.count

                        if let overwrite = preflightResult.overwrite {
                            guard self.confirmedOverwriteSignature == overwrite.signature else {
                                self.confirmedOverwriteSignature = nil
                                self.importPhase = .idle
                                self.overwritePreflight = ImportOverwritePreflight(
                                    primaryCollisionCount: overwrite.primaryCollisionCount,
                                    backupCollisionCount: overwrite.backupCollisionCount,
                                    primaryRoot: baseURL,
                                    backupRoot: backupDestination?.url,
                                    signature: overwrite.signature
                                )
                                return false
                            }
                            // A confirmation is single-use and belongs to this exact collision set.
                            self.confirmedOverwriteSignature = nil
                            self.overwritePreflight = nil
                        } else {
                            self.confirmedOverwriteSignature = nil
                            self.overwritePreflight = nil
                        }

                        return true
                    }
                    guard shouldBeginCopy else { return }
                    let jobsToRun = preflightResult.jobs

                    let backupSecurityScopeRequest = ImportExecutionSecurityScopeRequest(
                        roots: [backupDestination?.url]
                    )
                    let plannedFolders = allFolders
                    try await executionSecurityScopeService.withAccess(backupSecurityScopeRequest) {
                        if conflictPolicy == .overwrite {
                            try ImportCopyService.validateOverwritePreflight(jobs: jobsToRun)
                        }

                        // The browser must never receive a folder URL before that folder exists.
                        // Freeze a deterministic directory batch and publish only after its
                        // serialized commit reports complete evidence. Cancellation or failure
                        // retains the exact durable prefix instead of implying a rollback.
                        var directoriesToPrepare = plannedFolders.sorted { $0.path < $1.path }
                        if !directoriesToPrepare.contains(folderToOpen) {
                            directoriesToPrepare.append(folderToOpen)
                        }
                        let directoryResult = await directoryService.ensureDirectories(
                            at: directoriesToPrepare
                        )
                        switch directoryResult {
                        case .complete(let committedDirectoryURLs):
                            guard committedDirectoryURLs.count == directoriesToPrepare.count else {
                                throw ImportDirectoryPreparationError.incompleteEvidence
                            }
                        case .cancelled:
                            throw CancellationError()
                        case .failed(_, let message):
                            throw ImportDirectoryPreparationError.failed(message)
                        }
                        try Task.checkCancellation()
                        await MainActor.run {
                            guard self.importRequestID == requestID else { return }
                            self.importDidStartCopying = true
                            NotificationCenter.default.post(name: .importStarted, object: folderToOpen)
                        }

                        let results = try await copyService.run(
                            jobs: jobsToRun,
                            conflictPolicy: conflictPolicy,
                            verificationMode: verificationMode,
                            verifyBackup: verifyBackup,
                            progress: { [weak self] result in
                                await MainActor.run {
                                    guard self?.importRequestID == requestID else { return }
                                    self?.applyProgress(result)
                                }
                            }
                        )
                        try Task.checkCancellation()
                        // Bring each photo's existing XMP sidecar (captions, ratings, Camera Raw
                        // edits) along under the photo's final name, as Photo Mechanic does.
                        let sidecarFailures = Self.copyXMPSidecars(for: results, imageSources: imageSources)
                        if !sidecarFailures.isEmpty {
                            await MainActor.run {
                                guard self.importRequestID == requestID else { return }
                                for failure in sidecarFailures {
                                    self.recordMetadataFailure(source: failure.source, detail: failure.detail)
                                }
                            }
                        }
                        // Persist only relationships whose image and memo both survived the copy and
                        // verification boundary. Each relationship commits on its own, so one failed
                        // WAV leg is reported for its photo instead of failing the whole import.
                        let associationRepository = VoiceMemoCompanionRepository()
                        for association in voiceMemoAssociationsToPersist {
                            try Task.checkCancellation()
                            do {
                                _ = try associationRepository.saveImportedAssociations(
                                    [association],
                                    results: results
                                )
                            } catch {
                                let detail = "Voice memo link not saved: \(error.localizedDescription)"
                                await MainActor.run {
                                    guard self.importRequestID == requestID else { return }
                                    self.recordMetadataFailure(source: association.imageURL, detail: detail)
                                }
                            }
                        }
                        // Pull successful primary URLs (verified or verification disabled) for metadata pass.
                        let copiedImages = results.compactMap { result -> (source: URL, destination: URL)? in
                            guard imageSources.contains(result.source),
                                  let destination = result.primaryURL else { return nil }
                            return (result.source, destination)
                        }

                        // Apply metadata if configured
                        if applyMetadata && !copiedImages.isEmpty {
                            let writeModes = await MainActor.run { () -> ImportMetadataWriteModes? in
                                guard self.importRequestID == requestID else { return nil }
                                self.importPhase = .applyingMetadata
                                self.metadataTotalFiles = copiedImages.count
                                self.metadataProcessedFiles = 0
                                return ImportMetadataWriteModes.current
                            }
                            guard let writeModes else { return }

                            // Each file goes to the destination its write preset chooses: RAW always
                            // gets an XMP sidecar (merge keeps any develop block), and a C2PA file is
                            // only embedded into when the preset allows invalidating its credential.
                            let boundary = DescriptiveMetadataWriteBoundary(writeEngine: self.writeEngine)
                            let c2paDetector = self.c2paDetector
                            var sequenceNumber = 1
                            for image in copiedImages {
                                try Task.checkCancellation()
                                let fileMetadata: IPTCMetadata
                                if processVariables {
                                    var resolved = await self.resolveMetadataForFile(
                                        image.destination,
                                        metadata: metadata,
                                        interpolator: interpolator,
                                        sequenceIndex: sequenceNumber
                                    )
                                    // Coordinates read from the file only feed place variables;
                                    // the file already carries them.
                                    resolved.latitude = metadata.latitude
                                    resolved.longitude = metadata.longitude
                                    fileMetadata = resolved
                                    sequenceNumber += 1
                                } else {
                                    fileMetadata = metadata
                                }
                                var failureDetail: String?
                                do {
                                    let mode = await writeModes.mode(
                                        for: image.destination,
                                        hasC2PA: c2paDetector
                                    )
                                    // Merge never clears: drop empty values so a blank field
                                    // can't erase what the camera wrote.
                                    _ = try await boundary.write(
                                        metadata: IPTCMetadata().merged(preferring: fileMetadata),
                                        for: image.destination,
                                        requestedMode: mode,
                                        semantics: .merge
                                    )
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    failureDetail = "Metadata not written: \(error.localizedDescription)"
                                }
                                await MainActor.run {
                                    guard self.importRequestID == requestID else { return }
                                    self.metadataProcessedFiles += 1
                                    if let failureDetail {
                                        self.recordMetadataFailure(source: image.source, detail: failureDetail)
                                    }
                                }
                            }
                        }

                        await MainActor.run {
                            guard self.importRequestID == requestID else { return }
                            self.importPhase = .complete
                            self.importSummary = self.buildImportSummary()
                            importLog.info("Import complete: \(self.importSummary)")
                            self.recordCompletion(cancelled: false)
                            NotificationCenter.default.post(name: .importCompleted, object: destURL)
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.importRequestID == requestID else { return }
                    self.importPhase = .cancelled
                    self.importSummary = self.buildImportSummary()
                    importLog.info("Import cancelled: \(self.importSummary)")
                    self.recordCompletion(cancelled: true)
                    NotificationCenter.default.post(name: .importCompleted, object: destURL)
                }
            } catch ImportCopyService.CopyError.overwritePreflightChanged {
                await MainActor.run {
                    guard self.importRequestID == requestID else { return }
                    self.importPhase = .idle
                    self.errorMessage = ImportCopyService.CopyError.overwritePreflightChanged.localizedDescription
                    // Rebuild and present the changed collision set. No destination
                    // file was staged or replaced after validation failed.
                    self.startImport()
                }
            } catch {
                await MainActor.run {
                    guard self.importRequestID == requestID else { return }
                    self.importPhase = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                    importLog.error("Import failed: \(error.localizedDescription)")
                    // Once copying started the sheet has closed: report the stop in the sidebar
                    // banner and Activity history, where the user can still see it.
                    if self.importDidStartCopying {
                        self.importSummary = self.buildImportSummary()
                        self.recordCompletion(cancelled: false, stopError: error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Cancel a running import. The actor sees the cancellation between files
    /// (and inside the chunk loop) and tears down any partial files before
    /// the result is returned.
    func cancelImport() {
        importTask?.cancel()
    }

    /// Accepts only the exact preflight currently presented. `startImport()` rebuilds
    /// and compares the collision signature before scheduling any destination write.
    func confirmOverwritePreflight() {
        guard let overwritePreflight else { return }
        confirmedOverwriteSignature = overwritePreflight.signature
        self.overwritePreflight = nil
        startImport()
    }

    /// Dismisses overwrite preflight without creating a folder or destination file.
    func cancelOverwritePreflight() {
        confirmedOverwriteSignature = nil
        overwritePreflight = nil
        importPhase = .idle
    }

    @MainActor
    private func applyProgress(_ result: ImportCopyService.CopyResult) {
        currentFile = result.source.lastPathComponent
        copyResults.append(result)

        switch result.primary {
        case .copied(_, let renamed, let replaced, _):
            copiedFiles += 1
            if result.source.pathExtension.lowercased() == "wav" {
                voiceMemoCopiedFiles += 1
            }
            if renamed || plannedRenamedSources.contains(result.source) { renamedFiles += 1 }
            if replaced { replacedFiles += 1 }
        case .skipped(let reason):
            skippedFiles += 1
            if reason == .previouslyImported { duplicateSkippedFiles += 1 }
        case .failed(let detail):
            failedFiles += 1
            failureRecords.append(ImportFailureRecord(source: result.source, kind: .copyFailed, detail: detail))
        }

        switch result.primaryVerification {
        case .verified:
            verifiedFiles += 1
        case .mismatch(let expected, let got):
            mismatchedFiles += 1
            failureRecords.append(ImportFailureRecord(
                source: result.source,
                kind: .verificationMismatch,
                detail: "expected \(expected.shortHex), got \(got.shortHex)"
            ))
        case .skipped, .failed:
            break
        }

        if let backup = result.backup {
            switch backup {
            case .copied(_, _, let replaced, _):
                backupCopiedFiles += 1
                if replaced { backupReplacedFiles += 1 }
            case .failed(let detail):
                backupFailedFiles += 1
                failureRecords.append(ImportFailureRecord(source: result.source, kind: .backupFailed, detail: detail))
            case .skipped(_):
                break
            }
        }
    }

    /// Records a copied photo whose template metadata or voice-memo link could not be saved.
    /// The import continues; the failure is listed in the summary and Activity history.
    @MainActor
    private func recordMetadataFailure(source: URL, detail: String) {
        let key = source.standardizedFileURL
        if metadataFailureDetailBySource[key] == nil {
            metadataFailedFiles += 1
        }
        metadataFailureDetailBySource[key] = [metadataFailureDetailBySource[key], detail]
            .compactMap { $0 }
            .joined(separator: " ")
        failureRecords.append(ImportFailureRecord(source: source, kind: .metadataFailed, detail: detail))
    }

    /// Builds an activity-history entry from the accumulated per-file results,
    /// records it to the shared history, and raises the sticky completion banner.
    /// `stopError` is set when the import stopped with an error after it had started copying.
    @MainActor
    private func recordCompletion(cancelled: Bool, stopError: String? = nil) {
        let verificationEnabled = configuration.verificationMode == .on
        let files: [ActivityFileRecord] = copyResults.map { result in
            let destination: String
            let succeeded: Bool
            if let url = result.primaryURL {
                destination = url.deletingLastPathComponent().path
                succeeded = true
            } else {
                destination = ""
                succeeded = false
            }
            let verification: ActivityVerification
            switch result.primaryVerification {
            case .verified: verification = .verified
            case .mismatch, .failed: verification = .failed
            case .skipped: verification = .notApplicable
            }
            return ActivityFileRecord(
                fileName: result.source.lastPathComponent,
                destination: destination,
                succeeded: succeeded,
                verification: verification,
                statusDetail: statusDetail(for: result)
            )
        }

        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
        let entry = ActivityEntry(
            kind: .importJob,
            date: Date(),
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            successCount: copiedFiles,
            totalCount: totalFiles,
            verificationFailures: mismatchedFiles,
            verificationEnabled: verificationEnabled,
            wasCancelled: cancelled,
            importResultCounts: ActivityImportResultCounts(
                replaced: replacedFiles,
                backupReplaced: backupReplacedFiles,
                skipped: skippedFiles,
                renamed: renamedFiles,
                backupFailed: backupFailedFiles,
                metadataFailed: metadataFailedFiles
            ),
            persistenceError: stopError,
            files: files
        )

        activityHistory?.record(entry)
        lastCompletionEntry = entry
        showCompletionBanner = true
    }

    /// Why a file needs attention, for the Activity detail row. Nil for a clean copy.
    private func statusDetail(for result: ImportCopyService.CopyResult) -> String? {
        var parts: [String] = []
        switch result.primary {
        case .copied:
            break
        case .skipped(let reason):
            switch reason {
            case .destinationExists: parts.append("Skipped: already exists at the destination")
            case .previouslyImported: parts.append("Skipped: already imported")
            case .associatedImageFailed: parts.append("Skipped: its photo was not imported")
            }
        case .failed(let detail):
            parts.append(detail)
        }
        if case .failed(let detail) = result.backup {
            parts.append("Backup failed: \(detail)")
        }
        if let metadataDetail = metadataFailureDetailBySource[result.source.standardizedFileURL] {
            parts.append(metadataDetail)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Dismisses the sticky completion banner (the green-check confirm action).
    func dismissCompletionBanner() {
        showCompletionBanner = false
    }

    nonisolated static func relativePath(of url: URL, under root: URL) -> String? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return nil }
        for (i, c) in rootComponents.enumerated() where urlComponents[i] != c {
            return nil
        }
        return urlComponents[rootComponents.count..<urlComponents.count].joined(separator: "/")
    }

    private struct ImportJobDraft: Sendable {
        let source: URL
        let imageDestination: URL
        let imageBackupDestination: URL?
        let memoSource: URL?
        let bundleRequestID: UUID?
    }

    private func canonicalVoiceMemoImageURL(for source: URL) -> URL {
        canonicalVoiceMemoImageURLBySource[source] ?? source.standardizedFileURL
    }

    private enum ImportPlanningError: LocalizedError {
        case incompleteBundleEvidence
        case imageDestinationEscaped
        case voiceMemoDestinationEscaped

        var errorDescription: String? {
            switch self {
            case .incompleteBundleEvidence:
                return "Voice memo destination planning did not complete. No files were imported."
            case .imageDestinationEscaped:
                return "An import folder name resolves outside the selected destination."
            case .voiceMemoDestinationEscaped:
                return "A voice memo destination resolves outside the selected destination."
            }
        }
    }

    private enum ImportDirectoryPreparationError: LocalizedError {
        case incompleteEvidence
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .incompleteEvidence:
                return "Destination-folder preparation returned incomplete evidence. No files were imported."
            case .failed(let message):
                return "Could not prepare the import destination: \(message)"
            }
        }
    }

    nonisolated static func commonAncestor(of urls: [URL]) -> URL? {
        guard var commonComponents = urls.first?.standardizedFileURL.pathComponents else { return nil }
        for url in urls.dropFirst() {
            let components = url.standardizedFileURL.pathComponents
            var sharedCount = 0
            while sharedCount < commonComponents.count,
                  sharedCount < components.count,
                  commonComponents[sharedCount] == components[sharedCount] {
                sharedCount += 1
            }
            commonComponents = Array(commonComponents.prefix(sharedCount))
            if commonComponents.isEmpty { return nil }
        }
        guard !commonComponents.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: commonComponents))
    }

    private func buildImportSummary() -> String {
        var parts: [String] = []
        let copiedPhotos = copiedFiles - voiceMemoCopiedFiles
        parts.append("Imported \(copiedPhotos) photo\(copiedPhotos == 1 ? "" : "s")")
        if voiceMemoCopiedFiles > 0 {
            parts.append("voice memos \(voiceMemoCopiedFiles)")
        }
        if renamedFiles > 0 { parts.append("renamed \(renamedFiles)") }
        let otherSkipped = skippedFiles - duplicateSkippedFiles
        if otherSkipped > 0 { parts.append("skipped \(otherSkipped)") }
        if duplicateSkippedFiles > 0 { parts.append("already imported \(duplicateSkippedFiles)") }
        if failedFiles > 0 { parts.append("failed \(failedFiles)") }
        if mismatchedFiles > 0 { parts.append("verification failures \(mismatchedFiles)") }
        if metadataFailedFiles > 0 { parts.append("metadata failed \(metadataFailedFiles)") }
        if backupCopiedFiles > 0 || backupFailedFiles > 0 {
            parts.append("backup \(backupCopiedFiles) of \(backupCopiedFiles + backupFailedFiles)")
        }
        return parts.joined(separator: ", ") + "."
    }

    private func resolveMetadataForFile(_ url: URL, metadata: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int = 1) async -> IPTCMetadata {
        let filename = url.lastPathComponent
        var reference = metadata

        if let fileMetadata = try? await readService.readFullMetadata(url: url) {
            reference = fileMetadata.merged(preferring: metadata)
        }

        // Import presets usually don't carry GPS themselves; use coordinates read from the
        // source file/map-backed reference while resolving the preset's place variables.
        var variableMetadata = metadata
        variableMetadata.latitude = variableMetadata.latitude ?? reference.latitude
        variableMetadata.longitude = variableMetadata.longitude ?? reference.longitude
        let metadata = await interpolator.resolvingGPSPlaceVariables(in: variableMetadata)
        var resolved = metadata
        resolved.title = Self.resolveField(metadata.title, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.description = Self.resolveField(metadata.description, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.extendedDescription = Self.resolveField(metadata.extendedDescription, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.creators = IPTCMetadata.normalizedCreators(metadata.creators.compactMap {
            Self.resolveField($0, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        })
        resolved.creatorJobTitle = Self.resolveField(metadata.creatorJobTitle, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.descriptionWriter = Self.resolveField(metadata.descriptionWriter, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.credit = Self.resolveField(metadata.credit, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.copyright = Self.resolveField(metadata.copyright, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.rightsUsageTerms = Self.resolveField(metadata.rightsUsageTerms, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.webStatementOfRights = Self.resolveField(metadata.webStatementOfRights, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.digitalImageGUID = Self.resolveField(metadata.digitalImageGUID, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.imageSupplierImageID = Self.resolveField(metadata.imageSupplierImageID, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.imageSuppliers = EditorialImageSupplier.normalizedValues(
            metadata.imageSuppliers.map { supplier in
                EditorialImageSupplier(
                    identifier: Self.resolveField(
                        supplier.identifier,
                        filename: filename,
                        ref: reference,
                        interpolator: interpolator,
                        sequenceIndex: sequenceIndex
                    ),
                    name: Self.resolveField(
                        supplier.name,
                        filename: filename,
                        ref: reference,
                        interpolator: interpolator,
                        sequenceIndex: sequenceIndex
                    )
                )
            }
        )
        resolved.jobId = Self.resolveField(metadata.jobId, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.dateCreated = Self.resolveField(metadata.dateCreated, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.city = Self.resolveField(metadata.city, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.sublocation = Self.resolveField(metadata.sublocation, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.provinceState = Self.resolveField(metadata.provinceState, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.country = Self.resolveField(metadata.country, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.countryCode = ISO3166Country.normalizedAlpha3(metadata.countryCode)
        resolved.event = Self.resolveField(metadata.event, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.instructions = Self.resolveField(metadata.instructions, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.source = Self.resolveField(metadata.source, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.organisationsShownNames = Self.resolveListField(metadata.organisationsShownNames, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.organisationsShownCodes = Self.resolveListField(metadata.organisationsShownCodes, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.sceneCodes = IPTCSceneCode.normalizedValues(
            Self.resolveListField(metadata.sceneCodes, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        )
        resolved.subjectCodes = IPTCSubjectCode.normalizedValues(
            Self.resolveListField(metadata.subjectCodes, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        )

        return resolved
    }

    private static func resolveField(_ value: String?, filename: String, ref: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int = 1) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex)
        return resolved.isEmpty ? nil : resolved
    }

    private static func resolveListField(_ values: [String], filename: String, ref: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int) -> [String] {
        values.flatMap { value in
            interpolator.resolve(
                value,
                filename: filename,
                existingMetadata: ref,
                sequenceIndex: sequenceIndex
            )
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        }.uniqued()
    }

    static func buildMetadataFields(from meta: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]

        if let v = meta.title, !v.isEmpty { fields[.headline] = v }
        if let v = meta.description, !v.isEmpty { fields[.description] = v }
        if let v = meta.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }
        if !meta.keywords.isEmpty { fields[.subject] = meta.keywords.joined(separator: ", ") }
        if !meta.personShown.isEmpty { fields[.personInImage] = meta.personShown.joined(separator: ", ") }
        if !meta.organisationsShownNames.isEmpty { fields[.organisationInImageName] = meta.organisationsShownNames.joined(separator: ", ") }
        if !meta.organisationsShownCodes.isEmpty { fields[.organisationInImageCode] = meta.organisationsShownCodes.joined(separator: ", ") }
        if !meta.sceneCodes.isEmpty { fields[.scene] = meta.sceneCodes.joined(separator: ", ") }
        if !meta.subjectCodes.isEmpty { fields[.subjectCode] = meta.subjectCodes.joined(separator: ", ") }
        if !meta.mediaTopics.isEmpty { fields[.mediaTopic] = meta.mediaTopics.map(\.termIdentifier).joined(separator: ", ") }
        if !meta.genres.isEmpty { fields[.genre] = meta.genres.map(\.termIdentifier).joined(separator: ", ") }
        if let v = meta.digitalSourceType { fields[.digitalSourceType] = v.newsCodeURI }
        if let v = meta.creatorTransportValue { fields[.creator] = v }
        if let v = meta.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
        if let v = meta.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
        if let v = meta.credit, !v.isEmpty { fields[.credit] = v }
        if let v = meta.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = meta.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
        if let v = meta.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
        if let v = meta.digitalImageGUID, !v.isEmpty { fields[.digitalImageGUID] = v }
        if let v = meta.imageSupplierImageID, !v.isEmpty { fields[.imageSupplierImageID] = v }
        if let v = EditorialImageSupplier.canonicalJSONString(for: meta.imageSuppliers) {
            fields[.imageSupplier] = v
        }
        if let v = meta.jobId, !v.isEmpty { fields[.transmissionReference] = v }
        if let v = meta.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
        if let v = meta.city, !v.isEmpty { fields[.city] = v }
        if let v = meta.sublocation, !v.isEmpty { fields[.sublocation] = v }
        if let v = meta.provinceState, !v.isEmpty { fields[.provinceState] = v }
        if let v = meta.country, !v.isEmpty { fields[.country] = v }
        if let v = meta.countryCode, !v.isEmpty { fields[.countryCode] = v }
        if let v = meta.event, !v.isEmpty { fields[.event] = v }
        if let v = meta.instructions, !v.isEmpty { fields[.instructions] = v }
        if let v = meta.source, !v.isEmpty { fields[.source] = v }

        return fields
    }

    // MARK: - Capture Date Scanning

    func scanCaptureDates() {
        let files = filteredSourceFiles
        dateScanTask?.cancel()
        let requestID = UUID()
        dateScanRequestID = requestID
        guard !files.isEmpty else {
            dateGroups = []
            isScanningDates = false
            return
        }

        isScanningDates = true

        dateScanTask = Task(priority: .userInitiated) { [weak self, captureDateScanService] in
            let result = await captureDateScanService.scan(files)
            guard let self, self.dateScanRequestID == requestID else { return }
            switch result {
            case .complete(let evidence):
                var currentGroups = evidence.groups.map { group in
                    ImportDateGroup(
                        dateString: group.dateString,
                        folderName: group.folderDate,
                        shootFolderName: nil,
                        isIncluded: true,
                        yearFolder: group.yearFolder,
                        monthFolder: group.monthFolder,
                        files: group.files,
                        captureTimes: group.captureTimes
                    )
                }
                for index in currentGroups.indices {
                    currentGroups[index].folderName = self.autoLeafName(
                        for: currentGroups[index],
                        title: self.configuration.importTitle
                    )
                }
                // A re-scan of the same card (second source added, filter changed) keeps the
                // user's choices for capture dates that still exist: an unchecked date stays
                // unchecked and a hand-renamed (unsplit) date folder keeps its name.
                let previousGroupsByDate = Dictionary(grouping: self.dateGroups, by: \.dateString)
                for index in currentGroups.indices {
                    guard let previous = previousGroupsByDate[currentGroups[index].dateString] else { continue }
                    currentGroups[index].isIncluded = previous.contains(where: \.isIncluded)
                    if previous.count == 1, let only = previous.first, only.shootFolderName == nil,
                       only.folderName != self.autoLeafName(for: only, title: self.configuration.importTitle) {
                        currentGroups[index].folderName = only.folderName
                    }
                }
                self.dateGroups = currentGroups
                self.ensureUniqueFolderNames()
                self.isScanningDates = false
                self.refreshPreviousImportFolderSuggestions()
            case .cancelled:
                self.isScanningDates = false
            }
        }
    }

    // MARK: - Thumbnail Sampling & Gap Detection

    /// Default minimum gap between consecutive shots that suggests a new shoot.
    static let defaultShootGapThreshold: TimeInterval = 2 * 3600

    /// Orders files by capture time, falling back to a stable filename comparison for
    /// files that share (or lack) a timestamp.
    static func chronologicalOrder(of files: [URL], captureTimes: [URL: Date]) -> [URL] {
        // With no timestamps at all, the caller's order (already filename-sorted in
        // practice) is the chronological order — skip the expensive locale-aware sort,
        // which matters for the flat whole-import preview over thousands of files.
        guard !captureTimes.isEmpty else { return files }
        return files.sorted { a, b in
            switch (captureTimes[a], captureTimes[b]) {
            case let (ta?, tb?):
                if ta != tb { return ta < tb }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }
    }

    /// Picks up to `max` files spread evenly across a chronological sequence, for a
    /// compact preview strip. Returns all files when there are `max` or fewer. Pure.
    static func representativeFiles(from files: [URL], captureTimes: [URL: Date], max n: Int = 8) -> [URL] {
        let ordered = chronologicalOrder(of: files, captureTimes: captureTimes)
        guard ordered.count > n else { return ordered }
        guard n > 1 else { return ordered.isEmpty ? [] : [ordered[0]] }
        var picked: [URL] = []
        var seen = Set<URL>()
        for i in 0..<n {
            let idx = Int((Double(i) * Double(ordered.count - 1) / Double(n - 1)).rounded())
            let url = ordered[idx]
            if seen.insert(url).inserted { picked.append(url) }
        }
        return picked
    }

    /// Convenience overload for a date group.
    static func representativeFiles(from group: ImportDateGroup, max n: Int = 8) -> [URL] {
        representativeFiles(from: group.files, captureTimes: group.captureTimes, max: n)
    }

    /// Indices into `group.chronologicalFiles` where the gap to the previous shot
    /// exceeds `gapThreshold` — i.e. suggested start-of-new-shoot boundaries.
    /// Files lacking a timestamp never trigger a boundary.
    static func suggestedSplitBoundaries(
        for group: ImportDateGroup,
        gapThreshold: TimeInterval = ImportViewModel.defaultShootGapThreshold
    ) -> [Int] {
        let ordered = group.chronologicalFiles
        guard ordered.count > 1 else { return [] }
        var boundaries: [Int] = []
        for i in 1..<ordered.count {
            guard let prev = group.captureTimes[ordered[i - 1]],
                  let cur = group.captureTimes[ordered[i]] else { continue }
            if cur.timeIntervalSince(prev) > gapThreshold {
                boundaries.append(i)
            }
        }
        return boundaries
    }

    // MARK: - Folder Name Preview & Title

    /// "yyyy-MM-dd" display form derived from a group's "yyyy:MM:dd" capture-date key.
    func displayDate(for group: ImportDateGroup) -> String {
        if let parsed = Self.captureDateKeyFormatter.date(from: group.dateString) {
            return Self.folderDateFormatter.string(from: parsed)
        }
        return group.dateString
    }

    /// Shared formatters: `displayDate(for:)` runs for every file when an import is planned and
    /// for every group on each render, so building formatters per call scaled with card size.
    private static let captureDateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The auto-generated leaf folder name for a group given an import title.
    private func autoLeafName(for group: ImportDateGroup, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? displayDate(for: group) : "\(displayDate(for: group)) \u{2013} \(trimmed)"
    }

    /// Re-applies a changed import title to every group whose folder name still matches
    /// the auto-generated pattern, so the title stays in sync without a re-scan. This
    /// includes split sub-shoots, whose names are the auto base plus a " – Shoot N"
    /// suffix — the suffix is preserved. Groups the user renamed by hand no longer match
    /// the pattern and are left untouched.
    func updateGroupFolderTitles(from oldTitle: String, to newTitle: String) {
        guard !dateGroups.isEmpty else { return }
        for i in dateGroups.indices {
            let oldBase = autoLeafName(for: dateGroups[i], title: oldTitle)
            let newBase = autoLeafName(for: dateGroups[i], title: newTitle)
            let current = dateGroups[i].folderName
            if current == oldBase {
                dateGroups[i].folderName = newBase
            } else {
                // Split sub-shoot: "<auto base> – Shoot N". Swap the base, keep the rest.
                let shootPrefix = oldBase + " \u{2013} Shoot "
                if current.hasPrefix(shootPrefix) {
                    dateGroups[i].folderName = newBase + String(current.dropFirst(oldBase.count))
                }
            }
        }
        ensureUniqueFolderNames()
    }

    /// Full destination path preview for a group, e.g. "Photos / 2026 / 2026-05-12 – Vacation".
    func folderPathPreview(for group: ImportDateGroup) -> String {
        var parts = [configuration.destinationBaseURL.lastPathComponent]
        parts.append(contentsOf: folderGroupingComponents(for: group, grouping: dateFolderGrouping))
        parts.append(group.folderName)
        if let shoot = group.shootFolderName?.trimmingCharacters(in: .whitespaces), !shoot.isEmpty {
            parts.append(shoot)
        }
        return parts.joined(separator: " / ")
    }

    func folderPathGroupingPrefix(for group: ImportDateGroup) -> String {
        folderGroupingComponents(for: group, grouping: dateFolderGrouping).joined(separator: "/")
    }

    private func destinationFolderURL(for group: ImportDateGroup) -> URL {
        var url = Self.appendingPathComponents(
            folderGroupingComponents(for: group, grouping: dateFolderGrouping),
            to: configuration.destinationBaseURL
        )
        url = url.appendingPathComponent(group.folderName)
        if let shoot = group.shootFolderName?.trimmingCharacters(in: .whitespaces), !shoot.isEmpty {
            url = url.appendingPathComponent(shoot)
        }
        return url
    }

    private func folderGroupingComponents(for group: ImportDateGroup, grouping: ImportDateFolderGrouping) -> [String] {
        switch grouping {
        case .none:
            return []
        case .year:
            return group.yearFolder.map { [$0] } ?? []
        case .month:
            guard let year = group.yearFolder, let month = group.monthFolder else { return [] }
            return [year, month]
        }
    }

    nonisolated private static func appendingPathComponents(_ components: [String], to baseURL: URL) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    // MARK: - Shoot Splitting

    /// Splits one date group into contiguous segments at the given boundary indices
    /// (indices into the group's `chronologicalFiles`). The first segment keeps the
    /// original folder name; later segments get a " – Shoot N" suffix (user-editable
    /// afterward). No-op when there are fewer than two resulting segments.
    func splitGroup(_ groupID: UUID, boundaries: [Int]) {
        guard let gIdx = dateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = dateGroups[gIdx]
        let ordered = group.chronologicalFiles

        // Sanitize + sort boundaries; drop out-of-range and duplicates.
        let bounds = Set(boundaries.filter { $0 > 0 && $0 < ordered.count }).sorted()
        guard !bounds.isEmpty else { return }

        // Build contiguous segment ranges: [0, b0), [b0, b1), … [bn, count).
        var starts = [0]
        starts.append(contentsOf: bounds)
        var newGroups: [ImportDateGroup] = []
        for (segIndex, start) in starts.enumerated() {
            let end = segIndex + 1 < starts.count ? starts[segIndex + 1] : ordered.count
            let segFiles = Array(ordered[start..<end])
            guard !segFiles.isEmpty else { continue }
            var segTimes: [URL: Date] = [:]
            for f in segFiles { if let t = group.captureTimes[f] { segTimes[f] = t } }
            // Every segment — including the first — gets a "Shoot N" suffix so the
            // resulting folders are named consistently (Shoot 1, Shoot 2, …).
            let segmentNumber = newGroups.count + 1
            let shootName = "Shoot \(segmentNumber)"
            let name = splitShootsIntoSubfolders
                ? baseDateFolderName(for: group)
                : "\(group.folderName) \u{2013} \(shootName)"
            newGroups.append(ImportDateGroup(
                dateString: group.dateString,
                folderName: name,
                shootFolderName: splitShootsIntoSubfolders ? shootName : nil,
                isIncluded: group.isIncluded,
                yearFolder: group.yearFolder,
                monthFolder: group.monthFolder,
                files: segFiles,
                captureTimes: segTimes
            ))
        }

        guard newGroups.count > 1 else { return }
        dateGroups.replaceSubrange(gIdx...gIdx, with: newGroups)
        ensureUniqueFolderNames()
    }

    /// Moves an arbitrary (possibly non-contiguous) selection of files out of a group
    /// into a new sub-shoot inserted right after it. The source group keeps the rest.
    func splitOff(_ groupID: UUID, fileURLs: Set<URL>, newSuffix: String? = nil) {
        guard let gIdx = dateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var source = dateGroups[gIdx]
        let moved = source.files.filter { fileURLs.contains($0) }
        guard !moved.isEmpty, moved.count < source.files.count else { return }

        var movedTimes: [URL: Date] = [:]
        for f in moved { if let t = source.captureTimes[f] { movedTimes[f] = t } }

        source.files.removeAll { fileURLs.contains($0) }
        for f in moved { source.captureTimes.removeValue(forKey: f) }
        if splitShootsIntoSubfolders, source.shootFolderName == nil {
            source.folderName = baseDateFolderName(for: source)
            source.shootFolderName = "Shoot 1"
        }

        let suffix = (newSuffix?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let shootName = suffix ?? "Shoot 2"
        let baseName = splitShootsIntoSubfolders
            ? baseDateFolderName(for: source)
            : "\(source.folderName) \u{2013} \(shootName)"
        let newGroup = ImportDateGroup(
            dateString: source.dateString,
            folderName: baseName,
            shootFolderName: splitShootsIntoSubfolders ? shootName : nil,
            isIncluded: source.isIncluded,
            yearFolder: source.yearFolder,
            monthFolder: source.monthFolder,
            files: moved,
            captureTimes: movedTimes
        )

        dateGroups[gIdx] = source
        dateGroups.insert(newGroup, at: gIdx + 1)
        ensureUniqueFolderNames()
    }

    /// Merges the given groups (which should share a `dateString`) back into the
    /// chronologically-earliest one, resetting its folder name to a clean base.
    func mergeGroups(_ groupIDs: [UUID]) {
        let idSet = Set(groupIDs)
        let indices = dateGroups.indices.filter { idSet.contains(dateGroups[$0].id) }
        guard indices.count > 1 else { return }

        // Earliest by first capture time, falling back to current order.
        let targetIdx = indices.min { lhs, rhs in
            let l = dateGroups[lhs].captureTimes.values.min()
            let r = dateGroups[rhs].captureTimes.values.min()
            switch (l, r) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs < rhs
            }
        } ?? indices[0]

        var merged = dateGroups[targetIdx]
        for idx in indices where idx != targetIdx {
            let other = dateGroups[idx]
            merged.files.append(contentsOf: other.files)
            for (url, t) in other.captureTimes { merged.captureTimes[url] = t }
        }

        // Reset folder name to a clean date-derived base (drop " – Shoot N").
        if let parsed = Self.captureDateKeyFormatter.date(from: merged.dateString) {
            let title = configuration.importTitle.trimmingCharacters(in: .whitespaces)
            let display = Self.folderDateFormatter.string(from: parsed)
            merged.folderName = title.isEmpty
                ? display
                : "\(display) \u{2013} \(title)"
        }
        merged.shootFolderName = nil

        // Remove merged-away groups (highest index first) and write back the target.
        dateGroups[targetIdx] = merged
        for idx in indices.sorted(by: >) where idx != targetIdx {
            dateGroups.remove(at: idx)
        }
        ensureUniqueFolderNames()
    }

    /// Whether other groups share this group's capture date (i.e. it has been split
    /// into multiple shoots that could be merged back).
    func hasSiblingGroups(_ group: ImportDateGroup) -> Bool {
        dateGroups.contains { $0.id != group.id && $0.dateString == group.dateString }
    }

    /// Merges all groups sharing this group's capture date back into one.
    func mergeSiblings(of group: ImportDateGroup) {
        let ids = dateGroups.filter { $0.dateString == group.dateString }.map(\.id)
        mergeGroups(ids)
    }

    /// Guarantees every group has a distinct `folderName` by auto-suffixing collisions
    /// with " (2)", " (3)", … This protects the import copy step, which maps each file
    /// to its destination by folder name. Call after any split/merge or name edit.
    func ensureUniqueFolderNames() {
        // Folder names become on-disk directories under a volume that is
        // case-insensitive by default (APFS and HFS+), so uniqueness must be
        // enforced case-insensitively. A case-sensitive check would let "Beach"
        // and "beach" both pass, then `appendingPathComponent` would resolve them
        // to the *same* physical folder — silently merging two groups' files (and
        // overwriting same-named files under the .overwrite conflict policy).
        // First occurrence keeps its original casing; later collisions get suffixed.
        var used = Set<String>()
        for i in dateGroups.indices {
            var name = dateGroups[i].folderName
            if name.isEmpty { name = dateGroups[i].dateString }
            let shoot = dateGroups[i].shootFolderName?.trimmingCharacters(in: .whitespaces)
            var candidate = name
            var counter = 2
            var uniqueKey = folderUniquenessKey(for: dateGroups[i], folderName: candidate, shootFolderName: shoot)
            while !used.insert(uniqueKey).inserted {
                candidate = "\(name) (\(counter))"
                counter += 1
                uniqueKey = folderUniquenessKey(for: dateGroups[i], folderName: candidate, shootFolderName: shoot)
            }
            if candidate != dateGroups[i].folderName {
                dateGroups[i].folderName = candidate
            }
        }
    }

    private func folderUniquenessKey(for group: ImportDateGroup, folderName: String, shootFolderName: String?) -> String {
        var parts = folderGroupingComponents(for: group, grouping: dateFolderGrouping).map { $0.lowercased() }
        parts.append(folderName.lowercased())
        if let shootFolderName, !shootFolderName.isEmpty { parts.append(shootFolderName.lowercased()) }
        return parts.joined(separator: "/")
    }

    private func baseDateFolderName(for group: ImportDateGroup) -> String {
        let base = autoLeafName(for: group, title: configuration.importTitle)
        if group.folderName == base {
            return base
        }
        if let range = group.folderName.range(of: " \u{2013} Shoot ", options: [.backwards]) {
            return String(group.folderName[..<range.lowerBound])
        }
        return group.folderName
    }

    private func normalizeSplitFolderLayout() {
        guard sortByDate, !dateGroups.isEmpty else { return }
        var normalizedGroups = dateGroups
        var dateCounters: [String: Int] = [:]
        for i in normalizedGroups.indices {
            let siblings = normalizedGroups.filter { $0.dateString == normalizedGroups[i].dateString }
            guard siblings.count > 1 || normalizedGroups[i].shootFolderName != nil else { continue }

            dateCounters[normalizedGroups[i].dateString, default: 0] += 1
            let shootName = normalizedGroups[i].shootFolderName ?? "Shoot \(dateCounters[normalizedGroups[i].dateString] ?? 1)"
            if splitShootsIntoSubfolders {
                normalizedGroups[i].folderName = baseDateFolderName(for: normalizedGroups[i])
                normalizedGroups[i].shootFolderName = shootName
            } else {
                let baseName = baseDateFolderName(for: normalizedGroups[i])
                normalizedGroups[i].folderName = "\(baseName) \u{2013} \(shootName)"
                normalizedGroups[i].shootFolderName = nil
            }
        }
        dateGroups = normalizedGroups
        ensureUniqueFolderNames()
    }

    // MARK: - Reset

    /// Prepares the view model for a freshly-opened import sheet. Resets to a clean
    /// form unless a copy is currently in progress — in that case the sheet should
    /// show the running import's progress rather than wipe it.
    func prepareForNewSession() {
        switch importPhase {
        case .copying, .applyingMetadata:
            return
        default:
            reset()
        }
    }

    func reset() {
        let preservedFileTypeFilter = configuration.fileTypeFilter
        let preservedConflictPolicy = configuration.conflictPolicy
        let preservedCreateSubFolders = configuration.createSubFolders
        let preservedVerificationMode = configuration.verificationMode
        let preservedBackup = configuration.backupDestination
        let preservedSkipPreviouslyImported = configuration.skipPreviouslyImported
        let preservedDestinationBaseURL = configuration.destinationBaseURL
        let preservedSortByDate = sortByDate
        configuration = ImportConfiguration()
        // Preserve the user's import-mode choices and destinations across sessions. The
        // destination root is restored from its bookmark only at launch, so a fresh
        // configuration would otherwise fall back to ~/Photos every time the sheet opens.
        configuration.destinationBaseURL = preservedDestinationBaseURL
        configuration.fileTypeFilter = preservedFileTypeFilter
        configuration.conflictPolicy = preservedConflictPolicy
        configuration.createSubFolders = preservedCreateSubFolders
        configuration.verificationMode = preservedVerificationMode
        configuration.backupDestination = preservedBackup
        configuration.skipPreviouslyImported = preservedSkipPreviouslyImported
        sourceFiles = []
        sourceVoiceMemoFiles = []
        voiceMemoSourceFiles = []
        voiceMemoAssociationReport = nil
        canonicalVoiceMemoImageURLBySource = [:]
        sourceScanProgress = ImportSourceDiscoveryProgress()
        voiceMemoSourceScanProgress = ImportSourceDiscoveryProgress()
        isDiscoveringVoiceMemoSource = false
        isScanningVoiceMemoSource = false
        importPhase = .idle
        copiedFiles = 0
        voiceMemoCopiedFiles = 0
        totalFiles = 0
        skippedFiles = 0
        renamedFiles = 0
        replacedFiles = 0
        backupReplacedFiles = 0
        failedFiles = 0
        verifiedFiles = 0
        mismatchedFiles = 0
        backupCopiedFiles = 0
        backupFailedFiles = 0
        metadataFailedFiles = 0
        metadataProcessedFiles = 0
        metadataTotalFiles = 0
        duplicateSkippedFiles = 0
        currentFile = ""
        importSummary = ""
        errorMessage = nil
        failureRecords = []
        metadataFailureDetailBySource = [:]
        plannedRenamedSources = []
        importDidStartCopying = false
        ignoredPrimarySourceFiles = []
        ignoredSecondSourceFiles = []
        refreshIgnoredSourceFiles()
        overwritePreflight = nil
        confirmedOverwriteSignature = nil
        dateGroups = []
        sortByDate = preservedSortByDate
        isScanningDates = false
        scanTask?.cancel()
        dateScanTask?.cancel()
        dateScanRequestID = UUID()
        voiceMemoScanTask?.cancel()
        voiceMemoAssociationTask?.cancel()
        voiceMemoAssociationRequestID = UUID()
        folderSuggestionTask?.cancel()
        importRequestID = UUID()
        importTask?.cancel()
        refreshPreviousImportFolderSuggestions()
    }

    // MARK: - Backup Destination

    func selectBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder for the additional import copy"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        scheduleBackupBookmarkCreation(for: url)
    }

    func setBackupDestinationURL(_ url: URL) async {
        scheduleBackupBookmarkCreation(for: url)
        await backupBookmarkTask?.value
    }

    func clearBackupDestination() {
        backupBookmarkTask?.cancel()
        backupBookmarkTask = nil
        backupBookmarkRequestID = nil
        configuration.backupDestination = nil
        bookmarkDefaults.removeObject(forKey: UserDefaultsKeys.importBackupBookmark)
    }

    func waitForDestinationBookmarkRestoration() async {
        await destinationBookmarkTask?.value
        await backupBookmarkTask?.value
    }

    private func scheduleDestinationBookmarkLoad() {
        guard let bookmarkData = bookmarkDefaults.data(
            forKey: UserDefaultsKeys.importDestinationBookmark
        ) else { return }
        destinationBookmarkTask?.cancel()
        let requestID = UUID()
        destinationBookmarkRequestID = requestID
        let service = destinationBookmarkService
        let defaults = bookmarkDefaults
        let task = Task { @MainActor [weak self] in
            let result = await service.resolve(bookmarkData, requestID: requestID)
            guard let self, self.destinationBookmarkRequestID == requestID else { return }
            self.destinationBookmarkTask = nil
            self.destinationBookmarkRequestID = nil
            switch result {
            case .loaded(let snapshot) where snapshot.requestID == requestID:
                self.configuration.destinationBaseURL = snapshot.url
                if let refreshedBookmarkData = snapshot.refreshedBookmarkData {
                    defaults.set(refreshedBookmarkData, forKey: UserDefaultsKeys.importDestinationBookmark)
                }
                self.refreshPreviousImportFolderSuggestions()
            case .failed(let failedRequestID) where failedRequestID == requestID:
                defaults.removeObject(forKey: UserDefaultsKeys.importDestinationBookmark)
            default:
                break
            }
        }
        destinationBookmarkTask = task
    }

    private func scheduleBackupBookmarkLoad() {
        guard let bookmarkData = bookmarkDefaults.data(
            forKey: UserDefaultsKeys.importBackupBookmark
        ) else { return }
        backupBookmarkTask?.cancel()
        let requestID = UUID()
        backupBookmarkRequestID = requestID
        let verifyAfterWrite = bookmarkDefaults.object(
            forKey: UserDefaultsKeys.importBackupVerifyAfterWrite
        ) as? Bool ?? true
        let service = destinationBookmarkService
        let defaults = bookmarkDefaults
        let task = Task { @MainActor [weak self] in
            let result = await service.resolve(bookmarkData, requestID: requestID)
            guard let self, self.backupBookmarkRequestID == requestID else { return }
            self.backupBookmarkTask = nil
            self.backupBookmarkRequestID = nil
            switch result {
            case .loaded(let snapshot) where snapshot.requestID == requestID:
                self.configuration.backupDestination = BackupDestination(
                    url: snapshot.url,
                    verifyAfterWrite: verifyAfterWrite
                )
                if let refreshedBookmarkData = snapshot.refreshedBookmarkData {
                    defaults.set(refreshedBookmarkData, forKey: UserDefaultsKeys.importBackupBookmark)
                }
            case .failed(let failedRequestID) where failedRequestID == requestID:
                defaults.removeObject(forKey: UserDefaultsKeys.importBackupBookmark)
            default:
                break
            }
        }
        backupBookmarkTask = task
    }

    private func scheduleDestinationBookmarkCreation(for url: URL) {
        destinationBookmarkTask?.cancel()
        let requestID = UUID()
        destinationBookmarkRequestID = requestID
        configuration.destinationBaseURL = url
        refreshPreviousImportFolderSuggestions()
        let service = destinationBookmarkService
        let defaults = bookmarkDefaults
        let task = Task { @MainActor [weak self] in
            let result = await service.createBookmark(for: url, requestID: requestID)
            guard let self, self.destinationBookmarkRequestID == requestID else { return }
            self.destinationBookmarkTask = nil
            self.destinationBookmarkRequestID = nil
            guard case .completed(let commit) = result,
                  commit.requestID == requestID else { return }
            if let bookmarkData = commit.bookmarkData {
                defaults.set(bookmarkData, forKey: UserDefaultsKeys.importDestinationBookmark)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.importDestinationBookmark)
            }
        }
        destinationBookmarkTask = task
    }

    private func scheduleBackupBookmarkCreation(for url: URL) {
        backupBookmarkTask?.cancel()
        let requestID = UUID()
        backupBookmarkRequestID = requestID
        let verifyAfterWrite = configuration.backupDestination?.verifyAfterWrite
            ?? (bookmarkDefaults.object(forKey: UserDefaultsKeys.importBackupVerifyAfterWrite) as? Bool)
            ?? true
        configuration.backupDestination = BackupDestination(
            url: url,
            verifyAfterWrite: verifyAfterWrite
        )
        let service = destinationBookmarkService
        let defaults = bookmarkDefaults
        let task = Task { @MainActor [weak self] in
            let result = await service.createBookmark(for: url, requestID: requestID)
            guard let self, self.backupBookmarkRequestID == requestID else { return }
            self.backupBookmarkTask = nil
            self.backupBookmarkRequestID = nil
            guard case .completed(let commit) = result,
                  commit.requestID == requestID else { return }
            if let bookmarkData = commit.bookmarkData {
                defaults.set(bookmarkData, forKey: UserDefaultsKeys.importBackupBookmark)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.importBackupBookmark)
            }
        }
        backupBookmarkTask = task
    }
}
