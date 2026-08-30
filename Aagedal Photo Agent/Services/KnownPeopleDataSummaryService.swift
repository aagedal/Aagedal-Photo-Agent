import Foundation

/// Immutable evidence from a Known People storage measurement. A cancelled scan never exposes a
/// partial byte count to the main actor.
nonisolated enum KnownPeopleDataSummaryEvidence: Equatable, Sendable {
    case complete(KnownPeopleDataSummary)
    case cancelled
}

/// Serializes recursive Known People directory reads away from the main actor.
actor KnownPeopleDataSummaryService {
    static let shared = KnownPeopleDataSummaryService()

    nonisolated enum DirectorySizeEvidence: Equatable, Sendable {
        case complete(Int64)
        case cancelled
    }

    private let measureDirectory: @Sendable (URL) -> DirectorySizeEvidence

    init(
        measureDirectory: @escaping @Sendable (URL) -> DirectorySizeEvidence = {
            KnownPeopleDataSummaryService.systemDirectorySize(at: $0)
        }
    ) {
        self.measureDirectory = measureDirectory
    }

    func summarize(
        peopleCount: Int,
        sampleCount: Int,
        storageURL: URL,
        syncEnabled: Bool
    ) -> KnownPeopleDataSummaryEvidence {
        guard !Task.isCancelled else { return .cancelled }
        let measurement = measureDirectory(storageURL)
        guard !Task.isCancelled else { return .cancelled }

        switch measurement {
        case .complete(let storedBytes):
            return .complete(KnownPeopleDataSummary(
                peopleCount: peopleCount,
                sampleCount: sampleCount,
                storedBytes: storedBytes,
                syncEnabled: syncEnabled
            ))
        case .cancelled:
            return .cancelled
        }
    }

    /// Counts regular files only and never follows package descendants or symbolic links.
    nonisolated static func systemDirectorySize(at root: URL) -> DirectorySizeEvidence {
        guard !Task.isCancelled else { return .cancelled }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return Task.isCancelled ? .cancelled : .complete(0)
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return .cancelled }
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return Task.isCancelled ? .cancelled : .complete(total)
    }
}
