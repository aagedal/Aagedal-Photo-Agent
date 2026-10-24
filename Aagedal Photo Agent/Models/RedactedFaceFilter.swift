import CoreGraphics
import Foundation
import ImageIO

/// Keeps the names of blurred people out of generated captions.
///
/// A face whose box overlaps an enabled Anonymizer mask (or every face, when the global
/// Anonymizer is on) is removed from the Description Assistant's face context. Both geometries
/// are mapped into the same frame first: the full, uncropped, display-oriented photo with a
/// top-left origin. Face boxes arrive display-oriented in Vision convention (bottom-left origin,
/// see `CaptionConfirmedPersonOrdering`); mask geometry lives in the sensor (XMP) frame and is
/// rotated by the photo's display orientation like the crop is.
///
/// Every approximation errs toward removing a name: masks are reduced to generous bounding
/// boxes, any overlap counts, and geometry that can't be resolved covers the whole photo.
nonisolated enum RedactedFaceFilter {
    enum Coverage: Equatable {
        /// Every face is redacted (global Anonymizer, inverted or full-frame redaction, or
        /// geometry that could not be resolved).
        case everything
        /// Top-left-origin normalized rectangles in the display-oriented frame.
        case regions([CGRect])
    }

    /// Bounding box (top-left origin, normalized) of an AI matte's visible pixels in the frame
    /// it was authored in; nil when it can't be decoded.
    typealias AIMaskBounds = (AIMaskGeometry) -> CGRect?

    static func people(
        _ people: [CaptionConfirmedPerson],
        excludingRedactedBy settings: [CameraRawSettings],
        displayOrientation: Int,
        sensorAspect: Double?,
        aiMaskBounds: AIMaskBounds = decodedAIMaskBounds
    ) -> [CaptionConfirmedPerson] {
        let coverages = settings.map {
            coverage(of: $0, displayOrientation: displayOrientation, sensorAspect: sensorAspect,
                     aiMaskBounds: aiMaskBounds)
        }
        if coverages.contains(.everything) { return [] }
        let regions = coverages.flatMap { coverage -> [CGRect] in
            if case .regions(let rects) = coverage { return rects }
            return []
        }
        guard !regions.isEmpty else { return people }
        return people.filter { person in
            let face = topLeftRect(fromVision: person.normalizedFaceRect)
            return !regions.contains { $0.intersects(face) }
        }
    }

    static func coverage(
        of settings: CameraRawSettings,
        displayOrientation: Int,
        sensorAspect: Double?,
        aiMaskBounds: AIMaskBounds = decodedAIMaskBounds
    ) -> Coverage {
        if settings.anonymizer?.isEmpty == false { return .everything }
        let redactions = (settings.localAdjustments ?? []).filter { $0.enabled && $0.isRedaction }
        var regions: [CGRect] = []
        for mask in redactions {
            if mask.inverted || mask.isFullFrame { return .everything }
            if let brush = mask.brush {
                guard let aspect = sensorAspect, aspect > 0 else { return .everything }
                regions.append(contentsOf: brushRegions(brush, displayOrientation: displayOrientation,
                                                        sensorAspect: aspect))
            } else if let aiMask = mask.aiMask {
                guard let bounds = aiMaskBounds(aiMask),
                      let mapped = rotated(bounds, from: aiMask.sourceOrientation, to: displayOrientation)
                else { return .everything }
                if !bounds.isEmpty { regions.append(mapped) }
            } else {
                guard let aspect = sensorAspect, aspect > 0 else { return .everything }
                regions.append(ellipseRegion(mask.geometry, displayOrientation: displayOrientation,
                                             sensorAspect: aspect))
            }
        }
        return .regions(regions)
    }

    // MARK: - Geometry

    static func topLeftRect(fromVision rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display-frame bounding box of an ellipse or rounded-rectangle mask. Computed for the
    /// enclosing rotated rectangle, which contains every corner-radius variant, then padded.
    static func ellipseRegion(
        _ geometry: EllipseMaskGeometry,
        displayOrientation: Int,
        sensorAspect: Double
    ) -> CGRect {
        let display = geometry.transformedForDisplay(orientation: displayOrientation, sensorAspect: sensorAspect)
        let displayAspect = displayOrientation >= 5 && displayOrientation <= 8 ? 1 / sensorAspect : sensorAspect
        let radii = display.trueRadii(aspect: displayAspect)
        // Semi-axes in image-height units, so the rotation happens in square pixel space.
        let a = abs(radii.x) * displayAspect
        let b = abs(radii.y)
        let theta = display.rotation * .pi / 180
        let halfWidth = (a * abs(cos(theta)) + b * abs(sin(theta))) / displayAspect
        let halfHeight = a * abs(sin(theta)) + b * abs(cos(theta))
        let pad = 1.1
        return CGRect(
            x: display.centerX - halfWidth * pad,
            y: display.centerY - halfHeight * pad,
            width: 2 * halfWidth * pad,
            height: 2 * halfHeight * pad
        )
    }

    /// One box per painted (non-erase) stroke, dab centres padded by the brush radius. Erasing
    /// only removes coverage, so ignoring it keeps the box a superset.
    static func brushRegions(
        _ brush: BrushMaskGeometry,
        displayOrientation: Int,
        sensorAspect: Double
    ) -> [CGRect] {
        let display = brush.transformedForDisplay(orientation: displayOrientation)
        let displayAspect = displayOrientation >= 5 && displayOrientation <= 8 ? 1 / sensorAspect : sensorAspect
        return display.strokes.compactMap { stroke -> CGRect? in
            guard !stroke.erase, !stroke.dabs.isEmpty else { return nil }
            // The radius is a fraction of the long edge.
            let radiusX = displayAspect >= 1 ? stroke.radius : stroke.radius / displayAspect
            let radiusY = displayAspect >= 1 ? stroke.radius * displayAspect : stroke.radius
            let xs = stroke.dabs.map(\.x)
            let ys = stroke.dabs.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return nil
            }
            return CGRect(x: minX - radiusX, y: minY - radiusY,
                          width: maxX - minX + 2 * radiusX, height: maxY - minY + 2 * radiusY)
        }
    }

    /// Rotates a top-left normalized rect between two display orientations. Nil when a mirror
    /// orientation is involved (not a pure rotation), so the caller falls back to full coverage.
    static func rotated(_ rect: CGRect, from source: Int, to target: Int) -> CGRect? {
        guard source != target else { return rect }
        let quarterTurns: [Int: Int] = [1: 0, 6: 1, 3: 2, 8: 3]
        guard let from = quarterTurns[source], let to = quarterTurns[target] else { return nil }
        var result = rect
        for _ in 0..<((to - from + 4) % 4) {
            // 90° clockwise in top-left coordinates: (x, y) → (1 − y, x).
            result = CGRect(x: 1 - result.maxY, y: result.minX, width: result.height, height: result.width)
        }
        return result
    }

    /// Bounding box of the matte's pixels above a small threshold, in its authored frame.
    static func decodedAIMaskBounds(_ mask: AIMaskGeometry) -> CGRect? {
        guard mask.isValid,
              let source = CGImageSourceCreateWithData(mask.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] > 8 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return .zero }
        // CGContext memory starts at the top row, so rows are already top-left oriented.
        let pad = 2.0
        return CGRect(
            x: (Double(minX) - pad) / Double(width),
            y: (Double(minY) - pad) / Double(height),
            width: (Double(maxX - minX + 1) + 2 * pad) / Double(width),
            height: (Double(maxY - minY + 1) + 2 * pad) / Double(height)
        )
    }
}
