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
