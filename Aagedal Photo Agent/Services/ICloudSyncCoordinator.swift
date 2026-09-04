import Foundation
import os

private let cloudSyncLog = Logger(subsystem: "com.aagedal.photo-agent", category: "ICloudSyncCoordinator")

/// Every user-facing data category controlled by the master iCloud switch.
/// Keeping the master implementation driven by `allCases` prevents newly-added
/// categories from being omitted from either its displayed state or its action.
nonisolated enum ICloudSyncCategory: CaseIterable, Sendable {
    case preferences
    case keywordLists
    case templates
    case knownPeople
    case teams
    case watermarks
}

nonisolated struct KeywordListsRoutingCommit: Equatable, Sendable {
    let requestID: UUID
    let enabled: Bool
    let sourceURL: URL
    let destinationURL: URL
    let performedMerge: Bool
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum KeywordListsRoutingResult: Equatable, Sendable {
    case committed(KeywordListsRoutingCommit)
    case unavailable(requestID: UUID, enabled: Bool)
    case cancelledBeforeResolution(requestID: UUID, enabled: Bool)
    case cancelledBeforeCommit(requestID: UUID, enabled: Bool)
}

/// Stable roots used by one Known People iCloud reconciliation. The destination is the active
/// store only after the merge and preference commit both succeed.
nonisolated struct KnownPeopleICloudRoutingCommit: Equatable, Sendable {
    let requestID: UUID
    let enabled: Bool
    let localRootURL: URL
    let cloudRootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum KnownPeopleICloudRoutingResult: Equatable, Sendable {
    case committed(KnownPeopleICloudRoutingCommit)
    case unavailable(requestID: UUID, enabled: Bool)
    case cancelledBeforeResolution(requestID: UUID, enabled: Bool)
    case cancelledBeforeCommit(requestID: UUID, enabled: Bool)
}

nonisolated struct KnownPeopleStorageSnapshot: Equatable, Sendable {
    let url: URL
    let syncEnabled: Bool
}

nonisolated struct KnownPeopleICloudRoutingFileAccess: Sendable {
    let localRootURL: @Sendable () -> URL
    let cloudRootURL: @Sendable () -> URL?
    let ensureDirectory: @Sendable (URL) throws -> Void
    let merge: @Sendable (URL, URL) throws -> Void

    static let system = KnownPeopleICloudRoutingFileAccess(
        localRootURL: { KnownPeopleService.localKnownPeopleDirectory },
        cloudRootURL: { AppPaths.iCloudKnownPeopleURL },
        ensureDirectory: CloudCoordinatedIO.ensureDirectory,
        merge: CloudCoordinatedIO.mergeCopyPreservingNewer
    )
}

nonisolated protocol KnownPeopleICloudRouting: Sendable {
    func reconcile(
        enabled: Bool,
        requestID: UUID
    ) async throws -> KnownPeopleICloudRoutingResult

    func storageURL(syncEnabled: Bool) async -> URL

    func cloudRootURL(ensuringDirectory: Bool) async -> URL?
}

/// Serializes ubiquity-container resolution and the complete recursive merge away from MainActor.
/// Coordinated file copying is synchronous and intentionally non-preemptible once entered, so
/// cancellation is sampled on both sides and a completed merge returns durable evidence.
actor KnownPeopleICloudRoutingService: KnownPeopleICloudRouting {
    static let shared = KnownPeopleICloudRoutingService()

    private let access: KnownPeopleICloudRoutingFileAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "KnownPeopleICloudRouting"
    )

    init(access: KnownPeopleICloudRoutingFileAccess = .system) {
        self.access = access
    }

    func reconcile(
        enabled: Bool,
        requestID: UUID
    ) async throws -> KnownPeopleICloudRoutingResult {
        let interval = signposter.beginInterval(
            "Reconcile",
            id: signposter.makeSignpostID()
        )
        guard !Task.isCancelled else {
            signposter.endInterval("Reconcile", interval, "result=cancelled stage=before-resolution")
            return .cancelledBeforeResolution(requestID: requestID, enabled: enabled)
        }

        let local = access.localRootURL()
        guard let cloud = access.cloudRootURL() else {
            signposter.endInterval("Reconcile", interval, "result=unavailable")
            return .unavailable(requestID: requestID, enabled: enabled)
        }
        guard !Task.isCancelled else {
            signposter.endInterval("Reconcile", interval, "result=cancelled stage=before-commit")
            return .cancelledBeforeCommit(requestID: requestID, enabled: enabled)
        }

        let source = enabled ? local : cloud
        let destination = enabled ? cloud : local
        try access.merge(source, destination)
        let commit = KnownPeopleICloudRoutingCommit(
            requestID: requestID,
            enabled: enabled,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: source,
            destinationURL: destination,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
        signposter.endInterval(
            "Reconcile",
            interval,
            "result=committed cancelled=\(commit.cancellationRequestedAfterCommit)"
        )
        return .committed(commit)
    }

    func storageURL(syncEnabled: Bool) async -> URL {
        let local = access.localRootURL()
        guard syncEnabled else { return local }
        return access.cloudRootURL() ?? local
    }

    func cloudRootURL(ensuringDirectory: Bool) async -> URL? {
        guard let cloud = access.cloudRootURL() else { return nil }
        if ensuringDirectory {
            try? access.ensureDirectory(cloud)
        }
        return cloud
    }
}

nonisolated struct KeywordListsRoutingFileAccess: Sendable {
    let localRootURL: @Sendable () -> URL
    let cloudRootURL: @Sendable () -> URL?
    let merge: @Sendable (URL, URL) throws -> Void

    static let system = KeywordListsRoutingFileAccess(
        localRootURL: {
            AppPaths.applicationSupport.appendingPathComponent("Lists", isDirectory: true)
        },
        cloudRootURL: {
            FileManager.default
                .url(forUbiquityContainerIdentifier: KeywordListsStore.iCloudContainerID)?
                .appendingPathComponent("Documents/Lists", isDirectory: true)
        },
        merge: { source, destination in
            try KeywordListsStore.reconcileTree(from: source, to: destination)
        }
    )
}

/// Resolves iCloud/local roots and reconciles the selected route away from MainActor. Each merge
/// is serialized, and cancellation is sampled before resolution and before the non-preemptible
/// coordinated tree commit. A completed merge returns durable evidence even if the caller was
/// cancelled while Foundation was inside the filesystem operation.
actor KeywordListsRoutingService {
    static let shared = KeywordListsRoutingService()

    private let access: KeywordListsRoutingFileAccess

    init(access: KeywordListsRoutingFileAccess = .system) {
        self.access = access
    }

    func reconcile(enabled: Bool, requestID: UUID) throws -> KeywordListsRoutingResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeResolution(requestID: requestID, enabled: enabled)
        }

        let local = access.localRootURL()
        let resolvedCloud = access.cloudRootURL()
        if enabled, resolvedCloud == nil {
            return .unavailable(requestID: requestID, enabled: enabled)
        }
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, enabled: enabled)
        }

        // Turning sync off must remain possible while iCloud is unavailable. In that case there
        // are no reachable cloud bytes to reconcile, and the caller can safely install the local
        // route without a filesystem commit.
        guard let cloud = resolvedCloud else {
            return .committed(KeywordListsRoutingCommit(
                requestID: requestID,
                enabled: false,
                sourceURL: local,
                destinationURL: local,
                performedMerge: false,
                cancellationRequestedAfterCommit: false
            ))
        }

        let source = enabled ? local : cloud
        let destination = enabled ? cloud : local
        try access.merge(source, destination)
        return .committed(KeywordListsRoutingCommit(
            requestID: requestID,
            enabled: enabled,
            sourceURL: source,
            destinationURL: destination,
            performedMerge: true,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }
}

/// Single entry point the Sync settings UI binds to. Owns the per-category
/// iCloud opt-in toggles and the data movement they imply:
///
/// - **Preferences** → delegates to `PreferencesSyncService` (key-value store).
/// - **Keyword lists** → reconciles roots through `KeywordListsRoutingService`, then publishes
///   the selected route through `KeywordListsStore`.
/// - **Templates** / **Known People** / **Teams** / **Watermarks** → flips a
///   flag and copies the backing directory between the local Application
///   Support folder and the iCloud ubiquity container.
@MainActor
@Observable
final class ICloudSyncCoordinator {
    static let shared = ICloudSyncCoordinator()

    nonisolated static let masterCategories = ICloudSyncCategory.allCases

    /// Bumped after any toggle so SwiftUI re-reads the derived `*Enabled` values.
    private(set) var version = 0

    /// Last failure reason for the most recent toggle, surfaced in the UI.
    private(set) var lastError: String?

    private var pendingKeywordListsEnabled: Bool?
    @ObservationIgnored private var keywordListsRoutingTask: Task<Void, Never>?
    @ObservationIgnored private var keywordListsRoutingRequestID: UUID?
    private var pendingKnownPeopleEnabled: Bool?
    @ObservationIgnored private let knownPeopleRouting: any KnownPeopleICloudRouting
    @ObservationIgnored private var knownPeopleRoutingTask: Task<Void, Never>?
    @ObservationIgnored private var knownPeopleRoutingRequestID: UUID?

    init(
        knownPeopleRouting: any KnownPeopleICloudRouting = KnownPeopleICloudRoutingService.shared
    ) {
        self.knownPeopleRouting = knownPeopleRouting
    }

    deinit {
        keywordListsRoutingTask?.cancel()
        knownPeopleRoutingTask?.cancel()
    }

    /// Whether iCloud Drive is reachable for this app right now.
    var iCloudAvailable: Bool {
        AppPaths.iCloudDocuments != nil
    }

    // MARK: - All categories

    /// True only when every category is currently syncing. The master toggle in
    /// Settings binds to this; a mixed state reads as off so flipping it on
    /// brings everything up.
    var allEnabled: Bool {
        _ = version
        return Self.masterCategories.allSatisfy { isEnabled($0) }
    }

    /// Enables or disables every category at once. Each per-category setter still
    /// runs its own data movement and availability check, and any failure remains
    /// surfaced in `lastError` after all categories have been attempted.
    func setAllEnabled(_ on: Bool, confirmedKnownPeopleFirstEnable: Bool = false) {
        var firstError: String?
        for category in Self.masterCategories {
            setEnabled(
                on,
                for: category,
                confirmedKnownPeopleFirstEnable: confirmedKnownPeopleFirstEnable
            )
            if firstError == nil { firstError = lastError }
        }
        // Each category setter clears its predecessor's error. Preserve the
        // first failure so a partially-applied master toggle remains visible.
        lastError = firstError
    }

    // MARK: - Preferences (key-value store)

    var preferencesEnabled: Bool {
        _ = version
        return PreferencesSyncService.shared.isEnabled
    }

    func setPreferencesEnabled(_ on: Bool) {
        lastError = nil
        if on && !iCloudAvailable {
            lastError = Self.unavailableMessage
            bump()
            return
        }
        PreferencesSyncService.shared.setEnabled(on)
        bump()
    }

    // MARK: - Keyword lists

    var keywordListsEnabled: Bool {
        _ = version
        return pendingKeywordListsEnabled ?? KeywordListsStore.shared.iCloudEnabled
    }

    func setKeywordListsEnabled(_ on: Bool) {
        keywordListsRoutingTask?.cancel()
        let requestID = UUID()
        keywordListsRoutingRequestID = requestID
        pendingKeywordListsEnabled = on
        lastError = nil
        bump()
        keywordListsRoutingTask = Task { [weak self] in
            do {
                let result = try await KeywordListsRoutingService.shared.reconcile(
                    enabled: on,
                    requestID: requestID
                )
                guard let self, keywordListsRoutingRequestID == requestID else { return }
                keywordListsRoutingTask = nil
                keywordListsRoutingRequestID = nil
                pendingKeywordListsEnabled = nil
                switch result {
                case .committed:
                    KeywordListsStore.shared.applyICloudRoutingPreference(on)
                    KeywordListsCloudCoordinator.shared.refresh()
                case .unavailable:
                    lastError = Self.unavailableMessage
                case .cancelledBeforeResolution, .cancelledBeforeCommit:
                    break
                }
                bump()
            } catch {
                guard let self, keywordListsRoutingRequestID == requestID else { return }
                keywordListsRoutingTask = nil
                keywordListsRoutingRequestID = nil
                pendingKeywordListsEnabled = nil
                lastError = "Could not reconcile keyword lists with iCloud Drive: \(error.localizedDescription)"
                bump()
            }
        }
    }

    // MARK: - Templates

    var templatesEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.templatesICloudEnabled)
    }

    func setTemplatesEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudTemplatesURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                let (current, release) = AppPaths.localTemplatesDirectory()
                defer { release() }
                try mergeCopy(from: current, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.templatesICloudEnabled)
            } else {
                guard let cloud = AppPaths.iCloudTemplatesURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                let (dest, release) = AppPaths.localTemplatesDirectory()
                defer { release() }
                try mergeCopy(from: cloud, to: dest)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.templatesICloudEnabled)
            }
        } catch {
            lastError = "Could not reconcile templates with iCloud Drive: \(error.localizedDescription)"
        }
        bump()
    }

    // MARK: - Known People

    var knownPeopleEnabled: Bool {
        _ = version
        return pendingKnownPeopleEnabled
            ?? UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
    }

    func setKnownPeopleEnabled(_ on: Bool, confirmedFirstEnable: Bool = false) {
        if KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: on,
            currentlyEnabled: knownPeopleEnabled
        ), !confirmedFirstEnable {
            lastError = Self.knownPeopleConfirmationRequiredMessage
            bump()
            return
        }
        knownPeopleRoutingTask?.cancel()
        let requestID = UUID()
        knownPeopleRoutingRequestID = requestID
        pendingKnownPeopleEnabled = on
        lastError = nil
        bump()
        knownPeopleRoutingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await knownPeopleRouting.reconcile(
                    enabled: on,
                    requestID: requestID
                )
                guard knownPeopleRoutingRequestID == requestID else { return }
                knownPeopleRoutingTask = nil
                knownPeopleRoutingRequestID = nil
                pendingKnownPeopleEnabled = nil
                switch result {
                case .committed(let commit):
                    UserDefaults.standard.set(on, forKey: UserDefaultsKeys.knownPeopleICloudEnabled)
                    if confirmedFirstEnable {
                        KnownPeoplePrivacyLifecycle.recordICloudTransferConfirmation()
                    }
                    KnownPeopleService.shared.reloadAfterStorageChange(
                        resolvedStorageURL: commit.destinationURL
                    )
                    if on {
                        KnownPeopleCloudCoordinator.shared.refresh(resolvedRoot: commit.cloudRootURL)
                    } else {
                        KnownPeopleCloudCoordinator.shared.refresh()
                    }
                case .unavailable:
                    lastError = Self.unavailableMessage
                    KnownPeopleCloudCoordinator.shared.refresh()
                case .cancelledBeforeResolution, .cancelledBeforeCommit:
                    break
                }
                bump()
            } catch {
                guard knownPeopleRoutingRequestID == requestID else { return }
                knownPeopleRoutingTask = nil
                knownPeopleRoutingRequestID = nil
                pendingKnownPeopleEnabled = nil
                lastError = "Could not reconcile the Known People database with iCloud Drive: \(error.localizedDescription)"
                KnownPeopleCloudCoordinator.shared.refresh()
                bump()
            }
        }
    }

    /// Returns a route that agrees with the latest observable preference. If a toggle completes
    /// while the actor is resolving the container, repeat once rather than publishing stale
    /// storage-location evidence in Settings.
    func knownPeopleStorageSnapshot() async -> KnownPeopleStorageSnapshot {
        while true {
            if let routingTask = knownPeopleRoutingTask {
                await routingTask.value
                continue
            }
            let enabled = knownPeopleEnabled
            let url = await knownPeopleRouting.storageURL(syncEnabled: enabled)
            guard enabled == knownPeopleEnabled else { continue }
            return KnownPeopleStorageSnapshot(url: url, syncEnabled: enabled)
        }
    }

    // MARK: - Teams library

    var teamsEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.teamsICloudEnabled)
    }

    func setTeamsEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudTeamsURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: RosterStore.localTeamsDirectory, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.teamsICloudEnabled)
            } else {
                guard let cloud = AppPaths.iCloudTeamsURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: cloud, to: RosterStore.localTeamsDirectory)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.teamsICloudEnabled)
            }
            Task { @MainActor in
                await RosterStore.shared.reloadAfterStorageChange()
            }
        } catch {
            lastError = "Could not reconcile the Teams library with iCloud Drive: \(error.localizedDescription)"
        }
        RosterCloudCoordinator.shared.refresh()
        bump()
    }

    // MARK: - Watermark library

    var watermarksEnabled: Bool {
        _ = version
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.watermarksICloudEnabled)
    }

    func setWatermarksEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on {
                guard let cloud = AppPaths.iCloudWatermarksURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: WatermarkStore.localWatermarksDirectory, to: cloud)
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.watermarksICloudEnabled)
            } else {
                guard let cloud = AppPaths.iCloudWatermarksURL else {
                    lastError = Self.unavailableMessage
                    bump()
                    return
                }
                try mergeCopy(from: cloud, to: WatermarkStore.localWatermarksDirectory)
                UserDefaults.standard.set(false, forKey: UserDefaultsKeys.watermarksICloudEnabled)
            }
            WatermarkStore.shared.reloadAfterStorageChange()
        } catch {
            lastError = "Could not reconcile the Watermark library with iCloud Drive: \(error.localizedDescription)"
        }
        WatermarkCloudCoordinator.shared.refresh()
        bump()
    }

    // MARK: - Helpers

    private func isEnabled(_ category: ICloudSyncCategory) -> Bool {
        switch category {
        case .preferences: return preferencesEnabled
        case .keywordLists: return keywordListsEnabled
        case .templates: return templatesEnabled
        case .knownPeople: return knownPeopleEnabled
        case .teams: return teamsEnabled
        case .watermarks: return watermarksEnabled
        }
    }

    private func setEnabled(
        _ on: Bool,
        for category: ICloudSyncCategory,
        confirmedKnownPeopleFirstEnable: Bool = false
    ) {
        switch category {
        case .preferences: setPreferencesEnabled(on)
        case .keywordLists: setKeywordListsEnabled(on)
        case .templates: setTemplatesEnabled(on)
        case .knownPeople:
            setKnownPeopleEnabled(on, confirmedFirstEnable: confirmedKnownPeopleFirstEnable)
        case .teams: setTeamsEnabled(on)
        case .watermarks: setWatermarksEnabled(on)
        }
    }

    private static let unavailableMessage =
        "iCloud Drive is not available. Sign in to iCloud in System Settings and enable iCloud Drive for this app."
    private static let knownPeopleConfirmationRequiredMessage =
        "Confirm the Known People iCloud transfer before turning on this sync category."

    private func bump() { version &+= 1 }

    /// Recursively copies the contents of `src` into `dst`, overwriting files
    /// with the same name and preserving subdirectories. Missing source folders
    /// are treated as empty (nothing to copy). Coordinated via `NSFileCoordinator`
    /// so moving data into the ubiquity container doesn't fork conflict folders.
    private func mergeCopy(from src: URL, to dst: URL) throws {
        try CloudCoordinatedIO.mergeCopyPreservingNewer(from: src, to: dst)
    }
}
