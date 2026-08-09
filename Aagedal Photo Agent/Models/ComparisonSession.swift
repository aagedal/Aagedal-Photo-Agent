import CoreGraphics
import Foundation

/// One side of a two-image comparison, bound to the exact source bytes it represents.
nonisolated struct ComparisonSource: Identifiable, Hashable, Sendable {
    enum Representation: Hashable, Sendable {
        case original
        case committedEdit
        case liveEdit(renderToken: String)
        case namedVersion(id: UUID, name: String)

        var label: String {
            switch self {
            case .original:
                "Original"
            case .committedEdit:
                "Committed Edit"
            case .liveEdit:
                "Live Edit"
            case let .namedVersion(_, name):
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Named Version"
                    : name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    enum Availability: Hashable, Sendable {
        case available
        /// The source remains in the session so the surviving pane does not disappear.
        case missing
    }

    let id: UUID
    let revision: SourceImageRevision
    var representation: Representation
    var availability: Availability

    init(
        id: UUID = UUID(),
        revision: SourceImageRevision,
        representation: Representation,
        availability: Availability = .available
    ) {
        self.id = id
        self.revision = revision
        self.representation = representation
        self.availability = availability
    }
}

nonisolated enum ComparisonPane: String, CaseIterable, Hashable, Sendable {
    case left
    case right

    var other: ComparisonPane {
        self == .left ? .right : .left
    }
}

nonisolated enum ComparisonLayout: String, CaseIterable, Hashable, Sendable {
    case sideBySide
    case stacked
    case single
}

nonisolated enum ComparisonOriginWorkspace: String, Hashable, Sendable {
    case browser
    case develop
    case fullScreen
}

nonisolated enum ComparisonLockState: Hashable, Sendable {
    case locked
    case temporarilyUnlocked
    case aligning(anchor: ComparisonPane)
    case lockedWithOffset
}

/// The saved relationship between panes. Unlocking never discards this alignment.
nonisolated struct ComparisonAlignment: Hashable, Sendable {
    static let identity = ComparisonAlignment()

    /// Right-pane center minus left-pane center in normalized displayed-image coordinates.
    var normalizedCenterOffset: CGSize
    /// Right image-pixels-per-backing-pixel divided by the left value.
    var scaleRatio: CGFloat

    init(normalizedCenterOffset: CGSize = .zero, scaleRatio: CGFloat = 1) {
        self.normalizedCenterOffset = normalizedCenterOffset
        self.scaleRatio = scaleRatio
    }

    var isIdentity: Bool {
        abs(normalizedCenterOffset.width) < 0.000_000_1
            && abs(normalizedCenterOffset.height) < 0.000_000_1
            && abs(scaleRatio - 1) < 0.000_000_1
    }
}

/// Transient comparison state shared by Browser, Develop, full-screen, and Clean Feed.
nonisolated struct ComparisonSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let origin: ComparisonOriginWorkspace
    var leftSource: ComparisonSource
    var rightSource: ComparisonSource
    var layout: ComparisonLayout
    var focusedPane: ComparisonPane
    var lockState: ComparisonLockState
    var alignment: ComparisonAlignment
    var leftViewport: ViewportState
    var rightViewport: ViewportState

    init(
        id: UUID = UUID(),
        origin: ComparisonOriginWorkspace,
        leftSource: ComparisonSource,
        rightSource: ComparisonSource,
        layout: ComparisonLayout = .sideBySide,
        focusedPane: ComparisonPane = .left,
        lockState: ComparisonLockState = .locked,
        alignment: ComparisonAlignment = .identity,
        leftViewport: ViewportState = ViewportState(),
        rightViewport: ViewportState = ViewportState()
    ) {
        self.id = id
        self.origin = origin
        self.leftSource = leftSource
        self.rightSource = rightSource
        self.layout = layout
        self.focusedPane = focusedPane
        self.lockState = lockState
        self.alignment = alignment
        self.leftViewport = leftViewport
        self.rightViewport = rightViewport
    }

    func source(for pane: ComparisonPane) -> ComparisonSource {
        pane == .left ? leftSource : rightSource
    }

    mutating func replaceSource(_ source: ComparisonSource, in pane: ComparisonPane) {
        if pane == .left {
            leftSource = source
        } else {
            rightSource = source
        }
    }

    mutating func markSourceMissing(in pane: ComparisonPane) {
        if pane == .left {
            leftSource.availability = .missing
        } else {
            rightSource.availability = .missing
        }
    }

    func viewport(for pane: ComparisonPane) -> ViewportState {
        pane == .left ? leftViewport : rightViewport
    }

    mutating func setViewport(_ viewport: ViewportState, for pane: ComparisonPane) {
        if pane == .left {
            leftViewport = viewport
        } else {
            rightViewport = viewport
        }
    }
}

/// Geometry needed to clamp one pane without leaking any view type into the coordinator.
nonisolated struct ComparisonViewportSurface: Hashable, Sendable {
    let displayedPixelSize: CGSize
    let viewSize: CGSize
    let backingScale: CGFloat
}

nonisolated struct ComparisonViewportSurfaces: Hashable, Sendable {
    let left: ComparisonViewportSurface
    let right: ComparisonViewportSurface

    func surface(for pane: ComparisonPane) -> ComparisonViewportSurface {
        pane == .left ? left : right
    }
}

/// An atomic, one-way viewport update. Views must pass `id` back as `causedBy` when applying it.
nonisolated struct ComparisonViewportTransaction: Hashable, Sendable {
    let id: UInt64
    let initiatingPane: ComparisonPane
    let changedPanes: Set<ComparisonPane>
    let clampedPanes: Set<ComparisonPane>
    let leftViewport: ViewportState
    let rightViewport: ViewportState

    var exactLockWasPossible: Bool { clampedPanes.isEmpty }
}

/// Applies synchronized viewport changes without allowing programmatic echoes to loop.
nonisolated struct ComparisonCoordinator: Sendable {
    private static let maximumPendingEchoesPerPane = 32

    private var nextTransactionID: UInt64 = 0
    private var expectedEchoes: [ComparisonPane: [UInt64]] = [:]

    mutating func updateViewport(
        _ requestedViewport: ViewportState,
        in pane: ComparisonPane,
        session: inout ComparisonSession,
        surfaces: ComparisonViewportSurfaces,
        causedBy transactionID: UInt64? = nil
    ) throws -> ComparisonViewportTransaction? {
        if let transactionID, consumeExpectedEcho(transactionID, in: pane) {
            return nil
        }

        var changedPanes: Set<ComparisonPane> = [pane]
        var clampedPanes: Set<ComparisonPane> = []
        let sourceSurface = surfaces.surface(for: pane)
        let sourceViewport = try clamped(
            requestedViewport,
            for: sourceSurface,
            pane: pane,
            clampedPanes: &clampedPanes
        )
        session.setViewport(sourceViewport, for: pane)

        switch session.lockState {
        case .locked, .lockedWithOffset:
            let targetPane = pane.other
            let targetSurface = surfaces.surface(for: targetPane)
            let synchronized = try synchronizedViewport(
                from: sourceViewport,
                sourcePane: pane,
                alignment: session.alignment,
                sourceSurface: sourceSurface
            )
            let targetViewport = try clamped(
                synchronized,
                for: targetSurface,
                pane: targetPane,
                clampedPanes: &clampedPanes
            )
            session.setViewport(targetViewport, for: targetPane)
            changedPanes.insert(targetPane)
        case .temporarilyUnlocked, .aligning:
            break
        }

        nextTransactionID &+= 1
        if nextTransactionID == 0 { nextTransactionID = 1 }
        for changedPane in changedPanes {
            recordExpectedEcho(nextTransactionID, in: changedPane)
        }

        return ComparisonViewportTransaction(
            id: nextTransactionID,
            initiatingPane: pane,
            changedPanes: changedPanes,
            clampedPanes: clampedPanes,
            leftViewport: session.leftViewport,
            rightViewport: session.rightViewport
        )
    }

    mutating func temporarilyUnlock(session: inout ComparisonSession) {
        guard session.lockState == .locked || session.lockState == .lockedWithOffset else { return }
        session.lockState = .temporarilyUnlocked
    }

    mutating func relock(session: inout ComparisonSession) {
        guard session.lockState == .temporarilyUnlocked else { return }
        session.lockState = session.alignment.isIdentity ? .locked : .lockedWithOffset
    }

    mutating func beginAlignment(anchor: ComparisonPane, session: inout ComparisonSession) {
        session.lockState = .aligning(anchor: anchor)
    }

    mutating func saveAlignment(
        session: inout ComparisonSession,
        surfaces: ComparisonViewportSurfaces
    ) throws {
        guard case .aligning = session.lockState else { return }

        let leftScale = try resolvedScale(
            session.leftViewport,
            surface: surfaces.left
        )
        let rightScale = try resolvedScale(
            session.rightViewport,
            surface: surfaces.right
        )
        session.alignment = ComparisonAlignment(
            normalizedCenterOffset: CGSize(
                width: session.rightViewport.normalizedCenter.x - session.leftViewport.normalizedCenter.x,
                height: session.rightViewport.normalizedCenter.y - session.leftViewport.normalizedCenter.y
            ),
            scaleRatio: rightScale / leftScale
        )
        session.lockState = session.alignment.isIdentity ? .locked : .lockedWithOffset
    }

    mutating func resetAlignment(
        anchoredAt pane: ComparisonPane,
        session: inout ComparisonSession,
        surfaces: ComparisonViewportSurfaces
    ) throws -> ComparisonViewportTransaction? {
        session.alignment = .identity
        session.lockState = .locked
        return try updateViewport(
            session.viewport(for: pane),
            in: pane,
            session: &session,
            surfaces: surfaces
        )
    }

    private func synchronizedViewport(
        from source: ViewportState,
        sourcePane: ComparisonPane,
        alignment: ComparisonAlignment,
        sourceSurface: ComparisonViewportSurface
    ) throws -> ViewportState {
        let direction: CGFloat = sourcePane == .left ? 1 : -1
        let targetCenter = CGPoint(
            x: source.normalizedCenter.x + direction * alignment.normalizedCenterOffset.width,
            y: source.normalizedCenter.y + direction * alignment.normalizedCenterOffset.height
        )

        let targetMode: ViewportState.Mode
        if case .fit = source.mode {
            targetMode = .fit
        } else {
            let sourceScale = try resolvedScale(source, surface: sourceSurface)
            let targetScale = sourcePane == .left
                ? sourceScale * alignment.scaleRatio
                : sourceScale / alignment.scaleRatio
            targetMode = abs(targetScale - 1) < 0.000_000_1
                ? .actualPixels
                : .custom(imagePixelsPerBackingPixel: targetScale)
        }

        return ViewportState(
            mode: targetMode,
            normalizedCenter: targetCenter,
            interpolation: source.interpolation
        )
    }

    private func resolvedScale(
        _ viewport: ViewportState,
        surface: ComparisonViewportSurface
    ) throws -> CGFloat {
        try viewport.geometry(
            displayedPixelSize: surface.displayedPixelSize,
            viewSize: surface.viewSize,
            backingScale: surface.backingScale
        ).imagePixelsPerBackingPixel
    }

    private func clamped(
        _ viewport: ViewportState,
        for surface: ComparisonViewportSurface,
        pane: ComparisonPane,
        clampedPanes: inout Set<ComparisonPane>
    ) throws -> ViewportState {
        let result = try viewport.clamped(
            displayedPixelSize: surface.displayedPixelSize,
            viewSize: surface.viewSize,
            backingScale: surface.backingScale
        )
        if result.normalizedCenter != viewport.normalizedCenter {
            clampedPanes.insert(pane)
        }
        return result
    }

    private mutating func consumeExpectedEcho(
        _ transactionID: UInt64,
        in pane: ComparisonPane
    ) -> Bool {
        guard var pending = expectedEchoes[pane],
              let index = pending.firstIndex(of: transactionID) else {
            return false
        }
        pending.remove(at: index)
        expectedEchoes[pane] = pending.isEmpty ? nil : pending
        return true
    }

    private mutating func recordExpectedEcho(
        _ transactionID: UInt64,
        in pane: ComparisonPane
    ) {
        var pending = expectedEchoes[pane, default: []]
        pending.append(transactionID)
        if pending.count > Self.maximumPendingEchoesPerPane {
            pending.removeFirst(pending.count - Self.maximumPendingEchoesPerPane)
        }
        expectedEchoes[pane] = pending
    }
}

/// Browser entry preserves visible ordering even though selection itself is stored as a set.
nonisolated enum ComparisonSelectionResolver {
    static func images(
        in visibleImages: [ImageFile],
        selectedURLs: Set<URL>
    ) -> (left: ImageFile, right: ImageFile)? {
        guard selectedURLs.count == 2 else { return nil }
        let selected = visibleImages.filter {
            selectedURLs.contains($0.url) && SupportedImageFormats.isSupported(url: $0.url)
        }
        guard selected.count == 2 else { return nil }
        return (selected[0], selected[1])
    }
}
