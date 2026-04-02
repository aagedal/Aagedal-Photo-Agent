import Foundation
import ImageIO
import CoreGraphics

struct TechnicalMetadata {
    private enum ExifKey {
        static let make = "Make"
        static let model = "Model"
        static let lensModel = "LensModel"
        static let dateTimeOriginal = "DateTimeOriginal"
        static let fileModifyDate = "FileModifyDate"
        static let focalLength = "FocalLength"
        static let fNumber = "FNumber"
        static let exposureTime = "ExposureTime"
        static let iso = "ISO"
        static let imageWidth = "ImageWidth"
        static let imageHeight = "ImageHeight"
        static let fileImageWidth = "File:ImageWidth"
        static let fileImageHeight = "File:ImageHeight"
        static let bitsPerSample = "BitsPerSample"
        static let profileDescription = "ProfileDescription"
        static let colorSpace = "ColorSpace"
        static let claimGenerator = "Claim_generator"
        static let claimGeneratorInfoName = "Claim_Generator_InfoName"
        static let authorName = "AuthorName"
        static let relationship = "Relationship"
        static let serialNumber = "SerialNumber"
        static let software = "Software"
        static let lensID = "LensID"
        static let whiteBalance = "WhiteBalance"
    }

    var camera: String?
    var lens: String?
    var captureDate: String?
    var modifiedDate: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var bitDepth: Int?
    var colorSpace: String?
    var serialNumber: String?
    var software: String?
    var lensID: String?
    var whiteBalance: String?

    // C2PA
    var hasC2PA: Bool
    var c2paClaimGenerator: String?
    var c2paAuthor: String?
    var c2paEdited: Bool

    var resolution: String? {
        guard let w = imageWidth, let h = imageHeight else { return nil }
        return "\(w) x \(h)"
    }

    /// Check whether a dict (from ExifTool JSON output with `-JUMBF:All`) contains C2PA data.
    static func dictHasC2PA(_ dict: [String: Any]) -> Bool {
        dict.keys.contains { $0.hasPrefix("JUMD") || $0.hasPrefix("C2PA") || $0 == ExifKey.claimGenerator }
    }

    init(from dict: [String: Any], fileURL: URL? = nil) {
        // Camera: combine Make + Model, avoiding duplication
        let make = (dict[ExifKey.make] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (dict[ExifKey.model] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let make, let model {
            if model.lowercased().hasPrefix(make.lowercased()) {
                camera = model
            } else {
                camera = "\(make) \(model)"
            }
        } else {
            camera = model ?? make
        }

        lens = dict[ExifKey.lensModel] as? String
        captureDate = dict[ExifKey.dateTimeOriginal] as? String
        modifiedDate = dict[ExifKey.fileModifyDate] as? String

        // Focal length
        if let fl = dict[ExifKey.focalLength] as? Double {
            let rounded = fl.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", fl) : String(format: "%.1f", fl)
            focalLength = "\(rounded) mm"
        } else if let fl = dict[ExifKey.focalLength] as? String {
            focalLength = fl
        }

        // Aperture
        if let fn = dict[ExifKey.fNumber] as? Double {
            aperture = fn.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "f/%.0f", fn) : String(format: "f/%.1f", fn)
        }

        // Shutter speed
        if let et = dict[ExifKey.exposureTime] as? Double {
            if et >= 1 {
                shutterSpeed = String(format: "%.1f s", et)
            } else {
                let denom = Int(round(1.0 / et))
                shutterSpeed = "1/\(denom) s"
            }
        }

        // ISO
        if let isoVal = dict[ExifKey.iso] as? Int {
            iso = String(isoVal)
        } else if let isoVal = dict[ExifKey.iso] as? Double {
            iso = String(Int(isoVal))
        }

        // Serial number
        serialNumber = dict[ExifKey.serialNumber] as? String

        // Software / firmware
        software = dict[ExifKey.software] as? String

        // Lens ID (Composite tag — text description when available, numeric otherwise)
        if let lid = dict[ExifKey.lensID] as? String {
            lensID = lid
        } else if let lid = dict[ExifKey.lensID] as? Int, lid != 65535, lid != 0 {
            lensID = String(lid)
        }

        // White balance (EXIF numeric: 0 = Auto, 1 = Manual)
        if let wb = dict[ExifKey.whiteBalance] as? Int {
            whiteBalance = wb == 0 ? "Auto" : "Manual"
        } else if let wb = dict[ExifKey.whiteBalance] as? String {
            whiteBalance = wb
        }

        // Resolution — prefer EXIF, fall back to File
        imageWidth = dict[ExifKey.imageWidth] as? Int ?? dict[ExifKey.fileImageWidth] as? Int
        imageHeight = dict[ExifKey.imageHeight] as? Int ?? dict[ExifKey.fileImageHeight] as? Int

        // Bit depth and color space — prefer native Apple APIs (CGImageSource),
        // which correctly read CICP/NCLX, JXL codestream headers, ICC profiles etc.
        // Fall back to ExifTool tags when native detection isn't available.
        let nativeInfo = fileURL.flatMap { Self.nativeImageInfo(for: $0) }

        // Bit depth
        if let nativeBitDepth = nativeInfo?.bitDepth {
            bitDepth = nativeBitDepth
        } else if let bps = dict[ExifKey.bitsPerSample] as? Int {
            bitDepth = bps
        } else if let bpsArr = dict[ExifKey.bitsPerSample] as? [Int], let first = bpsArr.first {
            bitDepth = first
        }

        // Color space
        if let nativeProfile = nativeInfo?.profileName, !nativeProfile.isEmpty {
            colorSpace = Self.cleanProfileName(nativeProfile)
        } else if let iccDesc = dict[ExifKey.profileDescription] as? String, !iccDesc.isEmpty {
            colorSpace = iccDesc
        } else if let cs = dict[ExifKey.colorSpace] as? Int {
            switch cs {
            case 1: colorSpace = "sRGB"
            case 2: colorSpace = "Adobe RGB"
            case 0xFFFF: colorSpace = "Uncalibrated"
            default: colorSpace = "Unknown (\(cs))"
            }
        } else if let cs = dict[ExifKey.colorSpace] as? String {
            colorSpace = cs
        }

        // C2PA — detect from JUMD/C2PA keys returned by -JUMBF:All
        hasC2PA = Self.dictHasC2PA(dict)

        // Claim generator — ExifTool flattens multi-manifest C2PA data.
        // When a file has been edited (has "Relationship" = "parentOf"),
        // the flat "Claim_generator" is from the ingredient/original manifest.
        // The active manifest's generator info is in Claim_Generator_InfoVersion etc.
        c2paClaimGenerator = dict[ExifKey.claimGenerator] as? String
            ?? dict[ExifKey.claimGeneratorInfoName] as? String

        // Author (from schema.org CreativeWork assertion)
        c2paAuthor = dict[ExifKey.authorName] as? String

        // Edited detection: "Relationship" = "parentOf" means the file has an
        // ingredient (i.e. it was edited/re-signed by another tool)
        c2paEdited = (dict[ExifKey.relationship] as? String) == "parentOf"
    }

    // MARK: - ImageIO fast path

    /// Read technical metadata directly from the image file using CGImageSource.
    /// Much faster than ExifTool since it avoids subprocess overhead.
    /// C2PA detail fields are not populated — use ExifToolService.readC2PAMetadata for those.
    static func fromImageIO(url: URL, hasC2PA: Bool = false) -> TechnicalMetadata {
        var dict: [String: Any] = [:]

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]

            // Camera / lens
            dict[ExifKey.make] = tiff[kCGImagePropertyTIFFMake as String]
            dict[ExifKey.model] = tiff[kCGImagePropertyTIFFModel as String]
            dict[ExifKey.lensModel] = exif[kCGImagePropertyExifLensModel as String]

            // Date
            dict[ExifKey.dateTimeOriginal] = exif[kCGImagePropertyExifDateTimeOriginal as String]

            // Exposure
            dict[ExifKey.focalLength] = exif[kCGImagePropertyExifFocalLength as String]
            dict[ExifKey.fNumber] = exif[kCGImagePropertyExifFNumber as String]
            dict[ExifKey.exposureTime] = exif[kCGImagePropertyExifExposureTime as String]

            // ISO — ImageIO returns an array of speed ratings
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any],
               let first = isoArr.first {
                dict[ExifKey.iso] = first
            }

            // Body serial number & firmware
            dict[ExifKey.serialNumber] = exif[kCGImagePropertyExifBodySerialNumber as String]
            dict[ExifKey.software] = tiff[kCGImagePropertyTIFFSoftware as String]

            // White balance
            dict[ExifKey.whiteBalance] = exif[kCGImagePropertyExifWhiteBalance as String]

            // Dimensions
            dict[ExifKey.imageWidth] = props[kCGImagePropertyPixelWidth as String]
            dict[ExifKey.imageHeight] = props[kCGImagePropertyPixelHeight as String]
        }

        // File modification date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
            dict[ExifKey.fileModifyDate] = formatter.string(from: modDate)
        }

        // Build via the existing init (which also calls nativeImageInfo for bitDepth/colorSpace)
        var meta = TechnicalMetadata(from: dict, fileURL: url)
        meta.hasC2PA = hasC2PA
        return meta
    }

    // MARK: - Native Apple API color space detection

    private struct NativeImageInfo {
        let profileName: String?
        let bitDepth: Int?
    }

    /// Use CGImageSource to read the actual color profile and bit depth from the image file.
    /// This correctly handles CICP/NCLX (AVIF/HEIF), JXL codestream headers, and ICC profiles.
    private static func nativeImageInfo(for url: URL) -> NativeImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let profileName = props?[kCGImagePropertyProfileName as String] as? String
        let depth = props?[kCGImagePropertyDepth as String] as? Int
        if profileName == nil && depth == nil { return nil }
        return NativeImageInfo(profileName: profileName, bitDepth: depth)
    }

    /// Clean up raw profile names for display.
    /// e.g. "QuickTime 'nclc' Video (9,1,9)" → "Rec. 2020" via CICP code parsing.
    private static func cleanProfileName(_ name: String) -> String {
        // Handle QuickTime NCLX profile strings like "QuickTime 'nclc' Video (9,1,9)"
        if name.contains("nclc") || name.contains("nclx") {
            // Extract CICP codes from parenthesized tuple
            if let range = name.range(of: #"\((\d+),(\d+),(\d+)\)"#, options: .regularExpression) {
                let match = String(name[range]).dropFirst().dropLast() // remove parens
                let codes = match.split(separator: ",").compactMap { Int($0) }
                if codes.count >= 2 {
                    return colorSpaceFromCICPCodes(primaries: codes[0], transfer: codes[1])
                }
            }
            return name
        }
        return name
    }

    private static func colorSpaceFromCICPCodes(primaries: Int, transfer: Int) -> String {
        let isPQ = transfer == 16
        let isHLG = transfer == 18

        let gamut: String
        switch primaries {
        case 9:  gamut = "Rec. 2020"
        case 12: gamut = "Display P3"
        case 1:  gamut = "sRGB"
        default: gamut = "CICP \(primaries)"
        }

        if isPQ { return "\(gamut) PQ" }
        if isHLG { return "\(gamut) HLG" }
        return gamut
    }
}
