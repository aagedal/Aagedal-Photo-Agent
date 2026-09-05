import CoreGraphics
import Foundation

/// Geometry required to clamp and synchronize a pane's reusable `ViewportState`.
nonisolated struct ComparisonPaneGeometry: Hashable, Sendable {
    let displayedPixelSize: CGSize
    let viewSize: CGSize
    let backingScale: CGFloat

    init(displayedPixelSize: CGSize, viewSize: CGSize, backingScale: CGFloat) {
        self.displayedPixelSize = displayedPixelSize
        self.viewSize = viewSize
        self.backingScale = backingScale
    }

    func resolvedScale(for viewport: ViewportState) throws -> CGFloat {
        try viewport.geometry(
            displayedPixelSize: displayedPixelSize,
            viewSize: viewSize,
            backingScale: backingScale
        ).imagePixelsPerBackingPixel
    }

    func clamped(_ viewport: ViewportState) throws -> ViewportState {
        try viewport.clamped(
            displayedPixelSize: displayedPixelSize,
            viewSize: viewSize,
            backingScale: backingScale
        )
    }
}

/// One atomic, one-way viewport update. UI adapters can attach `id` to programmatic pane changes
/// and pass it back as `causedBy`; those callbacks are ignored instead of becoming a new driver.
nonisolated struct ComparisonViewportTransaction: Hashable, Sendable {
    let id: UInt64
    let driver: ComparisonPane
    let leftViewport: ViewportState
    let rightViewport: ViewportState
    let driverWasClamped: Bool
    let followerWasClamped: Bool

    var exactLockWasPossible: Bool {
        !driverWasClamped && !followerWasClamped
    }
}

nonisolated enum ComparisonCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case missingGeometry(ComparisonPane)
    case invalidAlignmentOffset(CGPoint)
    case invalidAlignmentScaleRatio(CGFloat)

    var errorDescription: String? {
        switch self {
        case let .missingGeometry(pane):
            "Comparison geometry is unavailable for the \(pane.rawValue) pane."
        case let .invalidAlignmentOffset(offset):
            "Comparison alignment offset must be finite (received \(offset))."
        case let .invalidAlignmentScaleRatio(ratio):
            "Comparison alignment scale ratio must be positive and finite (received \(ratio))."
        }
    }
}

/// Pure comparison coordination. All state changes happen in a single mutating call, which makes
/// the behavior testable without SwiftUI and prevents clamping in one pane from oscillating back.
nonisolated struct ComparisonCoordinator: Sendable {
    private(set) var session: ComparisonSession
    private var nextTransactionID: UInt64 = 1
    private var lastProgrammaticTransaction: [ComparisonPane: UInt64] = [:]

    init(session: ComparisonSession) throws {
        try Self.validate(session.alignment)
        self.session = session
    }

    /// Applies a direct user viewport change. Returns `nil` for a callback caused by the most
    /// recent programmatic update delivered to that pane.
    mutating func updateViewport(
        in pane: ComparisonPane,
        to requested: ViewportState,
        geometries: [ComparisonPane: ComparisonPaneGeometry],
        causedBy transactionID: UInt64? = nil
    ) throws -> ComparisonViewportTransaction? {
        if let transactionID,
           let lastTransactionID = lastProgrammaticTransaction[pane],
           transactionID <= lastTransactionID {
            return nil
        }

        guard let driverGeometry = geometries[pane] else {
            throw ComparisonCoordinatorError.missingGeometry(pane)
        }

        var updatedSession = session
        let previousDriver = updatedSession[pane].viewport
        let clampedDriver: ViewportState
        if case let .aligning(anchor) = updatedSession.lockState, anchor == pane {
            // Alignment mode makes the chosen pane a stable reference.
            clampedDriver = previousDriver
        } else {
            clampedDriver = try driverGeometry.clamped(requested)
        }
        updatedSession[pane].viewport = clampedDriver

        var followerWasClamped = false
        var changedPanes: Set<ComparisonPane> = [pane]
        if updatedSession.lockState == .locked,
           updatedSession[pane.other].source != nil {
            guard let followerGeometry = geometries[pane.other] else {
                throw ComparisonCoordinatorError.missingGeometry(pane.other)
            }
            let desiredFollower = try synchronizedViewport(
                drivenBy: pane,
                driverViewport: clampedDriver,
                driverGeometry: driverGeometry,
                followerGeometry: followerGeometry
            )
            let clampedFollower = try followerGeometry.clamped(desiredFollower)
            followerWasClamped = !Self.sameCenter(
                desiredFollower.normalizedCenter,
                clampedFollower.normalizedCenter
            )
            updatedSession[pane.other].viewport = clampedFollower
            changedPanes.insert(pane.other)
        }

        session = updatedSession
        let id = issueTransactionID()
        for changedPane in changedPanes {
            lastProgrammaticTransaction[changedPane] = id
        }
        return ComparisonViewportTransaction(
            id: id,
            driver: pane,
            leftViewport: session.left.viewport,
            rightViewport: session.right.viewport,
            driverWasClamped: !Self.sameCenter(
                requested.normalizedCenter,
                clampedDriver.normalizedCenter
            ),
            followerWasClamped: followerWasClamped
        )
    }

    /// Temporarily unlocks without modifying the saved offset or scale relationship.
    mutating func unlock() {
        session.lockState = .unlocked
    }

    /// Re-locks using one pane as the authoritative viewport. Temporary movement in the other pane
    /// is discarded, while the previously saved alignment remains intact.
    @discardableResult
    mutating func relock(
        drivenBy pane: ComparisonPane,
        geometries: [ComparisonPane: ComparisonPaneGeometry]
    ) throws -> ComparisonViewportTransaction? {
        let previousSession = session
        session.lockState = .locked
        do {
            return try updateViewport(
                in: pane,
                to: session[pane].viewport,
                geometries: geometries
            )
        } catch {
            session = previousSession
            throw error
        }
    }

    mutating func beginAlignment(anchor: ComparisonPane) {
        session.lockState = .aligning(anchor: anchor)
    }

    /// Saves the current right-versus-left relationship and returns to locked operation.
    mutating func commitAlignment(
        geometries: [ComparisonPane: ComparisonPaneGeometry]
    ) throws {
        guard case .aligning = session.lockState else { return }
        guard let leftGeometry = geometries[.left] else {
            throw ComparisonCoordinatorError.missingGeometry(.left)
        }
        guard let rightGeometry = geometries[.right] else {
            throw ComparisonCoordinatorError.missingGeometry(.right)
        }

        let leftScale = try leftGeometry.resolvedScale(for: session.left.viewport)
        let rightScale = try rightGeometry.resolvedScale(for: session.right.viewport)
        let alignment = ComparisonAlignment(
            normalizedCenterOffset: CGPoint(
                x: session.right.viewport.normalizedCenter.x - session.left.viewport.normalizedCenter.x,
                y: session.right.viewport.normalizedCenter.y - session.left.viewport.normalizedCenter.y
            ),
            rightToLeftScaleRatio: rightScale / leftScale
        )
        try Self.validate(alignment)
        session.alignment = alignment
        session.lockState = .locked
    }

    /// Clears both offset and scale alignment, then synchronizes from the requested anchor.
    @discardableResult
    mutating func resetAlignment(
        drivenBy pane: ComparisonPane,
        geometries: [ComparisonPane: ComparisonPaneGeometry]
    ) throws -> ComparisonViewportTransaction? {
        let previousSession = session
        session.alignment = .identity
        session.lockState = .locked
        do {
            return try updateViewport(
                in: pane,
                to: session[pane].viewport,
                geometries: geometries
            )
        } catch {
            session = previousSession
            throw error
        }
    }

    mutating func replaceSource(_ source: ComparisonSource, in pane: ComparisonPane) {
        session.replaceSource(source, in: pane)
    }

    mutating func reassociateSources(
        using mappings: [BatchRenameExecutionPresentation.Mapping],
        identities: PreparedRenameIdentities? = nil
    ) {
        session.reassociateSources(using: mappings, identities: identities)
    }

    mutating func markSourceMissing(in pane: ComparisonPane) {
        session.markSourceMissing(in: pane)
    }

    mutating func setLayout(_ layout: ComparisonLayout) {
        session.layout = layout
    }

    mutating func setWipePosition(_ position: CGFloat) {
        session.wipePosition = min(max(position, 0), 1)
    }

    mutating func setWipeAngleDegrees(_ angle: CGFloat) {
        session.wipeAngleDegrees = min(max(angle, -90), 90)
    }

    mutating func setFocusedPane(_ pane: ComparisonPane) {
        guard session[pane].source != nil else { return }
        session.focusedPane = pane
    }

    private func synchronizedViewport(
        drivenBy pane: ComparisonPane,
        driverViewport: ViewportState,
        driverGeometry: ComparisonPaneGeometry,
        followerGeometry: ComparisonPaneGeometry
    ) throws -> ViewportState {
        let alignment = session.alignment
        try Self.validate(alignment)

        let driverScale = try driverGeometry.resolvedScale(for: driverViewport)
        let followerScale: CGFloat
        let followerCenter: CGPoint
        if pane == .left {
            followerScale = driverScale * alignment.rightToLeftScaleRatio
            followerCenter = CGPoint(
                x: driverViewport.normalizedCenter.x + alignment.normalizedCenterOffset.x,
                y: driverViewport.normalizedCenter.y + alignment.normalizedCenterOffset.y
            )
        } else {
            followerScale = driverScale / alignment.rightToLeftScaleRatio
            followerCenter = CGPoint(
                x: driverViewport.normalizedCenter.x - alignment.normalizedCenterOffset.x,
                y: driverViewport.normalizedCenter.y - alignment.normalizedCenterOffset.y
            )
        }

        let followerMode: ViewportState.Mode
        if case .fit = driverViewport.mode, alignment == .identity {
            followerMode = .fit
        } else if case .actualPixels = driverViewport.mode, alignment == .identity {
            followerMode = .actualPixels
        } else {
            // Resolve through custom mode even if the follower currently fits. This preserves the
            // driver's comparable pixel scale across different source and pane aspect ratios.
            _ = try followerGeometry.resolvedScale(
                for: ViewportState(mode: .custom(imagePixelsPerBackingPixel: followerScale))
            )
            followerMode = .custom(imagePixelsPerBackingPixel: followerScale)
        }

        return ViewportState(
            mode: followerMode,
            normalizedCenter: followerCenter,
            interpolation: driverViewport.interpolation
        )
    }

    private mutating func issueTransactionID() -> UInt64 {
        let issued = nextTransactionID
        nextTransactionID = nextTransactionID == .max ? 1 : nextTransactionID + 1
        return issued
    }

    private static func validate(_ alignment: ComparisonAlignment) throws {
        guard alignment.normalizedCenterOffset.x.isFinite,
              alignment.normalizedCenterOffset.y.isFinite else {
            throw ComparisonCoordinatorError.invalidAlignmentOffset(
                alignment.normalizedCenterOffset
            )
        }
        guard alignment.rightToLeftScaleRatio.isFinite,
              alignment.rightToLeftScaleRatio > 0 else {
            throw ComparisonCoordinatorError.invalidAlignmentScaleRatio(
                alignment.rightToLeftScaleRatio
            )
        }
    }

    private static func sameCenter(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.000_000_1 && abs(lhs.y - rhs.y) <= 0.000_000_1
    }
}

/// A rename is an event rather than durable view state. Its identity ensures that repeating the
/// same source/destination names in a later operation is still observed exactly once.
nonisolated struct ComparisonRenameEvent: Equatable, Sendable {
    let id: UUID
    let mappings: [BatchRenameExecutionPresentation.Mapping]

    init(
        id: UUID = UUID(),
        mappings: [BatchRenameExecutionPresentation.Mapping]
    ) {
        self.id = id
        self.mappings = mappings
    }
}

nonisolated struct ComparisonWorkspaceSourceReconciliationResult: Sendable {
    let coordinator: ComparisonCoordinator
    let previousAvailableOrder: [URL]
    let missingPanes: Set<ComparisonPane>
    let replacementURLs: [ComparisonPane: URL]
}

/// Applies a rename event before checking availability, in one value-state transaction. Newly
/// mapped destinations are provisionally available for this pass so an observation delivered
/// before Browser publishes its replacement `ImageFile` values cannot erase a comparison pane.
nonisolated enum ComparisonWorkspaceSourceReconciler {
    static func reconcile(
        coordinator: ComparisonCoordinator,
        previousAvailableOrder: [URL],
        availableImages: [ImageFile],
        renameMappings: [BatchRenameExecutionPresentation.Mapping],
        identities: PreparedRenameIdentities? = nil,
        provisionalURLs: [URL] = []
    ) -> ComparisonWorkspaceSourceReconciliationResult {
        let lookup = identities.map { prepared in { prepared.lookup($0) } }
            ?? renameReassociationLookupURL
        var updated = coordinator
        updated.reassociateSources(using: renameMappings, identities: identities)

        let destinations = Dictionary(uniqueKeysWithValues: renameMappings.map {
            (lookup($0.sourceURL), $0.destinationURL.standardizedFileURL)
        })
        let mappedPreviousOrder = previousAvailableOrder.map { oldURL in
            destinations[lookup(oldURL)] ?? oldURL
        }
        let availableKeys = Set(availableImages.map { lookup($0.url) })
            .union(renameMappings.map { lookup($0.destinationURL) })
            .union(provisionalURLs.map(lookup))

        var missingPanes = Set<ComparisonPane>()
        var replacementURLs: [ComparisonPane: URL] = [:]
        for pane in ComparisonPane.allCases {
            guard let source = updated.session[pane].source,
                  !availableKeys.contains(
                    lookup(source.revision.canonicalURL)
                  ) else { continue }
            let otherURL = updated.session[pane.other].source?.revision.canonicalURL
            if let replacement = closestReplacement(
                in: availableImages,
                previousOrder: mappedPreviousOrder,
                missingURL: source.revision.canonicalURL,
                excluding: otherURL,
                lookup: lookup
            ) {
                replacementURLs[pane] = replacement.url
            }
            missingPanes.insert(pane)
            updated.markSourceMissing(in: pane)
        }

        return ComparisonWorkspaceSourceReconciliationResult(
            coordinator: updated,
            previousAvailableOrder: availableImages.map(\.url),
            missingPanes: missingPanes,
            replacementURLs: replacementURLs
        )
    }

    private static func closestReplacement(
        in availableImages: [ImageFile],
        previousOrder: [URL],
        missingURL: URL,
        excluding excludedURL: URL?,
        lookup: (URL) -> URL
    ) -> ImageFile? {
        let excludedKey = excludedURL.map(lookup)
        let availableByKey = Dictionary(
            uniqueKeysWithValues: availableImages.compactMap { image -> (URL, ImageFile)? in
                let key = lookup(image.url)
                guard SupportedImageFormats.isSupported(url: image.url),
                      key != excludedKey else { return nil }
                return (key, image)
            }
        )
        guard !availableByKey.isEmpty else { return nil }

        let missingKey = lookup(missingURL)
        guard let missingIndex = previousOrder.firstIndex(where: {
            lookup($0) == missingKey
        }) else {
            return availableImages.first {
                availableByKey[lookup($0.url)] != nil
            }
        }

        for distance in 1..<previousOrder.count {
            let nextIndex = missingIndex + distance
            if previousOrder.indices.contains(nextIndex),
               let image = availableByKey[
                lookup(previousOrder[nextIndex])
               ] {
                return image
            }
            let priorIndex = missingIndex - distance
            if previousOrder.indices.contains(priorIndex),
               let image = availableByKey[
                lookup(previousOrder[priorIndex])
               ] {
                return image
            }
        }
        return nil
    }
}
