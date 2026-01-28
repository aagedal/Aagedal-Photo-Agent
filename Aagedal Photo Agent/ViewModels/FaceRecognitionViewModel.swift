import Foundation
import AppKit

@Observable
final class FaceRecognitionViewModel {
    var faceData: FolderFaceData?
    var isScanning = false
    var scanProgress: String = ""
    var scanComplete = false
    var errorMessage: String?

    // Thumbnail cache: faceID -> NSImage
    var thumbnailCache: [UUID: NSImage] = [:]

    // Merge suggestions for similar groups
    var mergeSuggestions: [MergeSuggestion] = []

    // Detection configuration from settings
    var detectionConfig: FaceDetectionService.DetectionConfig {
        var config = FaceDetectionService.DetectionConfig()
        let threshold = UserDefaults.standard.object(forKey: "faceClusteringThreshold") as? Double
        config.clusteringThreshold = Float(threshold ?? 0.55)
        let confidence = UserDefaults.standard.object(forKey: "faceMinConfidence") as? Double
        config.minConfidence = Float(confidence ?? 0.7)
        let minSize = UserDefaults.standard.object(forKey: "faceMinFaceSize") as? Int
        config.minFaceSize = minSize ?? 50
        return config
    }

    private let detectionService = FaceDetectionService()
    private let storageService = FaceDataStorageService()
    private let exifToolService: ExifToolService

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
    }

    // MARK: - Sorted Groups

    var sortedGroups: [FaceGroup] {
        guard let groups = faceData?.groups else { return [] }
        return groups.sorted { a, b in
            // Named groups first (alphabetical), then unnamed (by size descending)
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

        Task {
            // Load existing data for incremental scan
            let existingData = forceFullScan ? nil : storageService.loadFaceData(for: folderURL)

            // Determine which files need scanning
            let (toScan, toRemove, unchangedFiles) = await categorizeFiles(
                imageURLs: imageURLs,
                existingData: existingData
            )

            // Start with existing faces (excluding those from removed/modified files)
            var allFaces: [DetectedFace] = existingData?.faces.filter { face in
                unchangedFiles.contains(face.imageURL.path)
            } ?? []

            var allGroups: [FaceGroup] = existingData?.groups ?? []
            var scannedFiles = existingData?.scannedFiles ?? [:]

            // Remove faces from deleted/modified files
            let removedFaceIDs = Set(existingData?.faces.filter { face in
                toRemove.contains(face.imageURL.path)
            }.map(\.id) ?? [])

            // Clean up groups
            if !removedFaceIDs.isEmpty {
                for i in allGroups.indices {
                    allGroups[i].faceIDs.removeAll { removedFaceIDs.contains($0) }
                }
                allGroups.removeAll { $0.faceIDs.isEmpty }

                // Update representatives
                for i in allGroups.indices {
                    if removedFaceIDs.contains(allGroups[i].representativeFaceID) {
                        if let newRep = allGroups[i].faceIDs.first {
                            allGroups[i].representativeFaceID = newRep
                        }
                    }
                }
            }

            // Remove old file signatures
            for path in toRemove {
                scannedFiles.removeValue(forKey: path)
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

            var processed = 0

            // Process images concurrently, capped at 4
            await withTaskGroup(of: (URL, [(face: DetectedFace, thumbnail: Data)]).self) { taskGroup in
                var pending = 0

                for url in toScan {
                    if pending >= 4 {
                        if let (scannedURL, results) = await taskGroup.next() {
                            for result in results {
                                allFaces.append(result.face)
                                try? storageService.saveThumbnail(result.thumbnail, for: result.face.id, folderURL: folderURL)
                                let image = NSImage(data: result.thumbnail)
                                if let image {
                                    await MainActor.run {
                                        thumbnailCache[result.face.id] = image
                                    }
                                }
                            }
                            // Record file signature
                            if let sig = self.getFileSignature(for: scannedURL) {
                                scannedFiles[scannedURL.path] = sig
                            }
                            processed += 1
                            let current = processed
                            let total = toScan.count
                            await MainActor.run {
                                scanProgress = "\(current)/\(total)"
                            }
                        }
                        pending -= 1
                    }

                    taskGroup.addTask {
                        let results = (try? await self.detectionService.detectFaces(in: url, config: config)) ?? []
                        return (url, results)
                    }
                    pending += 1
                }

                // Collect remaining
                for await (scannedURL, results) in taskGroup {
                    for result in results {
                        allFaces.append(result.face)
                        try? storageService.saveThumbnail(result.thumbnail, for: result.face.id, folderURL: folderURL)
                        let image = NSImage(data: result.thumbnail)
                        if let image {
                            await MainActor.run {
                                thumbnailCache[result.face.id] = image
                            }
                        }
                    }
                    // Record file signature
                    if let sig = self.getFileSignature(for: scannedURL) {
                        scannedFiles[scannedURL.path] = sig
                    }
                    processed += 1
                    let current = processed
                    let total = toScan.count
                    await MainActor.run {
                        scanProgress = "\(current)/\(total)"
                    }
                }
            }

            // Cluster faces
            let unclustered = allFaces.filter { $0.groupID == nil }
            allGroups = detectionService.clusterFaces(unclustered, allFaces: allFaces, existingGroups: allGroups, threshold: config.clusteringThreshold)

            // Assign group IDs to faces
            for group in allGroups {
                for faceID in group.faceIDs {
                    if let index = allFaces.firstIndex(where: { $0.id == faceID }) {
                        allFaces[index].groupID = group.id
                    }
                }
            }

            let folderData = FolderFaceData(
                folderURL: folderURL,
                faces: allFaces,
                groups: allGroups,
                lastScanDate: Date(),
                scanComplete: true,
                scannedFiles: scannedFiles
            )

            try? storageService.saveFaceData(folderData)

            await MainActor.run {
                self.faceData = folderData
                self.isScanning = false
                self.scanComplete = true
                self.scanProgress = ""
                self.loadThumbnails(for: folderData)
                self.updateMergeSuggestions()
            }
        }
    }

    // MARK: - Incremental Scan Helpers

    /// Categorize files into: need scanning, removed/modified, unchanged
    private func categorizeFiles(imageURLs: [URL], existingData: FolderFaceData?) async -> (toScan: [URL], toRemove: Set<String>, unchanged: Set<String>) {
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

    private func getFileSignature(for url: URL) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return FileSignature(modificationDate: modDate, fileSize: size)
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

        let imageURLs = group.faceIDs.compactMap { faceID in
            data.faces.first(where: { $0.id == faceID })?.imageURL
        }
        let uniqueURLs = Array(Set(imageURLs))

        guard !uniqueURLs.isEmpty else { return }

        Task {
            for url in uniqueURLs {
                do {
                    // Read existing PersonInImage
                    let existing = try await exifToolService.readFullMetadata(url: url)
                    var persons = existing.personShown

                    // Split name on comma/semicolon to support multiple person names
                    let names = name
                        .components(separatedBy: CharacterSet(charactersIn: ",;"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    // Deduplicate: only add if not already present
                    for n in names {
                        if !persons.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
                            persons.append(n)
                        }
                    }

                    let value = persons.joined(separator: ", ")
                    try await exifToolService.writeFields(["XMP-iptcExt:PersonInImage": value], to: [url])
                } catch {
                    // Continue with next image
                }
            }

            // Post notification so MetadataPanel refreshes
            await MainActor.run {
                NotificationCenter.default.post(name: .faceMetadataDidChange, object: nil)
            }
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
    func createNewGroup(withFaces faceIDs: Set<UUID>) {
        guard var data = faceData, !faceIDs.isEmpty else { return }

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
        data.groups.append(newGroup)

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
        guard let data = faceData else { return [] }
        return group.faceIDs.compactMap { faceID in
            data.faces.first { $0.id == faceID }
        }
    }

    func imageURLs(for group: FaceGroup) -> Set<URL> {
        let faces = faces(in: group)
        return Set(faces.map(\.imageURL))
    }

    func thumbnailImage(for faceID: UUID) -> NSImage? {
        if let cached = thumbnailCache[faceID] { return cached }
        guard let folderURL = faceData?.folderURL,
              let data = storageService.loadThumbnail(for: faceID, folderURL: folderURL),
              let image = NSImage(data: data) else { return nil }
        thumbnailCache[faceID] = image
        return image
    }
}
