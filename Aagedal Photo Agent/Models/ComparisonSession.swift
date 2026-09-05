import CoreGraphics
import Foundation

/// Identifies one side of a comparison without coupling comparison logic to a particular layout.
nonisolated enum ComparisonPane: String, CaseIterable, Hashable, Sendable {
    case left
    case right

    var other: ComparisonPane {
        self == .left ? .right : .left
    }
}

/// Presentation choices shared by Browser, Develop, full-screen, and Clean Feed.
nonisolated enum ComparisonLayout: String, CaseIterable, Hashable, Sendable {
    case sideBySide
    case stacked
    case wipe
}

/// Geometry for the adjustable comparison wipe. The angle is measured from a vertical divider:
/// zero degrees produces the familiar left/right wipe, while positive values tilt it clockwise.
nonisolated enum ComparisonWipeGeometry {
    static func maskPolygon(
        in rect: CGRect,
        position: CGFloat,
        angleDegrees: CGFloat
    ) -> [CGPoint] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let normal = normalVector(angleDegrees: angleDegrees)
        let threshold = projectionThreshold(
            in: rect,
            position: position,
            normal: normal
        )
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]

        var output: [CGPoint] = []
        for index in corners.indices {
            let current = corners[index]
            let previous = corners[(index + corners.count - 1) % corners.count]
            let currentInside = projection(of: current, normal: normal) <= threshold
            let previousInside = projection(of: previous, normal: normal) <= threshold

            if currentInside != previousInside,
               let intersection = intersection(
                    from: previous,
                    to: current,
                    threshold: threshold,
                    normal: normal
               ) {
                output.append(intersection)
            }
            if currentInside { output.append(current) }
        }
        return output
    }

    static func dividerSegment(
        in rect: CGRect,
        position: CGFloat,
        angleDegrees: CGFloat
    ) -> (CGPoint, CGPoint)? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let normal = normalVector(angleDegrees: angleDegrees)
        let threshold = projectionThreshold(
            in: rect,
            position: position,
            normal: normal
        )
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        var intersections: [CGPoint] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            if let point = intersection(
                from: start,
                to: end,
                threshold: threshold,
                normal: normal
            ), rect.insetBy(dx: -0.001, dy: -0.001).contains(point) {
                if !intersections.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 0.001 }) {
                    intersections.append(point)
                }
            }
        }
        guard intersections.count >= 2 else { return nil }
        var pair = (intersections[0], intersections[1])
        var longestDistance = hypot(
            pair.0.x - pair.1.x,
            pair.0.y - pair.1.y
        )
        for firstIndex in intersections.indices {
            for secondIndex in intersections.indices where secondIndex > firstIndex {
                let first = intersections[firstIndex]
                let second = intersections[secondIndex]
                let distance = hypot(first.x - second.x, first.y - second.y)
                if distance > longestDistance {
                    pair = (first, second)
                    longestDistance = distance
                }
            }
        }
        return pair
    }

    static func position(
        for point: CGPoint,
        in rect: CGRect,
        angleDegrees: CGFloat
    ) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 0.5 }
        let normal = normalVector(angleDegrees: angleDegrees)
        let range = projectionRange(in: rect, normal: normal)
        guard range.upperBound > range.lowerBound else { return 0.5 }
        return min(max(
            (projection(of: point, normal: normal) - range.lowerBound)
                / (range.upperBound - range.lowerBound),
            0
        ), 1)
    }

    private static func normalVector(angleDegrees: CGFloat) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(x: cos(radians), y: sin(radians))
    }

    private static func projectionThreshold(
        in rect: CGRect,
        position: CGFloat,
        normal: CGPoint
    ) -> CGFloat {
        let range = projectionRange(in: rect, normal: normal)
        return range.lowerBound
            + min(max(position, 0), 1) * (range.upperBound - range.lowerBound)
    }

    private static func projectionRange(
        in rect: CGRect,
        normal: CGPoint
    ) -> ClosedRange<CGFloat> {
        let values = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map { projection(of: $0, normal: normal) }
        return (values.min() ?? 0)...(values.max() ?? 0)
    }

    private static func projection(of point: CGPoint, normal: CGPoint) -> CGFloat {
        point.x * normal.x + point.y * normal.y
    }

    private static func intersection(
        from start: CGPoint,
        to end: CGPoint,
        threshold: CGFloat,
        normal: CGPoint
    ) -> CGPoint? {
        let startProjection = projection(of: start, normal: normal)
        let deltaProjection = projection(
            of: CGPoint(x: end.x - start.x, y: end.y - start.y),
            normal: normal
        )
        guard abs(deltaProjection) > 0.000_001 else { return nil }
        let amount = (threshold - startProjection) / deltaProjection
        guard amount >= -0.000_001, amount <= 1.000_001 else { return nil }
        return CGPoint(
            x: start.x + (end.x - start.x) * amount,
            y: start.y + (end.y - start.y) * amount
        )
    }
}

nonisolated enum ComparisonOriginWorkspace: String, Hashable, Sendable {
    case browser
    case develop
    case fullScreen
}

/// A fixed Develop representation selected for comparison with the currently active version.
/// Primary remains virtual and XMP-backed, while named versions resolve through the source-bound
/// catalog. Keeping this separate from `ComparisonRepresentation` makes target selection stable
/// before the render token is known.
nonisolated enum DevelopVersionComparisonTarget: Hashable, Sendable {
    case primary
    case named(UUID)
}

/// The pixels a comparison pane resolves for a source revision.
nonisolated enum ComparisonRepresentation: Hashable, Sendable {
    case original
    case committedEdit
    case liveEdit(renderToken: String)
    case primary(renderToken: String)
    case namedVersion(id: UUID, name: String, renderToken: String)

    var displayName: String {
        switch self {
        case .original:
            "Original"
        case .committedEdit:
            "Committed Edit"
        case .liveEdit:
            "Live Edit"
        case .primary:
            "Primary (XMP)"
        case let .namedVersion(_, name, _):
            name
        }
    }

    /// Changes whenever cached pixels for a non-static representation become stale.
    var renderToken: String? {
        switch self {
        case .original, .committedEdit:
            nil
        case let .liveEdit(renderToken), let .primary(renderToken),
             let .namedVersion(_, _, renderToken):
            renderToken
        }
    }
}

nonisolated enum ComparisonDynamicRange: String, Hashable, Sendable {
    case unknown
    case sdr
    case hdr
}

/// A source is bound to exact bytes. Its URL is only a discovery hint through
/// `SourceImageRevision`; replacing a missing source requires a new exact revision.
nonisolated struct ComparisonSource: Hashable, Sendable {
    let revision: SourceImageRevision
    var representation: ComparisonRepresentation
    var dynamicRange: ComparisonDynamicRange

    init(
        revision: SourceImageRevision,
        representation: ComparisonRepresentation,
        dynamicRange: ComparisonDynamicRange = .unknown
    ) {
        self.revision = revision
        self.representation = representation
        self.dynamicRange = dynamicRange
    }

    var filename: String { revision.filenameAtCreation }
    var representationLabel: String { representation.displayName }

    func relocated(to url: URL, identities: PreparedRenameIdentities? = nil) -> ComparisonSource {
        ComparisonSource(
            revision: identities.map { revision.relocated(toPreparedCanonicalURL: $0.canonical(url)) }
                ?? revision.relocated(to: url),
            representation: representation,
            dynamicRange: dynamicRange
        )
    }
}

nonisolated struct ComparisonPaneState: Hashable, Sendable {
    /// `nil` deliberately represents a source removed while Compare is open. The other pane and
    /// its viewport remain intact so the UI can offer replacement without destroying the session.
    var source: ComparisonSource?
    var viewport: ViewportState

    init(source: ComparisonSource?, viewport: ViewportState = ViewportState()) {
        self.source = source
        self.viewport = viewport
    }
}

/// Right-pane alignment relative to the left pane.
nonisolated struct ComparisonAlignment: Hashable, Sendable {
    var normalizedCenterOffset: CGPoint
    var rightToLeftScaleRatio: CGFloat

    static let identity = ComparisonAlignment(
        normalizedCenterOffset: .zero,
        rightToLeftScaleRatio: 1
    )

    init(normalizedCenterOffset: CGPoint, rightToLeftScaleRatio: CGFloat) {
        self.normalizedCenterOffset = normalizedCenterOffset
        self.rightToLeftScaleRatio = rightToLeftScaleRatio
    }
}

/// Unlocking never clears `ComparisonSession.alignment`; reset is a separate explicit action.
nonisolated enum ComparisonLockState: Hashable, Sendable {
    case locked
    case unlocked
    case aligning(anchor: ComparisonPane)
}

/// The reusable, UI-independent state shared by every comparison entry point.
nonisolated struct ComparisonSession: Hashable, Sendable {
    let id: UUID
    let origin: ComparisonOriginWorkspace
    var layout: ComparisonLayout
    var focusedPane: ComparisonPane
    var lockState: ComparisonLockState
    var alignment: ComparisonAlignment
    var wipePosition: CGFloat
    var wipeAngleDegrees: CGFloat
    var left: ComparisonPaneState
    var right: ComparisonPaneState

    init(
        id: UUID = UUID(),
        origin: ComparisonOriginWorkspace,
        left: ComparisonSource,
        right: ComparisonSource,
        layout: ComparisonLayout = .sideBySide,
        focusedPane: ComparisonPane = .left,
        lockState: ComparisonLockState = .locked,
        alignment: ComparisonAlignment = .identity,
        wipePosition: CGFloat = 0.5,
        wipeAngleDegrees: CGFloat = 0,
        viewport: ViewportState = ViewportState()
    ) {
        self.id = id
        self.origin = origin
        self.layout = layout
        self.focusedPane = focusedPane
        self.lockState = lockState
        self.alignment = alignment
        self.wipePosition = min(max(wipePosition, 0), 1)
        self.wipeAngleDegrees = min(max(wipeAngleDegrees, -90), 90)
        self.left = ComparisonPaneState(source: left, viewport: viewport)
        self.right = ComparisonPaneState(source: right, viewport: viewport)
    }

    subscript(_ pane: ComparisonPane) -> ComparisonPaneState {
        get { pane == .left ? left : right }
        set {
            if pane == .left {
                left = newValue
            } else {
                right = newValue
            }
        }
    }

    mutating func replaceSource(_ source: ComparisonSource, in pane: ComparisonPane) {
        self[pane].source = source
    }

    mutating func markSourceMissing(in pane: ComparisonPane) {
        self[pane].source = nil
        if focusedPane == pane, self[pane.other].source != nil {
            focusedPane = pane.other
        }
    }

    var hasBothSources: Bool {
        left.source != nil && right.source != nil
    }

    var hasDynamicRangeMismatch: Bool {
        guard let leftRange = left.source?.dynamicRange,
              let rightRange = right.source?.dynamicRange,
              leftRange != .unknown,
              rightRange != .unknown else { return false }
        return leftRange != rightRange
    }

    /// Refreshes only URL discovery hints while preserving the comparison identity, rendered
    /// representation, layout, focus, alignment, and viewport state. The lookup is simultaneous,
    /// which keeps A↔B swaps and longer cycles unambiguous.
    mutating func reassociateSources(
        using mappings: [BatchRenameExecutionPresentation.Mapping],
        identities: PreparedRenameIdentities? = nil
    ) {
        let lookup = identities.map { prepared in { prepared.lookup($0) } }
            ?? renameReassociationLookupURL
        let destinations = Dictionary(uniqueKeysWithValues: mappings.map {
            (lookup($0.sourceURL), $0.destinationURL.standardizedFileURL)
        })
        for pane in ComparisonPane.allCases {
            guard let source = self[pane].source,
                  let destination = destinations[
                    lookup(source.revision.canonicalURL)
                  ]
            else { continue }
            self[pane].source = source.relocated(to: destination, identities: identities)
        }
    }
}

/// Resolves Browser Compare input in the same order the user sees in the grid. A `Set` does not
/// preserve selection order, so callers must supply the currently visible, sorted image list.
nonisolated enum ComparisonSelectionResolver {
    static func images(
        in visibleImages: [ImageFile],
        selectedURLs: Set<URL>
    ) -> [ImageFile]? {
        guard selectedURLs.count == 2 else { return nil }
        let selection = visibleImages.filter { image in
            selectedURLs.contains(image.url) && SupportedImageFormats.isSupported(url: image.url)
        }
        return selection.count == 2 ? selection : nil
    }
}

/// Resolves a comparison launched from the dedicated full-screen viewer. The image currently
/// displayed remains pane A. A second selected image wins when available; otherwise the next
/// supported filmstrip image is used, with the previous image as the end-of-filmstrip fallback.
nonisolated enum FullScreenComparisonSelectionResolver {
    static func images(
        in visibleImages: [ImageFile],
        currentURL: URL?,
        selectedURLs: Set<URL>
    ) -> [ImageFile]? {
        guard let currentURL,
              let currentIndex = visibleImages.firstIndex(where: {
                  $0.url == currentURL && SupportedImageFormats.isSupported(url: $0.url)
              }) else {
            return nil
        }

        let current = visibleImages[currentIndex]
        if let selectedPeer = visibleImages.first(where: {
            $0.url != currentURL
                && selectedURLs.contains($0.url)
                && SupportedImageFormats.isSupported(url: $0.url)
        }) {
            return [current, selectedPeer]
        }

        if currentIndex < visibleImages.index(before: visibleImages.endIndex) {
            for index in visibleImages.index(after: currentIndex)..<visibleImages.endIndex {
                let candidate = visibleImages[index]
                if SupportedImageFormats.isSupported(url: candidate.url) {
                    return [current, candidate]
                }
            }
        }

        if currentIndex > visibleImages.startIndex {
            for index in stride(from: currentIndex - 1, through: visibleImages.startIndex, by: -1) {
                let candidate = visibleImages[index]
                if SupportedImageFormats.isSupported(url: candidate.url) {
                    return [current, candidate]
                }
            }
        }
        return nil
    }
}

/// Resolves the default Develop comparison target without changing the current edit selection.
/// The previous supported filmstrip image wins; the next image is the boundary fallback.
nonisolated enum DevelopComparisonSelectionResolver {
    static func target(
        in visibleImages: [ImageFile],
        currentURL: URL
    ) -> ImageFile? {
        guard let currentIndex = visibleImages.firstIndex(where: { $0.url == currentURL }) else {
            return nil
        }

        if currentIndex > visibleImages.startIndex {
            for index in stride(from: currentIndex - 1, through: visibleImages.startIndex, by: -1) {
                let candidate = visibleImages[index]
                if SupportedImageFormats.isSupported(url: candidate.url) {
                    return candidate
                }
            }
        }

        if currentIndex < visibleImages.index(before: visibleImages.endIndex) {
            for index in visibleImages.index(after: currentIndex)..<visibleImages.endIndex {
                let candidate = visibleImages[index]
                if SupportedImageFormats.isSupported(url: candidate.url) {
                    return candidate
                }
            }
        }
        return nil
    }
}

nonisolated enum ComparisonNavigationDirection: Sendable {
    case previous
    case next

    var step: Int {
        switch self {
        case .previous: -1
        case .next: 1
        }
    }
}

/// Resolves filmstrip replacement without letting both comparison panes silently resolve to the
/// same source. Navigation stops at the visible-order boundary, matching Browser arrow behavior.
nonisolated enum ComparisonNavigationResolver {
    static func replacement(
        in visibleImages: [ImageFile],
        currentURL: URL,
        excluding excludedURL: URL?,
        direction: ComparisonNavigationDirection
    ) -> ImageFile? {
        guard let currentIndex = visibleImages.firstIndex(where: { $0.url == currentURL }) else {
            return nil
        }

        var index = currentIndex + direction.step
        while visibleImages.indices.contains(index) {
            let candidate = visibleImages[index]
            if candidate.url != excludedURL,
               SupportedImageFormats.isSupported(url: candidate.url) {
                return candidate
            }
            index += direction.step
        }
        return nil
    }

    /// Picks the nearest surviving source from the order that existed before deletion. The image
    /// after the missing source wins ties, and the source already displayed in the other pane is
    /// excluded.
    static func closestReplacement(
        in availableImages: [ImageFile],
        previousOrder: [URL],
        missingURL: URL,
        excluding excludedURL: URL?
    ) -> ImageFile? {
        let availableByURL: [URL: ImageFile] = Dictionary(
            uniqueKeysWithValues: availableImages.compactMap { image -> (URL, ImageFile)? in
                guard SupportedImageFormats.isSupported(url: image.url),
                      image.url != excludedURL else { return nil }
                return (image.url, image)
            }
        )
        guard !availableByURL.isEmpty else { return nil }

        guard let missingIndex = previousOrder.firstIndex(of: missingURL) else {
            return availableImages.first { availableByURL[$0.url] != nil }
        }

        for distance in 1..<previousOrder.count {
            let nextIndex = missingIndex + distance
            if previousOrder.indices.contains(nextIndex),
               let image = availableByURL[previousOrder[nextIndex]] {
                return image
            }

            let previousIndex = missingIndex - distance
            if previousOrder.indices.contains(previousIndex),
               let image = availableByURL[previousOrder[previousIndex]] {
                return image
            }
        }
        return availableImages.first { availableByURL[$0.url] != nil }
    }
}
