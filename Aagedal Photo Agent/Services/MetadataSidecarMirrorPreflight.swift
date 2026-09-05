import Foundation

/// Filters embedded read-back work without probing storage on MainActor. These facts are only
/// an optimization: the serialized XMP commit must recheck existence on every transaction attempt.
actor MetadataSidecarMirrorPreflight {
    static let shared = MetadataSidecarMirrorPreflight()

    private let exists: @Sendable (URL) -> Bool

    init(exists: @escaping @Sendable (URL) -> Bool = { XMPSidecarService().sidecarExists(for: $0) }) {
        self.exists = exists
    }

    func existingImageURLs(_ urls: [URL]) throws -> [URL] {
        try Task.checkCancellation()
        var result: [URL] = []
        for url in urls {
            try Task.checkCancellation()
            if exists(url) { result.append(url) }
            try Task.checkCancellation()
        }
        return result
    }
}
