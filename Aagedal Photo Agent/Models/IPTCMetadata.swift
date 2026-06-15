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
        (master?.count ?? 0) <= 2
            && red == nil
            && green == nil
            && blue == nil
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

nonisolated struct MaskAdjustment: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Mask 1"
    var enabled: Bool = true
    var inverted: Bool = false
    var amount: Double = 1.0
    var geometry: EllipseMaskGeometry = EllipseMaskGeometry()

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

    var hasAdjustments: Bool {
        exposure != nil || contrast != nil || highlights != nil
            || shadows != nil || whites != nil || blacks != nil
            || saturation != nil || vibrance != nil
            || temperature != nil || tint != nil
    }

    func transformedForDisplay(orientation: Int, sensorAspect: Double) -> MaskAdjustment {
        var result = self
        result.geometry = geometry.transformedForDisplay(orientation: orientation, sensorAspect: sensorAspect)
        return result
    }

    func transformedForSensor(orientation: Int, displayAspect: Double) -> MaskAdjustment {
        var result = self
        result.geometry = geometry.transformedForSensor(orientation: orientation, displayAspect: displayAspect)
        return result
    }

    /// The layer kind for icon/affordance purposes. Today every mask is an ellipse;
    /// when more geometry types arrive, switch on `geometry` here.
    var layerKind: LayerKind { .ellipseMask }
}

/// Visual classification of an editing layer, used to pick an icon in the layer strip.
/// Extend with new cases as mask geometry types are added — keep it the single source
/// of truth for layer→icon mapping so new kinds don't require touching the UI call sites.
nonisolated enum LayerKind: Sendable, Equatable {
    case global
    case ellipseMask

    /// SF Symbol name representing this layer kind.
    var systemImage: String {
        switch self {
        case .global:      return "circle.lefthalf.filled"
        case .ellipseMask: return "circle.dashed"
        }
    }
}

/// A stable reference to a node in the editing layer chain. `.global` is the single
/// global-adjustment node; `.mask` points at a `MaskAdjustment` by its UUID (stable across
/// reordering, unlike an array index). Encoded as a compact string for clean JSON sidecars:
/// `"global"` or `"mask:<uuid>"`.
nonisolated enum LayerRef: Sendable, Equatable, Hashable, Codable {
    case global
    case mask(UUID)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "global" {
            self = .global
        } else if raw.hasPrefix("mask:"), let uuid = UUID(uuidString: String(raw.dropFirst(5))) {
            self = .mask(uuid)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized LayerRef \"\(raw)\""))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .global:        try container.encode("global")
        case .mask(let id):  try container.encode("mask:\(id.uuidString)")
        }
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
    var hslAdjustments: HSLAdjustments?

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
            && (hslAdjustments?.isEmpty ?? true)
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
        if let value = override.hslAdjustments { result.hslAdjustments = value }
        if let value = override.layerOrder { result.layerOrder = value }
        return result
    }

    /// The processing order of the layer chain, sanitized against the current masks.
    /// Drops refs to masks that no longer exist, appends any masks missing from the
    /// stored order (new masks land at the end), and guarantees exactly one `.global`
    /// (prepended if the stored order somehow lacks it). When `layerOrder` is nil this
    /// returns the canonical `[.global] + masks` order — identical to legacy rendering.
    func resolvedLayerOrder() -> [LayerRef] {
        let masks = localAdjustments ?? []
        let maskIDs = masks.map(\.id)
        guard let stored = layerOrder, !stored.isEmpty else {
            return [.global] + maskIDs.map(LayerRef.mask)
        }
        let validIDs = Set(maskIDs)
        var seenMaskIDs = Set<UUID>()
        var sawGlobal = false
        var result: [LayerRef] = []
        for ref in stored {
            switch ref {
            case .global:
                guard !sawGlobal else { continue }   // collapse duplicate globals
                sawGlobal = true
                result.append(.global)
            case .mask(let id):
                guard validIDs.contains(id), !seenMaskIDs.contains(id) else { continue }
                seenMaskIDs.insert(id)
                result.append(.mask(id))
            }
        }
        if !sawGlobal { result.insert(.global, at: 0) }
        // Append any masks not referenced by the stored order (e.g. just added).
        for id in maskIDs where !seenMaskIDs.contains(id) {
            result.append(.mask(id))
        }
        return result
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
    }
}

nonisolated extension Array where Element: Hashable {
    /// Returns the array with duplicates removed, preserving the order of first occurrences.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
