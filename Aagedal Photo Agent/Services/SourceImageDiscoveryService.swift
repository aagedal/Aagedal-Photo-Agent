import Foundation

/// Locates the exact bytes recorded by a persisted ``SourceImageRevision``.
///
/// Paths, filenames, resource identifiers, and byte counts are only used to order or
/// eliminate candidates. A candidate is never returned as an exact match until its
/// SHA-256 digest has been captured and compared with the persisted revision.
nonisolated struct SourceImageDiscoveryService: Sendable {
    enum MatchMethod: Equatable, Sendable {
        /// The source is still present at its recorded canonical URL.
        case currentPath
        /// A single candidate retained the source's filesystem resource identifier.
        case fileResourceIdentifier
        /// A single candidate matched by content after the stronger hints failed.
        case contentHash
    }

    enum Result: Equatable, Sendable {
        case located(SourceImageRevision, method: MatchMethod)
        /// More than one URL contains the exact bytes and no stronger hint selects one.
        /// The caller must ask the user which location should own future persisted work.
        case ambiguous([SourceImageRevision])
        /// The recorded path or filesystem object still exists, but its bytes changed.
        case sourceChanged(SourceImageRevision)
        case notFound
    }

    /// Searches a caller-provided set of files for an exact source revision.
    ///
    /// The recorded canonical URL is always checked as well. Candidates with a different
    /// byte count are rejected without hashing. Same-path and resource-ID candidates are
    /// hashed first, followed by filename matches and then the remaining same-size files.
    func discover(
        _ source: SourceImageRevision,
        among candidateURLs: [URL]
    ) async throws -> Result {
        try Task.checkCancellation()

        let candidates = candidateSnapshots(
            for: source,
            candidateURLs: candidateURLs
        )

        var exactMatches: [SourceImageRevision] = []
        var changedAtCurrentPath: SourceImageRevision?
        var changedResourceMatches: [SourceImageRevision] = []

        for candidate in candidates {
            try Task.checkCancellation()

            let revision: SourceImageRevision
            do {
                revision = try await SourceImageRevision.capture(
                    at: candidate.url,
                    pixelWidth: source.pixelWidth,
                    pixelHeight: source.pixelHeight,
                    exifOrientation: source.exifOrientation
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A candidate may disappear, become unavailable from iCloud, lose access,
                // or change while hashing. None of those failures weaken exact matching.
                continue
            }

            switch source.relationship(to: revision) {
            case .exactRevision:
                exactMatches.append(revision)
            case .sameFileChanged:
                changedResourceMatches.append(revision)
                if candidate.isCurrentPath {
                    changedAtCurrentPath = revision
                }
            case .samePathChanged:
                if candidate.isCurrentPath {
                    changedAtCurrentPath = revision
                }
            case .unrelated:
                break
            }
        }

        if let currentMatch = exactMatches.first(where: {
            $0.canonicalURL == source.canonicalURL
        }) {
            return .located(currentMatch, method: .currentPath)
        }

        let resourceMatches = exactMatches.filter {
            source.fileResourceIdentifier != nil
                && $0.fileResourceIdentifier == source.fileResourceIdentifier
        }
        if resourceMatches.count == 1, let match = resourceMatches.first {
            return .located(match, method: .fileResourceIdentifier)
        }
        if resourceMatches.count > 1 {
            return .ambiguous(Self.sorted(resourceMatches))
        }

        if exactMatches.count == 1, let match = exactMatches.first {
            return .located(match, method: .contentHash)
        }
        if exactMatches.count > 1 {
            return .ambiguous(Self.sorted(exactMatches))
        }

        if let changedAtCurrentPath {
            return .sourceChanged(changedAtCurrentPath)
        }
        if changedResourceMatches.count == 1, let changed = changedResourceMatches.first {
            return .sourceChanged(changed)
        }
        return .notFound
    }
}

private extension SourceImageDiscoveryService {
    struct CandidateSnapshot {
        let url: URL
        let fileResourceIdentifier: SourceImageRevision.FileResourceIdentifier?
        let isCurrentPath: Bool
        let hasOriginalFilename: Bool

        nonisolated var priority: Int {
            if isCurrentPath { return 0 }
            if fileResourceIdentifier != nil { return 1 }
            if hasOriginalFilename { return 2 }
            return 3
        }
    }

    nonisolated func candidateSnapshots(
        for source: SourceImageRevision,
        candidateURLs: [URL]
    ) -> [CandidateSnapshot] {
        var seen = Set<URL>()
        var urls = [source.canonicalURL]
        urls.append(contentsOf: candidateURLs)

        return urls.compactMap { inputURL -> CandidateSnapshot? in
            guard inputURL.isFileURL else { return nil }
            let url = inputURL.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(url).inserted else { return nil }

            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .fileResourceIdentifierKey
            ]),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            Int64(fileSize) == source.byteCount else {
                return nil
            }

            let identifier = SourceImageRevision.FileResourceIdentifier(
                foundationValue: values.fileResourceIdentifier
            )
            return CandidateSnapshot(
                url: url,
                fileResourceIdentifier: identifier == source.fileResourceIdentifier
                    ? identifier
                    : nil,
                isCurrentPath: url == source.canonicalURL,
                hasOriginalFilename: url.lastPathComponent == source.filenameAtCreation
            )
        }
        .sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    nonisolated static func sorted(
        _ revisions: [SourceImageRevision]
    ) -> [SourceImageRevision] {
        revisions.sorted {
            $0.canonicalURL.path.localizedStandardCompare($1.canonicalURL.path) == .orderedAscending
        }
    }
}
