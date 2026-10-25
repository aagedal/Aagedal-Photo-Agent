import Darwin
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
    /// `requiringFreshListing`: write-path ownership decisions never trust a cached listing
    /// that might predate a RAW arriving on a coarse-timestamp volume (missing the RAW would let
    /// a JPEG write clobber the RAW's crs). Read paths may reuse the short-lived cache.
    static func stemSidecarDevelopBelongsToRawSibling(of imageURL: URL, requiringFreshListing: Bool = false) -> Bool {
        developOwningRawSibling(of: imageURL, requiringFreshListing: requiringFreshListing) != nil
    }

    /// The same-stem RAW file that owns `imageURL`'s stem sidecar develop settings, if any.
    /// Answered from a per-folder stem→RAW index (one directory listing per folder, reused
    /// while the folder's modification time is unchanged), so folder loads, saves and NAS
    /// volumes don't pay ~24 probes per photo. Extensions match case-insensitively.
    static func developOwningRawSibling(of imageURL: URL, requiringFreshListing: Bool = false) -> URL? {
        guard !SupportedImageFormats.isRaw(url: imageURL) else { return nil }
        return PhotoRawStemIndex.shared.rawFile(
            forStem: imageURL.deletingPathExtension().lastPathComponent,
            in: imageURL.deletingLastPathComponent(),
            allowsUnsettledReuse: !requiringFreshListing)
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

    // MARK: - Splitting a RAW+JPEG pair

    /// True when a RAW file named `stem` (any RAW extension, case-insensitive) is in `folder`
    /// right now. A direct listing, never the cached stem index: callers ask right after this
    /// process moved files.
    static func folderContainsRAW(stem: String, in folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let wanted = stem.lowercased()
        return names.contains { name in
            let url = URL(fileURLWithPath: name)
            return url.deletingPathExtension().lastPathComponent.lowercased() == wanted
                && SupportedImageFormats.rawExtensions.contains(url.pathExtension.lowercased())
        }
    }

    /// True when `imageURL` is a RAW or has a same-stem RAW beside it — i.e. its stem `.xmp`'s
    /// develop settings belong to a RAW. Ask before a split moves anything.
    static func stemGroupIncludesRAW(_ imageURL: URL) -> Bool {
        SupportedImageFormats.isRaw(url: imageURL) || folderContainsRAW(
            stem: imageURL.deletingPathExtension().lastPathComponent,
            in: imageURL.deletingLastPathComponent())
    }

    /// For a stem `.xmp` that a RAW+JPEG split copied, moved or left behind. Its Camera Raw block
    /// belongs to the RAW; once no RAW shares its stem in its folder, the non-RAW photo beside it
    /// would adopt that block in place of its own embedded develop — dropping the JPEG's own
    /// Anonymizer redaction and giving it the RAW's absolute white balance and crop. So the
    /// develop block is removed (descriptive metadata stays). A sidecar still beside a RAW keeps
    /// it. Returns true when the file was rewritten.
    @discardableResult
    static func detachRawDevelopIfNoRAWBeside(sidecarURL: URL) throws -> Bool {
        let folder = sidecarURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              !folderContainsRAW(stem: sidecarURL.deletingPathExtension().lastPathComponent, in: folder)
        else { return false }
        let data = try Data(contentsOf: sidecarURL)
        guard let stripped = XMPSidecarService.removingDevelopBlock(from: data) else { return false }
        try XMPSidecarService.installSidecarBytes(stripped, at: sidecarURL)
        return true
    }

    /// Runs `detachRawDevelopIfNoRAWBeside` once per sidecar after a batch finished moving files
    /// (per-item decisions mid-batch would see a half-moved pair). Returns per-sidecar failures.
    static func detachRawDevelopAfterSplit(_ sidecarURLs: [URL]) -> [(URL, Error)] {
        var seen = Set<String>()
        var failures: [(URL, Error)] = []
        for url in sidecarURLs where seen.insert(url.standardizedFileURL.path.lowercased()).inserted {
            do { try detachRawDevelopIfNoRAWBeside(sidecarURL: url) }
            catch { failures.append((url, error)) }
        }
        return failures
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
                NSLocalizedDescriptionKey: "An older saved edits file (\(recordURL.lastPathComponent)) doesn't say which photo it belongs to, so it was left as it is."
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

/// Per-folder index of RAW files by lowercased stem. A listing is reused while the folder's
/// modification time (which changes whenever an entry is added, removed or renamed) is
/// unchanged. A listing taken within two seconds of that time is reused for at most one second
/// before being revalidated, so coarse network-volume timestamps can't hide a RAW that arrived
/// in the same tick, while bursts of lookups (a Develop commit rewrites the photo and bumps the
/// folder time) still list the directory only once.
nonisolated final class PhotoRawStemIndex: @unchecked Sendable {
    static let shared = PhotoRawStemIndex()

    private struct Entry {
        var modification: timespec
        let listedAt: Date
        let settled: Bool
        let rawByStem: [String: URL]
        /// The only folder changes since this listing were this process's own sidecar writes.
        var rolledForwardByOwnWrite = false
    }

    nonisolated static func folderKey(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func folderModification(_ folder: URL) -> timespec? {
        var status = stat()
        guard Darwin.lstat(folderKey(folder), &status) == 0 else { return nil }
        return status.st_mtimespec
    }

    /// After this process wrote a sidecar into `folder`: if the cached listing was settled and
    /// current just before that write, it is still correct (a sidecar is never a RAW), so carry it
    /// forward to the folder's new modification time. An unsettled listing (taken within the
    /// volume's timestamp granularity of a change) is never carried: a RAW that arrived in the
    /// same tick would stay hidden. Only read paths accept a carried listing.
    func noteOwnWrite(in folder: URL, previousModification: timespec?) {
        guard let previousModification, let current = Self.folderModification(folder),
              current.tv_sec != previousModification.tv_sec || current.tv_nsec != previousModification.tv_nsec
        else { return }
        let key = Self.folderKey(folder)
        lock.withLock {
            guard var entry = entries[key], entry.settled,
                  entry.modification.tv_sec == previousModification.tv_sec,
                  entry.modification.tv_nsec == previousModification.tv_nsec else { return }
            entry.modification = current
            entry.rolledForwardByOwnWrite = true
            entries[key] = entry
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let maximumFolders = 64
    private let freshReuseInterval: TimeInterval = 1
    private let settleInterval: TimeInterval = 2
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func rawFile(forStem stem: String, in folder: URL, allowsUnsettledReuse: Bool = true) -> URL? {
        let key = Self.folderKey(folder)
        var status = stat()
        guard Darwin.lstat(key, &status) == 0 else { return nil }
        let modification = status.st_mtimespec
        let currentTime = now()
        if let cached = lock.withLock({ entries[key] }),
           cached.modification.tv_sec == modification.tv_sec,
           cached.modification.tv_nsec == modification.tv_nsec,
           (cached.settled && !cached.rolledForwardByOwnWrite)
            || (allowsUnsettledReuse && (cached.rolledForwardByOwnWrite
                || currentTime.timeIntervalSince(cached.listedAt) <= freshReuseInterval)) {
            return cached.rawByStem[stem.lowercased()]
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: key) else { return nil }
        var rawByStem: [String: URL] = [:]
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            guard SupportedImageFormats.rawExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let rawStem = url.deletingPathExtension().lastPathComponent.lowercased()
            // Deterministic when several RAW formats share a stem.
            if let existing = rawByStem[rawStem], existing.lastPathComponent < name { continue }
            rawByStem[rawStem] = url
        }
        let modifiedAt = Double(modification.tv_sec) + Double(modification.tv_nsec) / 1_000_000_000
        let settled = currentTime.timeIntervalSince1970 - modifiedAt > settleInterval
        lock.withLock {
            if entries.count >= maximumFolders, entries[key] == nil { entries.removeAll() }
            entries[key] = Entry(modification: modification, listedAt: currentTime,
                                 settled: settled, rawByStem: rawByStem)
        }
        return rawByStem[stem.lowercased()]
    }
}
