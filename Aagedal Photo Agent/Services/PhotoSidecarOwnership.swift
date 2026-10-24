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

    // MARK: - Develop settings in a shared stem sidecar (RAW+JPEG pairs)

    /// A RAW+JPEG pair shares one stem-named `IMG_1.xmp`. Descriptive fields in it are the
    /// pair's shared record (Photo Mechanic), but its Camera Raw (`crs`) settings belong to the
    /// RAW (Adobe: ACR/Lightroom never apply a sidecar's develop settings to a JPEG — the JPEG
    /// keeps its own in its embedded XMP). True when `imageURL` is a non-RAW file whose stem
    /// sidecar is owned, for develop purposes, by a same-stem RAW sibling. RAW files own their
    /// sidecar, so this is always false for them.
    static func stemSidecarDevelopBelongsToRawSibling(of imageURL: URL) -> Bool {
        developOwningRawSibling(of: imageURL) != nil
    }

    /// The same-stem RAW file that owns `imageURL`'s stem sidecar develop settings, if any.
    static func developOwningRawSibling(of imageURL: URL) -> URL? {
        guard !SupportedImageFormats.isRaw(url: imageURL) else { return nil }
        let base = imageURL.deletingPathExtension()
        let fm = FileManager.default
        for ext in SupportedImageFormats.rawExtensions.sorted() {
            for variant in [ext, ext.uppercased()] {
                let candidate = base.appendingPathExtension(variant)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The stem sidecar's develop settings as they apply to `imageURL` — nil for a non-RAW file
    /// whose sidecar belongs to its RAW sibling. Every reader that takes `crs` settings from a
    /// stem `.xmp` for display, render, export, upload or Develop load goes through this (or
    /// `applyingDevelopOwnership`) so the pair's JPEG never inherits the RAW's absolute-Kelvin
    /// WB and crop. Probes the filesystem only when there are settings to drop.
    static func stemSidecarCameraRaw(_ settings: CameraRawSettings?, for imageURL: URL) -> CameraRawSettings? {
        guard let settings, stemSidecarDevelopBelongsToRawSibling(of: imageURL) == false else { return nil }
        return settings
    }

    /// Parsed stem-sidecar metadata with the develop settings removed when they belong to a
    /// RAW sibling. Descriptive fields, rating and label are kept (shared PM-style record).
    static func applyingDevelopOwnership(_ metadata: IPTCMetadata?, for imageURL: URL) -> IPTCMetadata? {
        guard var metadata, metadata.cameraRaw != nil,
              stemSidecarDevelopBelongsToRawSibling(of: imageURL) else { return metadata }
        metadata.cameraRaw = nil
        return metadata
    }

    static func hasSurvivingStemSibling(of imageURL: URL, in folderURL: URL) throws -> Bool {
        let stem = imageURL.deletingPathExtension().lastPathComponent
        return try FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).contains { candidate in
            guard candidate.standardizedFileURL.path != imageURL.standardizedFileURL.path,
                  // A same-stem video (Live Photo, camera pair) shares the stem-named XMP too.
                  SupportedImageFormats.isSupported(url: candidate) || BrowserFileVisibility.isVideo(candidate),
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

/// A Develop write for the non-RAW half of a RAW+JPEG pair that could only land in the shared
/// stem `.xmp` — where it would overwrite the RAW's Camera Raw settings — is refused.
nonisolated struct StemSidecarDevelopOwnedByRawError: LocalizedError, Sendable {
    let imageURL: URL
    let rawURL: URL

    var errorDescription: String? {
        "\(imageURL.lastPathComponent) shares \(imageURL.deletingPathExtension().lastPathComponent).xmp with its RAW file \(rawURL.lastPathComponent). "
            + "Develop settings in that sidecar belong to the RAW, so edits to \(imageURL.lastPathComponent) can't be saved there. "
            + "Choose a metadata write preset that writes into the image file (Simple or Professional), or edit the RAW file instead."
    }
}
