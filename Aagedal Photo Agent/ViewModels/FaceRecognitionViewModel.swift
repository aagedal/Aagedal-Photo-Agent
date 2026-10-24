import Foundation
import AppKit
import os

enum FaceGroupSortMode: String, CaseIterable {
    case manual = "Insertion Order"
    case bySize = "Largest First"
}

struct AddToKnownPeopleResult {
    let addedToExisting: Bool
    let embeddingCount: Int
    let name: String
    /// The id of the created/merged Known Person (used by the roster bridge).
    let personID: UUID
}

enum AddToKnownPeopleError: LocalizedError {
    case groupNotFound
    case noFaces
    var errorDescription: String? {
        switch self {
        case .groupNotFound: "Face group not found"
        case .noFaces: "Face group has no faces"
        }
    }
}

/// Retain encoded bytes with their display image so background preparation never reads a
/// mutable AppKit image. Both representations share the same bounded cache lifetime.
private final class FaceThumbnailCacheEntry: NSObject {
    let image: NSImage
    let data: Data

    init(image: NSImage, data: Data) {
        self.image = image
        self.data = data
    }
}

/// Value returned by the off-main scan worker. The contained model values are immutable at the
/// actor boundary and become the visible folder state only after the worker has finished.
nonisolated private struct FaceScanWorkerResult: @unchecked Sendable {
    let faces: [DetectedFace]
    let groups: [FaceGroup]
    let scannedFiles: [String: FileSignature]
    let numbers: [NumberDetection]
    let processedCount: Int
    let failureCount: Int
    let thumbnailFailureCount: Int
    let cancelledThumbnailCount: Int
    let thumbnailPersistenceError: String?
    let incompleteThumbnailPaths: Set<String>
    let committedThumbnailIDs: [UUID]
    let documentPersistenceResults: [FaceDataPersistenceResult]
}

enum FaceScanQuiescenceError: LocalizedError, Equatable {
    case persistenceFailed(String)
    case replacementScanStarted

    var errorDescription: String? {
        switch self {
        case .persistenceFailed(let detail):
            "The face scan finished, but its final data could not be saved: \(detail)"
        case .replacementScanStarted:
            "A new face scan started before rename could begin. Wait for it to finish and try again."
        }
    }
}

/// Immutable outcome of deleting a face group, including the filesystem commit evidence needed
/// by browser state and the reason a post-I/O face-data mutation may not have been applied.
nonisolated struct FaceGroupDeletionResult: Sendable, Equatable {
    enum FaceDataDisposition: Sendable, Equatable {
        case applied
        case groupNotFound
        case cancelledBeforeMutation
        case staleStatePreserved
        case failed(String)
    }

    let trashedPhotoURLs: Set<URL>
    let failures: [FileSystemService.ItemFailure]
    let cancellationStoppedRemainingPhotos: Bool
    let faceDataDisposition: FaceDataDisposition
}

@Observable
final class FaceRecognitionViewModel {
    /// Stable ID for the synthetic "Unmatched Faces" group (singletons with no match)
    static let unmatchedGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var faceData: FolderFaceData? {
        didSet {
            previousFaceDataSnapshot = oldValue
            faceDataRevision &+= 1
            invalidateCaches()
        }
    }
    @ObservationIgnored private var previousFaceDataSnapshot: FolderFaceData?
    /// Per-view-model durable authority; another window's reload cannot authorize our stale edit.
    @ObservationIgnored private var durableFaceSnapshots: [String: FolderFaceData] = [:]
    @ObservationIgnored private var faceDataRevision: UInt64 = 0
    @ObservationIgnored private var photoDeletionGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var stalePhotoDeletionFolders: Set<String> = []

    /// Live "minimum sharpness" filter (0...1 face capture-quality). Faces below this are hidden
    /// from the displayed face set without re-scanning. Bound to the slider in the expanded face
    /// view and persisted to `faceMinQuality`.
    var displayQualityThreshold: Float = Float(
        AppDefaults.store.object(forKey: UserDefaultsKeys.faceMinQuality) as? Double
            ?? Double(FaceRecognitionDefaults.minFaceQuality)
    ) {
        didSet {
            guard displayQualityThreshold != oldValue else { return }
            AppDefaults.store.set(Double(displayQualityThreshold), forKey: UserDefaultsKeys.faceMinQuality)
            invalidateCaches()
        }
    }
    var isScanning = false
    private(set) var isCancellingScan = false
    var scanProgress: String = ""
    private(set) var scanProcessedCount = 0
    private(set) var scanTotalCount = 0
    /// The browser folder represented by `faceData` and the face bar.
    private(set) var displayedFolderURL: URL?
    /// The folder owned by the one background scan. This deliberately survives folder navigation.
    private(set) var scanningFolderURL: URL?
    /// While a browser rename sheet is executing, this reservation prevents any programmatic
    /// scan start from reopening the writer race after the current scan has been drained.
    @ObservationIgnored private var renameQuiescenceFolderURL: URL?
    var scanComplete = false
    /// Explicit tests and packaged-unavailable builds can pin a state. Normal app use resolves
    /// the on-demand component dynamically so a verified install/removal takes effect without
    /// requiring a relaunch.
    @ObservationIgnored private let faceModelAvailabilityOverride: FaceRecognitionModelAvailability?
    var faceModelAvailability: FaceRecognitionModelAvailability {
        faceModelAvailabilityOverride ?? CoreMLFaceEmbedder.shared.availability
    }
    /// The expanded manager can work with partial results from a cancelled or interrupted scan.
    /// Keep scan completion separate so the face bar can still offer to resume scanning.
    var canShowExpandedFaceManagement: Bool {
        scanComplete || faceData?.faces.isEmpty == false
    }
    var errorMessage: String?

    /// "Update Person Shown on N photos?" offer created by a face edit that made a name this app
    /// applied wrong (rename, move, merge, delete, Known People change). Nil when none is pending.
    var pendingPersonShownUpdate: PersonShownUpdateProposal?
    @ObservationIgnored nonisolated(unsafe) private var knownPeopleObserver: (any NSObjectProtocol)?
    /// Face-data updates that arrived while this folder was scanning. The scan publishes its own
    /// snapshot at the end, so these are replayed afterwards instead of being overwritten.
    @ObservationIgnored private var deferredAfterScan: [@MainActor () -> Void] = []

    /// Whether Apply All has anything to write: named face groups, or — with the Sports lens
    /// active — confirmed jersey players (sports resolution never names face groups). Partial
    /// data from a cancelled or partly failed scan is still applicable; `scanComplete` only
    /// drives the "resume scanning" affordance.
    var canApplyAllNames: Bool {
        guard faceData != nil else { return false }
        if !namedGroups.isEmpty { return true }
        return activeLens == .sports && !confirmedPlayerCards.isEmpty
    }

    // Keep compressed crops for the displayed folder so an evicted decoded image can be
    // recreated when its card scrolls back into view.
    @ObservationIgnored private var thumbnailDataByFaceID: [UUID: Data] = [:]
    // Thumbnail cache: faceID -> decoded NSImage (evictable, not observed)
    @ObservationIgnored nonisolated(unsafe) private let thumbnailCache: NSCache<NSUUID, FaceThumbnailCacheEntry> = {
        let cache = NSCache<NSUUID, FaceThumbnailCacheEntry>()
        cache.countLimit = 500
        return cache
    }()

    // Merge suggestions for similar groups
    var mergeSuggestions: [MergeSuggestion] = []

    // Known People suggestions (moderate-confidence matches requiring user confirmation)
    var knownPersonSuggestions: [KnownPersonSuggestion] = []

    // Result summary from the last Known People check
    var lastKnownPeopleCheckResult: KnownPeopleCheckResult?

    // Intermediate groups shown during active scan (for live UI feedback)
    var scanningGroups: [FaceGroup] = []

    // Sort mode for face groups
    var sortMode: FaceGroupSortMode = .bySize {
        didSet { invalidateCaches() }
    }

    /// The lens whose grouping the expanded view shows. Persisted per folder. Switching never
    /// re-detects or re-embeds — it only changes which stored grouping is displayed (secondary
    /// lenses re-cluster from stored embeddings when they land).
    var activeLens: FaceLens {
        get {
            let stored = faceData?.currentLens ?? .face
            // Never surface a lens that isn't available (multi-lens off, or Sports without
            // jersey data) — a stale persisted value falls back to Face.
            return availableLenses.contains(stored) ? stored : .face
        }
        set {
            guard var data = faceData, data.currentLens != newValue else { return }
            data.activeLens = newValue
            faceData = data
            scheduleFaceDataPersistence(data)
            lensDidChange(to: newValue)
        }
    }

    /// Lenses offered in the switcher for this folder. Sports only appears when the scan
    /// produced jersey data (sports tagging enabled and numbers found).
    var availableLenses: [FaceLens] {
        // Sports ships independently of the other secondary lenses (which stay gated behind
        // multiLensEnabled until their thresholds are calibrated). It appears only when this
        // folder actually produced jersey data.
        if !FaceRecognitionDefaults.multiLensEnabled {
            var lenses: [FaceLens] = [.face]
            if FaceRecognitionDefaults.sportsLensEnabled, folderHasJerseyData { lenses.append(.sports) }
            return lenses
        }
        return FaceLens.allCases.filter {
            switch $0 {
            case .sports: return FaceRecognitionDefaults.sportsLensEnabled && folderHasJerseyData
            default: return true
            }
        }
    }

    var folderHasJerseyData: Bool {
        guard let data = faceData else { return false }
        if data.numberDetections?.isEmpty == false { return true }
        return data.faces.contains { $0.jerseyNumber != nil }
    }

    /// Stored number detections with no associated face (back-turned players), excluding ones the
    /// photographer has rejected — the "unmatched numbers" shown in the Sports lens. The stored
    /// array also holds face-attached claims after resolution, so this filters to standalone.
    var standaloneNumberDetections: [NumberDetection] {
        (faceData?.numberDetections ?? []).filter {
            $0.associatedFaceID == nil && $0.effectiveClaimState != .rejected
        }
    }

    /// One confirmed player, aggregating every confirmed number claim that resolved to them — the
    /// identity-centric "player card" unit. Keyed on the resolved name, not on body geometry.
    struct SportsPlayerCard: Identifiable {
        var id: String { name.lowercased() }
        let name: String
        let representativeFaceID: UUID?
        let teamSide: TeamSide?
        let imageCount: Int
        let detectionIDs: [UUID]
    }

    /// Confirmed players for the Sports lens, most-photographed first. These are the names that
    /// will be written on Apply.
    var confirmedPlayerCards: [SportsPlayerCard] {
        let confirmed = (faceData?.numberDetections ?? []).filter {
            $0.effectiveClaimState == .confirmed && ($0.resolvedPlayerName?.isEmpty == false)
        }
        let grouped = Dictionary(grouping: confirmed) { $0.resolvedPlayerName! }
        return grouped.map { name, dets in
            SportsPlayerCard(
                name: name,
                representativeFaceID: dets.first(where: { $0.associatedFaceID != nil })?.associatedFaceID,
                teamSide: dets.compactMap(\.teamSide).first,
                imageCount: Set(dets.map(\.imageURL)).count,
                detectionIDs: dets.map(\.id)
            )
        }
        .sorted { ($0.imageCount, $1.name) > ($1.imageCount, $0.name) }
    }

    /// Why a claim is in the review queue rather than auto-confirmed.
    enum SportsReviewReason {
        /// A number with no face in the frame — could be a supporter or a misread.
        case numberOnly
        /// A number over a detected (but not independently identified) face.
        case unconfirmedFace
        /// The number exists on both teams and needs a side.
        case ambiguousSide
    }

    /// One claim awaiting the photographer's decision.
    struct SportsReviewItem: Identifiable {
        var id: UUID { detection.id }
        let detection: NumberDetection
        let reason: SportsReviewReason
    }

    /// Suggested (and ambiguous) claims that need confirmation before any name is written —
    /// the review queue. Number-only claims surface first (highest risk of a wrong name).
    var sportsReviewItems: [SportsReviewItem] {
        let ambiguousIDs = Set(ambiguousNumberDetections.map(\.id))
        let items: [SportsReviewItem] = (faceData?.numberDetections ?? []).compactMap { det in
            guard det.effectiveClaimState == .suggested else { return nil }
            if ambiguousIDs.contains(det.id) {
                return SportsReviewItem(detection: det, reason: .ambiguousSide)
            }
            guard det.resolvedPlayerName?.isEmpty == false else { return nil }
            return SportsReviewItem(
                detection: det,
                reason: det.associatedFaceID == nil ? .numberOnly : .unconfirmedFace
            )
        }
        let order: [SportsReviewReason: Int] = [.numberOnly: 0, .ambiguousSide: 1, .unconfirmedFace: 2]
        return items.sorted { (order[$0.reason] ?? 9, $0.detection.number) < (order[$1.reason] ?? 9, $1.detection.number) }
    }

    func lensState(for lens: FaceLens) -> FaceLensState {
        faceData?.lensState(for: lens) ?? FaceLensState()
    }

    func lensGroups(for lens: FaceLens) -> [FaceGroup] {
        faceData?.groups(for: lens) ?? []
    }

    /// Run the switched-to lens's assist over the people groups. Cheap: works entirely from
    /// stored embeddings/detections, never re-detects or re-embeds.
    private func lensDidChange(to lens: FaceLens) {
        switch lens {
        case .face:
            updateMergeSuggestions()
        case .redCarpet:
            updateClothingMergeSuggestions()
        case .sports:
            // Do NOT auto-merge groups by jersey number: that silently asserts the number on a
            // torso identifies the face, exactly the body-association we don't trust. Merging by
            // number stays an explicit, user-initiated action ("Merge by numbers"). Switching to
            // the lens just (re)resolves claims so the cards and review queue are current.
            runSportsResolution()
        case .expression:
            break
        }
    }

    // MARK: - Red Carpet assist

    /// Replace the merge suggestions with clothing-assisted ones (combined face+clothing
    /// distance between existing groups). Runs off-main; suggestions land asynchronously.
    func updateClothingMergeSuggestions() {
        guard let data = faceData else {
            mergeSuggestions = []
            return
        }
        let groups = data.groups
        let faces = data.faces
        let folderURL = data.folderURL
        let service = lensService
        Task(priority: .userInitiated) { [weak self] in
            let suggestions = await service.clothingAssistedMergeSuggestions(groups: groups, faces: faces)
            guard let self, self.faceData?.folderURL == folderURL, self.activeLens == .redCarpet else { return }
            self.mergeSuggestions = suggestions
        }
    }

    // MARK: - Sports assist

    /// Number of groups merged by the last jersey-number assist run (transient, for UI feedback).
    var lastJerseyMergeCount = 0

    /// How many group merges the jersey-number assist would make right now (0 ⇒ nothing to merge,
    /// so the "Merge by numbers" action is hidden).
    var jerseyMergeCandidateCount: Int {
        guard let data = faceData else { return 0 }
        return Self.jerseyMergePlan(groups: data.groups, faces: data.faces).count
    }

    /// Merge people groups that share the same jersey number with agreeing kit colours.
    /// Conservative: groups with mixed member numbers, differently named groups, or colour
    /// disagreement never merge. Returns the number of merges applied.
    @discardableResult
    func applyJerseyNumberMerges() -> Int {
        guard let data = faceData else { return 0 }
        let plan = Self.jerseyMergePlan(groups: data.groups, faces: data.faces)
        for merge in plan {
            // Carry a name over before the source group is destroyed: mergeGroups keeps the
            // target's name, so move the source's name across when the target is unnamed.
            if let source = group(byID: merge.source), let target = group(byID: merge.target),
               target.name == nil, let sourceName = source.name {
                nameGroup(merge.target, name: sourceName)
            }
            mergeGroups(sourceID: merge.source, into: merge.target)
        }
        return plan.count
    }

    /// Decide which groups to merge based on jersey numbers. A group participates when its
    /// numbered faces agree on exactly one number; two groups merge when they share that
    /// number, are not named as different people, and their sampled kit colours agree
    /// (both-missing colours also block the merge — the same number on the other team must
    /// not collapse two players).
    nonisolated static func jerseyMergePlan(
        groups: [FaceGroup],
        faces: [DetectedFace]
    ) -> [(source: UUID, target: UUID)] {
        let lookup = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })

        struct Entry {
            let groupID: UUID
            let number: Int
            let name: String?
            let size: Int
            let color: ColorRGB?
        }

        var entries: [Entry] = []
        for group in groups {
            let members = group.faceIDs.compactMap { lookup[$0] }
            let numbers = Set(members.compactMap(\.jerseyNumber))
            guard numbers.count == 1, let number = numbers.first else { continue }
            let colors = members.compactMap(\.jerseyColorRGB)
            let avgColor: ColorRGB? = colors.isEmpty ? nil : ColorRGB(
                r: colors.map(\.r).reduce(0, +) / Double(colors.count),
                g: colors.map(\.g).reduce(0, +) / Double(colors.count),
                b: colors.map(\.b).reduce(0, +) / Double(colors.count)
            )
            entries.append(Entry(groupID: group.id, number: number, name: group.name, size: group.faceIDs.count, color: avgColor))
        }

        func colorsAgree(_ a: ColorRGB?, _ b: ColorRGB?) -> Bool {
            guard let a, let b else { return false }
            let d = (a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)
            return d.squareRoot() < 0.25
        }

        var merges: [(source: UUID, target: UUID)] = []
        for (_, candidates) in Dictionary(grouping: entries, by: \.number) where candidates.count >= 2 {
            // Target preference: named first, then largest.
            let ranked = candidates.sorted { a, b in
                if (a.name != nil) != (b.name != nil) { return a.name != nil }
                return a.size > b.size
            }
            guard let target = ranked.first else { continue }
            for other in ranked.dropFirst() {
                if let n1 = target.name, let n2 = other.name, n1 != n2 { continue }
                guard colorsAgree(target.color, other.color) else { continue }
                merges.append((source: other.groupID, target: target.groupID))
            }
        }
        return merges
    }

    // MARK: - Secondary Lens Prewarm

    /// Compute Expression/Red Carpet embeddings and clusterings in the background once the
    /// Face scan is complete (or when opening a folder whose stored lens data is missing or
    /// stale). Lens switches never wait on this — they show whatever grouping is stored, with
    /// an in-progress state until this pass lands.
    private func prewarmSecondaryLensesIfNeeded() {
        // No secondary lenses ship in 2.0, so skip the background embedding passes entirely.
        guard FaceRecognitionDefaults.multiLensEnabled else { return }
        guard let data = faceData, data.scanComplete, !data.faces.isEmpty else { return }

        let staleLenses = FaceLens.allCases.filter { lens in
            switch lens {
            case .face, .sports:
                // Face is clustered by the scan; Sports works from jersey detections the
                // scan already stored — neither needs embedding prewarm.
                false
            case .expression:
                needsPrewarm(data.lensState(for: lens), version: FaceRecognitionDefaults.expressionEmbeddingVersion)
            case .redCarpet:
                needsPrewarm(data.lensState(for: lens), version: FaceRecognitionDefaults.redCarpetEmbeddingVersion)
            }
        }
        guard !staleLenses.isEmpty else { return }

        lensPrewarmTask?.cancel()

        // Mark the stale lenses as in-progress (in memory only; persisted state stays as-is
        // so an interrupted prewarm simply re-runs on the next folder open).
        var marked = data
        for lens in staleLenses {
            var state = marked.lensState(for: lens)
            state.status = .embedding
            marked.setLensState(state, for: lens)
        }
        faceData = marked

        let faces = marked.faces
        let folderURL = marked.folderURL
        let persistenceService = folderLoadService
        let service = lensService

        lensPrewarmTask = Task(priority: .utility) { [weak self] in
            let outcome = await service.prewarm(
                faces: faces,
                folderURL: folderURL,
                persistenceService: persistenceService
            )
            guard !Task.isCancelled else { return }
            self?.applyLensPrewarm(outcome)
        }
    }

    /// A lens needs (re)computation unless its stored results are complete on the current
    /// embedding version. `.embedding` from a superseded in-memory run also re-queues.
    private func needsPrewarm(_ state: FaceLensState, version: Int) -> Bool {
        state.status != .complete || (state.embeddingVersion ?? 0) < version
    }

    private func applyLensPrewarm(_ outcome: FaceLensPrewarmOutcome) {
        // The folder may have changed while the prewarm ran; results merge by face ID, so
        // faces deleted in the meantime simply drop out.
        guard var data = faceData, data.folderURL == outcome.folderURL else { return }

        let indexByID = faceIndexMap(from: data)
        for (id, print) in outcome.appearancePrints {
            if let i = indexByID[id] { data.faces[i].appearanceFeaturePrintData = print }
        }
        for (id, item) in outcome.clothingPrints {
            if let i = indexByID[id] {
                data.faces[i].clothingFeaturePrintData = item.data
                data.faces[i].clothingRect = item.rect
            }
        }

        let validIDs = Set(data.faces.map(\.id))
        data.setLensState(FaceLensState(
            groups: Self.sanitizedLensGroups(outcome.expressionGroups, validFaceIDs: validIDs),
            status: .complete,
            embeddingVersion: FaceRecognitionDefaults.expressionEmbeddingVersion,
            lastUpdated: Date()
        ), for: .expression)
        // Red Carpet keeps no groups of its own (it assists the canonical people groups);
        // a complete state just records that the clothing embeddings are ready.
        data.setLensState(FaceLensState(
            groups: [],
            status: .complete,
            embeddingVersion: FaceRecognitionDefaults.redCarpetEmbeddingVersion,
            lastUpdated: Date()
        ), for: .redCarpet)

        faceData = data
        lensPrewarmTask = nil
        scheduleFaceDataPersistence(data)
    }

    /// Drop face IDs that no longer exist (deleted while the prewarm ran) and repair
    /// representatives; empty groups vanish.
    nonisolated private static func sanitizedLensGroups(_ groups: [FaceGroup], validFaceIDs: Set<UUID>) -> [FaceGroup] {
        groups.compactMap { group in
            var sanitized = group
            sanitized.faceIDs = sanitized.faceIDs.filter { validFaceIDs.contains($0) }
            guard !sanitized.faceIDs.isEmpty else { return nil }
            if !sanitized.faceIDs.contains(sanitized.representativeFaceID) {
                sanitized.representativeFaceID = sanitized.faceIDs[0]
            }
            return sanitized
        }
    }

    // Track matches between groups and known people
    // Maps groupID -> (knownPersonID, matchConfidence)
    var knownPersonMatchByGroup: [UUID: (personID: UUID, confidence: Float)] = [:]

    // MARK: - Sports tagging
    /// Per-folder match setup (home/away teams). Drives number→player resolution.
    var matchRoster: MatchRoster? {
        didSet { matchRosterRevision &+= 1 }
    }
    @ObservationIgnored private var matchRosterRevision: UInt64 = 0
    /// When set, the colour-cluster → team mapping needs the photographer to
    /// confirm (or flip) before names are written. Drives the confirm UI.
    var pendingColorClusterConfirmation: TeamColorClusterer.ClusterResult?
    /// Standalone numbers that couldn't be resolved unambiguously (same number on
    /// both teams with unknown side, etc.) — surfaced for manual assignment.
    var ambiguousNumberDetections: [NumberDetection] = []

    @ObservationIgnored private let matchRosterService = MatchRosterService.shared
    @ObservationIgnored private var matchRosterLoadTask: Task<Void, Never>?
    @ObservationIgnored private var matchRosterLoadRequestID = UUID()
    @ObservationIgnored private let colorClusterer = TeamColorClusterer()
    @ObservationIgnored private let playerResolver = PlayerResolver()
    /// Minimum colour-cluster confidence to treat the split as trustworthy.
    @ObservationIgnored private let clusterConfidenceFloor: Float = 0.5

    // The currently selected group for thumbnail replacement (only one at a time)
    var selectedThumbnailReplacementGroupID: UUID?
    // The currently selected face within that group for thumbnail replacement
    var selectedThumbnailReplacementFaceID: UUID?

    // Cached sorted groups (invalidated when faceData changes)
    private(set) var sortedGroups: [FaceGroup] = []
    private(set) var namedGroups: [FaceGroup] = []
    private(set) var unnamedGroups: [FaceGroup] = []

    // Fast face lookup by ID (invalidated when faceData changes)
    // Not observed - always rebuilt alongside sortedGroups
    @ObservationIgnored private var faceLookup: [UUID: DetectedFace] = [:]

    // Fast group lookup by ID (invalidated when faceData changes)
    // Not observed - always rebuilt alongside sortedGroups
    @ObservationIgnored private var groupLookup: [UUID: FaceGroup] = [:]

    // Fast face lookup by image URL (invalidated when faceData changes)
    @ObservationIgnored private var facesByImageURL: [URL: [DetectedFace]] = [:]

    // Detection configuration from settings
    var detectionConfig: FaceDetectionService.DetectionConfig {
        var config = FaceDetectionService.DetectionConfig()

        let confidence = AppDefaults.store.object(forKey: UserDefaultsKeys.faceMinConfidence) as? Double
        config.minConfidence = Float(confidence ?? 0.7)
        let minSize = AppDefaults.store.object(forKey: UserDefaultsKeys.faceMinFaceSize) as? Int
        config.minFaceSize = minSize ?? 50

        // Fast is the default. Thorough adds tiled detection for small/off-angle group-shot faces.
        config.tiledDetection = AppDefaults.store.object(forKey: UserDefaultsKeys.faceTiledDetection) as? Bool ?? false

        // OCR is an explicit scan action, independent of the legacy saved Sports toggle.
        config.sportsModeEnabled = false
        let ocrConf = AppDefaults.store.object(forKey: UserDefaultsKeys.sportsOCRConfidenceThreshold) as? Double
        config.sportsOCRConfidenceThreshold = Float(ocrConf ?? 0.5)
        let minHeight = AppDefaults.store.object(forKey: UserDefaultsKeys.sportsNumberMinHeightFraction) as? Double
        config.sportsNumberMinHeightFraction = CGFloat(minHeight ?? 0.02)

        return config
    }

    @ObservationIgnored private var activeScanTask: Task<FaceScanCompletion, Never>?
    @ObservationIgnored private var activeScanWorkerTask: Task<FaceScanWorkerResult, Never>?
    /// Folders whose UI-bound Known People/Sports finishing pass was deferred because another
    /// folder was displayed when their background scan completed.
    @ObservationIgnored private var deferredPostprocessingFolders: Set<URL> = []
    @ObservationIgnored private var metadataWriteTask: Task<Void, Never>?
    @ObservationIgnored private let injectedFieldMutationWriter: (@Sendable (MetadataFieldMutationWriteRequest) async -> MetadataFieldMutationWriteResult)?
    @ObservationIgnored private let fieldMutationModeResolver: @MainActor (Bool, Bool) -> MetadataWriteMode
    private(set) var fieldMutationResults: [MetadataFieldMutationWriteResult] = []
    @ObservationIgnored private var lensPrewarmTask: Task<Void, Never>?
    @ObservationIgnored private var faceDataLoadTask: Task<Void, Never>?
    @ObservationIgnored private var faceDataPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var faceDataLoadRequestID = UUID()
    private let detectionService = FaceDetectionService()
    private let thumbnailRegenerator: (@Sendable (DetectedFace) async throws -> Data)?
    private let scanDetector: (@Sendable (URL, FaceDetectionService.DetectionConfig) async throws -> FaceDetectionService.DetectionResult)?
    /// Shared across off-main merge-suggestion recomputations so each face's feature print
    /// is unarchived once and reused, rather than allocating a fresh cache per call.
    /// FeaturePrintCache is thread-safe (`@unchecked Sendable`).
    @ObservationIgnored private let mergeFeaturePrintCache = FaceDetectionService.FeaturePrintCache()
    private let lensService = FaceLensService()
    @ObservationIgnored private let folderLoadService: FaceDataFolderLoadService
    @ObservationIgnored private let fileSignatureService: FaceScanFileSignatureService
    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()
    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "FaceRecognitionViewModel")
    @ObservationIgnored private let activityHistory: ActivityHistoryStore?
    @ObservationIgnored private let fileSystemService: FileSystemService
    @ObservationIgnored private let imageTrashHandler: any ImageTrashHandling

    init(
        readService: SwiftExifReadService,
        writeEngine: any MetadataWriteEngine,
        activityHistory: ActivityHistoryStore? = nil,
        faceModelAvailability: FaceRecognitionModelAvailability? = nil,
        fileSystemService: FileSystemService = FileSystemService(),
        imageTrashHandler: any ImageTrashHandling = SystemImageTrashHandler(),
        folderLoadService: FaceDataFolderLoadService = .shared,
        fileSignatureService: FaceScanFileSignatureService = .shared,
        scanDetector: (@Sendable (URL, FaceDetectionService.DetectionConfig) async throws -> FaceDetectionService.DetectionResult)? = nil,
        thumbnailRegenerator: (@Sendable (DetectedFace) async throws -> Data)? = nil,
        fieldMutationWriter: (@Sendable (MetadataFieldMutationWriteRequest) async -> MetadataFieldMutationWriteResult)? = nil,
        fieldMutationModeResolver: @escaping @MainActor (Bool, Bool) -> MetadataWriteMode = {
            MetadataWriteMode.current(forC2PA: $0, isRaw: $1)
        }
    ) {
        self.readService = readService
        self.writeEngine = writeEngine
        self.injectedFieldMutationWriter = fieldMutationWriter
        self.fieldMutationModeResolver = fieldMutationModeResolver
        self.activityHistory = activityHistory
        self.faceModelAvailabilityOverride = faceModelAvailability
        self.fileSystemService = fileSystemService
        self.imageTrashHandler = imageTrashHandler
        self.folderLoadService = folderLoadService
        self.fileSignatureService = fileSignatureService
        self.scanDetector = scanDetector
        self.thumbnailRegenerator = thumbnailRegenerator
        knownPeopleObserver = NotificationCenter.default.addObserver(
            forName: .knownPeopleDatabaseDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let change = notification.userInfo?[KnownPeopleIdentityChange.userInfoKey]
                as? KnownPeopleIdentityChange else { return }
            MainActor.assumeIsolated { self?.handleKnownPeopleIdentityChange(change) }
        }
    }

    deinit {
        if let knownPeopleObserver { NotificationCenter.default.removeObserver(knownPeopleObserver) }
        activeScanTask?.cancel()
        activeScanWorkerTask?.cancel()
        metadataWriteTask?.cancel()
        lensPrewarmTask?.cancel()
        faceDataLoadTask?.cancel()
        matchRosterLoadTask?.cancel()
    }

    // MARK: - Cache Management

    private func invalidateCaches() {
        // Clear stale group-level state that references old group IDs
        knownPersonMatchByGroup.removeAll()
        mergeSuggestions.removeAll()
        knownPersonSuggestions.removeAll()
        lastKnownPeopleCheckResult = nil

        // Rebuild sorted groups
        guard let groups = faceData?.groups else {
            sortedGroups = []
            namedGroups = []
            unnamedGroups = []
            canRefine = false
            faceLookup = [:]
            groupLookup = [:]
            facesByImageURL = [:]
            return
        }

        // Live sharpness filter: only groups with at least one visible face appear in the display
        // lists. (groupLookup below keeps the FULL groups, so mutations still see every face.)
        let visibleFaceIDs: Set<UUID> = Set((faceData?.faces ?? []).filter(isVisibleByQuality).map(\.id))
        let visibleGroups = groups.filter { group in
            group.faceIDs.contains { visibleFaceIDs.contains($0) }
        }

        // Split into named/unnamed — both sort modes need this partition
        var named: [FaceGroup] = []
        var unnamed: [FaceGroup] = []
        for group in visibleGroups {
            if group.name != nil {
                named.append(group)
            } else {
                unnamed.append(group)
            }
        }
        named.sort {
            ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
        }

        // Separate auto-generated singletons from multi-face and user-created groups
        var multiface = unnamed.filter { $0.faceIDs.count > 1 || $0.userCreated == true }
        let singletons = unnamed.filter { $0.faceIDs.count == 1 && $0.userCreated != true }

        switch sortMode {
        case .bySize:
            multiface.sort { $0.faceIDs.count > $1.faceIDs.count }
        case .manual:
            break
        }

        // Build synthetic "Unmatched Faces" group from singletons, always placed last
        var unmatchedGroup: [FaceGroup] = []
        if !singletons.isEmpty {
            let allSingletonFaceIDs = singletons.flatMap(\.faceIDs)
            unmatchedGroup = [FaceGroup(
                id: Self.unmatchedGroupID,
                name: nil,
                representativeFaceID: singletons[0].representativeFaceID,
                faceIDs: allSingletonFaceIDs
            )]
        }

        namedGroups = named
        unnamedGroups = multiface + unmatchedGroup
        canRefine = !named.isEmpty && !unnamedGroups.isEmpty
        sortedGroups = named + multiface + unmatchedGroup

        // Rebuild group lookup (includes synthetic unmatched group for card view operations)
        groupLookup = [:]
        for group in groups {
            groupLookup[group.id] = group
        }
        if let syntheticGroup = unmatchedGroup.first {
            groupLookup[syntheticGroup.id] = syntheticGroup
        }

        // Rebuild face lookup and per-image index
        faceLookup = [:]
        facesByImageURL = [:]
        if let faces = faceData?.faces {
            for face in faces {
                faceLookup[face.id] = face
                facesByImageURL[face.imageURL, default: []].append(face)
            }
        }
    }

    // MARK: - Load Existing Data

    /// The active browser pane has no folder: stop presenting the previous folder's faces.
    /// A background scan keeps running (its folder is tracked by `scanningFolderURL`).
    func clearDisplayedFolder() {
        guard displayedFolderURL != nil || faceData != nil else { return }
        matchRosterLoadTask?.cancel()
        matchRosterLoadRequestID = UUID()
        matchRoster = nil
        lensPrewarmTask?.cancel()
        faceDataLoadTask?.cancel()
        faceDataLoadRequestID = UUID()
        displayedFolderURL = nil
        faceData = nil
        scanComplete = false
        thumbnailCache.removeAllObjects()
        thumbnailDataByFaceID.removeAll()
    }

    func loadFaceData(for folderURL: URL, cleanupPolicy: FaceCleanupPolicy) {
        let isSameFolder = displayedFolderURL == folderURL.standardizedFileURL
        if !isSameFolder {
            matchRosterLoadTask?.cancel()
            matchRosterLoadRequestID = UUID()
            matchRoster = nil
        }
        displayedFolderURL = folderURL.standardizedFileURL
        lensPrewarmTask?.cancel()
        faceDataLoadTask?.cancel()
        let requestID = UUID()
        faceDataLoadRequestID = requestID

        // Never present the preceding folder's people or thumbnails while the new immutable
        // snapshot is being read. Folder identity itself remains synchronous for scan routing.
        if !isSameFolder {
            faceData = nil
            scanComplete = false
            thumbnailCache.removeAllObjects()
            thumbnailDataByFaceID.removeAll()
        }

        let pendingPersistence = faceDataPersistenceTask
        let folderLoadService = self.folderLoadService
        faceDataLoadTask = Task(priority: .userInitiated) { [weak self] in
            _ = await pendingPersistence?.value
            let result: FaceDataFolderLoadResult
            do {
                result = try await folderLoadService.loadWithFolderReservation(
                    folderURL: folderURL,
                    cleanupPolicy: cleanupPolicy
                )
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.faceDataLoadRequestID == requestID,
                      self.displayedFolderURL == folderURL.standardizedFileURL else { return }
                self.errorMessage = "Failed to load face data: \(error.localizedDescription)"
                return
            }
            guard let self,
                  self.faceDataLoadRequestID == requestID,
                  self.displayedFolderURL == folderURL.standardizedFileURL else {
                return
            }

            switch result {
            case .cancelled:
                return
            case .complete(let evidence):
                self.stalePhotoDeletionFolders.remove(folderURL.standardizedFileURL.path)
                // Reload establishes a new authority and invalidates edits queued from the
                // pre-load presentation. Retire old folders' potentially large embeddings.
                self.photoDeletionGenerations[folderURL.standardizedFileURL.path, default: 0] &+= 1
                self.durableFaceSnapshots.removeAll()
                self.durableFaceSnapshots[folderURL.standardizedFileURL.path] = evidence.faceData
                self.faceData = evidence.faceData
                self.scanComplete = evidence.scanCompleteWithThumbnails
                self.installThumbnails(evidence.thumbnailData)

                if case .deletionFailed(let message) = evidence.cleanupDisposition {
                    self.errorMessage = "Failed to remove expired face data: \(message)"
                }

                guard evidence.faceData != nil else { return }
                if self.deferredPostprocessingFolders.remove(folderURL.standardizedFileURL) != nil {
                    if self.folderHasJerseyData {
                        self.scheduleMatchRosterLoad(for: folderURL, resolveAfterLoad: true)
                    }
                    self.applyKnownPeopleMatches()
                }
                self.prewarmSecondaryLensesIfNeeded()
            }
        }
    }

    /// Test and command-boundary synchronization without exposing the task itself.
    func waitForCurrentFaceDataLoad() async {
        _ = await faceDataLoadTask?.value
    }

    /// Suspends until the latest queued face-data mutation has crossed the serialized durable
    /// boundary. Mutations remain UI-immediate, while their ordered writes never block MainActor.
    func waitForCurrentFaceDataPersistence() async {
        _ = await faceDataPersistenceTask?.value
    }

    @discardableResult
    private func scheduleFaceDataPersistence(
        _ data: FolderFaceData,
        deletingThumbnailIDs: [UUID] = [],
        failurePrefix: String = "Failed to save face data"
    ) -> Task<Void, Never> {
        let expectedRevision = faceDataRevision
        let folderIdentity = data.folderURL.standardizedFileURL.path
        if durableFaceSnapshots[folderIdentity] == nil,
           let previous = previousFaceDataSnapshot,
           previous.folderURL.standardizedFileURL.path == folderIdentity {
            durableFaceSnapshots[folderIdentity] = previous
        }
        let expectedDeletionGeneration = photoDeletionGenerations[folderIdentity, default: 0]
        let precedingTask = faceDataPersistenceTask
        let service = folderLoadService
        let task = Task(priority: .utility) { [weak self] in
            _ = await precedingTask?.value
            guard let self else { return }
            // An edit captured before a pending photo deletion cannot restore its removed
            // faces by replaying an old whole-document snapshot after the transaction.
            guard !self.stalePhotoDeletionFolders.contains(folderIdentity),
                  self.photoDeletionGenerations[folderIdentity, default: 0] == expectedDeletionGeneration else {
                self.stalePhotoDeletionFolders.insert(folderIdentity)
                if self.faceDataRevision == expectedRevision {
                    self.errorMessage = "Face data changed before this edit could be saved. This edit was not saved. Reload the folder and reapply the edit."
                }
                return
            }
            guard let baseline = self.durableFaceSnapshots[folderIdentity] else {
                if self.faceDataRevision == expectedRevision {
                    self.errorMessage = "Face data has no saved baseline. Reload the folder and reapply the edit."
                }
                return
            }
            let result = await service.persistWithFolderReservation(
                data,
                deletingThumbnailIDs: deletingThumbnailIDs,
                expectedSnapshot: baseline
            )
            if case .committed = result {
                self.durableFaceSnapshots[folderIdentity] = data
            }
            guard self.faceDataRevision == expectedRevision,
                  let failure = result.failureMessage else { return }
            self.errorMessage = "\(failurePrefix): \(failure)"
        }
        faceDataPersistenceTask = task
        return task
    }

    @discardableResult
    private func scheduleFaceDataDeletion(for folderURL: URL) -> Task<Void, Never> {
        let expectedRevision = faceDataRevision
        let precedingTask = faceDataPersistenceTask
        let service = folderLoadService
        let task = Task(priority: .utility) { [weak self] in
            _ = await precedingTask?.value
            let result = await service.deleteAllWithFolderReservation(for: folderURL)
            guard let self, self.faceDataRevision == expectedRevision else { return }
            if let failure = result.failureMessage {
                self.errorMessage = "Failed to delete face data: \(failure)"
            } else if case .committed = result,
                      self.displayedFolderURL == folderURL.standardizedFileURL {
                self.faceData = nil
                self.thumbnailCache.removeAllObjects()
                self.thumbnailDataByFaceID.removeAll()
                self.scanComplete = false
            }
        }
        faceDataPersistenceTask = task
        return task
    }

    private func installThumbnails(_ thumbnailData: [UUID: Data]) {
        thumbnailCache.removeAllObjects()
        thumbnailDataByFaceID = thumbnailData
        for (faceID, data) in thumbnailData {
            if let image = NSImage(data: data) {
                thumbnailCache.setObject(FaceThumbnailCacheEntry(image: image, data: data), forKey: faceID as NSUUID)
            }
        }
    }

    /// True only when the active background scan belongs to the folder represented by the face bar.
    /// A scan in another folder remains visible in Activity without taking over this folder's UI.
    func isScanning(folderURL: URL?) -> Bool {
        guard isScanning, let folderURL, let scanningFolderURL else { return false }
        return folderURL.standardizedFileURL == scanningFolderURL
    }

    // MARK: - Scan Folder

    /// Scan folder for faces with incremental support.
    /// - Parameters:
    ///   - imageURLs: All image URLs in the folder
    ///   - folderURL: The folder being scanned
    ///   - forceFullScan: If true, deletes existing data and rescans all images
    ///   - includeJerseyNumbers: Explicitly runs jersey OCR alongside a full face rescan.
    ///     The caller must confirm that existing face groups/names will be reset.
    @discardableResult
    func scanFolder(imageURLs: [URL], folderURL: URL, forceFullScan: Bool = false, includeJerseyNumbers: Bool = false,
                    retainedAuthority: MCPFaceScanAdmissionService.RetainedFolder? = nil,
                    validateNativeAuthority: @escaping @Sendable () throws -> Void = {}) -> FaceFolderScanAdmission {
        let request = FaceFolderScanRequest(imageURLs: imageURLs, folderURL: folderURL,
            forceFullScan: forceFullScan, includeJerseyNumbers: includeJerseyNumbers)
        guard !isScanning else { return .refused(.scanAlreadyRunning) }
        if let retainedAuthority {
            let prepared = retainedAuthority.prepared
            guard request.folderURL == prepared.folderURL.standardizedFileURL,
                  request.imageURLs.map(\.standardizedFileURL) == prepared.imageURLs.map(\.standardizedFileURL),
                  request.forceFullScan == prepared.forceFullScan,
                  request.includeJerseyNumbers == prepared.includeJerseyNumbers else {
                return .refused(.invalidInventory("the retained intent differs from the requested scan"))
            }
            do {
                try validateNativeAuthority()
                try retainedAuthority.validate()
                try validateNativeAuthority()
            }
            catch { return .refused(.reservationFailed(error.localizedDescription)) }
        }
        let effectAuthority: FaceDataFolderLoadService.EffectAuthority?
        if let retained = retainedAuthority {
            effectAuthority = { folder in
                guard folder.standardizedFileURL == retained.prepared.folderURL.standardizedFileURL else {
                    throw MCPFaceScanAdmissionService.Failure.staleSnapshot
                }
                try validateNativeAuthority()
                try retained.validateForEffect(folderURL: folder)
                try validateNativeAuthority()
            }
        } else {
            effectAuthority = nil
        }
        guard faceModelAvailability.isAvailable else {
            errorMessage = faceModelAvailability.detail
            return .refused(.modelUnavailable(faceModelAvailability))
        }
        guard renameQuiescenceFolderURL != request.folderURL else {
            errorMessage = FaceFolderScanRefusal.renameInProgress.message
            return .refused(.renameInProgress)
        }
        let forceFullScan = request.forceFullScan

        // The scan owns its own initial disk snapshot. Prevent an older navigation load from
        // publishing over incremental results once detection has started.
        faceDataLoadTask?.cancel()
        faceDataLoadRequestID = UUID()

        // A scan invalidates the face set the prewarm was working from.
        lensPrewarmTask?.cancel()

        var preparedConfig = detectionConfig
        preparedConfig.sportsModeEnabled = includeJerseyNumbers
        let config = preparedConfig
        let detectionService = self.detectionService
        let scanDetector = self.scanDetector
        let thumbnailRegenerator = self.thumbnailRegenerator
        let folderLoadService = self.folderLoadService
        let fileSignatureService = self.fileSignatureService
        let pendingPersistence = faceDataPersistenceTask

        isScanning = true
        isCancellingScan = false
        scanningFolderURL = folderURL.standardizedFileURL
        scanProcessedCount = 0
        scanTotalCount = imageURLs.count
        scanProgress = "0/\(imageURLs.count)"
        errorMessage = nil
        scanningGroups = []

        activeScanTask = Task(priority: .userInitiated) {
            defer { retainedAuthority?.release() }
            _ = await pendingPersistence?.value
            // Acquire off MainActor before reading or deleting the scan snapshot. The folder
            // lease excludes both helper photo reads and retained GUI writes until the exact
            // final result (including cancelled partial work) has been persisted and reloaded.
            let reservation: MCPProcessReservationLease?
            do {
                if let retainedAuthority {
                    try validateNativeAuthority()
                    try retainedAuthority.validate()
                    try validateNativeAuthority()
                    reservation = nil
                } else {
                    reservation = try await Task.detached(priority: .utility) {
                        try MCPProcessReservation.acquireFolder(folderURL)
                    }.value
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.isScanning = false
                self.isCancellingScan = false
                self.scanningFolderURL = nil
                self.scanProgress = ""
                self.scanProcessedCount = 0
                self.scanTotalCount = 0
                self.activeScanTask = nil
                return FaceScanCompletion(
                    folderURL: folderURL.standardizedFileURL,
                    outcome: .refused(.reservationFailed(error.localizedDescription))
                )
            }
            defer { reservation?.release() }

            @MainActor func refuseAuthority(_ error: any Error, reset: FaceDataDeletionResult? = nil) -> FaceScanCompletion {
                self.errorMessage = error.localizedDescription
                self.isScanning = false
                self.isCancellingScan = false
                self.scanningFolderURL = nil
                self.scanProgress = ""
                self.scanProcessedCount = 0
                self.scanTotalCount = 0
                self.activeScanTask = nil
                return FaceScanCompletion(folderURL: request.folderURL,
                    outcome: .refused(.reservationFailed(error.localizedDescription)),
                    persistenceError: error.localizedDescription, resetPersistence: reset)
            }

            // Validate the caller's whole scope before reset/pruning can discard saved results.
            let inventoryRefusal = await Task.detached(priority: .utility) {
                await fileSignatureService.validateCompleteInventory(request)
            }.value
            if let inventoryRefusal {
                self.errorMessage = inventoryRefusal.message
                self.isScanning = false
                self.isCancellingScan = false
                self.scanningFolderURL = nil
                self.scanProgress = ""
                self.scanProcessedCount = 0
                self.scanTotalCount = 0
                self.activeScanTask = nil
                return FaceScanCompletion(folderURL: request.folderURL, outcome: .refused(inventoryRefusal))
            }

            do { try effectAuthority?(folderURL) }
            catch { return refuseAuthority(error) }

            let writeCapability: FaceDataWriteCapability?
            do {
                if let effectAuthority {
                    writeCapability = try await folderLoadService.prepareWriteCapability(
                        folderURL: folderURL, effectAuthority: effectAuthority)
                } else {
                    writeCapability = nil
                }
            } catch { return refuseAuthority(error) }

            var resetPersistence: FaceDataDeletionResult?
            let initialSnapshot: FaceDataFolderLoadEvidence?
            if forceFullScan {
                // Retained reset observes cancellation between removals and returns its
                // physical prefix. Legacy native preparation keeps its detached behavior.
                let deletion: FaceDataDeletionResult
                if let writeCapability {
                    // Retained resets sample scan cancellation between physical removals.
                    deletion = await folderLoadService.deleteAll(for: folderURL,
                        effectAuthority: effectAuthority, writeCapability: writeCapability)
                } else {
                    deletion = await Task.detached(priority: .utility) {
                        await folderLoadService.deleteAll(for: folderURL, effectAuthority: effectAuthority)
                    }.value
                }
                resetPersistence = deletion
                guard deletion.deletionCompleted else {
                    // A failed reset must never authorize a fresh scan/save. Keep the snapshot
                    // available for inspection; resetPersistence retains its exact physical effects.
                    if case .anchored(let evidence) = deletion, !evidence.removedRelativePaths.isEmpty {
                        self.errorMessage = "Face reset stopped after removing \(evidence.removedRelativePaths.count) saved entries. Review the folder before retrying."
                    } else {
                        self.errorMessage = deletion.failureMessage.map {
                            "Failed to remove previous face data: \($0)"
                        } ?? "Face scan stopped before previous face data was removed."
                    }
                    self.isScanning = false
                    self.isCancellingScan = false
                    self.scanningFolderURL = nil
                    self.scanProgress = ""
                    self.scanProcessedCount = 0
                    self.scanTotalCount = 0
                    self.activeScanTask = nil
                    let resetOutcome: FaceScanCompletion.Outcome
                    if case .anchored(let evidence) = deletion, evidence.cancellationRequested,
                       evidence.failureMessage == nil {
                        resetOutcome = .cancelled
                    } else {
                        resetOutcome = .refused(.resetFailed(self.errorMessage ?? "Face scan reset failed."))
                    }
                    return FaceScanCompletion(
                        folderURL: folderURL.standardizedFileURL,
                        outcome: resetOutcome,
                        persistenceError: deletion.failureMessage,
                        resetPersistence: deletion
                    )
                }
                if self.displayedFolderURL == folderURL.standardizedFileURL {
                    self.faceData = nil
                    self.thumbnailCache.removeAllObjects()
                    self.thumbnailDataByFaceID.removeAll()
                    self.scanComplete = false
                    self.mergeSuggestions = []
                }
                initialSnapshot = nil
            } else {
                let preparation = await Task.detached(priority: .utility) {
                    await folderLoadService.load(folderURL: folderURL, cleanupPolicy: .never,
                        readOnlyRecovery: retainedAuthority != nil)
                }.value
                switch preparation {
                case .complete(let evidence):
                    initialSnapshot = evidence
                case .cancelled:
                    initialSnapshot = nil
                }
            }

            // Discard stale data if the embedding predates aligned feature prints.
            let loadedData = initialSnapshot?.faceData
            let existingData: FolderFaceData? = if let loadedData, (loadedData.embeddingVersion ?? 0) >= FaceRecognitionDefaults.embeddingVersion {
                loadedData
            } else {
                nil
            }

            // Freeze the incremental scan plan on the serialized filesystem actor. A partial
            // classification is never installed because it could discard faces whose files
            // were not reached before cancellation.
            let classificationResult = await fileSignatureService.classify(
                imageURLs: imageURLs,
                existingSignatures: existingData?.scannedFiles ?? [:]
            )
            let toScan: [URL]
            let toRemove: Set<String>
            let unchangedFiles: Set<String>
            let refreshedSignatures: [String: FileSignature]
            let classificationWasCancelled: Bool
            switch classificationResult {
            case .complete(let classification):
                toScan = classification.imageURLsToScan
                toRemove = classification.removedOrModifiedPaths
                unchangedFiles = classification.unchangedPaths
                refreshedSignatures = classification.refreshedSignatures
                classificationWasCancelled = false
            case .cancelled:
                // Keep the complete prior snapshot intact. The cancelled worker below will
                // persist it as an incomplete scan without trusting partial filesystem facts.
                toScan = []
                toRemove = []
                unchangedFiles = Set(existingData?.scannedFiles.keys.map { $0 } ?? [])
                refreshedSignatures = [:]
                classificationWasCancelled = true
            }

            // Only repair crops whose source identity is still unchanged. Retain their exact
            // face IDs and groups, even if crop generation or persistence fails again.
            let missingThumbnails = existingData?.faces.filter {
                unchangedFiles.contains($0.imageURL.path)
                    && initialSnapshot?.thumbnailData[$0.id] == nil
            } ?? []
            let missingThumbnailsByPath = Dictionary(grouping: missingThumbnails, by: { $0.imageURL.path })
            let thumbnailRepairPaths = Set(missingThumbnailsByPath.keys)
            let thumbnailRepairURLs = imageURLs.filter { thumbnailRepairPaths.contains($0.path) }

            // Start with existing faces (excluding those from removed/modified files)
            let initialFaces: [DetectedFace] = existingData?.faces.filter { face in
                classificationWasCancelled || unchangedFiles.contains(face.imageURL.path)
            } ?? []

            var initialGroups: [FaceGroup] = existingData?.groups ?? []
            var initialScannedFiles = existingData?.scannedFiles ?? [:]

            // Keep standalone jersey numbers only for unchanged files: re-scanned
            // files regenerate their own, and removed files drop out.
            let initialNumbers: [NumberDetection] = existingData?.numberDetections?.filter { number in
                classificationWasCancelled || unchangedFiles.contains(number.imageURL.path)
            } ?? []
            // Prune groups for every face dropped above, including a previous partial
            // photo whose thumbnail failure prevented it from receiving a signature.
            let removedFaceIDs = Set(existingData?.faces.filter { face in
                !classificationWasCancelled && !unchangedFiles.contains(face.imageURL.path)
            }.map(\.id) ?? [])

            // Clean up groups
            if !removedFaceIDs.isEmpty {
                for i in initialGroups.indices {
                    initialGroups[i].faceIDs.removeAll { removedFaceIDs.contains($0) }
                }
                initialGroups.removeAll { $0.faceIDs.isEmpty }

                // Update representatives
                for i in initialGroups.indices {
                    if removedFaceIDs.contains(initialGroups[i].representativeFaceID) {
                        if let newRep = initialGroups[i].faceIDs.first {
                            initialGroups[i].representativeFaceID = newRep
                        }
                    }
                }
            }

            // Remove old file signatures
            for path in toRemove {
                initialScannedFiles.removeValue(forKey: path)
            }
            // A metadata-only write (Apply, Review, another app) kept the pixels: keep the faces
            // and adopt the new date/size so the next scan does not re-check the content.
            for (path, signature) in refreshedSignatures where unchangedFiles.contains(path) {
                initialScannedFiles[path] = signature
            }

            await MainActor.run {
                self.scanTotalCount = toScan.count + thumbnailRepairURLs.count
                self.scanProgress = "0/\(toScan.count + thumbnailRepairURLs.count)"
            }

            do { try effectAuthority?(folderURL) }
            catch { return refuseAuthority(error, reset: resetPersistence) }

            if toScan.isEmpty && thumbnailRepairURLs.isEmpty && toRemove.isEmpty && refreshedSignatures.isEmpty
                && !classificationWasCancelled && existingData?.scanComplete != false {
                // Only a truly unchanged inventory can skip persistence. A removal-only
                // scan must save the pruned faces, groups, numbers and signatures below.
                reservation?.release()
                await MainActor.run {
                    self.isScanning = false
                    self.isCancellingScan = false
                    self.scanProgress = ""
                    self.scanProcessedCount = 0
                    self.scanTotalCount = 0
                    self.scanningFolderURL = nil
                    self.activeScanTask = nil
                    if self.displayedFolderURL == folderURL.standardizedFileURL {
                        self.scanComplete = true
                    }
                    if let existingData,
                       self.displayedFolderURL == folderURL.standardizedFileURL {
                        self.photoDeletionGenerations[folderURL.standardizedFileURL.path, default: 0] &+= 1
                        self.durableFaceSnapshots[folderURL.standardizedFileURL.path] = existingData
                        self.faceData = existingData
                        self.installThumbnails(initialSnapshot?.thumbnailData ?? [:])
                        if retainedAuthority == nil { self.updateMergeSuggestions() }
                    }
                }
                return FaceScanCompletion(
                    folderURL: folderURL.standardizedFileURL,
                    outcome: .unchanged,
                    unsignedFileCount: imageURLs.filter { existingData?.scannedFiles[$0.path] == nil }.count
                )
            }

            let scanLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FaceRecognitionViewModel")
            let reportSaveError: @MainActor @Sendable (String) -> Void = { [self] message in
                self.errorMessage = message
            }
            let reportGroups: @MainActor @Sendable ([FaceGroup]) -> Void = { [self] groups in
                do { try effectAuthority?(folderURL) } catch { return }
                self.scanningGroups = groups
            }
            let reportProgress: @MainActor @Sendable (Int, String) -> Void = { [self] count, progress in
                self.scanProcessedCount = count
                self.scanProgress = progress
            }
            let reportThumbnail: @MainActor @Sendable (UUID, Data) -> Void = { [self] faceID, data in
                do { try effectAuthority?(folderURL) } catch { return }
                guard self.displayedFolderURL == folderURL.standardizedFileURL,
                      let image = NSImage(data: data) else { return }
                self.thumbnailDataByFaceID[faceID] = data
                self.thumbnailCache.setObject(FaceThumbnailCacheEntry(image: image, data: data), forKey: faceID as NSUUID)
            }

            // Keep detection, disk writes, and clustering off the main actor. `Task {}` inherits
            // this view model's MainActor isolation; without this worker the increasingly costly
            // clustering pass competes directly with folder navigation and SwiftUI updates.
            let worker = Task.detached(priority: .utility) {
                await withTaskGroup(
                    of: (URL, FaceDetectionService.DetectionResult, Bool).self
                ) { taskGroup -> FaceScanWorkerResult in
                var allFaces = initialFaces
                var allGroups = initialGroups
                var scannedFiles = initialScannedFiles
                var allNumbers = initialNumbers
                var processed = 0
                var detectionErrors = 0
                var thumbnailFailureCount = 0
                var cancelledThumbnailCount = 0
                var thumbnailPersistenceError: String?
                var committedThumbnailIDs: [UUID] = []
                var documentPersistenceResults: [FaceDataPersistenceResult] = []
                var incompleteThumbnailPaths = thumbnailRepairPaths
                var imagesSinceLastSave = 0
                var imagesSinceLastCluster = 0
                var pendingFaces: [DetectedFace] = []
                var faceIndexByID = Dictionary(uniqueKeysWithValues: allFaces.enumerated().map { ($1.id, $0) })
                let saveInterval = 10
                // Cluster one completion wave at a time instead of rebuilding the all-face lookup
                // and walking every group after every image.
                let clusteringImageBatchSize = 4

                // Clustering runs incrementally per batch and matches each batch's new
                // faces against every existing group, deserializing those members'
                // feature prints (NSKeyedUnarchiver) on the way. Share one cache across
                // all batches so each face's feature print is unarchived once for the
                // whole scan instead of re-unarchived on every subsequent batch — without
                // this the per-batch work grows with the running face count (≈O(N²) total
                // unarchives over a scan). FeaturePrintCache is thread-safe.
                let visionFeaturePrintCache = FaceDetectionService.FeaturePrintCache()

                func flushPendingClustering() {
                    guard !pendingFaces.isEmpty else {
                        imagesSinceLastCluster = 0
                        return
                    }
                    let pendingIDs = Set(pendingFaces.map(\.id))
                    allGroups = detectionService.clusterFacesWithAlgorithm(
                        pendingFaces,
                        allFaces: allFaces,
                        existingGroups: allGroups,
                        config: config,
                        cache: visionFeaturePrintCache
                    )

                    for group in allGroups {
                        for faceID in group.faceIDs where pendingIDs.contains(faceID) {
                            if let index = faceIndexByID[faceID] {
                                allFaces[index].groupID = group.id
                            }
                        }
                    }
                    pendingFaces.removeAll(keepingCapacity: true)
                    imagesSinceLastCluster = 0
                }

                // Ingest a completed image. Expensive clustering is coalesced separately.
                func processImage(scannedURL: URL, detection: FaceDetectionService.DetectionResult, failed: Bool) async {
                    do { try effectAuthority?(folderURL) }
                    catch {
                        detectionErrors += 1
                        thumbnailPersistenceError = thumbnailPersistenceError ?? error.localizedDescription
                        return
                    }
                    var imageFailed = failed
                    allNumbers.append(contentsOf: detection.standaloneNumbers)

                    for result in detection.faces {
                        let thumbnailPersistence = await folderLoadService.persistThumbnail(
                            result.thumbnail,
                            faceID: result.face.id,
                            folderURL: folderURL,
                            effectAuthority: effectAuthority,
                            writeCapability: writeCapability
                        )
                        switch thumbnailPersistence {
                        case .committed:
                            committedThumbnailIDs.append(result.face.id)
                            // Only retain faces whose thumbnails were durably installed.
                            faceIndexByID[result.face.id] = allFaces.count
                            allFaces.append(result.face)
                            pendingFaces.append(result.face)
                            await reportThumbnail(result.face.id, result.thumbnail)
                        case .committedButUnverified(let faceID, let message, _):
                            committedThumbnailIDs.append(faceID)
                            thumbnailFailureCount += 1
                            thumbnailPersistenceError = thumbnailPersistenceError ?? message
                            imageFailed = true
                        case .cancelledBeforeCommit:
                            cancelledThumbnailCount += 1
                            imageFailed = true
                        case .failed(_, let message):
                            thumbnailFailureCount += 1
                            thumbnailPersistenceError = thumbnailPersistenceError ?? message
                            imageFailed = true
                            scanLogger.warning("Failed to save thumbnail for face \(result.face.id): \(message)")
                        }
                    }

                    if imageFailed { detectionErrors += 1 }
                    imagesSinceLastCluster += 1
                    if imagesSinceLastCluster >= clusteringImageBatchSize {
                        flushPendingClustering()
                    }

                    // A failed image must remain eligible for the next incremental scan.
                    if !imageFailed {
                        switch await fileSignatureService.signature(for: scannedURL) {
                        case .captured(let imageURL, let signature?):
                            scannedFiles[imageURL.path] = signature
                        case .captured(_, nil), .cancelled:
                            break
                        }
                    }

                    processed += 1
                    imagesSinceLastSave += 1

                    // Periodic save to preserve progress and update live UI
                    if imagesSinceLastSave >= saveInterval {
                        flushPendingClustering()
                        let progressData = FolderFaceData(
                            folderURL: folderURL,
                            faces: allFaces,
                            groups: allGroups,
                            lastScanDate: Date(),
                            scanComplete: false,
                            scannedFiles: scannedFiles,
                            embeddingVersion: FaceRecognitionDefaults.embeddingVersion,
                            numberDetections: allNumbers
                        )
                        let persistence = await folderLoadService.persist(progressData, effectAuthority: effectAuthority, writeCapability: writeCapability)
                        documentPersistenceResults.append(persistence)
                        if let failure = persistence.failureMessage {
                            await reportSaveError("Failed to save face data: \(failure)")
                        }
                        imagesSinceLastSave = 0

                        // Update intermediate UI state for live face bar
                        let groupsSnapshot = allGroups
                        await reportGroups(groupsSnapshot)
                    }

                    let current = processed
                    let total = toScan.count + thumbnailRepairURLs.count
                    let errors = detectionErrors
                    let progress = errors > 0 ? "\(current)/\(total) (\(errors) failed)" : "\(current)/\(total)"
                    await reportProgress(current, progress)
                }

                // Repair inherited crops first. A failed repair leaves the source signature as
                // identity evidence and an incomplete document, so retry preserves manual groups.
                for url in thumbnailRepairURLs {
                    guard !Task.isCancelled else { break }
                    var repairFailed = false
                    for face in missingThumbnailsByPath[url.path] ?? [] {
                        guard !Task.isCancelled else {
                            cancelledThumbnailCount += 1
                            repairFailed = true
                            break
                        }
                        do {
                            try effectAuthority?(folderURL)
                            let bytes: Data
                            if let thumbnailRegenerator {
                                bytes = try await thumbnailRegenerator(face)
                            } else {
                                bytes = try detectionService.regenerateThumbnail(for: face)
                            }
                            switch await folderLoadService.persistThumbnail(bytes, faceID: face.id, folderURL: folderURL,
                                effectAuthority: effectAuthority, writeCapability: writeCapability) {
                            case .committed:
                                committedThumbnailIDs.append(face.id)
                                await reportThumbnail(face.id, bytes)
                            case .committedButUnverified(let faceID, let message, _):
                                committedThumbnailIDs.append(faceID)
                                thumbnailFailureCount += 1
                                thumbnailPersistenceError = thumbnailPersistenceError ?? message
                                repairFailed = true
                            case .cancelledBeforeCommit:
                                cancelledThumbnailCount += 1
                                repairFailed = true
                            case .failed(_, let message):
                                thumbnailFailureCount += 1
                                thumbnailPersistenceError = thumbnailPersistenceError ?? message
                                repairFailed = true
                            }
                        } catch is CancellationError {
                            cancelledThumbnailCount += 1
                            repairFailed = true
                        } catch {
                            thumbnailFailureCount += 1
                            thumbnailPersistenceError = thumbnailPersistenceError ?? error.localizedDescription
                            repairFailed = true
                        }
                    }
                    if !repairFailed && !Task.isCancelled {
                        switch await fileSignatureService.signature(for: url) {
                        case .captured(_, let signature?) where scannedFiles[url.path].map(signature.hasSameFileFacts(as:)) == true:
                            incompleteThumbnailPaths.remove(url.path)
                        default:
                            // Source drift invalidates retained detection authority on the next retry.
                            scannedFiles.removeValue(forKey: url.path)
                            repairFailed = true
                        }
                    }
                    if repairFailed { detectionErrors += 1 }
                    processed += 1
                    await reportProgress(processed, "\(processed)/\(toScan.count + thumbnailRepairURLs.count)")
                }

                // Process images concurrently, capped at 4
                var pending = 0

                for url in toScan {
                    do { try effectAuthority?(folderURL) }
                    catch {
                        thumbnailPersistenceError = thumbnailPersistenceError ?? error.localizedDescription
                        detectionErrors += 1
                        taskGroup.cancelAll()
                        break
                    }
                    if Task.isCancelled {
                        taskGroup.cancelAll()
                        break
                    }

                    if pending >= 4 {
                        if let (scannedURL, detection, failed) = await taskGroup.next() {
                            await processImage(scannedURL: scannedURL, detection: detection, failed: failed)
                        }
                        pending -= 1
                    }

                    taskGroup.addTask(priority: .utility) {
                        do {
                            try effectAuthority?(folderURL)
                            let detection: FaceDetectionService.DetectionResult
                            if let scanDetector {
                                detection = try await scanDetector(url, config)
                            } else {
                                detection = try await detectionService.detectFaces(in: url, config: config)
                            }
                            try effectAuthority?(folderURL)
                            return (url, detection, false)
                        } catch {
                            scanLogger.warning("Face detection failed for \(url.lastPathComponent): \(error.localizedDescription)")
                            return (url, FaceDetectionService.DetectionResult(faces: []), true)
                        }
                    }
                    pending += 1
                }

                // Collect remaining
                for await (scannedURL, detection, failed) in taskGroup {
                    await processImage(scannedURL: scannedURL, detection: detection, failed: failed)
                }

                flushPendingClustering()
                return FaceScanWorkerResult(
                    faces: allFaces,
                    groups: allGroups,
                    scannedFiles: scannedFiles,
                    numbers: allNumbers,
                    processedCount: processed,
                    failureCount: detectionErrors,
                    thumbnailFailureCount: thumbnailFailureCount,
                    cancelledThumbnailCount: cancelledThumbnailCount,
                    thumbnailPersistenceError: thumbnailPersistenceError,
                    incompleteThumbnailPaths: incompleteThumbnailPaths,
                    committedThumbnailIDs: committedThumbnailIDs,
                    documentPersistenceResults: documentPersistenceResults
                )
                }
            }
            self.activeScanWorkerTask = worker
            // Cancellation can land while incremental file categorisation is still running,
            // before the worker exists. Propagate that already-set parent state immediately.
            if Task.isCancelled {
                worker.cancel()
            }
            let result = await worker.value
            self.activeScanWorkerTask = nil

            let isCancelled = Task.isCancelled
            let unsignedFileCount = imageURLs.filter { result.scannedFiles[$0.path] == nil
                || result.incompleteThumbnailPaths.contains($0.path) }.count
            let scanSucceeded = !isCancelled && result.failureCount == 0 && unsignedFileCount == 0

            let folderData = FolderFaceData(
                folderURL: folderURL,
                faces: result.faces,
                groups: result.groups,
                lastScanDate: Date(),
                scanComplete: scanSucceeded,
                scannedFiles: result.scannedFiles,
                embeddingVersion: FaceRecognitionDefaults.embeddingVersion,
                numberDetections: result.numbers
            )

            // A cancelled scan must still durably preserve its exact partial result. Detaching
            // prevents the persistence service from treating the parent cancellation as a
            // pre-commit cancellation request.
            let finalPersistence = await Task.detached(priority: .utility) {
                await folderLoadService.persist(folderData, effectAuthority: effectAuthority, writeCapability: writeCapability)
            }.value
            // A detached child is intentional here: a cancelled scan still saves and presents
            // its exact partial result, so its just-committed thumbnails must be loaded even
            // though the parent scan task carries cancellation.
            let thumbnailRefresh = await Task.detached(priority: .utility) {
                do { try effectAuthority?(folderURL) }
                catch {
                    return FaceDataFolderLoadResult.cancelled(CancelledFaceDataFolderLoadEvidence(
                        folderURL: folderURL.standardizedFileURL, requestedThumbnailCount: 0, processedThumbnailCount: 0))
                }
                let loaded = await folderLoadService.load(folderURL: folderURL, cleanupPolicy: .never,
                    readOnlyRecovery: retainedAuthority != nil)
                do { try effectAuthority?(folderURL) }
                catch {
                    return .cancelled(CancelledFaceDataFolderLoadEvidence(
                        folderURL: folderURL.standardizedFileURL, requestedThumbnailCount: 0, processedThumbnailCount: 0))
                }
                return loaded
            }.value
            let refreshedThumbnailData: [UUID: Data]
            switch thumbnailRefresh {
            case .complete(let evidence):
                refreshedThumbnailData = evidence.thumbnailData
            case .cancelled:
                refreshedThumbnailData = [:]
            }

            let presentationAuthorityError: String?
            do { try effectAuthority?(folderURL); presentationAuthorityError = nil }
            catch { presentationAuthorityError = error.localizedDescription }
            let finalPersistenceError = finalPersistence.failureMessage ?? presentationAuthorityError
            let persistenceError = [result.thumbnailPersistenceError, finalPersistenceError]
                .compactMap { $0 }.joined(separator: "; ")
            let completionPersistenceError = persistenceError.isEmpty ? nil : persistenceError
            if let completionPersistenceError {
                self.errorMessage = "Failed to save face scan results: \(completionPersistenceError)"
            }

            reservation?.release()
            await MainActor.run {
                self.photoDeletionGenerations[folderURL.standardizedFileURL.path, default: 0] &+= 1
                if case .complete(let evidence) = thumbnailRefresh,
                   retainedAuthority == nil || completionPersistenceError == nil {
                    self.durableFaceSnapshots[folderURL.standardizedFileURL.path] = evidence.faceData
                }
                let isDisplayedFolder = self.displayedFolderURL == folderURL.standardizedFileURL
                if isDisplayedFolder, retainedAuthority == nil || completionPersistenceError == nil {
                    self.faceData = folderData
                    self.scanComplete = scanSucceeded && finalPersistenceError == nil
                    if !refreshedThumbnailData.isEmpty || folderData.faces.isEmpty {
                        self.installThumbnails(refreshedThumbnailData)
                    }
                    if retainedAuthority == nil { self.updateMergeSuggestions() }

                    // Sports mode: resolve detected numbers → player names (or surface
                    // the colour-mapping confirmation if not yet confirmed).
                    if config.sportsModeEnabled, retainedAuthority == nil {
                        self.scheduleMatchRosterLoad(for: folderURL, resolveAfterLoad: true)
                    }
                } else if retainedAuthority == nil {
                    self.deferredPostprocessingFolders.insert(folderURL.standardizedFileURL)
                }
                self.isScanning = false
                self.isCancellingScan = false
                self.scanProgress = ""
                self.scanProcessedCount = 0
                self.scanTotalCount = 0
                self.scanningFolderURL = nil
                self.scanningGroups = []
                self.activeScanTask = nil
                self.replayDeferredFaceUpdates()

                let succeeded = max(0, result.processedCount - result.failureCount)
                self.activityHistory?.record(ActivityEntry(
                    kind: .faceScan,
                    date: Date(),
                    title: folderURL.lastPathComponent,
                    successCount: succeeded,
                    totalCount: toScan.count + thumbnailRepairURLs.count,
                    wasCancelled: isCancelled,
                    persistenceError: completionPersistenceError,
                    files: []
                ))
            }

            if retainedAuthority == nil, !isCancelled, completionPersistenceError == nil,
               self.displayedFolderURL == folderURL.standardizedFileURL {
                // Known People matching is always automatic now. `applyKnownPeopleMatches`
                // no-ops when the database is empty, so this is safe to always call.
                await self.matchKnownPeopleIntegrated()

                // Face results are live; compute the secondary lenses in the background.
                self.prewarmSecondaryLensesIfNeeded()
            }

            return FaceScanCompletion(
                folderURL: folderURL.standardizedFileURL,
                outcome: isCancelled ? .cancelled : (scanSucceeded ? .completed : .partial),
                processedCount: result.processedCount,
                failureCount: result.failureCount,
                unsignedFileCount: unsignedFileCount,
                thumbnailFailureCount: result.thumbnailFailureCount,
                cancelledThumbnailCount: result.cancelledThumbnailCount,
                persistenceError: completionPersistenceError,
                committedThumbnailIDs: result.committedThumbnailIDs,
                documentPersistenceResults: result.documentPersistenceResults + [finalPersistence],
                resetPersistence: resetPersistence
            )
        }
        return .scheduled(request)
    }

    /// Internal native bridge only. The caller must separately establish consent and
    /// operation retention; this capability advertises no helper execution permission.
    func scheduleRetainedFolderScan(intents: MCPFaceScanIntentStore, id: UUID,
                                   validateNativeAuthority: @escaping @Sendable () throws -> Void = {}) throws -> FaceFolderScanSubmission {
        try scheduleRetainedFolderScan(retained: intents.retain(id: id), validateNativeAuthority: validateNativeAuthority)
    }

    /// Takes the exact capability acquired before durable admission. No intent lookup
    /// or recapture can reopen review once the durable record has been admitted.
    func scheduleRetainedFolderScan(retained: MCPFaceScanAdmissionService.RetainedFolder,
                                   validateNativeAuthority: @escaping @Sendable () throws -> Void = {}) -> FaceFolderScanSubmission {
        let prepared = retained.prepared
        let admission = scanFolder(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL,
            forceFullScan: prepared.forceFullScan, includeJerseyNumbers: prepared.includeJerseyNumbers,
            retainedAuthority: retained, validateNativeAuthority: validateNativeAuthority)
        if case .scheduled = admission {
            return FaceFolderScanSubmission(admission: admission, task: activeScanTask)
        }
        retained.release()
        return FaceFolderScanSubmission(admission: admission, task: nil)
    }

    /// Captures scheduling and its exact task without yielding the MainActor. Callers that
    /// need durable completion evidence must retain this handle rather than read the active
    /// slot later; fast refusals and completed scans clear that slot.
    func scheduleFolderScan(imageURLs: [URL], folderURL: URL, forceFullScan: Bool = false,
                            includeJerseyNumbers: Bool = false) -> FaceFolderScanSubmission {
        let admission = scanFolder(imageURLs: imageURLs, folderURL: folderURL,
            forceFullScan: forceFullScan, includeJerseyNumbers: includeJerseyNumbers)
        let task: Task<FaceScanCompletion, Never>?
        if case .scheduled = admission { task = activeScanTask } else { task = nil }
        return FaceFolderScanSubmission(admission: admission, task: task)
    }

    /// Suspends until the scan that was active when this method was called finishes.
    /// Useful to coordinate navigation and deterministic tests without guessing a
    /// wall-clock duration for Vision work under system load.
    @discardableResult
    func waitForCurrentScan() async -> FaceScanCompletion? {
        let task = activeScanTask
        return await task?.value
    }

    /// Cancels only the scan currently writing the requested folder and waits for that exact
    /// task's final persistence before returning. The caller may safely mutate image paths only
    /// after this method succeeds.
    func quiesceScanForRename(in folderURL: URL) async throws {
        let normalizedFolder = folderURL.standardizedFileURL
        renameQuiescenceFolderURL = normalizedFolder
        if isScanning(folderURL: normalizedFolder), let task = activeScanTask {
            cancelScan()
            let completion = await task.value
            if isScanning(folderURL: normalizedFolder) {
                renameQuiescenceFolderURL = nil
                throw FaceScanQuiescenceError.replacementScanStarted
            }
            if completion.folderURL == normalizedFolder,
               let persistenceError = completion.persistenceError {
                renameQuiescenceFolderURL = nil
                throw FaceScanQuiescenceError.persistenceFailed(persistenceError)
            }
        }

        // Secondary-lens prewarming can also persist the folder's face document after a scan.
        // Drain it under the same reservation so no delayed face-data writer survives the barrier.
        if faceData?.folderURL.standardizedFileURL == normalizedFolder {
            let prewarm = lensPrewarmTask
            prewarm?.cancel()
            await prewarm?.value
        }

        // Face-name propagation writes the image and/or its XMP sidecar. Finish the task that
        // existed when the reservation was acquired; new starts are refused while reserved.
        let pendingMetadataWrite = metadataWriteTask
        await pendingMetadataWrite?.value
    }

    func endRenameQuiescence(in folderURL: URL) {
        guard renameQuiescenceFolderURL == folderURL.standardizedFileURL else { return }
        renameQuiescenceFolderURL = nil
    }

    func cancelScan() {
        guard isScanning, !isCancellingScan else { return }
        isCancellingScan = true
        scanProgress = "Cancelling…"
        activeScanTask?.cancel()
        activeScanWorkerTask?.cancel()
    }

    // MARK: - Known People Matching

    /// Match unnamed face groups against the Known People database.
    /// Automatically names groups that match known people.
    /// If multiple groups match the same known person, they are merged together.
    /// Also records matches in knownPersonMatchByGroup for the "Replace Thumbnail" feature.
    private func applyKnownPeopleMatches() {
        guard var data = faceData else { return }

        let stats = KnownPeopleService.shared.getStatistics()
        guard stats.peopleCount > 0 else { return }

        // Batch-match all unnamed groups at once (single DB load)
        let unnamedGroups = data.groups.filter { $0.name == nil && !$0.isExcludedFromPersonShown }
        let facesToMatch = unnamedGroups.compactMap { group -> (id: UUID, featurePrintData: Data)? in
            guard let face = faceLookup[group.representativeFaceID] else { return nil }
            return (id: group.id, featurePrintData: face.featurePrintData)
        }

        let batchMatches = KnownPeopleService.shared.bestAutoMatches(facesToMatch)

        // Build a map: knownPersonID -> [groupIDs that matched this person]
        var matchesByPerson: [UUID: [(groupID: UUID, confidence: Float)]] = [:]

        for (groupID, bestMatch) in batchMatches {
            knownPersonMatchByGroup[groupID] = (personID: bestMatch.person.id, confidence: bestMatch.confidence)

            if matchesByPerson[bestMatch.person.id] == nil {
                matchesByPerson[bestMatch.person.id] = []
            }
            matchesByPerson[bestMatch.person.id]?.append((groupID: groupID, confidence: bestMatch.confidence))
        }

        // For each known person with matches, merge multiple groups and name them
        // Index dicts are stable because removals are deferred to after the loop
        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)
        var groupIDsToRemove: Set<UUID> = []

        for (personID, groupMatches) in matchesByPerson {
            guard let knownPerson = KnownPeopleService.shared.person(byID: personID) else { continue }

            // Sort by confidence (highest first) - the best match becomes the target
            let sorted = groupMatches.sorted { $0.confidence > $1.confidence }
            guard let bestMatch = sorted.first else { continue }
            let targetGroupID = bestMatch.groupID
            guard let targetIndex = groupIdx[targetGroupID] else { continue }

            // Name the target group
            data.groups[targetIndex].name = knownPerson.name
            data.groups[targetIndex].knownPersonID = personID

            // Merge other matching groups into the target
            for match in sorted.dropFirst() {
                guard let sourceIndex = groupIdx[match.groupID],
                      sourceIndex != targetIndex else { continue }

                // Move faces from source to target
                let sourceFaceIDs = data.groups[sourceIndex].faceIDs
                data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)
                data.groups[targetIndex].inheritAppliedName(from: data.groups[sourceIndex])

                // Update face groupIDs
                for faceID in sourceFaceIDs {
                    if let fi = faceIdx[faceID] {
                        data.faces[fi].groupID = targetGroupID
                    }
                }

                // Update match tracking to point to merged group
                knownPersonMatchByGroup[match.groupID] = nil
                knownPersonMatchByGroup[targetGroupID] = (personID: personID, confidence: bestMatch.confidence)

                groupIDsToRemove.insert(match.groupID)
            }
        }

        // Remove all merged source groups in one pass
        data.groups.removeAll { groupIDsToRemove.contains($0.id) }

        // Save updated data
        commitFaceEdit(data, reportsScanRefusal: false)
    }

    /// Runs Known People matching after scan completes (async wrapper for use in scan task).
    private func matchKnownPeopleIntegrated() async {
        applyKnownPeopleMatches()
    }

    func matchKnownPeople() {
        applyKnownPeopleMatches()
    }

    /// Select up to `maxSamples` faces from a group for Known People matching.
    /// Prioritizes higher quality faces. Always includes the representative face.
    func sampleFaces(from group: FaceGroup, maxSamples: Int = 5) -> [DetectedFace] {
        let allFaces = faces(in: group)
        guard allFaces.count > maxSamples else { return allFaces }

        var sorted = allFaces.sorted { ($0.qualityScore ?? 0) > ($1.qualityScore ?? 0) }

        // Ensure representative face is included
        if let repIndex = sorted.firstIndex(where: { $0.id == group.representativeFaceID }), repIndex >= maxSamples {
            sorted.swapAt(0, repIndex)
        }

        return Array(sorted.prefix(maxSamples))
    }

    /// Check unnamed groups against Known People database.
    /// Produces both auto-matches (applied immediately) and suggestions (for user review).
    func checkKnownPeopleWithSuggestions(maxSamplesPerGroup: Int = 5) -> KnownPeopleCheckResult {
        guard faceData != nil else {
            return KnownPeopleCheckResult(autoMatchCount: 0, suggestionCount: 0, noMatchCount: 0, totalChecked: 0)
        }

        let policy = KnownPeopleService.shared.currentAutoMatchPolicy()
        let suggestionMinConfidence: Float = max(policy.minConfidence - 0.15, 0.40)

        let groupsToCheck = unnamedGroups.filter { !$0.isExcludedFromPersonShown }
        guard !groupsToCheck.isEmpty else {
            return KnownPeopleCheckResult(autoMatchCount: 0, suggestionCount: 0, noMatchCount: 0, totalChecked: 0)
        }

        // Build input: sample multiple faces per group
        let groupInputs: [(groupID: UUID, faceEmbeddings: [(faceID: UUID, featurePrintData: Data)])] =
            groupsToCheck.compactMap { group in
                let sampled = sampleFaces(from: group, maxSamples: maxSamplesPerGroup)
                guard !sampled.isEmpty else { return nil }
                let embeddings = sampled.map { (faceID: $0.id, featurePrintData: $0.featurePrintData) }
                return (groupID: group.id, faceEmbeddings: embeddings)
            }

        // Build lookup for sampled face counts per group (avoids O(N) scan in the loop below)
        let sampledCountByGroup = Dictionary(uniqueKeysWithValues: groupInputs.map { ($0.groupID, $0.faceEmbeddings.count) })

        // Batch match all groups
        let allMatches = KnownPeopleService.shared.matchGroupsForSuggestions(groups: groupInputs)

        var autoMatchCount = 0
        var suggestionCount = 0
        var noMatchCount = 0
        var newSuggestions: [KnownPersonSuggestion] = []
        var lastAutoMatchedGroupID: UUID?

        for group in groupsToCheck {
            guard let matches = allMatches[group.id], let best = matches.first else {
                noMatchCount += 1
                continue
            }

            // Check if best match passes the strict auto-match policy
            let passesAutoMatch: Bool
            if best.match.confidence >= policy.minConfidence {
                if matches.count >= 2 {
                    passesAutoMatch = (best.match.confidence - matches[1].match.confidence) >= policy.minConfidenceGap
                } else {
                    passesAutoMatch = true
                }
            } else {
                passesAutoMatch = false
            }

            if passesAutoMatch {
                nameGroup(group.id, name: best.match.person.name, knownPersonID: best.match.person.id)
                knownPersonMatchByGroup[group.id] = (personID: best.match.person.id, confidence: best.match.confidence)
                lastAutoMatchedGroupID = group.id
                autoMatchCount += 1
            } else if best.match.confidence >= suggestionMinConfidence {
                let sampledCount = sampledCountByGroup[group.id] ?? 1
                newSuggestions.append(KnownPersonSuggestion(
                    groupID: group.id,
                    personID: best.match.person.id,
                    personName: best.match.person.name,
                    confidence: best.match.confidence,
                    sampledFaceCount: sampledCount,
                    matchedFaceCount: best.matchedFaceCount
                ))
                suggestionCount += 1
            } else {
                noMatchCount += 1
            }
        }

        knownPersonSuggestions = newSuggestions

        let result = KnownPeopleCheckResult(
            autoMatchCount: autoMatchCount,
            suggestionCount: suggestionCount,
            noMatchCount: noMatchCount,
            totalChecked: groupsToCheck.count
        )
        lastKnownPeopleCheckResult = result

        if lastAutoMatchedGroupID != nil {
            selectGroupForThumbnailReplacement(lastAutoMatchedGroupID)
        }

        return result
    }

    func acceptKnownPersonSuggestion(_ suggestion: KnownPersonSuggestion) {
        nameGroup(suggestion.groupID, name: suggestion.personName, knownPersonID: suggestion.personID)
        knownPersonMatchByGroup[suggestion.groupID] = (personID: suggestion.personID, confidence: suggestion.confidence)
        knownPersonSuggestions.removeAll { $0.id == suggestion.id }
        selectGroupForThumbnailReplacement(suggestion.groupID)
    }

    func dismissKnownPersonSuggestion(_ suggestion: KnownPersonSuggestion) {
        knownPersonSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// Match a specific group against Known People and track the match.
    /// Returns the matched person ID if found.
    @discardableResult
    func matchGroupToKnownPeople(_ groupID: UUID) -> UUID? {
        guard faceData != nil,
              let group = groupLookup[groupID],
              let face = faceLookup[group.representativeFaceID] else {
            return nil
        }

        if let bestMatch = KnownPeopleService.shared.bestAutoMatch(
            featurePrintData: face.featurePrintData
        ) {
            // Record the match for "Replace Thumbnail" feature
            knownPersonMatchByGroup[groupID] = (personID: bestMatch.person.id, confidence: bestMatch.confidence)
            return bestMatch.person.id
        }

        return nil
    }

    private func normalizePersonName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizePersonName(lhs).caseInsensitiveCompare(normalizePersonName(rhs)) == .orderedSame
    }

    private func nameMatchesKnownPerson(groupID: UUID, name: String) -> Bool {
        guard let match = knownPersonMatchByGroup[groupID],
              let person = KnownPeopleService.shared.person(byID: match.personID) else {
            return false
        }
        return namesMatch(name, person.name)
    }

    func groupNameMatchesKnownPerson(_ groupID: UUID) -> Bool {
        guard let group = group(byID: groupID),
              let groupName = group.name else {
            return false
        }
        return nameMatchesKnownPerson(groupID: groupID, name: groupName)
    }

    func shouldAllowFaceMatchForKnownPeopleAdd(groupID: UUID, name: String) -> Bool {
        return nameMatchesKnownPerson(groupID: groupID, name: name)
    }

    /// Add a face group to the Known People database.
    /// Collects embeddings, extracts a thumbnail, checks for duplicates, and calls addOrMergePerson.
    func addGroupToKnownPeople(groupID: UUID, name: String) async throws -> AddToKnownPeopleResult {
        guard let group = group(byID: groupID) else {
            throw AddToKnownPeopleError.groupNotFound
        }

        let faces = faces(in: group)
        guard !faces.isEmpty else {
            throw AddToKnownPeopleError.noFaces
        }

        let embeddings = faces.map { PersonEmbedding(detectedFace: $0) }

        let expectedRevision = faceDataRevision
        let expectedFolder = displayedFolderURL
        let sourceThumbnails = Dictionary(uniqueKeysWithValues: faces.enumerated().compactMap { index, face in
            thumbnailDataByFaceID[face.id].map { (embeddings[index].id, $0) }
        })
        let representativeData = thumbnailDataByFaceID[group.representativeFaceID]
        let prepared = try await KnownPeopleAdditionThumbnailService.shared.prepare(
            embeddingSources: sourceThumbnails, representativeSource: representativeData
        )
        let upgradeSources: [UUID: Data]
        if AppDefaults.store.bool(forKey: UserDefaultsKeys.knownPeopleRetainUpgradeSources) {
            let cropInputs = zip(faces, embeddings).map { face, embedding in
                KnownPeopleUpgradeCropSource(embeddingID: embedding.id,
                    imageURL: face.imageURL, faceRect: face.faceRect)
            }
            upgradeSources = try await KnownPeopleAdditionThumbnailService.shared
                .prepareUpgradeSources(cropInputs)
        } else {
            upgradeSources = [:]
        }
        try Task.checkCancellation()
        guard faceDataRevision == expectedRevision, displayedFolderURL == expectedFolder else {
            throw CancellationError()
        }

        let representativeFace = faces.first { $0.id == group.representativeFaceID } ?? faces.first
        let duplicateCheck: KnownPeopleService.DuplicateCheckResult
        if let repFace = representativeFace {
            let allowFaceMatch = shouldAllowFaceMatchForKnownPeopleAdd(groupID: groupID, name: name)
            duplicateCheck = KnownPeopleService.shared.checkForDuplicate(
                name: name,
                representativeFaceData: repFace.featurePrintData,
                allowFaceMatch: allowFaceMatch
            )
        } else {
            duplicateCheck = .noDuplicate
        }

        let person: KnownPerson
        let addedToExisting: Bool
        do {
            (person, addedToExisting) = try await KnownPeopleService.shared.addOrMergePerson(
                name: name,
                embeddings: embeddings,
                thumbnailData: prepared.representative,
                embeddingThumbnails: prepared.embeddings,
                upgradeSources: upgradeSources,
                duplicateCheck: duplicateCheck
            )
        } catch {
            guard !Task.isCancelled, faceDataRevision == expectedRevision,
                  displayedFolderURL == expectedFolder else { throw CancellationError() }
            throw error
        }

        // A completed durable write survives navigation, but its result must not update
        // a different folder or a group that changed while storage was suspended.
        try Task.checkCancellation()
        guard faceDataRevision == expectedRevision, displayedFolderURL == expectedFolder else {
            throw CancellationError()
        }

        return AddToKnownPeopleResult(
            addedToExisting: addedToExisting,
            embeddingCount: embeddings.count,
            name: name,
            personID: person.id
        )
    }

    /// Select a group for thumbnail replacement. Only shows in suggestions panel if the group
    /// is named and has a known person match.
    func selectGroupForThumbnailReplacement(_ groupID: UUID?, faceID: UUID? = nil) {
        guard let groupID,
              let group = group(byID: groupID),
              group.name != nil,
              groupNameMatchesKnownPerson(groupID) else {
            selectedThumbnailReplacementGroupID = nil
            selectedThumbnailReplacementFaceID = nil
            return
        }
        selectedThumbnailReplacementGroupID = groupID
        if let faceID, group.faceIDs.contains(faceID) {
            selectedThumbnailReplacementFaceID = faceID
        } else {
            selectedThumbnailReplacementFaceID = group.representativeFaceID
        }
    }

    /// Clear the thumbnail replacement selection (e.g., after replacing or dismissing)
    func clearThumbnailReplacementSelection() {
        selectedThumbnailReplacementGroupID = nil
        selectedThumbnailReplacementFaceID = nil
    }

    // MARK: - Merge Suggestions

    /// Recompute the Face-lens merge suggestions. The all-pairs group comparison is O(groups²
    /// × faces²) cosine work, so it runs off-main (it fires at the end of every scan and on
    /// lens switch); suggestions land asynchronously on the MainActor.
    func updateMergeSuggestions() {
        guard let data = faceData else {
            mergeSuggestions = []
            return
        }

        let groups = data.groups
        let faces = data.faces
        let folderURL = data.folderURL
        let threshold = detectionConfig.clusteringThreshold
        let service = detectionService
        let cache = mergeFeaturePrintCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let suggestions = service.computeMergeSuggestions(
                groups: groups,
                faces: faces,
                threshold: threshold,
                cache: cache
            )
            await MainActor.run {
                // Drop the result if the folder changed or the user switched away from the
                // Face lens while the computation was in flight.
                guard let self, self.faceData?.folderURL == folderURL, self.activeLens == .face else { return }
                self.mergeSuggestions = suggestions
            }
        }
    }

    /// Refine clustering using named groups as anchors.
    /// Compares unnamed groups against named groups and returns merge suggestions.
    /// Returns the number of suggestions found.
    @discardableResult
    func refineWithNamedGroups() -> Int {
        guard let data = faceData else { return 0 }

        let namedCount = data.groups.filter { $0.name != nil }.count
        guard namedCount > 0 else { return 0 }

        let config = detectionConfig
        let refinementSuggestions = detectionService.computeRefinementSuggestions(
            groups: data.groups,
            faces: data.faces,
            threshold: config.clusteringThreshold
        )

        // Add refinement suggestions to the existing merge suggestions
        // Filter out duplicates (same pair of groups)
        let existingPairs = Set(mergeSuggestions.map { Set([$0.group1ID, $0.group2ID]) })
        let newSuggestions = refinementSuggestions.filter { suggestion in
            !existingPairs.contains(Set([suggestion.group1ID, suggestion.group2ID]))
        }

        mergeSuggestions.append(contentsOf: newSuggestions)
        mergeSuggestions.sort { $0.similarity > $1.similarity }

        return newSuggestions.count
    }

    /// Run refinement and immediately merge every confident match into its named group,
    /// in a single mutation + save. Returns the number of unnamed groups absorbed.
    /// Refinement suggestions always pair a named group (group1) with an unnamed one
    /// (group2), and each unnamed group appears at most once, so merges never conflict.
    @discardableResult
    func refineAndApplyMatches() -> Int {
        guard var data = faceData else { return 0 }
        guard data.groups.contains(where: { $0.name != nil }) else { return 0 }

        let config = detectionConfig
        let suggestions = detectionService.computeRefinementSuggestions(
            groups: data.groups,
            faces: data.faces,
            threshold: config.clusteringThreshold
        )
        guard !suggestions.isEmpty else { return 0 }

        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)
        var removedSourceIDs: Set<UUID> = []

        for suggestion in suggestions {
            // group2 (unnamed) folds into group1 (named).
            guard let targetIndex = groupIdx[suggestion.group1ID],
                  let sourceIndex = groupIdx[suggestion.group2ID],
                  suggestion.group1ID != suggestion.group2ID,
                  !removedSourceIDs.contains(suggestion.group2ID) else { continue }

            let sourceFaceIDs = data.groups[sourceIndex].faceIDs
            data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)
            data.groups[targetIndex].inheritAppliedName(from: data.groups[sourceIndex])
            for faceID in sourceFaceIDs {
                if let fi = faceIdx[faceID] { data.faces[fi].groupID = suggestion.group1ID }
            }
            removedSourceIDs.insert(suggestion.group2ID)
        }

        guard !removedSourceIDs.isEmpty else { return 0 }
        data.groups.removeAll { removedSourceIDs.contains($0.id) }

        guard commitFaceEdit(data) else { return 0 }
        mergeSuggestions.removeAll()
        return removedSourceIDs.count
    }

    /// Whether refinement is available (at least one named group and one unnamed group)
    private(set) var canRefine: Bool = false

    func dismissMergeSuggestion(_ suggestion: MergeSuggestion) {
        mergeSuggestions.removeAll { $0.id == suggestion.id }
    }

    func applyMergeSuggestion(_ suggestion: MergeSuggestion) {
        mergeGroups(sourceID: suggestion.group2ID, into: suggestion.group1ID)
        dismissMergeSuggestion(suggestion)
    }

    // MARK: - Naming & Metadata

    /// Display name for a group, or `nil` when the group is missing or unnamed.
    /// Used by the full-screen overlay to label and pre-fill the rename popover.
    func groupName(_ groupID: UUID) -> String? {
        guard let group = groupLookup[groupID], let name = group.name, !name.isEmpty else { return nil }
        return name
    }

    /// The jersey number for a group (Sports lens only), used to prefix the name tag.
    /// Resolved first from numbers actually read off the group's faces, then — for
    /// players named from the team sheet or Known People without an OCR'd number — from
    /// the roster via the linked person or a name match. `nil` when nothing resolves.
    func groupNumber(_ groupID: UUID) -> Int? {
        guard let group = groupLookup[groupID] else { return nil }
        guard activeLens == .sports else { return nil }

        // 0. A hand-assigned number is an explicit choice — always honored, and it wins
        //    over any detected/roster number (it's how the user corrects a misread).
        if let manual = group.manualNumber { return manual }

        // 1. Majority vote across detected face numbers (most authoritative).
        var votes: [Int: Int] = [:]
        for faceID in group.faceIDs {
            guard let number = faceLookup[faceID]?.jerseyNumber else { continue }
            votes[number, default: 0] += 1
        }
        if let voted = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            return voted
        }

        // 2. Roster fallback: the number is on the team sheet even when no face was OCR'd.
        return rosterNumber(forGroup: groupID, group: group)
    }

    /// The roster jersey number for an already-identified group: by the linked
    /// known-person id, else by matching the group name to a roster player.
    private func rosterNumber(forGroup groupID: UUID, group: FaceGroup) -> Int? {
        guard let match = matchRoster else { return nil }
        let teams = [match.team(for: .home), match.team(for: .away)].compactMap { $0 }
        guard !teams.isEmpty else { return nil }

        if let personID = group.knownPersonID ?? knownPersonMatchByGroup[groupID]?.personID {
            for team in teams {
                if let player = team.roster.first(where: { $0.knownPersonID == personID }) {
                    return player.number
                }
            }
        }
        if let name = group.name {
            for team in teams {
                if let player = team.roster.first(where: {
                    namesMatch($0.playerName, name) || namesMatch(resolvedDisplayName(for: $0), name)
                }) {
                    return player.number
                }
            }
        }
        return nil
    }

    func nameGroup(_ groupID: UUID, name: String, knownPersonID: UUID? = nil) {
        guard var data = faceData else { return }
        let groupIdx = groupIndexMap(from: data)
        guard let index = groupIdx[groupID] else { return }

        let newName: String? = name.isEmpty ? nil : name
        let previousName = data.groups[index].name
        data.groups[index].name = newName
        if let knownPersonID {
            // A Known People pick (suggestion, auto-match, roster link) asserts the identity.
            data.groups[index].knownPersonID = knownPersonID
        } else if newName != previousName {
            // A typed rename is a different identity claim; an unchanged name keeps the link
            // that roster lookups and Known People renames rely on.
            data.groups[index].knownPersonID = nil
        }
        commitFaceEdit(data)
    }

    /// Clears the group's identification while preserving its faces and key art.
    /// Previously written photo metadata and the Known People database are not edited.
    func resetGroupName(_ groupID: UUID) {
        nameGroup(groupID, name: "")
    }

    /// Assign (or clear, with `nil`) a hand-picked jersey number for a group. Display-only —
    /// see `groupNumber(_:)`. Persisted alongside the rest of the face data.
    func setManualNumber(_ number: Int?, forGroup groupID: UUID) {
        guard var data = faceData else { return }
        let groupIdx = groupIndexMap(from: data)
        guard let index = groupIdx[groupID] else { return }

        data.groups[index].manualNumber = number
        commitFaceEdit(data)
    }

    /// Reversibly exclude a referee or other non-player from Person Shown. The group stays in
    /// face data for later correction, while attached Sports claims become sticky rejections.
    func setExcludedFromPersonShown(_ excluded: Bool, forGroup groupID: UUID) {
        guard var data = faceData,
              let index = data.groups.firstIndex(where: { $0.id == groupID }) else { return }
        data.groups[index].excludedFromPersonShown = excluded ? true : nil
        if excluded, data.numberDetections != nil {
            let faceIDs = Set(data.groups[index].faceIDs)
            for detectionIndex in data.numberDetections!.indices {
                guard let faceID = data.numberDetections![detectionIndex].associatedFaceID,
                      faceIDs.contains(faceID) else { continue }
                data.numberDetections![detectionIndex].claimState = .rejected
                ambiguousNumberDetections.removeAll {
                    $0.id == data.numberDetections![detectionIndex].id
                }
            }
        }
        commitFaceEdit(data, failurePrefix: "Failed to save face exclusion")
    }

    func setRepresentativeFace(_ faceID: UUID, forGroup groupID: UUID) {
        guard var data = faceData else { return }
        let groupIdx = groupIndexMap(from: data)
        guard let index = groupIdx[groupID],
              data.groups[index].faceIDs.contains(faceID) else { return }

        data.groups[index].representativeFaceID = faceID
        commitFaceEdit(data)
    }

    // MARK: - Sports tagging: match setup & resolution

    /// Load the per-folder match roster, if one was saved. A request token prevents a slow read
    /// from an old folder from replacing the roster selected by a newer navigation.
    @discardableResult
    func loadMatchRoster(for folderURL: URL) async -> MatchRoster? {
        let requestID = UUID()
        matchRosterLoadRequestID = requestID
        let result = await matchRosterService.load(for: folderURL, requestID: requestID)
        guard !Task.isCancelled, matchRosterLoadRequestID == requestID else { return nil }
        guard case .loaded(let snapshot) = result else { return nil }
        matchRoster = snapshot.roster
        return snapshot.roster
    }

    private func scheduleMatchRosterLoad(for folderURL: URL, resolveAfterLoad: Bool) {
        matchRosterLoadTask?.cancel()
        matchRosterLoadTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.loadMatchRoster(for: folderURL)
            guard !Task.isCancelled,
                  self.displayedFolderURL == folderURL.standardizedFileURL else { return }
            if resolveAfterLoad { self.runSportsResolution() }
            self.matchRosterLoadTask = nil
        }
    }

    /// Set the two teams for this folder, embedding current library snapshots.
    /// Changing teams invalidates any previous colour-mapping confirmation.
    func setMatchTeams(homeTeamID: UUID?, awayTeamID: UUID?, folderURL: URL) async {
        var roster = matchRoster ?? MatchRoster(folderURL: folderURL)
        roster.folderURL = folderURL
        roster.mode = .team
        roster.homeTeamID = homeTeamID
        roster.awayTeamID = awayTeamID
        roster.homeTeamSnapshot = homeTeamID.flatMap { RosterStore.shared.team(byID: $0) }
        roster.awayTeamSnapshot = awayTeamID.flatMap { RosterStore.shared.team(byID: $0) }
        roster.clusterMappingConfirmed = false
        matchRoster = roster
        _ = try? await matchRosterService.save(roster, requestID: UUID())
    }

    /// Set a single startlist for an individual-sport event (bib mode). Bib numbers resolve
    /// directly to athletes — no team colour, no home/away confirm step. The startlist is held
    /// in the home slot; away stays empty.
    func setEventStartlist(teamID: UUID?, folderURL: URL) async {
        var roster = matchRoster ?? MatchRoster(folderURL: folderURL)
        roster.folderURL = folderURL
        roster.mode = .event
        roster.homeTeamID = teamID
        roster.awayTeamID = nil
        roster.homeTeamSnapshot = teamID.flatMap { RosterStore.shared.team(byID: $0) }
        roster.awayTeamSnapshot = nil
        // No colour clustering in event mode — nothing to confirm.
        roster.clusterMappingConfirmed = true
        roster.clusterFlipped = false
        matchRoster = roster
        _ = try? await matchRosterService.save(roster, requestID: UUID())
    }

    /// Cluster sampled jersey colours into the two teams. If the mapping is
    /// already confirmed (and trustworthy), assign sides and resolve names; else
    /// surface the confirm/flip prompt and stop.
    func runSportsResolution() {
        guard let data = faceData, let match = matchRoster, match.isReady else { return }

        // No colour clustering when there's nothing to tell apart: an individual event (bib →
        // athlete) or a match with only one team configured. Each claim resolves by number alone
        // against the single roster; numbers not on it stay unmatched.
        guard match.effectiveMode == .team, match.hasBothTeams,
              let home = match.homeTeamSnapshot, let away = match.awayTeamSnapshot else {
            applyResolution(cluster: nil, flipped: false)
            return
        }

        var colors: [ColorRGB] = []
        for face in data.faces { if let c = face.jerseyColorRGB { colors.append(c) } }
        for number in data.numberDetections ?? [] { if let c = number.jerseyColorRGB { colors.append(c) } }

        let cluster = colorClusterer.cluster(
            colors: colors,
            homeKits: home.kitColors,
            awayKits: away.kitColors
        )

        // No usable colours → resolve by number alone (side unknown).
        guard let cluster else {
            applyResolution(cluster: nil, flipped: false)
            return
        }

        if match.clusterMappingConfirmed {
            applyResolution(cluster: cluster, flipped: match.clusterFlipped)
        } else {
            // First time (or teams changed): always confirm. Low confidence makes
            // the confirm step doubly important.
            pendingColorClusterConfirmation = cluster
        }
    }

    /// Apply the photographer's confirm/flip choice, persist it, and resolve.
    func confirmClusterMapping(flip: Bool) async {
        guard var roster = matchRoster else { return }
        roster.clusterMappingConfirmed = true
        roster.clusterFlipped = flip
        matchRoster = roster
        _ = try? await matchRosterService.save(roster, requestID: UUID())

        let cluster = pendingColorClusterConfirmation
        pendingColorClusterConfirmation = nil
        applyResolution(cluster: cluster, flipped: flip)
    }

    /// Turn detected numbers into resolved player *claims* without ever renaming a
    /// face group from a number. Each number — whether it sat over a face's torso or
    /// stood alone — becomes a `NumberDetection` claim that resolves to a player and
    /// then waits for confirmation, except claims that corroborate an independently
    /// recognised face naming the same player, which auto-confirm. Ambiguous numbers
    /// are bucketed for manual side assignment.
    private func applyResolution(cluster: TeamColorClusterer.ClusterResult?, flipped: Bool) {
        guard var data = faceData, let match = matchRoster else { return }

        // Assign team sides from sampled colours (faces keep a side for the overlay).
        for i in data.faces.indices {
            if let c = data.faces[i].jerseyColorRGB, let cluster {
                data.faces[i].teamSide = colorClusterer.side(for: c, in: cluster, flipped: flipped)
            }
        }

        let result = Self.reconcileNumberClaims(
            faces: data.faces,
            groups: data.groups,
            existing: data.numberDetections ?? [],
            resolver: playerResolver,
            match: match,
            sideForColor: { color in
                guard let cluster else { return nil }
                return self.colorClusterer.side(for: color, in: cluster, flipped: flipped)
            },
            displayName: { self.resolvedDisplayName(for: $0) }
        )

        data.numberDetections = result.numbers
        guard commitFaceEdit(data, failurePrefix: "Failed to save sports resolution",
                             reportsScanRefusal: false) else { return }
        ambiguousNumberDetections = result.ambiguous
    }

    /// Pure core of sports resolution: turn detected numbers into resolved, confirmation-gated
    /// player claims. Kept `nonisolated static` (like `jerseyMergePlan`) so it's unit-testable
    /// without the MainActor view model. The two closures inject the colour→side mapping and the
    /// player→display-name choice so this stays free of clustering/Known-People dependencies.
    ///
    /// Guarantees, in order:
    /// 1. Every face-attached number becomes a first-class claim (geometry never names a group).
    /// 2. `.rejected` is sticky; `.confirmed` survives only while the resolved name is unchanged.
    /// 3. A still-suggested claim auto-confirms iff its image holds an independently identified
    ///    face naming the same player (two agreeing signals).
    nonisolated static func reconcileNumberClaims(
        faces: [DetectedFace],
        groups: [FaceGroup],
        existing: [NumberDetection],
        resolver: PlayerResolver,
        match: MatchRoster,
        sideForColor: (ColorRGB) -> TeamSide?,
        displayName: (RosterPlayer) -> String
    ) -> (numbers: [NumberDetection], ambiguous: [NumberDetection]) {
        // 1. Promote face-attached numbers into claims (skip faces already represented).
        var numbers = existing
        let attachedFaceIDs = Set(numbers.compactMap(\.associatedFaceID))
        for face in faces {
            guard let number = face.jerseyNumber, !attachedFaceIDs.contains(face.id) else { continue }
            numbers.append(NumberDetection(
                imageURL: face.imageURL,
                number: number,
                numberConfidence: face.numberConfidence ?? 0,
                boundingBox: face.jerseyNumberBox ?? face.faceRect,
                jerseyColorRGB: face.jerseyColorRGB,
                associatedFaceID: face.id
            ))
        }

        // 2. Side + resolve + reconcile sticky state.
        var ambiguous: [NumberDetection] = []
        for i in numbers.indices {
            if let c = numbers[i].jerseyColorRGB { numbers[i].teamSide = sideForColor(c) }
            let previousName = numbers[i].resolvedPlayerName
            let previousState = numbers[i].effectiveClaimState

            switch resolver.resolve(number: numbers[i].number, side: numbers[i].teamSide, match: match) {
            case .resolved(let player, _):
                let name = displayName(player)
                numbers[i].resolvedPlayerName = name
                if previousState == .rejected {
                    numbers[i].claimState = .rejected
                } else if name != previousName {
                    numbers[i].claimState = .suggested
                }
            case .ambiguous:
                numbers[i].resolvedPlayerName = nil
                if previousState != .rejected { numbers[i].claimState = .suggested }
                ambiguous.append(numbers[i])
            case .notFound:
                numbers[i].resolvedPlayerName = nil
                if previousState != .rejected { numbers[i].claimState = .suggested }
            }
        }

        // 3. Auto-confirm on agreement with an independently identified face.
        let faceNamesByURL = independentFaceNamesByURL(faces: faces, groups: groups)
        for i in numbers.indices where numbers[i].effectiveClaimState == .suggested {
            guard let name = numbers[i].resolvedPlayerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  faceNamesByURL[numbers[i].imageURL]?.contains(name.lowercased()) == true else { continue }
            numbers[i].claimState = .confirmed
        }

        return (numbers, ambiguous)
    }

    /// Per-image set of lower-cased player names that come from an *independently* identified
    /// face — a face group named by face recognition or the user. Numbers never write group
    /// names, so any group name here is a genuine second signal for auto-confirmation.
    nonisolated static func independentFaceNamesByURL(faces: [DetectedFace], groups: [FaceGroup]) -> [URL: Set<String>] {
        let groupNameByID: [UUID: String] = Dictionary(
            groups.compactMap { group in
                guard !group.isExcludedFromPersonShown else { return nil }
                guard let name = group.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
                else { return nil }
                return (group.id, name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var namesByURL: [URL: Set<String>] = [:]
        for face in faces {
            guard let groupID = face.groupID, let name = groupNameByID[groupID] else { continue }
            namesByURL[face.imageURL, default: []].insert(name.lowercased())
        }
        return namesByURL
    }

    /// The canonical name to tag a resolved player with: prefer the linked Known
    /// Person's name (stable identity, shared across games) over the free-text
    /// roster name, falling back to the roster name when there's no link.
    private func resolvedDisplayName(for player: RosterPlayer) -> String {
        if let personID = player.knownPersonID,
           let known = KnownPeopleService.shared.person(byID: personID),
           !known.name.isEmpty {
            return known.name
        }
        return player.playerName
    }

    /// The player name a (number, side) resolves to in the current match, for previewing the
    /// "Name from team sheet" action. `nil` if there's no match or the number is ambiguous/unknown.
    func rosterName(forNumber number: Int, side: TeamSide?) -> String? {
        guard let match = matchRoster,
              case .resolved(let player, _) = playerResolver.resolve(number: number, side: side, match: match)
        else { return nil }
        return resolvedDisplayName(for: player)
    }

    /// Name a face group from the roster by jersey number + team — the manual counterpart to number
    /// resolution, for players whose number couldn't be read (stylised font) or that the
    /// photographer can't place by name. Records the Known-People link when the roster player has one.
    @discardableResult
    func nameGroup(_ groupID: UUID, fromNumber number: Int, side: TeamSide?) -> Bool {
        guard let match = matchRoster,
              case .resolved(let player, _) = playerResolver.resolve(number: number, side: side, match: match)
        else { return false }
        if let personID = player.knownPersonID {
            nameGroup(groupID, name: resolvedDisplayName(for: player), knownPersonID: personID)
            knownPersonMatchByGroup[groupID] = (personID: personID, confidence: 1.0)
        } else {
            nameGroup(groupID, name: resolvedDisplayName(for: player))
        }
        return true
    }

    /// Manually assign a side to an ambiguous number, then re-resolve it. The claim still
    /// needs confirmation afterwards — picking a side disambiguates the team, it doesn't
    /// assert the player is actually in the frame.
    func assignSide(_ side: TeamSide, toNumberDetection detectionID: UUID) {
        guard var data = faceData, let match = matchRoster, data.numberDetections != nil else { return }
        guard let i = data.numberDetections!.firstIndex(where: { $0.id == detectionID }) else { return }
        data.numberDetections![i].teamSide = side
        if case .resolved(let player, _) = playerResolver.resolve(number: data.numberDetections![i].number, side: side, match: match) {
            data.numberDetections![i].resolvedPlayerName = resolvedDisplayName(for: player)
        }
        guard commitFaceEdit(data) else { return }
        ambiguousNumberDetections.removeAll { $0.id == detectionID }
    }

    /// Mutate a single number claim's confirmation state and persist. Confirmed claims (and only
    /// confirmed claims) write their resolved player name to metadata on Apply.
    private func setClaimState(_ state: NumberClaimState, forNumberDetection detectionID: UUID) {
        guard var data = faceData, data.numberDetections != nil,
              let i = data.numberDetections!.firstIndex(where: { $0.id == detectionID }) else { return }
        data.numberDetections![i].claimState = state
        commitFaceEdit(data)
    }

    /// Accept a number → player claim: its name will be written on Apply.
    func confirmNumberClaim(_ detectionID: UUID) {
        setClaimState(.confirmed, forNumberDetection: detectionID)
        ambiguousNumberDetections.removeAll { $0.id == detectionID }
    }

    /// Reject a number → player claim (wrong number, opposing team, a supporter, an OCR misread).
    /// The detection is kept — so re-resolution won't resurrect it — but its name is never written
    /// and it drops off the player's card. This is also "remove this number from the group".
    func rejectNumberClaim(_ detectionID: UUID) {
        setClaimState(.rejected, forNumberDetection: detectionID)
        ambiguousNumberDetections.removeAll { $0.id == detectionID }
    }

    /// Manually bind a number claim to a face group — the photographer dragging a number onto a
    /// person's card. This is an explicit identity assertion, so it confirms the claim: the
    /// number is linked to the group's representative face and named with the group's name (or, if
    /// the group is unnamed, the group takes the number's resolved name). Either way it then
    /// writes on Apply.
    func bindNumberDetection(_ detectionID: UUID, toGroup groupID: UUID) {
        guard var data = faceData, data.numberDetections != nil,
              let i = data.numberDetections!.firstIndex(where: { $0.id == detectionID }),
              let group = data.groups.first(where: { $0.id == groupID }) else { return }

        data.numberDetections![i].associatedFaceID = group.representativeFaceID
        let groupName = group.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let groupName, !groupName.isEmpty {
            data.numberDetections![i].resolvedPlayerName = groupName
            data.numberDetections![i].claimState = .confirmed
            commitFaceEdit(data)
        } else if let resolved = data.numberDetections![i].resolvedPlayerName?.trimmingCharacters(in: .whitespacesAndNewlines), !resolved.isEmpty {
            data.numberDetections![i].claimState = .confirmed
            commitFaceEdit(data)
            // Name the previously-unnamed group with the number's player (user-asserted identity).
            nameGroup(groupID, name: resolved)
        } else {
            commitFaceEdit(data)
        }
        ambiguousNumberDetections.removeAll { $0.id == detectionID }
    }

    /// Detach a number from the face it was geometrically attached to, returning it to a
    /// standalone (back-turned-style) claim. Use when the number clearly belongs to a different
    /// player than the face it landed on; resolution by colour/side is otherwise unchanged.
    func detachNumberFromFace(_ detectionID: UUID) {
        guard var data = faceData, data.numberDetections != nil,
              let i = data.numberDetections!.firstIndex(where: { $0.id == detectionID }) else { return }
        let det = data.numberDetections![i]
        // Clear the matching denormalised hint on the face so the overlay/merge stop showing it.
        if let faceID = det.associatedFaceID, let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
            data.faces[fi].jerseyNumber = nil
            data.faces[fi].numberConfidence = nil
            data.faces[fi].jerseyNumberBox = nil
        }
        data.numberDetections![i].associatedFaceID = nil
        commitFaceEdit(data)
    }

    /// Correct a misread number (OCR read "1" but the shirt shows "21"). Updates the claim and its
    /// denormalised face hint, re-resolves against the roster with the current side, and resets the
    /// claim to `suggested` so the corrected identity is reviewed before it's written.
    func correctNumber(_ detectionID: UUID, to newNumber: Int) {
        guard var data = faceData, let match = matchRoster, data.numberDetections != nil,
              let i = data.numberDetections!.firstIndex(where: { $0.id == detectionID }) else { return }
        guard newNumber != data.numberDetections![i].number else { return }

        data.numberDetections![i].number = newNumber
        if let faceID = data.numberDetections![i].associatedFaceID,
           let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
            data.faces[fi].jerseyNumber = newNumber
        }

        let side = data.numberDetections![i].teamSide
        ambiguousNumberDetections.removeAll { $0.id == detectionID }
        switch playerResolver.resolve(number: newNumber, side: side, match: match) {
        case .resolved(let player, _):
            data.numberDetections![i].resolvedPlayerName = resolvedDisplayName(for: player)
        case .ambiguous:
            data.numberDetections![i].resolvedPlayerName = nil
            ambiguousNumberDetections.append(data.numberDetections![i])
        case .notFound:
            data.numberDetections![i].resolvedPlayerName = nil
        }
        data.numberDetections![i].claimState = .suggested
        commitFaceEdit(data)
    }

    /// If a face group carries a jersey number that maps to a roster player on a
    /// known side, return the data needed to link it to Known People. `nil` when
    /// the group has no resolvable number/side yet.
    func rosterLinkTarget(forGroup groupID: UUID) -> (number: Int, teamID: UUID, playerName: String)? {
        guard let data = faceData,
              let match = matchRoster,
              let group = groupLookup[groupID] else { return nil }

        // A named group can be linked even when OCR missed the shirt entirely. Require a unique
        // name match across the configured sheets; an existing bridge needs no repeat action.
        if let personID = group.knownPersonID ?? knownPersonMatchByGroup[groupID]?.personID {
            let alreadyLinked = [match.homeTeamSnapshot, match.awayTeamSnapshot]
                .compactMap { $0 }
                .flatMap(\.roster)
                .contains { $0.knownPersonID == personID }
            if alreadyLinked { return nil }
        }
        if let name = group.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let namedCandidates: [(RosterPlayer, TeamSide, UUID?)] = [
                match.homeTeamSnapshot.map { team in team.roster.filter { namesMatch($0.playerName, name) }.map { ($0, TeamSide.home, match.homeTeamID) } } ?? [],
                match.awayTeamSnapshot.map { team in team.roster.filter { namesMatch($0.playerName, name) }.map { ($0, TeamSide.away, match.awayTeamID) } } ?? []
            ].flatMap { $0 }
            if namedCandidates.count == 1,
               let candidate = namedCandidates.first,
               candidate.0.knownPersonID == nil,
               let teamID = candidate.2 {
                return (candidate.0.number, teamID, candidate.0.playerName)
            }
        }

        let facesByID = Dictionary(data.faces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var votes: [String: (count: Int, conf: Float, number: Int, side: TeamSide?)] = [:]
        if let manual = group.manualNumber {
            votes["manual"] = (Int.max, Float.greatestFiniteMagnitude, manual, nil)
        }
        for faceID in group.faceIDs {
            guard let face = facesByID[faceID], let number = face.jerseyNumber else { continue }
            let key = "\(number)-\(face.teamSide?.rawValue ?? "?")"
            var vote = votes[key] ?? (0, 0, number, face.teamSide)
            vote.count += 1
            vote.conf += face.numberConfidence ?? 0
            votes[key] = vote
        }
        guard let best = votes.values.max(by: { ($0.count, $0.conf) < ($1.count, $1.conf) }) else { return nil }
        guard case .resolved(let player, let side) = playerResolver.resolve(
            number: best.number,
            side: best.side,
            match: match
        ) else { return nil }
        let teamID = side == .home ? match.homeTeamID : match.awayTeamID
        guard player.knownPersonID == nil, let teamID else { return nil }
        return (best.number, teamID, player.playerName)
    }

    /// The bridge: confirm a face group is a roster player, promoting the group's
    /// faces into Known People and stamping the new person's id onto the roster
    /// entry so future games recognise the player by face.
    @discardableResult
    func linkPlayerToKnownPeople(groupID: UUID, playerNumber: Int, teamID: UUID) async -> Bool {
        guard let data = faceData,
              let team = RosterStore.shared.team(byID: teamID),
              let player = team.roster.first(where: { $0.number == playerNumber }) else { return false }
        let folderURL = data.folderURL.standardizedFileURL
        let displayedFolder = displayedFolderURL
        var expectedFaceRevision = faceDataRevision
        var expectedMatchRevision = matchRosterRevision
        func canPublish() -> Bool {
            !Task.isCancelled && faceDataRevision == expectedFaceRevision
                && matchRosterRevision == expectedMatchRevision
                && faceData?.folderURL.standardizedFileURL == folderURL
                && displayedFolderURL == displayedFolder
        }
        do {
            let result = try await addGroupToKnownPeople(groupID: groupID, name: player.playerName)
            // Known People may already be durable. A newer folder/edit only stops subsequent
            // linking and presentation; it does not roll back that completed storage operation.
            guard canPublish() else { return false }
            try await RosterStore.shared.linkKnownPerson(
                result.personID,
                toPlayerNumber: playerNumber,
                teamID: teamID
            )
            guard canPublish() else { return false }
            nameGroup(groupID, name: player.playerName, knownPersonID: result.personID)
            expectedFaceRevision = faceDataRevision
            knownPersonMatchByGroup[groupID] = (personID: result.personID, confidence: 1.0)
            if var match = matchRoster, let updatedTeam = RosterStore.shared.team(byID: teamID) {
                if match.homeTeamID == teamID { match.homeTeamSnapshot = updatedTeam }
                if match.awayTeamID == teamID { match.awayTeamSnapshot = updatedTeam }
                matchRoster = match
                expectedMatchRevision = matchRosterRevision
                _ = try await matchRosterService.save(match, requestID: UUID())
                guard canPublish() else { return false }
            }
            return true
        } catch {
            guard canPublish() else { return false }
            errorMessage = "Failed to link player to Known People: \(error.localizedDescription)"
            return false
        }
    }

    func applyNameToMetadata(groupID: UUID) {
        guard let data = faceData,
              let group = groupLookup[groupID], !group.isExcludedFromPersonShown,
              let name = group.name, !name.isEmpty else { return }
        guard !refuseFaceEditDuringScan(data.folderURL) else { return }
        guard !fieldMutationIsPaused(in: data.folderURL) else {
            errorMessage = "Face metadata writing is paused while files in this folder are being renamed."
            return
        }

        let names = splitPersonNames(name)
        guard let appliedName = names.first else { return }

        // Always write into the folder that is open now (a moved or copied folder's stored URLs
        // are rebased on load; this keeps a stale absolute URL from reaching the old folder).
        let uniqueURLs = Array(Set(group.faceIDs.compactMap { faceID in
            faceLookup[faceID].map { Self.currentPhotoURL($0.imageURL, in: data.folderURL) }
        }))

        guard !uniqueURLs.isEmpty else { return }

        enqueuePersonMutations(
            mutationsByURL: Dictionary(uniqueKeysWithValues: uniqueURLs.map { ($0, .addPersons(names)) }),
            folderURL: data.folderURL, capturedC2PA: nil,
            appliedNameUpdates: [groupID: appliedName], onComplete: nil)
    }

    /// A face's photo inside `folderURL`, by filename when the stored URL names another folder.
    nonisolated static func currentPhotoURL(_ url: URL, in folderURL: URL) -> URL {
        url.deletingLastPathComponent().standardizedFileURL.path == folderURL.standardizedFileURL.path
            ? url : folderURL.appendingPathComponent(url.lastPathComponent)
    }

    func applyAllNamesToMetadata(
        images: [ImageFile],
        folderURL: URL?,
        onComplete: (() -> Void)? = nil
    ) {
        guard let data = faceData else {
            onComplete?()
            return
        }
        guard !refuseFaceEditDuringScan(data.folderURL) else {
            onComplete?()
            return
        }
        guard !fieldMutationIsPaused(in: data.folderURL) else {
            errorMessage = "Face metadata writing is paused while files in this folder are being renamed."
            onComplete?()
            return
        }

        // Match faces to the browser's photos by path inside the open folder, never by a stored
        // absolute URL that may still name the folder this one was moved or copied from.
        var availableByPath: [String: URL] = [:]
        for image in images { availableByPath[image.url.standardizedFileURL.path] = image.url }
        var namesByURL: [URL: [String]] = [:]
        var seenNamesByURL: [URL: Set<String>] = [:]
        var appliedNameUpdates: [UUID: String?] = [:]

        for face in data.faces {
            guard let photoURL = availableByPath[Self.currentPhotoURL(face.imageURL, in: data.folderURL).standardizedFileURL.path],
                  let groupID = face.groupID,
                  let group = groupLookup[groupID], !group.isExcludedFromPersonShown,
                  let rawName = group.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { continue }

            let names = splitPersonNames(rawName)
            guard let appliedName = names.first else { continue }
            appliedNameUpdates[groupID] = appliedName

            var existing = namesByURL[photoURL] ?? []
            var seen = seenNamesByURL[photoURL] ?? Set(existing.map { $0.lowercased() })
            for name in names {
                let key = name.lowercased()
                if seen.insert(key).inserted {
                    existing.append(name)
                }
            }
            namesByURL[photoURL] = existing
            seenNamesByURL[photoURL] = seen
        }

        // Jersey-number claims (including back-turned players with no face) only write when the
        // photographer has them in front of them: the Sports lens must be active. Switch away to
        // Face and number-derived names stop being applied — the detections stay in the folder's
        // .face_data, but nothing is written from a number alone. Within Sports, only *confirmed*
        // claims write; suggested/rejected/ambiguous ones never reach metadata. Names that overlap
        // a face group dedupe against the per-URL set built above.
        if activeLens == .sports {
            let excludedFaceIDs = Set(data.groups.filter(\.isExcludedFromPersonShown).flatMap(\.faceIDs))
            for det in data.numberDetections ?? [] where det.effectiveClaimState == .confirmed {
                guard let photoURL = availableByPath[Self.currentPhotoURL(det.imageURL, in: data.folderURL).standardizedFileURL.path],
                      det.associatedFaceID.map({ !excludedFaceIDs.contains($0) }) ?? true,
                      let rawName = det.resolvedPlayerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawName.isEmpty else { continue }
                let names = splitPersonNames(rawName)
                guard !names.isEmpty else { continue }

                var existing = namesByURL[photoURL] ?? []
                var seen = seenNamesByURL[photoURL] ?? Set(existing.map { $0.lowercased() })
                for name in names where seen.insert(name.lowercased()).inserted {
                    existing.append(name)
                }
                namesByURL[photoURL] = existing
                seenNamesByURL[photoURL] = seen
            }
        }

        guard !namesByURL.isEmpty else {
            onComplete?()
            return
        }

        let capturedFolder = folderURL ?? data.folderURL
        guard Self.fieldMutationFolderIdentity(capturedFolder) == Self.fieldMutationFolderIdentity(data.folderURL) else {
            errorMessage = "The face folder changed; person names were not written."
            onComplete?()
            return
        }
        let c2paLookup = Dictionary(images.map { ($0.url, $0.hasC2PA) }, uniquingKeysWith: { first, _ in first })
        enqueuePersonMutations(mutationsByURL: namesByURL.mapValues { .addPersons($0) }, folderURL: capturedFolder,
            capturedC2PA: c2paLookup, appliedNameUpdates: appliedNameUpdates, onComplete: onComplete)
    }

    /// Directory identity must not depend on whether a decoded URL carries a trailing slash.
    /// Keep this normalization scoped to field-write admission/completion and its rename barrier.
    nonisolated private static func fieldMutationFolderIdentity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func fieldMutationIsPaused(in folderURL: URL) -> Bool {
        guard let reservation = renameQuiescenceFolderURL else { return false }
        return Self.fieldMutationFolderIdentity(reservation) == Self.fieldMutationFolderIdentity(folderURL)
    }

    /// The one Person Shown write path for faces (Apply and "Update Person Shown"): every photo
    /// goes through `MetadataFieldMutationWriteService`, which honours the write preset (RAW →
    /// XMP sidecar only), C2PA, the metadata loss guard and preserves Develop settings.
    /// `appliedNameUpdates` records the exact name now in the photos once any write completes.
    private func enqueuePersonMutations(mutationsByURL: [URL: MetadataPhysicalFieldMutation], folderURL: URL,
        capturedC2PA: [URL: Bool]?, appliedNameUpdates: [UUID: String?] = [:], onComplete: (() -> Void)?) {
        // Capture settings before any asynchronous reads or preceding accepted operations.
        let ordinaryMode = fieldMutationModeResolver(false, false)
        let c2paMode = fieldMutationModeResolver(true, false)
        let rawMode = fieldMutationModeResolver(false, true)
        let urls = mutationsByURL.keys.sorted { $0.path < $1.path }
        let previous = metadataWriteTask
        let writer = injectedFieldMutationWriter
        let engine = writeEngine
        let reader = readService
        let signatureService = fileSignatureService
        metadataWriteTask = Task {
            // The completion closure releases FaceBar's busy state, including failures. Success
            // is represented by immutable results and change notifications, never this callback.
            defer { onComplete?() }
            await previous?.value
            // Content-credential status by path (URL spellings of one file may differ). Photos the
            // caller could not describe are read from disk; an unreadable photo is refused below.
            var c2pa: [String: Bool] = [:]
            for (url, value) in capturedC2PA ?? [:] { c2pa[url.standardizedFileURL.path] = value }
            let undescribed = urls.filter { c2pa[$0.standardizedFileURL.path] == nil }
            if !undescribed.isEmpty {
                for (url, value) in await loadC2PALookup(urls: undescribed) { c2pa[url.standardizedFileURL.path] = value }
            }
            let service = MetadataFieldMutationWriteService(writeEngine: engine, readEmbedded: { url in
                guard let value = try await reader.readBatchFullMetadata(urls: [url])[url] else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
                }
                return value
            })
            var results: [MetadataFieldMutationWriteResult] = []
            var ownWrites: [OwnPersonWrite] = []
            for url in urls {
                guard let mutation = mutationsByURL[url] else { continue }
                let hasC2PA = c2pa[url.standardizedFileURL.path]
                let mode = SupportedImageFormats.isRaw(url: url) ? rawMode : ((hasC2PA ?? false) ? c2paMode : ordinaryMode)
                let request = MetadataFieldMutationWriteRequest(imageURL: url, folderURL: folderURL,
                    requestedMode: mode, mutation: mutation)
                guard hasC2PA != nil else {
                    results.append(.failed(request: request,
                        message: "Could not read this photo's metadata and content-credential status. Person names were not written."))
                    continue
                }
                let factsBefore = await signatureService.fileFacts(for: url)
                let result = if let writer { await writer(request) } else { await service.write(request) }
                if result.didWriteEmbedded, let factsBefore, let factsAfter = await signatureService.fileFacts(for: url) {
                    ownWrites.append(OwnPersonWrite(url: url, before: factsBefore, after: factsAfter))
                }
                results.append(result)
            }
            // Files changed on disk regardless of what the face bar shows now: always announce
            // them so open editors refresh. Results and errors are scoped to the folder that is
            // still displayed — not its face-data revision, which every naming/merge edit made
            // during the write bumps (that hid earlier write failures).
            let changed = results.filter {
                $0.installedSidecar != nil || $0.didWriteEmbedded || $0.didWriteXMP
                    || $0.embeddedWriteMayHaveOccurred || $0.committedButUnverifiedSidecarURL != nil
            }.map(\.imageURL)
            if !changed.isEmpty {
                NotificationCenter.default.post(name: .faceMetadataDidChange, object: nil,
                    userInfo: ["imageURLs": changed])
            }
            guard faceData.map({ Self.fieldMutationFolderIdentity($0.folderURL) }) == Self.fieldMutationFolderIdentity(folderURL) else { return }
            fieldMutationResults = results
            if let failure = MetadataFieldMutationFeedback.failureSummary(results) { errorMessage = failure }
            let completedAny = results.contains(where: \.completed)
            updateFaceDataAfterOwnWrites(folderURL: folderURL,
                appliedNameUpdates: completedAny ? appliedNameUpdates : [:], ownWrites: ownWrites)
        }
    }

    private struct OwnPersonWrite {
        let url: URL
        let before: FileSignature
        let after: FileSignature
    }

    /// After our own verified Person Shown writes: remember the exact applied names, and move each
    /// rewritten photo's scan signature forward (only when it still described the pre-write file)
    /// so the next incremental scan keeps the faces of a photo whose pixels did not change.
    private func updateFaceDataAfterOwnWrites(folderURL: URL, appliedNameUpdates: [UUID: String?],
                                              ownWrites: [OwnPersonWrite]) {
        guard !appliedNameUpdates.isEmpty || !ownWrites.isEmpty else { return }
        guard var data = faceData,
              Self.fieldMutationFolderIdentity(data.folderURL) == Self.fieldMutationFolderIdentity(folderURL) else { return }
        if isScanning(folderURL: data.folderURL) {
            deferredAfterScan.append { [weak self] in
                self?.updateFaceDataAfterOwnWrites(folderURL: folderURL, appliedNameUpdates: appliedNameUpdates, ownWrites: ownWrites)
            }
            return
        }
        var changed = false
        var renamedSinceApply = data
        var hasStaleAppliedName = false
        for (groupID, name) in appliedNameUpdates {
            guard let index = data.groups.firstIndex(where: { $0.id == groupID }) else { continue }
            if data.groups[index].appliedPersonShownName != name {
                data.groups[index].appliedPersonShownName = name
                renamedSinceApply.groups[index].appliedPersonShownName = name
                changed = true
            }
            // The group was renamed while its write was in flight: offer the correction now.
            let current = data.groups[index].isExcludedFromPersonShown ? nil
                : data.groups[index].name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, current != name {
                renamedSinceApply.groups[index].name = name
                renamedSinceApply.groups[index].excludedFromPersonShown = nil
                hasStaleAppliedName = true
            }
        }
        for write in ownWrites {
            let key = write.url.path
            guard let stored = data.scannedFiles[key], stored.hasSameFileFacts(as: write.before),
                  !stored.hasSameFileFacts(as: write.after) else { continue }
            // A Person Shown write never changes pixels or orientation: the fingerprint holds.
            data.scannedFiles[key] = FileSignature(modificationDate: write.after.modificationDate,
                fileSize: write.after.fileSize, contentFingerprint: stored.contentFingerprint)
            changed = true
        }
        guard changed else { return }
        faceData = data
        scheduleFaceDataPersistence(data)
        if hasStaleAppliedName {
            renamedSinceApply.scannedFiles = data.scannedFiles
            offerPersonShownUpdate(before: renamedSinceApply, after: data)
        }
    }

    func waitForPendingFieldMutationWrites() async { await metadataWriteTask?.value }

    /// A face group (or confirmed player) is one person: its name is written as a single
    /// Person Shown entry. Splitting on commas broke Photo Mechanic style "Last, First" names.
    private func splitPersonNames(_ rawName: String) -> [String] {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    private func loadC2PALookup(urls: [URL]) async -> [URL: Bool] {
        guard !urls.isEmpty else { return [:] }
        do {
            let results = try await readService.readBatchBasicMetadata(urls: urls)
            var lookup: [URL: Bool] = [:]
            for dict in results {
                guard let sourcePath = dict[MetadataDictKey.sourceFile] as? String else { continue }
                let sourceURL = URL(fileURLWithPath: sourcePath)
                let hasC2PA = TechnicalMetadata.dictHasC2PA(dict)
                lookup[sourceURL] = hasC2PA
            }
            return lookup
        } catch {
            return [:]
        }
    }

    // MARK: - Edit Admission & Person Shown Corrections

    /// User-facing refusal when a face edit arrives while this folder is scanning.
    static let scanInProgressEditRefusal =
        "Faces can't be changed while this folder is being scanned. Wait for the scan to finish, then make the change again."

    /// A running scan publishes its own snapshot of this folder when it finishes, so names,
    /// merges, moves, deletions and Apply made meanwhile would be silently lost. Face views
    /// disable editing while this is true; the view model refuses such edits as well.
    func faceEditingPausedForScan(folderURL: URL? = nil) -> Bool {
        isScanning(folderURL: folderURL ?? faceData?.folderURL ?? displayedFolderURL)
    }

    private func refuseFaceEditDuringScan(_ folderURL: URL?, reports: Bool = true) -> Bool {
        guard faceEditingPausedForScan(folderURL: folderURL) else { return false }
        if reports { errorMessage = Self.scanInProgressEditRefusal }
        return true
    }

    /// Every interactive face-data edit: refused during this folder's scan, otherwise published,
    /// persisted, and checked for app-applied Person Shown names it made wrong.
    @discardableResult
    private func commitFaceEdit(_ data: FolderFaceData, failurePrefix: String = "Failed to save face data",
                                reportsScanRefusal: Bool = true) -> Bool {
        guard !refuseFaceEditDuringScan(data.folderURL, reports: reportsScanRefusal) else { return false }
        let before = faceData
        faceData = data
        scheduleFaceDataPersistence(data, failurePrefix: failurePrefix)
        if let before { offerPersonShownUpdate(before: before, after: data) }
        return true
    }

    private func offerPersonShownUpdate(before: FolderFaceData, after: FolderFaceData,
                                        excluding excludedURLs: Set<URL> = []) {
        guard Self.fieldMutationFolderIdentity(before.folderURL) == Self.fieldMutationFolderIdentity(after.folderURL),
              var proposal = PersonShownCorrectionPlanner.proposal(before: before, after: after) else { return }
        if !excludedURLs.isEmpty {
            let excludedPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })
            proposal.replacementsByURL = proposal.replacementsByURL.filter {
                !excludedPaths.contains($0.key.standardizedFileURL.path)
            }
            guard !proposal.replacementsByURL.isEmpty else { return }
        }
        if let pending = pendingPersonShownUpdate,
           Self.fieldMutationFolderIdentity(pending.folderURL) == Self.fieldMutationFolderIdentity(proposal.folderURL) {
            pendingPersonShownUpdate = pending.merged(with: proposal)
        } else {
            pendingPersonShownUpdate = proposal
        }
    }

    /// "Update": replace/remove only the exact app-applied names, through the field-mutation
    /// write path (presets, RAW → sidecar, loss guard), then record the new applied names.
    /// `knownC2PA`: the browser's content-credential status per photo (avoids re-reading files).
    func confirmPersonShownUpdate(knownC2PA: [URL: Bool]? = nil, onComplete: (() -> Void)? = nil) {
        guard let proposal = pendingPersonShownUpdate else { onComplete?(); return }
        pendingPersonShownUpdate = nil
        guard faceData.map({ Self.fieldMutationFolderIdentity($0.folderURL) })
                == Self.fieldMutationFolderIdentity(proposal.folderURL) else {
            errorMessage = "The face folder changed; Person Shown was not updated."
            onComplete?()
            return
        }
        guard !refuseFaceEditDuringScan(proposal.folderURL) else {
            pendingPersonShownUpdate = proposal
            onComplete?()
            return
        }
        guard !fieldMutationIsPaused(in: proposal.folderURL) else {
            errorMessage = "Face metadata writing is paused while files in this folder are being renamed."
            pendingPersonShownUpdate = proposal
            onComplete?()
            return
        }
        enqueuePersonMutations(mutationsByURL: proposal.replacementsByURL.mapValues { .replacePersons($0) },
            folderURL: proposal.folderURL, capturedC2PA: knownC2PA,
            appliedNameUpdates: proposal.appliedNameUpdates, onComplete: onComplete)
    }

    /// "Leave Photos Unchanged": photos keep their names; the applied names stay as they were,
    /// so a later correction still targets exactly what is in the photos.
    func declinePersonShownUpdate() {
        pendingPersonShownUpdate = nil
    }

    private func replayDeferredFaceUpdates() {
        let deferred = deferredAfterScan
        deferredAfterScan = []
        for update in deferred { update() }
    }

    /// Folder groups linked to a Known Person follow its rename, merge or deletion. Applied
    /// names then produce the usual "Update Person Shown" offer.
    func handleKnownPeopleIdentityChange(_ change: KnownPeopleIdentityChange) {
        guard var data = faceData else { return }
        if isScanning(folderURL: data.folderURL) {
            deferredAfterScan.append { [weak self] in self?.handleKnownPeopleIdentityChange(change) }
            return
        }
        var changed = false
        for index in data.groups.indices {
            guard let linked = data.groups[index].knownPersonID else { continue }
            switch change {
            case .renamed(let personID, let newName) where linked == personID:
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, data.groups[index].name != name {
                    data.groups[index].name = name
                    changed = true
                }
            case .merged(let sourceID, let targetID, let targetName) where linked == sourceID:
                data.groups[index].knownPersonID = targetID
                let name = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { data.groups[index].name = name }
                changed = true
            case .deleted(let personID) where linked == personID:
                // The folder keeps its name; only the identity link is gone.
                data.groups[index].knownPersonID = nil
                changed = true
            default:
                break
            }
        }
        guard changed else { return }
        commitFaceEdit(data, reportsScanRefusal: false)
    }

    // MARK: - Merge & Ungroup

    /// Merge sourceGroup into targetGroup. All faces move to target; source is deleted.
    func mergeGroups(sourceID: UUID, into targetID: UUID) {
        guard var data = faceData else { return }
        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)
        guard let sourceIndex = groupIdx[sourceID],
              let targetIndex = groupIdx[targetID],
              sourceIndex != targetIndex else { return }

        let sourceFaceIDs = data.groups[sourceIndex].faceIDs
        data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)
        data.groups[targetIndex].inheritAppliedName(from: data.groups[sourceIndex])

        // Update face groupIDs
        for faceID in sourceFaceIDs {
            if let fi = faceIdx[faceID] {
                data.faces[fi].groupID = targetID
            }
        }

        data.groups.remove(at: sourceIndex)
        commitFaceEdit(data)
    }

    /// Remove a single face from its group and place it in a new solo group.
    func ungroupFace(_ faceID: UUID) {
        guard var data = faceData else { return }
        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)
        guard let faceIndex = faceIdx[faceID],
              let oldGroupID = data.faces[faceIndex].groupID,
              let groupIndex = groupIdx[oldGroupID] else { return }

        // If already solo, just mark as user-created (pulls it out of the unmatched pool)
        if data.groups[groupIndex].faceIDs.count == 1 {
            guard data.groups[groupIndex].userCreated != true else { return }
            data.groups[groupIndex].userCreated = true
            commitFaceEdit(data)
            return
        }

        // Remove from old group
        data.groups[groupIndex].faceIDs.removeAll { $0 == faceID }

        // If the representative was removed, pick a new one
        if data.groups[groupIndex].representativeFaceID == faceID,
           let newRep = data.groups[groupIndex].faceIDs.first {
            data.groups[groupIndex].representativeFaceID = newRep
        }

        // Create new solo group
        let newGroup = FaceGroup(
            id: UUID(),
            name: nil,
            representativeFaceID: faceID,
            faceIDs: [faceID],
            userCreated: true
        )
        data.groups.append(newGroup)
        data.faces[faceIndex].groupID = newGroup.id

        commitFaceEdit(data)
    }

    /// Merge multiple groups into the first group in the set (by sort order).
    func mergeMultipleGroups(_ groupIDs: Set<UUID>) {
        guard groupIDs.count >= 2, var data = faceData else { return }

        // Use sorted order so the "first" group (named or largest) becomes the target
        let sorted = sortedGroups.filter { groupIDs.contains($0.id) }
        guard let target = sorted.first else { return }
        let sources = sorted.dropFirst()

        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)
        guard let targetIndex = groupIdx[target.id] else { return }
        var sourceIDs: Set<UUID> = []

        for source in sources {
            guard let sourceIndex = groupIdx[source.id] else { continue }

            let sourceFaceIDs = data.groups[sourceIndex].faceIDs
            data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)
            data.groups[targetIndex].inheritAppliedName(from: data.groups[sourceIndex])

            for faceID in sourceFaceIDs {
                if let fi = faceIdx[faceID] {
                    data.faces[fi].groupID = target.id
                }
            }

            sourceIDs.insert(source.id)
        }

        data.groups.removeAll { sourceIDs.contains($0.id) }

        commitFaceEdit(data)
    }

    /// Ungroup all selected groups — split every face into its own solo group.
    func ungroupMultiple(_ groupIDs: Set<UUID>) {
        guard var data = faceData else { return }

        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)

        for groupID in groupIDs {
            guard let groupIndex = groupIdx[groupID] else { continue }
            let group = data.groups[groupIndex]
            guard group.faceIDs.count > 1 else { continue }

            // Create solo groups for each face except the first (which stays as representative)
            // All resulting singletons go back to the unmatched pool (userCreated = nil)
            let remaining = Array(group.faceIDs.dropFirst())
            guard let firstFaceID = group.faceIDs.first else { continue }
            data.groups[groupIndex].faceIDs = [firstFaceID]
            data.groups[groupIndex].userCreated = nil
            data.groups[groupIndex].name = nil

            for faceID in remaining {
                let newGroup = FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: faceID,
                    faceIDs: [faceID]
                )
                data.groups.append(newGroup)
                if let fi = faceIdx[faceID] {
                    data.faces[fi].groupID = newGroup.id
                }
            }
        }

        commitFaceEdit(data)
    }

    /// Move faces into the unmatched pool by splitting them into non-user-created singletons.
    func moveToUnmatched(_ faceIDs: Set<UUID>) {
        guard var data = faceData else { return }

        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)

        for faceID in faceIDs {
            guard let faceIndex = faceIdx[faceID],
                  let oldGroupID = data.faces[faceIndex].groupID,
                  let groupIndex = groupIdx[oldGroupID] else { continue }

            if data.groups[groupIndex].faceIDs.count == 1 {
                // Already a singleton — just clear userCreated so it joins the unmatched pool
                data.groups[groupIndex].userCreated = nil
            } else {
                // Remove from old group
                data.groups[groupIndex].faceIDs.removeAll { $0 == faceID }
                if data.groups[groupIndex].representativeFaceID == faceID,
                   let newRep = data.groups[groupIndex].faceIDs.first {
                    data.groups[groupIndex].representativeFaceID = newRep
                }

                // Create new singleton (not user-created → goes to unmatched)
                let newGroup = FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: faceID,
                    faceIDs: [faceID]
                )
                data.groups.append(newGroup)
                data.faces[faceIndex].groupID = newGroup.id
            }
        }

        commitFaceEdit(data)
    }

    // MARK: - Move Faces Between Groups

    /// Move a single face from its current group to a target group.
    func moveFace(_ faceID: UUID, toGroup targetGroupID: UUID) {
        guard var data = faceData else { return }
        let faceIdx = faceIndexMap(from: data)
        var groupIdx = groupIndexMap(from: data)
        guard let faceIndex = faceIdx[faceID],
              let oldGroupID = data.faces[faceIndex].groupID,
              let oldGroupIndex = groupIdx[oldGroupID],
              groupIdx[targetGroupID] != nil,
              oldGroupID != targetGroupID else { return }

        // Remove from old group
        data.groups[oldGroupIndex].faceIDs.removeAll { $0 == faceID }

        // Clean up empty group or update representative
        if data.groups[oldGroupIndex].faceIDs.isEmpty {
            data.groups.remove(at: oldGroupIndex)
        } else if data.groups[oldGroupIndex].representativeFaceID == faceID,
                  let newRep = data.groups[oldGroupIndex].faceIDs.first {
            data.groups[oldGroupIndex].representativeFaceID = newRep
        }

        // Rebuild group index after potential removal
        groupIdx = groupIndexMap(from: data)
        guard let newTargetIndex = groupIdx[targetGroupID] else { return }

        // Add to target group
        data.groups[newTargetIndex].faceIDs.append(faceID)
        data.faces[faceIndex].groupID = targetGroupID

        commitFaceEdit(data)
    }

    /// Move multiple faces to a target group (single mutation + single save).
    func moveFaces(_ faceIDs: Set<UUID>, toGroup targetGroupID: UUID) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

        // Remove faces from their source groups
        removeFacesFromGroups(faceIDs, in: &data)

        // Add all faces to the target group
        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)
        guard let targetIndex = groupIdx[targetGroupID] else { return }
        for faceID in faceIDs {
            data.groups[targetIndex].faceIDs.append(faceID)
            if let fi = faceIdx[faceID] {
                data.faces[fi].groupID = targetGroupID
            }
        }

        commitFaceEdit(data)
    }

    /// Remove faces from their current groups and create a new group with them (single mutation + single save).
    /// The new group is inserted after the source groups to keep it visually close when in manual sort mode.
    func createNewGroup(withFaces faceIDs: Set<UUID>) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

        // Find source group IDs before removal (to determine insertion position)
        let preFaceIdx = faceIndexMap(from: data)
        let sourceGroupIDs = Set(faceIDs.compactMap { faceID -> UUID? in
            guard let faceIndex = preFaceIdx[faceID] else { return nil }
            return data.faces[faceIndex].groupID
        })

        // Find the highest index among source groups (for insertion position)
        let preGroupIdx = groupIndexMap(from: data)
        var maxSourceIndex = -1
        for groupID in sourceGroupIDs {
            if let index = preGroupIdx[groupID] {
                maxSourceIndex = max(maxSourceIndex, index)
            }
        }

        // Remove faces from their source groups
        removeFacesFromGroups(faceIDs, in: &data)

        // Create new group
        let faceIDArray = Array(faceIDs)
        guard let representativeID = faceIDArray.first else { return }
        let newGroup = FaceGroup(
            id: UUID(),
            name: nil,
            representativeFaceID: representativeID,
            faceIDs: faceIDArray,
            userCreated: true
        )

        // Insert after the last source group (accounting for potential removal of empty groups)
        let postGroupIdx = groupIndexMap(from: data)
        let insertionIndex: Int
        if maxSourceIndex >= 0 {
            // Count how many source groups were removed (became empty)
            var removedCount = 0
            for groupID in sourceGroupIDs {
                if postGroupIdx[groupID] == nil {
                    removedCount += 1
                }
            }
            // Adjust index: after the remaining source groups
            insertionIndex = min(maxSourceIndex - removedCount + 1, data.groups.count)
        } else {
            insertionIndex = data.groups.count
        }

        data.groups.insert(newGroup, at: max(0, insertionIndex))

        let faceIdx = faceIndexMap(from: data)
        for faceID in faceIDs {
            if let fi = faceIdx[faceID] {
                data.faces[fi].groupID = newGroup.id
            }
        }

        commitFaceEdit(data)
    }

    /// Place each given face into its own brand-new user-created group (one group per face).
    /// Used by "Add to Separate Groups" — pulls faces out of the unmatched pool (or any group)
    /// so each becomes an individual unnamed group rather than landing together.
    func createSeparateGroups(forFaces faceIDs: Set<UUID>) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

        // Detach from current groups, cleaning up empties/representatives.
        removeFacesFromGroups(faceIDs, in: &data)

        // faceIndexMap is stable across group appends, and removeFacesFromGroups
        // doesn't reorder the faces array, so this lookup stays valid below.
        let faceIdx = faceIndexMap(from: data)
        for faceID in faceIDs {
            guard let fi = faceIdx[faceID] else { continue }
            let newGroup = FaceGroup(
                id: UUID(),
                name: nil,
                representativeFaceID: faceID,
                faceIDs: [faceID],
                userCreated: true
            )
            data.groups.append(newGroup)
            data.faces[fi].groupID = newGroup.id
        }

        commitFaceEdit(data)
    }

    /// Promote every unmatched (auto-generated singleton) face into its own user-created
    /// group, emptying the synthetic "Unmatched Faces" pool. Singletons are already solo
    /// groups, so this just flips `userCreated` so they leave the pool.
    func splitAllUnmatchedIntoGroups() {
        guard var data = faceData else { return }

        var changed = false
        for i in data.groups.indices
        where data.groups[i].name == nil
            && data.groups[i].userCreated != true
            && data.groups[i].faceIDs.count == 1 {
            data.groups[i].userCreated = true
            changed = true
        }
        guard changed else { return }

        commitFaceEdit(data)
    }

    /// Remove faces from whatever groups they belong to, cleaning up empties and representatives.
    /// Mutates `data` in place without assigning to `faceData` or saving — caller is responsible.
    private func removeFacesFromGroups(_ faceIDs: Set<UUID>, in data: inout FolderFaceData) {
        let faceIdx = faceIndexMap(from: data)
        let groupIdx = groupIndexMap(from: data)

        for faceID in faceIDs {
            guard let faceIndex = faceIdx[faceID],
                  let oldGroupID = data.faces[faceIndex].groupID,
                  let oldGroupIndex = groupIdx[oldGroupID] else { continue }

            data.groups[oldGroupIndex].faceIDs.removeAll { $0 == faceID }

            if !data.groups[oldGroupIndex].faceIDs.isEmpty,
               data.groups[oldGroupIndex].representativeFaceID == faceID,
               let newRep = data.groups[oldGroupIndex].faceIDs.first {
                data.groups[oldGroupIndex].representativeFaceID = newRep
            }
        }

        // Remove emptied groups in one pass
        data.groups.removeAll { $0.faceIDs.isEmpty }
    }

    // MARK: - Delete Individual Faces

    /// Delete all faces that belong to the provided image URLs.
    func deleteFaces(forImageURLs imageURLs: Set<URL>) {
        guard !imageURLs.isEmpty else { return }

        guard let targetFolder = imageURLs.first?.deletingLastPathComponent(),
              imageURLs.allSatisfy({
                  $0.deletingLastPathComponent().standardizedFileURL.path == targetFolder.standardizedFileURL.path
              }),
              faceData == nil || faceData?.folderURL.standardizedFileURL.path == targetFolder.standardizedFileURL.path
        else { return }

        scheduleReservedFaceDeletion(in: targetFolder, selection: .photos(imageURLs))
    }

    private func scheduleReservedFaceDeletion(in targetFolder: URL, selection: FaceDataDeletionSelection,
                                              offersPersonShownUpdate: Bool = false) {
        let alreadyLoaded = faceData != nil
        let beforeDeletion = offersPersonShownUpdate ? faceData : nil
        if !alreadyLoaded { faceDataLoadTask?.cancel() }
        let requestID = UUID()
        let expectedRevision = faceDataRevision
        faceDataLoadRequestID = requestID
        let service = folderLoadService
        let pendingPersistence = faceDataPersistenceTask
        let task = Task(priority: .utility) { [weak self] in
            _ = await pendingPersistence?.value
            guard let self, !Task.isCancelled else { return }
            if !alreadyLoaded, self.faceDataLoadRequestID != requestID { return }
            let result: (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?)
            do {
                result = try await service.deleteFacesWithFolderReservation(
                    folderURL: targetFolder, selection: selection
                )
            } catch {
                guard !Task.isCancelled, self.faceDataLoadRequestID == requestID,
                      self.faceDataRevision == expectedRevision else { return }
                self.errorMessage = "Failed to delete face data: \(error.localizedDescription)"
                return
            }
            if case .committed = result.persistence {
                self.photoDeletionGenerations[targetFolder.standardizedFileURL.path, default: 0] &+= 1
                if case .complete(let evidence) = result.load {
                    self.durableFaceSnapshots[targetFolder.standardizedFileURL.path] = evidence.faceData
                }
            }
            guard !Task.isCancelled, self.faceDataLoadRequestID == requestID,
                  self.faceDataRevision == expectedRevision,
                  case .complete(let evidence) = result.load else { return }
            self.stalePhotoDeletionFolders.remove(targetFolder.standardizedFileURL.path)
            self.faceData = evidence.faceData
            self.scanComplete = evidence.scanCompleteWithThumbnails
            self.installThumbnails(evidence.thumbnailData)
            if let failure = result.persistence?.failureMessage {
                self.errorMessage = "Failed to delete face data: \(failure)"
            }
            if case .committed = result.persistence, let beforeDeletion, let after = evidence.faceData {
                // A deleted false positive must not leave its applied name in the photo.
                self.offerPersonShownUpdate(before: beforeDeletion, after: after)
            }
        }
        faceDataLoadTask = task
        // Subsequent queued writes must also wait for this transaction.
        faceDataPersistenceTask = task
    }

    /// Permanently delete faces from the data set (removes from groups, face list, thumbnail cache, and disk).
    func deleteFaces(_ faceIDs: Set<UUID>) {
        guard let data = faceData, !faceIDs.isEmpty else { return }
        guard !refuseFaceEditDuringScan(data.folderURL) else { return }
        scheduleReservedFaceDeletion(in: data.folderURL, selection: .faces(faceIDs), offersPersonShownUpdate: true)
    }

    /// Apply the confirmed face selection to the latest disk document while reserving
    /// the folder through photo Trash, document persistence, and thumbnail cleanup.
    @discardableResult
    func deleteGroup(_ groupID: UUID, includePhotos: Bool) async -> FaceGroupDeletionResult {
        guard let data = faceData, let group = groupLookup[groupID] else {
            return FaceGroupDeletionResult(trashedPhotoURLs: [], failures: [],
                cancellationStoppedRemainingPhotos: false, faceDataDisposition: .groupNotFound)
        }
        guard !refuseFaceEditDuringScan(data.folderURL) else {
            return FaceGroupDeletionResult(trashedPhotoURLs: [], failures: [],
                cancellationStoppedRemainingPhotos: false,
                faceDataDisposition: .failed(Self.scanInProgressEditRefusal))
        }
        let faceIDs = Set(group.faceIDs)
        let photosByID = Dictionary(uniqueKeysWithValues: data.faces.filter {
            faceIDs.contains($0.id)
        }.map { ($0.id, $0.imageURL.standardizedFileURL.path) })
        let folder = data.folderURL
        let folderIdentity = folder.standardizedFileURL.path
        let revision = faceDataRevision
        let preceding = faceDataPersistenceTask
        let operation = Task { [self] in
            _ = await preceding?.value
            var trash = FileSystemService.BatchMutationResult(completedSourceURLs: [],
                failures: [], cancellationStoppedRemainingItems: false)
            func result(_ disposition: FaceGroupDeletionResult.FaceDataDisposition) -> FaceGroupDeletionResult {
                FaceGroupDeletionResult(trashedPhotoURLs: trash.completedSourceURLs,
                    failures: trash.failures,
                    cancellationStoppedRemainingPhotos: trash.cancellationStoppedRemainingItems,
                    faceDataDisposition: disposition)
            }
            guard !Task.isCancelled else {
                trash = FileSystemService.BatchMutationResult(completedSourceURLs: [], failures: [],
                    cancellationStoppedRemainingItems: true)
                return result(.cancelledBeforeMutation)
            }
            do {
                let reservation = try MCPProcessReservation.acquireFolder(folder)
                defer { reservation.release() }
                guard case .complete(let snapshot) = await folderLoadService.loadDocument(folderURL: folder),
                      let latest = snapshot.faceData,
                      latest.folderURL.standardizedFileURL.path == folderIdentity else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Never let a replaced document redirect a confirmed Trash request.
                let selected = latest.faces.filter { faceIDs.contains($0.id) }
                guard selected.allSatisfy({
                    $0.imageURL.deletingLastPathComponent().standardizedFileURL.path == folderIdentity
                        && photosByID[$0.id] == $0.imageURL.standardizedFileURL.path
                }) else { throw CocoaError(.fileReadCorruptFile) }
                if includePhotos {
                    trash = await fileSystemService.trashItems(
                        Array(Set(selected.map(\.imageURL))), using: imageTrashHandler)
                }
                if Task.isCancelled, trash.completedSourceURLs.isEmpty, trash.failures.isEmpty {
                    trash = FileSystemService.BatchMutationResult(completedSourceURLs: [], failures: [],
                    cancellationStoppedRemainingItems: true)
                    return result(.cancelledBeforeMutation)
                }
                let deletion = try await folderLoadService.deleteFaces(
                    folderURL: folder, selection: .faces(faceIDs))
                if case .committed = deletion.persistence {
                    photoDeletionGenerations[folderIdentity, default: 0] &+= 1
                    if case .complete(let evidence) = deletion.load {
                        durableFaceSnapshots[folderIdentity] = evidence.faceData
                    }
                }
                if case .failedBeforeCommit(_, let failure) = deletion.persistence {
                    if faceDataRevision == revision { errorMessage = "Failed to delete face data: \(failure)" }
                    return result(.failed(failure))
                }
                if case .cancelledBeforeCommit = deletion.persistence {
                    return result(.failed("Face-data deletion was cancelled. Reload the folder before retrying."))
                }
                guard case .complete(let evidence) = deletion.load else {
                    return result(.failed("Face-data deletion was cancelled. Reload the folder before retrying."))
                }
                guard faceDataRevision == revision else { return result(.staleStatePreserved) }
                stalePhotoDeletionFolders.remove(folderIdentity)
                faceData = evidence.faceData
                scanComplete = evidence.scanCompleteWithThumbnails
                installThumbnails(evidence.thumbnailData)
                if let after = evidence.faceData {
                    // Photos that went to the Trash need no correction; the rest lose the
                    // deleted group's applied name unless another face still shows that person.
                    offerPersonShownUpdate(before: data, after: after, excluding: Set(trash.completedSourceURLs))
                }
                if let failure = deletion.persistence?.failureMessage {
                    errorMessage = "Failed to delete face data: \(failure)"
                    return result(.failed(failure))
                }
                return result(.applied)
            } catch {
                if faceDataRevision == revision {
                    errorMessage = "Failed to delete face data: \(error.localizedDescription)"
                }
                return result(.failed(error.localizedDescription))
            }
        }
        faceDataPersistenceTask = Task { _ = await operation.value }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    // MARK: - Delete Face Data

    func deleteFaceData(for folderURL: URL) {
        lensPrewarmTask?.cancel()
        if displayedFolderURL == folderURL.standardizedFileURL {
            faceDataLoadTask?.cancel()
            faceDataLoadRequestID = UUID()
        }
        scheduleFaceDataDeletion(for: folderURL)
    }

    // MARK: - Index Helpers

    private func faceIndexMap(from data: FolderFaceData) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: data.faces.enumerated().map { ($1.id, $0) })
    }

    private func groupIndexMap(from data: FolderFaceData) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: data.groups.enumerated().map { ($1.id, $0) })
    }

    // MARK: - Helper

    func faces(in group: FaceGroup) -> [DetectedFace] {
        // Use lookup dictionary for O(1) access per face instead of O(n).
        // Apply the live sharpness filter so blurry faces are hidden everywhere faces are shown.
        return group.faceIDs.compactMap { faceLookup[$0] }.filter(isVisibleByQuality)
    }

    /// Whether a face passes the live "minimum sharpness" filter. Faces with no capture-quality
    /// (scanned before the metric existed) always pass, so older data isn't hidden.
    func isVisibleByQuality(_ face: DetectedFace) -> Bool {
        guard let q = face.captureQuality else { return true }
        return q >= displayQualityThreshold
    }

    func face(byID faceID: UUID) -> DetectedFace? {
        faceLookup[faceID]
    }

    func group(byID groupID: UUID) -> FaceGroup? {
        groupLookup[groupID]
    }

    /// All detected faces in a specific image
    func facesForImage(_ imageURL: URL) -> [DetectedFace] {
        facesByImageURL[imageURL] ?? []
    }

    /// Standalone (back-turned) jersey-number detections for one image. Face-attached
    /// numbers live on the faces themselves (`jerseyNumber`/`jerseyNumberBox`).
    func numberDetectionsForImage(_ imageURL: URL) -> [NumberDetection] {
        faceData?.numberDetections?.filter { $0.imageURL == imageURL } ?? []
    }

    /// Face+group pairs for an image, sorted named-first then by face rect position
    func faceGroupPairs(forImageURL imageURL: URL) -> [(face: DetectedFace, group: FaceGroup?)] {
        let faces = facesForImage(imageURL)
        let pairs = faces.map { face in
            (face: face, group: face.groupID.flatMap { groupLookup[$0] })
        }
        return pairs.sorted { a, b in
            // Named groups first
            switch (a.group?.name, b.group?.name) {
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.face.faceRect.origin.x < b.face.faceRect.origin.x
            }
        }
    }

    func imageURLs(for group: FaceGroup) -> Set<URL> {
        let faces = faces(in: group)
        return Set(faces.map(\.imageURL))
    }

    func thumbnailImage(for faceID: UUID) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: faceID as NSUUID) {
            return cached.image
        }
        guard let data = thumbnailDataByFaceID[faceID], let image = NSImage(data: data) else { return nil }
        thumbnailCache.setObject(FaceThumbnailCacheEntry(image: image, data: data), forKey: faceID as NSUUID)
        return image
    }
}
