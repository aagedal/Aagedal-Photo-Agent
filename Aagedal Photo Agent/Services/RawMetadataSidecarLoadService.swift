import Foundation

nonisolated struct RawMetadataSidecarSnapshot: Equatable, Sendable {
    let requestID: UUID
    let imageURL: URL
    let folderURL: URL
    let text: String
    let byteCount: Int
}

nonisolated enum RawMetadataSidecarLoadResult: Equatable, Sendable {
    case loaded(RawMetadataSidecarSnapshot)
    case notFound(requestID: UUID, imageURL: URL, folderURL: URL)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, imageURL: URL, byteCount: Int?)
}

nonisolated enum RawMetadataSidecarLoadError: LocalizedError, Equatable {
    case unsupportedEncoding

    var errorDescription: String? {
        "Unable to encode app sidecar."
    }
}

nonisolated struct RawMetadataSidecarAccess: Sendable {
    let readEncodedSidecar: @Sendable (URL, URL) throws -> Data?

    static let system = RawMetadataSidecarAccess { imageURL, folderURL in
        guard let sidecar = MetadataSidecarService().loadSidecar(
            for: imageURL,
            in: folderURL
        ) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sidecar)
    }
}

/// Serializes app-sidecar reads and JSON encoding away from MainActor for the Raw Metadata
/// inspector. A synchronous filesystem read cannot be preempted after it starts, so cancellation
/// on either side of that read is represented explicitly and no partial text is published.
actor RawMetadataSidecarLoadService {
    static let shared = RawMetadataSidecarLoadService()

    private let access: RawMetadataSidecarAccess

    init(access: RawMetadataSidecarAccess = .system) {
        self.access = access
    }

    func load(
        imageURL: URL,
        folderURL: URL,
        requestID: UUID
    ) throws -> RawMetadataSidecarLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }

        let data = try access.readEncodedSidecar(imageURL, folderURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                imageURL: imageURL,
                byteCount: data?.count
            )
        }
        guard let data else {
            return .notFound(
                requestID: requestID,
                imageURL: imageURL,
                folderURL: folderURL
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RawMetadataSidecarLoadError.unsupportedEncoding
        }

        return .loaded(RawMetadataSidecarSnapshot(
            requestID: requestID,
            imageURL: imageURL,
            folderURL: folderURL,
            text: text,
            byteCount: data.count
        ))
    }
}
