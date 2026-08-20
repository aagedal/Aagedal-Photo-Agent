import Foundation
import os

nonisolated private let parsingLog = Logger(subsystem: "com.aagedal.photo-agent", category: "IPTCMetadataParsing")

/// Field-name keys used in the metadata dictionaries that drive
/// `IPTCMetadata` and `TechnicalMetadata` construction. The names match the
/// canonical IPTC / XMP / EXIF tag names so parsers stay format-agnostic.
nonisolated enum MetadataDictKey {
    static let sourceFile = "SourceFile"
    static let headline = "Headline"
    static let title = "Title"
    static let objectName = "ObjectName"
    static let description = "Description"
    static let captionAbstract = "Caption-Abstract"
    static let extDescrAccessibility = "ExtDescrAccessibility"
    static let subject = "Subject"
    static let keywords = "Keywords"
    static let personInImage = "PersonInImage"
    static let organisationInImageName = "OrganisationInImageName"
    static let organisationInImageCode = "OrganisationInImageCode"
    static let digitalSourceType = "DigitalSourceType"
    static let creatorContactInfo = "CreatorContactInfo"
    static let locationCreated = "LocationCreated"
    static let locationShown = "LocationShown"
    static let gpsLatitude = "GPSLatitude"
    static let gpsLongitude = "GPSLongitude"
    static let creator = "Creator"
    static let byLine = "By-line"
    static let creatorJobTitle = "AuthorsPosition"
    static let byLineTitle = "By-lineTitle"
    static let descriptionWriter = "CaptionWriter"
    static let writerEditor = "Writer-Editor"
    static let credit = "Credit"
    static let rights = "Rights"
    static let copyrightNotice = "CopyrightNotice"
    static let rightsUsageTerms = "UsageTerms"
    static let webStatementOfRights = "WebStatement"
    static let transmissionReference = "TransmissionReference"
    static let jobID = "JobID"
    static let originalTransmissionReference = "OriginalTransmissionReference"
    static let dateCreated = "DateCreated"
    static let createDate = "CreateDate"
    static let dateTimeOriginal = "DateTimeOriginal"
    static let city = "City"
    static let sublocation = "Sub-location"
    static let location = "Location"
    static let provinceState = "Province-State"
    static let state = "State"
    static let country = "Country"
    static let countryCode = "CountryCode"
    static let countryPrimaryLocationCode = "Country-PrimaryLocationCode"
    static let countryPrimaryLocationName = "Country-PrimaryLocationName"
    static let event = "Event"
    static let specialInstructions = "SpecialInstructions"
    static let instructions = "Instructions"
    static let source = "Source"
    static let rating = "Rating"
    static let label = "Label"
    static let orientation = "Orientation"
    static let imageWidth = "ImageWidth"
    static let imageHeight = "ImageHeight"

    // Camera Raw (XMP-crs)
    static let crsVersion = "Version"
    static let crsProcessVersion = "ProcessVersion"
    static let crsWhiteBalance = "WhiteBalance"
    static let crsTemperature = "Temperature"
    static let crsTint = "Tint"
    static let crsIncrementalTemperature = "IncrementalTemperature"
    static let crsIncrementalTint = "IncrementalTint"
    static let crsExposure2012 = "Exposure2012"
    static let crsContrast2012 = "Contrast2012"
    static let crsHighlights2012 = "Highlights2012"
    static let crsShadows2012 = "Shadows2012"
    static let crsWhites2012 = "Whites2012"
    static let crsBlacks2012 = "Blacks2012"
    static let crsSaturation = "Saturation"
    static let crsVibrance = "Vibrance"
    static let crsSharpness = "Sharpness"
    static let crsClarity2012 = "Clarity2012"
    static let crsDehaze = "Dehaze"
    static let crsHasSettings = "HasSettings"
    static let crsAlreadyApplied = "AlreadyApplied"
    static let crsCropTop = "CropTop"
    static let crsCropLeft = "CropLeft"
    static let crsCropBottom = "CropBottom"
    static let crsCropRight = "CropRight"
    static let crsCropAngle = "CropAngle"
    static let crsHasCrop = "HasCrop"
    static let crsHDREditMode = "HDREditMode"
    static let crsHDRMaxValue = "HDRMaxValue"
    static let crsSDRBrightness = "SDRBrightness"
    static let crsSDRContrast = "SDRContrast"
    static let crsSDRClarity = "SDRClarity"
    static let crsSDRHighlights = "SDRHighlights"
    static let crsSDRShadows = "SDRShadows"
    static let crsSDRWhites = "SDRWhites"
    static let crsSDRBlend = "SDRBlend"
    static let crsToneCurvePV2012 = "ToneCurvePV2012"
    static let crsToneCurvePV2012Red = "ToneCurvePV2012Red"
    static let crsToneCurvePV2012Green = "ToneCurvePV2012Green"
    static let crsToneCurvePV2012Blue = "ToneCurvePV2012Blue"
    static let maskGroupBasedCorrections = "MaskGroupBasedCorrections"
    /// App-private (aaphoto namespace): the global node's position in the layer chain.
    static let globalLayerIndex = "GlobalLayerIndex"
    /// App-private (aaphoto namespace): the fully-explicit layer-chain order, used once any
    /// watermark layer exists (see `CameraRawSettings.needsExplicitLayerOrderPersistence`).
    static let layerOrderExplicit = "LayerOrder"
    /// App-private (aaphoto namespace): the watermark layer library-reference array.
    static let watermarkLayers = "WatermarkLayers"
    /// App-private (aaphoto namespace): the global Anonymizer redaction settings.
    static let anonymizerAmount = "AnonymizerAmount"
    static let anonymizerBlackOut = "AnonymizerBlackOut"
    /// App-private (aaphoto namespace): global density render adjustment.
    static let globalDensity = "GlobalDensity"
    static let filmGrain = "FilmGrain"
    static let filmGrainCoarseness = "FilmGrainCoarseness"
    static let filmHalation = "FilmHalation"
    static let filmBloom = "FilmBloom"
    static let filmVignette = "FilmVignette"
    static let filmEdgeBlur = "FilmEdgeBlur"
}

nonisolated func parseStringOrArray(_ value: Any?) -> [String] {
    if let array = value as? [String] { return array.uniqued() }
    if let str = value as? String { return [str] }
    return []
}

nonisolated func parseFirstString(_ value: Any?) -> String? {
    if let str = value as? String { return str }
    if let arr = value as? [String] { return arr.first }
    return nil
}

nonisolated func parseIntValue(_ value: Any?) -> Int? {
    if let intValue = value as? Int { return intValue }
    if let doubleValue = value as? Double { return safeInt(doubleValue) }
    if let stringValue = value as? String {
        return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

nonisolated func parseDoubleValue(_ value: Any?) -> Double? {
    if let doubleValue = value as? Double { return doubleValue }
    if let intValue = value as? Int { return Double(intValue) }
    if let stringValue = value as? String {
        return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

// MARK: - Structured IPTC editorial values

nonisolated private let iptcCoreXMPNamespace = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
nonisolated private let iptcExtensionXMPNamespace = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
nonisolated private let exifXMPNamespace = "http://ns.adobe.com/exif/1.0/"

/// SwiftExif unwraps an XMP structure with namespace-qualified dictionary keys. Accept local
/// names too so generated fixtures and callers that already normalized the structure stay usable.
nonisolated private func structuredXMPValue(
    _ fields: [String: Any],
    namespace: String,
    property: String
) -> Any? {
    fields[namespace + property] ?? fields[property]
}

nonisolated private func nonemptyStrings(_ value: Any?) -> [String] {
    parseStringOrArray(value)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Decode the single IPTC Core CreatorContactInfo structure without flattening its repeatable
/// address/contact channels into a delimiter-dependent display string.
nonisolated func parseCreatorContactInfo(_ value: Any?) -> CreatorContactInfo? {
    guard let fields = value as? [String: Any] else { return nil }
    let contact = CreatorContactInfo(
        addressLines: nonemptyStrings(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiAdrExtadr"
        )),
        city: parseFirstString(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiAdrCity"
        )),
        region: parseFirstString(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiAdrRegion"
        )),
        postalCode: parseFirstString(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiAdrPcode"
        )),
        country: parseFirstString(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiAdrCtry"
        )),
        emails: nonemptyStrings(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiEmailWork"
        )),
        phoneNumbers: nonemptyStrings(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiTelWork"
        )),
        webURLs: nonemptyStrings(structuredXMPValue(
            fields, namespace: iptcCoreXMPNamespace, property: "CiUrlWork"
        ))
    )
    return contact.isEmpty ? nil : contact
}

/// Parse decimal, Adobe/XMP degree-minute, and common human-readable coordinate spellings.
/// XMP's canonical GPSCoordinate lexical form is `degrees,minutesN|S|E|W`.
nonisolated func parseXMPGPSCoordinate(_ value: Any?) -> Double? {
    guard let raw = value as? String else { return parseDoubleValue(value) }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let direct = Double(trimmed) { return direct }

    let decimalWithDirection = /^\s*(-?\d+\.?\d*)\s*([NSEWnsew])\s*$/
    if let match = trimmed.firstMatch(of: decimalWithDirection), let base = Double(match.1) {
        let direction = String(match.2).uppercased()
        return direction == "S" || direction == "W" ? -abs(base) : abs(base)
    }

    let xmpDegreesMinutes = /^\s*(\d+)\s*,\s*(\d+(?:\.\d+)?)\s*([NSEWnsew])\s*$/
    if let match = trimmed.firstMatch(of: xmpDegreesMinutes),
       let degrees = Double(match.1), let minutes = Double(match.2), minutes < 60 {
        let decimal = degrees + minutes / 60
        let direction = String(match.3).uppercased()
        return direction == "S" || direction == "W" ? -decimal : decimal
    }

    let dms = /(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
    if let match = trimmed.firstMatch(of: dms),
       let degrees = Int(match.1), let minutes = Int(match.2),
       let seconds = Double(match.3), minutes < 60, seconds < 60 {
        var decimal = Double(abs(degrees)) + Double(minutes) / 60 + seconds / 3600
        if degrees < 0 { decimal = -decimal }
        if let direction = match.4.map({ String($0).uppercased() }),
           direction == "S" || direction == "W" {
            decimal = -abs(decimal)
        }
        return decimal
    }

    let ddm = /(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
    if let match = trimmed.firstMatch(of: ddm),
       let degrees = Int(match.1), let minutes = Double(match.2), minutes < 60 {
        var decimal = Double(abs(degrees)) + minutes / 60
        if degrees < 0 { decimal = -decimal }
        if let direction = match.3.map({ String($0).uppercased() }),
           direction == "S" || direction == "W" {
            decimal = -abs(decimal)
        }
        return decimal
    }
    return nil
}

nonisolated private func parseXMPAltitude(_ value: Any?) -> Double? {
    if let number = parseDoubleValue(value) { return number }
    guard let raw = value as? String else { return nil }
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let numerator = Double(parts[0]),
          let denominator = Double(parts[1]), denominator != 0 else { return nil }
    return numerator / denominator
}

nonisolated private func parseEditorialLocation(_ value: Any?) -> EditorialLocation? {
    guard let fields = value as? [String: Any] else { return nil }
    let altitudeMagnitude = parseXMPAltitude(structuredXMPValue(
        fields, namespace: exifXMPNamespace, property: "GPSAltitude"
    ))
    let altitudeReference = parseIntValue(structuredXMPValue(
        fields, namespace: exifXMPNamespace, property: "GPSAltitudeRef"
    ))
    let location = EditorialLocation(
        identifiers: nonemptyStrings(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "LocationId"
        )),
        name: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "LocationName"
        )),
        sublocation: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "Sublocation"
        )),
        city: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "City"
        )),
        provinceState: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "ProvinceState"
        )),
        countryName: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "CountryName"
        )),
        countryCode: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "CountryCode"
        )),
        worldRegion: parseFirstString(structuredXMPValue(
            fields, namespace: iptcExtensionXMPNamespace, property: "WorldRegion"
        )),
        latitude: parseXMPGPSCoordinate(structuredXMPValue(
            fields, namespace: exifXMPNamespace, property: "GPSLatitude"
        )),
        longitude: parseXMPGPSCoordinate(structuredXMPValue(
            fields, namespace: exifXMPNamespace, property: "GPSLongitude"
        )),
        altitudeMeters: altitudeMagnitude.map {
            altitudeReference == 1 ? -abs($0) : abs($0)
        }
    )
    return location.isEmpty ? nil : location
}

nonisolated func parseEditorialLocations(_ value: Any?) -> [EditorialLocation] {
    if let values = value as? [[String: Any]] {
        return values.compactMap(parseEditorialLocation)
    }
    return parseEditorialLocation(value).map { [$0] } ?? []
}

/// Sensor-frame (un-oriented) pixel aspect ratio (width/height) from a metadata
/// dict's EXIF dimensions. The crs crop/mask values live in this frame, so the
/// ACR boundary conversion uses this aspect — not the display-oriented one.
nonisolated func metadataDictPixelAspect(_ dict: [String: Any]) -> Double? {
    guard let width = parseDoubleValue(dict[MetadataDictKey.imageWidth]),
          let height = parseDoubleValue(dict[MetadataDictKey.imageHeight]),
          width > 0, height > 0
    else { return nil }
    return width / height
}

/// Safely convert a Double (possibly parsed from corrupt metadata) to Int.
/// `Int(_:)` traps on non-finite or out-of-range values, so guard them here.
nonisolated func safeInt(_ value: Double) -> Int? {
    guard value.isFinite,
          value >= Double(Int.min),
          value < Double(Int.max) else { return nil }
    return Int(value)
}

/// Parse an Adobe Camera Raw fractional value (e.g. `LocalContrast2012`) into a
/// 0–100-scale integer. Returns nil for missing or non-finite values — a crafted
/// XMP value of `inf`/`nan` would otherwise trap in `Int(_:)`.
nonisolated func parsePercentInt(_ value: Any?) -> Int? {
    guard let d = parseDoubleValue(value) else { return nil }
    return safeInt((d * 100).rounded())
}

nonisolated func parseBoolValue(_ value: Any?) -> Bool? {
    if let boolValue = value as? Bool { return boolValue }
    if let intValue = value as? Int {
        if intValue == 0 { return false }
        if intValue == 1 { return true }
    }
    if let stringValue = value as? String {
        switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }
    return nil
}

/// Parse a tone curve from a `[String]` of `"x, y"` pairs (Adobe Camera Raw 0-255 scale).
nonisolated func parseToneCurveArray(_ value: Any?) -> [ToneCurvePoint]? {
    guard let array = value as? [String], array.count >= 2 else { return nil }
    let points = array.compactMap { str -> ToneCurvePoint? in
        let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else { return nil }
        return ToneCurvePoint(acr255: x, y)
    }
    return points.isIdentityToneCurve ? nil : points
}

/// Serialize tone-curve points to Adobe Camera Raw `"x, y"` strings on the 0–255
/// scale — the inverse of `parseToneCurveArray`. `ToneCurvePoint` x/y are
/// normalized 0–1, but a corrupt sidecar (or a curve decoded straight from JSON)
/// can carry non-finite or out-of-range coordinates; clamp before `Int(round(...))`,
/// which traps on non-finite input. Clamp rather than drop so the point count —
/// and the comma-separated list it feeds — stays valid.
nonisolated func serializeToneCurvePoints(_ points: [ToneCurvePoint]) -> [String] {
    func scaled(_ value: Double) -> Int {
        guard value.isFinite else { return value == .infinity ? 255 : 0 }
        return Int(round(min(max(value, 0), 1) * 255))
    }
    return points.map { "\(scaled($0.x)), \(scaled($0.y))" }
}

/// Look up an ACR correction/mask struct field. SwiftExif keys structured XMP
/// fields as `<namespaceURI><Property>` (e.g. `http://ns.adobe.com/camera-raw-
/// settings/1.0/Top`), while hand-built dicts (tests, JSON sidecars) use the
/// bare property name — accept both.
nonisolated private func crsMaskField(_ dict: [String: Any], _ name: String) -> Any? {
    dict[name] ?? dict["http://ns.adobe.com/camera-raw-settings/1.0/" + name]
}

/// Same lookup as `crsMaskField`, but for the app-private `aaphoto` namespace — used by
/// fields (like Anonymizer) that aren't a real ACR concept and so can't live under `crs:`.
nonisolated private func aaphotoMaskField(_ dict: [String: Any], _ name: String) -> Any? {
    dict[name] ?? dict["http://aagedal.me/ns/photo/1.0/" + name]
}

/// The outcome of parsing `MaskGroupBasedCorrections`: the corrections this app models
/// (`masks`) plus corrections it can't (`preserved` — kept verbatim so a develop save
/// re-emits them instead of dropping them).
nonisolated struct ParsedMaskCorrections {
    var masks: [MaskAdjustment] = []
    var preserved: [PreservedMaskCorrection] = []
}

/// Parse Adobe Camera Raw `MaskGroupBasedCorrections`. Each correction is a dictionary with
/// `CorrectionMasks` as a nested array of mask dictionaries. Three mask kinds are modeled:
/// a single `Mask/CircularGradient` (ellipse), a single additive `Mask/Aggregate` of
/// `Mask/Paint` sub-masks (brush), and Photo Agent's app-namespaced AI raster mask. Anything
/// else — an erase-brush `MaskBrushTable` blob, an
/// unknown mask type, a multi-mask intersection — is kept verbatim in `preserved` rather than
/// dropped, so it survives a develop save (the next `replaceCameraRawBlock` wipe would otherwise
/// delete it permanently). Substituting a default ellipse would silently misrender it.
nonisolated func parseMaskGroupBasedCorrections(_ value: Any?) -> ParsedMaskCorrections? {
    guard let corrections = value as? [[String: Any]], !corrections.isEmpty else { return nil }
    var result = ParsedMaskCorrections()
    for (index, corr) in corrections.enumerated() {
        let active = parseBoolValue(crsMaskField(corr, "CorrectionActive")) ?? true
        let amount = parseDoubleValue(crsMaskField(corr, "CorrectionAmount")) ?? 1.0
        let name = crsMaskField(corr, "CorrectionName") as? String ?? "Mask \(index + 1)"

        let maskArray = crsMaskField(corr, "CorrectionMasks") as? [[String: Any]]
        let firstMask = maskArray?.first
        let what = firstMask.flatMap { crsMaskField($0, "What") as? String }

        // Photo Agent-only AI raster matte. It deliberately has no ACR shape fallback: the
        // correction's nested mask struct is entirely app-namespaced, so ACR can ignore it.
        if let firstMask, maskArray?.count == 1,
           (aaphotoMaskField(firstMask, "What") as? String) == "Mask/AISelection" {
            let inverted = parseBoolValue(aaphotoMaskField(firstMask, "Inverted")) ?? false
            let mask = makeMaskAdjustment(
                corr: corr,
                name: name,
                active: active,
                amount: amount,
                inverted: inverted,
                geometry: EllipseMaskGeometry()
            )
            if mask.aiMask != nil {
                result.masks.append(mask)
                continue
            }
        }

        // Brush: a single additive Mask/Aggregate whose sub-masks are all Mask/Paint.
        if let firstMask, maskArray?.count == 1, what == "Mask/Aggregate",
           let brush = parseBrushGeometry(firstMask) {
            var mask = makeMaskAdjustment(corr: corr, name: name, active: active, amount: amount,
                                          inverted: false, geometry: EllipseMaskGeometry())
            mask.brush = brush
            result.masks.append(mask)
            continue
        }

        // Ellipse (radial): a single Mask/CircularGradient with parseable corner fields.
        if let firstMask, maskArray?.count == 1, what == "Mask/CircularGradient",
           let geometry = parseEllipseGeometry(firstMask) {
            // ACR Flipped=true means effect applies inside the ellipse;
            // our inverted=true means effect applies outside. Negate.
            let inverted = !(parseBoolValue(crsMaskField(firstMask, "Flipped")) ?? true)
            let mask = makeMaskAdjustment(corr: corr, name: name, active: active, amount: amount,
                                          inverted: inverted, geometry: geometry)
            result.masks.append(mask)
            continue
        }

        // Anything else — erase-brush MaskBrushTable, unknown mask type, multi-mask
        // intersection — is preserved verbatim so a develop save doesn't delete it.
        parsingLog.warning("Preserving MaskGroupBasedCorrections[\(index)] (\(name, privacy: .public)) verbatim: unmodeled mask type \(what ?? "unknown", privacy: .public)")
        result.preserved.append(PreservedMaskCorrection(fields: preservedFields(from: corr)))
    }
    return result
}

/// Parse the app-private `aaphoto:WatermarkLayers` array back into `[WatermarkLayer]`.
/// Mirrors `parseMaskGroupBasedCorrections`'s defensive style: an entry missing its
/// `AssetID` (or with an unparseable UUID) is skipped rather than thrown, so one bad
/// hand-edited sidecar doesn't break the whole layer chain.
nonisolated func parseWatermarkLayers(_ value: Any?) -> [WatermarkLayer]? {
    guard let items = value as? [[String: Any]], !items.isEmpty else { return nil }
    let layers: [WatermarkLayer] = items.compactMap { item in
        guard let assetIDString = aaphotoMaskField(item, "AssetID") as? String,
              let assetID = UUID(uuidString: assetIDString)
        else { return nil }
        let id = (aaphotoMaskField(item, "ID") as? String).flatMap { UUID(uuidString: $0) } ?? UUID()

        var geometry = WatermarkGeometry()
        geometry.centerX = parseDoubleValue(aaphotoMaskField(item, "CenterX")) ?? geometry.centerX
        geometry.centerY = parseDoubleValue(aaphotoMaskField(item, "CenterY")) ?? geometry.centerY
        if let dim = aaphotoMaskField(item, "SizeDimension") as? String {
            geometry.sizeDimension = WatermarkDimension(rawValue: dim) ?? geometry.sizeDimension
        }
        if let unit = aaphotoMaskField(item, "SizeUnit") as? String {
            geometry.sizeUnit = WatermarkSizeUnit(rawValue: unit) ?? geometry.sizeUnit
        }
        geometry.sizeValue = parseDoubleValue(aaphotoMaskField(item, "SizeValue")) ?? geometry.sizeValue
        if let unit = aaphotoMaskField(item, "MarginUnit") as? String {
            geometry.marginUnit = WatermarkMarginUnit(rawValue: unit) ?? geometry.marginUnit
        }
        geometry.marginValue = parseDoubleValue(aaphotoMaskField(item, "MarginValue")) ?? geometry.marginValue

        var layer = WatermarkLayer(id: id, libraryAssetID: assetID, geometry: geometry)
        layer.name = aaphotoMaskField(item, "Name") as? String ?? layer.name
        layer.enabled = parseBoolValue(aaphotoMaskField(item, "Enabled")) ?? true
        layer.opacity = parseDoubleValue(aaphotoMaskField(item, "Opacity")) ?? 1.0
        return layer
    }
    return layers.isEmpty ? nil : layers
}

/// Parse the app-private `aaphoto:LayerOrder` token array (rdf:Seq of simple strings) back
/// into `[LayerRef]`, using the shared token grammar from `LayerRef.init(token:)`.
/// Malformed tokens are skipped defensively.
nonisolated func parseExplicitLayerOrder(_ value: Any?) -> [LayerRef]? {
    guard let tokens = value as? [String], !tokens.isEmpty else { return nil }
    let refs = tokens.compactMap(LayerRef.init(token:))
    return refs.isEmpty ? nil : refs
}

/// Decode the oriented-corner ellipse box (`Mask/CircularGradient`) into `EllipseMaskGeometry`.
/// Returns nil when the corner fields are missing (caller preserves the correction instead).
nonisolated private func parseEllipseGeometry(_ maskDict: [String: Any]) -> EllipseMaskGeometry? {
    guard let top = parseDoubleValue(crsMaskField(maskDict, "Top")),
          let left = parseDoubleValue(crsMaskField(maskDict, "Left")),
          let bottom = parseDoubleValue(crsMaskField(maskDict, "Bottom")),
          let right = parseDoubleValue(crsMaskField(maskDict, "Right"))
    else { return nil }

    var geometry = EllipseMaskGeometry()
    geometry.centerX = (left + right) / 2
    geometry.centerY = (top + bottom) / 2
    // ACR's (Left,Top)/(Right,Bottom) are opposite corners of the ellipse's ORIENTED bounding
    // rect — the corner vector rotates with the ellipse in aspect-corrected (pixel) space, so
    // for rotated masks Left can exceed Right and these half-extents are signed, NOT the
    // semi-axes. The true radii are recovered by un-rotating the corner vector at render time
    // (see EllipseMaskGeometry); at Angle=0 they coincide.
    geometry.radiusX = (right - left) / 2
    geometry.radiusY = (bottom - top) / 2
    geometry.rotation = parseDoubleValue(crsMaskField(maskDict, "Angle")) ?? 0
    geometry.feather = parseDoubleValue(crsMaskField(maskDict, "Feather")) ?? 50
    return geometry
}

/// Decode an additive `Mask/Aggregate` into `BrushMaskGeometry`. Each `Mask/Paint` sub-mask
/// becomes one `BrushStroke`. Returns nil for an opaque erase-brush aggregate (`MaskBrushTable`,
/// no decodable `Masks`) or any sub-mask that isn't a parseable `Mask/Paint`, so the caller
/// preserves the whole correction verbatim rather than rendering it wrong.
nonisolated private func parseBrushGeometry(_ aggregate: [String: Any]) -> BrushMaskGeometry? {
    // Erase strokes switch ACR to a rasterized MaskBrushTable blob with no decodable Dabs.
    if crsMaskField(aggregate, "MaskBrushTable") != nil { return nil }
    guard let subMasks = crsMaskField(aggregate, "Masks") as? [[String: Any]], !subMasks.isEmpty else {
        return nil
    }
    var strokes: [BrushStroke] = []
    for sub in subMasks {
        guard (crsMaskField(sub, "What") as? String) == "Mask/Paint",
              let radius = parseDoubleValue(crsMaskField(sub, "Radius")),
              let dabsRaw = crsMaskField(sub, "Dabs") as? [String]
        else { return nil }
        // MaskValue is the per-sub-mask accumulated-opacity ceiling (ACR "Density"); Flow and
        // CenterWeight (hardness) seed the current brush state before any inline f/h records.
        let density = parseDoubleValue(crsMaskField(sub, "MaskValue")) ?? 1.0
        let baseFlow = parseDoubleValue(crsMaskField(sub, "Flow")) ?? 1.0
        let baseHardness = parseDoubleValue(crsMaskField(sub, "CenterWeight")) ?? 0.0
        let dabs = parseDabs(dabsRaw, flow: baseFlow, hardness: baseHardness)
        guard !dabs.isEmpty else { continue }
        strokes.append(BrushStroke(dabs: dabs, radius: radius, density: density, erase: false))
    }
    return strokes.isEmpty ? nil : BrushMaskGeometry(strokes: strokes)
}

/// Parse ACR `Dabs` records into `[BrushDab]`. A record is `f <flow>` (set current flow),
/// `h <hardness>` (set current hardness/CenterWeight), or `d <x> <y>` (a dab at normalized UV
/// using the current flow/hardness). `flow`/`hardness` seed the state before the first f/h.
nonisolated private func parseDabs(_ records: [String], flow: Double, hardness: Double) -> [BrushDab] {
    var currentFlow = flow
    var currentHardness = hardness
    var dabs: [BrushDab] = []
    for record in records {
        let parts = record.split(separator: " ")
        guard let tag = parts.first else { continue }
        switch String(tag) {
        case "f":
            if parts.count >= 2, let f = Double(parts[1]) { currentFlow = f }
        case "h":
            if parts.count >= 2, let h = Double(parts[1]) { currentHardness = h }
        case "d":
            if parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                dabs.append(BrushDab(x: x, y: y, flow: currentFlow, hardness: currentHardness))
            }
        default:
            break
        }
    }
    return dabs
}

/// Build a `MaskAdjustment` from a correction's shared correction-level fields (the effect
/// sliders + app-private Photo Agent extensions) — used by both the ellipse and brush paths.
nonisolated private func makeMaskAdjustment(corr: [String: Any], name: String, active: Bool,
                                            amount: Double, inverted: Bool,
                                            geometry: EllipseMaskGeometry) -> MaskAdjustment {
    // ACR stores all local adjustments as fractions of their full range (-1..+1).
    // Exposure range is -4..+4 EV, so XMP value × 4 = EV stops.
    let exposure = parseDoubleValue(crsMaskField(corr, "LocalExposure2012")).map { $0 * 4.0 }
    let contrast = parsePercentInt(crsMaskField(corr, "LocalContrast2012"))
    let highlights = parsePercentInt(crsMaskField(corr, "LocalHighlights2012"))
    let shadows = parsePercentInt(crsMaskField(corr, "LocalShadows2012"))
    let whites = parsePercentInt(crsMaskField(corr, "LocalWhites2012"))
    let blacks = parsePercentInt(crsMaskField(corr, "LocalBlacks2012"))
    let saturation = parsePercentInt(crsMaskField(corr, "LocalSaturation"))
    let vibrance = parsePercentInt(crsMaskField(corr, "LocalVibrance"))
    let temperature = parseDoubleValue(crsMaskField(corr, "LocalTemperature")).map { $0 * 100 }
    let tint = parseDoubleValue(crsMaskField(corr, "LocalTint")).map { $0 * 100 }

    // App-private (aaphoto namespace): Anonymizer isn't a real ACR concept, so it's a
    // sibling field on the correction rather than a `crs:Local*` property.
    let anonymizerAmount = parseDoubleValue(aaphotoMaskField(corr, "AnonymizerAmount"))
    let anonymizerBlackOut = parseBoolValue(aaphotoMaskField(corr, "AnonymizerBlackOut"))
    let anonymizer: AnonymizerSettings? = (anonymizerAmount ?? 0) > 0 || anonymizerBlackOut == true
        ? AnonymizerSettings(amount: anonymizerAmount, blackOut: anonymizerBlackOut)
        : nil
    let fullFrame = parseBoolValue(aaphotoMaskField(corr, "FullFrame")) == true
    let colorTransform: ColorTransformSettings? = {
        guard let rawMode = aaphotoMaskField(corr, "ColorTransformMode") as? String,
              let mode = ColorTransformMode(rawValue: rawMode)
        else { return nil }
        var transform = ColorTransformSettings(mode: mode)
        transform.lutName = aaphotoMaskField(corr, "LUTName") as? String
        if let encoded = aaphotoMaskField(corr, "LUTData") as? String,
           encoded.count <= 12_000_000,
           let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
           !data.isEmpty, data.count <= 8_000_000 {
            transform.lutData = data
        }
        if let raw = aaphotoMaskField(corr, "CSTInput") as? String,
           let space = ColorTransformSpace(rawValue: raw) {
            transform.inputSpace = space
        }
        if let raw = aaphotoMaskField(corr, "CSTOutput") as? String,
           let space = ColorTransformSpace(rawValue: raw) {
            transform.outputSpace = space
        }
        return transform
    }()

    // ACR ignores this app-private sibling and renders the standard CircularGradient ellipse.
    // Photo Agent uses it to turn the same oriented box into a rounded rectangle. Absence means
    // a native ACR ellipse, preserving import fidelity and old sidecar compatibility.
    var resolvedGeometry = geometry
    if let cornerRadius = parseDoubleValue(aaphotoMaskField(corr, "CornerRadius")),
       cornerRadius.isFinite {
        resolvedGeometry.cornerRadius = min(max(cornerRadius, 0), 1)
    }

    // Vision subject mattes are a Photo Agent extension. Keep the payload deliberately bounded
    // when reading hand-edited XMP: generated masks are at most 1024 px on their long edge and
    // comfortably below 2 MB, so larger values are malformed rather than useful mask data.
    let aiMask: AIMaskGeometry? = {
        guard let encoded = aaphotoMaskField(corr, "AIMaskPNG") as? String,
              encoded.count <= 2_800_000,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count <= 2_000_000,
              let width = parseIntValue(aaphotoMaskField(corr, "AIMaskWidth")),
              let height = parseIntValue(aaphotoMaskField(corr, "AIMaskHeight")),
              (1...4096).contains(width), (1...4096).contains(height)
        else { return nil }
        let orientation = min(max(parseIntValue(aaphotoMaskField(corr, "AIMaskOrientation")) ?? 1, 1), 8)
        let target = (aaphotoMaskField(corr, "AIMaskTarget") as? String)
            .flatMap(AIMaskTarget.init(rawValue:))
        let blackPoint = parseDoubleValue(aaphotoMaskField(corr, "AIMaskBlackPoint"))
            .flatMap { $0.isFinite ? min(max($0, 0), 0.99) : nil }
        let whitePoint = parseDoubleValue(aaphotoMaskField(corr, "AIMaskWhitePoint"))
            .flatMap { $0.isFinite ? min(max($0, 0.01), 1) : nil }
        let blurRadius = parseDoubleValue(aaphotoMaskField(corr, "AIMaskBlurRadius"))
            .flatMap { $0.isFinite ? min(max($0, 0), 0.02) : nil }
        return AIMaskGeometry(
            width: width,
            height: height,
            pngData: data,
            sourceOrientation: orientation,
            displayOrientation: orientation,
            target: target,
            blackPoint: blackPoint,
            whitePoint: whitePoint,
            blurRadius: blurRadius
        )
    }()

    return MaskAdjustment(
        name: name,
        enabled: active,
        inverted: inverted,
        amount: amount,
        geometry: resolvedGeometry,
        fullFrame: fullFrame ? true : nil,
        colorTransform: colorTransform,
        aiMask: aiMask,
        exposure: exposure.flatMap { abs($0) < 0.001 ? nil : $0 },
        contrast: contrast.flatMap { $0 == 0 ? nil : $0 },
        highlights: highlights.flatMap { $0 == 0 ? nil : $0 },
        shadows: shadows.flatMap { $0 == 0 ? nil : $0 },
        whites: whites.flatMap { $0 == 0 ? nil : $0 },
        blacks: blacks.flatMap { $0 == 0 ? nil : $0 },
        saturation: saturation.flatMap { $0 == 0 ? nil : $0 },
        vibrance: vibrance.flatMap { $0 == 0 ? nil : $0 },
        temperature: temperature.flatMap { abs($0) < 0.01 ? nil : $0 },
        tint: tint.flatMap { abs($0) < 0.01 ? nil : $0 },
        anonymizer: anonymizer
    )
}

/// Recursively convert an unwrapped XMP correction dictionary (namespace-prefixed keys,
/// values are `String` / `[String]` / nested `[[String: Any]]` / `[String: Any]`) into the
/// Codable `PreservedXMPNode` mirror, dropping only value shapes that can't occur in a
/// correction. The full-namespace keys are kept so the writer re-emits them verbatim.
nonisolated private func preservedFields(from dict: [String: Any]) -> [String: PreservedXMPNode] {
    dict.reduce(into: [:]) { out, kv in
        if let node = preservedNode(from: kv.value) { out[kv.key] = node }
    }
}

nonisolated private func preservedNode(from value: Any) -> PreservedXMPNode? {
    if let s = value as? String { return .string(s) }
    if let a = value as? [String] { return .strings(a) }
    if let items = value as? [[String: Any]] { return .items(items.map(preservedFields(from:))) }
    if let dict = value as? [String: Any] { return .structure(preservedFields(from: dict)) }
    return nil
}

/// A nested `crs` mask node — bare-name simple fields, plus array-typed fields (`Dabs`) and
/// nested structured-array children (`Masks`). Lets a brush correction carry the full
/// `Mask/Aggregate` → `Masks` → `Mask/Paint` → `Dabs` tree that the flat single-struct
/// `maskFields` shape can't express. The writer (`XMPDataBuilder`) turns it into `XMPValue`.
nonisolated struct ACRMaskNode {
    var fields: [(name: String, value: String)] = []
    var arrays: [(name: String, values: [String])] = []
    var children: [(name: String, nodes: [ACRMaskNode])] = []
}

/// One ACR `MaskGroupBasedCorrections` entry encoded as bare-name field/value
/// pairs: the correction-level fields (without the nested `CorrectionMasks`
/// array) plus either a single `Mask/CircularGradient` struct (`maskFields`) or a nested
/// `correctionMasks` node tree (brush). Shared by the embedded-XMP writer
/// (`SwiftExifWriteEngine.applyMasks`, which namespace-prefixes the keys) and the .xmp sidecar
/// writer (`XMPSidecarService`, which writes them as `crs:` attributes) so the two destinations
/// encode masks identically.
nonisolated struct ACRMaskCorrection {
    var correctionFields: [(name: String, value: String)]
    var maskFields: [(name: String, value: String)]
    /// App-private fields with no ACR equivalent (e.g. Anonymizer) — written under the
    /// `aaphoto` namespace as siblings of `correctionFields`, never `crs:`.
    var appPrivateFields: [(name: String, value: String)] = []
    /// Photo Agent-only nested mask fields. When present, `CorrectionMasks` contains an
    /// `aaphoto` struct rather than an ACR `crs:Mask/*` shape, so ACR has no visual fallback.
    var customMaskFields: [(name: String, value: String)]? = nil
    /// When set, the `CorrectionMasks` array is built from these nodes (brush masks) instead of
    /// wrapping the flat `maskFields` as a single struct (ellipse masks).
    var correctionMasks: [ACRMaskNode]? = nil
}

/// Encode enabled masks into ACR's `MaskGroupBasedCorrections` schema —
/// the exact inverse of `parseMaskGroupBasedCorrections`.
nonisolated func encodeMaskGroupBasedCorrections(_ masks: [MaskAdjustment]) -> [ACRMaskCorrection] {
    masks.filter(\.enabled).enumerated().map { index, mask in
        let correctionFields = encodeCorrectionFields(mask)
        let appPrivateFields = encodeMaskAppPrivateFields(mask)

        if mask.aiMask?.isValid == true {
            return ACRMaskCorrection(
                correctionFields: correctionFields,
                maskFields: [],
                appPrivateFields: appPrivateFields,
                customMaskFields: [
                    ("What", "Mask/AISelection"),
                    ("Inverted", mask.inverted ? "True" : "False"),
                    ("Version", "1"),
                ]
            )
        }

        if let brush = mask.brush {
            return ACRMaskCorrection(
                correctionFields: correctionFields,
                maskFields: [],
                appPrivateFields: appPrivateFields,
                correctionMasks: encodeBrushCorrectionMasks(brush, name: mask.name)
            )
        }

        return ACRMaskCorrection(
            correctionFields: correctionFields,
            maskFields: encodeEllipseMaskFields(mask, index: index),
            appPrivateFields: appPrivateFields
        )
    }
}

/// A fresh ACR-style sync ID (a UUID with the hyphens stripped).
nonisolated private func newMaskSyncID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
}

/// The single `Mask/CircularGradient` struct fields for an ellipse mask.
nonisolated private func encodeEllipseMaskFields(_ mask: MaskAdjustment, index: Int) -> [(name: String, value: String)] {
    let geo = mask.geometry
    let top = geo.centerY - geo.radiusY
    let left = geo.centerX - geo.radiusX
    let bottom = geo.centerY + geo.radiusY
    let right = geo.centerX + geo.radiusX
    return [
        ("What", "Mask/CircularGradient"),
        ("Top", acrNum(top)),
        ("Left", acrNum(left)),
        ("Bottom", acrNum(bottom)),
        ("Right", acrNum(right)),
        ("Angle", acrNum(geo.rotation)),
        ("Feather", acrNum(geo.feather)),
        ("Midpoint", "50"),
        ("Roundness", "0"),
        // ACR Flipped=true means effect applies inside the ellipse;
        // our `inverted=true` means effect applies outside. Negate.
        ("Flipped", mask.inverted ? "false" : "true"),
        ("MaskActive", "true"),
        ("MaskBlendMode", "0"),
        ("MaskInverted", "false"),
        ("MaskName", "Radial Gradient \(index + 1)"),
        ("MaskSyncID", newMaskSyncID()),
        ("MaskValue", "1"),
        ("Version", "2"),
    ]
}

/// The `CorrectionMasks` node tree for a brush mask: one `Mask/Aggregate` whose `Masks` are the
/// per-stroke `Mask/Paint` sub-masks (each carrying its `Dabs`). Additive strokes only — an
/// erase stroke can't be expressed as ACR `Dabs` (it round-trips through the app-private
/// preserve path instead), so `erase` strokes are skipped here.
nonisolated private func encodeBrushCorrectionMasks(_ brush: BrushMaskGeometry, name: String) -> [ACRMaskNode] {
    let paints: [ACRMaskNode] = brush.strokes.compactMap { stroke in
        guard !stroke.erase, !stroke.dabs.isEmpty else { return nil }
        var node = ACRMaskNode()
        node.fields = [
            ("What", "Mask/Paint"),
            ("MaskActive", "true"),
            ("MaskBlendMode", "0"),
            ("MaskInverted", "false"),
            ("MaskSyncID", newMaskSyncID()),
            ("MaskValue", acrNum(stroke.density)),
            ("Radius", acrNum(stroke.radius)),
            ("Flow", acrNum(stroke.dabs.first?.flow ?? 1.0)),
            ("CenterWeight", acrNum(stroke.dabs.first?.hardness ?? 0.0)),
        ]
        node.arrays = [("Dabs", encodeDabs(stroke.dabs))]
        return node
    }
    var aggregate = ACRMaskNode()
    aggregate.fields = [
        ("What", "Mask/Aggregate"),
        ("MaskActive", "true"),
        ("MaskBlendMode", "0"),
        ("MaskInverted", "false"),
        ("MaskName", name),
        ("MaskSyncID", newMaskSyncID()),
        ("MaskValue", "1"),
    ]
    aggregate.children = [("Masks", paints)]
    return [aggregate]
}

/// Encode a stroke's dabs as ACR `Dabs` records: `f <flow>` / `h <hardness>` whenever the value
/// changes (flow always emitted first; hardness only when it differs from ACR's implicit 0),
/// then `d <x> <y>` per dab using the current flow/hardness. The exact inverse of `parseDabs`.
nonisolated private func encodeDabs(_ dabs: [BrushDab]) -> [String] {
    var out: [String] = []
    var lastFlow: Double? = nil
    var lastHardness = 0.0  // ACR's implicit starting hardness (omits `h` while it's 0)
    for dab in dabs {
        if dab.flow != lastFlow {
            out.append("f " + String(format: "%.4f", dab.flow))
            lastFlow = dab.flow
        }
        if dab.hardness != lastHardness {
            out.append("h " + String(format: "%.4f", dab.hardness))
            lastHardness = dab.hardness
        }
        out.append("d " + String(format: "%.6f", dab.x) + " " + String(format: "%.6f", dab.y))
    }
    return out
}

/// The shared correction-level fields (effect sliders + legacy zeros) — identical for ellipse
/// and brush masks, since the effect is geometry-independent.
nonisolated private func encodeCorrectionFields(_ mask: MaskAdjustment) -> [(name: String, value: String)] {
    // ACR stores all local adjustments as fractions of their full range
    // (-1..+1). Exposure is on a -4..+4 EV range, so divide by 4.
    let exp = (mask.exposure ?? 0) / 4.0
    let con = Double(mask.contrast ?? 0) / 100.0
    let hi = Double(mask.highlights ?? 0) / 100.0
    let sh = Double(mask.shadows ?? 0) / 100.0
    let wh = Double(mask.whites ?? 0) / 100.0
    let bl = Double(mask.blacks ?? 0) / 100.0
    let sat = Double(mask.saturation ?? 0) / 100.0
    let vib = Double(mask.vibrance ?? 0) / 100.0
    let temp = (mask.temperature ?? 0) / 100.0
    let tint = (mask.tint ?? 0) / 100.0

    return [
        ("CorrectionActive", "true"),
        ("CorrectionAmount", acrNum(mask.amount)),
        ("CorrectionName", mask.name),
        ("CorrectionSyncID", mask.id.uuidString.replacingOccurrences(of: "-", with: "")),
        ("What", "Correction"),
        ("LocalExposure2012", acrNum(exp)),
        ("LocalContrast2012", acrNum(con)),
        ("LocalHighlights2012", acrNum(hi)),
        ("LocalShadows2012", acrNum(sh)),
        ("LocalWhites2012", acrNum(wh)),
        ("LocalBlacks2012", acrNum(bl)),
        ("LocalSaturation", acrNum(sat)),
        ("LocalVibrance", acrNum(vib)),
        ("LocalTemperature", acrNum(temp)),
        ("LocalTint", acrNum(tint)),
        // Legacy fields ACR still expects, all zero.
        ("LocalExposure", "0"),
        ("LocalContrast", "0"),
        ("LocalBrightness", "0"),
        ("LocalClarity", "0"),
        ("LocalClarity2012", "0"),
        ("LocalSharpness", "0"),
        ("LocalLuminanceNoise", "0"),
        ("LocalMoire", "0"),
        ("LocalDefringe", "0"),
        ("LocalDehaze", "0"),
        ("LocalTexture", "0"),
        ("LocalHue", "0"),
        ("LocalToningHue", "0"),
        ("LocalToningSaturation", "0"),
    ]
}

/// App-private (aaphoto) sibling fields with no ACR equivalent. Analytic masks retain their
/// CircularGradient fallback; AI masks use these fields with a wholly custom nested mask node.
nonisolated private func encodeMaskAppPrivateFields(_ mask: MaskAdjustment) -> [(name: String, value: String)] {
    var appPrivateFields: [(name: String, value: String)] = []
    if mask.isFullFrame {
        appPrivateFields.append(("FullFrame", "True"))
    }
    if let transform = mask.colorTransform {
        appPrivateFields.append(("ColorTransformMode", transform.mode.rawValue))
        if let name = transform.lutName, !name.isEmpty {
            appPrivateFields.append(("LUTName", name))
        }
        if let data = transform.lutData, !data.isEmpty, data.count <= 8_000_000 {
            appPrivateFields.append(("LUTData", data.base64EncodedString()))
        }
        appPrivateFields.append(("CSTInput", transform.inputSpace.rawValue))
        appPrivateFields.append(("CSTOutput", transform.outputSpace.rawValue))
    }
    if let cornerRadius = mask.geometry.cornerRadius, cornerRadius.isFinite,
       cornerRadius < 0.999999 {
        appPrivateFields.append(("CornerRadius", acrNum(min(max(cornerRadius, 0), 1))))
    }
    if let aiMask = mask.aiMask, aiMask.isValid, aiMask.pngData.count <= 2_000_000 {
        appPrivateFields.append(("AIMaskVersion", aiMask.hasRefinements ? "2" : "1"))
        appPrivateFields.append(("AIMaskWidth", String(aiMask.width)))
        appPrivateFields.append(("AIMaskHeight", String(aiMask.height)))
        appPrivateFields.append(("AIMaskOrientation", String(min(max(aiMask.sourceOrientation, 1), 8))))
        appPrivateFields.append(("AIMaskTarget", aiMask.resolvedTarget.rawValue))
        if aiMask.resolvedBlackPoint > 0.000001 {
            appPrivateFields.append(("AIMaskBlackPoint", acrNum(aiMask.resolvedBlackPoint)))
        }
        if aiMask.resolvedWhitePoint < 0.999999 {
            appPrivateFields.append(("AIMaskWhitePoint", acrNum(aiMask.resolvedWhitePoint)))
        }
        if aiMask.resolvedBlurRadius > 0.000001 {
            appPrivateFields.append(("AIMaskBlurRadius", acrNum(aiMask.resolvedBlurRadius)))
        }
        appPrivateFields.append(("AIMaskPNG", aiMask.pngData.base64EncodedString()))
    }
    if let anon = mask.anonymizer, !anon.isEmpty {
        if let amount = anon.amount, amount > 0 {
            appPrivateFields.append(("AnonymizerAmount", String(format: "%.1f", amount)))
        }
        if anon.blackOut == true {
            appPrivateFields.append(("AnonymizerBlackOut", "True"))
        }
    }
    return appPrivateFields
}

// MARK: - HSL per-color adjustments (shared encode/decode)

/// The seven Adobe Camera Raw HSL color channels: the ACR property-name suffix
/// (note `Aqua` for cyan and the ACR-custom `SkinTone`) paired with the writable
/// key path into `HSLAdjustments`. The single source of truth for the channel set
/// and its names — shared by every HSL read/write path so the embedded-file and
/// .xmp sidecar encodings can't drift. A function rather than a stored global
/// because `WritableKeyPath` isn't `Sendable`; the value is built fresh per call
/// and only used locally, never shared across isolation domains.
nonisolated func acrHSLChannels() -> [(acrName: String, keyPath: WritableKeyPath<HSLAdjustments, HSLColorAdjustment?>)] {
    [
        ("Red", \.red),
        ("Yellow", \.yellow),
        ("Green", \.green),
        ("Aqua", \.cyan),
        ("Blue", \.blue),
        ("Magenta", \.magenta),
        ("SkinTone", \.skinTone),
    ]
}

/// All 21 ACR HSL crs property names (e.g. `HueAdjustmentRed`) — the seven
/// channels × hue/saturation/luminance. Drives the embedded-file dict read loop
/// and the sidecar's clear-then-set write so neither hardcodes the name list.
nonisolated let acrHSLPropertyNames: [String] = acrHSLChannels().flatMap { channel in
    ["HueAdjustment", "SaturationAdjustment", "LuminanceAdjustment"].map { $0 + channel.acrName }
}

/// Encode per-color HSL adjustments into ACR `crs:` property name/value pairs
/// (signed-int strings, e.g. `+15`); only non-nil fields are emitted. Shared by
/// the embedded-XMP writer (`SwiftExifWriteEngine.applyHSL`) and the .xmp sidecar
/// writer (`XMPSidecarService`) so both destinations encode HSL identically.
nonisolated func encodeHSLAdjustments(_ hsl: HSLAdjustments) -> [(name: String, value: String)] {
    func signedInt(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    var out: [(name: String, value: String)] = []
    for channel in acrHSLChannels() {
        guard let adj = hsl[keyPath: channel.keyPath] else { continue }
        if let hue = adj.hueShift { out.append(("HueAdjustment\(channel.acrName)", signedInt(hue))) }
        if let sat = adj.saturation { out.append(("SaturationAdjustment\(channel.acrName)", signedInt(sat))) }
        if let lum = adj.luminance { out.append(("LuminanceAdjustment\(channel.acrName)", signedInt(lum))) }
    }
    return out
}

/// Decode per-color HSL adjustments from a property-name → signed-int `lookup` —
/// the exact inverse of `encodeHSLAdjustments`. Returns nil when no channel
/// carries a value. Shared by the embedded-file dict parsers
/// (`iptcMetadataFromDict`, `BrowserViewModel.cameraRawSettings`) and the .xmp
/// sidecar reader so every read path reconstructs HSL identically.
nonisolated func decodeHSLAdjustments(_ lookup: (String) -> Int?) -> HSLAdjustments? {
    var hsl = HSLAdjustments()
    for channel in acrHSLChannels() {
        let hue = lookup("HueAdjustment\(channel.acrName)")
        let sat = lookup("SaturationAdjustment\(channel.acrName)")
        let lum = lookup("LuminanceAdjustment\(channel.acrName)")
        guard hue != nil || sat != nil || lum != nil else { continue }
        hsl[keyPath: channel.keyPath] = HSLColorAdjustment(saturation: sat, luminance: lum, hueShift: hue)
    }
    return hsl.isEmpty ? nil : hsl
}

/// Construct an `IPTCMetadata` from a flat tag-name dictionary.
/// The dictionary keys match the canonical IPTC / XMP / EXIF tag names used by
/// `MetadataDictKey` so callers can either build the dict from SwiftExif's
/// typed model (`ImageMetadata`) or feed pre-existing JSON shaped that way.
nonisolated func iptcMetadataFromDict(_ dict: [String: Any]) -> IPTCMetadata {
    // crs fields hold Adobe's un-rotated-frame corner encoding; convert to the
    // app's upright-rect convention at this read boundary (identity at angle 0).
    let crop = CameraRawCrop(
        top: parseDoubleValue(dict[MetadataDictKey.crsCropTop]),
        left: parseDoubleValue(dict[MetadataDictKey.crsCropLeft]),
        bottom: parseDoubleValue(dict[MetadataDictKey.crsCropBottom]),
        right: parseDoubleValue(dict[MetadataDictKey.crsCropRight]),
        angle: parseDoubleValue(dict[MetadataDictKey.crsCropAngle]),
        hasCrop: parseBoolValue(dict[MetadataDictKey.crsHasCrop])
    ).decodedFromACR(aspect: metadataDictPixelAspect(dict))
    let cropValue = crop.isEmpty ? nil : crop
    let parsedMasks = parseMaskGroupBasedCorrections(dict[MetadataDictKey.maskGroupBasedCorrections])
    let localAdjustments = (parsedMasks?.masks).flatMap { $0.isEmpty ? nil : $0 }

    let tcMaster = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012])
    let tcRed = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012Red])
    let tcGreen = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012Green])
    let tcBlue = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012Blue])
    let toneCurve: ToneCurve? = {
        let tc = ToneCurve(master: tcMaster, red: tcRed, green: tcGreen, blue: tcBlue)
        return tc.isEmpty ? nil : tc
    }()

    var cameraRaw = CameraRawSettings(
        version: dict[MetadataDictKey.crsVersion] as? String,
        processVersion: dict[MetadataDictKey.crsProcessVersion] as? String,
        whiteBalance: dict[MetadataDictKey.crsWhiteBalance] as? String,
        temperature: parseIntValue(dict[MetadataDictKey.crsTemperature]),
        tint: parseIntValue(dict[MetadataDictKey.crsTint]),
        incrementalTemperature: parseIntValue(dict[MetadataDictKey.crsIncrementalTemperature]),
        incrementalTint: parseIntValue(dict[MetadataDictKey.crsIncrementalTint]),
        exposure2012: parseDoubleValue(dict[MetadataDictKey.crsExposure2012]),
        contrast2012: parseIntValue(dict[MetadataDictKey.crsContrast2012]),
        highlights2012: parseIntValue(dict[MetadataDictKey.crsHighlights2012]),
        shadows2012: parseIntValue(dict[MetadataDictKey.crsShadows2012]),
        whites2012: parseIntValue(dict[MetadataDictKey.crsWhites2012]),
        blacks2012: parseIntValue(dict[MetadataDictKey.crsBlacks2012]),
        saturation: parseIntValue(dict[MetadataDictKey.crsSaturation]),
        vibrance: parseIntValue(dict[MetadataDictKey.crsVibrance]),
        globalDensity: parseIntValue(dict[MetadataDictKey.globalDensity]),
        sharpness: parseIntValue(dict[MetadataDictKey.crsSharpness]),
        clarity2012: parseIntValue(dict[MetadataDictKey.crsClarity2012]),
        dehaze: parseIntValue(dict[MetadataDictKey.crsDehaze]),
        hasSettings: parseBoolValue(dict[MetadataDictKey.crsHasSettings]),
        crop: cropValue,
        hdrEditMode: parseIntValue(dict[MetadataDictKey.crsHDREditMode]),
        hdrMaxValue: dict[MetadataDictKey.crsHDRMaxValue] as? String,
        sdrBrightness: parseIntValue(dict[MetadataDictKey.crsSDRBrightness]),
        sdrContrast: parseIntValue(dict[MetadataDictKey.crsSDRContrast]),
        sdrClarity: parseIntValue(dict[MetadataDictKey.crsSDRClarity]),
        sdrHighlights: parseIntValue(dict[MetadataDictKey.crsSDRHighlights]),
        sdrShadows: parseIntValue(dict[MetadataDictKey.crsSDRShadows]),
        sdrWhites: parseIntValue(dict[MetadataDictKey.crsSDRWhites]),
        sdrBlend: parseIntValue(dict[MetadataDictKey.crsSDRBlend]),
        toneCurve: toneCurve,
        localAdjustments: localAdjustments,
        watermarkLayers: parseWatermarkLayers(dict[MetadataDictKey.watermarkLayers]),
        hslAdjustments: decodeHSLAdjustments { parseIntValue(dict[$0]) }
    )
    // Reconstruct the reorderable layer chain: masks are already in render-stack order; the
    // app-private GlobalLayerIndex (if present) says where the global node sits among them.
    // This legacy encoding can't place a watermark layer, so if the fully-explicit
    // `aaphoto:LayerOrder` is present (written whenever any watermark layer exists), it takes
    // priority over the GlobalLayerIndex reconstruction.
    cameraRaw.layerOrder = CameraRawSettings.layerOrder(
        masks: localAdjustments,
        globalIndex: parseIntValue(dict[MetadataDictKey.globalLayerIndex])
    )
    if let explicitOrder = parseExplicitLayerOrder(dict[MetadataDictKey.layerOrderExplicit]) {
        cameraRaw.layerOrder = explicitOrder
    }
    // Corrections we can't model (erase-brush blobs, unknown mask types) — kept verbatim so a
    // develop save re-emits them instead of dropping them.
    if let preserved = parsedMasks?.preserved, !preserved.isEmpty {
        cameraRaw.unparsedMaskCorrections = preserved
    }
    // App-private Anonymizer redaction (not an ACR concept — Adobe tools ignore it).
    let anonymizerAmount = parseDoubleValue(dict[MetadataDictKey.anonymizerAmount])
    let anonymizerBlackOut = parseBoolValue(dict[MetadataDictKey.anonymizerBlackOut])
    if (anonymizerAmount ?? 0) > 0 || anonymizerBlackOut == true {
        cameraRaw.anonymizer = AnonymizerSettings(amount: anonymizerAmount, blackOut: anonymizerBlackOut)
    }
    let film = FilmEmulationSettings(
        grain: parseDoubleValue(dict[MetadataDictKey.filmGrain]),
        grainCoarseness: parseDoubleValue(dict[MetadataDictKey.filmGrainCoarseness]),
        halation: parseDoubleValue(dict[MetadataDictKey.filmHalation]),
        bloom: parseDoubleValue(dict[MetadataDictKey.filmBloom]),
        vignette: parseDoubleValue(dict[MetadataDictKey.filmVignette]),
        edgeBlur: parseDoubleValue(dict[MetadataDictKey.filmEdgeBlur])
    )
    if !film.isEmpty {
        cameraRaw.filmEmulation = film
    }

    return IPTCMetadata(
        title: dict[MetadataDictKey.headline] as? String
            ?? dict[MetadataDictKey.title] as? String
            ?? dict[MetadataDictKey.objectName] as? String,
        description: dict[MetadataDictKey.description] as? String
            ?? dict[MetadataDictKey.captionAbstract] as? String,
        extendedDescription: dict[MetadataDictKey.extDescrAccessibility] as? String,
        keywords: parseStringOrArray(dict[MetadataDictKey.subject] ?? dict[MetadataDictKey.keywords]),
        personShown: parseStringOrArray(dict[MetadataDictKey.personInImage]),
        organisationsShownNames: parseStringOrArray(dict[MetadataDictKey.organisationInImageName]),
        organisationsShownCodes: parseStringOrArray(dict[MetadataDictKey.organisationInImageCode]),
        digitalSourceType: (dict[MetadataDictKey.digitalSourceType] as? String)
            .flatMap { DigitalSourceType(metadataValue: $0) },
        latitude: dict[MetadataDictKey.gpsLatitude] as? Double,
        longitude: dict[MetadataDictKey.gpsLongitude] as? Double,
        creator: parseFirstString(dict[MetadataDictKey.creator] ?? dict[MetadataDictKey.byLine]),
        creatorJobTitle: dict[MetadataDictKey.creatorJobTitle] as? String
            ?? dict[MetadataDictKey.byLineTitle] as? String,
        descriptionWriter: dict[MetadataDictKey.descriptionWriter] as? String
            ?? dict[MetadataDictKey.writerEditor] as? String,
        credit: dict[MetadataDictKey.credit] as? String,
        copyright: dict[MetadataDictKey.rights] as? String
            ?? dict[MetadataDictKey.copyrightNotice] as? String,
        rightsUsageTerms: dict[MetadataDictKey.rightsUsageTerms] as? String,
        webStatementOfRights: dict[MetadataDictKey.webStatementOfRights] as? String,
        jobId: dict[MetadataDictKey.transmissionReference] as? String
            ?? dict[MetadataDictKey.jobID] as? String
            ?? dict[MetadataDictKey.originalTransmissionReference] as? String,
        dateCreated: dict[MetadataDictKey.dateCreated] as? String
            ?? dict[MetadataDictKey.createDate] as? String,
        captureDate: dict[MetadataDictKey.dateTimeOriginal] as? String,
        city: dict[MetadataDictKey.city] as? String,
        sublocation: dict[MetadataDictKey.location] as? String
            ?? dict[MetadataDictKey.sublocation] as? String,
        provinceState: dict[MetadataDictKey.state] as? String
            ?? dict[MetadataDictKey.provinceState] as? String,
        country: dict[MetadataDictKey.country] as? String
            ?? dict[MetadataDictKey.countryPrimaryLocationName] as? String,
        countryCode: dict[MetadataDictKey.countryCode] as? String
            ?? dict[MetadataDictKey.countryPrimaryLocationCode] as? String,
        event: dict[MetadataDictKey.event] as? String,
        instructions: dict[MetadataDictKey.instructions] as? String
            ?? dict[MetadataDictKey.specialInstructions] as? String,
        source: dict[MetadataDictKey.source] as? String,
        creatorContactInfo: parseCreatorContactInfo(dict[MetadataDictKey.creatorContactInfo]),
        locationsCreated: parseEditorialLocations(dict[MetadataDictKey.locationCreated]),
        locationsShown: parseEditorialLocations(dict[MetadataDictKey.locationShown]),
        rating: dict[MetadataDictKey.rating] as? Int,
        label: ColorLabel.canonicalMetadataLabel(dict[MetadataDictKey.label] as? String),
        cameraRaw: (cameraRaw.isEmpty || crsIsAlreadyApplied(in: dict)) ? nil : cameraRaw,
        exifOrientation: parseIntValue(dict[MetadataDictKey.orientation])
    )
}

/// True when a file's crs block is marked `AlreadyApplied="True"` — the develop
/// settings are already baked into the pixels (e.g. our own export, or a JPEG ACR
/// rendered from RAW), so they must NOT be re-loaded as live edits or they would be
/// applied a second time on top of the baked render. Absence or `"False"` means the
/// settings are live and editable.
nonisolated func crsIsAlreadyApplied(in dict: [String: Any]) -> Bool {
    guard let raw = dict[MetadataDictKey.crsAlreadyApplied] as? String else { return false }
    return raw.caseInsensitiveCompare("True") == .orderedSame
}

/// Detect a Description vs IPTC Caption-Abstract conflict.
nonisolated func descriptionConflict(in dict: [String: Any]) -> DescriptionConflict? {
    guard let xmp = dict[MetadataDictKey.description] as? String, !xmp.isEmpty,
          let iptc = dict[MetadataDictKey.captionAbstract] as? String, !iptc.isEmpty,
          xmp != iptc else { return nil }
    return DescriptionConflict(xmpDescription: xmp, iptcCaptionAbstract: iptc)
}
