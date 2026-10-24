import AppKit
import Foundation
import Observation
import SwiftMediaMetadata

/// Describes whether a Develop settings transition remains transient or must cross one of the
/// workspace's existing durable persistence boundaries.
nonisolated enum DevelopPersistenceIntent: Equatable, Sendable {
    case unchanged
    case previewOnly
    case commitPrimary
    case commitNamedVersion
}

/// The observable result of the most recently requested batch settings write.
///
/// Request identity is part of the value so callers and tests can distinguish an explicit
/// cancellation from a failure without coupling themselves to the coordinator's task storage.
nonisolated enum DevelopBatchPersistenceOutcome: Equatable, Sendable {
    case succeeded(requestID: UUID)
    case cancelled(requestID: UUID)
    case failed(requestID: UUID, message: String)
}

/// The completion reported by the injected Primary metadata/history writer.
///
/// The durable writer remains responsible for distinguishing a complete transaction from a
/// partial/cancelled one. Keeping that distinction in the completion lets this coordinator own
/// presentation without inspecting mutable `MetadataViewModel` state after a newer save begins.
nonisolated enum DevelopPrimaryPersistenceCompletion: Equatable, Sendable {
    case succeeded
    case cancelled(message: String?)
    case failed(message: String)
}

/// Decides when a completed metadata load ends the Develop undo history.
///
/// History belongs to one photo *and* to the settings Develop itself produced. It ends when
/// another photo loads, or when the app explicitly replaced the settings from outside (Reset
/// All Edits; a multi-photo paste reload clears it directly) — Undo would otherwise bring
/// discarded edits back and write them. Ordinary same-photo reloads (Paste IPTC, face scans,
/// automation drafts, self-initiated saves) keep it. As a fallback for replacements the app
/// isn't told about (an external sidecar edit), a same-photo reload whose develop settings
/// differ from what Develop published *after the real XMP write/read round trip* also ends it.
/// Comparing against the actual round trip (not a rounded guess) makes the check immune to
/// encoder precision (brush dabs, crop, curve grid) and to mask reordering.
nonisolated enum DevelopUndoHistoryPolicy {
    static func shouldClearHistory(
        historyImageURL: URL?,
        loadedImageURL: URL?,
        settingsDevelopPublished: CameraRawSettings?,
        loadedSettings: CameraRawSettings?,
        settingsReplacedExternally: Bool = false
    ) -> Bool {
        guard historyImageURL == loadedImageURL, !settingsReplacedExternally else { return true }
        return reloadComparable(roundTripped(settingsDevelopPublished)) != reloadComparable(loadedSettings)
    }

    /// `settings` as this app reads them back after writing them to XMP: the same encoder
    /// (`XMPDataBuilder.applyCameraRaw`) and parser (`XMPMetadataReader.parseMetadata`) a save
    /// and the following reload use.
    static func roundTripped(_ settings: CameraRawSettings?) -> CameraRawSettings? {
        guard let settings, !settings.isEmpty else { return nil }
        var xmp = XMPData()
        XMPDataBuilder.applyCameraRaw(settings, imageAspect: nil, into: &xmp)
        return XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil }).cameraRaw
    }

    /// A round-tripped (or reloaded) record with the incidental differences removed: decode
    /// facts and version markers, layer identities (as render-order positions — the writer
    /// stores masks in render order), and angled-crop aspect conversions below 1e-4.
    static func reloadComparable(_ settings: CameraRawSettings?) -> CameraRawSettings? {
        guard var settings else { return nil }
        settings.asShotNeutralTemperature = nil
        settings.asShotNeutralTint = nil
        settings.sourceHasHDRHeadroom = nil
        settings.hasSettings = nil
        settings.version = nil
        settings.processVersion = nil
        if var crop = settings.crop {
            func rounded(_ value: Double?) -> Double? { value.map { ($0 * 10_000).rounded() / 10_000 } }
            crop.top = rounded(crop.top)
            crop.left = rounded(crop.left)
            crop.bottom = rounded(crop.bottom)
            crop.right = rounded(crop.right)
            crop.angle = rounded(crop.angle)
            settings.crop = crop.isEmpty ? nil : crop
        }
        let masks = settings.masksInRenderOrder() ?? []
        let watermarks = settings.watermarkLayers ?? []
        var positions: [UUID: UUID] = [:]
        for (index, mask) in masks.enumerated() {
            positions[mask.id] = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))
        }
        for (index, layer) in watermarks.enumerated() {
            positions[layer.id] = UUID(uuidString: String(format: "00000000-0000-0000-0001-%012x", index + 1))
        }
        let order = settings.resolvedLayerOrder().map { ref -> LayerRef in
            switch ref {
            case .global: return .global
            case .mask(let id): return .mask(positions[id] ?? id)
            case .watermark(let id): return .watermark(positions[id] ?? id)
            }
        }
        settings.localAdjustments = masks.isEmpty ? nil : masks.map { mask in
            var copy = mask
            copy.id = positions[mask.id] ?? mask.id
            return copy
        }
        settings.watermarkLayers = watermarks.isEmpty ? nil : watermarks.map { layer in
            var copy = layer
            copy.id = positions[layer.id] ?? layer.id
            return copy
        }
        settings.layerOrder = order
        return settings.isEmpty ? nil : settings
    }
}

/// The observable result of the latest Primary metadata/history request in an image session.
nonisolated enum DevelopPrimaryPersistenceOutcome: Equatable, Sendable {
    case succeeded(requestID: UUID)
    case cancelled(requestID: UUID, message: String?)
    case failed(requestID: UUID, message: String)
}

/// Owns the Develop workspace's undo lifetime and the set of image previews invalidated by edits.
///
/// The coordinator deliberately does not write XMP or named-version JSON. Those operations remain
/// injected at `EditWorkspaceView`, where the metadata and version services already reconcile
/// durable state. Undo restorations carry an image-session identity so a stale callback retained
/// by AppKit cannot publish settings into a replacement image.
@MainActor
@Observable
final class DevelopPersistenceSessionCoordinator {
    typealias SettingsPublisher = @MainActor (CameraRawSettings?, Bool) -> Void
    typealias PersistenceAction = @MainActor () -> Void
    typealias PrimaryPersistenceCompletion = @MainActor (DevelopPrimaryPersistenceCompletion) -> Void
    typealias PrimaryPersistenceOperation = @MainActor (@escaping PrimaryPersistenceCompletion) -> Void
    typealias BatchPersistenceOperation = @MainActor () async throws -> Void

    private(set) var isWorkspaceActive = false
    private(set) var activeImageURL: URL?
    private(set) var editedURLs: Set<URL> = []
    private(set) var pendingPrimaryPersistenceCount = 0
    private(set) var latestPrimaryPersistenceOutcome: DevelopPrimaryPersistenceOutcome?
    private(set) var pendingBatchPersistenceCount = 0
    private(set) var latestBatchPersistenceOutcome: DevelopBatchPersistenceOutcome?
    /// Bumped whenever the undo stack may have changed, so observers (the Edit menu's
    /// Undo/Redo titles) re-read the otherwise unobservable `UndoManager`.
    private(set) var historyRevision = 0

    @ObservationIgnored private(set) var undoManager = UndoManager()
    @ObservationIgnored private var imageSessionID = UUID()
    @ObservationIgnored private var workspaceSessionID = UUID()
    @ObservationIgnored private var latestPrimaryPersistenceRequestID: UUID?
    @ObservationIgnored private var primaryPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var latestBatchPersistenceRequestID: UUID?
    @ObservationIgnored private var batchPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recent mutation registered on top of the undo stack, eligible for coalescing.
    @ObservationIgnored private var lastMutation: (
        sessionID: UUID, before: CameraRawSettings?, after: CameraRawSettings?
    )?
    /// Set while a coalesced entry is popped: its restoration must neither publish nor
    /// register a redo.
    @ObservationIgnored private var isDiscardingRestoration = false

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    /// "Undo Exposure" etc. for the Edit menu; observable through `historyRevision`.
    var undoMenuTitle: String {
        _ = historyRevision
        return undoManager.undoMenuItemTitle
    }
    var redoMenuTitle: String {
        _ = historyRevision
        return undoManager.redoMenuItemTitle
    }
    var canUndoFromMenu: Bool {
        _ = historyRevision
        return isWorkspaceActive && undoManager.canUndo
    }
    var canRedoFromMenu: Bool {
        _ = historyRevision
        return isWorkspaceActive && undoManager.canRedo
    }
    var isPrimaryPersistenceInProgress: Bool { pendingPrimaryPersistenceCount > 0 }
    var primaryPersistenceErrorMessage: String? {
        guard case .failed(_, let message) = latestPrimaryPersistenceOutcome else { return nil }
        return message
    }
    var isBatchPersistenceInProgress: Bool { pendingBatchPersistenceCount > 0 }
    var batchPersistenceErrorMessage: String? {
        guard case .failed(_, let message) = latestBatchPersistenceOutcome else { return nil }
        return message
    }

    /// Starts a clean workspace lifetime. Session-local cache refresh evidence never leaks from a
    /// previous presentation of the editor.
    func beginWorkspace() {
        invalidateImageSession()
        workspaceSessionID = UUID()
        latestPrimaryPersistenceRequestID = nil
        pendingPrimaryPersistenceCount = 0
        latestPrimaryPersistenceOutcome = nil
        latestBatchPersistenceRequestID = nil
        pendingBatchPersistenceCount = 0
        latestBatchPersistenceOutcome = nil
        editedURLs.removeAll(keepingCapacity: true)
        activeImageURL = nil
        isWorkspaceActive = true
    }

    /// Replaces the image-scoped undo lifetime and invalidates every restoration registered for
    /// the previous image, even if an external AppKit owner retained a callback temporarily.
    func beginImageSession(_ imageURL: URL?) {
        // Preview refreshes (for example after paste or an orientation fallback) can restart the
        // rendering session without replacing the selected image. Preserve that image's undo
        // history exactly as the former view-owned UndoManager did.
        guard activeImageURL != imageURL else { return }
        invalidateImageSession()
        latestPrimaryPersistenceRequestID = nil
        pendingPrimaryPersistenceCount = 0
        latestPrimaryPersistenceOutcome = nil
        activeImageURL = imageURL
    }

    func endImageSession() {
        invalidateImageSession()
        activeImageURL = nil
    }

    /// Ends the workspace and consumes the exact URL set whose edited previews must be rebuilt.
    func endWorkspace() -> Set<URL> {
        let result = editedURLs
        invalidateImageSession()
        // A batch paste may already have crossed into a durable sidecar transaction. Do not
        // cancel that work when the view disappears: finishing it preserves the in-memory edit
        // the user already saw. Rotating the session identity suppresses late UI publication.
        workspaceSessionID = UUID()
        latestPrimaryPersistenceRequestID = nil
        pendingPrimaryPersistenceCount = 0
        latestPrimaryPersistenceOutcome = nil
        latestBatchPersistenceRequestID = nil
        pendingBatchPersistenceCount = 0
        latestBatchPersistenceOutcome = nil
        activeImageURL = nil
        editedURLs.removeAll(keepingCapacity: false)
        isWorkspaceActive = false
        return result
    }

    /// Starts one Primary XMP/history transaction and owns its completion publication.
    ///
    /// The operation is invoked synchronously so it snapshots the same edit that requested the
    /// save. The injected metadata owner retains the actual durable transaction, including its
    /// per-file serialization and partial-commit rules. This coordinator retains the awaiting
    /// task, request/image/workspace identities, pending state, and latest-result policy. Image or
    /// workspace replacement therefore cannot publish a late failure into a different session.
    @discardableResult
    func schedulePrimaryPersistence(
        operation: @escaping PrimaryPersistenceOperation
    ) -> UUID? {
        guard isWorkspaceActive, activeImageURL != nil else { return nil }

        let requestID = UUID()
        let workspaceID = workspaceSessionID
        let imageID = imageSessionID
        latestPrimaryPersistenceRequestID = requestID
        latestPrimaryPersistenceOutcome = nil
        pendingPrimaryPersistenceCount += 1

        var streamContinuation: AsyncStream<DevelopPrimaryPersistenceCompletion>.Continuation?
        let completions = AsyncStream<DevelopPrimaryPersistenceCompletion> { continuation in
            streamContinuation = continuation
        }
        operation { completion in
            streamContinuation?.yield(completion)
            streamContinuation?.finish()
        }

        let task = Task { @MainActor [self] in
            var iterator = completions.makeAsyncIterator()
            let completion = await iterator.next()
                ?? .cancelled(message: "The Develop save was cancelled before it completed.")
            self.finishPrimaryPersistence(
                requestID: requestID,
                workspaceID: workspaceID,
                imageID: imageID,
                completion: completion
            )
        }
        primaryPersistenceTasks[requestID] = task
        return requestID
    }

    /// Waits accepted presentation callbacks across image/workspace replacement. Durable
    /// failure retention belongs to DevelopPrimaryLifecycleCoordinator's immutable VM owner;
    /// resetting or dismissing this session's alert never acknowledges those requests.
    func waitForAcceptedPrimaryPersistence() async {
        while !primaryPersistenceTasks.isEmpty {
            for task in Array(primaryPersistenceTasks.values) { await task.value }
        }
    }

    func cancelPrimaryPersistence(requestID: UUID) {
        primaryPersistenceTasks[requestID]?.cancel()
    }

    /// Hides only this presentation. The independently retained immutable writer still blocks
    /// Close/Quit until successful retry or verified export and explicit scoped discard.
    func dismissPrimaryPersistenceResult() {
        latestPrimaryPersistenceOutcome = nil
    }

    /// Starts a batch settings write owned by this workspace coordinator.
    ///
    /// Multiple durable writes are allowed to finish because the injected metadata engine owns
    /// per-file transaction serialization. Only the latest request may publish UI state, while
    /// every request remains explicitly cancellable by identity. Workspace teardown intentionally
    /// lets already-started durable work finish and rejects its late result instead of cancelling
    /// a possibly partially committed batch.
    @discardableResult
    func scheduleBatchPersistence(
        operation: @escaping BatchPersistenceOperation
    ) -> UUID? {
        guard isWorkspaceActive else { return nil }

        let requestID = UUID()
        let sessionID = workspaceSessionID
        latestBatchPersistenceRequestID = requestID
        latestBatchPersistenceOutcome = nil
        pendingBatchPersistenceCount += 1

        let task = Task { @MainActor [weak self] in
            do {
                try await operation()
                try Task.checkCancellation()
                self?.finishBatchPersistence(
                    requestID: requestID,
                    sessionID: sessionID,
                    outcome: .succeeded(requestID: requestID)
                )
            } catch is CancellationError {
                self?.finishBatchPersistence(
                    requestID: requestID,
                    sessionID: sessionID,
                    outcome: .cancelled(requestID: requestID)
                )
            } catch {
                self?.finishBatchPersistence(
                    requestID: requestID,
                    sessionID: sessionID,
                    outcome: .failed(
                        requestID: requestID,
                        message: error.localizedDescription
                    )
                )
            }
        }
        batchPersistenceTasks[requestID] = task
        return requestID
    }

    func cancelBatchPersistence(requestID: UUID) {
        batchPersistenceTasks[requestID]?.cancel()
    }

    func dismissBatchPersistenceResult() {
        latestBatchPersistenceOutcome = nil
    }

    /// Records an already-published in-memory settings change for the active image. This is
    /// preview/cache state only; callers still choose when to request a durable commit.
    @discardableResult
    func recordPublishedSettingsChange(for imageURL: URL) -> DevelopPersistenceIntent {
        guard isWorkspaceActive, activeImageURL == imageURL else { return .unchanged }
        editedURLs.insert(imageURL)
        return .previewOnly
    }

    /// Batch paste publishes settings for images outside the active image session. It is still
    /// scoped to the current workspace lifetime and shares the same exit-time refresh inventory.
    @discardableResult
    func recordPublishedSettingsChanges(for imageURLs: some Sequence<URL>) -> DevelopPersistenceIntent {
        guard isWorkspaceActive else { return .unchanged }
        let urls = Set(imageURLs)
        guard !urls.isEmpty else { return .unchanged }
        editedURLs.formUnion(urls)
        return .previewOnly
    }

    /// Returns the durable boundary appropriate for the current edit without performing I/O.
    func persistenceIntent(
        hasChanges: Bool,
        editsNamedVersion: Bool
    ) -> DevelopPersistenceIntent {
        guard isWorkspaceActive else { return .unchanged }
        if editsNamedVersion { return .commitNamedVersion }
        return hasChanges ? .commitPrimary : .unchanged
    }

    /// Routes one persistence request to the durable boundary selected for the active image.
    ///
    /// Concrete XMP and named-version writers stay injected so this coordinator owns policy and
    /// lifecycle without taking a dependency on `MetadataViewModel` or the version store. The
    /// in-memory image snapshot is published exactly once before either durable action, matching
    /// the Develop workspace's established thumbnail/full-screen invalidation order.
    @discardableResult
    func performPersistence(
        hasChanges: Bool,
        editsNamedVersion: Bool,
        publishImageSnapshot: PersistenceAction,
        commitPrimary: PersistenceAction,
        commitNamedVersion: PersistenceAction
    ) -> DevelopPersistenceIntent {
        let intent = persistenceIntent(
            hasChanges: hasChanges,
            editsNamedVersion: editsNamedVersion
        )
        switch intent {
        case .commitPrimary:
            publishImageSnapshot()
            commitPrimary()
        case .commitNamedVersion:
            publishImageSnapshot()
            commitNamedVersion()
        case .unchanged, .previewOnly:
            break
        }
        return intent
    }

    /// Registers one value transition with an image identity. Undo and redo both restore the
    /// original dirty-state policy: Primary edits are marked changed; named versions are not.
    ///
    /// `coalescesWithPrevious` folds this transition into the immediately preceding one when it
    /// continues from that one's result (a slider double-click reset whose first click already
    /// committed a value), so a single Undo returns to the state before both.
    @discardableResult
    func recordMutation(
        before: CameraRawSettings?,
        after: CameraRawSettings?,
        editsNamedVersion: Bool,
        actionName: String? = nil,
        coalescesWithPrevious: Bool = false,
        publisher: @escaping SettingsPublisher
    ) -> DevelopPersistenceIntent {
        guard isWorkspaceActive, activeImageURL != nil, before != after else { return .unchanged }
        let sessionID = imageSessionID
        var before = before
        if coalescesWithPrevious, let previous = lastMutation,
           previous.sessionID == sessionID, previous.after == before,
           undoManager.canUndo, undoManager.groupingLevel <= 1 {
            isDiscardingRestoration = true
            undoManager.undo()
            isDiscardingRestoration = false
            before = previous.before
        }
        lastMutation = nil
        // A fold can land back on the original state; there is then nothing left to undo.
        guard before != after else { return .previewOnly }
        registerRestoration(
            target: before,
            inverse: after,
            editsNamedVersion: editsNamedVersion,
            sessionID: sessionID,
            actionName: actionName,
            publisher: publisher
        )
        lastMutation = (sessionID, before, after)
        historyRevision &+= 1
        return .previewOnly
    }

    func undo() {
        guard isWorkspaceActive else { return }
        lastMutation = nil
        undoManager.undo()
        historyRevision &+= 1
    }

    func redo() {
        guard isWorkspaceActive else { return }
        lastMutation = nil
        undoManager.redo()
        historyRevision &+= 1
    }

    func removeAllUndoActions() {
        lastMutation = nil
        undoManager.removeAllActions()
        historyRevision &+= 1
    }

    private func registerRestoration(
        target: CameraRawSettings?,
        inverse: CameraRawSettings?,
        editsNamedVersion: Bool,
        sessionID: UUID,
        actionName: String?,
        publisher: @escaping SettingsPublisher
    ) {
        undoManager.registerUndo(withTarget: self) { coordinator in
            guard !coordinator.isDiscardingRestoration,
                  coordinator.isWorkspaceActive,
                  coordinator.imageSessionID == sessionID else { return }
            publisher(target, editsNamedVersion)
            coordinator.registerRestoration(
                target: inverse,
                inverse: target,
                editsNamedVersion: editsNamedVersion,
                sessionID: sessionID,
                actionName: actionName,
                publisher: publisher
            )
        }
        if let actionName {
            undoManager.setActionName(actionName)
        }
    }

    private func invalidateImageSession() {
        imageSessionID = UUID()
        lastMutation = nil
        undoManager.removeAllActions()
        historyRevision &+= 1
    }

    private func finishBatchPersistence(
        requestID: UUID,
        sessionID: UUID,
        outcome: DevelopBatchPersistenceOutcome
    ) {
        batchPersistenceTasks[requestID] = nil
        guard isWorkspaceActive, workspaceSessionID == sessionID else { return }
        pendingBatchPersistenceCount = max(0, pendingBatchPersistenceCount - 1)
        guard latestBatchPersistenceRequestID == requestID else { return }
        latestBatchPersistenceOutcome = outcome
    }

    private func finishPrimaryPersistence(
        requestID: UUID,
        workspaceID: UUID,
        imageID: UUID,
        completion: DevelopPrimaryPersistenceCompletion
    ) {
        primaryPersistenceTasks[requestID] = nil
        guard isWorkspaceActive,
              workspaceSessionID == workspaceID,
              imageSessionID == imageID else { return }
        pendingPrimaryPersistenceCount = max(0, pendingPrimaryPersistenceCount - 1)
        guard latestPrimaryPersistenceRequestID == requestID else { return }

        switch completion {
        case .succeeded:
            latestPrimaryPersistenceOutcome = .succeeded(requestID: requestID)
        case .cancelled(let message):
            latestPrimaryPersistenceOutcome = .cancelled(requestID: requestID, message: message)
        case .failed(let message):
            latestPrimaryPersistenceOutcome = .failed(requestID: requestID, message: message)
        }
    }
}

/// Routes the Edit menu's Undo/Redo to the Develop history while the Develop workspace owns the
/// key window and no text field is editing; everywhere else the menu falls back to the standard
/// responder-chain `undo:`/`redo:` (text fields, the Metadata panel, sheets, Settings).
///
/// The keyboard shortcut path is unchanged: the Develop and Analysis key monitors consume ⌘Z
/// before the menu sees it, and pass it on untouched while a text field edits.
@MainActor
@Observable
final class DevelopUndoMenuRouter {
    static let shared = DevelopUndoMenuRouter()

    struct Registration {
        let ownerID: UUID
        let session: DevelopPersistenceSessionCoordinator
        /// The window hosting this Develop workspace (nil until it is attached).
        let window: @MainActor () -> NSWindow?
        /// True when the Develop workspace may take the menu action now (its window is key, no
        /// text field or overlay owns input).
        let canRoute: @MainActor () -> Bool
        let perform: @MainActor (_ redo: Bool) -> Void
    }

    /// One registration per Develop workspace (window); the key window's one is used.
    private var registrations: [UUID: Registration] = [:]
    /// Bumped when the key window changes or a menu starts tracking, so the Edit menu titles
    /// re-read state SwiftUI can't observe (key window, first responder).
    private(set) var focusRevision = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSMenu.didBeginTrackingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusRevision &+= 1 }
            })
        }
    }

    func register(_ registration: Registration) {
        registrations[registration.ownerID] = registration
    }

    /// Call when that workspace leaves Develop or its window closes.
    func unregister(ownerID: UUID) {
        registrations[ownerID] = nil
    }

    /// The registration of the Develop workspace in the key window, if any.
    private var keyRegistration: Registration? {
        _ = focusRevision
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return registrations.values.first { $0.session.isWorkspaceActive && $0.window() === keyWindow }
    }

    /// The Develop session the menu routes to right now (key window's Develop, with no text
    /// field editing), if any.
    var activeSession: DevelopPersistenceSessionCoordinator? {
        guard let registration = keyRegistration, registration.canRoute() else { return nil }
        return registration.session
    }

    /// "Undo Exposure" while the menu drives Develop; plain "Undo" otherwise (e.g. a focused
    /// text field, whose own undo the menu performs).
    var undoTitle: String { activeSession?.undoMenuTitle ?? "Undo" }
    var redoTitle: String { activeSession?.redoMenuTitle ?? "Redo" }

    func undo() { route(redo: false) }
    func redo() { route(redo: true) }

    private func route(redo: Bool) {
        if let registration = keyRegistration, registration.canRoute() {
            registration.perform(redo)
            return
        }
        let selector = redo ? Selector(("redo:")) : Selector(("undo:"))
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
