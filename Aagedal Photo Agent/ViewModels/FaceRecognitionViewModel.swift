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

    func scanFolder(imageURLs: [URL], folderURL: URL) {
        guard !isScanning else { return }

        // Always start fresh — delete any previous face data
        try? storageService.deleteFaceData(for: folderURL)
        faceData = nil
        thumbnailCache = [:]
        scanComplete = false

        isScanning = true
        scanProgress = "0/\(imageURLs.count)"
        errorMessage = nil

        Task {
            var allFaces: [DetectedFace] = []
            var allGroups: [FaceGroup] = []

            let toScan = imageURLs
            var processed = 0

            // Process images concurrently, capped at 4
            await withTaskGroup(of: [(face: DetectedFace, thumbnail: Data)].self) { taskGroup in
                var pending = 0

                for url in toScan {
                    if pending >= 4 {
                        if let results = await taskGroup.next() {
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
                        (try? await self.detectionService.detectFaces(in: url)) ?? []
                    }
                    pending += 1
                }

                // Collect remaining
                for await results in taskGroup {
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
            allGroups = detectionService.clusterFaces(unclustered, allFaces: allFaces, existingGroups: allGroups)

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
                scanComplete: true
            )

            try? storageService.saveFaceData(folderData)

            await MainActor.run {
                self.faceData = folderData
                self.isScanning = false
                self.scanComplete = true
                self.scanProgress = ""
                self.loadThumbnails(for: folderData)
            }
        }
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

                    // Deduplicate: only add if not already present
                    if !persons.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        persons.append(name)
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
              let targetGroupIndex = data.groups.firstIndex(where: { $0.id == targetGroupID }),
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
