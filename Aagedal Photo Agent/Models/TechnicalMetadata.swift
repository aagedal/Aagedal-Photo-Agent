import Foundation
import ImageIO
import CoreGraphics

struct TechnicalMetadata: Sendable {
    private enum ExifKey {
        nonisolated static let make = "Make"
        nonisolated static let model = "Model"
        nonisolated static let lensModel = "LensModel"
        nonisolated static let dateTimeOriginal = "DateTimeOriginal"
        nonisolated static let fileModifyDate = "FileModifyDate"
        nonisolated static let focalLength = "FocalLength"
        nonisolated static let fNumber = "FNumber"
        nonisolated static let exposureTime = "ExposureTime"
        nonisolated static let iso = "ISO"
        nonisolated static let imageWidth = "ImageWidth"
        nonisolated static let imageHeight = "ImageHeight"
        nonisolated static let fileImageWidth = "File:ImageWidth"
        nonisolated static let fileImageHeight = "File:ImageHeight"
        nonisolated static let bitsPerSample = "BitsPerSample"
        nonisolated static let profileDescription = "ProfileDescription"
        nonisolated static let colorSpace = "ColorSpace"
        nonisolated static let claimGenerator = "Claim_generator"
        nonisolated static let claimGeneratorInfoName = "Claim_Generator_InfoName"
        nonisolated static let authorName = "AuthorName"
        nonisolated static let relationship = "Relationship"
        nonisolated static let serialNumber = "SerialNumber"
        nonisolated static let software = "Software"
        nonisolated static let lensID = "LensID"
        nonisolated static let whiteBalance = "WhiteBalance"
        nonisolated static let shutterCount = "ShutterCount"
        nonisolated static let cameraTemperature = "CameraTemperature"
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
    var shutterCount: Int?
    var cameraTemperature: Int?

    // C2PA
    var hasC2PA: Bool
    var c2paClaimGenerator: String?
    var c2paAuthor: String?
    var c2paEdited: Bool

    /// Displayed resolution, swapping width/height for transposed EXIF
    /// orientations (5–8) so a 90°-rotated 3840×2160 reads 2160×3840. Matches
    /// Photo Mechanic, which reports oriented (not stored) dimensions: an
    /// orientation-only rotate (⌘R) flips the EXIF tag without transposing the
    /// stored pixel buffer, so the swap must happen at display time.
    func resolution(orientation: Int) -> String? {
        guard let w = imageWidth, let h = imageHeight else { return nil }
        switch orientation {
        case 5, 6, 7, 8: return "\(h) x \(w)"
        default: return "\(w) x \(h)"
        }
    }

    /// Check whether a metadata dict contains C2PA data.
    nonisolated static func dictHasC2PA(_ dict: [String: Any]) -> Bool {
        dict.keys.contains { $0.hasPrefix("JUMD") || $0.hasPrefix("C2PA") || $0 == ExifKey.claimGenerator }
    }

    /// Safely convert a Double derived from (possibly corrupt) file metadata to Int.
    /// `Int(_:)` traps on non-finite or out-of-range values, so a malformed EXIF
    /// field (e.g. a `0/n` exposure-time rational, or an `inf`/`nan` ISO) must be
    /// filtered here before the conversion. Returns nil for unrepresentable values.
    nonisolated private static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite,
              value >= Double(Int.min),
              value < Double(Int.max) else { return nil }
        return Int(value)
    }

    nonisolated init(from dict: [String: Any], fileURL: URL? = nil) {
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

        // Shutter speed (guard against corrupt 0/non-finite exposure times,
        // which would trap in Int(.infinity) via the 1/et reciprocal below)
        if let et = dict[ExifKey.exposureTime] as? Double, et.isFinite, et > 0 {
            if et >= 1 {
                shutterSpeed = String(format: "%.1f s", et)
            } else if let denom = Self.safeInt((1.0 / et).rounded()) {
                shutterSpeed = "1/\(denom) s"
            }
        }

        // ISO
        if let isoVal = dict[ExifKey.iso] as? Int {
            iso = String(isoVal)
        } else if let isoVal = dict[ExifKey.iso] as? Double, let isoInt = Self.safeInt(isoVal) {
            iso = String(isoInt)
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

        // Shutter count & camera temperature — MakerNote-only (Canon/Nikon shutter
        // count, Canon temperature in °C). Not exposed by ImageIO.
        shutterCount = dict[ExifKey.shutterCount] as? Int
        cameraTemperature = dict[ExifKey.cameraTemperature] as? Int

        // Resolution — prefer EXIF, fall back to File
        imageWidth = dict[ExifKey.imageWidth] as? Int ?? dict[ExifKey.fileImageWidth] as? Int
        imageHeight = dict[ExifKey.imageHeight] as? Int ?? dict[ExifKey.fileImageHeight] as? Int

        // Bit depth and color space — prefer native Apple APIs (CGImageSource),
        // which correctly read CICP/NCLX, JXL codestream headers, ICC profiles etc.
        // Fall back to embedded EXIF tags when native detection isn't available.
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

        // Claim generator — flattened multi-manifest C2PA data.
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

    /// Whether any camera/exposure field was populated. Used to decide whether the
    /// ImageIO fast path found EXIF, or a fallback reader is needed (Apple's ImageIO
    /// doesn't expose EXIF for some containers, e.g. JPEG XL and AVIF).
    var hasCameraInfo: Bool {
        camera != nil || lens != nil || iso != nil || captureDate != nil
            || focalLength != nil || aperture != nil || shutterSpeed != nil
    }

    /// Returns a copy with camera/exposure fields taken from `other`, while keeping our own
    /// dimensions, bit depth, color space, and C2PA flags. The ImageIO fast path reads those
    /// reliably for every format (including ones it can't read EXIF from), so when we enrich
    /// with a fallback EXIF reader we only want its camera fields.
    func mergingCameraFields(from other: TechnicalMetadata) -> TechnicalMetadata {
        var copy = self
        copy.camera = other.camera
        copy.lens = other.lens
        copy.captureDate = other.captureDate
        copy.focalLength = other.focalLength
        copy.aperture = other.aperture
        copy.shutterSpeed = other.shutterSpeed
        copy.iso = other.iso
        copy.serialNumber = other.serialNumber
        copy.software = other.software
        copy.lensID = other.lensID
        copy.whiteBalance = other.whiteBalance
        copy.shutterCount = other.shutterCount
        copy.cameraTemperature = other.cameraTemperature
        if copy.modifiedDate == nil { copy.modifiedDate = other.modifiedDate }
        return copy
    }

    /// Returns a copy that keeps all of our own fields but overlays the MakerNote-only
    /// technical extras from `other` — shutter count and camera temperature (which the
    /// ImageIO fast path never reads), plus lens/lens-ID/serial/firmware when we lacked
    /// them (e.g. a CR3 whose lens model lives only in the Canon MakerNote). Used when
    /// the ImageIO fast path already supplied reliable camera/exposure fields.
    func mergingTechnicalExtras(from other: TechnicalMetadata) -> TechnicalMetadata {
        var copy = self
        copy.shutterCount = other.shutterCount
        copy.cameraTemperature = other.cameraTemperature
        if copy.lens == nil { copy.lens = other.lens }
        if copy.lensID == nil { copy.lensID = other.lensID }
        if copy.serialNumber == nil { copy.serialNumber = other.serialNumber }
        if copy.software == nil { copy.software = other.software }
        return copy
    }

    // MARK: - ImageIO fast path

    /// Read technical metadata directly from the image file using CGImageSource.
    /// Much faster than parsing the whole file with the metadata engine.
    /// C2PA detail fields are not populated — use SwiftExifReadService.readC2PAMetadata for those.
    nonisolated static func fromImageIO(url: URL, hasC2PA: Bool = false) -> TechnicalMetadata {
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
    nonisolated private static func nativeImageInfo(for url: URL) -> NativeImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let profileName = props?[kCGImagePropertyProfileName as String] as? String
        let depth = props?[kCGImagePropertyDepth as String] as? Int
        if profileName == nil && depth == nil { return nil }
        return NativeImageInfo(profileName: profileName, bitDepth: depth)
    }

    /// Clean up raw profile names for display.
    /// e.g. "QuickTime 'nclc' Video (9,1,9)" → "Rec. 2020" via CICP code parsing.
    nonisolated private static func cleanProfileName(_ name: String) -> String {
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

    nonisolated private static func colorSpaceFromCICPCodes(primaries: Int, transfer: Int) -> String {
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

nonisolated struct TechnicalMetadataFastSnapshot: Sendable {
    let requestID: UUID
    let imageURL: URL
    let metadata: TechnicalMetadata
}

nonisolated enum TechnicalMetadataFastLoadResult: Sendable {
    case loaded(TechnicalMetadataFastSnapshot)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, imageURL: URL)
}

nonisolated struct TechnicalMetadataFastAccess: Sendable {
    let read: @Sendable (URL, Bool) -> TechnicalMetadata

    static let system = TechnicalMetadataFastAccess { imageURL, hasC2PA in
        TechnicalMetadata.fromImageIO(url: imageURL, hasC2PA: hasC2PA)
    }
}

/// Serializes ImageIO container/header reads and the adjacent file-attribute probe used by the
/// technical inspector. These synchronous APIs can block on remote and placeholder-backed files
/// and cannot be preempted once entered, so cancellation is made explicit on both sides of the
/// access and the MainActor owner publishes only an identity-matching complete snapshot.
actor TechnicalMetadataFastLoadService {
    static let shared = TechnicalMetadataFastLoadService()

    private let access: TechnicalMetadataFastAccess

    init(access: TechnicalMetadataFastAccess = .system) {
        self.access = access
    }

    func load(
        imageURL: URL,
        hasC2PA: Bool,
        requestID: UUID
    ) -> TechnicalMetadataFastLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }
        let metadata = access.read(imageURL, hasC2PA)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(requestID: requestID, imageURL: imageURL)
        }
        return .loaded(TechnicalMetadataFastSnapshot(
            requestID: requestID,
            imageURL: imageURL,
            metadata: metadata
        ))
    }
}
