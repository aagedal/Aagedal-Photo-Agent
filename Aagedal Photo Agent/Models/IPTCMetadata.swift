import Foundation

nonisolated struct ToneCurvePoint: Codable, Sendable, Equatable {
    var x: Double  // 0-1 input brightness
    var y: Double  // 0-1 output brightness
}

extension ToneCurvePoint {
    /// Build a point from Adobe Camera Raw 0–255 coordinates, sanitizing
    /// non-finite or out-of-range input to the normalized 0...1 range. A corrupt
    /// sidecar value of `inf`/`nan` would otherwise seed a non-finite coordinate
    /// that traps on re-serialization (`Int(round(...))`) and poisons LUT generation.
    nonisolated init(acr255 x: Double, _ y: Double) {
        func normalized(_ value: Double) -> Double {
            guard value.isFinite else { return value == .infinity ? 1 : 0 }
            return min(max(value / 255, 0), 1)
        }
        self.init(x: normalized(x), y: normalized(y))
    }
}

nonisolated struct ToneCurve: Codable, Sendable, Equatable {
    var master: [ToneCurvePoint]?
    var red: [ToneCurvePoint]?
    var green: [ToneCurvePoint]?
    var blue: [ToneCurvePoint]?

    var isEmpty: Bool {
        (master?.isIdentityToneCurve ?? true)
            && (red?.isIdentityToneCurve ?? true)
            && (green?.isIdentityToneCurve ?? true)
            && (blue?.isIdentityToneCurve ?? true)
    }
}

nonisolated extension Array where Element == ToneCurvePoint {
    var isIdentityToneCurve: Bool {
        guard count >= 2 else { return true }
        let ordered = sorted { $0.x < $1.x }
        let epsilon = 0.001
        guard let first = ordered.first, let last = ordered.last,
              abs(first.x) < epsilon,
              abs(first.y) < epsilon,
              abs(last.x - 1) < epsilon,
              abs(last.y - 1) < epsilon
        else { return false }
        return ordered.allSatisfy { abs($0.x - $0.y) < epsilon }
    }
}

nonisolated struct CameraRawCrop: Codable, Sendable, Equatable {
    var top: Double?
    var left: Double?
    var bottom: Double?
    var right: Double?
    var angle: Double?
    var hasCrop: Bool?

    var isEmpty: Bool {
        top == nil
            && left == nil
            && bottom == nil
            && right == nil
            && angle == nil
            && hasCrop == nil
    }

    /// A crop the user can actually see — a non-full-frame rectangle or a straighten
    /// angle. Merely opening the crop tool persists `hasCrop = true` with a full-frame
    /// identity rect (top/left = 0, bottom/right = 1, angle = 0); that is a no-op and
    /// must not light the crop badge, so `hasCrop` alone is not enough.
    var isEffectiveCrop: Bool {
        let epsilon = 0.0001
        return abs(top ?? 0) > epsilon
            || abs(left ?? 0) > epsilon
            || abs((bottom ?? 1) - 1) > epsilon
            || abs((right ?? 1) - 1) > epsilon
            || abs(angle ?? 0) > epsilon
    }
}

// MARK: - ACR XMP boundary conversion
//
// In-app, `CameraRawCrop` stores the UPRIGHT actual crop rectangle in normalized
// sensor-frame coordinates: width/height are the straightened crop's real
// dimensions, and the rect's center — read as a point in the un-rotated image and
// mapped through the straighten rotation about the image center — is the crop's
// position (see CameraRawApproximation.applyCrop). Adobe's crs:CropLeft/Top/
// Right/Bottom are different: two opposite corners of the crop's footprint in the
// UN-ROTATED original frame — the same corner model the radial masks use (see
// EllipseMaskGeometry). Rotating both stored corners about the image center by
// −CropAngle in pixel space yields the axis-aligned crop in the straightened
// canvas. Both conventions share the corner midpoint as the crop center, so only
// the corner diagonal needs rotating; they coincide exactly at angle = 0.
//
// Authority: darktable's Lightroom-XMP importer (src/develop/lightroom.c).
// Validated against Camera Raw 18.3.2: decoding the repro file's stored values
// (CropAngle −12.786738 on 7008×4672) gives 4415×4649 px, matching ACR's render
// aspect to 4 decimals (ACR auto-shrunk the out-of-bounds app-convention values
// uniformly, preserving that aspect).
nonisolated extension CameraRawCrop {
    /// Convert Adobe-convention crs values (un-rotated-frame corners) to the
    /// app's upright-rect convention. `aspect` is the sensor-frame (un-oriented)
    /// imageWidth/imageHeight. Identity at angle 0 or when edges/aspect are missing.
    func decodedFromACR(aspect: Double?) -> CameraRawCrop {
        rotatedDiagonal(aspect: aspect, theta: -(angle ?? 0) * .pi / 180, absolute: true)
    }

    /// Inverse of `decodedFromACR`: re-encode the app's upright rect into Adobe's
    /// un-rotated-frame corners for writing to crs fields.
    func encodedForACR(aspect: Double?) -> CameraRawCrop {
        rotatedDiagonal(aspect: aspect, theta: (angle ?? 0) * .pi / 180, absolute: false)
    }

    /// Shared core: rotate the corner diagonal by `theta` in pixel-proportional
    /// space (x scaled by aspect, y-down) about the shared center. `absolute`
    /// normalizes the result to positive extents (decoding must yield a real
    /// rect; encoding keeps signed corners exactly as Adobe stores them).
    private func rotatedDiagonal(aspect: Double?, theta: Double, absolute: Bool) -> CameraRawCrop {
        guard let top, let left, let bottom, let right,
              let aspect, aspect > 0,
              abs(angle ?? 0) > 0.0001
        else { return self }

        let dx = (right - left) * aspect
        let dy = bottom - top
        var rx = dx * cos(theta) - dy * sin(theta)
        var ry = dx * sin(theta) + dy * cos(theta)
        if absolute {
            rx = abs(rx)
            ry = abs(ry)
        }

        let cx = (left + right) / 2
        let cy = (top + bottom) / 2
        var result = self
        result.left = cx - rx / (2 * aspect)
        result.right = cx + rx / (2 * aspect)
        result.top = cy - ry / 2
        result.bottom = cy + ry / 2
        return result
    }
}

/// Radial-gradient mask geometry, stored in ACR's XMP encoding so the values
/// round-trip losslessly through `crs:MaskGroupBasedCorrections`.
///
/// `radiusX`/`radiusY` are the SIGNED half-extents of the box (Left,Top)-(Right,Bottom).
/// ACR's box corners are the corners of the ellipse's ORIENTED bounding rect: the
/// half-diagonal is the ellipse corner vector rotated by `rotation` in aspect-corrected
/// (pixel-proportional) space. For rotated masks the corner can cross the center
/// (Left > Right in real ACR files), so the half-extents go negative and are NOT the
/// semi-axes. Decode (aspect = imageW/imageH, θ = rotation):
///
///     (a·aspect, b) = R(−θ) · (radiusX·aspect, radiusY)
///
/// where (a, b) are the true UV semi-axes; both must come out positive or the mask is
/// degenerate (ACR renders nothing). At rotation 0 the box half-extents ARE the
/// semi-axes — verified empirically against Camera Raw 18.3.2 (2026-06: two rotated
/// samples decode to the authored ellipse within 4 decimals; a rotated visually-circular
/// mask decodes to a pixel circle within 0.04%; a rendered export fits the rigid
/// pixel-space rotation within 0.6°). ACR additionally only accepts `rotation` in its
/// canonical (−45°, 45°] range — out-of-range angles render nothing there — so the
/// mask overlay canonicalizes the angle (swapping axes per quarter turn) on rotation.
nonisolated struct EllipseMaskGeometry: Codable, Sendable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radiusX: Double = 0.15
    var radiusY: Double = 0.10
    var rotation: Double = 0
    var feather: Double = 50

    /// True UV semi-axes, decoded from the oriented-corner box encoding.
    /// Components ≤ 0 mean the stored values don't describe a valid ellipse
    /// at this rotation (ACR renders nothing for these).
    func trueRadii(aspect: Double) -> (x: Double, y: Double) {
        guard aspect > 0 else { return (radiusX, radiusY) }
        let theta = rotation * .pi / 180
        let dx = radiusX * aspect
        let dy = radiusY
        let a = dx * cos(theta) + dy * sin(theta)
        let b = -dx * sin(theta) + dy * cos(theta)
        return (a / aspect, b)
    }

    /// Inverse of `trueRadii`: re-encode true UV semi-axes into the stored
    /// oriented-corner half-extents for the current rotation.
    mutating func setTrueRadii(x: Double, y: Double, aspect: Double) {
        guard aspect > 0 else { radiusX = x; radiusY = y; return }
        let theta = rotation * .pi / 180
        let ax = x * aspect
        let ay = y
        radiusX = (ax * cos(theta) - ay * sin(theta)) / aspect
        radiusY = ax * sin(theta) + ay * cos(theta)
    }

    /// Rigidly rotate the whole ellipse by `degrees` about the frame center
    /// (0.5, 0.5) — the continuous analogue of `transformedForDisplay`, used to
    /// follow a crop STRAIGHTEN angle. The display path renders the mask effect
    /// in source space and then rotates the whole image view by the straighten
    /// angle, so the overlay (a non-rotated sibling) must bake the same rotation
    /// in to stay aligned. Rotation happens in aspect-corrected (pixel) space so
    /// the ellipse isn't sheared; the true semi-axes are preserved and re-encoded
    /// at the new angle. `aspect` is the display frame's pixel width/height.
    /// `degrees` uses the screen convention (positive = clockwise, matching
    /// SwiftUI's `.rotationEffect(.degrees(_:))`). Inverse: negate `degrees`.
    func rotatedInDisplay(byDegrees degrees: Double, aspect: Double) -> EllipseMaskGeometry {
        guard abs(degrees) > 1e-12 else { return self }
        let a = aspect > 0 ? aspect : 1
        let rad = degrees * .pi / 180
        let semi = trueRadii(aspect: a)   // rotation-invariant ellipse shape
        var result = self
        // Rotate the center about (0.5, 0.5) in aspect-corrected space.
        let dx = (centerX - 0.5) * a
        let dy = centerY - 0.5
        result.centerX = 0.5 + (dx * cos(rad) - dy * sin(rad)) / a
        result.centerY = 0.5 + (dx * sin(rad) + dy * cos(rad))
        result.rotation = rotation + degrees
        result.setTrueRadii(x: semi.x, y: semi.y, aspect: a)
        return result
    }

    /// Transform mask geometry from sensor (XMP) orientation to display
    /// orientation, mirroring `CameraRawCrop.transformedForDisplay`. The center
    /// point-maps like the crop corners. The true semi-axes are frame-relative
    /// fractions (x of width, y of height), so 90°-family orientations swap
    /// them directly; flips negate the rotation angle (reflection), and the
    /// ±90° of pure rotations is absorbed by the axis swap so the angle stays
    /// in ACR's canonical (−45°, 45°] range. `sensorAspect` is the un-oriented
    /// pixel width/height — needed to decode the oriented-corner box encoding.
    func transformedForDisplay(orientation: Int, sensorAspect: Double) -> EllipseMaskGeometry {
        let aspect = sensorAspect > 0 ? sensorAspect : 1
        var result = self
        var axes = trueRadii(aspect: aspect)
        let cx = centerX, cy = centerY
        switch orientation {
        case 2:  // flip horizontal
            result.centerX = 1 - cx
            result.rotation = -rotation
        case 3:  // rotate 180°
            result.centerX = 1 - cx
            result.centerY = 1 - cy
        case 4:  // flip vertical
            result.centerY = 1 - cy
            result.rotation = -rotation
        case 5:  // transpose
            result.centerX = cy
            result.centerY = cx
            result.rotation = -rotation
            axes = (axes.y, axes.x)
        case 6:  // rotate 90° CW
            result.centerX = 1 - cy
            result.centerY = cx
            axes = (axes.y, axes.x)
        case 7:  // transverse
            result.centerX = 1 - cy
            result.centerY = 1 - cx
            result.rotation = -rotation
            axes = (axes.y, axes.x)
        case 8:  // rotate 90° CCW
            result.centerX = cy
            result.centerY = 1 - cx
            axes = (axes.y, axes.x)
        default:
            return self  // O=1 or unknown
        }
        // A flipped boundary angle can land exactly on −45°, which ACR rejects
        // ((−45°, 45°] is the accepted range) — rotate a quarter turn into range.
        if result.rotation <= -45 {
            result.rotation += 90
            axes = (axes.y, axes.x)
        }
        let displayAspect = orientation >= 5 ? 1 / aspect : aspect
        result.setTrueRadii(x: axes.x, y: axes.y, aspect: displayAspect)
        return result
    }

    /// Inverse: transform mask geometry from display orientation back to the
    /// sensor (XMP) frame. `displayAspect` is the oriented pixel width/height
    /// (the frame the geometry currently lives in).
    func transformedForSensor(orientation: Int, displayAspect: Double) -> EllipseMaskGeometry {
        let inverse: Int
        switch orientation {
        case 6: inverse = 8  // inverse of 90° CW = 90° CCW
        case 8: inverse = 6  // inverse of 90° CCW = 90° CW
        default: inverse = orientation  // flips, 180°, transpose, transverse are self-inverse
        }
        return transformedForDisplay(orientation: inverse, sensorAspect: displayAspect)
    }
}

/// One paint dab — a single stamped disc along a brush stroke. Coordinates are normalized UV
/// in the sensor (XMP) frame, matching ACR's `d x y` `Dabs` convention (values can slightly
/// exceed [0,1] at frame edges). `flow` and `hardness` are the brush settings in effect for
/// this dab (ACR's inline `f`/`h` records), so a stroke can vary them mid-drag.
nonisolated struct BrushDab: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var flow: Double      // 0-1, ACR `f` record
    var hardness: Double  // 0-1, ACR `h` record (a.k.a. CenterWeight)
}

/// One brush stroke — a single mouse-down/up gesture, mirroring one ACR `Mask/Paint` sub-mask.
/// The dabs union together (or subtract, when `erase`) to form this stroke's contribution.
nonisolated struct BrushStroke: Codable, Sendable, Equatable {
    var dabs: [BrushDab]
    var radius: Double    // normalized brush radius, constant per stroke (ACR `Radius`)
    var density: Double   // 0-1 accumulated-opacity ceiling (ACR per-sub-mask `MaskValue`) — needs calibration
    var erase: Bool       // true = subtract this stroke from the accumulated mask

    init(dabs: [BrushDab] = [], radius: Double = 0.1, density: Double = 1.0, erase: Bool = false) {
        self.dabs = dabs
        self.radius = radius
        self.density = density
        self.erase = erase
    }
}

/// Freeform paint-mask geometry — a list of strokes (mirrors one ACR `Mask/Aggregate`'s
/// nested `Mask/Paint` sub-masks). A sibling of `EllipseMaskGeometry` on `MaskAdjustment`;
/// every existing per-mask adjustment (exposure, Anonymizer, Temp/Tint…) works on it
/// unchanged because they only ever see a resolved weight + rgb.
nonisolated struct BrushMaskGeometry: Codable, Sendable, Equatable {
    var strokes: [BrushStroke] = []
    var isEmpty: Bool { strokes.isEmpty }

    /// Point-maps every dab from the sensor (XMP) frame to the display frame under an EXIF
    /// orientation, mirroring `EllipseMaskGeometry.transformedForDisplay`'s center mapping.
    /// A dab is a pixel-space circle whose radius is long-edge-relative (invariant under the
    /// 90°-family axis swap), so only the position needs remapping — no aspect correction, and
    /// `radius`/`density`/flow/hardness are untouched.
    func transformedForDisplay(orientation: Int) -> BrushMaskGeometry {
        guard orientation > 1 else { return self }
        var result = self
        result.strokes = strokes.map { stroke in
            var s = stroke
            s.dabs = stroke.dabs.map { dab in
                var d = dab
                let mapped = Self.mapPoint(x: dab.x, y: dab.y, orientation: orientation)
                d.x = mapped.x
                d.y = mapped.y
                return d
            }
            return s
        }
        return result
    }

    /// Inverse of `transformedForDisplay` — maps dabs from the display frame back to the sensor
    /// (XMP) frame for writing. Only the ±90° rotations aren't self-inverse.
    func transformedForSensor(orientation: Int) -> BrushMaskGeometry {
        let inverse: Int
        switch orientation {
        case 6: inverse = 8
        case 8: inverse = 6
        default: inverse = orientation
        }
        return transformedForDisplay(orientation: inverse)
    }

    /// UV point mapping for each EXIF orientation, identical to the center mapping in
    /// `EllipseMaskGeometry.transformedForDisplay`. Normalized UV, so the 90°-family swap is a
    /// direct x/y exchange (no aspect term).
    private static func mapPoint(x: Double, y: Double, orientation: Int) -> (x: Double, y: Double) {
        switch orientation {
        case 2: return (1 - x, y)          // flip horizontal
        case 3: return (1 - x, 1 - y)      // rotate 180°
        case 4: return (x, 1 - y)          // flip vertical
        case 5: return (y, x)              // transpose
        case 6: return (1 - y, x)          // rotate 90° CW
        case 7: return (1 - y, 1 - x)      // transverse
        case 8: return (y, 1 - x)          // rotate 90° CCW
        default: return (x, y)             // O=1 or unknown
        }
    }
}

nonisolated enum WatermarkDimension: String, Codable, Sendable {
    case width, height
}

nonisolated enum WatermarkSizeUnit: String, Codable, Sendable {
    case pixel, percent
}

nonisolated enum WatermarkMarginUnit: String, Codable, Sendable {
    case pixel, percent
}

/// Position + sizing for one watermark layer instance. `centerX`/`centerY` are the
/// watermark's own anchor point (its rendered center), normalized UV in the sensor (XMP)
/// frame — same convention as `EllipseMaskGeometry`'s center. Size and margin are each
/// independently expressed as either an absolute pixel value or a percentage (of the
/// relevant image dimension); the watermark's own aspect ratio determines whichever
/// dimension isn't explicitly constrained. Unlike the ellipse/brush masks there is no
/// rotation or feather — a watermark is a rigid rectangle with a hard edge.
nonisolated struct WatermarkGeometry: Codable, Sendable, Equatable {
    var centerX: Double = 1.0
    var centerY: Double = 1.0
    var sizeDimension: WatermarkDimension = .width
    var sizeUnit: WatermarkSizeUnit = .percent
    var sizeValue: Double = 20.0
    var marginUnit: WatermarkMarginUnit = .percent
    var marginValue: Double = 10.0

    /// Point-maps the center from sensor (XMP) frame to display frame under an EXIF
    /// orientation, mirroring `BrushMaskGeometry.transformedForDisplay`'s dab mapping — a
    /// watermark has no shape to reorient, so only its anchor point moves.
    func transformedForDisplay(orientation: Int) -> WatermarkGeometry {
        guard orientation > 1 else { return self }
        var result = self
        let mapped = Self.mapPoint(x: centerX, y: centerY, orientation: orientation)
        result.centerX = mapped.x
        result.centerY = mapped.y
        return result
    }

    /// Inverse of `transformedForDisplay`.
    func transformedForSensor(orientation: Int) -> WatermarkGeometry {
        let inverse: Int
        switch orientation {
        case 6: inverse = 8
        case 8: inverse = 6
        default: inverse = orientation
        }
        return transformedForDisplay(orientation: inverse)
    }

    /// Rigidly rotate the anchor point by `degrees` about the frame center (0.5, 0.5), to
    /// follow a crop STRAIGHTEN angle — mirrors `EllipseMaskGeometry.rotatedInDisplay`'s
    /// center rotation. `aspect` is the display frame's pixel width/height.
    func rotatedInDisplay(byDegrees degrees: Double, aspect: Double) -> WatermarkGeometry {
        guard abs(degrees) > 1e-12 else { return self }
        let a = aspect > 0 ? aspect : 1
        let rad = degrees * .pi / 180
        var result = self
        let dx = (centerX - 0.5) * a
        let dy = centerY - 0.5
        result.centerX = 0.5 + (dx * cos(rad) - dy * sin(rad)) / a
        result.centerY = 0.5 + (dx * sin(rad) + dy * cos(rad))
        return result
    }

    /// UV point mapping for each EXIF orientation, identical to `BrushMaskGeometry`'s.
    private static func mapPoint(x: Double, y: Double, orientation: Int) -> (x: Double, y: Double) {
        switch orientation {
        case 2: return (1 - x, y)
        case 3: return (1 - x, 1 - y)
        case 4: return (x, 1 - y)
        case 5: return (y, x)
        case 6: return (1 - y, x)
        case 7: return (1 - y, 1 - x)
        case 8: return (y, 1 - x)
        default: return (x, y)
        }
    }

    /// The watermark's rendered half-width/half-height in normalized UV (display frame),
    /// resolved from `sizeDimension`/`sizeUnit`/`sizeValue` plus the source asset's own
    /// aspect ratio (asset pixel width / pixel height). Shared by the CPU-side drag-clamp
    /// math and the GPU param upload, so the two never disagree about where the
    /// watermark's edges actually are.
    func renderedHalfExtentUV(assetAspect: Double, imageWidth: Double, imageHeight: Double) -> (halfWidthUV: Double, halfHeightUV: Double) {
        guard imageWidth > 0, imageHeight > 0, assetAspect > 0 else { return (0, 0) }
        let widthPixels: Double
        let heightPixels: Double
        switch (sizeDimension, sizeUnit) {
        case (.width, .pixel):
            widthPixels = max(sizeValue, 0)
            heightPixels = widthPixels / assetAspect
        case (.width, .percent):
            widthPixels = imageWidth * max(sizeValue, 0) / 100
            heightPixels = widthPixels / assetAspect
        case (.height, .pixel):
            heightPixels = max(sizeValue, 0)
            widthPixels = heightPixels * assetAspect
        case (.height, .percent):
            heightPixels = imageHeight * max(sizeValue, 0) / 100
            widthPixels = heightPixels * assetAspect
        }
        return (widthPixels / imageWidth / 2, heightPixels / imageHeight / 2)
    }

    /// The margin inset in normalized UV, independently on each axis (a percent margin is a
    /// percentage of that axis's own image dimension, matching how crop insets work).
    func marginInsetUV(imageWidth: Double, imageHeight: Double) -> (x: Double, y: Double) {
        guard imageWidth > 0, imageHeight > 0 else { return (0, 0) }
        switch marginUnit {
        case .pixel:
            return (max(marginValue, 0) / imageWidth, max(marginValue, 0) / imageHeight)
        case .percent:
            let fraction = max(marginValue, 0) / 100
            return (fraction, fraction)
        }
    }

    /// The UV-space rectangle the center may occupy without the watermark crossing the
    /// margin-inset boundary on any edge. Degenerates to the single center point
    /// (0.5, 0.5) if the margin + half-extent leave no room.
    func safeAreaRect(assetAspect: Double, imageWidth: Double, imageHeight: Double) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let half = renderedHalfExtentUV(assetAspect: assetAspect, imageWidth: imageWidth, imageHeight: imageHeight)
        let margin = marginInsetUV(imageWidth: imageWidth, imageHeight: imageHeight)
        var minX = margin.x + half.halfWidthUV
        var maxX = 1 - margin.x - half.halfWidthUV
        var minY = margin.y + half.halfHeightUV
        var maxY = 1 - margin.y - half.halfHeightUV
        if minX > maxX { minX = 0.5; maxX = 0.5 }
        if minY > maxY { minY = 0.5; maxY = 0.5 }
        return (minX, maxX, minY, maxY)
    }

    /// Clamp `centerX`/`centerY` into `safeAreaRect`, returning a corrected copy.
    func clamped(assetAspect: Double, imageWidth: Double, imageHeight: Double) -> WatermarkGeometry {
        let rect = safeAreaRect(assetAspect: assetAspect, imageWidth: imageWidth, imageHeight: imageHeight)
        var result = self
        result.centerX = min(max(centerX, rect.minX), rect.maxX)
        result.centerY = min(max(centerY, rect.minY), rect.maxY)
        return result
    }

    /// The UV-space rectangle the watermark's own rendered EDGE may not cross — i.e. the
    /// margin inset directly from the image edges, independent of the watermark's own size.
    /// This is what the edit-view overlay draws as the dashed margin boundary: unlike
    /// `safeAreaRect` (where the CENTER may travel, which sits margin+half-extent inside the
    /// image), this rect's boundary IS where the watermark's visible border sits when pushed
    /// as close to the image edge as the margin allows.
    func marginBoundaryRect(imageWidth: Double, imageHeight: Double) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let margin = marginInsetUV(imageWidth: imageWidth, imageHeight: imageHeight)
        return (margin.x, 1 - margin.x, margin.y, 1 - margin.y)
    }
}

/// A verbatim-preserved Camera Raw mask value node — a Codable/Sendable mirror of the subset of
/// `XMPValue` shapes an unparseable `crs` correction can contain (simple, rdf:Seq of strings,
/// single struct, or rdf:Bag/Seq of structs). Kept model-side (no SwiftExif dependency) so the
/// preserved data survives through the model; converted back to `XMPValue` at the write boundary.
nonisolated indirect enum PreservedXMPNode: Codable, Sendable, Equatable {
    case string(String)
    case strings([String])
    case structure([String: PreservedXMPNode])
    case items([[String: PreservedXMPNode]])
}

/// A Camera Raw `MaskGroupBasedCorrections` entry this app can't model or edit — an ACR
/// erase-brush `MaskBrushTable` blob, or any future Adobe mask type. Its full nested field set
/// is kept verbatim (keys are namespace-prefixed, as parsed) so a develop save re-emits it
/// byte-for-byte instead of silently dropping it. Without this, the next `replaceCameraRawBlock`
/// crs-block rewrite would delete it permanently — a real data-loss bug for files edited with an
/// ACR erase brush. Per-image (bound to specific pixels): excluded from paste/merge like as-shot WB.
nonisolated struct PreservedMaskCorrection: Codable, Sendable, Equatable {
    var fields: [String: PreservedXMPNode]
}

nonisolated struct MaskAdjustment: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Mask 1"
    var enabled: Bool = true
    var inverted: Bool = false
    var amount: Double = 1.0
    var geometry: EllipseMaskGeometry = EllipseMaskGeometry()
    /// When non-nil, this is a freeform paint mask and `geometry` (ellipse) is unused;
    /// nil means an analytic ellipse mask. Kept as a sibling field (like `anonymizer`) rather
    /// than making the geometry a polymorphic sum type, so every `mask.geometry` call site is
    /// untouched.
    var brush: BrushMaskGeometry?

    var exposure: Double?
    var contrast: Int?
    var highlights: Int?
    var shadows: Int?
    var whites: Int?
    var blacks: Int?
    var saturation: Int?
    var vibrance: Int?
    var temperature: Double?
    var tint: Double?
    var anonymizer: AnonymizerSettings?

    var hasAdjustments: Bool {
        exposure != nil || contrast != nil || highlights != nil
            || shadows != nil || whites != nil || blacks != nil
            || saturation != nil || vibrance != nil
            || temperature != nil || tint != nil
            || (anonymizer?.isEmpty == false)
    }

    func transformedForDisplay(orientation: Int, sensorAspect: Double) -> MaskAdjustment {
        var result = self
        result.geometry = geometry.transformedForDisplay(orientation: orientation, sensorAspect: sensorAspect)
        if let brush {
            result.brush = brush.transformedForDisplay(orientation: orientation)
        }
        return result
    }

    func transformedForSensor(orientation: Int, displayAspect: Double) -> MaskAdjustment {
        var result = self
        result.geometry = geometry.transformedForSensor(orientation: orientation, displayAspect: displayAspect)
        if let brush {
            result.brush = brush.transformedForSensor(orientation: orientation)
        }
        return result
    }

    /// The layer kind for icon/affordance purposes — a brush mask when `brush` is set,
    /// otherwise an analytic ellipse.
    var layerKind: LayerKind { brush != nil ? .brushMask : .ellipseMask }
}

/// One watermark layer instance — references a named PNG in the reusable Watermark
/// library (`WatermarkStore`) by `libraryAssetID` and carries only positioning, sizing,
/// and opacity. Deliberately has no color/tonal fields (unlike `MaskAdjustment`) since a
/// watermark layer has no color controls.
nonisolated struct WatermarkLayer: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Watermark 1"
    var enabled: Bool = true
    var libraryAssetID: UUID
    var geometry: WatermarkGeometry = WatermarkGeometry()
    var opacity: Double = 1.0

    var layerKind: LayerKind { .watermark }

    func transformedForDisplay(orientation: Int) -> WatermarkLayer {
        var result = self
        result.geometry = geometry.transformedForDisplay(orientation: orientation)
        return result
    }

    func transformedForSensor(orientation: Int) -> WatermarkLayer {
        var result = self
        result.geometry = geometry.transformedForSensor(orientation: orientation)
        return result
    }
}

/// Visual classification of an editing layer, used to pick an icon in the layer strip.
/// Extend with new cases as mask geometry types are added — keep it the single source
/// of truth for layer→icon mapping so new kinds don't require touching the UI call sites.
nonisolated enum LayerKind: Sendable, Equatable {
    case global
    case ellipseMask
    case brushMask
    case watermark

    /// SF Symbol name representing this layer kind.
    var systemImage: String {
        switch self {
        case .global:      return "circle.lefthalf.filled"
        case .ellipseMask: return "circle.dashed"
        case .brushMask:   return "paintbrush.pointed"
        case .watermark:   return "seal"
        }
    }
}

/// A stable reference to a node in the editing layer chain. `.global` is the single
/// global-adjustment node; `.mask` points at a `MaskAdjustment` by its UUID (stable across
/// reordering, unlike an array index); `.watermark` points at a `WatermarkLayer` the same
/// way. Encoded as a compact string for clean JSON sidecars: `"global"`, `"mask:<uuid>"`,
/// or `"watermark:<uuid>"`.
nonisolated enum LayerRef: Sendable, Equatable, Hashable, Codable {
    case global
    case mask(UUID)
    case watermark(UUID)

    /// Parses the compact string token grammar shared by the `Codable` conformance below
    /// and the XMP `aaphoto:LayerOrder` dict-based parser (`IPTCMetadataParsing`).
    init?(token: String) {
        if token == "global" {
            self = .global
        } else if token.hasPrefix("mask:"), let uuid = UUID(uuidString: String(token.dropFirst(5))) {
            self = .mask(uuid)
        } else if token.hasPrefix("watermark:"), let uuid = UUID(uuidString: String(token.dropFirst(10))) {
            self = .watermark(uuid)
        } else {
            return nil
        }
    }

    var token: String {
        switch self {
        case .global:             return "global"
        case .mask(let id):       return "mask:\(id.uuidString)"
        case .watermark(let id):  return "watermark:\(id.uuidString)"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = LayerRef(token: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized LayerRef \"\(raw)\""))
        }
        self = ref
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

nonisolated struct HSLColorAdjustment: Codable, Sendable, Equatable {
    var saturation: Int?    // -100..+100
    var luminance: Int?     // -100..+100 ("Density" in UI)
    var hueShift: Int?      // -25..+25 (maps to ±7.5°)

    nonisolated var isEmpty: Bool {
        (saturation ?? 0) == 0 && (luminance ?? 0) == 0 && (hueShift ?? 0) == 0
    }
}

nonisolated struct HSLAdjustments: Codable, Sendable, Equatable {
    var red: HSLColorAdjustment?
    var yellow: HSLColorAdjustment?
    var green: HSLColorAdjustment?
    var cyan: HSLColorAdjustment?
    var blue: HSLColorAdjustment?
    var magenta: HSLColorAdjustment?
    var skinTone: HSLColorAdjustment?

    nonisolated var isEmpty: Bool {
        (red?.isEmpty ?? true) && (yellow?.isEmpty ?? true)
            && (green?.isEmpty ?? true) && (cyan?.isEmpty ?? true)
            && (blue?.isEmpty ?? true) && (magenta?.isEmpty ?? true)
            && (skinTone?.isEmpty ?? true)
    }
}

/// Multi-layer redaction effect (random distortion + blur + mosaic sampled in one pass,
/// or a hard "Black Out") — not an ACR/Lightroom concept, persisted as an app-private
/// XMP extension. `amount` is a 0...100 strength (nil/0 means off); `blackOut` overrides
/// the layered effect with full opaque redaction.
nonisolated struct AnonymizerSettings: Codable, Sendable, Equatable {
    var amount: Double?
    var blackOut: Bool?

    nonisolated var isEmpty: Bool {
        (amount ?? 0) <= 0 && (blackOut ?? false) == false
    }
}

nonisolated struct CameraRawSettings: Codable, Sendable, Equatable {
    var version: String?
    var processVersion: String?
    var whiteBalance: String?
    var temperature: Int?
    var tint: Int?
    var incrementalTemperature: Int?
    var incrementalTint: Int?
    var exposure2012: Double?
    var contrast2012: Int?
    var highlights2012: Int?
    var shadows2012: Int?
    var whites2012: Int?
    var blacks2012: Int?
    var saturation: Int?
    var vibrance: Int?
    var hasSettings: Bool?
    var crop: CameraRawCrop?
    var hdrEditMode: Int?
    var hdrMaxValue: String?
    var sdrBrightness: Int?
    var sdrContrast: Int?
    var sdrClarity: Int?
    var sdrHighlights: Int?
    var sdrShadows: Int?
    var sdrWhites: Int?
    var sdrBlend: Int?
    var toneCurve: ToneCurve?
    var localAdjustments: [MaskAdjustment]?
    /// Watermark layers — app-private, no Adobe Camera Raw equivalent. Persisted separately
    /// from `localAdjustments` under `aaphoto:WatermarkLayers` (see `XMPDataBuilder`).
    var watermarkLayers: [WatermarkLayer]?
    var hslAdjustments: HSLAdjustments?
    var anonymizer: AnonymizerSettings?

    /// Camera Raw mask corrections this app can't model (ACR erase-brush `MaskBrushTable`
    /// blobs, future Adobe mask types). Kept verbatim and re-emitted on write so a develop
    /// save doesn't permanently drop them — see `PreservedMaskCorrection`. Per-image: excluded
    /// from `merged()`/paste operations.
    var unparsedMaskCorrections: [PreservedMaskCorrection]?

    /// Explicit processing order of the editing layer chain, interleaving the global
    /// adjustment node among the masks. `nil` (all legacy edits) means the canonical
    /// order `[.global] + masks`, which reproduces the historical "global is the fixed
    /// base, masks on top in array order" behavior exactly. Resolve via
    /// `resolvedLayerOrder()` rather than reading this directly — it sanitizes stale refs.
    var layerOrder: [LayerRef]?

    /// As-shot neutral white balance from the RAW decoder (CIRAWFilter.neutralTemperature/Tint).
    /// Used as the reference point for white balance correction in renderOffscreen().
    /// Per-image metadata — excluded from isEmpty, merged(), and paste operations.
    var asShotNeutralTemperature: Double?
    var asShotNeutralTint: Double?

    /// True when the source pixels are a scene-referred RAW decode with highlight data
    /// above SDR white (RAW files always decode with full EDR headroom). Tells the tone
    /// pipeline to apply the SDR output tonemap when hdrEditMode is off, so super-white
    /// detail rolls off smoothly and stays recoverable via Exposure/Highlights.
    /// Render-time only — set on local copies at decode sites, never persisted; excluded
    /// from isEmpty, merged(), and paste operations like the as-shot fields above.
    var sourceHasHDRHeadroom: Bool?

    var isEmpty: Bool {
        version == nil
            && processVersion == nil
            && whiteBalance == nil
            && temperature == nil
            && tint == nil
            && incrementalTemperature == nil
            && incrementalTint == nil
            && exposure2012 == nil
            && contrast2012 == nil
            && highlights2012 == nil
            && shadows2012 == nil
            && whites2012 == nil
            && blacks2012 == nil
            && saturation == nil
            && vibrance == nil
            && hasSettings == nil
            && (crop?.isEmpty ?? true)
            && hdrEditMode == nil
            && hdrMaxValue == nil
            && sdrBrightness == nil
            && sdrContrast == nil
            && sdrClarity == nil
            && sdrHighlights == nil
            && sdrShadows == nil
            && sdrWhites == nil
            && sdrBlend == nil
            && (toneCurve?.isEmpty ?? true)
            && (localAdjustments?.isEmpty ?? true)
            && (watermarkLayers?.isEmpty ?? true)
            && (hslAdjustments?.isEmpty ?? true)
            && (anonymizer?.isEmpty ?? true)
            && (unparsedMaskCorrections?.isEmpty ?? true)
    }

    /// True when the settings contain at least one edit the user can see. Unlike
    /// `isEmpty`, a full-frame identity crop (from merely opening the crop tool) does
    /// not count. Use for edit-badge decisions only — not for write/merge gating.
    var hasEffectiveEdits: Bool {
        if isEmpty { return false }
        var withoutCrop = self
        withoutCrop.crop = nil
        if !withoutCrop.isEmpty { return true }
        return crop?.isEffectiveCrop ?? false
    }

    func merged(preferring override: CameraRawSettings) -> CameraRawSettings {
        var result = self
        if let value = override.version, !value.isEmpty { result.version = value }
        if let value = override.processVersion, !value.isEmpty { result.processVersion = value }
        if let value = override.whiteBalance, !value.isEmpty { result.whiteBalance = value }
        if let value = override.temperature { result.temperature = value }
        if let value = override.tint { result.tint = value }
        if let value = override.incrementalTemperature { result.incrementalTemperature = value }
        if let value = override.incrementalTint { result.incrementalTint = value }
        if let value = override.exposure2012 { result.exposure2012 = value }
        if let value = override.contrast2012 { result.contrast2012 = value }
        if let value = override.highlights2012 { result.highlights2012 = value }
        if let value = override.shadows2012 { result.shadows2012 = value }
        if let value = override.whites2012 { result.whites2012 = value }
        if let value = override.blacks2012 { result.blacks2012 = value }
        if let value = override.saturation { result.saturation = value }
        if let value = override.vibrance { result.vibrance = value }
        if let value = override.hasSettings { result.hasSettings = value }
        if let crop = override.crop {
            if let existing = result.crop {
                result.crop = existing.merged(preferring: crop)
            } else {
                result.crop = crop
            }
        }
        if let value = override.hdrEditMode { result.hdrEditMode = value }
        if let value = override.hdrMaxValue, !value.isEmpty { result.hdrMaxValue = value }
        if let value = override.sdrBrightness { result.sdrBrightness = value }
        if let value = override.sdrContrast { result.sdrContrast = value }
        if let value = override.sdrClarity { result.sdrClarity = value }
        if let value = override.sdrHighlights { result.sdrHighlights = value }
        if let value = override.sdrShadows { result.sdrShadows = value }
        if let value = override.sdrWhites { result.sdrWhites = value }
        if let value = override.sdrBlend { result.sdrBlend = value }
        if let value = override.toneCurve { result.toneCurve = value }
        if let value = override.localAdjustments { result.localAdjustments = value }
        if let value = override.watermarkLayers { result.watermarkLayers = value }
        if let value = override.hslAdjustments { result.hslAdjustments = value }
        if let value = override.anonymizer { result.anonymizer = value }
        if let value = override.layerOrder { result.layerOrder = value }
        // Per-image, but merged() combines records for the SAME image (embedded + sidecar),
        // so prefer the override's copy rather than dropping it.
        if let value = override.unparsedMaskCorrections { result.unparsedMaskCorrections = value }
        return result
    }

    /// The processing order of the layer chain, sanitized against the current masks and
    /// watermark layers. Drops refs to layers that no longer exist, appends any layers
    /// missing from the stored order (new layers land at the end), and guarantees exactly
    /// one `.global` (prepended if the stored order somehow lacks it). When `layerOrder` is
    /// nil this returns the canonical `[.global] + masks + watermarks` order — identical to
    /// legacy rendering when there are no watermark layers.
    func resolvedLayerOrder() -> [LayerRef] {
        let masks = localAdjustments ?? []
        let watermarks = watermarkLayers ?? []
        let maskIDs = masks.map(\.id)
        let watermarkIDs = watermarks.map(\.id)
        guard let stored = layerOrder, !stored.isEmpty else {
            return [.global] + maskIDs.map(LayerRef.mask) + watermarkIDs.map(LayerRef.watermark)
        }
        let validMaskIDs = Set(maskIDs)
        let validWatermarkIDs = Set(watermarkIDs)
        var seenMaskIDs = Set<UUID>()
        var seenWatermarkIDs = Set<UUID>()
        var sawGlobal = false
        var result: [LayerRef] = []
        for ref in stored {
            switch ref {
            case .global:
                guard !sawGlobal else { continue }   // collapse duplicate globals
                sawGlobal = true
                result.append(.global)
            case .mask(let id):
                guard validMaskIDs.contains(id), !seenMaskIDs.contains(id) else { continue }
                seenMaskIDs.insert(id)
                result.append(.mask(id))
            case .watermark(let id):
                guard validWatermarkIDs.contains(id), !seenWatermarkIDs.contains(id) else { continue }
                seenWatermarkIDs.insert(id)
                result.append(.watermark(id))
            }
        }
        if !sawGlobal { result.insert(.global, at: 0) }
        // Append any layers not referenced by the stored order (e.g. just added).
        for id in maskIDs where !seenMaskIDs.contains(id) {
            result.append(.mask(id))
        }
        for id in watermarkIDs where !seenWatermarkIDs.contains(id) {
            result.append(.watermark(id))
        }
        return result
    }

    /// True when persistence needs the fully-explicit `aaphoto:LayerOrder` XMP array
    /// rather than the legacy masks-in-render-order + `GlobalLayerIndex` encoding. The
    /// legacy encoding can only place a single global node among an otherwise-homogeneous
    /// mask list by reconstructing it from one int; once a watermark layer exists there are
    /// 3 independently-positioned kinds, which that int can no longer reconstruct.
    var needsExplicitLayerOrderPersistence: Bool {
        !(watermarkLayers?.isEmpty ?? true)
    }

    // MARK: - Persistence helpers for the layer chain
    //
    // ACR's schema can't express the global node's position, so persistence (both the .xmp
    // sidecar and the embedded-XMP writer) stores masks in render-stack order and adds only
    // the global node's index. These pure helpers are the shared source of truth for that.

    /// Masks reordered to match the resolved chain's mask sub-order (ACR render-stack order).
    /// Returns `localAdjustments` unchanged when there's no custom order.
    func masksInRenderOrder() -> [MaskAdjustment]? {
        guard let masks = localAdjustments, layerOrder != nil else { return localAdjustments }
        let byID = Dictionary(masks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [MaskAdjustment] = []
        for case .mask(let id) in resolvedLayerOrder() {
            if let mask = byID[id] { ordered.append(mask) }
        }
        return ordered.isEmpty ? localAdjustments : ordered
    }

    /// Number of masks that precede the global node in the resolved chain. nil when there's
    /// no custom order; 0 means global-first (canonical) and need not be persisted.
    func globalLayerIndex() -> Int? {
        guard layerOrder != nil else { return nil }
        let resolved = resolvedLayerOrder()
        guard let gi = resolved.firstIndex(of: .global) else { return 0 }
        return resolved[..<gi].reduce(0) { count, ref in
            if case .mask = ref { return count + 1 }
            return count
        }
    }

    /// Rebuilds a `layerOrder` from masks (already in render-stack order) plus the stored
    /// global position. nil `globalIndex` ⇒ nil (canonical global-first).
    static func layerOrder(masks: [MaskAdjustment]?, globalIndex: Int?) -> [LayerRef]? {
        guard let globalIndex else { return nil }
        var order = (masks ?? []).map { LayerRef.mask($0.id) }
        order.insert(.global, at: max(0, min(globalIndex, order.count)))
        return order
    }

    /// Mask geometry is stored in the sensor (XMP) frame, but rendering happens
    /// on display-oriented pixels — returns a copy with `localAdjustments`
    /// transformed into the display frame (the crop is handled separately by
    /// `CameraRawCrop.transformedForDisplay` at its consumers).
    /// `displayAspect` is the oriented pixel width/height of the render target.
    func masksTransformedForDisplay(orientation: Int, displayAspect: Double) -> CameraRawSettings {
        guard orientation > 1, let masks = localAdjustments, !masks.isEmpty else { return self }
        let sensorAspect = orientation >= 5 && displayAspect > 0 ? 1 / displayAspect : displayAspect
        var result = self
        result.localAdjustments = masks.map {
            $0.transformedForDisplay(orientation: orientation, sensorAspect: sensorAspect)
        }
        return result
    }

    /// Watermark geometry is stored in the sensor (XMP) frame like mask geometry, but
    /// only carries a point (no oriented-corner box to decode), so unlike
    /// `masksTransformedForDisplay` this needs no aspect term.
    func watermarksTransformedForDisplay(orientation: Int) -> CameraRawSettings {
        guard orientation > 1, let layers = watermarkLayers, !layers.isEmpty else { return self }
        var result = self
        result.watermarkLayers = layers.map { $0.transformedForDisplay(orientation: orientation) }
        return result
    }

    /// Canonical serialization of the *simple* (non-array) crs develop settings to a
    /// metadata write-key dictionary in ACR's value style (signed ints, +exposure,
    /// 6-decimal crop). Tone curves and masks are array-typed and written separately by
    /// the engine (`applyToneCurves` / `applyMasks`). HSL is sidecar-only and not emitted
    /// here. `imageAspect` is read only for an angled crop (un-rotated-frame ACR encoding);
    /// the conversion is the identity at angle 0, so the closure is left uncalled otherwise.
    nonisolated func developWriteFields(imageAspect: () -> Double? = { nil }) -> [MetadataFieldKey: String] {
        func signedInt(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
        func signedDouble(_ value: Double, precision: Int) -> String {
            let absValue = String(format: "%.\(precision)f", abs(value))
            if value > 0 { return "+\(absValue)" }
            if value < 0 { return "-\(absValue)" }
            return absValue
        }

        var fields: [MetadataFieldKey: String] = [:]
        // ACR requires Version and ProcessVersion to recognize settings.
        fields[.crsVersion] = version ?? "15.4"
        fields[.crsProcessVersion] = processVersion ?? "15.4"

        // Present values are written; nils are emitted empty so a partial reset clears
        // any stale value rather than leaving it behind.
        fields[.crsWhiteBalance] = whiteBalance ?? ""
        fields[.crsTemperature] = temperature.map(String.init) ?? ""
        fields[.crsTint] = tint.map(signedInt) ?? ""
        fields[.crsIncrementalTemperature] = incrementalTemperature.map(signedInt) ?? ""
        fields[.crsIncrementalTint] = incrementalTint.map(signedInt) ?? ""
        fields[.crsExposure2012] = exposure2012.map { signedDouble($0, precision: 2) } ?? ""
        fields[.crsContrast2012] = contrast2012.map(signedInt) ?? ""
        fields[.crsHighlights2012] = highlights2012.map(signedInt) ?? ""
        fields[.crsShadows2012] = shadows2012.map(signedInt) ?? ""
        fields[.crsWhites2012] = whites2012.map(signedInt) ?? ""
        fields[.crsBlacks2012] = blacks2012.map(signedInt) ?? ""
        fields[.crsSaturation] = saturation.map(signedInt) ?? ""
        fields[.crsVibrance] = vibrance.map(signedInt) ?? ""

        let settingsPresent = hasSettings ?? !isEmpty
        fields[.crsHasSettings] = settingsPresent ? "True" : "False"

        if let internalCrop = crop {
            // crs crop fields carry Adobe's un-rotated-frame corner encoding, not the
            // app's upright rect — convert at this write boundary (identity at angle 0).
            let acrCrop = abs(internalCrop.angle ?? 0) > 0.0001
                ? internalCrop.encodedForACR(aspect: imageAspect())
                : internalCrop
            fields[.crsCropTop] = acrCrop.top.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropLeft] = acrCrop.left.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropBottom] = acrCrop.bottom.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropRight] = acrCrop.right.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropAngle] = acrCrop.angle.map { String(format: "%.6f", $0) } ?? ""
            let hasCrop = acrCrop.hasCrop ?? !acrCrop.isEmpty
            fields[.crsHasCrop] = hasCrop ? "True" : "False"
            fields[.crsCropConstrainToWarp] = "0"
            fields[.crsCropConstrainToUnitSquare] = "1"
        } else {
            fields[.crsCropTop] = ""
            fields[.crsCropLeft] = ""
            fields[.crsCropBottom] = ""
            fields[.crsCropRight] = ""
            fields[.crsCropAngle] = ""
            fields[.crsHasCrop] = "False"
            fields[.crsCropConstrainToWarp] = ""
            fields[.crsCropConstrainToUnitSquare] = ""
        }

        fields[.crsHDREditMode] = hdrEditMode.map(String.init) ?? ""
        fields[.crsHDRMaxValue] = hdrMaxValue ?? ""
        fields[.crsSDRBrightness] = sdrBrightness.map(signedInt) ?? ""
        fields[.crsSDRContrast] = sdrContrast.map(signedInt) ?? ""
        fields[.crsSDRClarity] = sdrClarity.map(signedInt) ?? ""
        fields[.crsSDRHighlights] = sdrHighlights.map(signedInt) ?? ""
        fields[.crsSDRShadows] = sdrShadows.map(signedInt) ?? ""
        fields[.crsSDRWhites] = sdrWhites.map(signedInt) ?? ""
        fields[.crsSDRBlend] = sdrBlend.map(signedInt) ?? ""
        return fields
    }
}

extension CameraRawCrop {
    /// Transform crop from sensor (XMP) orientation to display orientation.
    nonisolated func transformedForDisplay(orientation: Int) -> CameraRawCrop {
        // Normalize: Adobe XMP can store top > bottom or left > right
        let rawT = top ?? 0, rawL = left ?? 0, rawB = bottom ?? 1, rawR = right ?? 1
        let t = min(rawT, rawB), l = min(rawL, rawR), b = max(rawT, rawB), r = max(rawL, rawR)
        let (dt, dl, db, dr): (Double, Double, Double, Double)
        switch orientation {
        case 2: (dt, dl, db, dr) = (t, 1-r, b, 1-l)       // flip horizontal
        case 3: (dt, dl, db, dr) = (1-b, 1-r, 1-t, 1-l)   // rotate 180°
        case 4: (dt, dl, db, dr) = (1-b, l, 1-t, r)        // flip vertical
        case 5: (dt, dl, db, dr) = (l, t, r, b)             // transpose
        case 6: (dt, dl, db, dr) = (l, 1-b, r, 1-t)        // rotate 90° CW
        case 7: (dt, dl, db, dr) = (1-r, 1-b, 1-l, 1-t)    // transverse
        case 8: (dt, dl, db, dr) = (1-r, t, 1-l, b)         // rotate 90° CCW
        default: return self                                  // O=1 or unknown
        }
        return CameraRawCrop(top: dt, left: dl, bottom: db, right: dr, angle: angle, hasCrop: hasCrop)
    }

    /// Inverse: transform crop from display orientation back to sensor (XMP) orientation.
    nonisolated func transformedForSensor(orientation: Int) -> CameraRawCrop {
        // Normalize: ensure proper coordinate ordering
        let rawT = top ?? 0, rawL = left ?? 0, rawB = bottom ?? 1, rawR = right ?? 1
        let t = min(rawT, rawB), l = min(rawL, rawR), b = max(rawT, rawB), r = max(rawL, rawR)
        let (st, sl, sb, sr): (Double, Double, Double, Double)
        switch orientation {
        case 2: (st, sl, sb, sr) = (t, 1-r, b, 1-l)       // flip H is self-inverse
        case 3: (st, sl, sb, sr) = (1-b, 1-r, 1-t, 1-l)   // 180° is self-inverse
        case 4: (st, sl, sb, sr) = (1-b, l, 1-t, r)        // flip V is self-inverse
        case 5: (st, sl, sb, sr) = (l, t, r, b)             // transpose is self-inverse
        case 6: (st, sl, sb, sr) = (1-l, t, 1-r, b)        // inverse of 90° CW = 90° CCW
        case 7: (st, sl, sb, sr) = (1-r, 1-b, 1-l, 1-t)    // transverse is self-inverse
        case 8: (st, sl, sb, sr) = (l, 1-b, r, 1-t)        // inverse of 90° CCW = 90° CW
        default: return self
        }
        return CameraRawCrop(top: st, left: sl, bottom: sb, right: sr, angle: angle, hasCrop: hasCrop)
    }

    nonisolated func merged(preferring override: CameraRawCrop) -> CameraRawCrop {
        var result = self
        if let value = override.top { result.top = value }
        if let value = override.left { result.left = value }
        if let value = override.bottom { result.bottom = value }
        if let value = override.right { result.right = value }
        if let value = override.angle { result.angle = value }
        if let value = override.hasCrop { result.hasCrop = value }
        return result
    }
}

nonisolated struct DescriptionConflict: Sendable {
    let xmpDescription: String
    let iptcCaptionAbstract: String
}

nonisolated struct IPTCMetadata: Codable, Sendable, Equatable {
    // Priority fields (always visible)
    var title: String?
    var description: String?
    var extendedDescription: String?
    var keywords: [String]
    var personShown: [String]

    // Classification
    var digitalSourceType: DigitalSourceType?

    // Secondary fields (collapsible)
    var creator: String?
    var credit: String?
    var copyright: String?
    var jobId: String?
    var dateCreated: String?
    var captureDate: String?
    var city: String?
    var country: String?
    var event: String?

    // GPS
    var latitude: Double?
    var longitude: Double?

    // XMP managed alongside IPTC (persisted to JSON sidecar)
    var rating: Int?
    var label: String?

    // Camera raw / orientation — in-memory only, sourced from XMP, NOT persisted to JSON sidecar
    var cameraRaw: CameraRawSettings?
    var exifOrientation: Int?

    // Exclude cameraRaw and exifOrientation from JSON sidecar serialization.
    // These are sourced exclusively from XMP (embedded in image or XMP sidecar file).
    enum CodingKeys: String, CodingKey {
        case title, description, extendedDescription, keywords, personShown
        case digitalSourceType
        case creator, credit, copyright, jobId, dateCreated, captureDate
        case city, country, event
        case latitude, longitude
        case rating, label
    }

    init(
        title: String? = nil,
        description: String? = nil,
        extendedDescription: String? = nil,
        keywords: [String] = [],
        personShown: [String] = [],
        digitalSourceType: DigitalSourceType? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        creator: String? = nil,
        credit: String? = nil,
        copyright: String? = nil,
        jobId: String? = nil,
        dateCreated: String? = nil,
        captureDate: String? = nil,
        city: String? = nil,
        country: String? = nil,
        event: String? = nil,
        rating: Int? = nil,
        label: String? = nil,
        cameraRaw: CameraRawSettings? = nil,
        exifOrientation: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.extendedDescription = extendedDescription
        self.keywords = keywords
        self.personShown = personShown
        self.digitalSourceType = digitalSourceType
        self.latitude = latitude
        self.longitude = longitude
        self.creator = creator
        self.credit = credit
        self.copyright = copyright
        self.jobId = jobId
        self.dateCreated = dateCreated
        self.captureDate = captureDate
        self.city = city
        self.country = country
        self.event = event
        self.rating = rating
        self.label = label
        self.cameraRaw = cameraRaw
        self.exifOrientation = exifOrientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        extendedDescription = try container.decodeIfPresent(String.self, forKey: .extendedDescription)
        keywords = (try container.decodeIfPresent([String].self, forKey: .keywords) ?? []).uniqued()
        personShown = (try container.decodeIfPresent([String].self, forKey: .personShown) ?? []).uniqued()
        digitalSourceType = try container.decodeIfPresent(DigitalSourceType.self, forKey: .digitalSourceType)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
        dateCreated = try container.decodeIfPresent(String.self, forKey: .dateCreated)
        captureDate = try container.decodeIfPresent(String.self, forKey: .captureDate)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // cameraRaw and exifOrientation are not decoded — sourced from XMP only
    }
}

extension IPTCMetadata {
    /// Returns true if any user-facing IPTC fields differ between self and another metadata instance.
    func hasIPTCDifferences(from other: IPTCMetadata) -> Bool {
        title != other.title
            || description != other.description
            || extendedDescription != other.extendedDescription
            || keywords != other.keywords
            || personShown != other.personShown
            || digitalSourceType != other.digitalSourceType
            || creator != other.creator
            || credit != other.credit
            || copyright != other.copyright
            || jobId != other.jobId
            || city != other.city
            || country != other.country
            || event != other.event
    }

    /// Whether any descriptive (editor-managed) field carries a value. The field set
    /// mirrors `SidecarReconciliation.descriptiveFieldsDiffer` / `toOverwriteFields()`.
    /// A sidecar without descriptive content (e.g. develop-settings-only `.xmp` written
    /// by `saveCameraRawOnly`) is not an IPTC record and must never be treated as one —
    /// neither authoritatively on read nor as an overwrite source on export.
    nonisolated var hasDescriptiveContent: Bool {
        if let title, !title.isEmpty { return true }
        if let description, !description.isEmpty { return true }
        if let extendedDescription, !extendedDescription.isEmpty { return true }
        if !keywords.isEmpty { return true }
        if !personShown.isEmpty { return true }
        if digitalSourceType != nil { return true }
        if let creator, !creator.isEmpty { return true }
        if let credit, !credit.isEmpty { return true }
        if let copyright, !copyright.isEmpty { return true }
        if let jobId, !jobId.isEmpty { return true }
        if let dateCreated, !dateCreated.isEmpty { return true }
        if let city, !city.isEmpty { return true }
        if let country, !country.isEmpty { return true }
        if let event, !event.isEmpty { return true }
        return false
    }

    /// Photo Mechanic-style read of a sidecar record: the record's *descriptive* fields
    /// replace `self`'s wholesale — a field absent from the record stays cleared rather
    /// than inheriting the embedded value (unlike `merged(preferring:)`, which skips
    /// empties). Everything outside the descriptive domain keeps the additive merge:
    /// GPS, rating, label, capture date, Camera Raw, and orientation come from the
    /// record only when present.
    ///
    /// Only call this when `record.hasDescriptiveContent` — for develop-only sidecars
    /// use `merged(preferring:)` so embedded descriptive values show through.
    nonisolated func replacingDescriptiveFields(from record: IPTCMetadata) -> IPTCMetadata {
        var result = self

        result.title = record.title
        result.description = record.description
        result.extendedDescription = record.extendedDescription
        result.keywords = record.keywords
        result.personShown = record.personShown
        result.digitalSourceType = record.digitalSourceType
        result.creator = record.creator
        result.credit = record.credit
        result.copyright = record.copyright
        result.jobId = record.jobId
        result.dateCreated = record.dateCreated
        result.city = record.city
        result.country = record.country
        result.event = record.event

        if let value = record.captureDate, !value.isEmpty { result.captureDate = value }
        if let value = record.latitude { result.latitude = value }
        if let value = record.longitude { result.longitude = value }
        if let value = record.rating { result.rating = value }
        if let value = record.label, !value.isEmpty { result.label = value }
        if let recordCRS = record.cameraRaw, !recordCRS.isEmpty {
            if let existingCRS = result.cameraRaw {
                result.cameraRaw = existingCRS.merged(preferring: recordCRS)
            } else {
                result.cameraRaw = recordCRS
            }
        }
        if let recordOrientation = record.exifOrientation {
            result.exifOrientation = recordOrientation
        }

        return result
    }

    func merged(preferring override: IPTCMetadata) -> IPTCMetadata {
        var result = self

        if let value = override.title, !value.isEmpty { result.title = value }
        if let value = override.description, !value.isEmpty { result.description = value }
        if let value = override.extendedDescription, !value.isEmpty { result.extendedDescription = value }
        if !override.keywords.isEmpty { result.keywords = override.keywords }
        if !override.personShown.isEmpty { result.personShown = override.personShown }
        if let value = override.digitalSourceType { result.digitalSourceType = value }
        if let value = override.creator, !value.isEmpty { result.creator = value }
        if let value = override.credit, !value.isEmpty { result.credit = value }
        if let value = override.copyright, !value.isEmpty { result.copyright = value }
        if let value = override.jobId, !value.isEmpty { result.jobId = value }
        if let value = override.dateCreated, !value.isEmpty { result.dateCreated = value }
        if let value = override.captureDate, !value.isEmpty { result.captureDate = value }
        if let value = override.city, !value.isEmpty { result.city = value }
        if let value = override.country, !value.isEmpty { result.country = value }
        if let value = override.event, !value.isEmpty { result.event = value }
        if let value = override.latitude { result.latitude = value }
        if let value = override.longitude { result.longitude = value }
        if let value = override.rating { result.rating = value }
        if let value = override.label, !value.isEmpty { result.label = value }
        // CameraRaw: prefer override (XMP) when it has data
        if let overrideCRS = override.cameraRaw, !overrideCRS.isEmpty {
            if let existingCRS = result.cameraRaw {
                result.cameraRaw = existingCRS.merged(preferring: overrideCRS)
            } else {
                result.cameraRaw = overrideCRS
            }
        }
        if let overrideOrientation = override.exifOrientation {
            result.exifOrientation = overrideOrientation
        }

        return result
    }
}

extension IPTCMetadata {
    /// Convert editable IPTC fields to a metadata write-key dictionary.
    /// Excludes rating, label, cameraRaw, and orientation (managed separately).
    func toWriteFields() -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        if let v = title { fields[.headline] = v }
        if let v = description { fields[.description] = v }
        if let v = extendedDescription { fields[.extendedDescription] = v }
        if !keywords.isEmpty { fields[.subject] = keywords.joined(separator: ", ") }
        if !personShown.isEmpty { fields[.personInImage] = personShown.joined(separator: ", ") }
        if let v = digitalSourceType { fields[.digitalSourceType] = v.rawValue }
        if let v = creator { fields[.creator] = v }
        if let v = credit { fields[.credit] = v }
        if let v = copyright { fields[.rights] = v }
        if let v = jobId { fields[.transmissionReference] = v }
        if let v = dateCreated { fields[.dateCreated] = v }
        if let v = city { fields[.city] = v }
        if let v = country { fields[.country] = v }
        if let v = event { fields[.event] = v }
        if let lat = latitude, let lon = longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        }
        return fields
    }

    /// Like `toWriteFields()` but emits an empty string for every *cleared* descriptive
    /// field, so applying it replaces the target's descriptive metadata instead of only
    /// overlaying present values. Used on export, where the sidecar is the authoritative
    /// edited state: a field the user cleared must not survive from the source file's
    /// embedded metadata.
    ///
    /// GPS is deliberately additive (written only when present, never force-cleared):
    /// coordinates are technical source data that a sidecar — especially one written by
    /// an external tool, or with GPS in a format our parser can't read — may legitimately
    /// omit, and force-clearing would strip valid camera GPS from the export. Camera Raw,
    /// rating, and label are excluded (managed separately).
    func toOverwriteFields() -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        fields[.headline] = title ?? ""
        fields[.description] = description ?? ""
        fields[.extendedDescription] = extendedDescription ?? ""
        fields[.subject] = keywords.uniqued().joined(separator: ", ")
        fields[.personInImage] = personShown.uniqued().joined(separator: ", ")
        fields[.digitalSourceType] = digitalSourceType?.rawValue ?? ""
        fields[.creator] = creator ?? ""
        fields[.credit] = credit ?? ""
        fields[.rights] = copyright ?? ""
        fields[.transmissionReference] = jobId ?? ""
        fields[.dateCreated] = dateCreated ?? ""
        fields[.city] = city ?? ""
        fields[.country] = country ?? ""
        fields[.event] = event ?? ""
        if let lat = latitude, let lon = longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        }
        return fields
    }
}

nonisolated enum DigitalSourceType: String, Codable, CaseIterable, Sendable {
    case trainedAlgorithmicMedia = "trainedAlgorithmicMedia"
    case digitalCapture = "digitalCapture"
    case negativeFilm = "negativeFilm"
    case positiveFilm = "positiveFilm"
    case print = "print"
    case compositeCapture = "compositeCapture"
    case compositeSynthetic = "compositeSynthetic"
    case compositeWithTrainedAlgorithmicMedia = "compositeWithTrainedAlgorithmicMedia"

    var displayName: String {
        switch self {
        case .trainedAlgorithmicMedia: return "AI-Generated"
        case .digitalCapture: return "Digital Capture"
        case .negativeFilm: return "Scanned Negative"
        case .positiveFilm: return "Scanned Positive"
        case .print: return "Scanned Print"
        case .compositeCapture: return "Composite (Capture)"
        case .compositeSynthetic: return "Composite (Synthetic)"
        case .compositeWithTrainedAlgorithmicMedia: return "Composite (AI)"
        }
    }
}

// MARK: - Field Key (for upload metadata check)

extension IPTCMetadata {
    nonisolated enum FieldKey: String, CaseIterable, Codable, Sendable {
        case title, description, extendedDescription, keywords, personShown
        case creator, credit, copyright, jobId, dateCreated, city, country, event

        var displayName: String {
            switch self {
            case .title: return "Headline"
            case .description: return "Description"
            case .extendedDescription: return "Extended Description"
            case .keywords: return "Keywords"
            case .personShown: return "Person Shown"
            case .creator: return "Creator"
            case .credit: return "Credit"
            case .copyright: return "Copyright"
            case .jobId: return "Job ID"
            case .dateCreated: return "Date Created"
            case .city: return "City"
            case .country: return "Country"
            case .event: return "Event"
            }
        }

        func isEmpty(in metadata: IPTCMetadata) -> Bool {
            switch self {
            case .title: return metadata.title?.isEmpty ?? true
            case .description: return metadata.description?.isEmpty ?? true
            case .extendedDescription: return metadata.extendedDescription?.isEmpty ?? true
            case .keywords: return metadata.keywords.isEmpty
            case .personShown: return metadata.personShown.isEmpty
            case .creator: return metadata.creator?.isEmpty ?? true
            case .credit: return metadata.credit?.isEmpty ?? true
            case .copyright: return metadata.copyright?.isEmpty ?? true
            case .jobId: return metadata.jobId?.isEmpty ?? true
            case .dateCreated: return metadata.dateCreated?.isEmpty ?? true
            case .city: return metadata.city?.isEmpty ?? true
            case .country: return metadata.country?.isEmpty ?? true
            case .event: return metadata.event?.isEmpty ?? true
            }
        }

        static let defaultCheckedFields: Set<FieldKey> = [.title, .description, .creator, .copyright]

        /// Fields offered in the required-metadata settings and the browser's "Missing Field" filter.
        /// Excludes `dateCreated`, which has no editor in the metadata panel — requiring or filtering
        /// on it would be meaningless. The case itself is kept so stored prefs still decode.
        static let userSelectable: [FieldKey] = allCases.filter { $0 != .dateCreated }
    }
}

nonisolated extension Array where Element: Hashable {
    /// Returns the array with duplicates removed, preserving the order of first occurrences.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
