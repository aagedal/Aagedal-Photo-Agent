import Foundation
import Observation
import os

nonisolated enum DevelopVersionNameAction: Identifiable, Equatable, Sendable {
    case create
    case rename(UUID)
    case duplicate(UUID)

    var id: String {
        switch self {
        case .create: "create"
        case let .rename(id): "rename-\(id.uuidString)"
        case let .duplicate(id): "duplicate-\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create: "New Version from Current"
        case .rename: "Rename Version"
        case .duplicate: "Duplicate Version"
        }
    }

    var actionLabel: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        case .duplicate: "Duplicate"
        }
    }
}

/// Owns the short-lived alerts and confirmation intents for named Develop versions.
/// Image replacement and workspace teardown clear the complete modal session together, so a
/// confirmation captured for one image cannot be applied after navigation to another image.
@MainActor
@Observable
final class DevelopVersionDialogsCoordinator {
    var nameAction: DevelopVersionNameAction?
    var nameDraft = ""
    var pendingDeleteID: UUID?
    var pendingPromotionID: UUID?

    var isNameActionPresented: Bool {
        get { nameAction != nil }
        set { if !newValue { cancelNameAction() } }
    }

    var isDeletePresented: Bool {
        get { pendingDeleteID != nil }
        set { if !newValue { pendingDeleteID = nil } }
    }

    var isPromotionPresented: Bool {
        get { pendingPromotionID != nil }
        set { if !newValue { pendingPromotionID = nil } }
    }

    func beginNameAction(_ action: DevelopVersionNameAction, catalog: DevelopVersionCatalog?) {
        nameAction = action
        switch action {
        case .create:
            nameDraft = "Version \((catalog?.versions.count ?? 0) + 1)"
        case let .rename(id):
            nameDraft = catalog?.versions.first(where: { $0.id == id })?.name ?? ""
        case let .duplicate(id):
            let sourceName = catalog?.versions.first(where: { $0.id == id })?.name ?? "Version"
            nameDraft = "\(sourceName) Copy"
        }
    }

    func consumeNameAction() -> (DevelopVersionNameAction, String)? {
        guard let nameAction else { return nil }
        let result = (nameAction, nameDraft)
        cancelNameAction()
        return result
    }

    func requestDelete(_ id: UUID) {
        pendingDeleteID = id
    }

    func consumeDelete() -> UUID? {
        defer { pendingDeleteID = nil }
        return pendingDeleteID
    }

    func requestPromotion(_ id: UUID) {
        pendingPromotionID = id
    }

    func consumePromotion() -> UUID? {
        defer { pendingPromotionID = nil }
        return pendingPromotionID
    }

    func cancelNameAction() {
        nameAction = nil
        nameDraft = ""
    }

    func reset() {
        cancelNameAction()
        pendingDeleteID = nil
        pendingPromotionID = nil
    }
}

nonisolated enum DevelopVersionPersistenceState: Equatable {
    case unavailable
    case loading
    case clean
    case dirty
    case saving
    case saved
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .loading: "Loading…"
        case .clean: "Ready"
        case .dirty: "Unsaved"
        case .saving: "Saving…"
        case .saved: "Saved"
        case .failed: "Save Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .unavailable: "nosign"
        case .loading, .saving: "arrow.triangle.2.circlepath"
        case .clean, .saved: "checkmark.circle.fill"
        case .dirty: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// Persistence boundary used by a Develop-version editing session. The production repository is
/// an actor; tests can supply a deterministic in-memory implementation without touching disk.
nonisolated protocol DevelopVersionCatalogPersisting: Sendable {
    func loadMostRelevantCatalog(
        for revision: SourceImageRevision
    ) async -> DevelopVersionCatalogMatch

    func save(
        _ catalog: DevelopVersionCatalog
    ) async throws -> DevelopVersionCatalogStorage

    /// Removes the catalog stored under `sha256` when it belongs to `sourceURL`: used only for a
    /// hash superseded by this app's own metadata-only rewrite of that source.
    func removeSupersededCatalog(forSHA256 sha256: String, sourceURL: URL) async
}

extension DevelopVersionCatalogPersisting {
    func removeSupersededCatalog(forSHA256 sha256: String, sourceURL: URL) async {}
}

extension DevelopVersionCatalogRepository: DevelopVersionCatalogPersisting {}

/// Owns the named-version state for one Develop workspace image.
///
/// `beginLoading` defines the session boundary. Starting another session or calling `reset`
/// cancels load, debounced save, and UI-transition work. Every asynchronous result is also gated
/// by a session token and source hash so a dependency that ignores cancellation cannot install
/// stale state. Persisted editor settings stay in the view because applying them also resets crop,
/// layer, preview, and clean-feed UI; the coordinator reports that effect through explicit
/// callbacks only after the catalog write succeeds.
@MainActor
@Observable
final class DevelopVersionSessionCoordinator {
    typealias RevisionCapture = @Sendable (URL, Int) async throws -> SourceImageRevision
    typealias RepositoryFactory = @Sendable (URL) -> any DevelopVersionCatalogPersisting

    struct SettingsInstallation: Equatable {
        let settings: CameraRawSettings?
    }

    var catalog: DevelopVersionCatalog?
    var revision: SourceImageRevision?
    var storage: DevelopVersionCatalogStorage?
    var persistenceState: DevelopVersionPersistenceState = .unavailable
    var notice: String?
    var primarySettings: CameraRawSettings?
    var hasInstalledLoadedVersion = false

    @ObservationIgnored private(set) var repository: (any DevelopVersionCatalogPersisting)?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private let revisionCapture: RevisionCapture
    @ObservationIgnored private let repositoryFactory: RepositoryFactory
    @ObservationIgnored private let saveDelay: Duration
    /// Source hashes replaced by this app's own metadata-only rewrites (a RAW+JPEG pair's JPEG
    /// Develop saves) during this session. A catalog still bound to one of them is rebound to the
    /// current revision when saved, and its old file is removed instead of left as an orphan.
    @ObservationIgnored private var supersededSHAs: Set<String> = []

    private let log = Logger(
        subsystem: "com.aagedal.photo-agent",
        category: "DevelopVersionSession"
    )

    init(
        saveDelay: Duration = .milliseconds(650),
        revisionCapture: @escaping RevisionCapture = { url, orientation in
            try await SourceImageRevision.capture(at: url, exifOrientation: orientation)
        },
        repositoryFactory: @escaping RepositoryFactory = { sourceFolderURL in
            DevelopVersionCatalogRepository(sourceFolderURL: sourceFolderURL)
        }
    ) {
        self.saveDelay = saveDelay
        self.revisionCapture = revisionCapture
        self.repositoryFactory = repositoryFactory
    }

    var activeVersion: DevelopNamedVersion? {
        guard let activeID = catalog?.activeVersionID else { return nil }
        return catalog?.versions.first(where: { $0.id == activeID })
    }

    var isTransitioning: Bool {
        persistenceState == .saving || transitionTask != nil
    }

    var hasTransition: Bool {
        transitionTask != nil
    }

    func beginLoading(
        imageURL: URL,
        orientation: Int,
        onCatalogReady: @escaping @MainActor () -> Void
    ) {
        reset()
        let newSessionID = sessionID
        sourceURL = imageURL
        let repository = repositoryFactory(imageURL.deletingLastPathComponent())
        self.repository = repository
        persistenceState = .loading

        loadTask = Task { [weak self] in
            do {
                let revision = try await self?.revisionCapture(imageURL, orientation)
                guard let self, let revision, !Task.isCancelled,
                      sessionID == newSessionID, sourceURL == imageURL else { return }

                let match = await repository.loadMostRelevantCatalog(for: revision)
                guard !Task.isCancelled, sessionID == newSessionID,
                      sourceURL == imageURL else { return }

                self.revision = revision
                switch match {
                case let .exact(catalog, _, storage):
                    self.catalog = catalog
                    self.storage = storage
                    persistenceState = .clean
                    onCatalogReady()
                case .none:
                    catalog = DevelopVersionCatalog.create(for: revision)
                    persistenceState = .clean
                    onCatalogReady()
                case .sourceChanged:
                    catalog = nil
                    persistenceState = .unavailable
                    notice = "This photo has changed since its named versions were saved, so they can't be used with it. The versions are kept unchanged."
                case let .newerSchema(schemaVersion, _, _, _):
                    catalog = nil
                    persistenceState = .unavailable
                    notice = "This photo's named versions were saved by a newer version of Photo Agent (format \(schemaVersion)). You can view them, but update Photo Agent to change them."
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, sessionID == newSessionID, sourceURL == imageURL else { return }
                catalog = nil
                persistenceState = .unavailable
                notice = error.localizedDescription
            }
        }
    }

    /// Captures Primary once the metadata loader is ready, and returns the persisted named
    /// settings that the view should install. Nil means either not ready or Primary is active.
    func loadedSettingsToInstallIfReady(
        metadataIsLoading: Bool,
        selectedCount: Int,
        metadataSelectedURL: URL?,
        currentPrimarySettings: CameraRawSettings?
    ) -> SettingsInstallation? {
        guard !hasInstalledLoadedVersion,
              !metadataIsLoading,
              selectedCount == 1,
              metadataSelectedURL == sourceURL,
              let catalog else { return nil }

        primarySettings = currentPrimarySettings
        hasInstalledLoadedVersion = true
        guard let activeID = catalog.activeVersionID,
              let activeVersion = catalog.versions.first(where: { $0.id == activeID }) else {
            return nil
        }
        persistenceState = .saved
        return SettingsInstallation(settings: activeVersion.snapshot.settings)
    }

    func persist(
        _ candidate: DevelopVersionCatalog,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard let repository else { return }
        let sourceHash = candidate.source.sha256
        let expectedSessionID = sessionID
        saveTask?.cancel()
        persistenceState = .saving
        notice = nil
        saveTask = Task { [weak self] in
            do {
                guard let self,
                      let (saved, storage) = try await saveFollowingRewrites(candidate, repository: repository,
                        sessionID: expectedSessionID),
                      !Task.isCancelled else { return }
                catalog = saved
                self.storage = storage
                persistenceState = .saved
                onSuccess()
            } catch is CancellationError {
                return
            } catch {
                guard let self, sessionID == expectedSessionID,
                      revision?.sha256 == sourceHash || supersededSHAs.contains(sourceHash) else { return }
                persistenceState = .failed(error.localizedDescription)
                notice = error.localizedDescription
            }
        }
    }

    @discardableResult
    func scheduleActiveSave(
        settings: CameraRawSettings,
        watermarkDataProvider: (UUID) -> Data?,
        onSaved: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let activeID = catalog?.activeVersionID,
              let repository,
              var candidate = catalog else { return false }
        do {
            try candidate.updateVersion(
                id: activeID,
                settings: settings,
                watermarkDataProvider: watermarkDataProvider
            )
        } catch {
            persistenceState = .failed(error.localizedDescription)
            notice = error.localizedDescription
            return false
        }

        catalog = candidate
        persistenceState = .dirty
        let expectedSessionID = sessionID
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: saveDelay)
                try Task.checkCancellation()
                guard let (saved, storage) = try await saveFollowingRewrites(candidate, repository: repository,
                        sessionID: expectedSessionID),
                      !Task.isCancelled else { return }
                catalog = saved
                self.storage = storage
                persistenceState = .saved
                onSaved()
            } catch is CancellationError {
                return
            } catch {
                guard let self, sessionID == expectedSessionID,
                      revision?.sha256 == candidate.source.sha256
                        || supersededSHAs.contains(candidate.source.sha256) else { return }
                persistenceState = .failed(error.localizedDescription)
                notice = error.localizedDescription
            }
        }
        return true
    }

    func flushActive(
        reason: DevelopVersionFlushReason,
        settings: CameraRawSettings,
        watermarkDataProvider: (UUID) -> Data?,
        onSaved: @escaping @MainActor () -> Void
    ) async -> DevelopVersionFlushOutcome {
        saveTask?.cancel()
        saveTask = nil
        guard let activeID = catalog?.activeVersionID,
              let repository,
              var candidate = catalog else { return .succeeded }
        do {
            try candidate.updateVersion(
                id: activeID,
                settings: settings,
                watermarkDataProvider: watermarkDataProvider
            )
        } catch {
            persistenceState = .failed(error.localizedDescription)
            notice = error.localizedDescription
            return .failed(error.localizedDescription)
        }

        let expectedSessionID = sessionID
        persistenceState = .saving
        notice = nil
        do {
            guard let (saved, storage) = try await saveFollowingRewrites(candidate, repository: repository,
                    sessionID: expectedSessionID) else {
                let message = "The source changed before the named version could be saved."
                persistenceState = .failed(message)
                notice = message
                return .failed(message)
            }
            catalog = saved
            self.storage = storage
            persistenceState = .saved
            onSaved()
            return .succeeded
        } catch {
            let message = error.localizedDescription
            persistenceState = .failed(message)
            notice = message
            log.error(
                "Failed to flush named Develop version for \(String(describing: reason), privacy: .public): \(message, privacy: .private)"
            )
            return .failed(message)
        }
    }

    @discardableResult
    func startTransition(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard transitionTask == nil else { return false }
        let expectedSessionID = sessionID
        transitionTask = Task { [weak self] in
            await operation()
            guard let self, sessionID == expectedSessionID else { return }
            transitionTask = nil
        }
        return true
    }

    /// Waits for the current save chain (including a rebinding follow-up chained onto it).
    func waitForPendingSave() async {
        while let task = saveTask {
            await task.value
            if saveTask == task { break }
        }
    }

    func cancelSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    /// A Primary Develop save of a RAW+JPEG pair's JPEG rewrites only the file's embedded XMP
    /// (atomic, metadata-only): its pixels and geometry are unchanged but its sha256 is not, and
    /// catalogs are keyed by that hash. Rebind the session to the new revision in one main-actor
    /// step (no await between reading and replacing the catalog), so a version switch or save
    /// issued around it is never overwritten or dropped: every save path rebinds a catalog still
    /// bound to a superseded hash before writing (`saveFollowingRewrites`). A persisted catalog
    /// is saved under the new hash, chained after any in-flight save, and the superseded file is
    /// removed so sequential commits leave exactly one catalog.
    func followMetadataOnlyRewrite(of imageURL: URL) async {
        guard sourceURL == imageURL, let previous = revision else { return }
        let session = sessionID
        let current: SourceImageRevision
        do {
            current = try await revisionCapture(imageURL, previous.exifOrientation ?? 1)
        } catch {
            return
        }
        guard sessionID == session, sourceURL == imageURL, let bound = revision,
              bound.sha256 != current.sha256,
              current.pixelWidth == bound.pixelWidth, current.pixelHeight == bound.pixelHeight else { return }
        supersededSHAs.insert(bound.sha256)
        revision = current
        guard let latest = catalog else { return }
        do {
            catalog = try latest.reassociated(to: current)
        } catch {
            notice = "Named versions could not follow this photo's saved Develop settings: \(error.localizedDescription)"
            return
        }
        guard storage != nil, let repository else { return }
        let prior = saveTask
        saveTask = Task { [weak self] in
            await prior?.value
            guard let self, !Task.isCancelled, sessionID == session, let latest = catalog else { return }
            do {
                guard let (_, storage) = try await saveFollowingRewrites(latest, repository: repository,
                        sessionID: session) else { return }
                self.storage = storage
            } catch {
                guard sessionID == session else { return }
                log.error("Develop versions could not follow a metadata-only source rewrite: \(error.localizedDescription, privacy: .private)")
                notice = "Named versions could not follow this photo's saved Develop settings: \(error.localizedDescription)"
            }
        }
    }

    /// Rebinds a catalog whose source hash was superseded by this session's own metadata-only
    /// rewrite to the current revision; any other catalog is returned unchanged.
    private func rebasedForCurrentRevision(_ candidate: DevelopVersionCatalog) throws -> DevelopVersionCatalog {
        guard let revision, candidate.source.sha256 != revision.sha256,
              supersededSHAs.contains(candidate.source.sha256) else { return candidate }
        return try candidate.reassociated(to: revision)
    }

    /// Saves `candidate` bound to the session's current revision, re-saving if a metadata-only
    /// rewrite superseded it during the await, then removes catalogs left under superseded
    /// hashes. Nil when the session no longer owns this source.
    private func saveFollowingRewrites(
        _ candidate: DevelopVersionCatalog,
        repository: any DevelopVersionCatalogPersisting,
        sessionID expected: UUID
    ) async throws -> (DevelopVersionCatalog, DevelopVersionCatalogStorage)? {
        var current = try rebasedForCurrentRevision(candidate)
        for _ in 0..<4 {
            let storage = try await repository.save(current)
            guard sessionID == expected, let revision, let sourceURL else { return nil }
            if revision.sha256 == current.source.sha256 {
                for sha in supersededSHAs where sha != revision.sha256 {
                    await repository.removeSupersededCatalog(forSHA256: sha, sourceURL: sourceURL)
                }
                return (current, storage)
            }
            guard supersededSHAs.contains(current.source.sha256) else { return nil }
            current = try rebasedForCurrentRevision(current)
        }
        return nil
    }

    func reset() {
        loadTask?.cancel()
        saveTask?.cancel()
        transitionTask?.cancel()
        loadTask = nil
        saveTask = nil
        transitionTask = nil
        sessionID = UUID()
        sourceURL = nil
        catalog = nil
        repository = nil
        revision = nil
        storage = nil
        persistenceState = .unavailable
        notice = nil
        primarySettings = nil
        hasInstalledLoadedVersion = false
        supersededSHAs = []
    }
}
