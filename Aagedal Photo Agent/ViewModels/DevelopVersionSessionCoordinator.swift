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
protocol DevelopVersionCatalogPersisting: Sendable {
    func loadMostRelevantCatalog(
        for revision: SourceImageRevision
    ) async -> DevelopVersionCatalogMatch

    func save(
        _ catalog: DevelopVersionCatalog
    ) async throws -> DevelopVersionCatalogStorage
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
                    notice = "The source bytes changed. Reassociate the preserved catalog before applying a named version."
                case let .newerSchema(schemaVersion, _, _, _):
                    catalog = nil
                    persistenceState = .unavailable
                    notice = "This catalog uses newer schema \(schemaVersion) and is read-only in this build."
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
                let storage = try await repository.save(candidate)
                guard let self, !Task.isCancelled,
                      sessionID == expectedSessionID,
                      revision?.sha256 == sourceHash else { return }
                catalog = candidate
                self.storage = storage
                persistenceState = .saved
                onSuccess()
            } catch is CancellationError {
                return
            } catch {
                guard let self, sessionID == expectedSessionID,
                      revision?.sha256 == sourceHash else { return }
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
                let storage = try await repository.save(candidate)
                guard !Task.isCancelled, sessionID == expectedSessionID,
                      revision?.sha256 == candidate.source.sha256 else { return }
                catalog = candidate
                self.storage = storage
                persistenceState = .saved
                onSaved()
            } catch is CancellationError {
                return
            } catch {
                guard let self, sessionID == expectedSessionID,
                      revision?.sha256 == candidate.source.sha256 else { return }
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
            let storage = try await repository.save(candidate)
            guard sessionID == expectedSessionID,
                  revision?.sha256 == candidate.source.sha256 else {
                let message = "The source changed before the named version could be saved."
                persistenceState = .failed(message)
                notice = message
                return .failed(message)
            }
            catalog = candidate
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

    func cancelSave() {
        saveTask?.cancel()
        saveTask = nil
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
    }
}
