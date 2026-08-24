import Foundation

/// Parsed Exif metadata from a JPEG file.
public struct ExifData: Equatable, Sendable {
    public var ifd0: IFD?
    public var ifd1: IFD?       // Thumbnail IFD
    public var exifIFD: IFD?
    public var gpsIFD: IFD?
    public var makerNoteIFD: IFD?  // CR3: standalone MakerNote IFD from CMT3
    public var byteOrder: ByteOrder

    public init(byteOrder: ByteOrder = .bigEndian) {
        self.byteOrder = byteOrder
    }

    // MARK: - High-Level Accessors

    public var make: String? {
        ifd0?.entry(for: ExifTag.make)?.stringValue(endian: byteOrder)
    }

    public var model: String? {
        ifd0?.entry(for: ExifTag.model)?.stringValue(endian: byteOrder)
    }

    public var dateTime: String? {
        ifd0?.entry(for: ExifTag.dateTime)?.stringValue(endian: byteOrder)
    }

    public var dateTimeOriginal: String? {
        exifIFD?.entry(for: ExifTag.dateTimeOriginal)?.stringValue(endian: byteOrder)
    }

    public var orientation: UInt16? {
        ifd0?.entry(for: ExifTag.orientation)?.uint16Value(endian: byteOrder)
    }

    public var exposureTime: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.exposureTime)?.rationalValue(endian: byteOrder)
    }

    public var fNumber: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.fNumber)?.rationalValue(endian: byteOrder)
    }

    public var isoSpeed: UInt16? {
        exifIFD?.entry(for: ExifTag.isoSpeedRatings)?.uint16Value(endian: byteOrder)
    }

    public var focalLength: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.focalLength)?.rationalValue(endian: byteOrder)
    }

    public var software: String? {
        ifd0?.entry(for: ExifTag.software)?.stringValue(endian: byteOrder)
    }

    public var copyright: String? {
        ifd0?.entry(for: ExifTag.copyright)?.stringValue(endian: byteOrder)
    }

    public var artist: String? {
        ifd0?.entry(for: ExifTag.artist)?.stringValue(endian: byteOrder)
    }

    public var lensModel: String? {
        exifIFD?.entry(for: ExifTag.lensModel)?.stringValue(endian: byteOrder)
    }

    public var lensMake: String? {
        exifIFD?.entry(for: ExifTag.lensMake)?.stringValue(endian: byteOrder)
    }

    public var bodySerialNumber: String? {
        exifIFD?.entry(for: ExifTag.bodySerialNumber)?.stringValue(endian: byteOrder)
    }

    public var lensSerialNumber: String? {
        exifIFD?.entry(for: ExifTag.lensSerialNumber)?.stringValue(endian: byteOrder)
    }

    public var cameraOwnerName: String? {
        exifIFD?.entry(for: ExifTag.cameraOwnerName)?.stringValue(endian: byteOrder)
    }

    public var imageUniqueID: String? {
        exifIFD?.entry(for: ExifTag.imageUniqueID)?.stringValue(endian: byteOrder)
    }

    /// Subject distance in meters. Returns nil if absent or denominator is zero.
    /// Spec: a numerator of 0xFFFFFFFF means "infinity"; 0 means "unknown".
    public var subjectDistance: Double? {
        guard let r = exifIFD?.entry(for: ExifTag.subjectDistance)?.rationalValue(endian: byteOrder),
              r.denominator > 0 else { return nil }
        return Double(r.numerator) / Double(r.denominator)
    }

    public var apertureValue: (numerator: UInt32, denominator: UInt32)? {
        exifIFD?.entry(for: ExifTag.apertureValue)?.rationalValue(endian: byteOrder)
    }

    public var shutterSpeedValue: (numerator: Int32, denominator: Int32)? {
        exifIFD?.entry(for: ExifTag.shutterSpeedValue)?.srationalValue(endian: byteOrder)
    }

    public var pixelXDimension: UInt32? {
        if let entry = exifIFD?.entry(for: ExifTag.pixelXDimension) {
            return entry.uint32Value(endian: byteOrder)
                ?? entry.uint16Value(endian: byteOrder).map { UInt32($0) }
        }
        return nil
    }

    public var pixelYDimension: UInt32? {
        if let entry = exifIFD?.entry(for: ExifTag.pixelYDimension) {
            return entry.uint32Value(endian: byteOrder)
                ?? entry.uint16Value(endian: byteOrder).map { UInt32($0) }
        }
        return nil
    }

    public var focalLengthIn35mmFilm: UInt16? {
        exifIFD?.entry(for: ExifTag.focalLengthIn35mmFilm)?.uint16Value(endian: byteOrder)
    }

    // MARK: - SubSecond & Timezone Tags

    public var subSecTime: String? {
        exifIFD?.entry(for: ExifTag.subSecTime)?.stringValue(endian: byteOrder)
    }

    public var subSecTimeOriginal: String? {
        exifIFD?.entry(for: ExifTag.subSecTimeOriginal)?.stringValue(endian: byteOrder)
    }

    public var subSecTimeDigitized: String? {
        exifIFD?.entry(for: ExifTag.subSecTimeDigitized)?.stringValue(endian: byteOrder)
    }

    public var offsetTime: String? {
        exifIFD?.entry(for: ExifTag.offsetTime)?.stringValue(endian: byteOrder)
    }

    public var offsetTimeOriginal: String? {
        exifIFD?.entry(for: ExifTag.offsetTimeOriginal)?.stringValue(endian: byteOrder)
    }

    public var offsetTimeDigitized: String? {
        exifIFD?.entry(for: ExifTag.offsetTimeDigitized)?.stringValue(endian: byteOrder)
    }

    // MARK: - MakerNote

    public var makerNote: MakerNoteData?

    // MARK: - GPS

    public var gpsLatitude: Double? {
        guard let ref = gpsIFD?.entry(for: ExifTag.gpsLatitudeRef)?.stringValue(endian: byteOrder),
              let lat = gpsIFD?.entry(for: ExifTag.gpsLatitude) else { return nil }
        let degrees = parseGPSCoordinate(lat, endian: byteOrder)
        return ref == "S" ? -degrees : degrees
    }

    public var gpsLongitude: Double? {
        guard let ref = gpsIFD?.entry(for: ExifTag.gpsLongitudeRef)?.stringValue(endian: byteOrder),
              let lon = gpsIFD?.entry(for: ExifTag.gpsLongitude) else { return nil }
        let degrees = parseGPSCoordinate(lon, endian: byteOrder)
        return ref == "W" ? -degrees : degrees
    }

    /// Altitude in meters. Sign comes from GPSAltitudeRef (0 = above sea level, 1 = below).
    public var gpsAltitude: Double? {
        guard let r = gpsIFD?.entry(for: ExifTag.gpsAltitude)?.rationalValue(endian: byteOrder),
              r.denominator > 0 else { return nil }
        let value = Double(r.numerator) / Double(r.denominator)
        let ref = gpsIFD?.entry(for: ExifTag.gpsAltitudeRef)?.valueData.first ?? 0
        return ref == 1 ? -value : value
    }

    /// Image direction in degrees (0–360). Use `gpsImgDirectionRef` to know if true or magnetic north.
    public var gpsImgDirection: Double? {
        guard let r = gpsIFD?.entry(for: ExifTag.gpsImgDirection)?.rationalValue(endian: byteOrder),
              r.denominator > 0 else { return nil }
        return Double(r.numerator) / Double(r.denominator)
    }

    /// "T" (true north) or "M" (magnetic north).
    public var gpsImgDirectionRef: String? {
        gpsIFD?.entry(for: ExifTag.gpsImgDirectionRef)?.stringValue(endian: byteOrder)
    }

    /// Bearing to destination in degrees. Use `gpsDestBearingRef` to know if true or magnetic.
    public var gpsDestBearing: Double? {
        guard let r = gpsIFD?.entry(for: ExifTag.gpsDestBearing)?.rationalValue(endian: byteOrder),
              r.denominator > 0 else { return nil }
        return Double(r.numerator) / Double(r.denominator)
    }

    public var gpsDestBearingRef: String? {
        gpsIFD?.entry(for: ExifTag.gpsDestBearingRef)?.stringValue(endian: byteOrder)
    }

    /// Dilution of precision. Lower is better (typical good fix < 5).
    public var gpsDOP: Double? {
        guard let r = gpsIFD?.entry(for: ExifTag.gpsDOP)?.rationalValue(endian: byteOrder),
              r.denominator > 0 else { return nil }
        return Double(r.numerator) / Double(r.denominator)
    }

    /// Horizontal positioning error in meters (EXIF 2.31+).
    public var gpsHPositioningError: Double? {
        guard let r = gpsIFD?.entry(for: ExifTag.gpsHPositioningError)?.rationalValue(endian: byteOrder),
              r.denominator > 0 else { return nil }
        return Double(r.numerator) / Double(r.denominator)
    }

    private func parseGPSCoordinate(_ entry: IFDEntry, endian: ByteOrder) -> Double {
        guard entry.type == .rational, entry.count == 3, entry.valueData.count >= 24 else { return 0 }
        var reader = BinaryReader(data: entry.valueData)
        guard let degNum = try? reader.readUInt32(endian: endian),
              let degDen = try? reader.readUInt32(endian: endian),
              let minNum = try? reader.readUInt32(endian: endian),
              let minDen = try? reader.readUInt32(endian: endian),
              let secNum = try? reader.readUInt32(endian: endian),
              let secDen = try? reader.readUInt32(endian: endian) else { return 0 }
        let deg = degDen > 0 ? Double(degNum) / Double(degDen) : 0
        let min = minDen > 0 ? Double(minNum) / Double(minDen) : 0
        let sec = secDen > 0 ? Double(secNum) / Double(secDen) : 0
        return deg + min / 60.0 + sec / 3600.0
    }
}
