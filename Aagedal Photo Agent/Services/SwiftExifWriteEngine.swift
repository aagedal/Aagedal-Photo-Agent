import Foundation
import SwiftExif
import os

private let swiftExifLog = Logger(subsystem: "com.aagedal.photo-agent", category: "SwiftExifWriteEngine")

/// XMP namespace URI for Adobe Camera Raw Settings.
private let crsNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

/// MetadataWriteEngine implementation using native SwiftExif for fast metadata writes.
/// Falls back to ExifToolService for operations SwiftExif cannot handle natively
/// (structured XMP masks, cross-file metadata copy, EXIF IFD manipulation).
final class SwiftExifWriteEngine: MetadataWriteEngine, @unchecked Sendable {
    private let exifToolService: ExifToolService

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
    }

    func writeFields(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws {
        guard !urls.isEmpty, !fields.isEmpty || !structuredData.isEmpty else { return }

        // Separate fields into SwiftExif-native and ExifTool-delegated (EXIF IFD fields)
        var nativeFields: [MetadataFieldKey: String] = [:]
        var exifToolFields: [MetadataFieldKey: String] = [:]

        for (key, value) in fields {
            switch key {
            case .orientation, .gpsLatitude, .gpsLatitudeRef, .gpsLongitude, .gpsLongitudeRef:
                exifToolFields[key] = value
            default:
                nativeFields[key] = value
            }
        }

        // Write native fields via SwiftExif
        if !nativeFields.isEmpty || !structuredData.isEmpty {
            let creationDates = captureCreationDates(for: urls)
            defer { restoreCreationDates(creationDates) }

            for url in urls {
                try Task.checkCancellation()
                try writeFieldsToFile(nativeFields, structuredData: structuredData, url: url)
            }
        }

        // Delegate EXIF IFD fields to ExifTool
        if !exifToolFields.isEmpty {
            let tagFields = exifToolFields.reduce(into: [String: String]()) { $0[$1.key.exifToolTag] = $1.value }
            try await exifToolService.writeFields(tagFields, to: urls)
        }

        // Delegate mask writes to ExifTool (structured XMP bags not supported natively)
        if let masks = structuredData.masks {
            let maskEngine = ExifToolWriteEngine(exifToolService: exifToolService)
            try await maskEngine.writeFields([:], to: urls, structuredData: StructuredWriteData(masks: masks))
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
        // EXIF IFD manipulation — delegate to ExifTool
        try await exifToolService.writeOrientation(orientation, to: urls)
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
        // Complex cross-file copy with targeted exclusions — delegate to ExifTool
        try await exifToolService.copyMetadataToRenderedFile(from: source, to: destination)
    }

    // MARK: - Private Helpers

    private func writeFieldsToFile(
        _ fields: [MetadataFieldKey: String],
        structuredData: StructuredWriteData,
        url: URL
    ) throws {
        var metadata = try readMetadata(from: url)

        // Apply IPTC / XMP / CRS fields
        for (key, value) in fields {
            applyField(key: key, value: value, metadata: &metadata)
        }

        // Apply tone curves via XMP arrays
        if let tc = structuredData.toneCurve {
            applyToneCurves(tc, metadata: &metadata)
        }

        // Sync IPTC → XMP to ensure both sides are consistent
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

        // Camera Raw simple fields
        case .crsVersion:
            setCRSField(&metadata, property: "Version", value: value)
        case .crsProcessVersion:
            setCRSField(&metadata, property: "ProcessVersion", value: value)
        case .crsWhiteBalance:
            setCRSField(&metadata, property: "WhiteBalance", value: value)
        case .crsTemperature:
            setCRSField(&metadata, property: "Temperature", value: value)
        case .crsTint:
            setCRSField(&metadata, property: "Tint", value: value)
        case .crsIncrementalTemperature:
            setCRSField(&metadata, property: "IncrementalTemperature", value: value)
        case .crsIncrementalTint:
            setCRSField(&metadata, property: "IncrementalTint", value: value)
        case .crsExposure2012:
            setCRSField(&metadata, property: "Exposure2012", value: value)
        case .crsContrast2012:
            setCRSField(&metadata, property: "Contrast2012", value: value)
        case .crsHighlights2012:
            setCRSField(&metadata, property: "Highlights2012", value: value)
        case .crsShadows2012:
            setCRSField(&metadata, property: "Shadows2012", value: value)
        case .crsWhites2012:
            setCRSField(&metadata, property: "Whites2012", value: value)
        case .crsBlacks2012:
            setCRSField(&metadata, property: "Blacks2012", value: value)
        case .crsSaturation:
            setCRSField(&metadata, property: "Saturation", value: value)
        case .crsVibrance:
            setCRSField(&metadata, property: "Vibrance", value: value)
        case .crsHasSettings:
            setCRSField(&metadata, property: "HasSettings", value: value)
        case .crsCropTop:
            setCRSField(&metadata, property: "CropTop", value: value)
        case .crsCropLeft:
            setCRSField(&metadata, property: "CropLeft", value: value)
        case .crsCropBottom:
            setCRSField(&metadata, property: "CropBottom", value: value)
        case .crsCropRight:
            setCRSField(&metadata, property: "CropRight", value: value)
        case .crsCropAngle:
            setCRSField(&metadata, property: "CropAngle", value: value)
        case .crsHasCrop:
            setCRSField(&metadata, property: "HasCrop", value: value)
        case .crsCropConstrainToWarp:
            setCRSField(&metadata, property: "CropConstrainToWarp", value: value)
        case .crsCropConstrainToUnitSquare:
            setCRSField(&metadata, property: "CropConstrainToUnitSquare", value: value)
        case .crsHDREditMode:
            setCRSField(&metadata, property: "HDREditMode", value: value)
        case .crsHDRMaxValue:
            setCRSField(&metadata, property: "HDRMaxValue", value: value)
        case .crsSDRBrightness:
            setCRSField(&metadata, property: "SDRBrightness", value: value)
        case .crsSDRContrast:
            setCRSField(&metadata, property: "SDRContrast", value: value)
        case .crsSDRClarity:
            setCRSField(&metadata, property: "SDRClarity", value: value)
        case .crsSDRHighlights:
            setCRSField(&metadata, property: "SDRHighlights", value: value)
        case .crsSDRShadows:
            setCRSField(&metadata, property: "SDRShadows", value: value)
        case .crsSDRWhites:
            setCRSField(&metadata, property: "SDRWhites", value: value)
        case .crsSDRBlend:
            setCRSField(&metadata, property: "SDRBlend", value: value)
        case .crsToneCurveName2012:
            setCRSField(&metadata, property: "ToneCurveName2012", value: value)

        // EXIF IFD fields — handled separately (delegated to ExifTool)
        case .orientation, .gpsLatitude, .gpsLatitudeRef, .gpsLongitude, .gpsLongitudeRef:
            break
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
