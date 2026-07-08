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

@Observable
final class FaceRecognitionViewModel {
    /// Stable ID for the synthetic "Unmatched Faces" group (singletons with no match)
    static let unmatchedGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var faceData: FolderFaceData? {
        didSet { invalidateCaches() }
    }

    /// Live "minimum sharpness" filter (0...1 face capture-quality). Faces below this are hidden
    /// from the displayed face set without re-scanning. Bound to the slider in the expanded face
    /// view and persisted to `faceMinQuality`.
    var displayQualityThreshold: Float = Float(
        UserDefaults.standard.object(forKey: UserDefaultsKeys.faceMinQuality) as? Double
            ?? Double(FaceRecognitionDefaults.minFaceQuality)
    ) {
        didSet {
            guard displayQualityThreshold != oldValue else { return }
            UserDefaults.standard.set(Double(displayQualityThreshold), forKey: UserDefaultsKeys.faceMinQuality)
            invalidateCaches()
        }
    }
    var isScanning = false
    var scanProgress: String = ""
    var scanComplete = false
    var errorMessage: String?

    // Thumbnail cache: faceID -> NSImage (NSCache with eviction, not observed to avoid re-render loops)
    @ObservationIgnored nonisolated(unsafe) private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
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
            try? storageService.saveFaceData(data)
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
        let storage = storageService
        let service = lensService

        lensPrewarmTask = Task(priority: .utility) { [weak self] in
            let outcome = await service.prewarm(faces: faces, folderURL: folderURL, storage: storage)
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
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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
    var matchRoster: MatchRoster?
    /// When set, the colour-cluster → team mapping needs the photographer to
    /// confirm (or flip) before names are written. Drives the confirm UI.
    var pendingColorClusterConfirmation: TeamColorClusterer.ClusterResult?
    /// Standalone numbers that couldn't be resolved unambiguously (same number on
    /// both teams with unknown side, etc.) — surfaced for manual assignment.
    var ambiguousNumberDetections: [NumberDetection] = []

    @ObservationIgnored private let matchRosterService = MatchRosterService()
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

        let confidence = UserDefaults.standard.object(forKey: UserDefaultsKeys.faceMinConfidence) as? Double
        config.minConfidence = Float(confidence ?? 0.7)
        let minSize = UserDefaults.standard.object(forKey: UserDefaultsKeys.faceMinFaceSize) as? Int
        config.minFaceSize = minSize ?? 50

        // Tiled detection recovers faces the single whole-image Vision pass misses (group shots).
        // Defaults on; absent key reads as nil so we keep the `true` default rather than `false`.
        config.tiledDetection = UserDefaults.standard.object(forKey: UserDefaultsKeys.faceTiledDetection) as? Bool ?? true

        // Sports tagging
        config.sportsModeEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.sportsModeEnabled)
        let ocrConf = UserDefaults.standard.object(forKey: UserDefaultsKeys.sportsOCRConfidenceThreshold) as? Double
        config.sportsOCRConfidenceThreshold = Float(ocrConf ?? 0.5)
        let minHeight = UserDefaults.standard.object(forKey: UserDefaultsKeys.sportsNumberMinHeightFraction) as? Double
        config.sportsNumberMinHeightFraction = CGFloat(minHeight ?? 0.02)

        return config
    }

    @ObservationIgnored private var activeScanTask: Task<Void, Never>?
    @ObservationIgnored private var metadataWriteTask: Task<Void, Never>?
    @ObservationIgnored private var lensPrewarmTask: Task<Void, Never>?
    private let detectionService = FaceDetectionService()
    /// Shared across off-main merge-suggestion recomputations so each face's feature print
    /// is unarchived once and reused, rather than allocating a fresh cache per call.
    /// FeaturePrintCache is thread-safe (`@unchecked Sendable`).
    @ObservationIgnored private let mergeFeaturePrintCache = FaceDetectionService.FeaturePrintCache()
    private let lensService = FaceLensService()
    private let storageService = FaceDataStorageService()
    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()
    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "FaceRecognitionViewModel")

    init(readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine) {
        self.readService = readService
        self.writeEngine = writeEngine
    }

    deinit {
        activeScanTask?.cancel()
        metadataWriteTask?.cancel()
        lensPrewarmTask?.cancel()
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

    func loadFaceData(for folderURL: URL, cleanupPolicy: FaceCleanupPolicy) {
        // Apply cleanup policy first
        try? storageService.applyCleanupIfNeeded(for: folderURL, policy: cleanupPolicy)

        lensPrewarmTask?.cancel()

        if let data = storageService.loadFaceData(for: folderURL) {
            self.faceData = data
            self.scanComplete = data.scanComplete
            loadThumbnails(for: data)
            prewarmSecondaryLensesIfNeeded()
        } else {
            self.faceData = nil
            self.scanComplete = false
            self.thumbnailCache.removeAllObjects()
        }
    }

    private func loadThumbnails(for data: FolderFaceData) {
        thumbnailCache.removeAllObjects()
        for group in data.groups {
            let faceID = group.representativeFaceID
            if let thumbData = storageService.loadThumbnail(for: faceID, folderURL: data.folderURL),
               let image = NSImage(data: thumbData) {
                thumbnailCache.setObject(image, forKey: faceID as NSUUID)
            }
        }
    }

    // MARK: - Scan Folder

    /// Scan folder for faces with incremental support.
    /// - Parameters:
    ///   - imageURLs: All image URLs in the folder
    ///   - folderURL: The folder being scanned
    ///   - forceFullScan: If true, deletes existing data and rescans all images
    func scanFolder(imageURLs: [URL], folderURL: URL, forceFullScan: Bool = false) {
        guard !isScanning else { return }

        // A scan invalidates the face set the prewarm was working from.
        lensPrewarmTask?.cancel()

        let config = detectionConfig
        let storageService = self.storageService
        let detectionService = self.detectionService

        if forceFullScan {
            // Full rescan: delete all existing data
            try? storageService.deleteFaceData(for: folderURL)
            faceData = nil
            thumbnailCache.removeAllObjects()
            scanComplete = false
            mergeSuggestions = []
        }

        isScanning = true
        errorMessage = nil
        scanningGroups = []

        activeScanTask = Task(priority: .utility) {
            // Load existing data for incremental scan
            // Discard stale data if embedding version is outdated (pre-alignment feature prints)
            let loadedData = forceFullScan ? nil : storageService.loadFaceData(for: folderURL)
            let existingData: FolderFaceData? = if let loadedData, (loadedData.embeddingVersion ?? 0) >= FaceRecognitionDefaults.embeddingVersion {
                loadedData
            } else {
                nil
            }

            // Determine which files need scanning
            let (toScan, toRemove, unchangedFiles) = await categorizeFiles(
                imageURLs: imageURLs,
                existingData: existingData
            )

            // Start with existing faces (excluding those from removed/modified files)
            let initialFaces: [DetectedFace] = existingData?.faces.filter { face in
                unchangedFiles.contains(face.imageURL.path)
            } ?? []

            var initialGroups: [FaceGroup] = existingData?.groups ?? []
            var initialScannedFiles = existingData?.scannedFiles ?? [:]

            // Keep standalone jersey numbers only for unchanged files: re-scanned
            // files regenerate their own, and removed files drop out.
            let initialNumbers: [NumberDetection] = existingData?.numberDetections?.filter { number in
                unchangedFiles.contains(number.imageURL.path)
            } ?? []

            // Remove faces from deleted/modified files
            let removedFaceIDs = Set(existingData?.faces.filter { face in
                toRemove.contains(face.imageURL.path)
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

            await MainActor.run {
                scanProgress = "0/\(toScan.count)"
            }

            if toScan.isEmpty {
                // Nothing new to scan
                await MainActor.run {
                    self.isScanning = false
                    self.scanComplete = true
                    self.scanProgress = ""
                    if let existingData {
                        self.faceData = existingData
                        self.loadThumbnails(for: existingData)
                        self.updateMergeSuggestions()
                    }
                }
                return
            }

            let scanLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FaceRecognitionViewModel")

            let (allFaces, allGroups, scannedFiles, allNumbers) = await withTaskGroup(
                of: (URL, FaceDetectionService.DetectionResult, Bool).self
            ) { taskGroup -> ([DetectedFace], [FaceGroup], [String: FileSignature], [NumberDetection]) in
                var allFaces = initialFaces
                var allGroups = initialGroups
                var scannedFiles = initialScannedFiles
                var allNumbers = initialNumbers
                var processed = 0
                var detectionErrors = 0
                var batchesSinceLastSave = 0
                let saveInterval = 10 // Save progress every 10 batches

                // Clustering runs incrementally per batch and matches each batch's new
                // faces against every existing group, deserializing those members'
                // feature prints (NSKeyedUnarchiver) on the way. Share one cache across
                // all batches so each face's feature print is unarchived once for the
                // whole scan instead of re-unarchived on every subsequent batch — without
                // this the per-batch work grows with the running face count (≈O(N²) total
                // unarchives over a scan). FeaturePrintCache is thread-safe.
                let visionFeaturePrintCache = FaceDetectionService.FeaturePrintCache()

                // Helper to process a completed batch and cluster incrementally
                func processBatch(scannedURL: URL, detection: FaceDetectionService.DetectionResult, failed: Bool) async {
                    if failed { detectionErrors += 1 }
                    allNumbers.append(contentsOf: detection.standaloneNumbers)
                    var newFaces: [DetectedFace] = []

                    for result in detection.faces {
                        allFaces.append(result.face)
                        newFaces.append(result.face)
                        do {
                            try storageService.saveThumbnail(result.thumbnail, for: result.face.id, folderURL: folderURL)
                        } catch {
                            logger.warning("Failed to save thumbnail for face \(result.face.id): \(error.localizedDescription)")
                        }
                        let image = NSImage(data: result.thumbnail)
                        if let image {
                            await MainActor.run {
                                thumbnailCache.setObject(image, forKey: result.face.id as NSUUID)
                            }
                        }
                    }

                    // Incremental clustering: cluster new faces immediately against existing groups
                    if !newFaces.isEmpty {
                        allGroups = detectionService.clusterFacesWithAlgorithm(newFaces, allFaces: allFaces, existingGroups: allGroups, config: config, cache: visionFeaturePrintCache)

                        // Assign group IDs to the newly clustered faces
                        let ungroupedIndex = Dictionary(
                            allFaces.enumerated().compactMap { (i, f) in f.groupID == nil ? (f.id, i) : nil },
                            uniquingKeysWith: { first, _ in first }
                        )
                        for group in allGroups {
                            for faceID in group.faceIDs {
                                if let index = ungroupedIndex[faceID] {
                                    allFaces[index].groupID = group.id
                                }
                            }
                        }
                    }

                    // Record file signature
                    if let sig = getFileSignature(for: scannedURL) {
                        scannedFiles[scannedURL.path] = sig
                    }

                    processed += 1
                    batchesSinceLastSave += 1

                    // Periodic save to preserve progress and update live UI
                    if batchesSinceLastSave >= saveInterval {
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
                        do {
                            try storageService.saveFaceData(progressData)
                        } catch {
                            await MainActor.run {
                                self.errorMessage = "Failed to save face data: \(error.localizedDescription)"
                            }
                        }
                        batchesSinceLastSave = 0

                        // Update intermediate UI state for live face bar
                        let groupsSnapshot = allGroups
                        await MainActor.run {
                            self.scanningGroups = groupsSnapshot
                        }
                    }

                    let current = processed
                    let total = toScan.count
                    let errors = detectionErrors
                    await MainActor.run {
                        scanProgress = errors > 0 ? "\(current)/\(total) (\(errors) failed)" : "\(current)/\(total)"
                    }
                }

                // Process images concurrently, capped at 4
                var pending = 0

                for url in toScan {
                    if Task.isCancelled {
                        taskGroup.cancelAll()
                        break
                    }

                    if pending >= 4 {
                        if let (scannedURL, detection, failed) = await taskGroup.next() {
                            await processBatch(scannedURL: scannedURL, detection: detection, failed: failed)
                        }
                        pending -= 1
                    }

                    taskGroup.addTask(priority: .utility) {
                        do {
                            let detection = try await detectionService.detectFaces(in: url, config: config)
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
                    await processBatch(scannedURL: scannedURL, detection: detection, failed: failed)
                }

                return (allFaces, allGroups, scannedFiles, allNumbers)
            }

            let isCancelled = Task.isCancelled

            let folderData = FolderFaceData(
                folderURL: folderURL,
                faces: allFaces,
                groups: allGroups,
                lastScanDate: Date(),
                scanComplete: !isCancelled,
                scannedFiles: scannedFiles,
                embeddingVersion: FaceRecognitionDefaults.embeddingVersion,
                numberDetections: allNumbers
            )

            do {
                try storageService.saveFaceData(folderData)
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to save face data: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                self.faceData = folderData
                self.isScanning = false
                self.scanComplete = !isCancelled
                self.scanProgress = ""
                self.scanningGroups = []
                self.activeScanTask = nil
                self.loadThumbnails(for: folderData)
                self.updateMergeSuggestions()

                // Sports mode: resolve detected numbers → player names (or surface
                // the colour-mapping confirmation if not yet confirmed).
                if config.sportsModeEnabled {
                    self.loadMatchRoster(for: folderURL)
                    self.runSportsResolution()
                }
            }

            guard !isCancelled else { return }

            // Known People matching is always automatic now. `applyKnownPeopleMatches`
            // no-ops when the database is empty, so this is safe to always call.
            await self.matchKnownPeopleIntegrated()

            // Face results are live; compute the secondary lenses in the background.
            self.prewarmSecondaryLensesIfNeeded()
        }
    }

    func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        isScanning = false
        scanProgress = ""
        scanningGroups = []
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
        let unnamedGroups = data.groups.filter { $0.name == nil }
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

            // Merge other matching groups into the target
            for match in sorted.dropFirst() {
                guard let sourceIndex = groupIdx[match.groupID],
                      sourceIndex != targetIndex else { continue }

                // Move faces from source to target
                let sourceFaceIDs = data.groups[sourceIndex].faceIDs
                data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)

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
        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        let groupsToCheck = unnamedGroups
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
                nameGroup(group.id, name: best.match.person.name)
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
        nameGroup(suggestion.groupID, name: suggestion.personName)
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
    func addGroupToKnownPeople(groupID: UUID, name: String) throws -> AddToKnownPeopleResult {
        guard let group = group(byID: groupID) else {
            throw AddToKnownPeopleError.groupNotFound
        }

        let faces = faces(in: group)
        guard !faces.isEmpty else {
            throw AddToKnownPeopleError.noFaces
        }

        let embeddings = faces.map { face in
            PersonEmbedding(
                featurePrintData: face.featurePrintData,
                sourceDescription: face.imageURL.lastPathComponent,
                recognitionMode: face.embeddingMode
            )
        }

        // Build per-embedding thumbnail map (embedding ID → small JPEG)
        var embeddingThumbnails: [UUID: Data] = [:]
        for (index, face) in faces.enumerated() {
            if let thumbImage = thumbnailImage(for: face.id),
               let smallData = generateSmallThumbnailData(from: thumbImage) {
                embeddingThumbnails[embeddings[index].id] = smallData
            }
        }

        var thumbnailData: Data?
        if let thumbImage = thumbnailImage(for: group.representativeFaceID),
           let tiffData = thumbImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData) {
            thumbnailData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
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

        let (person, addedToExisting) = try KnownPeopleService.shared.addOrMergePerson(
            name: name,
            embeddings: embeddings,
            thumbnailData: thumbnailData,
            embeddingThumbnails: embeddingThumbnails,
            duplicateCheck: duplicateCheck
        )

        return AddToKnownPeopleResult(
            addedToExisting: addedToExisting,
            embeddingCount: embeddings.count,
            name: name,
            personID: person.id
        )
    }

    /// Generate a small thumbnail (80×80) for embedding storage in the Known People database.
    private func generateSmallThumbnailData(from image: NSImage, size: Int = 80) -> Data? {
        let targetSize = NSSize(width: size, height: size)
        let smallImage = NSImage(size: targetSize)
        smallImage.lockFocus()

        let sourceSize = image.size
        let scale = max(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let drawRect = NSRect(
            x: (targetSize.width - scaledWidth) / 2,
            y: (targetSize.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        smallImage.unlockFocus()

        guard let tiffData = smallImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
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
            for faceID in sourceFaceIDs {
                if let fi = faceIdx[faceID] { data.faces[fi].groupID = suggestion.group1ID }
            }
            removedSourceIDs.insert(suggestion.group2ID)
        }

        guard !removedSourceIDs.isEmpty else { return 0 }
        data.groups.removeAll { removedSourceIDs.contains($0.id) }

        faceData = data
        mergeSuggestions.removeAll()
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        if let personID = knownPersonMatchByGroup[groupID]?.personID {
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

    func nameGroup(_ groupID: UUID, name: String) {
        guard var data = faceData else { return }
        let groupIdx = groupIndexMap(from: data)
        guard let index = groupIdx[groupID] else { return }

        data.groups[index].name = name.isEmpty ? nil : name
        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
    }

    /// Assign (or clear, with `nil`) a hand-picked jersey number for a group. Display-only —
    /// see `groupNumber(_:)`. Persisted alongside the rest of the face data.
    func setManualNumber(_ number: Int?, forGroup groupID: UUID) {
        guard var data = faceData else { return }
        let groupIdx = groupIndexMap(from: data)
        guard let index = groupIdx[groupID] else { return }

        data.groups[index].manualNumber = number
        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
    }

    func setRepresentativeFace(_ faceID: UUID, forGroup groupID: UUID) {
        guard var data = faceData else { return }
        let groupIdx = groupIndexMap(from: data)
        guard let index = groupIdx[groupID],
              data.groups[index].faceIDs.contains(faceID) else { return }

        data.groups[index].representativeFaceID = faceID
        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
    }

    // MARK: - Sports tagging: match setup & resolution

    /// Load the per-folder match roster, if one was saved.
    func loadMatchRoster(for folderURL: URL) {
        matchRoster = matchRosterService.load(for: folderURL)
    }

    /// Set the two teams for this folder, embedding current library snapshots.
    /// Changing teams invalidates any previous colour-mapping confirmation.
    func setMatchTeams(homeTeamID: UUID?, awayTeamID: UUID?, folderURL: URL) {
        var roster = matchRoster ?? MatchRoster(folderURL: folderURL)
        roster.folderURL = folderURL
        roster.mode = .team
        roster.homeTeamID = homeTeamID
        roster.awayTeamID = awayTeamID
        roster.homeTeamSnapshot = homeTeamID.flatMap { RosterStore.shared.team(byID: $0) }
        roster.awayTeamSnapshot = awayTeamID.flatMap { RosterStore.shared.team(byID: $0) }
        roster.clusterMappingConfirmed = false
        matchRoster = roster
        try? matchRosterService.save(roster)
    }

    /// Set a single startlist for an individual-sport event (bib mode). Bib numbers resolve
    /// directly to athletes — no team colour, no home/away confirm step. The startlist is held
    /// in the home slot; away stays empty.
    func setEventStartlist(teamID: UUID?, folderURL: URL) {
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
        try? matchRosterService.save(roster)
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
    func confirmClusterMapping(flip: Bool) {
        guard var roster = matchRoster else { return }
        roster.clusterMappingConfirmed = true
        roster.clusterFlipped = flip
        matchRoster = roster
        try? matchRosterService.save(roster)

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
        faceData = data
        ambiguousNumberDetections = result.ambiguous
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save sports resolution: \(error.localizedDescription)"
        }
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
        nameGroup(groupID, name: resolvedDisplayName(for: player))
        if let personID = player.knownPersonID {
            knownPersonMatchByGroup[groupID] = (personID: personID, confidence: 1.0)
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
        faceData = data
        ambiguousNumberDetections.removeAll { $0.id == detectionID }
        try? storageService.saveFaceData(data)
    }

    /// Mutate a single number claim's confirmation state and persist. Confirmed claims (and only
    /// confirmed claims) write their resolved player name to metadata on Apply.
    private func setClaimState(_ state: NumberClaimState, forNumberDetection detectionID: UUID) {
        guard var data = faceData, data.numberDetections != nil,
              let i = data.numberDetections!.firstIndex(where: { $0.id == detectionID }) else { return }
        data.numberDetections![i].claimState = state
        faceData = data
        try? storageService.saveFaceData(data)
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
            faceData = data
            try? storageService.saveFaceData(data)
        } else if let resolved = data.numberDetections![i].resolvedPlayerName?.trimmingCharacters(in: .whitespacesAndNewlines), !resolved.isEmpty {
            data.numberDetections![i].claimState = .confirmed
            faceData = data
            try? storageService.saveFaceData(data)
            // Name the previously-unnamed group with the number's player (user-asserted identity).
            nameGroup(groupID, name: resolved)
        } else {
            faceData = data
            try? storageService.saveFaceData(data)
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
        faceData = data
        try? storageService.saveFaceData(data)
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
        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// If a face group carries a jersey number that maps to a roster player on a
    /// known side, return the data needed to link it to Known People. `nil` when
    /// the group has no resolvable number/side yet.
    func rosterLinkTarget(forGroup groupID: UUID) -> (number: Int, teamID: UUID, playerName: String)? {
        guard let data = faceData,
              let match = matchRoster,
              let group = groupLookup[groupID] else { return nil }

        let facesByID = Dictionary(data.faces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var votes: [String: (count: Int, conf: Float, number: Int, side: TeamSide?)] = [:]
        for faceID in group.faceIDs {
            guard let face = facesByID[faceID], let number = face.jerseyNumber else { continue }
            let key = "\(number)-\(face.teamSide?.rawValue ?? "?")"
            var vote = votes[key] ?? (0, 0, number, face.teamSide)
            vote.count += 1
            vote.conf += face.numberConfidence ?? 0
            votes[key] = vote
        }
        guard let best = votes.values.max(by: { ($0.count, $0.conf) < ($1.count, $1.conf) }),
              let side = best.side,
              let teamID = (side == .home ? match.homeTeamID : match.awayTeamID),
              let player = match.team(for: side)?.player(forNumber: best.number) else { return nil }
        return (best.number, teamID, player.playerName)
    }

    /// The bridge: confirm a face group is a roster player, promoting the group's
    /// faces into Known People and stamping the new person's id onto the roster
    /// entry so future games recognise the player by face.
    @discardableResult
    func linkPlayerToKnownPeople(groupID: UUID, playerNumber: Int, teamID: UUID) -> Bool {
        guard let team = RosterStore.shared.team(byID: teamID),
              let player = team.roster.first(where: { $0.number == playerNumber }) else { return false }
        do {
            let result = try addGroupToKnownPeople(groupID: groupID, name: player.playerName)
            try RosterStore.shared.linkKnownPerson(result.personID, toPlayerNumber: playerNumber, teamID: teamID)
            return true
        } catch {
            errorMessage = "Failed to link player to Known People: \(error.localizedDescription)"
            return false
        }
    }

    func applyNameToMetadata(groupID: UUID) {
        guard let data = faceData,
              let group = groupLookup[groupID],
              let name = group.name, !name.isEmpty else { return }

        let names = splitPersonNames(name)
        guard !names.isEmpty else { return }

        let imageURLs = group.faceIDs.compactMap { faceID in
            faceLookup[faceID]?.imageURL
        }
        let uniqueURLs = Array(Set(imageURLs))

        guard !uniqueURLs.isEmpty else { return }

        metadataWriteTask?.cancel()
        metadataWriteTask = Task {
            let c2paLookup = await loadC2PALookup(urls: uniqueURLs)
            let folderURL = data.folderURL

            for url in uniqueURLs {
                let hasC2PA = c2paLookup[url] ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA, isRaw: SupportedImageFormats.isRaw(url: url))

                switch mode {
                case .historyOnly:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: false,
                        pendingChanges: true
                    )
                case .writeToFileAndXMPSidecar:
                    // Dual write: .xmp sidecar (+ history) and the embedded file.
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: true,
                        pendingChanges: false
                    )
                    await applyNamesToFile(url: url, names: names)
                case .writeToXMPSidecar:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: true,
                        pendingChanges: false
                    )
                case .writeToFile:
                    // PM-style embed: the file is the record, but an .xmp already on
                    // disk must mirror it or its stale values shadow the file.
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: xmpSidecarService.sidecarExists(for: url),
                        pendingChanges: false
                    )
                    await applyNamesToFile(url: url, names: names)
                }
            }

            await MainActor.run {
                NotificationCenter.default.post(name: .faceMetadataDidChange, object: nil)
            }
        }
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

        let availableURLs = Set(images.map(\.url))
        var namesByURL: [URL: [String]] = [:]
        var seenNamesByURL: [URL: Set<String>] = [:]

        for face in data.faces {
            guard availableURLs.contains(face.imageURL),
                  let groupID = face.groupID,
                  let group = groupLookup[groupID],
                  let rawName = group.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { continue }

            let names = splitPersonNames(rawName)
            guard !names.isEmpty else { continue }

            var existing = namesByURL[face.imageURL] ?? []
            var seen = seenNamesByURL[face.imageURL] ?? Set(existing.map { $0.lowercased() })
            for name in names {
                let key = name.lowercased()
                if seen.insert(key).inserted {
                    existing.append(name)
                }
            }
            namesByURL[face.imageURL] = existing
            seenNamesByURL[face.imageURL] = seen
        }

        // Jersey-number claims (including back-turned players with no face) only write when the
        // photographer has them in front of them: the Sports lens must be active. Switch away to
        // Face and number-derived names stop being applied — the detections stay in the folder's
        // .face_data, but nothing is written from a number alone. Within Sports, only *confirmed*
        // claims write; suggested/rejected/ambiguous ones never reach metadata. Names that overlap
        // a face group dedupe against the per-URL set built above.
        if activeLens == .sports {
            for det in data.numberDetections ?? [] where det.effectiveClaimState == .confirmed {
                guard availableURLs.contains(det.imageURL),
                      let rawName = det.resolvedPlayerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawName.isEmpty else { continue }
                let names = splitPersonNames(rawName)
                guard !names.isEmpty else { continue }

                var existing = namesByURL[det.imageURL] ?? []
                var seen = seenNamesByURL[det.imageURL] ?? Set(existing.map { $0.lowercased() })
                for name in names where seen.insert(name.lowercased()).inserted {
                    existing.append(name)
                }
                namesByURL[det.imageURL] = existing
                seenNamesByURL[det.imageURL] = seen
            }
        }

        guard !namesByURL.isEmpty else {
            onComplete?()
            return
        }

        let c2paLookup = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0.hasC2PA) })

        metadataWriteTask?.cancel()
        metadataWriteTask = Task {
            for (url, names) in namesByURL {
                let hasC2PA = c2paLookup[url] ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA, isRaw: SupportedImageFormats.isRaw(url: url))

                switch mode {
                case .historyOnly:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: false,
                        pendingChanges: true
                    )
                case .writeToFileAndXMPSidecar:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: true,
                        pendingChanges: false
                    )
                    await applyNamesToFile(url: url, names: names)
                case .writeToXMPSidecar:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: true,
                        pendingChanges: false
                    )
                case .writeToFile:
                    // PM-style embed: the file is the record, but an .xmp already on
                    // disk must mirror it or its stale values shadow the file.
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: xmpSidecarService.sidecarExists(for: url),
                        pendingChanges: false
                    )
                    await applyNamesToFile(url: url, names: names)
                }
            }

            await MainActor.run {
                NotificationCenter.default.post(name: .faceMetadataDidChange, object: nil)
                onComplete?()
            }
        }
    }

    private func splitPersonNames(_ rawName: String) -> [String] {
        rawName
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func mergePersons(existing: [String], adding: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing.map { $0.lowercased() })
        for name in adding {
            if seen.insert(name.lowercased()).inserted {
                merged.append(name)
            }
        }
        return merged
    }

    @discardableResult
    private func applyNamesToFile(url: URL, names: [String]) async -> Bool {
        do {
            let existing = try await readService.readFullMetadata(url: url)
            let merged = mergePersons(existing: existing.personShown, adding: names)
            guard merged != existing.personShown else { return true }
            let value = merged.joined(separator: ", ")
            try await writeEngine.writeFields([.personInImage: value], to: [url])
            return true
        } catch {
            // Continue with next image
            return false
        }
    }

    private func applyNamesToSidecar(
        url: URL,
        folderURL: URL?,
        names: [String],
        writeXmpSidecar: Bool,
        pendingChanges: Bool
    ) async {
        guard let folderURL else { return }

        var baseMetadata: IPTCMetadata
        var history: [MetadataHistoryEntry] = []
        var snapshot: IPTCMetadata?
        let hadSidecar: Bool

        if let existingSidecar = sidecarService.loadSidecar(for: url, in: folderURL) {
            baseMetadata = existingSidecar.metadata
            history = existingSidecar.history
            history.trimToHistoryLimit()
            snapshot = existingSidecar.imageMetadataSnapshot
            hadSidecar = true
        } else {
            baseMetadata = IPTCMetadata()
            hadSidecar = false
        }

        if snapshot == nil {
            snapshot = await loadBaseMetadata(url: url)
        }

        if !hadSidecar {
            // Never seed a new record from nothing: a partial sidecar holding only
            // personShown would become the authoritative record and mask the file's
            // other descriptive fields on read and export.
            guard let snapshot else {
                errorMessage = "Could not read metadata for \(url.lastPathComponent); person names were not written to its sidecar."
                return
            }
            baseMetadata = snapshot
        }

        let merged = mergePersons(existing: baseMetadata.personShown, adding: names)
        guard merged != baseMetadata.personShown else { return }

        let oldValue = baseMetadata.personShown.isEmpty ? nil : baseMetadata.personShown.joined(separator: ", ")
        let newValue = merged.isEmpty ? nil : merged.joined(separator: ", ")

        if oldValue != newValue {
            history.append(MetadataHistoryEntry(
                timestamp: Date(),
                fieldName: "Person Shown",
                oldValue: oldValue,
                newValue: newValue
            ))
            history.trimToHistoryLimit()
        }

        var updatedMetadata = baseMetadata
        updatedMetadata.personShown = merged

        let sidecar = MetadataSidecar(
            sourceFile: url.lastPathComponent,
            lastModified: Date(),
            pendingChanges: pendingChanges,
            metadata: updatedMetadata,
            imageMetadataSnapshot: pendingChanges ? snapshot : updatedMetadata,
            history: history
        )

        do {
            try sidecarService.saveSidecar(sidecar, for: url, in: folderURL)
        } catch {
            errorMessage = "Failed to save metadata sidecar: \(error.localizedDescription)"
        }

        if writeXmpSidecar {
            do {
                try xmpSidecarService.saveSidecar(metadata: updatedMetadata, for: url)
            } catch {
                errorMessage = "Failed to save XMP sidecar: \(error.localizedDescription)"
            }
        }
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

    private func loadBaseMetadata(url: URL) async -> IPTCMetadata? {
        do {
            var metadata = try await readService.readFullMetadata(url: url)
            if let xmpMetadata = xmpSidecarService.loadSidecar(for: url) {
                // Record semantics, matching the panel's reference read: a descriptive
                // sidecar IS the record (clears stick — don't reseed cleared fields
                // from embedded); develop-only sidecars overlay additively.
                metadata = xmpMetadata.hasDescriptiveContent
                    ? metadata.replacingDescriptiveFields(from: xmpMetadata)
                    : metadata.merged(preferring: xmpMetadata)
            }
            return metadata
        } catch {
            return nil
        }
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

        // Update face groupIDs
        for faceID in sourceFaceIDs {
            if let fi = faceIdx[faceID] {
                data.faces[fi].groupID = targetID
            }
        }

        data.groups.remove(at: sourceIndex)
        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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
            faceData = data
            do { try storageService.saveFaceData(data) }
            catch { errorMessage = "Failed to save face data: \(error.localizedDescription)" }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

            for faceID in sourceFaceIDs {
                if let fi = faceIdx[faceID] {
                    data.faces[fi].groupID = target.id
                }
            }

            sourceIDs.insert(source.id)
        }

        data.groups.removeAll { sourceIDs.contains($0.id) }

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        faceData = data
        do { try storageService.saveFaceData(data) }
        catch { errorMessage = "Failed to save face data: \(error.localizedDescription)" }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
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

        let targetFolder = imageURLs.first?.deletingLastPathComponent()
        if faceData == nil, let targetFolder {
            if let loaded = storageService.loadFaceData(for: targetFolder) {
                faceData = loaded
                scanComplete = loaded.scanComplete
                loadThumbnails(for: loaded)
            }
        }

        guard let data = faceData,
              targetFolder == nil || data.folderURL == targetFolder else { return }

        let faceIDs = Set(data.faces.compactMap { face in
            imageURLs.contains(face.imageURL) ? face.id : nil
        })

        deleteFaces(faceIDs)
    }

    /// Permanently delete faces from the data set (removes from groups, face list, thumbnail cache, and disk).
    func deleteFaces(_ faceIDs: Set<UUID>) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

        // Remove from groups (cleans up empties)
        removeFacesFromGroups(faceIDs, in: &data)

        // Remove from the face list
        data.faces.removeAll { faceIDs.contains($0.id) }

        // Remove thumbnails from cache and disk
        for faceID in faceIDs {
            thumbnailCache.removeObject(forKey: faceID as NSUUID)
            storageService.deleteThumbnail(for: faceID, folderURL: data.folderURL)
        }

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
    }

    /// Delete an entire group: removes all face data and optionally trashes the source photos.
    /// Returns the set of photo URLs that were trashed (empty if `includePhotos` is false).
    @discardableResult
    func deleteGroup(_ groupID: UUID, includePhotos: Bool) -> Set<URL> {
        guard var data = faceData,
              let group = groupLookup[groupID] else { return [] }

        let faceIDs = Set(group.faceIDs)

        // Collect photo URLs before removing face data
        var trashedURLs: Set<URL> = []
        if includePhotos {
            let urls = Set(group.faceIDs.compactMap { faceID in
                faceLookup[faceID]?.imageURL
            })
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashedURLs.insert(url)
                } catch {
                    // Skip files that can't be trashed
                }
            }
        }

        // Remove from groups
        removeFacesFromGroups(faceIDs, in: &data)

        // Remove from the face list
        data.faces.removeAll { faceIDs.contains($0.id) }

        // Clean up thumbnails
        for faceID in faceIDs {
            thumbnailCache.removeObject(forKey: faceID as NSUUID)
            storageService.deleteThumbnail(for: faceID, folderURL: data.folderURL)
        }

        faceData = data
        do {
            try storageService.saveFaceData(data)
        } catch {
            errorMessage = "Failed to save face data: \(error.localizedDescription)"
        }
        return trashedURLs
    }

    // MARK: - Delete Face Data

    func deleteFaceData(for folderURL: URL) {
        lensPrewarmTask?.cancel()
        try? storageService.deleteFaceData(for: folderURL)
        faceData = nil
        thumbnailCache.removeAllObjects()
        scanComplete = false
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
        if let cached = thumbnailCache.object(forKey: faceID as NSUUID) { return cached }

        guard let folderURL = faceData?.folderURL,
              let data = storageService.loadThumbnail(for: faceID, folderURL: folderURL),
              let image = NSImage(data: data) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: faceID as NSUUID)
        return image
    }
}

// MARK: - Incremental Scan Helpers (Non-Actor)

/// Categorize files into: need scanning, removed/modified, unchanged.
nonisolated private func categorizeFiles(imageURLs: [URL], existingData: FolderFaceData?) async -> (toScan: [URL], toRemove: Set<String>, unchanged: Set<String>) {
    guard let existingData else {
        return (imageURLs, [], [])
    }

    let currentPaths = Set(imageURLs.map(\.path))
    let existingPaths = Set(existingData.scannedFiles.keys)

    var toScan: [URL] = []
    var unchanged: Set<String> = []

    for url in imageURLs {
        let path = url.path
        if let existingSig = existingData.scannedFiles[path],
           let currentSig = getFileSignature(for: url),
           existingSig == currentSig {
            // File unchanged
            unchanged.insert(path)
        } else {
            // New or modified file
            toScan.append(url)
        }
    }

    // Files in existing data but not in current folder = deleted
    let toRemove = existingPaths.subtracting(currentPaths).union(
        // Also include modified files (they need faces removed before re-scanning)
        Set(toScan.map(\.path)).intersection(existingPaths)
    )

    return (toScan, toRemove, unchanged)
}

nonisolated private func getFileSignature(for url: URL) -> FileSignature? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modDate = attrs[.modificationDate] as? Date,
          let size = attrs[.size] as? Int64 else {
        return nil
    }
    return FileSignature(modificationDate: modDate, fileSize: size)
}
