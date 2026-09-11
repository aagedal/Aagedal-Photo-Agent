import Foundation
import CryptoKit

/// An immutable caption-sidecar write captured before navigation changes the metadata selection.
///
/// Capturing the complete document lets navigation publish its new focus immediately while the
/// small JSON/XMP writes run on a serial background queue. Repeating `persist()` is safe and is
/// used by the durable barrier to retry a previously failed write.
nonisolated struct CaptionDraftPersistence: Sendable {
    let request: MetadataSidecarReplayRequest
    var imageURL: URL { request.imageURL }
    var folderURL: URL { request.folderURL }
    var sidecar: MetadataSidecar { request.sidecar }

    @discardableResult
    func persist() throws -> MetadataSidecar {
        // DispatchQueue.sync may run a durable retry inline on the caller's MainActor task.
        // Give this synchronous-to-async bridge an independent task context so the semaphore
        // cannot block the executor needed by its own persistence work.
        let completion = DispatchSemaphore(value: 0)
        let result = CaptionPersistenceResult()
        Task.detached {
            do {
                let persistence = await MetadataSidecarService().replayHistoryAndMirrorXMP(request)
                guard persistence.completed else {
                    if persistence.failure?.kind == .replayConflict {
                        throw CaptionWorkspaceFlushError.replayConflict(persistence.failure!.message)
                    }
                    throw CaptionWorkspaceFlushError.persistenceFailed(
                        persistence.failure?.message ?? "The captured Caption draft did not finish saving."
                    )
                }
                guard let installed = persistence.installedSidecar else {
                    throw CaptionWorkspaceFlushError.persistenceFailed("The captured metadata draft has no verified save receipt.")
                }
                result.set(.success(installed))
            } catch {
                result.set(.failure(error))
            }
            completion.signal()
        }
        completion.wait()
        return try result.get().get()
    }
}

nonisolated private final class CaptionPersistenceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<MetadataSidecar, any Error>?

    nonisolated func set(_ newValue: Result<MetadataSidecar, any Error>) {
        lock.withLock { value = newValue }
    }

    nonisolated func get() -> Result<MetadataSidecar, any Error> {
        lock.withLock { value! }
    }
}

nonisolated struct CaptionQueueFailure: Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case replayConflict, transient }
    let id: UUID
    let photoURL: URL?
    let message: String
    let kind: Kind
    let generation: UInt64
    let affectedRequestCount: Int
}

nonisolated struct CaptionConflictSnapshot: Identifiable, Sendable {
    let id: UUID
    let photoURL: URL
    let failure: CaptionQueueFailure
    let requestIDs: [UUID]
    let queueGeneration: UInt64
    fileprivate let exportData: Data
    var requestCount: Int { requestIDs.count }
}

nonisolated struct CaptionConflictExportReceipt: Sendable {
    let exportURL: URL
    let sha256: String
    let requestIDs: [UUID]
    let queueGeneration: UInt64
    let reviewID: UUID
}

nonisolated struct CaptionConflictDiscardResult: Sendable {
    let discardedCount: Int
    let remainingFailure: CaptionQueueFailure?
}

nonisolated enum CaptionConflictRecoveryError: LocalizedError, Sendable {
    case obsoleteReview, reviewInProgress, unsafeExport, exportVerificationFailed
    var errorDescription: String? {
        switch self {
        case .obsoleteReview: return "The queued requests changed. Review and export the current conflict again."
        case .reviewInProgress: return "Queued edits for this photo are being reviewed. Finish or cancel the review first."
        case .unsafeExport: return "Choose a separate recovery JSON file outside the photo metadata folder. Existing photo and sidecar files must be preserved."
        case .exportVerificationFailed: return "The recovery export could not be verified. All queued edits were retained. Export again before discarding."
        }
    }
}

/// Recovery carries the technical fields separately because ordinary editorial JSON omits them.
nonisolated private struct CaptionRecoveryMetadata: Codable {
    let editorial: IPTCMetadata
    let cameraRaw: CameraRawSettings?
    let orientation: Int?
    init(_ metadata: IPTCMetadata) {
        editorial = metadata
        cameraRaw = metadata.cameraRaw
        orientation = metadata.exifOrientation
    }
}

nonisolated private struct CaptionRecoveryRequest: Encodable {
    let requestID: UUID
    let imageURL: URL
    let folderURL: URL
    let sidecar: MetadataSidecar
    let capturedMetadata: CaptionRecoveryMetadata
    let originalImageSnapshot: CaptionRecoveryMetadata?
    let baselineMetadata: CaptionRecoveryMetadata
    let baselineHistory: [MetadataHistoryEntry]
    let baselineRecordExisted: Bool
    let changes: [MetadataHistoryEntry]
    let jsonWasCommitted: Bool
    let creationEvidence: MetadataSidecarReplayCreationEvidence?
    let creationEvidenceInvalidated: Bool
    let creationMirrorCompleted: Bool
    let creationInstalledXMPData: Data?
    init(id: UUID, persistence: CaptionDraftPersistence) {
        let request = persistence.request
        requestID = id
        imageURL = request.imageURL
        folderURL = request.folderURL
        sidecar = request.sidecar
        capturedMetadata = .init(request.sidecar.metadata)
        originalImageSnapshot = request.sidecar.imageMetadataSnapshot.map(CaptionRecoveryMetadata.init)
        baselineMetadata = .init(request.baselineMetadata)
        baselineHistory = request.baselineHistory
        baselineRecordExisted = request.baselineRecordExisted
        changes = request.changes
        jsonWasCommitted = request.receipt.hasCommitted
        creationEvidence = request.creationEvidence
        creationEvidenceInvalidated = request.receipt.creationEvidenceInvalidated
        creationMirrorCompleted = request.receipt.creationMirrorCompleted
        creationInstalledXMPData = request.receipt.creationInstalledXMPData
    }
}

nonisolated private struct CaptionRecoveryDocument: Encodable {
    let formatVersion = 1
    let reviewID: UUID
    let photoURL: URL
    let queueGeneration: UInt64
    let conflictReason: String
    let requests: [CaptionRecoveryRequest]
}

nonisolated struct CaptionConflictExportAccess: Sendable {
    var writeAtomic: @Sendable (Data, URL) throws -> Void = { data, url in
        let manager = FileManager.default
        let stage = url.deletingLastPathComponent().appendingPathComponent(".caption-recovery-\(UUID().uuidString).json")
        guard manager.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: stage) }
        guard try Data(contentsOf: stage) == data else { throw CaptionConflictRecoveryError.exportVerificationFailed }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: stage)
        } else {
            try manager.moveItem(at: stage, to: url)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
}

nonisolated struct CaptionQueueFailureDelivery: Sendable {
    var schedule: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { callback in
        Task { @MainActor in callback() }
    }
}

/// FIFO queue with a retained request identity and an explicit, photo-scoped recovery boundary.
nonisolated final class CaptionDraftPersistenceQueue: @unchecked Sendable {
    private struct Item: @unchecked Sendable {
        let id: UUID
        let persistence: CaptionDraftPersistence?
        let operation: @Sendable () throws -> MetadataSidecar?
        let onSuccess: @MainActor @Sendable (UUID, MetadataSidecar) -> Void
        let onFailure: @MainActor @Sendable (String) -> Void
        let photoURL: URL?
    }
    private let queue: DispatchQueue
    private let failureDelivery: CaptionQueueFailureDelivery
    private var items: [Item] = []
    private var failure: (any Error)?
    private var failureID: UUID?
    private var generation: UInt64 = 0
    private var photoGenerations: [URL: UInt64] = [:]
    private var review: CaptionConflictSnapshot?
    private let publicationLock = NSLock()
    private var publishedFailure: CaptionQueueFailure?
    private var admittedPendingCount = 0
    private var stateHandler: (@MainActor @Sendable (CaptionQueueFailure?) -> Void)?

    init(label: String = "com.aagedal.photo-agent.caption-persistence",
         failureDelivery: CaptionQueueFailureDelivery = .init()) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.failureDelivery = failureDelivery
    }

    func observeFailure(_ handler: @escaping @MainActor @Sendable (CaptionQueueFailure?) -> Void) {
        publicationLock.withLock { stateHandler = handler }
        queue.async { [self] in publish() }
    }

    @discardableResult
    func enqueue(_ persistence: CaptionDraftPersistence,
                 onFailure: @escaping @MainActor @Sendable (String) -> Void,
                 onSuccess: @escaping @MainActor @Sendable (UUID, MetadataSidecar) -> Void = { _, _ in }) -> UUID {
        enqueueItem(persistence: persistence, operation: { try persistence.persist() },
            onFailure: onFailure, onSuccess: onSuccess)
    }

    /// Retained-request operation injection exercises recovery without relying on filesystem faults.
    @discardableResult
    func enqueue(persistence: CaptionDraftPersistence? = nil,
                 operation: @escaping @Sendable () throws -> Void,
                 onFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in }) -> UUID {
        enqueueItem(persistence: persistence, operation: { try operation(); return nil },
            onFailure: onFailure, onSuccess: { _, _ in })
    }

    private func enqueueItem(persistence: CaptionDraftPersistence?,
                 operation: @escaping @Sendable () throws -> MetadataSidecar?,
                 onFailure: @escaping @MainActor @Sendable (String) -> Void,
                 onSuccess: @escaping @MainActor @Sendable (UUID, MetadataSidecar) -> Void) -> UUID {
        let item = Item(id: UUID(), persistence: persistence, operation: operation, onSuccess: onSuccess, onFailure: onFailure,
            photoURL: persistence.map { $0.imageURL.standardizedFileURL.resolvingSymlinksInPath() })
        publicationLock.withLock { admittedPendingCount += 1 }
        queue.async { [self] in
            // Normal admission is frozen before editor capture by the coordinator. A previously
            // captured request arriving late must still be retained; it invalidates the export set.
            items.append(item)
            generation &+= 1
            if let photo = item.photoURL { photoGenerations[photo, default: 0] &+= 1 }
            process(retryingFailure: false)
            publish()
        }
        return item.id
    }

    func drain() throws {
        let result: Result<Void, any Error> = queue.sync { [self] in
            guard review == nil else { return .failure(CaptionConflictRecoveryError.reviewInProgress) }
            process(retryingFailure: true)
            return failure.map(Result.failure) ?? .success(())
        }
        try result.get()
    }

    func drainAsync() async throws {
        try await perform { [self] in
            guard review == nil else { throw CaptionConflictRecoveryError.reviewInProgress }
            process(retryingFailure: true)
            if let failure { throw failure }
        }
    }

    var pendingCount: Int { queue.sync { items.count } }
    /// Includes work admitted before its queue block starts and the in-flight head, without waiting for I/O.
    var hasPendingWork: Bool { publicationLock.withLock { admittedPendingCount > 0 } }
    var currentFailure: CaptionQueueFailure? { publicationLock.withLock { publishedFailure } }

    func beginReview(_ expected: CaptionQueueFailure) async throws -> CaptionConflictSnapshot {
        try await perform { [self] in
            guard review == nil, failureID == expected.id,
                  let current = failureRecord(), current.kind == .replayConflict,
                  let photo = current.photoURL else { throw CaptionConflictRecoveryError.obsoleteReview }
            let affected = items.filter { $0.photoURL == photo }
            guard affected.allSatisfy({ $0.persistence != nil }) else { throw CaptionConflictRecoveryError.obsoleteReview }
            let id = UUID()
            let revision = photoGenerations[photo, default: 0]
            let document = CaptionRecoveryDocument(reviewID: id, photoURL: photo,
                queueGeneration: revision, conflictReason: current.message,
                requests: affected.map { CaptionRecoveryRequest(id: $0.id, persistence: $0.persistence!) })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let snapshot = CaptionConflictSnapshot(id: id, photoURL: photo, failure: current,
                requestIDs: affected.map(\.id), queueGeneration: revision, exportData: try encoder.encode(document))
            review = snapshot
            return snapshot
        }
    }

    func endReview(_ snapshot: CaptionConflictSnapshot) async {
        _ = try? await perform { [self] in
            if review?.id == snapshot.id { review = nil }
        }
    }

    func exportConflict(_ snapshot: CaptionConflictSnapshot, to url: URL,
                        access: CaptionConflictExportAccess = .init()) async throws -> CaptionConflictExportReceipt {
        try await perform { [self] in
            try validate(snapshot)
            try validateExportDestination(url)
            try access.writeAtomic(snapshot.exportData, url)
            let installed = try access.read(url)
            guard installed == snapshot.exportData else { throw CaptionConflictRecoveryError.exportVerificationFailed }
            return CaptionConflictExportReceipt(exportURL: url, sha256: Self.hash(installed),
                requestIDs: snapshot.requestIDs, queueGeneration: snapshot.queueGeneration, reviewID: snapshot.id)
        }
    }

    func discardExported(_ snapshot: CaptionConflictSnapshot,
                         receipt: CaptionConflictExportReceipt) async throws -> CaptionConflictDiscardResult {
        try await perform { [self] in
            try validate(snapshot)
            guard receipt.reviewID == snapshot.id, receipt.requestIDs == snapshot.requestIDs,
                  receipt.queueGeneration == snapshot.queueGeneration else { throw CaptionConflictRecoveryError.obsoleteReview }
            try validateExportDestination(receipt.exportURL)
            let exported = try Data(contentsOf: receipt.exportURL)
            guard Self.hash(exported) == receipt.sha256, exported == snapshot.exportData else {
                throw CaptionConflictRecoveryError.exportVerificationFailed
            }
            let ids = Set(snapshot.requestIDs)
            items.removeAll { ids.contains($0.id) }
            publicationLock.withLock { admittedPendingCount -= ids.count }
            generation &+= 1
            photoGenerations[snapshot.photoURL, default: 0] &+= 1
            failure = nil
            failureID = nil
            review = nil
            publish()
            process(retryingFailure: false)
            return CaptionConflictDiscardResult(discardedCount: ids.count, remainingFailure: failureRecord())
        }
    }

    private func validate(_ snapshot: CaptionConflictSnapshot) throws {
        guard review?.id == snapshot.id, failureID == snapshot.failure.id,
              photoGenerations[snapshot.photoURL, default: 0] == snapshot.queueGeneration,
              items.filter({ $0.photoURL == snapshot.photoURL }).map(\.id) == snapshot.requestIDs else {
            throw CaptionConflictRecoveryError.obsoleteReview
        }
    }

    private func validateExportDestination(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "json" else { throw CaptionConflictRecoveryError.unsafeExport }
        // Walk the spelling the caller selected. On macOS, standardizedFileURL can rewrite
        // a physical /private/var path to the logical /var symlink before this safety check.
        // Raw traversal both accepts physical paths and still observes actual linked components.
        var cursor = url
        while cursor.path != "/" {
            if cursor.lastPathComponent.lowercased() == MetadataSidecarService.sidecarDirectoryName { throw CaptionConflictRecoveryError.unsafeExport }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw CaptionConflictRecoveryError.unsafeExport }
            cursor.deleteLastPathComponent()
        }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !canonical.pathComponents.contains(where: {
            $0.lowercased() == MetadataSidecarService.sidecarDirectoryName
        }) else { throw CaptionConflictRecoveryError.unsafeExport }
        for item in items {
            guard let persistence = item.persistence else { continue }
            let image = persistence.imageURL.standardizedFileURL.resolvingSymlinksInPath()
            let xmp = XMPSidecarService().sidecarURL(for: persistence.imageURL).standardizedFileURL.resolvingSymlinksInPath()
            guard canonical != image, canonical != item.photoURL, canonical != xmp else { throw CaptionConflictRecoveryError.unsafeExport }
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw CaptionConflictRecoveryError.unsafeExport }
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func failureRecord() -> CaptionQueueFailure? {
        guard let failure, let first = items.first, failureID == first.id else { return nil }
        let kind: CaptionQueueFailure.Kind
        if let typed = failure as? CaptionWorkspaceFlushError, case .replayConflict = typed { kind = .replayConflict }
        else { kind = .transient }
        return .init(id: first.id, photoURL: first.photoURL, message: failure.localizedDescription,
            kind: kind, generation: generation,
            affectedRequestCount: first.photoURL.map { photo in items.filter { $0.photoURL == photo }.count } ?? 1)
    }

    private func publish() {
        let state = failureRecord()
        let handler = publicationLock.withLock { publishedFailure = state; return stateHandler }
        failureDelivery.schedule { @MainActor [weak self] in
            guard let self, self.currentFailure == state else { return }
            handler?(state)
        }
    }

    private func process(retryingFailure: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard review == nil else { return }
        if retryingFailure { failure = nil; failureID = nil }
        else if failure != nil { return }
        while let item = items.first {
            do {
                let installed = try item.operation()
                items.removeFirst()
                publicationLock.withLock { admittedPendingCount -= 1 }
                generation &+= 1
                if let photo = item.photoURL { photoGenerations[photo, default: 0] &+= 1 }
                if let installed {
                    // The callback carries the exact verified transaction receipt. A newer write
                    // may already exist when delivered; callers must gate UI publication by ID.
                    failureDelivery.schedule { @MainActor in item.onSuccess(item.id, installed) }
                }
            } catch {
                failure = error
                failureID = item.id
                generation &+= 1
                publish()
                let state = failureRecord()
                failureDelivery.schedule { @MainActor [weak self] in
                    guard self?.currentFailure == state else { return }
                    item.onFailure(error.localizedDescription)
                }
                return
            }
        }
        failure = nil
        failureID = nil
        publish()
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
@Observable
final class CaptionWorkspaceFlushCoordinator {
    static let shared = CaptionWorkspaceFlushCoordinator()

    private(set) var failure: CaptionQueueFailure?
    private(set) var activeConflictReview: CaptionConflictSnapshot?
    private var pendingReviewPhoto: URL?
    @ObservationIgnored private var currentImageURLHandler: (() -> URL?)?
    private var owner: UUID?
    private var handler: (() throws -> Void)?
    private var compositionStateHandler: (() -> CodeReplacementCompositionState)?
    private var persistenceCaptureHandler: (() throws -> CaptionDraftPersistence?)?
    private var persistenceFailureHandler: (@MainActor @Sendable (String) -> Void)?
    private let persistenceQueue: CaptionDraftPersistenceQueue

    var hasRegisteredHandler: Bool { handler != nil }
    var hasPendingPersistence: Bool { persistenceQueue.hasPendingWork }
    var currentQueueFailure: CaptionQueueFailure? { persistenceQueue.currentFailure }

    init(persistenceQueue: CaptionDraftPersistenceQueue = CaptionDraftPersistenceQueue()) {
        self.persistenceQueue = persistenceQueue
        persistenceQueue.observeFailure { [weak self] in self?.failure = $0 }
    }

    func isReviewing(_ imageURL: URL) -> Bool {
        let photo = imageURL.standardizedFileURL.resolvingSymlinksInPath()
        return pendingReviewPhoto == photo || activeConflictReview?.photoURL == photo
    }

    func beginConflictReview(_ failure: CaptionQueueFailure) async throws -> CaptionConflictSnapshot {
        pendingReviewPhoto = failure.photoURL
        defer { pendingReviewPhoto = nil }
        let snapshot = try await persistenceQueue.beginReview(failure)
        activeConflictReview = snapshot
        return snapshot
    }

    func endConflictReview(_ snapshot: CaptionConflictSnapshot) async {
        await persistenceQueue.endReview(snapshot)
        if activeConflictReview?.id == snapshot.id { activeConflictReview = nil }
    }

    func exportConflict(_ snapshot: CaptionConflictSnapshot, to url: URL) async throws -> CaptionConflictExportReceipt {
        try await persistenceQueue.exportConflict(snapshot, to: url)
    }

    func discardExportedConflict(_ snapshot: CaptionConflictSnapshot,
                                 receipt: CaptionConflictExportReceipt) async throws -> CaptionConflictDiscardResult {
        let result = try await persistenceQueue.discardExported(snapshot, receipt: receipt)
        if activeConflictReview?.id == snapshot.id { activeConflictReview = nil }
        failure = result.remainingFailure
        return result
    }

    func retryQueuedPersistence() async throws {
        try await persistenceQueue.drainAsync()
        failure = persistenceQueue.currentFailure
    }

    /// Admit an already captured Review/editor request into the shared durable FIFO. Admission
    /// occurs before optimistic editor state advances; the exact photo is frozen during recovery.
    @discardableResult
    func enqueueCapturedDraft(_ persistence: CaptionDraftPersistence,
        onFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onSuccess: @escaping @MainActor @Sendable (UUID, MetadataSidecar) -> Void = { _, _ in }
    ) throws -> UUID {
        guard !isReviewing(persistence.imageURL) else { throw CaptionConflictRecoveryError.reviewInProgress }
        return persistenceQueue.enqueue(persistence, onFailure: onFailure, onSuccess: onSuccess)
    }

    /// Drain already captured work when no editor handler is mounted (for example, after leaving Review).
    func flushQueuedPersistence() throws {
        try persistenceQueue.drain()
    }

    func register(
        owner: UUID,
        currentImageURL: @escaping () -> URL? = { nil },
        compositionState: @escaping () -> CodeReplacementCompositionState = { .committed },
        capturePersistence: @escaping () throws -> CaptionDraftPersistence? = { nil },
        persistenceFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        handler: @escaping () throws -> Void
    ) {
        self.owner = owner
        self.currentImageURLHandler = currentImageURL
        self.compositionStateHandler = compositionState
        self.persistenceCaptureHandler = capturePersistence
        self.persistenceFailureHandler = persistenceFailure
        self.handler = handler
    }

    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        currentImageURLHandler = nil
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
        if let current = currentImageURLHandler?(), isReviewing(current) {
            throw CaptionConflictRecoveryError.reviewInProgress
        }
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
    case replayConflict(String)

    var errorDescription: String? {
        switch self {
        case .handlerUnavailable:
            return "The caption editor is not ready to commit changes."
        case .sidecarUnavailable:
            return "The current folder is unavailable, so caption changes could not be saved."
        case let .persistenceFailed(message), let .replayConflict(message):
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


/// Capture only complete editorial snapshots; technical fields retain their existing carriers.
nonisolated enum MetadataReviewDraftCapture {
    @MetadataSidecarFilesystemActor
    static func loadBaseline(for imageURL: URL, in folderURL: URL) async throws -> MetadataSidecar? {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            try MetadataSidecarService().loadOwnedSidecarForMutation(for: imageURL, in: folderURL)
        }
    }

    static func capture(previous: IPTCMetadata, edited: IPTCMetadata, baselineSidecar: MetadataSidecar?,
                        imageURL: URL, folderURL: URL, timestamp: Date = Date(),
                        creationEvidence: MetadataSidecarReplayCreationEvidence? = nil) throws -> CaptionDraftPersistence? {
        if let baselineSidecar {
            guard baselineSidecar.sourceFile == imageURL.lastPathComponent,
                  try editorialBytes(baselineSidecar.metadata) == editorialBytes(previous) else {
                throw CaptionWorkspaceFlushError.persistenceFailed(
                    "The Metadata Review baseline changed. The visible edit was retained; reload the saved metadata before capturing it again.")
            }
        }
        guard try editorialBytes(previous) != editorialBytes(edited) else { return nil }
        if baselineSidecar == nil, creationEvidence == nil {
            throw CaptionWorkspaceFlushError.persistenceFailed("The first Metadata Review draft requires a verified photo and XMP baseline.")
        }
        let changes = MetadataHistoryEntry.changes(from: previous, to: edited, timestamp: timestamp)
        guard !changes.isEmpty else {
            throw CaptionWorkspaceFlushError.persistenceFailed("This Metadata Review change cannot be represented as an editorial draft.")
        }
        let baselineHistory = baselineSidecar?.history ?? []
        var history = baselineHistory + changes
        history.trimToHistoryLimit()
        let sidecar = MetadataSidecar(sourceFile: imageURL.lastPathComponent, lastModified: timestamp,
            pendingChanges: true, metadata: edited,
            imageMetadataSnapshot: baselineSidecar == nil ? previous : baselineSidecar?.imageMetadataSnapshot,
            history: history, orientationDraft: baselineSidecar?.orientationDraft)
        return CaptionDraftPersistence(request: .init(sidecar: sidecar,
            baselineMetadata: previous, baselineHistory: baselineHistory,
            baselineRecordExisted: baselineSidecar != nil, changes: changes,
            imageURL: imageURL, folderURL: folderURL, creationEvidence: creationEvidence))
    }

    private static func editorialBytes(_ metadata: IPTCMetadata) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }
}
