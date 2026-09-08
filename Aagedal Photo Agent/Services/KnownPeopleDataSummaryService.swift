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

    // Recursive provider enumeration must not occupy a cooperative executor thread.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    nonisolated enum DirectorySizeEvidence: Equatable, Sendable {
        case complete(Int64)
        case unavailable
        case cancelled
    }

    private let measureDirectory: @Sendable (URL) -> DirectorySizeEvidence

    init(
        measureDirectory: @escaping @Sendable (URL) -> DirectorySizeEvidence = {
            KnownPeopleDataSummaryService.systemDirectorySize(at: $0)
        },
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.known-people.storage-summary", qos: .utility
        )
    ) {
        self.measureDirectory = measureDirectory
        self.filesystemQueue = filesystemQueue
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
        case .unavailable:
            return .complete(KnownPeopleDataSummary(
                peopleCount: peopleCount,
                sampleCount: sampleCount,
                storedBytes: nil,
                syncEnabled: syncEnabled
            ))
        }
    }

    /// Counts regular files only and never follows package descendants or symbolic links.
    nonisolated static func systemDirectorySize(at root: URL) -> DirectorySizeEvidence {
        guard !Task.isCancelled else { return .cancelled }
        do {
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                return .unavailable
            }
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileReadNoSuchFileError {
                return .complete(0)
            }
            return .unavailable
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            return Task.isCancelled ? .cancelled : .unavailable
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return .cancelled }
            guard let values = try? fileURL.resourceValues(forKeys: keys) else {
                return .unavailable
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size >= 0 else { return .unavailable }
            let addition = total.addingReportingOverflow(Int64(size))
            guard !addition.overflow else { return .unavailable }
            total = addition.partialValue
        }
        if Task.isCancelled { return .cancelled }
        return enumerationFailed ? .unavailable : .complete(total)
    }
}
