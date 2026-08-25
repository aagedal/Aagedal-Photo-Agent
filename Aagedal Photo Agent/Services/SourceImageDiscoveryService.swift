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

// MARK: - Explicit companion association

/// A camera/card-layout rule validated outside the association engine. There is intentionally no
/// built-in Sony profile: supported bodies and firmware must be proven with real samples before
/// the application labels a filename match as an associated voice memo.
nonisolated struct VoiceMemoAssociationProfile: Codable, Equatable, Sendable {
    let identifier: String
    let imageFilenameExtensions: Set<String>
    let memoFilenameExtensions: Set<String>
    /// Components below the image's directory where the profile says memos are stored. Empty means
    /// adjacent to the image. Parent traversal and absolute components are rejected.
    let memoDirectoryComponents: [String]
    let filenameCaseSensitive: Bool

    init(
        identifier: String,
        imageFilenameExtensions: Set<String>,
        memoFilenameExtensions: Set<String> = ["wav"],
        memoDirectoryComponents: [String] = [],
        filenameCaseSensitive: Bool
    ) {
        self.identifier = identifier
        self.imageFilenameExtensions = Set(imageFilenameExtensions.map(Self.normalizedExtension))
        self.memoFilenameExtensions = Set(memoFilenameExtensions.map(Self.normalizedExtension))
        self.memoDirectoryComponents = memoDirectoryComponents
        self.filenameCaseSensitive = filenameCaseSensitive
    }

    var isValid: Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !imageFilenameExtensions.isEmpty
            && !memoFilenameExtensions.isEmpty
            && memoDirectoryComponents.allSatisfy(Self.isSafeDirectoryComponent)
    }

    private static func normalizedExtension(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func isSafeDirectoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}

nonisolated struct VoiceMemoAssociation: Codable, Equatable, Sendable {
    let profileIdentifier: String
    let imageURL: URL
    let memoURL: URL

    /// Converts a proven relationship into an explicit transactional rename companion. The source
    /// URL remains authoritative; only the accepted destination image stem is reused.
    var renameArtifact: RenamePlanningAssociatedArtifact {
        RenamePlanningAssociatedArtifact(
            identifier: "voice-memo",
            displayName: "Voice memo",
            sourceURL: memoURL,
            filenamePattern: RenameArtifactFilenamePattern(
                basis: .stem,
                suffix: memoURL.pathExtension.isEmpty ? "" : ".\(memoURL.pathExtension)"
            )
        )
    }
}

nonisolated struct VoiceMemoAssociationAmbiguity: Codable, Equatable, Sendable {
    let imageURLs: [URL]
    let memoURLs: [URL]
}

nonisolated struct VoiceMemoAssociationReport: Codable, Equatable, Sendable {
    let profileIdentifier: String
    let associations: [VoiceMemoAssociation]
    let imagesWithoutMemo: [URL]
    let ambiguous: [VoiceMemoAssociationAmbiguity]
    let orphanMemoURLs: [URL]

    func association(for imageURL: URL) -> VoiceMemoAssociation? {
        let canonical = VoiceMemoAssociationService.canonicalURL(imageURL)
        return associations.first { $0.imageURL == canonical }
    }
}

/// Deterministically associates voice memos using an explicit, sample-validated profile. A group
/// is associated only when it contains exactly one image and one memo. RAW+JPEG pairs, duplicate
/// memos, and case-folding collisions fail closed as ambiguities.
nonisolated struct VoiceMemoAssociationService: Sendable {
    enum AssociationError: Error, Equatable, Sendable {
        case invalidProfile
    }

    func associate(
        files: [URL],
        profile: VoiceMemoAssociationProfile
    ) throws -> VoiceMemoAssociationReport {
        guard profile.isValid else { throw AssociationError.invalidProfile }

        let uniqueFiles = Array(Set(files.filter(\.isFileURL).map(Self.canonicalURL)))
        let imageURLs = uniqueFiles.filter {
            profile.imageFilenameExtensions.contains($0.pathExtension.lowercased())
        }
        let memoURLs = uniqueFiles.filter {
            profile.memoFilenameExtensions.contains($0.pathExtension.lowercased())
        }
        let memosByKey = Dictionary(grouping: memoURLs) {
            key(forMemo: $0, profile: profile)
        }
        let imagesByKey = Dictionary(grouping: imageURLs) {
            key(forImage: $0, profile: profile)
        }

        var associations: [VoiceMemoAssociation] = []
        var missing: [URL] = []
        var ambiguities: [VoiceMemoAssociationAmbiguity] = []
        var claimedMemos = Set<URL>()

        for key in imagesByKey.keys.sorted() {
            let images = Self.sorted(imagesByKey[key] ?? [])
            let memos = Self.sorted(memosByKey[key] ?? [])
            if images.count == 1, memos.count == 1,
               let image = images.first, let memo = memos.first {
                associations.append(VoiceMemoAssociation(
                    profileIdentifier: profile.identifier,
                    imageURL: image,
                    memoURL: memo
                ))
                claimedMemos.insert(memo)
            } else if memos.isEmpty {
                missing.append(contentsOf: images)
            } else {
                ambiguities.append(VoiceMemoAssociationAmbiguity(
                    imageURLs: images,
                    memoURLs: memos
                ))
                claimedMemos.formUnion(memos)
            }
        }

        return VoiceMemoAssociationReport(
            profileIdentifier: profile.identifier,
            associations: associations.sorted { Self.urlLess($0.imageURL, $1.imageURL) },
            imagesWithoutMemo: Self.sorted(missing),
            ambiguous: ambiguities.sorted {
                Self.urlLess($0.imageURLs[0], $1.imageURLs[0])
            },
            orphanMemoURLs: Self.sorted(memoURLs.filter { !claimedMemos.contains($0) })
        )
    }

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func key(forImage url: URL, profile: VoiceMemoAssociationProfile) -> String {
        let memoDirectory = profile.memoDirectoryComponents.reduce(url.deletingLastPathComponent()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        return key(directory: memoDirectory, stem: url.deletingPathExtension().lastPathComponent, profile: profile)
    }

    private func key(forMemo url: URL, profile: VoiceMemoAssociationProfile) -> String {
        key(directory: url.deletingLastPathComponent(), stem: url.deletingPathExtension().lastPathComponent, profile: profile)
    }

    private func key(directory: URL, stem: String, profile: VoiceMemoAssociationProfile) -> String {
        let normalizedStem = profile.filenameCaseSensitive
            ? stem.precomposedStringWithCanonicalMapping
            : stem.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let directoryPath = Self.canonicalURL(directory).path.precomposedStringWithCanonicalMapping
        return directoryPath + "\u{0}" + normalizedStem
    }

    private static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted(by: urlLess)
    }

    private static func urlLess(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.path.localizedStandardCompare(rhs.path)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.path < rhs.path
    }
}

// MARK: - Sony dual-card voice memos

/// Metadata evidence used to prove that an image on the primary card and its JPEG counterpart on
/// the playback card describe the same exposure. The signature includes the camera identity,
/// firmware string, original timestamp, subsecond, and UTC offset when the camera recorded them.
nonisolated struct SonyVoiceMemoImageEvidence: Equatable, Sendable {
    let url: URL
    let captureSignature: String?
    let capturedAt: Date?
}

/// Associates Sony image variants and WAVs across one or two media sources. A WAV can be anchored
/// by a RAW or JPEG on its own source. Images with the same stem on the other source join the
/// exposure only when their exact capture signatures agree. Repeated variants, conflicting
/// signatures, duplicate WAVs, missing same-source anchors, and pre-capture WAVs fail closed.
/// There is deliberately no upper time limit for recording the memo.
nonisolated struct SonyDualCardVoiceMemoAssociationService: Sendable {
    static let profileIdentifier = "sony-dual-card-exact-capture-v1"

    func associate(
        primaryImages: [SonyVoiceMemoImageEvidence],
        companionImages: [SonyVoiceMemoImageEvidence],
        memoFileDates: [URL: Date]
    ) -> VoiceMemoAssociationReport {
        associate(
            primaryImages: primaryImages,
            companionImages: companionImages,
            primaryMemoFileDates: [:],
            companionMemoFileDates: memoFileDates
        )
    }

    func associate(
        primaryImages: [SonyVoiceMemoImageEvidence],
        companionImages: [SonyVoiceMemoImageEvidence],
        primaryMemoFileDates: [URL: Date],
        companionMemoFileDates: [URL: Date]
    ) -> VoiceMemoAssociationReport {
        let primary = Self.unique(primaryImages)
        let companion = Self.unique(companionImages)
        let allImages = Self.unique(primary + companion)
        let canonicalPrimaryMemoDates = Self.canonicalDates(primaryMemoFileDates)
        let canonicalCompanionMemoDates = Self.canonicalDates(companionMemoFileDates)
        let canonicalMemoDates = canonicalPrimaryMemoDates.merging(
            canonicalCompanionMemoDates,
            uniquingKeysWith: min
        )
        let memoURLs = Array(canonicalMemoDates.keys)

        let imagesByStem = Dictionary(grouping: allImages) { Self.stem($0.url) }
        let primaryByStem = Dictionary(grouping: primary) { Self.stem($0.url) }
        let companionByStem = Dictionary(grouping: companion) { Self.stem($0.url) }
        let memosByStem = Dictionary(grouping: memoURLs) { Self.stem($0) }

        var associations: [VoiceMemoAssociation] = []
        var missing: [URL] = []
        var ambiguous: [VoiceMemoAssociationAmbiguity] = []
        var claimedMemos = Set<URL>()

        for stem in imagesByStem.keys.sorted() {
            let images = Self.sortedEvidence(imagesByStem[stem] ?? [])
            let matchingMemos = Self.sortedURLs(memosByStem[stem] ?? [])

            guard !matchingMemos.isEmpty else {
                missing.append(contentsOf: images.map(\.url))
                continue
            }
            claimedMemos.formUnion(matchingMemos)

            let memoURL = matchingMemos.first
            let imageSignatures = Set(images.compactMap(\.captureSignature))
            let capturedDates = images.compactMap(\.capturedAt)
            let repeatedVariant = Dictionary(grouping: images) {
                Self.variantKind($0.url)
            }.values.contains { $0.count > 1 }
            let memoHasSameSourceAnchor: Bool
            if let memoURL, canonicalPrimaryMemoDates[memoURL] != nil {
                memoHasSameSourceAnchor = !(primaryByStem[stem] ?? []).isEmpty
            } else if let memoURL, canonicalCompanionMemoDates[memoURL] != nil {
                memoHasSameSourceAnchor = !(companionByStem[stem] ?? []).isEmpty
            } else {
                memoHasSameSourceAnchor = false
            }

            if matchingMemos.count == 1,
               let memoURL,
               images.allSatisfy({ $0.captureSignature != nil }),
               imageSignatures.count == 1,
               capturedDates.count == images.count,
               !repeatedVariant,
               memoHasSameSourceAnchor,
               let capturedAt = capturedDates.first,
               let memoDate = canonicalMemoDates[memoURL],
               memoDate >= capturedAt {
                associations.append(contentsOf: images.map {
                    VoiceMemoAssociation(
                        profileIdentifier: Self.profileIdentifier,
                        imageURL: $0.url,
                        memoURL: memoURL
                    )
                })
            } else {
                ambiguous.append(VoiceMemoAssociationAmbiguity(
                    imageURLs: images.map(\.url),
                    memoURLs: matchingMemos
                ))
            }
        }

        return VoiceMemoAssociationReport(
            profileIdentifier: Self.profileIdentifier,
            associations: associations.sorted { Self.urlLess($0.imageURL, $1.imageURL) },
            imagesWithoutMemo: Self.sortedURLs(missing),
            ambiguous: ambiguous.sorted {
                guard let left = $0.imageURLs.first, let right = $1.imageURLs.first else {
                    return $0.imageURLs.count < $1.imageURLs.count
                }
                return Self.urlLess(left, right)
            },
            orphanMemoURLs: Self.sortedURLs(memoURLs.filter { !claimedMemos.contains($0) })
        )
    }

    private static func canonicalDates(_ dates: [URL: Date]) -> [URL: Date] {
        Dictionary(
            dates.map {
                (VoiceMemoAssociationService.canonicalURL($0.key), $0.value)
            },
            uniquingKeysWith: min
        )
    }

    private static func variantKind(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg"].contains(ext) ? "jpeg" : ext
    }

    private static func unique(_ evidence: [SonyVoiceMemoImageEvidence]) -> [SonyVoiceMemoImageEvidence] {
        var seen = Set<URL>()
        return evidence.compactMap { item in
            let canonical = VoiceMemoAssociationService.canonicalURL(item.url)
            guard seen.insert(canonical).inserted else { return nil }
            return SonyVoiceMemoImageEvidence(
                url: canonical,
                captureSignature: item.captureSignature,
                capturedAt: item.capturedAt
            )
        }
    }

    private static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func sortedEvidence(
        _ evidence: [SonyVoiceMemoImageEvidence]
    ) -> [SonyVoiceMemoImageEvidence] {
        evidence.sorted { urlLess($0.url, $1.url) }
    }

    private static func sortedURLs(_ urls: [URL]) -> [URL] {
        urls.sorted(by: urlLess)
    }

    private static func urlLess(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.path.localizedStandardCompare(rhs.path)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.path < rhs.path
    }
}
