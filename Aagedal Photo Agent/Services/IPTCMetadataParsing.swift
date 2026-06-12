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
    static let digitalSourceType = "DigitalSourceType"
    static let gpsLatitude = "GPSLatitude"
    static let gpsLongitude = "GPSLongitude"
    static let creator = "Creator"
    static let byLine = "By-line"
    static let credit = "Credit"
    static let rights = "Rights"
    static let copyrightNotice = "CopyrightNotice"
    static let transmissionReference = "TransmissionReference"
    static let jobID = "JobID"
    static let originalTransmissionReference = "OriginalTransmissionReference"
    static let dateCreated = "DateCreated"
    static let createDate = "CreateDate"
    static let dateTimeOriginal = "DateTimeOriginal"
    static let city = "City"
    static let country = "Country"
    static let countryPrimaryLocationName = "Country-PrimaryLocationName"
    static let event = "Event"
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
    static let crsHasSettings = "HasSettings"
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
    guard let array = value as? [String], array.count > 2 else { return nil }
    let points = array.compactMap { str -> ToneCurvePoint? in
        let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else { return nil }
        return ToneCurvePoint(acr255: x, y)
    }
    return points.count > 2 ? points : nil
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

/// Parse Adobe Camera Raw `MaskGroupBasedCorrections` into `[MaskAdjustment]`.
/// Each correction is a dictionary with `CorrectionMasks` as a nested array
/// of mask geometry dictionaries. Corrections whose geometry can't be parsed
/// (unsupported mask type, missing corner fields) are dropped — substituting a
/// default ellipse would silently misrender them.
nonisolated func parseMaskGroupBasedCorrections(_ value: Any?) -> [MaskAdjustment]? {
    guard let corrections = value as? [[String: Any]], !corrections.isEmpty else { return nil }
    var masks: [MaskAdjustment] = []
    for (index, corr) in corrections.enumerated() {
        let active = parseBoolValue(crsMaskField(corr, "CorrectionActive")) ?? true
        let amount = parseDoubleValue(crsMaskField(corr, "CorrectionAmount")) ?? 1.0
        let name = crsMaskField(corr, "CorrectionName") as? String ?? "Mask \(index + 1)"

        guard let maskArray = crsMaskField(corr, "CorrectionMasks") as? [[String: Any]],
              let maskDict = maskArray.first,
              (crsMaskField(maskDict, "What") as? String) == "Mask/CircularGradient",
              let top = parseDoubleValue(crsMaskField(maskDict, "Top")),
              let left = parseDoubleValue(crsMaskField(maskDict, "Left")),
              let bottom = parseDoubleValue(crsMaskField(maskDict, "Bottom")),
              let right = parseDoubleValue(crsMaskField(maskDict, "Right"))
        else {
            parsingLog.warning("Dropping MaskGroupBasedCorrections[\(index)] (\(name, privacy: .public)): mask geometry failed to parse")
            continue
        }

        var geometry = EllipseMaskGeometry()
        geometry.centerX = (left + right) / 2
        geometry.centerY = (top + bottom) / 2
        // ACR's (Left,Top)/(Right,Bottom) are opposite corners of the ellipse's
        // ORIENTED bounding rect — the corner vector rotates with the ellipse in
        // aspect-corrected (pixel) space, so for rotated masks Left can exceed
        // Right and these half-extents are signed, NOT the semi-axes. The true
        // radii are recovered by un-rotating the corner vector at render time
        // (see EllipseMaskGeometry); at Angle=0 they coincide.
        geometry.radiusX = (right - left) / 2
        geometry.radiusY = (bottom - top) / 2
        geometry.rotation = parseDoubleValue(crsMaskField(maskDict, "Angle")) ?? 0
        geometry.feather = parseDoubleValue(crsMaskField(maskDict, "Feather")) ?? 50
        // ACR Flipped=true means effect applies inside the ellipse;
        // our inverted=true means effect applies outside. Negate.
        let inverted = !(parseBoolValue(crsMaskField(maskDict, "Flipped")) ?? true)

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

        let mask = MaskAdjustment(
            name: name,
            enabled: active,
            inverted: inverted,
            amount: amount,
            geometry: geometry,
            exposure: exposure.flatMap { abs($0) < 0.001 ? nil : $0 },
            contrast: contrast.flatMap { $0 == 0 ? nil : $0 },
            highlights: highlights.flatMap { $0 == 0 ? nil : $0 },
            shadows: shadows.flatMap { $0 == 0 ? nil : $0 },
            whites: whites.flatMap { $0 == 0 ? nil : $0 },
            blacks: blacks.flatMap { $0 == 0 ? nil : $0 },
            saturation: saturation.flatMap { $0 == 0 ? nil : $0 },
            vibrance: vibrance.flatMap { $0 == 0 ? nil : $0 },
            temperature: temperature.flatMap { abs($0) < 0.01 ? nil : $0 },
            tint: tint.flatMap { abs($0) < 0.01 ? nil : $0 }
        )
        masks.append(mask)
    }
    return masks.isEmpty ? nil : masks
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
    let localAdjustments = parseMaskGroupBasedCorrections(dict[MetadataDictKey.maskGroupBasedCorrections])

    let tcMaster = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012])
    let tcRed = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012Red])
    let tcGreen = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012Green])
    let tcBlue = parseToneCurveArray(dict[MetadataDictKey.crsToneCurvePV2012Blue])
    let toneCurve: ToneCurve? = {
        let tc = ToneCurve(master: tcMaster, red: tcRed, green: tcGreen, blue: tcBlue)
        return tc.isEmpty ? nil : tc
    }()

    let cameraRaw = CameraRawSettings(
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
        localAdjustments: localAdjustments
    )

    return IPTCMetadata(
        title: dict[MetadataDictKey.headline] as? String
            ?? dict[MetadataDictKey.title] as? String
            ?? dict[MetadataDictKey.objectName] as? String,
        description: dict[MetadataDictKey.description] as? String
            ?? dict[MetadataDictKey.captionAbstract] as? String,
        extendedDescription: dict[MetadataDictKey.extDescrAccessibility] as? String,
        keywords: parseStringOrArray(dict[MetadataDictKey.subject] ?? dict[MetadataDictKey.keywords]),
        personShown: parseStringOrArray(dict[MetadataDictKey.personInImage]),
        digitalSourceType: (dict[MetadataDictKey.digitalSourceType] as? String)
            .flatMap { DigitalSourceType(rawValue: $0) },
        latitude: dict[MetadataDictKey.gpsLatitude] as? Double,
        longitude: dict[MetadataDictKey.gpsLongitude] as? Double,
        creator: parseFirstString(dict[MetadataDictKey.creator] ?? dict[MetadataDictKey.byLine]),
        credit: dict[MetadataDictKey.credit] as? String,
        copyright: dict[MetadataDictKey.rights] as? String
            ?? dict[MetadataDictKey.copyrightNotice] as? String,
        jobId: dict[MetadataDictKey.transmissionReference] as? String
            ?? dict[MetadataDictKey.jobID] as? String
            ?? dict[MetadataDictKey.originalTransmissionReference] as? String,
        dateCreated: dict[MetadataDictKey.dateCreated] as? String
            ?? dict[MetadataDictKey.createDate] as? String,
        captureDate: dict[MetadataDictKey.dateTimeOriginal] as? String,
        city: dict[MetadataDictKey.city] as? String,
        country: dict[MetadataDictKey.country] as? String
            ?? dict[MetadataDictKey.countryPrimaryLocationName] as? String,
        event: dict[MetadataDictKey.event] as? String,
        rating: dict[MetadataDictKey.rating] as? Int,
        label: ColorLabel.canonicalMetadataLabel(dict[MetadataDictKey.label] as? String),
        cameraRaw: cameraRaw.isEmpty ? nil : cameraRaw,
        exifOrientation: parseIntValue(dict[MetadataDictKey.orientation])
    )
}

/// Detect a Description vs IPTC Caption-Abstract conflict.
nonisolated func descriptionConflict(in dict: [String: Any]) -> DescriptionConflict? {
    guard let xmp = dict[MetadataDictKey.description] as? String, !xmp.isEmpty,
          let iptc = dict[MetadataDictKey.captionAbstract] as? String, !iptc.isEmpty,
          xmp != iptc else { return nil }
    return DescriptionConflict(xmpDescription: xmp, iptcCaptionAbstract: iptc)
}
