import Foundation

/// Finds files on the second import source that are copies of a file on the first, such as a
/// dual-slot camera recording every frame to both cards. A name match alone is not enough: the
/// size and the sampled content hash (`HashStream.quickHashFile`, the check "skip previously
/// imported" uses) must agree too.
nonisolated enum ImportCrossSourceDuplicateDetector {
    /// The companion files that duplicate a primary file, or nil when cancelled.
    @concurrent
    static func duplicates(
        companionFiles: [URL],
        primaryFiles: [URL],
        primaryRoot: URL?,
        companionRoot: URL?
    ) async -> Set<URL>? {
        let didStartAccessingPrimary = primaryRoot?.startAccessingSecurityScopedResource() ?? false
        let didStartAccessingCompanion = companionRoot?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStartAccessingPrimary { primaryRoot?.stopAccessingSecurityScopedResource() }
            if didStartAccessingCompanion { companionRoot?.stopAccessingSecurityScopedResource() }
        }

        let primaryByName = Dictionary(grouping: primaryFiles) { $0.lastPathComponent.lowercased() }
        // The hash covers the file size; an unreadable file has no hash and is never a copy.
        var hashes: [URL: Data?] = [:]
        func hash(_ url: URL) -> Data? {
            if let cached = hashes[url] { return cached }
            let value = try? HashStream.quickHashFile(at: url)
            hashes.updateValue(value, forKey: url)
            return value
        }

        var duplicates = Set<URL>()
        for companion in companionFiles {
            guard !Task.isCancelled else { return nil }
            guard let candidates = primaryByName[companion.lastPathComponent.lowercased()],
                  let companionHash = hash(companion) else { continue }
            for primary in candidates {
                guard !Task.isCancelled else { return nil }
                // Same path means the two sources overlap; that is one file, not a duplicate.
                guard primary.standardizedFileURL != companion.standardizedFileURL,
                      hash(primary) == companionHash else { continue }
                duplicates.insert(companion)
                break
            }
        }
        return duplicates
    }
}
