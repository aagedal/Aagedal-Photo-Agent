import Foundation

/// An immutable caption-sidecar write captured before navigation changes the metadata selection.
///
/// Capturing the complete document lets navigation publish its new focus immediately while the
/// small JSON/XMP writes run on a serial background queue. Repeating `persist()` is safe and is
/// used by the durable barrier to retry a previously failed write.
nonisolated struct CaptionDraftPersistence: Sendable {
    let imageURL: URL
    let folderURL: URL
    let sidecar: MetadataSidecar

    func persist() throws {
        try MetadataSidecarService().saveSidecar(sidecar, for: imageURL, in: folderURL)
        try XMPSidecarService().saveSidecar(metadata: sidecar.metadata, for: imageURL)
    }
}

/// FIFO persistence behind Caption navigation.
///
/// `enqueue` only appends work; it never waits for disk I/O. A failed item remains at the head of
/// the queue so a later durable barrier can retry it without allowing newer drafts to overtake it.
nonisolated final class CaptionDraftPersistenceQueue: @unchecked Sendable {
    private struct Item: @unchecked Sendable {
        let operation: @Sendable () throws -> Void
        let onFailure: @MainActor @Sendable (String) -> Void
    }

    private let queue: DispatchQueue
    private var items: [Item] = []
    private var failure: (any Error)?

    init(label: String = "com.aagedal.photo-agent.caption-persistence") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(
        _ persistence: CaptionDraftPersistence,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        enqueue(operation: { try persistence.persist() }, onFailure: onFailure)
    }

    /// Internal operation injection keeps ordering and non-blocking behavior deterministic in
    /// tests without introducing artificial delays into production persistence.
    func enqueue(
        operation: @escaping @Sendable () throws -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        let item = Item(operation: operation, onFailure: onFailure)
        queue.async { [self] in
            items.append(item)
            process(retryingFailure: false)
        }
    }

    /// Waits for every captured draft to reach disk. Failed work is retried in exact FIFO order.
    /// This is intentionally reserved for explicit durable actions and workspace exit.
    func drain() throws {
        var result: Result<Void, any Error> = .success(())
        queue.sync { [self] in
            process(retryingFailure: true)
            if let failure {
                result = .failure(failure)
            }
        }
        try result.get()
    }

    /// Asynchronous durable barrier used during application termination. Work still executes on
    /// the same FIFO queue, but the AppKit main actor remains free to service termination UI.
    func drainAsync() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                process(retryingFailure: true)
                if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    var pendingCount: Int {
        queue.sync { items.count }
    }

    private func process(retryingFailure: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        if retryingFailure {
            failure = nil
        } else if failure != nil {
            return
        }

        while let item = items.first {
            do {
                try item.operation()
                items.removeFirst()
            } catch {
                failure = error
                let message = error.localizedDescription
                Task { @MainActor in
                    item.onFailure(message)
                }
                return
            }
        }
        failure = nil
    }
}

/// Readiness shown by the Caption Workspace for one image.
nonisolated enum CaptionReadiness: String, Codable, Sendable {
    case ready
    case warnings
    case blocked
}

/// Every operation that must first commit buffered editor text.
nonisolated enum CaptionSessionAction: Sendable, Equatable {
    case navigate
    case changeSelection
    case copyPrevious
    case codeReplacement
    case applyTemplate
    case write
    case send
    case workspaceExit
}

/// Identifies one asynchronous load of the currently focused image.
///
/// Consumers must call ``CaptionSession/accepts(load:)`` before publishing a result. Navigation,
/// selection changes, and an explicit reload all invalidate older tokens, preventing a slow load
/// for the previous image from replacing the current draft.
nonisolated struct CaptionLoadToken: Hashable, Sendable {
    let imageURL: URL
    fileprivate let generation: UUID
}

/// Owns the navigation and transient editing state for the Caption Workspace.
///
/// Metadata persistence remains in `MetadataViewModel`. This type deliberately coordinates only
/// ordered images, focus/selection, dirty state, validation readiness, and transition barriers so
/// the workspace cannot grow a second metadata save implementation.
@MainActor
@Observable
final class CaptionSession {
    private(set) var orderedImageURLs: [URL]
    private(set) var currentIndex: Int?
    private(set) var selectedURLs: Set<URL>
    private(set) var dirtyURLs: Set<URL> = []
    private(set) var readinessByURL: [URL: CaptionReadiness] = [:]
    private(set) var isTransitioning = false

    @ObservationIgnored private var loadGeneration = UUID()

    var currentURL: URL? {
        guard let currentIndex, orderedImageURLs.indices.contains(currentIndex) else { return nil }
        return orderedImageURLs[currentIndex]
    }

    var position: Int? {
        currentIndex.map { $0 + 1 }
    }

    var count: Int { orderedImageURLs.count }
    var canGoPrevious: Bool { (currentIndex ?? 0) > 0 }
    var previousURL: URL? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        return orderedImageURLs[currentIndex - 1]
    }
    var canGoNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < orderedImageURLs.count
    }
    var isCurrentDirty: Bool { currentURL.map(dirtyURLs.contains) ?? false }
    var currentReadiness: CaptionReadiness? { currentURL.flatMap { readinessByURL[$0] } }

    init(imageURLs: [URL], currentURL: URL? = nil, selectedURLs: Set<URL> = []) {
        let ordered = Self.uniqueStandardizedURLs(imageURLs)
        self.orderedImageURLs = ordered

        let initialIndex: Int?
        if let currentURL,
           let index = ordered.firstIndex(of: currentURL.standardizedFileURL) {
            initialIndex = index
        } else {
            initialIndex = ordered.isEmpty ? nil : 0
        }
        self.currentIndex = initialIndex

        let available = Set(ordered)
        let normalizedSelection = Set(selectedURLs.map(\.standardizedFileURL))
            .intersection(available)
        if normalizedSelection.isEmpty, let focused = initialIndex.map({ ordered[$0] }) {
            self.selectedURLs = [focused]
        } else {
            self.selectedURLs = normalizedSelection
        }
    }

    /// Reconciles the session after the browser's visible/sorted image list changes.
    /// The same focused URL is retained when possible; otherwise the nearest surviving position is
    /// used. State for images no longer in the session is discarded.
    func replaceImages(_ imageURLs: [URL]) {
        let oldURL = currentURL
        let oldIndex = currentIndex ?? 0
        let ordered = Self.uniqueStandardizedURLs(imageURLs)
        orderedImageURLs = ordered

        if let oldURL, let retainedIndex = ordered.firstIndex(of: oldURL) {
            currentIndex = retainedIndex
        } else if ordered.isEmpty {
            currentIndex = nil
        } else {
            currentIndex = min(oldIndex, ordered.count - 1)
        }

        let available = Set(ordered)
        selectedURLs.formIntersection(available)
        dirtyURLs.formIntersection(available)
        readinessByURL = readinessByURL.filter { available.contains($0.key) }
        if selectedURLs.isEmpty, let currentURL {
            selectedURLs = [currentURL]
        }
        invalidateLoads()
    }

    func markCurrentDirty() {
        guard let currentURL else { return }
        dirtyURLs.insert(currentURL)
    }

    func markCommitted(_ imageURL: URL? = nil) {
        guard let url = (imageURL ?? currentURL)?.standardizedFileURL else { return }
        dirtyURLs.remove(url)
    }

    func setReadiness(_ readiness: CaptionReadiness?, for imageURL: URL) {
        let url = imageURL.standardizedFileURL
        guard orderedImageURLs.contains(url) else { return }
        readinessByURL[url] = readiness
    }

    /// Starts a load for the currently focused image.
    func beginLoad() -> CaptionLoadToken? {
        guard let currentURL else { return nil }
        return CaptionLoadToken(imageURL: currentURL, generation: loadGeneration)
    }

    /// Returns true only while `load` still belongs to the focused image and latest generation.
    func accepts(load: CaptionLoadToken) -> Bool {
        load.generation == loadGeneration && load.imageURL == currentURL
    }

    func invalidateLoads() {
        loadGeneration = UUID()
    }

    /// Flushes buffered editor state before an action that does not itself change focus.
    /// A thrown flush error prevents the caller from proceeding.
    func prepare(
        for action: CaptionSessionAction,
        flush: @MainActor () async throws -> Void
    ) async throws {
        guard !isTransitioning else { throw CaptionSessionError.transitionInProgress }
        isTransitioning = true
        defer { isTransitioning = false }
        try await flush()
        if action == .copyPrevious || action == .codeReplacement || action == .applyTemplate || action == .write || action == .send {
            invalidateLoads()
        }
    }

    @discardableResult
    func goPrevious(flush: @MainActor () async throws -> Void) async throws -> Bool {
        guard let currentIndex, currentIndex > 0 else { return false }
        return try await focus(index: currentIndex - 1, flush: flush)
    }

    @discardableResult
    func goNext(flush: @MainActor () async throws -> Void) async throws -> Bool {
        guard let currentIndex, currentIndex + 1 < orderedImageURLs.count else { return false }
        return try await focus(index: currentIndex + 1, flush: flush)
    }

    /// Changes the selected set and focused image only after buffered text commits successfully.
    @discardableResult
    func select(
        _ urls: Set<URL>,
        focusedURL: URL? = nil,
        flush: @MainActor () async throws -> Void
    ) async throws -> Bool {
        let available = Set(orderedImageURLs)
        var selection = Set(urls.map(\.standardizedFileURL)).intersection(available)
        let requestedFocus = focusedURL?.standardizedFileURL
        let targetURL = requestedFocus.flatMap { available.contains($0) ? $0 : nil }
            ?? orderedImageURLs.first(where: selection.contains)
            ?? currentURL
        guard let targetURL, let index = orderedImageURLs.firstIndex(of: targetURL) else {
            return false
        }
        if selection.isEmpty { selection = [targetURL] }

        guard selection != selectedURLs || index != currentIndex else { return false }
        try await transition(flush: flush) {
            selectedURLs = selection
            currentIndex = index
        }
        return true
    }

    @discardableResult
    private func focus(
        index: Int,
        flush: @MainActor () async throws -> Void
    ) async throws -> Bool {
        guard orderedImageURLs.indices.contains(index), index != currentIndex else { return false }
        try await transition(flush: flush) {
            currentIndex = index
            selectedURLs = [orderedImageURLs[index]]
        }
        return true
    }

    private func transition(
        flush: @MainActor () async throws -> Void,
        mutation: () -> Void
    ) async throws {
        guard !isTransitioning else { throw CaptionSessionError.transitionInProgress }
        isTransitioning = true
        defer { isTransitioning = false }
        try await flush()
        mutation()
        invalidateLoads()
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.compactMap { candidate in
            let url = candidate.standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }
    }
}

nonisolated enum CaptionSessionError: LocalizedError, Equatable, Sendable {
    case transitionInProgress

    var errorDescription: String? {
        switch self {
        case .transitionInProgress:
            return "Another caption action is already committing edits."
        }
    }
}

/// The single flush registration used while the Caption Workspace is visible.
///
/// The metadata panel owns AppKit's buffered text editor state, while workspace navigation and
/// the parent `ContentView` own transitions. Registering the panel's flush closure here lets both
/// callers cross the same persistence barrier without duplicating metadata save logic.
@MainActor
final class CaptionWorkspaceFlushCoordinator {
    static let shared = CaptionWorkspaceFlushCoordinator()

    private var owner: UUID?
    private var handler: (() throws -> Void)?
    private var compositionStateHandler: (() -> CodeReplacementCompositionState)?
    private var persistenceCaptureHandler: (() throws -> CaptionDraftPersistence?)?
    private var persistenceFailureHandler: (@MainActor @Sendable (String) -> Void)?
    private let persistenceQueue: CaptionDraftPersistenceQueue

    var hasRegisteredHandler: Bool { handler != nil }

    init(persistenceQueue: CaptionDraftPersistenceQueue = CaptionDraftPersistenceQueue()) {
        self.persistenceQueue = persistenceQueue
    }

    func register(
        owner: UUID,
        compositionState: @escaping () -> CodeReplacementCompositionState = { .committed },
        capturePersistence: @escaping () throws -> CaptionDraftPersistence? = { nil },
        persistenceFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        handler: @escaping () throws -> Void
    ) {
        self.owner = owner
        self.compositionStateHandler = compositionState
        self.persistenceCaptureHandler = capturePersistence
        self.persistenceFailureHandler = persistenceFailure
        self.handler = handler
    }

    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        compositionStateHandler = nil
        persistenceCaptureHandler = nil
        persistenceFailureHandler = nil
        handler = nil
    }

    /// Durable flush used by explicit mutations and workspace exit. It crosses the in-memory text
    /// barrier, captures the current draft, and waits for all queued drafts in FIFO order.
    func flush() throws {
        try enqueueFlush()
        try persistenceQueue.drain()
    }

    /// Navigation flush: commits AppKit's buffered text and snapshots persistence without waiting
    /// for sidecar disk I/O. A capture failure still prevents navigation.
    func enqueueFlush() throws {
        guard let handler,
              let persistenceCaptureHandler,
              let persistenceFailureHandler else {
            throw CaptionWorkspaceFlushError.handlerUnavailable
        }
        try handler()
        if let persistence = try persistenceCaptureHandler() {
            persistenceQueue.enqueue(persistence, onFailure: persistenceFailureHandler)
        }
    }

    func editorCompositionState() throws -> CodeReplacementCompositionState {
        guard handler != nil, let compositionStateHandler else {
            throw CaptionWorkspaceFlushError.handlerUnavailable
        }
        return compositionStateHandler()
    }

    fileprivate func drainQueuedPersistenceForTermination() async throws {
        try await persistenceQueue.drainAsync()
    }
}

/// One application-termination attempt captures the live editor at most once. If persistence
/// fails, retry drains the retained FIFO item without appending a duplicate draft behind it.
@MainActor
final class CaptionWorkspaceTerminationFlushOperation {
    private let coordinator: CaptionWorkspaceFlushCoordinator
    private var didCaptureCurrentDraft = false

    init(coordinator: CaptionWorkspaceFlushCoordinator = .shared) {
        self.coordinator = coordinator
    }

    func flush() async throws {
        if !didCaptureCurrentDraft {
            if coordinator.hasRegisteredHandler {
                try coordinator.enqueueFlush()
            }
            didCaptureCurrentDraft = true
        }
        try await coordinator.drainQueuedPersistenceForTermination()
    }
}

nonisolated enum CaptionWorkspaceFlushError: LocalizedError, Equatable, Sendable {
    case handlerUnavailable
    case sidecarUnavailable
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .handlerUnavailable:
            return "The caption editor is not ready to commit changes."
        case .sidecarUnavailable:
            return "The current folder is unavailable, so caption changes could not be saved."
        case let .persistenceFailed(message):
            return message
        }
    }
}

/// Maps the shared validation report to the compact status used by Caption Workspace.
nonisolated enum CaptionReadinessResolver {
    static func readiness(for report: MetadataValidationReport) -> CaptionReadiness {
        if report.blockerCount > 0 { return .blocked }
        if report.warningCount > 0 { return .warnings }
        return .ready
    }
}
