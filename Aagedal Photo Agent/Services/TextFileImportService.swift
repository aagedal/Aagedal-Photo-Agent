import Foundation

nonisolated struct TextFileImportSnapshot: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let text: String
    let byteCount: Int
}

nonisolated enum TextFileImportResult: Equatable, Sendable {
    case loaded(TextFileImportSnapshot)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int)
}

nonisolated enum TextFileImportError: LocalizedError, Equatable {
    case unsupportedEncoding(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "Could not decode file contents."
        }
    }
}

nonisolated struct TextFileImportReader: Sendable {
    let read: @Sendable (URL) throws -> Data

    static let system = TextFileImportReader { url in
        try Data(contentsOf: url)
    }
}

/// Serializes user-selected text-file reads away from MainActor. Foundation file reads cannot be
/// preempted once entered, so cancellation before and after the synchronous read are distinct,
/// immutable results and callers never receive a partial text snapshot.
actor TextFileImportService {
    static let shared = TextFileImportService()

    private let reader: TextFileImportReader

    init(reader: TextFileImportReader = .system) {
        self.reader = reader
    }

    func loadText(
        from sourceURL: URL,
        requestID: UUID
    ) throws -> TextFileImportResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }

        let data = try reader.read(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw TextFileImportError.unsupportedEncoding(sourceURL)
        }

        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }

        return .loaded(TextFileImportSnapshot(
            requestID: requestID,
            sourceURL: sourceURL,
            text: text,
            byteCount: data.count
        ))
    }
}

nonisolated struct BundleTextResourceSnapshot: Equatable, Sendable {
    let requestID: UUID
    let resourceName: String
    let fileExtension: String
    let text: String
    let byteCount: Int
}

nonisolated enum BundleTextResourceLoadResult: Equatable, Sendable {
    case loaded(BundleTextResourceSnapshot)
    case notFound(requestID: UUID, resourceName: String)
    case cancelled(requestID: UUID, completedAccessCount: Int)
}

nonisolated enum BundleTextResourceError: LocalizedError, Equatable {
    case unsupportedEncoding(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "Could not decode bundled text resource."
        }
    }
}

nonisolated struct BundleTextResourceAccess: Sendable {
    let resourceURL: @Sendable (String, String) -> URL?
    let read: @Sendable (URL) throws -> Data

    static let system = BundleTextResourceAccess(
        resourceURL: { name, fileExtension in
            Bundle.main.url(forResource: name, withExtension: fileExtension)
        },
        read: { try Data(contentsOf: $0, options: .mappedIfSafe) }
    )
}

/// Serializes bundle resource lookup and reading away from MainActor. Although these files ship in
/// the app bundle, the bundle can still reside on a slow or externally backed volume. Foundation's
/// synchronous lookup/read calls are non-preemptible, so cancellation is reported only at stable
/// boundaries and no partial bytes are published to the settings view.
actor BundleTextResourceService {
    static let shared = BundleTextResourceService()

    private let access: BundleTextResourceAccess

    init(access: BundleTextResourceAccess = .system) {
        self.access = access
    }

    func loadText(
        resourceName: String,
        fileExtensions: [String],
        requestID: UUID
    ) throws -> BundleTextResourceLoadResult {
        var completedAccessCount = 0

        guard !Task.isCancelled else {
            return .cancelled(requestID: requestID, completedAccessCount: 0)
        }

        for fileExtension in fileExtensions {
            guard !Task.isCancelled else {
                return .cancelled(
                    requestID: requestID,
                    completedAccessCount: completedAccessCount
                )
            }

            guard let url = access.resourceURL(resourceName, fileExtension) else {
                completedAccessCount += 1
                continue
            }
            completedAccessCount += 1

            guard !Task.isCancelled else {
                return .cancelled(
                    requestID: requestID,
                    completedAccessCount: completedAccessCount
                )
            }

            let data = try access.read(url)
            completedAccessCount += 1
            guard !Task.isCancelled else {
                return .cancelled(
                    requestID: requestID,
                    completedAccessCount: completedAccessCount
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw BundleTextResourceError.unsupportedEncoding(url)
            }
            return .loaded(BundleTextResourceSnapshot(
                requestID: requestID,
                resourceName: resourceName,
                fileExtension: fileExtension,
                text: text,
                byteCount: data.count
            ))
        }

        return .notFound(requestID: requestID, resourceName: resourceName)
    }
}

nonisolated struct TextFileExportCommit: Equatable, Sendable {
    let requestID: UUID
    let destinationURL: URL
    let byteCount: Int
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum TextFileExportResult: Equatable, Sendable {
    case committed(TextFileExportCommit)
    case cancelledBeforeWrite(requestID: UUID)
}

nonisolated struct TextFileExportWriter: Sendable {
    let write: @Sendable (Data, URL) throws -> Void

    static let system = TextFileExportWriter { data, destination in
        try data.write(to: destination, options: .atomic)
    }
}

/// Serializes user-selected UTF-8 text exports away from MainActor. The atomic Foundation write
/// cannot be preempted once entered, so a cancellation observed after it returns is reported as a
/// durable commit instead of being mistaken for a write that never happened.
actor TextFileExportService {
    static let shared = TextFileExportService()

    private let writer: TextFileExportWriter

    init(writer: TextFileExportWriter = .system) {
        self.writer = writer
    }

    func writeText(
        _ text: String,
        to destinationURL: URL,
        requestID: UUID
    ) throws -> TextFileExportResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeWrite(requestID: requestID)
        }

        let data = Data(text.utf8)
        try writer.write(data, destinationURL)
        return .committed(TextFileExportCommit(
            requestID: requestID,
            destinationURL: destinationURL,
            byteCount: data.count,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }
}

nonisolated struct QuickListExistingFileEvidence: Equatable, Sendable {
    let requestID: UUID
    let destinationURL: URL
    let cancellationRequestedAfterCheck: Bool
}

nonisolated struct QuickListFileCreationCommit: Equatable, Sendable {
    let requestID: UUID
    let destinationURL: URL
    let byteCount: Int
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum QuickListFileCreationResult: Equatable, Sendable {
    case existing(QuickListExistingFileEvidence)
    case created(QuickListFileCreationCommit)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledBeforeCreation(requestID: UUID, destinationURL: URL)
}

nonisolated struct QuickListFileAccess: Sendable {
    let fileExists: @Sendable (URL) -> Bool
    let createEmptyFile: @Sendable (URL) throws -> Void

    static let system = QuickListFileAccess(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        // Preserve a file that appears between the existence probe and commit (for example from
        // a collaborating process or synced volume) instead of replacing it with an empty file.
        createEmptyFile: { try Data().write(to: $0, options: [.atomic, .withoutOverwriting]) }
    )
}

/// Serializes the existence probe and conditional empty-file commit selected by MetadataPanel.
/// Both Foundation calls can block on external, network, or cloud-backed volumes. Cancellation is
/// therefore observed around the non-preemptible calls, while a completed write always returns
/// immutable commit evidence even if cancellation arrived while the write was in flight.
actor QuickListFileCreationService {
    static let shared = QuickListFileCreationService()

    private let access: QuickListFileAccess

    init(access: QuickListFileAccess = .system) {
        self.access = access
    }

    func createIfNeeded(
        at destinationURL: URL,
        requestID: UUID
    ) throws -> QuickListFileCreationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeAccess(requestID: requestID)
        }

        if access.fileExists(destinationURL) {
            return .existing(QuickListExistingFileEvidence(
                requestID: requestID,
                destinationURL: destinationURL,
                cancellationRequestedAfterCheck: Task.isCancelled
            ))
        }

        guard !Task.isCancelled else {
            return .cancelledBeforeCreation(
                requestID: requestID,
                destinationURL: destinationURL
            )
        }

        try access.createEmptyFile(destinationURL)
        return .created(QuickListFileCreationCommit(
            requestID: requestID,
            destinationURL: destinationURL,
            byteCount: 0,
            cancellationRequestedAfterCommit: Task.isCancelled
        ))
    }
}
