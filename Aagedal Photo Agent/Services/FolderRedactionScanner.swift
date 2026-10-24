import Foundation

/// Cheap on-disk check for whether a folder (recursively) holds photos with Anonymizer
/// redactions, for dragging a sidebar folder out of the app. Anonymizer settings are
/// app-private XMP (`aaphoto:AnonymizerAmount` / `AnonymizerBlackOut`, on the global layer and
/// on masks), so a byte search for the property name finds them without parsing: in `.xmp`
/// sidecars (the whole file) and in the XMP packet of non-RAW photos (the file's head, and its
/// tail for larger files, where HEIC/TIFF may keep metadata). RAW files never carry embedded
/// develop settings. Any hit — even a disabled mask — counts: over-refusing is recoverable.
nonisolated enum FolderRedactionScanner {
    enum Result: Equatable, Sendable {
        case clean
        case redacts
        /// The folder holds more files than the check covers, or it was cancelled or unreadable.
        case incomplete
    }

    static let marker = Data("Anonymizer".utf8)
    static let defaultFileLimit = 5_000
    static let photoWindowBytes = 256 * 1024
    static let sidecarByteLimit = 8 * 1024 * 1024

    @concurrent
    static func scanned(folderURL: URL, fileLimit: Int = defaultFileLimit) async -> Result {
        scan(folderURL: folderURL, fileLimit: fileLimit)
    }

    static func scan(folderURL: URL, fileLimit: Int = defaultFileLimit) -> Result {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return .incomplete }
        var examined = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { return .incomplete }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let isSidecar = url.pathExtension.lowercased() == "xmp"
            let isEmbeddedCarrier = !isSidecar
                && SupportedImageFormats.isSupported(url: url)
                && !SupportedImageFormats.isRaw(url: url)
            guard isSidecar || isEmbeddedCarrier else { continue }
            examined += 1
            if examined > fileLimit { return .incomplete }
            let size = values?.fileSize ?? 0
            if containsMarker(url: url, size: size, wholeFile: isSidecar) { return .redacts }
        }
        return .clean
    }

    private static func containsMarker(url: URL, size: Int, wholeFile: Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        if wholeFile {
            let data = (try? handle.read(upToCount: sidecarByteLimit)) ?? Data()
            return data.range(of: marker) != nil
        }
        if let head = try? handle.read(upToCount: photoWindowBytes), head.range(of: marker) != nil {
            return true
        }
        guard size > 2 * photoWindowBytes else { return false }
        do {
            try handle.seek(toOffset: UInt64(size - photoWindowBytes))
            let tail = try handle.read(upToCount: photoWindowBytes) ?? Data()
            return tail.range(of: marker) != nil
        } catch {
            return false
        }
    }
}
