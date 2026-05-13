import Foundation
import SwiftExif
import os

private let swiftExifLog = Logger(subsystem: "com.aagedal.photo-agent", category: "SwiftExifWriteEngine")

/// XMP namespace URI for Adobe Camera Raw Settings.
private let crsNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

/// Native, in-process metadata write engine. Reads and re-emits the image file
/// via SwiftExif. There is no external process and no fallback path.
final class SwiftExifWriteEngine: MetadataWriteEngine, @unchecked Sendable {

    init() {}

    func writeFields(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws {
        guard !urls.isEmpty, !fields.isEmpty || !structuredData.isEmpty else { return }

        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        for url in urls {
            try Task.checkCancellation()
            try writeFieldsToFile(fields, structuredData: structuredData, url: url)
        }
    }

    func addRemoveListValues(
        add: [MetadataFieldKey: [String]],
        remove: [MetadataFieldKey: [String]],
        to urls: [URL]
    ) async throws {
        guard !urls.isEmpty else { return }
        let hasAdd = add.values.contains { !$0.isEmpty }
        let hasRemove = remove.values.contains { !$0.isEmpty }
        guard hasAdd || hasRemove else { return }

        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        for url in urls {
            try Task.checkCancellation()
            var metadata = try readMetadata(from: url)

            for (key, valuesToRemove) in remove {
                guard !valuesToRemove.isEmpty else { continue }
                applyListRemove(key: key, values: valuesToRemove, metadata: &metadata)
            }

            for (key, valuesToAdd) in add {
                guard !valuesToAdd.isEmpty else { continue }
                applyListAdd(key: key, values: valuesToAdd, metadata: &metadata)
            }

            metadata.syncIPTCToXMP()
            try metadata.write(to: url)
        }
    }

    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        let value = rating == .none ? "" : String(rating.rawValue)

        for url in urls {
            try Task.checkCancellation()
            var metadata = try readMetadata(from: url)
            if value.isEmpty {
                metadata.xmp?.removeValue(namespace: XMPNamespace.xmp, property: "Rating")
            } else {
                if metadata.xmp == nil { metadata.xmp = XMPData() }
                metadata.xmp?.setValue(.simple(value), namespace: XMPNamespace.xmp, property: "Rating")
            }
            try metadata.write(to: url)
        }
    }

    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        let value = label.xmpLabelValue ?? ""

        for url in urls {
            try Task.checkCancellation()
            var metadata = try readMetadata(from: url)
            if value.isEmpty {
                metadata.xmp?.removeValue(namespace: XMPNamespace.xmp, property: "Label")
            } else {
                if metadata.xmp == nil { metadata.xmp = XMPData() }
                metadata.xmp?.setValue(.simple(value), namespace: XMPNamespace.xmp, property: "Label")
            }
            try metadata.write(to: url)
        }
    }

    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        for url in urls {
            try Task.checkCancellation()
            var metadata = try readMetadata(from: url)
            metadata.setOrientation(UInt16(clamping: orientation))
            try metadata.write(to: url)
        }
    }

    func stripIPTCAndXMP(from urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        for url in urls {
            try Task.checkCancellation()
            var metadata = try readMetadata(from: url)
            metadata.iptc = IPTCData()
            metadata.xmp = nil
            try metadata.write(to: url)
        }
    }

    func copyMetadataToRenderedFile(from source: URL, to destination: URL) async throws {
        let creationDates = captureCreationDates(for: [destination])
        defer { restoreCreationDates(creationDates) }

        let sourceMetadata: ImageMetadata
        do {
            sourceMetadata = try readMetadata(from: source)
        } catch {
            swiftExifLog.error(
                "copyMetadataToRenderedFile: read source failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        var destMetadata: ImageMetadata
        do {
            destMetadata = try readMetadata(from: destination)
        } catch {
            swiftExifLog.error(
                "copyMetadataToRenderedFile: read destination failed for \(destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        // Copy IPTC + XMP wholesale, then strip Camera Raw and supersize-to-Standard
        // tags that would mislead viewers about the rendered output.
        destMetadata.iptc = sourceMetadata.iptc
        destMetadata.xmp = sourceMetadata.xmp

        // Drop every Adobe Camera Raw property the source may have carried.
        // The rendered file is the baked-in result, so leaving these around
        // would let editors apply the adjustments a second time.
        for property in cameraRawPropertyNames {
            destMetadata.xmp?.removeValue(namespace: crsNamespace, property: property)
        }

        // Drop the IFD1 thumbnail and ICC profile from the source — the renderer
        // is expected to set its own profile and produce a fresh thumbnail when
        // emitting the new file.
        destMetadata.exif?.ifd1 = nil
        destMetadata.stripICCProfile()

        // Force orientation to 1 — rendered pixels are already upright.
        destMetadata.setOrientation(1)

        do {
            try destMetadata.write(to: destination)
        } catch {
            swiftExifLog.error(
                "copyMetadataToRenderedFile: write failed for \(destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Private Helpers

    private func writeFieldsToFile(
        _ fields: [MetadataFieldKey: String],
        structuredData: StructuredWriteData,
        url: URL
    ) throws {
        var metadata = try readMetadata(from: url)

        // GPS coordinates are paired: SwiftExif's setGPS takes both at once
        // (refs are derived from sign). Pull them out before the per-field loop.
        let latString = fields[.gpsLatitude]
        let lonString = fields[.gpsLongitude]
        let bothCleared = (latString?.isEmpty ?? false) && (lonString?.isEmpty ?? false)
        if let latString, let lonString, !latString.isEmpty, !lonString.isEmpty,
           let lat = Double(latString), let lon = Double(lonString) {
            metadata.setGPS(latitude: lat, longitude: lon)
        } else if bothCleared {
            metadata.removeGPS()
        }

        for (key, value) in fields {
            // GPS handled above; refs are derived in setGPS.
            switch key {
            case .gpsLatitude, .gpsLongitude, .gpsLatitudeRef, .gpsLongitudeRef:
                continue
            default:
                applyField(key: key, value: value, metadata: &metadata)
            }
        }

        if let tc = structuredData.toneCurve {
            applyToneCurves(tc, metadata: &metadata)
        }

        if let masks = structuredData.masks {
            applyMasks(masks, metadata: &metadata)
        }

        // Sync IPTC → XMP to ensure both sides are consistent.
        metadata.syncIPTCToXMP()

        try metadata.write(to: url)
    }

    /// Apply a single field to the metadata.
    private func applyField(key: MetadataFieldKey, value: String, metadata: inout ImageMetadata) {
        let isEmpty = value.isEmpty

        switch key {
        // IPTC fields — set on IPTC, syncIPTCToXMP fills XMP
        case .headline:
            if isEmpty {
                metadata.iptc.removeAll(for: .headline)
                metadata.iptc.removeAll(for: .objectName)
            } else {
                metadata.iptc.headline = value
                metadata.iptc.objectName = value
            }

        case .description:
            if isEmpty {
                metadata.iptc.removeAll(for: .captionAbstract)
            } else {
                metadata.iptc.caption = value
            }

        case .subject:
            metadata.iptc.removeAll(for: .keywords)
            if !isEmpty {
                let keywords = value.components(separatedBy: ", ")
                metadata.iptc.keywords = keywords
            }

        case .creator:
            if isEmpty {
                metadata.iptc.removeAll(for: .byline)
            } else {
                metadata.iptc.byline = value
            }

        case .credit:
            if isEmpty {
                metadata.iptc.removeAll(for: .credit)
            } else {
                metadata.iptc.credit = value
            }

        case .rights:
            if isEmpty {
                metadata.iptc.removeAll(for: .copyrightNotice)
            } else {
                metadata.iptc.copyright = value
            }

        case .transmissionReference:
            if isEmpty {
                metadata.iptc.removeAll(for: .originalTransmissionReference)
            } else {
                metadata.iptc.jobId = value
            }

        case .dateCreated:
            if isEmpty {
                metadata.iptc.removeAll(for: .dateCreated)
            } else {
                metadata.iptc.dateCreated = value
            }

        case .city:
            if isEmpty {
                metadata.iptc.removeAll(for: .city)
            } else {
                metadata.iptc.city = value
            }

        case .country:
            if isEmpty {
                metadata.iptc.removeAll(for: .countryPrimaryLocationName)
            } else {
                metadata.iptc.countryName = value
            }

        // XMP-only fields
        case .extendedDescription:
            setXMPField(&metadata, namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility",
                        value: isEmpty ? nil : .langAlternative(value))

        case .personInImage:
            if isEmpty {
                metadata.xmp?.removeValue(namespace: XMPNamespace.iptcExt, property: "PersonInImage")
            } else {
                let persons = value.components(separatedBy: ", ")
                if metadata.xmp == nil { metadata.xmp = XMPData() }
                metadata.xmp?.setValue(.array(persons), namespace: XMPNamespace.iptcExt, property: "PersonInImage")
            }

        case .digitalSourceType:
            setXMPField(&metadata, namespace: XMPNamespace.iptcExt, property: "DigitalSourceType",
                        value: isEmpty ? nil : .simple(value))

        case .event:
            setXMPField(&metadata, namespace: XMPNamespace.iptcExt, property: "Event",
                        value: isEmpty ? nil : .langAlternative(value))

        case .xmpTitle:
            setXMPField(&metadata, namespace: XMPNamespace.dc, property: "title",
                        value: isEmpty ? nil : .langAlternative(value))

        case .rating:
            setXMPField(&metadata, namespace: XMPNamespace.xmp, property: "Rating",
                        value: isEmpty ? nil : .simple(value))

        case .label:
            setXMPField(&metadata, namespace: XMPNamespace.xmp, property: "Label",
                        value: isEmpty ? nil : .simple(value))

        // EXIF IFD: orientation
        case .orientation:
            if isEmpty {
                metadata.resetOrientation()
            } else if let parsed = Int(value) {
                metadata.setOrientation(UInt16(clamping: parsed))
            }

        // GPS coordinates are handled in `writeFieldsToFile` (paired write
        // via `setGPS`); these cases should never be reached but are here
        // to keep the switch exhaustive.
        case .gpsLatitude, .gpsLongitude, .gpsLatitudeRef, .gpsLongitudeRef:
            break

        // Camera Raw simple fields
        case .crsVersion: setCRSField(&metadata, property: "Version", value: value)
        case .crsProcessVersion: setCRSField(&metadata, property: "ProcessVersion", value: value)
        case .crsWhiteBalance: setCRSField(&metadata, property: "WhiteBalance", value: value)
        case .crsTemperature: setCRSField(&metadata, property: "Temperature", value: value)
        case .crsTint: setCRSField(&metadata, property: "Tint", value: value)
        case .crsIncrementalTemperature: setCRSField(&metadata, property: "IncrementalTemperature", value: value)
        case .crsIncrementalTint: setCRSField(&metadata, property: "IncrementalTint", value: value)
        case .crsExposure2012: setCRSField(&metadata, property: "Exposure2012", value: value)
        case .crsContrast2012: setCRSField(&metadata, property: "Contrast2012", value: value)
        case .crsHighlights2012: setCRSField(&metadata, property: "Highlights2012", value: value)
        case .crsShadows2012: setCRSField(&metadata, property: "Shadows2012", value: value)
        case .crsWhites2012: setCRSField(&metadata, property: "Whites2012", value: value)
        case .crsBlacks2012: setCRSField(&metadata, property: "Blacks2012", value: value)
        case .crsSaturation: setCRSField(&metadata, property: "Saturation", value: value)
        case .crsVibrance: setCRSField(&metadata, property: "Vibrance", value: value)
        case .crsHasSettings: setCRSField(&metadata, property: "HasSettings", value: value)
        case .crsCropTop: setCRSField(&metadata, property: "CropTop", value: value)
        case .crsCropLeft: setCRSField(&metadata, property: "CropLeft", value: value)
        case .crsCropBottom: setCRSField(&metadata, property: "CropBottom", value: value)
        case .crsCropRight: setCRSField(&metadata, property: "CropRight", value: value)
        case .crsCropAngle: setCRSField(&metadata, property: "CropAngle", value: value)
        case .crsHasCrop: setCRSField(&metadata, property: "HasCrop", value: value)
        case .crsCropConstrainToWarp: setCRSField(&metadata, property: "CropConstrainToWarp", value: value)
        case .crsCropConstrainToUnitSquare: setCRSField(&metadata, property: "CropConstrainToUnitSquare", value: value)
        case .crsHDREditMode: setCRSField(&metadata, property: "HDREditMode", value: value)
        case .crsHDRMaxValue: setCRSField(&metadata, property: "HDRMaxValue", value: value)
        case .crsSDRBrightness: setCRSField(&metadata, property: "SDRBrightness", value: value)
        case .crsSDRContrast: setCRSField(&metadata, property: "SDRContrast", value: value)
        case .crsSDRClarity: setCRSField(&metadata, property: "SDRClarity", value: value)
        case .crsSDRHighlights: setCRSField(&metadata, property: "SDRHighlights", value: value)
        case .crsSDRShadows: setCRSField(&metadata, property: "SDRShadows", value: value)
        case .crsSDRWhites: setCRSField(&metadata, property: "SDRWhites", value: value)
        case .crsSDRBlend: setCRSField(&metadata, property: "SDRBlend", value: value)
        case .crsToneCurveName2012: setCRSField(&metadata, property: "ToneCurveName2012", value: value)
        }
    }

    /// Apply tone curves as XMP-crs array values.
    private func applyToneCurves(_ tc: ToneCurve, metadata: inout ImageMetadata) {
        if metadata.xmp == nil { metadata.xmp = XMPData() }

        func setChannel(_ property: String, _ points: [ToneCurvePoint]?) {
            if let points, points.count > 2 {
                let values = points.map { "\(Int(round($0.x * 255))), \(Int(round($0.y * 255)))" }
                metadata.xmp?.setValue(.array(values), namespace: crsNamespace, property: property)
            } else {
                metadata.xmp?.removeValue(namespace: crsNamespace, property: property)
            }
        }

        setChannel("ToneCurvePV2012", tc.master)
        setChannel("ToneCurvePV2012Red", tc.red)
        setChannel("ToneCurvePV2012Green", tc.green)
        setChannel("ToneCurvePV2012Blue", tc.blue)

        if !tc.isEmpty {
            metadata.xmp?.setValue(.simple("Custom"), namespace: crsNamespace, property: "ToneCurveName2012")
        } else {
            metadata.xmp?.removeValue(namespace: crsNamespace, property: "ToneCurveName2012")
        }
    }

    /// Serialize local mask adjustments to ACR's `MaskGroupBasedCorrections`
    /// schema as a recursive XMP structured array. Each correction is a
    /// `[String: XMPValue]` dict whose `CorrectionMasks` field is itself a
    /// nested `XMPValue.structuredArray`.
    private func applyMasks(_ masks: [MaskAdjustment], metadata: inout ImageMetadata) {
        let enabled = masks.filter(\.enabled)
        if enabled.isEmpty {
            metadata.xmp?.removeValue(namespace: crsNamespace, property: "MaskGroupBasedCorrections")
            return
        }

        if metadata.xmp == nil { metadata.xmp = XMPData() }

        let corrections: [[String: XMPValue]] = enabled.enumerated().map { index, mask in
            let geo = mask.geometry
            let top = geo.centerY - geo.radiusY
            let left = geo.centerX - geo.radiusX
            let bottom = geo.centerY + geo.radiusY
            let right = geo.centerX + geo.radiusX

            let corrSyncID = mask.id.uuidString.replacingOccurrences(of: "-", with: "")
            let maskSyncID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

            let maskStruct: [String: XMPValue] = [
                "What": .simple("Mask/CircularGradient"),
                "Top": .simple(acrNum(top)),
                "Left": .simple(acrNum(left)),
                "Bottom": .simple(acrNum(bottom)),
                "Right": .simple(acrNum(right)),
                "Angle": .simple(acrNum(geo.rotation)),
                "Feather": .simple(acrNum(geo.feather)),
                "Midpoint": .simple("50"),
                "Roundness": .simple("0"),
                // ACR Flipped=true means effect applies inside the ellipse;
                // our `inverted=true` means effect applies outside. Negate.
                "Flipped": .simple(mask.inverted ? "false" : "true"),
                "MaskActive": .simple("true"),
                "MaskBlendMode": .simple("0"),
                "MaskInverted": .simple("false"),
                "MaskName": .simple("Radial Gradient \(index + 1)"),
                "MaskSyncID": .simple(maskSyncID),
                "MaskValue": .simple("1"),
                "Version": .simple("2")
            ]

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
                "CorrectionActive": .simple("true"),
                "CorrectionAmount": .simple(acrNum(mask.amount)),
                "CorrectionName": .simple(mask.name),
                "CorrectionSyncID": .simple(corrSyncID),
                "What": .simple("Correction"),
                "CorrectionMasks": .structuredArray([maskStruct]),
                "LocalExposure2012": .simple(acrNum(exp)),
                "LocalContrast2012": .simple(acrNum(con)),
                "LocalHighlights2012": .simple(acrNum(hi)),
                "LocalShadows2012": .simple(acrNum(sh)),
                "LocalWhites2012": .simple(acrNum(wh)),
                "LocalBlacks2012": .simple(acrNum(bl)),
                "LocalSaturation": .simple(acrNum(sat)),
                "LocalVibrance": .simple(acrNum(vib)),
                "LocalTemperature": .simple(acrNum(temp)),
                "LocalTint": .simple(acrNum(tint)),
                // Legacy fields ACR still expects, all zero.
                "LocalExposure": .simple("0"),
                "LocalContrast": .simple("0"),
                "LocalBrightness": .simple("0"),
                "LocalClarity": .simple("0"),
                "LocalClarity2012": .simple("0"),
                "LocalSharpness": .simple("0"),
                "LocalLuminanceNoise": .simple("0"),
                "LocalMoire": .simple("0"),
                "LocalDefringe": .simple("0"),
                "LocalDehaze": .simple("0"),
                "LocalTexture": .simple("0"),
                "LocalHue": .simple("0"),
                "LocalToningHue": .simple("0"),
                "LocalToningSaturation": .simple("0")
            ]
        }

        metadata.xmp?.setValue(
            .structuredArray(corrections),
            namespace: crsNamespace,
            property: "MaskGroupBasedCorrections"
        )
    }

    /// Set an XMP field, creating XMPData if needed. Pass nil value to remove.
    private func setXMPField(_ metadata: inout ImageMetadata, namespace: String, property: String, value: XMPValue?) {
        if let value {
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            metadata.xmp?.setValue(value, namespace: namespace, property: property)
        } else {
            metadata.xmp?.removeValue(namespace: namespace, property: property)
        }
    }

    /// Set a Camera Raw Settings (XMP-crs) field.
    private func setCRSField(_ metadata: inout ImageMetadata, property: String, value: String) {
        if value.isEmpty {
            metadata.xmp?.removeValue(namespace: crsNamespace, property: property)
        } else {
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            metadata.xmp?.setValue(.simple(value), namespace: crsNamespace, property: property)
        }
    }

    // MARK: - List Operations

    private func applyListRemove(key: MetadataFieldKey, values: [String], metadata: inout ImageMetadata) {
        switch key {
        case .subject:
            var existing = metadata.iptc.keywords
            existing.removeAll { values.contains($0) }
            metadata.iptc.removeAll(for: .keywords)
            metadata.iptc.keywords = existing

        case .personInImage:
            if let xmpPersons = metadata.xmp?.personInImage {
                var existing = xmpPersons
                existing.removeAll { values.contains($0) }
                if existing.isEmpty {
                    metadata.xmp?.removeValue(namespace: XMPNamespace.iptcExt, property: "PersonInImage")
                } else {
                    metadata.xmp?.setValue(.array(existing), namespace: XMPNamespace.iptcExt, property: "PersonInImage")
                }
            }

        default:
            swiftExifLog.warning("addRemoveListValues: unsupported key \(key.rawValue, privacy: .public) for remove")
        }
    }

    private func applyListAdd(key: MetadataFieldKey, values: [String], metadata: inout ImageMetadata) {
        switch key {
        case .subject:
            var existing = metadata.iptc.keywords
            for value in values {
                existing.removeAll { $0 == value }
                existing.append(value)
            }
            metadata.iptc.removeAll(for: .keywords)
            metadata.iptc.keywords = existing

        case .personInImage:
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            var existing = metadata.xmp?.personInImage ?? []
            for value in values {
                existing.removeAll { $0 == value }
                existing.append(value)
            }
            metadata.xmp?.setValue(.array(existing), namespace: XMPNamespace.iptcExt, property: "PersonInImage")

        default:
            swiftExifLog.warning("addRemoveListValues: unsupported key \(key.rawValue, privacy: .public) for add")
        }
    }
}

/// XMP-crs property names that get stripped when copying metadata onto a rendered file.
private let cameraRawPropertyNames: [String] = [
    "Version", "ProcessVersion", "WhiteBalance",
    "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint",
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
    "Whites2012", "Blacks2012", "Saturation", "Vibrance",
    "HasSettings", "HasCrop",
    "CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle",
    "CropConstrainToWarp", "CropConstrainToUnitSquare",
    "HDREditMode", "HDRMaxValue",
    "SDRBrightness", "SDRContrast", "SDRClarity",
    "SDRHighlights", "SDRShadows", "SDRWhites", "SDRBlend",
    "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
    "ToneCurveName2012",
    "MaskGroupBasedCorrections"
]
