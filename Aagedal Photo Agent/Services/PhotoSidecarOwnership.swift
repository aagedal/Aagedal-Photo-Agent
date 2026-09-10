import Foundation

/// Stem-named carriers may be used by more than one image, independently of voice memos.
/// Call only from a filesystem worker before retiring a source carrier.
nonisolated enum PhotoSidecarOwnership {
    /// Publish only a complete copy. A copy failure may leave bytes at its target, so keep
    /// that target inside an operation-owned directory until an exclusive rename installs it.
    static func copyPreservingSource(
        from source: URL, to destination: URL,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".photo-agent-sidecar-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try copy(source, staged)
        try fm.moveItem(at: staged, to: destination)
    }

    static func hasSurvivingStemSibling(of imageURL: URL, in folderURL: URL) throws -> Bool {
        let stem = imageURL.deletingPathExtension().lastPathComponent
        return try FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).contains { candidate in
            guard candidate.standardizedFileURL.path != imageURL.standardizedFileURL.path,
                  SupportedImageFormats.isSupported(url: candidate),
                  candidate.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
            else { return false }
            // An unreadable or linked sibling is still a reason to preserve its shared carrier.
            return (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
    }

    /// A legacy stem filename is discovery, not proof that the document belongs to this photo.
    /// Preserve another photo's record, including when that photo is temporarily unavailable.
    static func legacyRecordBelongsToImage(at recordURL: URL, imageURL: URL) throws -> Bool {
        let data = try Data(contentsOf: recordURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = object["sourceFile"] as? String, !owner.isEmpty,
              !owner.contains("/"), !owner.contains("\\"), !owner.contains("..") else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSFilePathErrorKey: recordURL.path,
                NSLocalizedDescriptionKey: "Cannot establish the owner of legacy metadata at \(recordURL.path). The source record was preserved."
            ])
        }
        return owner == imageURL.lastPathComponent
    }
}
