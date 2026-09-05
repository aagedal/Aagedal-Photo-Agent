import Foundation

/// Immutable URL facts prepared before Compare or Analysis updates live state. Reading these
/// dictionaries never consults the filesystem, including when a destination itself is a symlink.
nonisolated struct PreparedRenameIdentities: Sendable {
    let lookupURLs: [URL: URL]
    let canonicalURLs: [URL: URL]

    func lookup(_ url: URL) -> URL {
        precondition(lookupURLs[url] != nil, "Rename identity was not prepared")
        return lookupURLs[url]!
    }

    func canonical(_ url: URL) -> URL {
        precondition(canonicalURLs[url] != nil, "Rename destination was not prepared")
        return canonicalURLs[url]!
    }

    func contains(_ urls: [URL]) -> Bool {
        urls.allSatisfy { lookupURLs[$0] != nil }
    }
}

/// Foundation symlink resolution may block on a network volume. Serialize that work on this
/// actor and publish only a complete, non-cancelled snapshot to MainActor consumers.
actor RenameIdentityPreparationService {
    static let shared = RenameIdentityPreparationService()
    private let lookup: @Sendable (URL) -> URL
    private let canonical: @Sendable (URL) -> URL

    init(
        lookup: @escaping @Sendable (URL) -> URL = renameReassociationLookupURL,
        canonical: @escaping @Sendable (URL) -> URL = {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
    ) {
        self.lookup = lookup
        self.canonical = canonical
    }

    func prepare(urls: [URL], destinations: [URL]) throws -> PreparedRenameIdentities {
        try Task.checkCancellation()
        var lookupURLs: [URL: URL] = [:]
        var canonicalURLs: [URL: URL] = [:]
        for url in Set(urls + destinations + destinations.map(\.standardizedFileURL)) {
            try Task.checkCancellation()
            lookupURLs[url] = lookup(url)
        }
        for url in Set(destinations + destinations.map(\.standardizedFileURL)) {
            try Task.checkCancellation()
            let resolved = canonical(url)
            canonicalURLs[url] = resolved
            lookupURLs[resolved] = lookup(resolved)
        }
        try Task.checkCancellation()
        return PreparedRenameIdentities(lookupURLs: lookupURLs, canonicalURLs: canonicalURLs)
    }
}
