import Foundation
import SwiftExif
import os

/// Builds an `IPTCMetadata` value into a SwiftExif `XMPData` tree — the pure-Swift replacement
/// for the old NSXML (`XMLElement`) construction in `XMPSidecarService`. Used by the `.xmp`
/// sidecar writer; the crs/mask/tone encoders are shared with the embedded-file
/// `SwiftExifWriteEngine` so the two stores can't drift (see `applyMasks`/`applyToneCurves`).
///
/// Everything here is value-level and `nonisolated`: `XMPData` is a `Sendable` struct, so writing
/// is pure (no shared state, no libxml2) and safe from any thread.
enum XMPDataBuilder {

    /// App-private XMP namespace for settings ACR can't represent — the global node's position in
    /// the reorderable layer chain and app-native render controls. (crs uses `XMPNamespace.crs`.)
    nonisolated static let aaphotoNamespace = "http://aagedal.me/ns/photo/1.0/"

    // MARK: - Descriptive fields

    /// Write the IPTC/descriptive fields directly as XMP, mirroring the old NSXML `updateDescription`.
    /// Uses `XMPData`'s symmetric convenience setters where they exist, so `asMetadataDict` reads
    /// every field back identically. nil/empty ⇒ remove (clears propagate). Orientation,
    /// GPS and photoshop:DateCreated have no convenience setter, so they go through `setSimpleOrRemove`
    /// (and are read back via the service's `fillXMPOnlyGaps`).
    nonisolated static func applyDescriptive(_ m: IPTCMetadata, into xmp: inout XMPData) {
        // Title is written to BOTH photoshop:Headline and dc:title (the reader prefers Headline).
        xmp.headline = nilIfEmpty(m.title)
        xmp.title = nilIfEmpty(m.title)
        xmp.description = nilIfEmpty(m.description)
        xmp.extendedDescription = nilIfEmpty(m.extendedDescription)
        setArrayOrRemove(&xmp, m.keywords, namespace: XMPNamespace.dc, property: "subject")
        setArrayOrRemove(&xmp, m.personShown, namespace: XMPNamespace.iptcExt, property: "PersonInImage")
        xmp.rating = m.rating.map(Double.init)
        xmp.label = nilIfEmpty(m.label)
        xmp.digitalSourceType = nilIfEmpty(m.digitalSourceType?.rawValue)
        setArrayOrRemove(&xmp, m.creator.map { [$0] } ?? [], namespace: XMPNamespace.dc, property: "creator")
        xmp.credit = nilIfEmpty(m.credit)
        xmp.jobId = nilIfEmpty(m.jobId)
        xmp.rights = nilIfEmpty(m.copyright)
        // photoshop:DateCreated (the IPTC date) — distinct from xmp:CreateDate; no convenience setter.
        setSimpleOrRemove(&xmp, m.dateCreated, namespace: XMPNamespace.photoshop, property: "DateCreated")
        xmp.city = nilIfEmpty(m.city)
        xmp.country = nilIfEmpty(m.country)
        xmp.event = nilIfEmpty(m.event)

        // GPS is additive/paired: write both as %.6f decimal degrees (the old wire format), or clear both.
        if let lat = m.latitude, let lon = m.longitude {
            xmp.setValue(.simple(String(format: "%.6f", lat)), namespace: XMPNamespace.exif, property: "GPSLatitude")
            xmp.setValue(.simple(String(format: "%.6f", lon)), namespace: XMPNamespace.exif, property: "GPSLongitude")
        } else {
            xmp.removeValue(namespace: XMPNamespace.exif, property: "GPSLatitude")
            xmp.removeValue(namespace: XMPNamespace.exif, property: "GPSLongitude")
        }

        // Orientation to BOTH tiff (authoritative on read) and exif, in lockstep. nil clears both.
        let orientation = m.exifOrientation.map(String.init)
        Logger(subsystem: "com.aagedal.photo-agent", category: "XMPWrite")
            .info("sidecar write orientation=\(orientation ?? "nil", privacy: .public)")
        setSimpleOrRemove(&xmp, orientation, namespace: XMPNamespace.tiff, property: "Orientation")
        setSimpleOrRemove(&xmp, orientation, namespace: XMPNamespace.exif, property: "Orientation")
    }

    // MARK: - Camera Raw (crs) block

    /// Write the develop (`crs`) block, mirroring the old NSXML `updateCameraRawSettings`. nil ⇒
    /// clear the block. Managed fields are set/removed individually (preserving any unmodeled
    /// third-party crs props on a settings write, exactly as the old writer did). `imageAspect` is
    /// the sensor-frame aspect for the ACR angled-crop conversion (identity at angle 0).
    nonisolated static func applyCameraRaw(_ settings: CameraRawSettings?, imageAspect: Double?, into xmp: inout XMPData) {
        guard let settings else {
            removeCRSBlock(&xmp)
            return
        }

        // ACR requires Version + ProcessVersion to recognize the block.
        setCRS(&xmp, "Version", settings.version ?? "15.4")
        setCRS(&xmp, "ProcessVersion", settings.processVersion ?? "15.4")
        setCRS(&xmp, "WhiteBalance", settings.whiteBalance)
        setCRS(&xmp, "Temperature", settings.temperature.map(String.init))
        setCRS(&xmp, "Tint", settings.tint.map(formatSignedInt))
        setCRS(&xmp, "IncrementalTemperature", settings.incrementalTemperature.map(formatSignedInt))
        setCRS(&xmp, "IncrementalTint", settings.incrementalTint.map(formatSignedInt))
        setCRS(&xmp, "Exposure2012", settings.exposure2012.map { formatSignedDouble($0, precision: 2) })
        setCRS(&xmp, "Contrast2012", settings.contrast2012.map(formatSignedInt))
        setCRS(&xmp, "Highlights2012", settings.highlights2012.map(formatSignedInt))
        setCRS(&xmp, "Shadows2012", settings.shadows2012.map(formatSignedInt))
        setCRS(&xmp, "Whites2012", settings.whites2012.map(formatSignedInt))
        setCRS(&xmp, "Blacks2012", settings.blacks2012.map(formatSignedInt))
        setCRS(&xmp, "Saturation", settings.saturation.map(formatSignedInt))
        setCRS(&xmp, "Vibrance", settings.vibrance.map(formatSignedInt))
        setAppPrivate(&xmp, "GlobalDensity", settings.globalDensity.map(formatSignedInt))
        setAppPrivate(&xmp, "FilmGrain", settings.filmEmulation?.grain.map { String(format: "%.1f", $0) })
        setAppPrivate(&xmp, "FilmHalation", settings.filmEmulation?.halation.map { String(format: "%.1f", $0) })
        setAppPrivate(&xmp, "FilmBloom", settings.filmEmulation?.bloom.map { String(format: "%.1f", $0) })
        setAppPrivate(&xmp, "FilmVignette", settings.filmEmulation?.vignette.map { String(format: "%.1f", $0) })
        setAppPrivate(&xmp, "FilmEdgeBlur", settings.filmEmulation?.edgeBlur.map { String(format: "%.1f", $0) })
        setCRS(&xmp, "Sharpness", settings.sharpness.map(String.init))
        setCRS(&xmp, "Clarity2012", settings.clarity2012.map(formatSignedInt))
        setCRS(&xmp, "Dehaze", settings.dehaze.map(formatSignedInt))

        let hasSettings = settings.hasSettings ?? !settings.isEmpty
        setCRS(&xmp, "HasSettings", formatBool(hasSettings))

        // HSL: clear every channel, then set the present ones via the shared encoder — so a
        // smaller new HSL set can't leave stale channels behind (matches the old writer).
        let hslValues = Dictionary(
            uniqueKeysWithValues: (settings.hslAdjustments.map(encodeHSLAdjustments) ?? [])
                .map { ($0.name, $0.value) }
        )
        for name in acrHSLPropertyNames {
            setCRS(&xmp, name, hslValues[name])
        }

        // crs crop carries Adobe's un-rotated-frame corner encoding — convert at this boundary.
        let crop = settings.crop?.encodedForACR(aspect: imageAspect)
        let hasCrop: Bool? = crop.map { $0.hasCrop ?? !$0.isEmpty }
        setCRS(&xmp, "CropTop", crop?.top.map { formatUnsignedDouble($0, precision: 6) })
        setCRS(&xmp, "CropLeft", crop?.left.map { formatUnsignedDouble($0, precision: 6) })
        setCRS(&xmp, "CropBottom", crop?.bottom.map { formatUnsignedDouble($0, precision: 6) })
        setCRS(&xmp, "CropRight", crop?.right.map { formatUnsignedDouble($0, precision: 6) })
        setCRS(&xmp, "CropAngle", crop?.angle.map { formatUnsignedDouble($0, precision: 6) })
        setCRS(&xmp, "HasCrop", hasCrop.map(formatBool))
        setCRS(&xmp, "CropConstrainToWarp", hasCrop == true ? "0" : nil)
        setCRS(&xmp, "CropConstrainToUnitSquare", hasCrop == true ? "1" : nil)

        setCRS(&xmp, "HDREditMode", settings.hdrEditMode.map(String.init))
        setCRS(&xmp, "HDRMaxValue", settings.hdrMaxValue)
        setCRS(&xmp, "SDRBrightness", settings.sdrBrightness.map(formatSignedInt))
        setCRS(&xmp, "SDRContrast", settings.sdrContrast.map(formatSignedInt))
        setCRS(&xmp, "SDRClarity", settings.sdrClarity.map(formatSignedInt))
        setCRS(&xmp, "SDRHighlights", settings.sdrHighlights.map(formatSignedInt))
        setCRS(&xmp, "SDRShadows", settings.sdrShadows.map(formatSignedInt))
        setCRS(&xmp, "SDRWhites", settings.sdrWhites.map(formatSignedInt))
        setCRS(&xmp, "SDRBlend", settings.sdrBlend.map(formatSignedInt))

        applyToneCurves(settings.toneCurve, into: &xmp)
        applyLayerChain(masks: settings.localAdjustments ?? [], watermarks: settings.watermarkLayers ?? [],
                        layerOrder: settings.layerOrder,
                        preserved: settings.unparsedMaskCorrections ?? [], into: &xmp)
        applyAnonymizer(settings.anonymizer, into: &xmp)
    }

    /// Clear the develop block — the same fixed field list the old NSXML `removeCameraRawSettings`
    /// deleted, plus the HSL channels and the app-private GlobalLayerIndex. Scoped to the fields we
    /// manage so other unmodeled third-party crs props survive, matching prior behavior.
    nonisolated static func removeCRSBlock(_ xmp: inout XMPData) {
        let fields = [
            "Version", "ProcessVersion", "WhiteBalance", "Temperature", "Tint",
            "IncrementalTemperature", "IncrementalTint", "Exposure2012", "Contrast2012",
            "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012", "Saturation", "Vibrance",
            "Sharpness", "Clarity2012", "Dehaze",
            "HasSettings", "CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle", "HasCrop",
            "CropConstrainToWarp", "CropConstrainToUnitSquare", "HDREditMode", "HDRMaxValue",
            "SDRBrightness", "SDRContrast", "SDRClarity", "SDRHighlights", "SDRShadows", "SDRWhites",
            "SDRBlend", "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green",
            "ToneCurvePV2012Blue", "ToneCurveName2012", "MaskGroupBasedCorrections", "AlreadyApplied",
            "CompatibleVersion",
        ] + acrHSLPropertyNames
        for field in fields {
            xmp.removeValue(namespace: XMPNamespace.crs, property: field)
        }
        xmp.removeValue(namespace: aaphotoNamespace, property: "GlobalLayerIndex")
        xmp.removeValue(namespace: aaphotoNamespace, property: "LayerOrder")
        xmp.removeValue(namespace: aaphotoNamespace, property: "WatermarkLayers")
        xmp.removeValue(namespace: aaphotoNamespace, property: "AnonymizerAmount")
        xmp.removeValue(namespace: aaphotoNamespace, property: "AnonymizerBlackOut")
        xmp.removeValue(namespace: aaphotoNamespace, property: "GlobalDensity")
        xmp.removeValue(namespace: aaphotoNamespace, property: "FilmGrain")
        xmp.removeValue(namespace: aaphotoNamespace, property: "FilmHalation")
        xmp.removeValue(namespace: aaphotoNamespace, property: "FilmBloom")
        xmp.removeValue(namespace: aaphotoNamespace, property: "FilmVignette")
        xmp.removeValue(namespace: aaphotoNamespace, property: "FilmEdgeBlur")
    }

    // MARK: - Shared develop encoders (also used by the embedded SwiftExifWriteEngine)

    /// Tone curves as crs rdf:Seq arrays of "x, y" strings (ACR 0–255 scale). Identity
    /// channels are removed. Sets ToneCurveName2012="Custom" when any curve is set.
    nonisolated static func applyToneCurves(_ tc: ToneCurve?, into xmp: inout XMPData) {
        func setChannel(_ property: String, _ points: [ToneCurvePoint]?) {
            if let points, !points.isIdentityToneCurve {
                xmp.setValue(.array(serializeToneCurvePoints(points)), namespace: XMPNamespace.crs, property: property)
            } else {
                xmp.removeValue(namespace: XMPNamespace.crs, property: property)
            }
        }
        setChannel("ToneCurvePV2012", tc?.master)
        setChannel("ToneCurvePV2012Red", tc?.red)
        setChannel("ToneCurvePV2012Green", tc?.green)
        setChannel("ToneCurvePV2012Blue", tc?.blue)
        if let tc, !tc.isEmpty {
            xmp.setValue(.simple("Custom"), namespace: XMPNamespace.crs, property: "ToneCurveName2012")
        } else {
            xmp.removeValue(namespace: XMPNamespace.crs, property: "ToneCurveName2012")
        }
    }

    /// Local masks as ACR's `crs:MaskGroupBasedCorrections` — a structured array whose items each
    /// carry a nested `crs:CorrectionMasks` structured array. Field content comes from the shared
    /// `encodeMaskGroupBasedCorrections`; this exact nesting is what `parseMaskGroupBasedCorrections`
    /// expects on read-back. Stamps AlreadyApplied="False"/CompatibleVersion so Bridge/ACR badge the
    /// file as edited (only when masks exist).
    nonisolated static func applyMasks(_ masks: [MaskAdjustment], preserved: [PreservedMaskCorrection], into xmp: inout XMPData) {
        let encoded = encodeMaskGroupBasedCorrections(masks)
        if encoded.isEmpty && preserved.isEmpty {
            xmp.removeValue(namespace: XMPNamespace.crs, property: "MaskGroupBasedCorrections")
            return
        }
        var corrections: [[String: XMPValue]] = encoded.map { corr in
            var fields = Dictionary(uniqueKeysWithValues: corr.correctionFields.map {
                (XMPNamespace.crs + $0.name, XMPValue.simple($0.value))
            })
            // AI masks carry an entirely app-namespaced nested struct (no ACR fallback); brush
            // masks carry Mask/Aggregate → Masks → Mask/Paint; analytic masks carry one flat
            // Mask/CircularGradient struct.
            if let customFields = corr.customMaskFields {
                let maskStruct = Dictionary(uniqueKeysWithValues: customFields.map {
                    (aaphotoNamespace + $0.name, XMPValue.simple($0.value))
                })
                fields[XMPNamespace.crs + "CorrectionMasks"] = .structuredArray([maskStruct])
            } else if let nodes = corr.correctionMasks {
                fields[XMPNamespace.crs + "CorrectionMasks"] = .structuredArray(nodes.map(buildMaskNode))
            } else {
                let maskStruct = Dictionary(uniqueKeysWithValues: corr.maskFields.map {
                    (XMPNamespace.crs + $0.name, XMPValue.simple($0.value))
                })
                fields[XMPNamespace.crs + "CorrectionMasks"] = .structuredArray([maskStruct])
            }
            // App-private siblings (e.g. Anonymizer) live under aaphoto:, never crs:.
            for field in corr.appPrivateFields {
                fields[aaphotoNamespace + field.name] = .simple(field.value)
            }
            return fields
        }
        // Re-emit unmodeled corrections (erase-brush blobs, unknown mask types) verbatim, after
        // our own masks — the whole point of preserving them through the model.
        corrections.append(contentsOf: preserved.map { $0.fields.mapValues(xmpValue(from:)) })
        xmp.setValue(.simple("False"), namespace: XMPNamespace.crs, property: "AlreadyApplied")
        xmp.setValue(.simple("234881024"), namespace: XMPNamespace.crs, property: "CompatibleVersion")
        xmp.setValue(.structuredArray(corrections), namespace: XMPNamespace.crs, property: "MaskGroupBasedCorrections")
    }

    /// Recursively build one `crs` mask struct from an `ACRMaskNode` — simple fields, array
    /// fields (`Dabs`), and nested structured-array children (`Masks`), all `crs:`-prefixed.
    nonisolated private static func buildMaskNode(_ node: ACRMaskNode) -> [String: XMPValue] {
        var fields: [String: XMPValue] = [:]
        for field in node.fields { fields[XMPNamespace.crs + field.name] = .simple(field.value) }
        for array in node.arrays { fields[XMPNamespace.crs + array.name] = .array(array.values) }
        for child in node.children {
            fields[XMPNamespace.crs + child.name] = .structuredArray(child.nodes.map(buildMaskNode))
        }
        return fields
    }

    /// Convert a preserved (verbatim) correction node back to `XMPValue`. Keys inside a
    /// `PreservedMaskCorrection` are already full namespace-prefixed, so this only maps values.
    nonisolated private static func xmpValue(from node: PreservedXMPNode) -> XMPValue {
        switch node {
        case .string(let s):     return .simple(s)
        case .strings(let a):    return .array(a)
        case .structure(let f):  return .structure(f.mapValues(xmpValue(from:)))
        case .items(let items):  return .structuredArray(items.map { $0.mapValues(xmpValue(from:)) })
        }
    }

    /// Write masks in render-stack order, watermark layers, and the layer-chain order —
    /// plus the app-private `aaphoto:GlobalLayerIndex` (the global node's position). Reuses
    /// the shared model helpers so both stores agree.
    ///
    /// Persistence has two modes, chosen by `CameraRawSettings.needsExplicitLayerOrderPersistence`:
    /// the legacy encoding (masks in render-stack order + a single `GlobalLayerIndex` int) only
    /// works when there are just 2 conceptual buckets (masks, global) — it's kept as-is so
    /// watermark-free files round-trip byte-identically. Once any watermark layer exists there
    /// are 3 independently-positioned kinds, which that one int can no longer reconstruct, so the
    /// fully-explicit `aaphoto:LayerOrder` token array takes over instead.
    nonisolated static func applyLayerChain(masks: [MaskAdjustment], watermarks: [WatermarkLayer] = [], layerOrder: [LayerRef]?, preserved: [PreservedMaskCorrection] = [], into xmp: inout XMPData) {
        var chain = CameraRawSettings()
        chain.localAdjustments = masks
        chain.watermarkLayers = watermarks
        chain.layerOrder = layerOrder
        applyMasks(chain.masksInRenderOrder() ?? masks, preserved: preserved, into: &xmp)
        applyWatermarkLayers(watermarks, into: &xmp)
        if chain.needsExplicitLayerOrderPersistence {
            xmp.removeValue(namespace: aaphotoNamespace, property: "GlobalLayerIndex")
            applyExplicitLayerOrder(chain.resolvedLayerOrder(), into: &xmp)
        } else {
            xmp.removeValue(namespace: aaphotoNamespace, property: "LayerOrder")
            if let globalIndex = chain.globalLayerIndex(), globalIndex > 0 {
                xmp.setValue(.simple(String(globalIndex)), namespace: aaphotoNamespace, property: "GlobalLayerIndex")
            } else {
                xmp.removeValue(namespace: aaphotoNamespace, property: "GlobalLayerIndex")
            }
        }
    }

    /// Write watermark layers as app-private `aaphoto:WatermarkLayers` — not an ACR/Lightroom
    /// concept, so no `crs:` involvement, mirroring how Anonymizer settings live under `aaphoto:`.
    nonisolated static func applyWatermarkLayers(_ layers: [WatermarkLayer], into xmp: inout XMPData) {
        guard !layers.isEmpty else {
            xmp.removeValue(namespace: aaphotoNamespace, property: "WatermarkLayers")
            return
        }
        let encoded: [[String: XMPValue]] = layers.map { layer in
            [
                aaphotoNamespace + "ID": .simple(layer.id.uuidString),
                aaphotoNamespace + "Name": .simple(layer.name),
                aaphotoNamespace + "Enabled": .simple(formatBool(layer.enabled)),
                aaphotoNamespace + "AssetID": .simple(layer.libraryAssetID.uuidString),
                aaphotoNamespace + "CenterX": .simple(formatUnsignedDouble(layer.geometry.centerX, precision: 6)),
                aaphotoNamespace + "CenterY": .simple(formatUnsignedDouble(layer.geometry.centerY, precision: 6)),
                aaphotoNamespace + "SizeDimension": .simple(layer.geometry.sizeDimension.rawValue),
                aaphotoNamespace + "SizeUnit": .simple(layer.geometry.sizeUnit.rawValue),
                aaphotoNamespace + "SizeValue": .simple(formatUnsignedDouble(layer.geometry.sizeValue, precision: 4)),
                aaphotoNamespace + "MarginUnit": .simple(layer.geometry.marginUnit.rawValue),
                aaphotoNamespace + "MarginValue": .simple(formatUnsignedDouble(layer.geometry.marginValue, precision: 4)),
                aaphotoNamespace + "Opacity": .simple(formatUnsignedDouble(layer.opacity, precision: 4)),
            ]
        }
        xmp.setValue(.structuredArray(encoded), namespace: aaphotoNamespace, property: "WatermarkLayers")
    }

    /// Write the fully-explicit layer-chain order as an `aaphoto:LayerOrder` rdf:Seq of
    /// compact tokens (`"global"` / `"mask:<uuid>"` / `"watermark:<uuid>"`) — see `LayerRef.token`.
    nonisolated static func applyExplicitLayerOrder(_ resolved: [LayerRef], into xmp: inout XMPData) {
        xmp.setValue(.array(resolved.map(\.token)), namespace: aaphotoNamespace, property: "LayerOrder")
    }

    /// Write the global Anonymizer redaction settings as app-private XMP (`aaphoto:AnonymizerAmount`
    /// / `AnonymizerBlackOut`) — not an ACR/Lightroom concept, so other tools silently ignore it;
    /// this app's own render/export pipeline is the only consumer. nil/empty clears both fields.
    /// Shared with the embedded-file writer via `SwiftExifWriteEngine.applyAnonymizer`.
    nonisolated static func applyAnonymizer(_ anon: AnonymizerSettings?, into xmp: inout XMPData) {
        guard let anon, !anon.isEmpty else {
            xmp.removeValue(namespace: aaphotoNamespace, property: "AnonymizerAmount")
            xmp.removeValue(namespace: aaphotoNamespace, property: "AnonymizerBlackOut")
            return
        }
        if let amount = anon.amount, amount > 0 {
            xmp.setValue(.simple(String(format: "%.1f", amount)), namespace: aaphotoNamespace, property: "AnonymizerAmount")
        } else {
            xmp.removeValue(namespace: aaphotoNamespace, property: "AnonymizerAmount")
        }
        if anon.blackOut == true {
            xmp.setValue(.simple(formatBool(true)), namespace: aaphotoNamespace, property: "AnonymizerBlackOut")
        } else {
            xmp.removeValue(namespace: aaphotoNamespace, property: "AnonymizerBlackOut")
        }
    }

    // MARK: - Helpers

    nonisolated private static func setCRS(_ xmp: inout XMPData, _ property: String, _ value: String?) {
        setSimpleOrRemove(&xmp, value, namespace: XMPNamespace.crs, property: property)
    }

    nonisolated private static func setAppPrivate(_ xmp: inout XMPData, _ property: String, _ value: String?) {
        setSimpleOrRemove(&xmp, value, namespace: aaphotoNamespace, property: property)
    }

    nonisolated private static func setSimpleOrRemove(_ xmp: inout XMPData, _ value: String?, namespace: String, property: String) {
        if let value, !value.isEmpty {
            xmp.setValue(.simple(value), namespace: namespace, property: property)
        } else {
            xmp.removeValue(namespace: namespace, property: property)
        }
    }

    nonisolated private static func setArrayOrRemove(_ xmp: inout XMPData, _ values: [String], namespace: String, property: String) {
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            xmp.removeValue(namespace: namespace, property: property)
        } else {
            xmp.setValue(.array(cleaned), namespace: namespace, property: property)
        }
    }

    nonisolated private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func formatSignedInt(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    nonisolated static func formatSignedDouble(_ value: Double, precision: Int) -> String {
        let absValue = String(format: "%.\(precision)f", abs(value))
        if value > 0 { return "+\(absValue)" }
        if value < 0 { return "-\(absValue)" }
        return absValue
    }

    nonisolated static func formatUnsignedDouble(_ value: Double, precision: Int) -> String {
        String(format: "%.\(precision)f", value)
    }

    nonisolated static func formatBool(_ value: Bool) -> String {
        value ? "True" : "False"
    }
}
