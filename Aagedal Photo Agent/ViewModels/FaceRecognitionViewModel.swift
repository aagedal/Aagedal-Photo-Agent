import Foundation
import AppKit

enum FaceGroupSortMode: String, CaseIterable {
    case manual = "Insertion Order"
    case bySize = "Largest First"
}

@Observable
final class FaceRecognitionViewModel {
    var faceData: FolderFaceData? {
        didSet { invalidateCaches() }
    }
    var isScanning = false
    var scanProgress: String = ""
    var scanComplete = false
    var errorMessage: String?

    // Thumbnail cache: faceID -> NSImage (not observed to avoid re-render loops during lazy loading)
    @ObservationIgnored var thumbnailCache: [UUID: NSImage] = [:]

    // Merge suggestions for similar groups
    var mergeSuggestions: [MergeSuggestion] = []

    // Intermediate groups shown during active scan (for live UI feedback)
    var scanningGroups: [FaceGroup] = []

    // Sort mode for face groups
    var sortMode: FaceGroupSortMode = .manual {
        didSet { invalidateCaches() }
    }

    // Track matches between groups and known people
    // Maps groupID -> (knownPersonID, matchConfidence)
    var knownPersonMatchByGroup: [UUID: (personID: UUID, confidence: Float)] = [:]

    // The currently selected group for thumbnail replacement (only one at a time)
    var selectedThumbnailReplacementGroupID: UUID?
    // The currently selected face within that group for thumbnail replacement
    var selectedThumbnailReplacementFaceID: UUID?

    // Cached sorted groups (invalidated when faceData changes)
    private(set) var sortedGroups: [FaceGroup] = []

    // Fast face lookup by ID (invalidated when faceData changes)
    // Not observed - always rebuilt alongside sortedGroups
    @ObservationIgnored private var faceLookup: [UUID: DetectedFace] = [:]

    // Fast group lookup by ID (invalidated when faceData changes)
    // Not observed - always rebuilt alongside sortedGroups
    @ObservationIgnored private var groupLookup: [UUID: FaceGroup] = [:]

    // Detection configuration from settings
    var detectionConfig: FaceDetectionService.DetectionConfig {
        var config = FaceDetectionService.DetectionConfig()

        // Recognition mode settings
        let modeRaw = UserDefaults.standard.string(forKey: "faceRecognitionMode") ?? "vision"
        config.recognitionMode = FaceRecognitionMode(rawValue: modeRaw) ?? .visionFeaturePrint

        // Mode-specific clustering thresholds
        let threshold: Double
        switch config.recognitionMode {
        case .visionFeaturePrint:
            threshold = UserDefaults.standard.object(forKey: "visionClusteringThreshold") as? Double ?? 0.40
        case .faceAndClothing:
            threshold = UserDefaults.standard.object(forKey: "faceClothingClusteringThreshold") as? Double ?? 0.48
        }
        config.clusteringThreshold = Float(threshold)

        let confidence = UserDefaults.standard.object(forKey: "faceMinConfidence") as? Double
        config.minConfidence = Float(confidence ?? 0.7)
        let minSize = UserDefaults.standard.object(forKey: "faceMinFaceSize") as? Int
        config.minFaceSize = minSize ?? 50

        let faceWeight = UserDefaults.standard.object(forKey: "faceFaceWeight") as? Double
        config.faceWeight = Float(faceWeight ?? 0.7)
        config.clothingWeight = 1.0 - config.faceWeight

        // Clustering algorithm settings
        let algorithmRaw = UserDefaults.standard.string(forKey: "faceClusteringAlgorithm") ?? "chineseWhispers"
        config.clusteringAlgorithm = FaceClusteringAlgorithm(rawValue: algorithmRaw) ?? .chineseWhispers

        let qualityGate = UserDefaults.standard.object(forKey: "faceQualityGateThreshold") as? Double
        config.qualityGateThreshold = Float(qualityGate ?? 0.6)

        let useQualityWeighted = UserDefaults.standard.object(forKey: "faceUseQualityWeightedEdges") as? Bool
        config.useQualityWeightedEdges = useQualityWeighted ?? true

        let attachSecondPass = UserDefaults.standard.object(forKey: "faceClothingSecondPassAttachToExisting") as? Bool
        config.faceClothingSecondPassAttachToExisting = attachSecondPass ?? false

        return config
    }

    /// Current recognition mode from settings
    var recognitionMode: FaceRecognitionMode {
        let modeRaw = UserDefaults.standard.string(forKey: "faceRecognitionMode") ?? "vision"
        return FaceRecognitionMode(rawValue: modeRaw) ?? .visionFeaturePrint
    }

    /// Check if loaded face data was scanned with a different mode than current settings
    var needsRescanForModeChange: Bool {
        guard let data = faceData else { return false }
        // Legacy data (nil mode) is compatible with Vision mode
        let dataMode = data.recognitionMode ?? .visionFeaturePrint
        return dataMode != recognitionMode
    }

    private let detectionService = FaceDetectionService()
    private let storageService = FaceDataStorageService()
    private let exifToolService: ExifToolService
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
    }

    // MARK: - Cache Management

    private func invalidateCaches() {
        // Rebuild sorted groups
        guard let groups = faceData?.groups else {
            sortedGroups = []
            faceLookup = [:]
            groupLookup = [:]
            return
        }

        switch sortMode {
        case .bySize:
            // Named groups first (alphabetical), then unnamed (by size descending)
            sortedGroups = groups.sorted { a, b in
                switch (a.name, b.name) {
                case let (nameA?, nameB?):
                    return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return a.faceIDs.count > b.faceIDs.count
                }
            }
        case .manual:
            // Named groups first (alphabetical), then unnamed in array order (insertion order)
            let named = groups.filter { $0.name != nil }.sorted {
                $0.name!.localizedCaseInsensitiveCompare($1.name!) == .orderedAscending
            }
            let unnamed = groups.filter { $0.name == nil }
            sortedGroups = named + unnamed
        }

        // Rebuild group lookup
        groupLookup = [:]
        for group in groups {
            groupLookup[group.id] = group
        }

        // Rebuild face lookup
        faceLookup = [:]
        if let faces = faceData?.faces {
            for face in faces {
                faceLookup[face.id] = face
            }
        }
    }

    // MARK: - Load Existing Data

    func loadFaceData(for folderURL: URL, cleanupPolicy: FaceCleanupPolicy) {
        // Apply cleanup policy first
        try? storageService.applyCleanupIfNeeded(for: folderURL, policy: cleanupPolicy)

        if let data = storageService.loadFaceData(for: folderURL) {
            self.faceData = data
            self.scanComplete = data.scanComplete
            loadThumbnails(for: data)
        } else {
            self.faceData = nil
            self.scanComplete = false
            self.thumbnailCache = [:]
        }
    }

    private func loadThumbnails(for data: FolderFaceData) {
        thumbnailCache = [:]
        for group in data.groups {
            let faceID = group.representativeFaceID
            if let thumbData = storageService.loadThumbnail(for: faceID, folderURL: data.folderURL),
               let image = NSImage(data: thumbData) {
                thumbnailCache[faceID] = image
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

        let config = detectionConfig
        let visionThreshold = UserDefaults.standard.object(forKey: "visionClusteringThreshold") as? Double ?? 0.40
        let visionClusteringThreshold = Float(visionThreshold)
        let storageService = self.storageService
        let detectionService = self.detectionService

        if forceFullScan {
            // Full rescan: delete all existing data
            try? storageService.deleteFaceData(for: folderURL)
            faceData = nil
            thumbnailCache = [:]
            scanComplete = false
            mergeSuggestions = []
        }

        isScanning = true
        errorMessage = nil
        scanningGroups = []

        Task {
            // Load existing data for incremental scan
            let existingData = forceFullScan ? nil : storageService.loadFaceData(for: folderURL)

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

            let (allFaces, allGroups, scannedFiles) = await withTaskGroup(
                of: (URL, [(face: DetectedFace, thumbnail: Data)]).self
            ) { taskGroup -> ([DetectedFace], [FaceGroup], [String: FileSignature]) in
                var allFaces = initialFaces
                var allGroups = initialGroups
                var scannedFiles = initialScannedFiles
                var processed = 0
                var batchesSinceLastSave = 0
                let saveInterval = 10 // Save progress every 10 batches

                // Determine clustering approach based on recognition mode
                let useModeAwareClustering = config.recognitionMode != .visionFeaturePrint

                // Helper to process a completed batch and cluster incrementally
                func processBatch(scannedURL: URL, results: [(face: DetectedFace, thumbnail: Data)]) async {
                    var newFaces: [DetectedFace] = []

                    for result in results {
                        allFaces.append(result.face)
                        newFaces.append(result.face)
                        try? storageService.saveThumbnail(result.thumbnail, for: result.face.id, folderURL: folderURL)
                        let image = NSImage(data: result.thumbnail)
                        if let image {
                            await MainActor.run {
                                thumbnailCache[result.face.id] = image
                            }
                        }
                    }

                    // Incremental clustering: cluster new faces immediately against existing groups
                    if !newFaces.isEmpty {
                        if useModeAwareClustering {
                            // Use mode-aware clustering for ArcFace and Face+Clothing modes
                            allGroups = detectionService.clusterFacesModeAware(
                                newFaces,
                                allFaces: allFaces,
                                existingGroups: allGroups,
                                config: config,
                                visionClusteringThreshold: visionClusteringThreshold
                            )
                        } else {
                            // Use algorithm-aware clustering with selected algorithm
                            allGroups = detectionService.clusterFacesWithAlgorithm(newFaces, allFaces: allFaces, existingGroups: allGroups, config: config)
                        }

                        // Assign group IDs to the newly clustered faces
                        for group in allGroups {
                            for faceID in group.faceIDs {
                                if let index = allFaces.firstIndex(where: { $0.id == faceID && $0.groupID == nil }) {
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
                            recognitionMode: config.recognitionMode
                        )
                        try? storageService.saveFaceData(progressData)
                        batchesSinceLastSave = 0

                        // Update intermediate UI state for live face bar
                        let groupsSnapshot = allGroups
                        await MainActor.run {
                            self.scanningGroups = groupsSnapshot
                        }
                    }

                    let current = processed
                    let total = toScan.count
                    await MainActor.run {
                        scanProgress = "\(current)/\(total)"
                    }
                }

                // Process images concurrently, capped at 4
                var pending = 0

                for url in toScan {
                    if pending >= 4 {
                        if let (scannedURL, results) = await taskGroup.next() {
                            await processBatch(scannedURL: scannedURL, results: results)
                        }
                        pending -= 1
                    }

                    taskGroup.addTask {
                        let results = (try? await detectionService.detectFaces(in: url, config: config)) ?? []
                        return (url, results)
                    }
                    pending += 1
                }

                // Collect remaining
                for await (scannedURL, results) in taskGroup {
                    await processBatch(scannedURL: scannedURL, results: results)
                }

                return (allFaces, allGroups, scannedFiles)
            }

            let folderData = FolderFaceData(
                folderURL: folderURL,
                faces: allFaces,
                groups: allGroups,
                lastScanDate: Date(),
                scanComplete: true,
                scannedFiles: scannedFiles,
                recognitionMode: config.recognitionMode
            )

            try? storageService.saveFaceData(folderData)

            await MainActor.run {
                self.faceData = folderData
                self.isScanning = false
                self.scanComplete = true
                self.scanProgress = ""
                self.scanningGroups = []
                self.loadThumbnails(for: folderData)
                self.updateMergeSuggestions()
            }

            // Auto-match known people if Always On mode
            let modeRaw = UserDefaults.standard.string(forKey: "knownPeopleMode") ?? "off"
            let mode = KnownPeopleMode(rawValue: modeRaw) ?? .off
            if mode == .alwaysOn {
                await self.matchKnownPeopleIntegrated()
            }
        }
    }

    // MARK: - Integrated Known People Matching

    /// Enhanced Known People matching that runs during/after scanning.
    /// This version integrates with clustering by:
    /// 1. Matching each unnamed group's representative face against Known People
    /// 2. If multiple groups match the same known person, merging them together
    /// 3. Recording matches for the "Replace Thumbnail" feature
    private func matchKnownPeopleIntegrated() async {
        guard var data = faceData else { return }

        let stats = KnownPeopleService.shared.getStatistics()
        guard stats.peopleCount > 0 else { return }

        // Build a map: knownPersonID -> [groupIDs that matched this person]
        var matchesByPerson: [UUID: [(groupID: UUID, confidence: Float)]] = [:]

        for group in data.groups where group.name == nil {
            guard let face = data.faces.first(where: { $0.id == group.representativeFaceID }) else {
                continue
            }

            let matches = KnownPeopleService.shared.matchFace(
                featurePrintData: face.featurePrintData,
                threshold: 0.45,
                maxResults: 1
            )

            if let bestMatch = matches.first {
                // Record the match for "Replace Thumbnail" feature
                knownPersonMatchByGroup[group.id] = (personID: bestMatch.person.id, confidence: bestMatch.confidence)

                // Track for potential merging
                if matchesByPerson[bestMatch.person.id] == nil {
                    matchesByPerson[bestMatch.person.id] = []
                }
                matchesByPerson[bestMatch.person.id]?.append((groupID: group.id, confidence: bestMatch.confidence))
            }
        }

        // For each known person with matches, merge multiple groups and name them
        for (personID, groupMatches) in matchesByPerson {
            guard let knownPerson = KnownPeopleService.shared.person(byID: personID) else { continue }

            // Sort by confidence (highest first) - the best match becomes the target
            let sorted = groupMatches.sorted { $0.confidence > $1.confidence }
            guard let targetGroupID = sorted.first?.groupID else { continue }
            guard let initialTargetIndex = data.groups.firstIndex(where: { $0.id == targetGroupID }) else { continue }

            // Name the target group
            data.groups[initialTargetIndex].name = knownPerson.name

            // Merge other matching groups into the target
            for match in sorted.dropFirst() {
                guard let targetIndex = data.groups.firstIndex(where: { $0.id == targetGroupID }) else { break }
                guard let sourceIndex = data.groups.firstIndex(where: { $0.id == match.groupID }),
                      sourceIndex != targetIndex else { continue }

                // Move faces from source to target
                let sourceFaceIDs = data.groups[sourceIndex].faceIDs
                data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)

                // Update face groupIDs
                for faceID in sourceFaceIDs {
                    if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                        data.faces[fi].groupID = targetGroupID
                    }
                }

                // Update the match tracking to point to merged group
                knownPersonMatchByGroup[match.groupID] = nil
                knownPersonMatchByGroup[targetGroupID] = (personID: personID, confidence: sorted.first!.confidence)

                // Remove source group (need to re-find index as it may have shifted)
                if let currentSourceIndex = data.groups.firstIndex(where: { $0.id == match.groupID }) {
                    data.groups.remove(at: currentSourceIndex)
                }
            }
        }

        // Save updated data
        faceData = data
        try? storageService.saveFaceData(data)
    }

    // MARK: - Known People Matching

    /// Match unnamed face groups against the Known People database.
    /// Automatically names groups that match known people.
    /// If multiple groups match the same known person, they are merged together.
    /// Also records matches in knownPersonMatchByGroup for the "Replace Thumbnail" feature.
    func matchKnownPeople() {
        guard var data = faceData else { return }

        let stats = KnownPeopleService.shared.getStatistics()
        guard stats.peopleCount > 0 else { return }

        // Build a map: knownPersonID -> [groupIDs that matched this person]
        var matchesByPerson: [UUID: [(groupID: UUID, confidence: Float)]] = [:]

        let unnamedGroups = data.groups.filter { $0.name == nil }
        for group in unnamedGroups {
            guard let face = data.faces.first(where: { $0.id == group.representativeFaceID }) else {
                continue
            }

            let matches = KnownPeopleService.shared.matchFace(
                featurePrintData: face.featurePrintData,
                threshold: 0.45,
                maxResults: 1
            )

            if let bestMatch = matches.first {
                // Record the match
                knownPersonMatchByGroup[group.id] = (personID: bestMatch.person.id, confidence: bestMatch.confidence)

                // Track for potential merging
                if matchesByPerson[bestMatch.person.id] == nil {
                    matchesByPerson[bestMatch.person.id] = []
                }
                matchesByPerson[bestMatch.person.id]?.append((groupID: group.id, confidence: bestMatch.confidence))
            }
        }

        // For each known person with matches, merge multiple groups and name them
        for (personID, groupMatches) in matchesByPerson {
            guard let knownPerson = KnownPeopleService.shared.person(byID: personID) else { continue }

            // Sort by confidence (highest first) - the best match becomes the target
            let sorted = groupMatches.sorted { $0.confidence > $1.confidence }
            guard let targetGroupID = sorted.first?.groupID,
                  let targetIndex = data.groups.firstIndex(where: { $0.id == targetGroupID }) else { continue }

            // Name the target group
            data.groups[targetIndex].name = knownPerson.name

            // Merge other matching groups into the target
            for match in sorted.dropFirst() {
                guard let sourceIndex = data.groups.firstIndex(where: { $0.id == match.groupID }),
                      sourceIndex != targetIndex else { continue }

                // Move faces from source to target
                let sourceFaceIDs = data.groups[sourceIndex].faceIDs
                data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)

                // Update face groupIDs
                for faceID in sourceFaceIDs {
                    if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                        data.faces[fi].groupID = targetGroupID
                    }
                }

                // Update match tracking to point to merged group
                knownPersonMatchByGroup[match.groupID] = nil
                knownPersonMatchByGroup[targetGroupID] = (personID: personID, confidence: sorted.first!.confidence)

                // Remove source group
                if let currentSourceIndex = data.groups.firstIndex(where: { $0.id == match.groupID }) {
                    data.groups.remove(at: currentSourceIndex)
                }
            }
        }

        // Save updated data
        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Match a specific group against Known People and track the match.
    /// Returns the matched person ID if found.
    @discardableResult
    func matchGroupToKnownPeople(_ groupID: UUID) -> UUID? {
        guard let data = faceData,
              let group = data.groups.first(where: { $0.id == groupID }),
              let face = data.faces.first(where: { $0.id == group.representativeFaceID }) else {
            return nil
        }

        let matches = KnownPeopleService.shared.matchFace(
            featurePrintData: face.featurePrintData,
            threshold: 0.45,
            maxResults: 1
        )

        if let bestMatch = matches.first {
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
        guard knownPersonMatchByGroup[groupID] != nil else { return true }
        return nameMatchesKnownPerson(groupID: groupID, name: name)
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

    func updateMergeSuggestions() {
        guard let data = faceData else {
            mergeSuggestions = []
            return
        }

        let config = detectionConfig
        mergeSuggestions = detectionService.computeMergeSuggestions(
            groups: data.groups,
            faces: data.faces,
            threshold: config.clusteringThreshold
        )
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

    /// Check if refinement is available (at least one named group and one unnamed group)
    var canRefine: Bool {
        guard let data = faceData else { return false }
        let hasNamed = data.groups.contains { $0.name != nil }
        let hasUnnamed = data.groups.contains { $0.name == nil }
        return hasNamed && hasUnnamed
    }

    func dismissMergeSuggestion(_ suggestion: MergeSuggestion) {
        mergeSuggestions.removeAll { $0.id == suggestion.id }
    }

    func applyMergeSuggestion(_ suggestion: MergeSuggestion) {
        mergeGroups(sourceID: suggestion.group2ID, into: suggestion.group1ID)
        dismissMergeSuggestion(suggestion)
    }

    // MARK: - Naming & Metadata

    func nameGroup(_ groupID: UUID, name: String) {
        guard var data = faceData,
              let index = data.groups.firstIndex(where: { $0.id == groupID }) else { return }

        data.groups[index].name = name.isEmpty ? nil : name
        faceData = data
        try? storageService.saveFaceData(data)
    }

    func applyNameToMetadata(groupID: UUID) {
        guard let data = faceData,
              let group = data.groups.first(where: { $0.id == groupID }),
              let name = group.name, !name.isEmpty else { return }

        let names = splitPersonNames(name)
        guard !names.isEmpty else { return }

        let imageURLs = group.faceIDs.compactMap { faceID in
            data.faces.first(where: { $0.id == faceID })?.imageURL
        }
        let uniqueURLs = Array(Set(imageURLs))

        guard !uniqueURLs.isEmpty else { return }

        Task {
            let c2paLookup = await loadC2PALookup(urls: uniqueURLs)
            let folderURL = data.folderURL

            for url in uniqueURLs {
                let hasC2PA = c2paLookup[url] ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA)

                switch mode {
                case .historyOnly:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: false,
                        pendingChanges: true
                    )
                case .writeToXMPSidecar:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: true,
                        pendingChanges: false
                    )
                case .writeToFile:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: false,
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

        for face in data.faces {
            guard availableURLs.contains(face.imageURL),
                  let groupID = face.groupID,
                  let group = groupLookup[groupID],
                  let rawName = group.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { continue }

            let names = splitPersonNames(rawName)
            guard !names.isEmpty else { continue }

            var existing = namesByURL[face.imageURL] ?? []
            for name in names where !existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                existing.append(name)
            }
            namesByURL[face.imageURL] = existing
        }

        guard !namesByURL.isEmpty else {
            onComplete?()
            return
        }

        let c2paLookup = Dictionary(uniqueKeysWithValues: images.map { ($0.url, $0.hasC2PA) })

        Task {
            for (url, names) in namesByURL {
                let hasC2PA = c2paLookup[url] ?? false
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA)

                switch mode {
                case .historyOnly:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: false,
                        pendingChanges: true
                    )
                case .writeToXMPSidecar:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: true,
                        pendingChanges: false
                    )
                case .writeToFile:
                    await applyNamesToSidecar(
                        url: url,
                        folderURL: folderURL,
                        names: names,
                        writeXmpSidecar: false,
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
        for name in adding where !merged.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            merged.append(name)
        }
        return merged
    }

    private func applyNamesToFile(url: URL, names: [String]) async {
        do {
            let existing = try await exifToolService.readFullMetadata(url: url)
            let merged = mergePersons(existing: existing.personShown, adding: names)
            guard merged != existing.personShown else { return }
            let value = merged.joined(separator: ", ")
            try await exifToolService.writeFields(["XMP-iptcExt:PersonInImage": value], to: [url])
        } catch {
            // Continue with next image
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
            snapshot = await loadBaseMetadata(url: url, includeXmp: writeXmpSidecar)
        }

        if !hadSidecar, let snapshot {
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

        try? sidecarService.saveSidecar(sidecar, for: url, in: folderURL)

        if writeXmpSidecar {
            try? xmpSidecarService.saveSidecar(metadata: updatedMetadata, for: url)
        }
    }

    private func loadC2PALookup(urls: [URL]) async -> [URL: Bool] {
        guard !urls.isEmpty else { return [:] }
        do {
            let results = try await exifToolService.readBatchBasicMetadata(urls: urls)
            var lookup: [URL: Bool] = [:]
            for dict in results {
                guard let sourcePath = dict["SourceFile"] as? String else { continue }
                let sourceURL = URL(fileURLWithPath: sourcePath)
                let hasC2PA = dict.keys.contains { $0.hasPrefix("JUMD") || $0.hasPrefix("C2PA") || $0 == "Claim_generator" }
                lookup[sourceURL] = hasC2PA
            }
            return lookup
        } catch {
            return [:]
        }
    }

    private func loadBaseMetadata(url: URL, includeXmp: Bool) async -> IPTCMetadata? {
        do {
            var metadata = try await exifToolService.readFullMetadata(url: url)
            let preferXmp = UserDefaults.standard.bool(forKey: "metadataPreferXMPSidecar")
            if (includeXmp || preferXmp), let xmpMetadata = xmpSidecarService.loadSidecar(for: url) {
                metadata = metadata.merged(preferring: xmpMetadata)
            }
            return metadata
        } catch {
            return nil
        }
    }

    // MARK: - Merge & Ungroup

    /// Merge sourceGroup into targetGroup. All faces move to target; source is deleted.
    func mergeGroups(sourceID: UUID, into targetID: UUID) {
        guard var data = faceData,
              let sourceIndex = data.groups.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = data.groups.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }

        let sourceFaceIDs = data.groups[sourceIndex].faceIDs
        data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)

        // Update face groupIDs
        for faceID in sourceFaceIDs {
            if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                data.faces[fi].groupID = targetID
            }
        }

        data.groups.remove(at: sourceIndex)
        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Remove a single face from its group and place it in a new solo group.
    func ungroupFace(_ faceID: UUID) {
        guard var data = faceData,
              let faceIndex = data.faces.firstIndex(where: { $0.id == faceID }),
              let oldGroupID = data.faces[faceIndex].groupID,
              let groupIndex = data.groups.firstIndex(where: { $0.id == oldGroupID }) else { return }

        // Don't ungroup if it's the only face in the group
        guard data.groups[groupIndex].faceIDs.count > 1 else { return }

        // Remove from old group
        data.groups[groupIndex].faceIDs.removeAll { $0 == faceID }

        // If the representative was removed, pick a new one
        if data.groups[groupIndex].representativeFaceID == faceID {
            data.groups[groupIndex].representativeFaceID = data.groups[groupIndex].faceIDs[0]
        }

        // Create new solo group
        let newGroup = FaceGroup(
            id: UUID(),
            name: nil,
            representativeFaceID: faceID,
            faceIDs: [faceID]
        )
        data.groups.append(newGroup)
        data.faces[faceIndex].groupID = newGroup.id

        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Merge multiple groups into the first group in the set (by sort order).
    func mergeMultipleGroups(_ groupIDs: Set<UUID>) {
        guard groupIDs.count >= 2, var data = faceData else { return }

        // Use sorted order so the "first" group (named or largest) becomes the target
        let sorted = sortedGroups.filter { groupIDs.contains($0.id) }
        guard let target = sorted.first else { return }
        let sources = sorted.dropFirst()

        for source in sources {
            guard let sourceIndex = data.groups.firstIndex(where: { $0.id == source.id }),
                  let targetIndex = data.groups.firstIndex(where: { $0.id == target.id }) else { continue }

            let sourceFaceIDs = data.groups[sourceIndex].faceIDs
            data.groups[targetIndex].faceIDs.append(contentsOf: sourceFaceIDs)

            for faceID in sourceFaceIDs {
                if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                    data.faces[fi].groupID = target.id
                }
            }

            data.groups.remove(at: sourceIndex)
        }

        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Ungroup all selected groups — split every face into its own solo group.
    func ungroupMultiple(_ groupIDs: Set<UUID>) {
        guard var data = faceData else { return }

        for groupID in groupIDs {
            guard let groupIndex = data.groups.firstIndex(where: { $0.id == groupID }) else { continue }
            let group = data.groups[groupIndex]
            guard group.faceIDs.count > 1 else { continue }

            // Create solo groups for each face except the first (which stays as representative)
            let remaining = Array(group.faceIDs.dropFirst())
            data.groups[groupIndex].faceIDs = [group.faceIDs[0]]

            for faceID in remaining {
                let newGroup = FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: faceID,
                    faceIDs: [faceID]
                )
                data.groups.append(newGroup)
                if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                    data.faces[fi].groupID = newGroup.id
                }
            }
        }

        faceData = data
        try? storageService.saveFaceData(data)
    }

    // MARK: - Move Faces Between Groups

    /// Move a single face from its current group to a target group.
    func moveFace(_ faceID: UUID, toGroup targetGroupID: UUID) {
        guard var data = faceData,
              let faceIndex = data.faces.firstIndex(where: { $0.id == faceID }),
              let oldGroupID = data.faces[faceIndex].groupID,
              let oldGroupIndex = data.groups.firstIndex(where: { $0.id == oldGroupID }),
              data.groups.contains(where: { $0.id == targetGroupID }),
              oldGroupID != targetGroupID else { return }

        // Remove from old group
        data.groups[oldGroupIndex].faceIDs.removeAll { $0 == faceID }

        // Clean up empty group or update representative
        if data.groups[oldGroupIndex].faceIDs.isEmpty {
            data.groups.remove(at: oldGroupIndex)
        } else if data.groups[oldGroupIndex].representativeFaceID == faceID {
            data.groups[oldGroupIndex].representativeFaceID = data.groups[oldGroupIndex].faceIDs[0]
        }

        // Re-fetch target index (may have shifted after removal)
        guard let newTargetIndex = data.groups.firstIndex(where: { $0.id == targetGroupID }) else { return }

        // Add to target group
        data.groups[newTargetIndex].faceIDs.append(faceID)
        data.faces[faceIndex].groupID = targetGroupID

        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Move multiple faces to a target group (single mutation + single save).
    func moveFaces(_ faceIDs: Set<UUID>, toGroup targetGroupID: UUID) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

        // Remove faces from their source groups
        removeFacesFromGroups(faceIDs, in: &data)

        // Add all faces to the target group
        guard let targetIndex = data.groups.firstIndex(where: { $0.id == targetGroupID }) else { return }
        for faceID in faceIDs {
            data.groups[targetIndex].faceIDs.append(faceID)
            if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                data.faces[fi].groupID = targetGroupID
            }
        }

        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Remove faces from their current groups and create a new group with them (single mutation + single save).
    /// The new group is inserted after the source groups to keep it visually close when in manual sort mode.
    func createNewGroup(withFaces faceIDs: Set<UUID>) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

        // Find source group IDs before removal (to determine insertion position)
        let sourceGroupIDs = Set(faceIDs.compactMap { faceID -> UUID? in
            guard let faceIndex = data.faces.firstIndex(where: { $0.id == faceID }) else { return nil }
            return data.faces[faceIndex].groupID
        })

        // Find the highest index among source groups (for insertion position)
        var maxSourceIndex = -1
        for (index, group) in data.groups.enumerated() {
            if sourceGroupIDs.contains(group.id) {
                maxSourceIndex = max(maxSourceIndex, index)
            }
        }

        // Remove faces from their source groups
        removeFacesFromGroups(faceIDs, in: &data)

        // Create new group
        let faceIDArray = Array(faceIDs)
        let newGroup = FaceGroup(
            id: UUID(),
            name: nil,
            representativeFaceID: faceIDArray[0],
            faceIDs: faceIDArray
        )

        // Insert after the last source group (accounting for potential removal of empty groups)
        // We need to find the appropriate insertion index after removals
        let insertionIndex: Int
        if maxSourceIndex >= 0 {
            // Count how many source groups were removed (became empty)
            var removedCount = 0
            for groupID in sourceGroupIDs {
                if !data.groups.contains(where: { $0.id == groupID }) {
                    removedCount += 1
                }
            }
            // Adjust index: after the remaining source groups
            insertionIndex = min(maxSourceIndex - removedCount + 1, data.groups.count)
        } else {
            insertionIndex = data.groups.count
        }

        data.groups.insert(newGroup, at: max(0, insertionIndex))

        for faceID in faceIDs {
            if let fi = data.faces.firstIndex(where: { $0.id == faceID }) {
                data.faces[fi].groupID = newGroup.id
            }
        }

        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Remove faces from whatever groups they belong to, cleaning up empties and representatives.
    /// Mutates `data` in place without assigning to `faceData` or saving — caller is responsible.
    private func removeFacesFromGroups(_ faceIDs: Set<UUID>, in data: inout FolderFaceData) {
        for faceID in faceIDs {
            guard let faceIndex = data.faces.firstIndex(where: { $0.id == faceID }),
                  let oldGroupID = data.faces[faceIndex].groupID,
                  let oldGroupIndex = data.groups.firstIndex(where: { $0.id == oldGroupID }) else { continue }

            data.groups[oldGroupIndex].faceIDs.removeAll { $0 == faceID }

            if data.groups[oldGroupIndex].faceIDs.isEmpty {
                data.groups.remove(at: oldGroupIndex)
            } else if data.groups[oldGroupIndex].representativeFaceID == faceID {
                data.groups[oldGroupIndex].representativeFaceID = data.groups[oldGroupIndex].faceIDs[0]
            }
        }
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
            thumbnailCache.removeValue(forKey: faceID)
            storageService.deleteThumbnail(for: faceID, folderURL: data.folderURL)
        }

        faceData = data
        try? storageService.saveFaceData(data)
    }

    /// Delete an entire group: removes all face data and optionally trashes the source photos.
    /// Returns the set of photo URLs that were trashed (empty if `includePhotos` is false).
    @discardableResult
    func deleteGroup(_ groupID: UUID, includePhotos: Bool) -> Set<URL> {
        guard var data = faceData,
              let group = data.groups.first(where: { $0.id == groupID }) else { return [] }

        let faceIDs = Set(group.faceIDs)

        // Collect photo URLs before removing face data
        var trashedURLs: Set<URL> = []
        if includePhotos {
            let urls = Set(group.faceIDs.compactMap { faceID in
                data.faces.first(where: { $0.id == faceID })?.imageURL
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
            thumbnailCache.removeValue(forKey: faceID)
            storageService.deleteThumbnail(for: faceID, folderURL: data.folderURL)
        }

        faceData = data
        try? storageService.saveFaceData(data)
        return trashedURLs
    }

    // MARK: - Delete Face Data

    func deleteFaceData(for folderURL: URL) {
        try? storageService.deleteFaceData(for: folderURL)
        faceData = nil
        thumbnailCache = [:]
        scanComplete = false
    }

    // MARK: - Helper

    func faces(in group: FaceGroup) -> [DetectedFace] {
        // Use lookup dictionary for O(1) access per face instead of O(n)
        return group.faceIDs.compactMap { faceLookup[$0] }
    }

    func face(byID faceID: UUID) -> DetectedFace? {
        faceLookup[faceID]
    }

    func group(byID groupID: UUID) -> FaceGroup? {
        groupLookup[groupID]
    }

    func imageURLs(for group: FaceGroup) -> Set<URL> {
        let faces = faces(in: group)
        return Set(faces.map(\.imageURL))
    }

    func thumbnailImage(for faceID: UUID) -> NSImage? {
        if let cached = thumbnailCache[faceID] { return cached }

        guard let folderURL = faceData?.folderURL,
              let data = storageService.loadThumbnail(for: faceID, folderURL: folderURL),
              let image = NSImage(data: data) else {
            return nil
        }
        thumbnailCache[faceID] = image
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
