import Foundation
import SwiftExif

/// XMP namespace URI for Adobe Camera Raw Settings.
nonisolated private let crsNamespaceURI = "http://ns.adobe.com/camera-raw-settings/1.0/"
nonisolated private let aaphotoNamespaceURI = "http://aagedal.me/ns/photo/1.0/"

private extension MakerNoteValue {
    /// The value as an `Int` when it is an integer (signed or unsigned), else nil.
    /// MakerNote scalar tags are emitted as `.int` or `.uint` depending on the field.
    nonisolated var intValue: Int? {
        switch self {
        case .int(let i):  return i
        case .uint(let u): return Int(u)
        default:           return nil
        }
    }
}

/// Recursively unwrap `XMPValue` to plain Swift / Foundation types so the
/// dict-based parsers (`parseMaskGroupBasedCorrections` etc.) can consume
/// SwiftExif's recursive structured XMP without per-cast knowledge of the enum.
nonisolated private func unwrapXMPValue(_ value: XMPValue) -> Any {
    switch value {
    case .simple(let s):              return s
    case .array(let items):           return items
    case .langAlternative(let s):     return s
    case .structure(let fields):      return unwrapXMPStruct(fields)
    case .structuredArray(let items): return items.map(unwrapXMPStruct)
    }
}

nonisolated private func unwrapXMPStruct(_ fields: [String: XMPValue]) -> [String: Any] {
    var out: [String: Any] = [:]
    out.reserveCapacity(fields.count)
    for (key, value) in fields {
        out[key] = unwrapXMPValue(value)
    }
    return out
}

/// Bridges SwiftExif's typed `ImageMetadata` to the flat tag-name dictionary
/// shape used by `iptcMetadataFromDict` and `TechnicalMetadata.init(from:)`.
///
/// The dict shape preserves the field-name aliases and fallback paths that
/// the existing `IPTCMetadata` and `TechnicalMetadata` constructors rely on,
/// so behaviour matches what the app surfaced before. Both sides agree on
/// the canonical tag names declared in `MetadataDictKey`.
extension ImageMetadata {
    /// Build a flat `[String: Any]` keyed by canonical IPTC / XMP / EXIF tag names.
    /// `fileURL`, when provided, is recorded under `SourceFile`.
    nonisolated func asMetadataDict(fileURL: URL? = nil) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let fileURL { dict[MetadataDictKey.sourceFile] = fileURL.path }

        // MARK: IPTC

        if let v = iptc.headline { dict[MetadataDictKey.headline] = v }
        if let v = iptc.objectName { dict[MetadataDictKey.objectName] = v }
        if let v = iptc.caption { dict[MetadataDictKey.captionAbstract] = v }
        if !iptc.keywords.isEmpty { dict[MetadataDictKey.keywords] = iptc.keywords }
        if let v = iptc.byline { dict[MetadataDictKey.byLine] = v }
        if let v = iptc.credit { dict[MetadataDictKey.credit] = v }
        if let v = iptc.copyright { dict[MetadataDictKey.copyrightNotice] = v }
        if let v = iptc.dateCreated { dict[MetadataDictKey.dateCreated] = v }
        if let v = iptc.city { dict[MetadataDictKey.city] = v }
        if let v = iptc.countryName { dict[MetadataDictKey.countryPrimaryLocationName] = v }
        if let v = iptc.value(for: .originalTransmissionReference) {
            dict[MetadataDictKey.originalTransmissionReference] = v
        }
        if let v = iptc.jobId { dict[MetadataDictKey.jobID] = v }

        // MARK: XMP

        if let xmp {
            if let v = xmp.title { dict[MetadataDictKey.title] = v }
            if let v = xmp.description { dict[MetadataDictKey.description] = v }
            if let v = xmp.extendedDescription { dict[MetadataDictKey.extDescrAccessibility] = v }
            if !xmp.subject.isEmpty { dict[MetadataDictKey.subject] = xmp.subject }
            if !xmp.creator.isEmpty { dict[MetadataDictKey.creator] = xmp.creator }
            if let v = xmp.rights { dict[MetadataDictKey.rights] = v }
            if let v = xmp.headline, dict[MetadataDictKey.headline] == nil {
                dict[MetadataDictKey.headline] = v
            }
            if let v = xmp.city, dict[MetadataDictKey.city] == nil {
                dict[MetadataDictKey.city] = v
            }
            if let v = xmp.country { dict[MetadataDictKey.country] = v }
            if let v = xmp.credit, dict[MetadataDictKey.credit] == nil {
                dict[MetadataDictKey.credit] = v
            }
            if let v = xmp.jobId { dict[MetadataDictKey.transmissionReference] = v }
            if let v = xmp.rating { dict[MetadataDictKey.rating] = Int(v) }
            if let v = xmp.label { dict[MetadataDictKey.label] = v }
            if let v = xmp.createDate { dict[MetadataDictKey.createDate] = v }
            if !xmp.personInImage.isEmpty {
                dict[MetadataDictKey.personInImage] = xmp.personInImage
            }
            if let v = xmp.digitalSourceType { dict[MetadataDictKey.digitalSourceType] = v }
            if let v = xmp.event { dict[MetadataDictKey.event] = v }

            // MARK: XMP-crs (Adobe Camera Raw)

            // Simple-typed crs properties — read as strings, parser coerces to numeric.
            for property in [
                MetadataDictKey.crsVersion, MetadataDictKey.crsProcessVersion,
                MetadataDictKey.crsWhiteBalance,
                MetadataDictKey.crsTemperature, MetadataDictKey.crsTint,
                MetadataDictKey.crsIncrementalTemperature, MetadataDictKey.crsIncrementalTint,
                MetadataDictKey.crsExposure2012, MetadataDictKey.crsContrast2012,
                MetadataDictKey.crsHighlights2012, MetadataDictKey.crsShadows2012,
                MetadataDictKey.crsWhites2012, MetadataDictKey.crsBlacks2012,
                MetadataDictKey.crsSaturation, MetadataDictKey.crsVibrance,
                MetadataDictKey.crsHasSettings, MetadataDictKey.crsAlreadyApplied,
                MetadataDictKey.crsCropTop, MetadataDictKey.crsCropLeft,
                MetadataDictKey.crsCropBottom, MetadataDictKey.crsCropRight,
                MetadataDictKey.crsCropAngle, MetadataDictKey.crsHasCrop,
                MetadataDictKey.crsHDREditMode, MetadataDictKey.crsHDRMaxValue,
                MetadataDictKey.crsSDRBrightness, MetadataDictKey.crsSDRContrast,
                MetadataDictKey.crsSDRClarity, MetadataDictKey.crsSDRHighlights,
                MetadataDictKey.crsSDRShadows, MetadataDictKey.crsSDRWhites,
                MetadataDictKey.crsSDRBlend
            ] {
                if let v = xmp.simpleValue(namespace: crsNamespaceURI, property: property) {
                    dict[property] = v
                }
            }

            // HSL per-color adjustments — 21 simple signed-int crs properties
            // (HueAdjustment*/SaturationAdjustment*/LuminanceAdjustment* per color).
            for property in acrHSLPropertyNames {
                if let v = xmp.simpleValue(namespace: crsNamespaceURI, property: property) {
                    dict[property] = v
                }
            }

            // Tone curve arrays — rdf:Seq of "x, y" strings.
            for property in [
                MetadataDictKey.crsToneCurvePV2012,
                MetadataDictKey.crsToneCurvePV2012Red,
                MetadataDictKey.crsToneCurvePV2012Green,
                MetadataDictKey.crsToneCurvePV2012Blue
            ] {
                let arr = xmp.arrayValue(namespace: crsNamespaceURI, property: property)
                if !arr.isEmpty { dict[property] = arr }
            }

            // Local mask corrections — recursive structured array. The parser
            // expects plain `[[String: Any]]` with a nested `CorrectionMasks`
            // array, so we unwrap the recursive `XMPValue` shape here.
            if let masks = xmp.structuredArrayValue(
                namespace: crsNamespaceURI,
                property: MetadataDictKey.maskGroupBasedCorrections
            ) {
                dict[MetadataDictKey.maskGroupBasedCorrections] = masks.map(unwrapXMPStruct)
            }

            // App-private global-node position (ACR can't express it).
            if let v = xmp.simpleValue(namespace: aaphotoNamespaceURI,
                                       property: MetadataDictKey.globalLayerIndex) {
                dict[MetadataDictKey.globalLayerIndex] = v
            }
        }

        // MARK: EXIF

        if let exif {
            if let v = exif.dateTimeOriginal { dict[MetadataDictKey.dateTimeOriginal] = v }
            if let v = exif.gpsLatitude { dict[MetadataDictKey.gpsLatitude] = v }
            if let v = exif.gpsLongitude { dict[MetadataDictKey.gpsLongitude] = v }
            if let v = exif.orientation { dict[MetadataDictKey.orientation] = Int(v) }
            if let v = exif.make { dict["Make"] = v }
            if let v = exif.model { dict["Model"] = v }
            if let v = exif.lensModel { dict["LensModel"] = v }
            if let v = exif.software { dict["Software"] = v }
            if let v = exif.copyright, dict[MetadataDictKey.copyrightNotice] == nil {
                dict[MetadataDictKey.copyrightNotice] = v
            }
            if let r = exif.focalLength {
                dict["FocalLength"] = Double(r.numerator) / Double(max(r.denominator, 1))
            }
            if let r = exif.fNumber {
                dict["FNumber"] = Double(r.numerator) / Double(max(r.denominator, 1))
            }
            if let r = exif.exposureTime {
                dict["ExposureTime"] = Double(r.numerator) / Double(max(r.denominator, 1))
            }
            if let v = exif.isoSpeed { dict["ISO"] = Int(v) }
            if let v = exif.pixelXDimension { dict[MetadataDictKey.imageWidth] = Int(v) }
            if let v = exif.pixelYDimension { dict[MetadataDictKey.imageHeight] = Int(v) }

            // Raw IFD reads for fields not exposed via typed getters.
            // 0xA431 BodySerialNumber (ASCII), 0xA403 WhiteBalance (SHORT 0/1).
            let endian = exif.byteOrder
            if let serial = exif.exifIFD?.entry(for: 0xA431)?.stringValue() {
                let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { dict["SerialNumber"] = trimmed }
            }
            if let wb = exif.exifIFD?.entry(for: 0xA403)?.uint16Value(endian: endian) {
                dict["WhiteBalance"] = Int(wb)
            }

            // Composite tags computed by SwiftExif from EXIF.
            let composite = CompositeTagCalculator.calculate(from: exif)
            if let lensID = composite["LensID"] { dict["LensID"] = lensID }

            // MARK: MakerNote technical extras
            //
            // Shutter count, camera temperature, and (on CR3) the lens model live only
            // in the manufacturer MakerNote — they have no standard EXIF tag and ImageIO
            // never surfaces them. Pull the few we display into the flat dict.
            if let makerNote = exif.makerNote {
                if let shutterCount = makerNote.tags["ShutterCount"]?.intValue {
                    dict["ShutterCount"] = shutterCount
                }
                if let temperature = makerNote.tags["CameraTemperature"]?.intValue {
                    dict["CameraTemperature"] = temperature
                }
                // Canon CR3 carries the lens model in the MakerNote (0x0095) rather than
                // the standard EXIF LensModel tag — fill it only when EXIF didn't.
                if dict["LensModel"] == nil,
                   case let .string(lens)? = makerNote.tags["LensModel"] {
                    dict["LensModel"] = lens
                }
            }
        }

        // MARK: ICC profile

        if let profile = iccProfile, let desc = profile.profileDescription {
            dict["ProfileDescription"] = desc
        }

        // MARK: File modification date (FS-level fallback used by TechnicalMetadata)

        if let fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
            dict["FileModifyDate"] = formatter.string(from: modDate)
        }

        return dict
    }
}
