import Foundation

/// One retained claim travels with setup, admission and each in-flight provider.
nonisolated final class WhisperArtifactAccess: @unchecked Sendable {
    let url: URL
    private let stop: @Sendable (URL) -> Void
    private let accessed: Bool

    init(_ url: URL, start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stop = stop
        accessed = start(url)
    }

    deinit { if accessed { stop(url) } }
}

/// Bookmark APIs and filesystem checks never block the presentation actor.
actor FFmpegWhisperBookmarkService {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.whisper-bookmarks", qos: .utility
    )
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    nonisolated struct Selection: Sendable {
        let access: WhisperArtifactAccess
        let bookmark: Data
    }

    nonisolated struct Dependencies: Sendable {
        var create: @Sendable (URL) throws -> Data = {
            try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        var resolve: @Sendable (Data) throws -> (URL, Bool) = {
            var stale = false
            let url = try URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        }
        var access: @Sendable (URL) -> WhisperArtifactAccess = { WhisperArtifactAccess($0) }
        var exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let dependencies: Dependencies
    init(dependencies: Dependencies = Dependencies()) { self.dependencies = dependencies }

    func select(_ url: URL) throws -> Selection {
        try Task.checkCancellation()
        let access = dependencies.access(url)
        let bookmark = try dependencies.create(url)
        try Task.checkCancellation()
        return Selection(access: access, bookmark: bookmark)
    }

    func restore(_ bookmark: Data) throws -> Selection {
        try Task.checkCancellation()
        let (url, stale) = try dependencies.resolve(bookmark)
        let access = dependencies.access(url)
        guard dependencies.exists(url) else { throw CocoaError(.fileNoSuchFile) }
        // Never replace a valid retained grant with an unrefreshed stale bookmark.
        let updated = stale ? try dependencies.create(url) : bookmark
        try Task.checkCancellation()
        return Selection(access: access, bookmark: updated)
    }
}
