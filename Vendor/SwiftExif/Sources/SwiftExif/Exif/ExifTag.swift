import Foundation

/// Standard Exif tag constants.
public enum ExifTag: Sendable {
    // MARK: - IFD0 (Main Image)
    public static let imageWidth: UInt16            = 0x0100
    public static let imageHeight: UInt16           = 0x0101
    public static let bitsPerSample: UInt16         = 0x0102
    public static let compression: UInt16           = 0x0103
    public static let photometricInterpretation: UInt16 = 0x0106
    public static let imageDescription: UInt16      = 0x010E
    public static let make: UInt16                  = 0x010F
    public static let model: UInt16                 = 0x0110
    public static let orientation: UInt16           = 0x0112
    public static let samplesPerPixel: UInt16       = 0x0115
    public static let xResolution: UInt16           = 0x011A
    public static let yResolution: UInt16           = 0x011B
    public static let resolutionUnit: UInt16        = 0x0128
    public static let software: UInt16              = 0x0131
    public static let dateTime: UInt16              = 0x0132
    public static let artist: UInt16                = 0x013B
    public static let copyright: UInt16             = 0x8298
    public static let exifIFDPointer: UInt16        = 0x8769
    public static let gpsIFDPointer: UInt16         = 0x8825

    // MARK: - Exif Sub-IFD
    public static let exposureTime: UInt16          = 0x829A
    public static let fNumber: UInt16               = 0x829D
    public static let exposureProgram: UInt16       = 0x8822
    public static let isoSpeedRatings: UInt16       = 0x8827
    public static let sensitivityType: UInt16       = 0x8830
    public static let standardOutputSensitivity: UInt16 = 0x8831
    public static let recommendedExposureIndex: UInt16  = 0x8832
    public static let isoSpeed: UInt16              = 0x8833
    public static let exifVersion: UInt16           = 0x9000
    public static let dateTimeOriginal: UInt16      = 0x9003
    public static let dateTimeDigitized: UInt16     = 0x9004
    public static let shutterSpeedValue: UInt16     = 0x9201
    public static let apertureValue: UInt16         = 0x9202
    public static let brightnessValue: UInt16       = 0x9203
    public static let exposureBiasValue: UInt16     = 0x9204
    public static let maxApertureValue: UInt16      = 0x9205
    public static let subjectDistance: UInt16       = 0x9206
    public static let meteringMode: UInt16          = 0x9207
    public static let lightSource: UInt16           = 0x9208
    public static let flash: UInt16                 = 0x9209
    public static let focalLength: UInt16           = 0x920A
    public static let subjectArea: UInt16           = 0x9214
    public static let makerNote: UInt16             = 0x927C
    public static let userComment: UInt16           = 0x9286
    public static let interopIFDPointer: UInt16     = 0xA005
    public static let colorSpace: UInt16            = 0xA001
    public static let pixelXDimension: UInt16       = 0xA002
    public static let pixelYDimension: UInt16       = 0xA003
    public static let focalPlaneXResolution: UInt16 = 0xA20E
    public static let focalPlaneYResolution: UInt16 = 0xA20F
    public static let focalPlaneResolutionUnit: UInt16 = 0xA210
    public static let sensingMethod: UInt16         = 0xA217
    public static let fileSource: UInt16            = 0xA300
    public static let sceneType: UInt16             = 0xA301
    public static let customRendered: UInt16        = 0xA401
    public static let exposureMode: UInt16          = 0xA402
    public static let whiteBalance: UInt16          = 0xA403
    public static let digitalZoomRatio: UInt16      = 0xA404
    public static let focalLengthIn35mmFilm: UInt16 = 0xA405
    public static let sceneCaptureType: UInt16      = 0xA406
    public static let gainControl: UInt16           = 0xA407
    public static let contrast: UInt16              = 0xA408
    public static let saturation: UInt16            = 0xA409
    public static let sharpness: UInt16             = 0xA40A
    public static let subjectDistanceRange: UInt16  = 0xA40C
    public static let imageUniqueID: UInt16         = 0xA420
    public static let cameraOwnerName: UInt16       = 0xA430
    public static let bodySerialNumber: UInt16      = 0xA431
    public static let lensSerialNumber: UInt16      = 0xA435
    public static let compositeImage: UInt16        = 0xA460
    public static let sourceImageNumberOfCompositeImage: UInt16 = 0xA461
    public static let sourceExposureTimesOfCompositeImage: UInt16 = 0xA462
    public static let offsetTime: UInt16             = 0x9010  // UTC offset for DateTime
    public static let offsetTimeOriginal: UInt16    = 0x9011  // UTC offset for DateTimeOriginal
    public static let offsetTimeDigitized: UInt16   = 0x9012  // UTC offset for DateTimeDigitized
    public static let subSecTime: UInt16            = 0x9290  // Fractional seconds for DateTime
    public static let subSecTimeOriginal: UInt16    = 0x9291  // Fractional seconds for DateTimeOriginal
    public static let subSecTimeDigitized: UInt16   = 0x9292  // Fractional seconds for DateTimeDigitized
    public static let lensModel: UInt16             = 0xA434
    public static let lensMake: UInt16              = 0xA433
    public static let lensSpecification: UInt16     = 0xA432

    // MARK: - IFD1 (Thumbnail)
    public static let jpegIFOffset: UInt16          = 0x0201  // Thumbnail data offset
    public static let jpegIFByteCount: UInt16       = 0x0202  // Thumbnail data length

    // MARK: - GPS IFD
    public static let gpsVersionID: UInt16          = 0x0000
    public static let gpsLatitudeRef: UInt16        = 0x0001
    public static let gpsLatitude: UInt16           = 0x0002
    public static let gpsLongitudeRef: UInt16       = 0x0003
    public static let gpsLongitude: UInt16          = 0x0004
    public static let gpsAltitudeRef: UInt16        = 0x0005
    public static let gpsAltitude: UInt16           = 0x0006
    public static let gpsTimeStamp: UInt16          = 0x0007
    public static let gpsSatellites: UInt16         = 0x0008
    public static let gpsStatus: UInt16             = 0x0009
    public static let gpsMeasureMode: UInt16        = 0x000A
    public static let gpsDOP: UInt16                = 0x000B
    public static let gpsSpeedRef: UInt16           = 0x000C
    public static let gpsSpeed: UInt16              = 0x000D
    public static let gpsTrackRef: UInt16           = 0x000E
    public static let gpsTrack: UInt16              = 0x000F
    public static let gpsImgDirectionRef: UInt16    = 0x0010
    public static let gpsImgDirection: UInt16       = 0x0011
    public static let gpsMapDatum: UInt16           = 0x0012
    public static let gpsDestLatitudeRef: UInt16    = 0x0013
    public static let gpsDestLatitude: UInt16       = 0x0014
    public static let gpsDestLongitudeRef: UInt16   = 0x0015
    public static let gpsDestLongitude: UInt16      = 0x0016
    public static let gpsDestBearingRef: UInt16     = 0x0017
    public static let gpsDestBearing: UInt16        = 0x0018
    public static let gpsDestDistanceRef: UInt16    = 0x0019
    public static let gpsDestDistance: UInt16       = 0x001A
    public static let gpsProcessingMethod: UInt16   = 0x001B
    public static let gpsAreaInformation: UInt16    = 0x001C
    public static let gpsDateStamp: UInt16          = 0x001D
    public static let gpsDifferential: UInt16       = 0x001E
    public static let gpsHPositioningError: UInt16  = 0x001F

    // MARK: - TIFF Embedded Metadata Tags
    public static let iptcNAA: UInt16      = 0x83BB  // Raw IPTC-NAA data in IFD
    public static let photoshopIRB: UInt16 = 0x8649  // Photoshop IRB (contains IPTC)
    public static let xmpTag: UInt16       = 0x02BC  // Raw XMP XML string
    public static let iccProfile: UInt16   = 0x8773  // ICC color profile (InterColorProfile)

    // MARK: - IFD Type

    public enum IFDType: Sendable {
        case ifd0, ifd1, exifIFD, gpsIFD
    }

    // MARK: - Name Lookup

    /// Reverse lookup: find a tag ID by its name within a specific IFD.
    public static func tagID(for name: String, ifd: IFDType = .ifd0) -> UInt16? {
        switch ifd {
        case .gpsIFD:
            return gpsTagNames.first { $0.value == name }?.key
        case .exifIFD:
            return exifTagNames.first { $0.value == name }?.key
                ?? ifd0TagNames.first { $0.value == name }?.key
        default:
            return ifd0TagNames.first { $0.value == name }?.key
        }
    }

    public static func name(for tag: UInt16, ifd: IFDType = .ifd0) -> String {
        switch ifd {
        case .gpsIFD:
            return gpsTagNames[tag] ?? "GPS_0x\(String(tag, radix: 16, uppercase: true))"
        case .exifIFD:
            return exifTagNames[tag] ?? ifd0TagNames[tag] ?? "Exif_0x\(String(tag, radix: 16, uppercase: true))"
        default:
            return ifd0TagNames[tag] ?? "IFD_0x\(String(tag, radix: 16, uppercase: true))"
        }
    }

    private static let ifd0TagNames: [UInt16: String] = [
        0x0100: "ImageWidth", 0x0101: "ImageHeight", 0x0102: "BitsPerSample",
        0x0103: "Compression", 0x010E: "ImageDescription", 0x010F: "Make",
        0x0110: "Model", 0x0112: "Orientation", 0x011A: "XResolution",
        0x011B: "YResolution", 0x0128: "ResolutionUnit", 0x0131: "Software",
        0x0132: "DateTime", 0x013B: "Artist", 0x8298: "Copyright",
        0x8769: "ExifIFDPointer", 0x8825: "GPSIFDPointer",
    ]

    private static let exifTagNames: [UInt16: String] = [
        0x829A: "ExposureTime", 0x829D: "FNumber", 0x8822: "ExposureProgram",
        0x8827: "ISOSpeedRatings",
        0x8830: "SensitivityType", 0x8831: "StandardOutputSensitivity",
        0x8832: "RecommendedExposureIndex", 0x8833: "ISOSpeed",
        0x9000: "ExifVersion",
        0x9003: "DateTimeOriginal", 0x9004: "DateTimeDigitized",
        0x9010: "OffsetTime", 0x9011: "OffsetTimeOriginal", 0x9012: "OffsetTimeDigitized",
        0x9201: "ShutterSpeedValue", 0x9202: "ApertureValue",
        0x9203: "BrightnessValue", 0x9204: "ExposureBiasValue",
        0x9205: "MaxApertureValue", 0x9206: "SubjectDistance",
        0x9207: "MeteringMode", 0x9208: "LightSource",
        0x9209: "Flash", 0x920A: "FocalLength",
        0x9214: "SubjectArea",
        0x927C: "MakerNote", 0x9286: "UserComment",
        0x9290: "SubSecTime", 0x9291: "SubSecTimeOriginal", 0x9292: "SubSecTimeDigitized",
        0xA001: "ColorSpace",
        0xA002: "PixelXDimension", 0xA003: "PixelYDimension",
        0xA005: "InteropIFDPointer",
        0xA20E: "FocalPlaneXResolution", 0xA20F: "FocalPlaneYResolution",
        0xA210: "FocalPlaneResolutionUnit", 0xA217: "SensingMethod",
        0xA300: "FileSource", 0xA301: "SceneType",
        0xA401: "CustomRendered", 0xA402: "ExposureMode",
        0xA403: "WhiteBalance", 0xA404: "DigitalZoomRatio",
        0xA405: "FocalLengthIn35mmFilm", 0xA406: "SceneCaptureType",
        0xA407: "GainControl", 0xA408: "Contrast",
        0xA409: "Saturation", 0xA40A: "Sharpness",
        0xA40C: "SubjectDistanceRange",
        0xA420: "ImageUniqueID",
        0xA430: "CameraOwnerName", 0xA431: "BodySerialNumber",
        0xA432: "LensSpecification", 0xA433: "LensMake", 0xA434: "LensModel",
        0xA435: "LensSerialNumber",
        0xA460: "CompositeImage",
        0xA461: "SourceImageNumberOfCompositeImage",
        0xA462: "SourceExposureTimesOfCompositeImage",
    ]

    private static let gpsTagNames: [UInt16: String] = [
        0x0000: "GPSVersionID", 0x0001: "GPSLatitudeRef", 0x0002: "GPSLatitude",
        0x0003: "GPSLongitudeRef", 0x0004: "GPSLongitude",
        0x0005: "GPSAltitudeRef", 0x0006: "GPSAltitude",
        0x0007: "GPSTimeStamp",
        0x0008: "GPSSatellites", 0x0009: "GPSStatus",
        0x000A: "GPSMeasureMode", 0x000B: "GPSDOP",
        0x000C: "GPSSpeedRef", 0x000D: "GPSSpeed",
        0x000E: "GPSTrackRef", 0x000F: "GPSTrack",
        0x0010: "GPSImgDirectionRef", 0x0011: "GPSImgDirection",
        0x0012: "GPSMapDatum",
        0x0013: "GPSDestLatitudeRef", 0x0014: "GPSDestLatitude",
        0x0015: "GPSDestLongitudeRef", 0x0016: "GPSDestLongitude",
        0x0017: "GPSDestBearingRef", 0x0018: "GPSDestBearing",
        0x0019: "GPSDestDistanceRef", 0x001A: "GPSDestDistance",
        0x001B: "GPSProcessingMethod", 0x001C: "GPSAreaInformation",
        0x001D: "GPSDateStamp",
        0x001E: "GPSDifferential", 0x001F: "GPSHPositioningError",
    ]
}
