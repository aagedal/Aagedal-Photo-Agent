import Foundation

/// Deletion marker for a metadata or Develop template (`<uuid>.deleted` beside `<uuid>.json`),
/// like Teams and Watermarks. Without it, a Mac that kept a template while sync was off
/// copies it back into iCloud when sync is turned on again (the merge keeps the newer file,
/// and a deleted file has no date), and a template deleted while sync was off survives in
/// iCloud.
///
/// A marker hides its template only while the template file predates the deletion: a file
/// saved again, or restored from the Trash (which resets its date added), is newer and shows.
/// Saving also removes the marker. Markers are never pruned (a pruned marker would let a stale
/// copy come back).
nonisolated struct TemplateTombstone: Codable, Sendable {
    static let fileExtension = "deleted"

    let id: UUID
    let deletedAt: Date

    static func url(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    /// IDs whose `<uuid>.json` in `directory` is hidden by a marker.
    static func hiddenIDs(in directory: URL) -> Set<UUID> {
        guard let entries = try? CloudCoordinatedIO.contentsOfDirectory(at: directory) else { return [] }
        return Set(entries.compactMap { marker in
            guard marker.pathExtension.lowercased() == fileExtension,
                  let id = UUID(uuidString: marker.deletingPathExtension().lastPathComponent) else { return nil }
            let file = directory.appendingPathComponent("\(id.uuidString).json")
            return hides(file, marker: marker) ? id : nil
        })
    }

    static func write(for id: UUID, in directory: URL, at date: Date = Date()) throws {
        try CloudCoordinatedIO.writeData(
            encoder.encode(TemplateTombstone(id: id, deletedAt: date)),
            to: url(for: id, in: directory)
        )
    }

    /// Saving a template is a newer intent than its deletion.
    static func clear(for id: UUID, in directory: URL) throws {
        let marker = url(for: id, in: directory)
        guard CloudCoordinatedIO.itemExists(at: marker) else { return }
        try CloudCoordinatedIO.removeItem(at: marker)
    }

    /// Templates' iCloud routing merge: `CloudCoordinatedIO.mergeCopyPreservingNewer` plus
    /// markers. A template file deleted on either side after it was last written isn't copied,
    /// and a copied marker removes the destination's older template file.
    static func mergeCopyHonoringDeletions(from src: URL, to dst: URL) throws {
        try CloudCoordinatedIO.ensureDirectory(dst)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        for item in try CloudCoordinatedIO.contentsOfDirectory(at: src) {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try mergeCopyHonoringDeletions(from: item, to: target)
                continue
            }
            let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent)
            if item.pathExtension.lowercased() == "json", let id,
               hides(item, marker: url(for: id, in: src)) || hides(item, marker: url(for: id, in: dst)) {
                continue
            }
            if CloudCoordinatedIO.itemExists(at: target) {
                guard let sourceDate = modificationDate(of: item),
                      let targetDate = modificationDate(of: target),
                      sourceDate > targetDate else { continue }
            }
            try CloudCoordinatedIO.writeData(CloudCoordinatedIO.readData(at: item), to: target)
            if item.pathExtension.lowercased() == fileExtension, let id,
               let deletedAt = deletionDate(at: target) {
                let file = dst.appendingPathComponent("\(id.uuidString).json")
                if CloudCoordinatedIO.itemExists(at: file),
                   let written = modificationDate(of: file), written <= deletedAt {
                    try CloudCoordinatedIO.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Internals

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Whether `marker` exists and records a deletion at or after `file` was last written or
    /// moved into its folder. Unknown dates count as hidden: the marker is the evidence.
    private static func hides(_ file: URL, marker: URL) -> Bool {
        guard CloudCoordinatedIO.itemExists(at: marker) else { return false }
        guard let deletedAt = deletionDate(at: marker) else { return true }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey])
        guard let written = [values?.contentModificationDate, values?.addedToDirectoryDate]
            .compactMap({ $0 }).max() else { return true }
        return deletedAt >= written
    }

    private static func deletionDate(at marker: URL) -> Date? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? CloudCoordinatedIO.readData(at: marker),
           let tombstone = try? decoder.decode(TemplateTombstone.self, from: data) {
            return tombstone.deletedAt
        }
        return modificationDate(of: marker)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
