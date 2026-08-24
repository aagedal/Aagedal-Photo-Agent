import Foundation

/// Calculates derived/composite metadata values from existing EXIF data.
/// Equivalent to ExifTool's composite tags.
public struct CompositeTagCalculator: Sendable {

    /// Calculate all available composite tags from the given ExifData.
    /// Returns a dictionary with "Composite:" prefixed keys.
    public static func calculate(from exif: ExifData) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let v = apertureFromAPEX(exif) { dict["Composite:Aperture"] = v }
        if let v = shutterSpeedFromAPEX(exif) { dict["Composite:ShutterSpeed"] = v }
        if let v = megapixels(exif) { dict["Composite:Megapixels"] = v }
        if let v = lensID(exif) { dict["Composite:LensID"] = v }
        if let v = scaleFactor35efl(exif) { dict["Composite:ScaleFactor35efl"] = v }
        if let v = lightValue(exif) { dict["Composite:LightValue"] = v }
        if let v = fieldOfView(exif) { dict["Composite:FOV"] = v }
        if let v = gpsPosition(exif) { dict["Composite:GPSPosition"] = v }
        if let v = imageSize(exif) { dict["Composite:ImageSize"] = v }
        if let v = subSecDateTimeOriginal(exif) { dict["Composite:SubSecDateTimeOriginal"] = v }
        if let v = subSecCreateDate(exif) { dict["Composite:SubSecCreateDate"] = v }
        if let v = subSecModifyDate(exif) { dict["Composite:SubSecModifyDate"] = v }
        if let v = gpsDateTime(exif) { dict["Composite:GPSDateTime"] = v }
        if let v = circleOfConfusion(exif) { dict["Composite:CircleOfConfusion"] = v }
        if let v = hyperfocalDistance(exif) { dict["Composite:HyperfocalDistance"] = v }
        if let v = depthOfField(exif) { dict["Composite:DOF"] = v }

        return dict
    }

    // MARK: - Individual Calculators

    /// Calculate f-number from APEX ApertureValue: f = 2^(ApertureValue/2)
    public static func apertureFromAPEX(_ exif: ExifData) -> Double? {
        guard let av = exif.apertureValue, av.denominator > 0 else { return nil }
        let value = Double(av.numerator) / Double(av.denominator)
        return pow(2.0, value / 2.0)
    }

    /// Calculate exposure time in seconds from APEX ShutterSpeedValue: t = 1 / 2^value
    public static func shutterSpeedFromAPEX(_ exif: ExifData) -> Double? {
        guard let sv = exif.shutterSpeedValue, sv.denominator != 0 else { return nil }
        let value = Double(sv.numerator) / Double(sv.denominator)
        return 1.0 / pow(2.0, value)
    }

    /// Calculate megapixels from PixelXDimension * PixelYDimension / 1_000_000.
    public static func megapixels(_ exif: ExifData) -> Double? {
        guard let w = exif.pixelXDimension, let h = exif.pixelYDimension,
              w > 0, h > 0 else { return nil }
        return Double(w) * Double(h) / 1_000_000.0
    }

    /// Combined LensID from LensMake and LensModel.
    public static func lensID(_ exif: ExifData) -> String? {
        let make = exif.lensMake
        let model = exif.lensModel
        if let make = make, let model = model {
            if model.lowercased().hasPrefix(make.lowercased()) {
                return model
            }
            return "\(make) \(model)"
        }
        return model ?? make
    }

    /// Scale factor: FocalLengthIn35mmFilm / FocalLength.
    public static func scaleFactor35efl(_ exif: ExifData) -> Double? {
        guard let fl35 = exif.focalLengthIn35mmFilm, fl35 > 0,
              let fl = exif.focalLength, fl.denominator > 0 else { return nil }
        let focalLength = Double(fl.numerator) / Double(fl.denominator)
        guard focalLength > 0 else { return nil }
        return Double(fl35) / focalLength
    }

    /// Light Value (EV at ISO 100): log2(f^2 / t) adjusted for ISO.
    public static func lightValue(_ exif: ExifData) -> Double? {
        let fNum: Double
        if let fn = exif.fNumber, fn.denominator > 0 {
            fNum = Double(fn.numerator) / Double(fn.denominator)
        } else if let av = apertureFromAPEX(exif) {
            fNum = av
        } else {
            return nil
        }

        let shutterTime: Double
        if let et = exif.exposureTime, et.denominator > 0 {
            shutterTime = Double(et.numerator) / Double(et.denominator)
        } else if let ss = shutterSpeedFromAPEX(exif) {
            shutterTime = ss
        } else {
            return nil
        }

        guard fNum > 0, shutterTime > 0 else { return nil }

        let ev100 = log2((fNum * fNum) / shutterTime)

        guard let iso = exif.isoSpeed, iso > 0 else { return ev100 }
        return ev100 - log2(Double(iso) / 100.0)
    }

    /// Field of view in degrees, computed from focal length and sensor dimensions.
    public static func fieldOfView(_ exif: ExifData) -> Double? {
        guard let fl = exif.focalLength, fl.denominator > 0 else { return nil }
        let focalLength = Double(fl.numerator) / Double(fl.denominator)
        guard focalLength > 0 else { return nil }

        // Try to determine sensor width from FocalPlaneXResolution + ResolutionUnit
        guard let fpxrEntry = exif.exifIFD?.entry(for: ExifTag.focalPlaneXResolution),
              let fpxr = fpxrEntry.rationalValue(endian: exif.byteOrder),
              fpxr.denominator > 0 else { return nil }

        let fpxResolution = Double(fpxr.numerator) / Double(fpxr.denominator)
        guard fpxResolution > 0 else { return nil }

        // Get pixel width
        guard let pixelWidth = exif.pixelXDimension, pixelWidth > 0 else { return nil }

        // FocalPlaneResolutionUnit: 2=inches, 3=cm, default to inches
        let unitEntry = exif.exifIFD?.entry(for: ExifTag.focalPlaneResolutionUnit)
        let unit = unitEntry?.uint16Value(endian: exif.byteOrder) ?? 2
        let mmPerUnit: Double = (unit == 3) ? 10.0 : 25.4

        let sensorWidth = Double(pixelWidth) / fpxResolution * mmPerUnit
        return 2.0 * atan(sensorWidth / (2.0 * focalLength)) * 180.0 / .pi
    }

    /// Combined GPS position string: "lat, lon".
    public static func gpsPosition(_ exif: ExifData) -> String? {
        guard let lat = exif.gpsLatitude, let lon = exif.gpsLongitude else { return nil }
        return String(format: "%.6f, %.6f", lat, lon)
    }

    /// "WIDTHxHEIGHT" string from PixelXDimension/PixelYDimension.
    public static func imageSize(_ exif: ExifData) -> String? {
        guard let w = exif.pixelXDimension, let h = exif.pixelYDimension,
              w > 0, h > 0 else { return nil }
        return "\(w)x\(h)"
    }

    /// DateTimeOriginal merged with SubSecTimeOriginal and OffsetTimeOriginal.
    /// Format: "YYYY:MM:DD HH:MM:SS[.SSS][±HH:MM]".
    public static func subSecDateTimeOriginal(_ exif: ExifData) -> String? {
        return mergeDateSubSecOffset(
            base: exif.dateTimeOriginal,
            subSec: exif.subSecTimeOriginal,
            offset: exif.offsetTimeOriginal
        )
    }

    /// DateTimeDigitized merged with SubSecTimeDigitized and OffsetTimeDigitized.
    /// (ExifTool calls this "CreateDate"; the EXIF tag is DateTimeDigitized.)
    public static func subSecCreateDate(_ exif: ExifData) -> String? {
        let digitized = exif.exifIFD?
            .entry(for: ExifTag.dateTimeDigitized)?
            .stringValue(endian: exif.byteOrder)
        return mergeDateSubSecOffset(
            base: digitized,
            subSec: exif.subSecTimeDigitized,
            offset: exif.offsetTimeDigitized
        )
    }

    /// DateTime (file modify) merged with SubSecTime and OffsetTime.
    public static func subSecModifyDate(_ exif: ExifData) -> String? {
        return mergeDateSubSecOffset(
            base: exif.dateTime,
            subSec: exif.subSecTime,
            offset: exif.offsetTime
        )
    }

    /// GPSDateStamp + GPSTimeStamp combined into "YYYY:MM:DD HH:MM:SSZ" (UTC).
    public static func gpsDateTime(_ exif: ExifData) -> String? {
        guard let dateStamp = exif.gpsIFD?
                .entry(for: ExifTag.gpsDateStamp)?
                .stringValue(endian: exif.byteOrder),
              let timeEntry = exif.gpsIFD?.entry(for: ExifTag.gpsTimeStamp),
              timeEntry.type == .rational,
              timeEntry.count == 3,
              timeEntry.valueData.count >= 24 else { return nil }

        var reader = BinaryReader(data: timeEntry.valueData)
        guard let hN = try? reader.readUInt32(endian: exif.byteOrder),
              let hD = try? reader.readUInt32(endian: exif.byteOrder),
              let mN = try? reader.readUInt32(endian: exif.byteOrder),
              let mD = try? reader.readUInt32(endian: exif.byteOrder),
              let sN = try? reader.readUInt32(endian: exif.byteOrder),
              let sD = try? reader.readUInt32(endian: exif.byteOrder),
              hD > 0, mD > 0, sD > 0 else { return nil }

        let h = Int(hN / hD)
        let m = Int(mN / mD)
        let s = Double(sN) / Double(sD)
        let secStr = s == floor(s) ? String(format: "%02d", Int(s)) : String(format: "%06.3f", s)
        return String(format: "%@ %02d:%02d:%@Z", dateStamp, h, m, secStr)
    }

    /// Circle of confusion in mm. Uses full-frame reference of 0.030 mm scaled by crop factor.
    public static func circleOfConfusion(_ exif: ExifData) -> Double? {
        guard let scale = scaleFactor35efl(exif), scale > 0 else { return nil }
        return 0.030 / scale
    }

    /// Hyperfocal distance in meters. H = f² / (N · c) + f, where f and c are in mm and result in m.
    public static func hyperfocalDistance(_ exif: ExifData) -> Double? {
        guard let fl = exif.focalLength, fl.denominator > 0 else { return nil }
        let f = Double(fl.numerator) / Double(fl.denominator)
        guard f > 0 else { return nil }

        let n: Double
        if let fn = exif.fNumber, fn.denominator > 0 {
            n = Double(fn.numerator) / Double(fn.denominator)
        } else if let av = apertureFromAPEX(exif) {
            n = av
        } else {
            return nil
        }
        guard n > 0 else { return nil }

        guard let c = circleOfConfusion(exif), c > 0 else { return nil }

        // H in mm, then convert to meters.
        let hMm = (f * f) / (n * c) + f
        return hMm / 1000.0
    }

    /// Depth of field as "near m - far m" (or "near m - inf" beyond hyperfocal).
    /// Requires SubjectDistance, FocalLength, and FNumber/ApertureValue.
    public static func depthOfField(_ exif: ExifData) -> String? {
        guard let s = exif.subjectDistance, s > 0,
              let h = hyperfocalDistance(exif), h > 0,
              let fl = exif.focalLength, fl.denominator > 0 else { return nil }
        let fMm = Double(fl.numerator) / Double(fl.denominator)
        let f = fMm / 1000.0  // focal length in meters
        guard f > 0 else { return nil }

        let near = (h * (s - f)) / (h + (s - f))
        let denomFar = h - (s - f)
        let nearStr = String(format: "%.2f m", near)
        if denomFar <= 0 {
            return "\(nearStr) - inf"
        }
        let far = (h * (s - f)) / denomFar
        return String(format: "%@ - %.2f m", nearStr, far)
    }

    // MARK: - Private helpers

    private static func mergeDateSubSecOffset(base: String?, subSec: String?, offset: String?) -> String? {
        guard let base = base, !base.isEmpty else { return nil }
        var result = base
        if let sub = subSec?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
            // Strip any trailing nulls / non-digits, keep leading digits as fractional seconds.
            let digits = sub.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty {
                result += "." + String(digits)
            }
        }
        if let off = offset?.trimmingCharacters(in: .whitespacesAndNewlines), !off.isEmpty {
            result += off
        }
        return result
    }
}
