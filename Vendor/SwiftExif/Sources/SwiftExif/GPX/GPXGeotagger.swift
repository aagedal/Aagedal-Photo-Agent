import Foundation

/// Matches photo timestamps to GPX track data and builds GPS IFD entries.
public struct GPXGeotagger: Sendable {

    /// Match a photo's DateTimeOriginal to a GPX track and return interpolated coordinates.
    /// - Parameters:
    ///   - dateTimeOriginal: The photo's capture timestamp (EXIF format "YYYY:MM:DD HH:MM:SS").
    ///   - track: The GPX track to match against.
    ///   - maxOffset: Maximum time difference in seconds to accept a match. Default 60.
    ///   - timeZoneOffset: Camera timezone offset from UTC in seconds. Default 0.
    /// - Returns: Interpolated trackpoint, or nil if no match within maxOffset.
    public static func match(
        dateTimeOriginal: String,
        track: GPXTrack,
        maxOffset: TimeInterval = 60,
        timeZoneOffset: TimeInterval = 0
    ) -> GPXTrackpoint? {
        guard let photoDate = parseExifDate(dateTimeOriginal, timeZoneOffset: timeZoneOffset) else {
            return nil
        }

        let points = track.trackpoints
        guard !points.isEmpty else { return nil }

        // Binary search for the insertion point
        var lo = 0
        var hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].timestamp < photoDate {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // lo = index of first point >= photoDate
        let before = lo > 0 ? points[lo - 1] : nil
        let after = lo < points.count ? points[lo] : nil

        // Check if both bracketing points exist and are within maxOffset
        if let b = before, let a = after {
            let diffBefore = photoDate.timeIntervalSince(b.timestamp)
            let diffAfter = a.timestamp.timeIntervalSince(photoDate)

            if diffBefore <= maxOffset && diffAfter <= maxOffset {
                // Interpolate between the two points
                let totalInterval = a.timestamp.timeIntervalSince(b.timestamp)
                if totalInterval > 0 {
                    let factor = diffBefore / totalInterval
                    return interpolate(from: b, to: a, factor: factor, at: photoDate)
                }
                return b
            }
            // Fall through to check closest single point
        }

        // Check closest single point
        let candidates: [(GPXTrackpoint, TimeInterval)] = [
            before.map { ($0, abs(photoDate.timeIntervalSince($0.timestamp))) },
            after.map { ($0, abs(photoDate.timeIntervalSince($0.timestamp))) },
        ].compactMap { $0 }

        guard let closest = candidates.min(by: { $0.1 < $1.1 }),
              closest.1 <= maxOffset else { return nil }

        return closest.0
    }

    /// Build a complete GPS IFD from a trackpoint.
    public static func buildGPSIFD(from trackpoint: GPXTrackpoint, byteOrder: ByteOrder) -> IFD {
        var entries: [IFDEntry] = []

        // GPSVersionID (tag 0x0000): [2, 3, 0, 0]
        entries.append(IFDEntry(
            tag: ExifTag.gpsVersionID, type: .byte, count: 4,
            valueData: Data([2, 3, 0, 0])
        ))

        // Latitude
        let latRef: String = trackpoint.latitude >= 0 ? "N" : "S"
        entries.append(makeASCIIEntry(tag: ExifTag.gpsLatitudeRef, value: latRef))
        entries.append(makeRationalTripletEntry(
            tag: ExifTag.gpsLatitude,
            triplet: degreesToRationalTriplet(abs(trackpoint.latitude)),
            byteOrder: byteOrder
        ))

        // Longitude
        let lonRef: String = trackpoint.longitude >= 0 ? "E" : "W"
        entries.append(makeASCIIEntry(tag: ExifTag.gpsLongitudeRef, value: lonRef))
        entries.append(makeRationalTripletEntry(
            tag: ExifTag.gpsLongitude,
            triplet: degreesToRationalTriplet(abs(trackpoint.longitude)),
            byteOrder: byteOrder
        ))

        // Altitude (if present)
        if let elevation = trackpoint.elevation {
            let altRef: UInt8 = elevation >= 0 ? 0 : 1
            entries.append(IFDEntry(
                tag: ExifTag.gpsAltitudeRef, type: .byte, count: 1,
                valueData: Data([altRef, 0, 0, 0])
            ))
            let absAlt = abs(elevation)
            let altNum = UInt32(round(absAlt * 1000))
            var altWriter = BinaryWriter(capacity: 8)
            altWriter.writeUInt32(altNum, endian: byteOrder)
            altWriter.writeUInt32(1000, endian: byteOrder)
            entries.append(IFDEntry(
                tag: ExifTag.gpsAltitude, type: .rational, count: 1,
                valueData: altWriter.data
            ))
        }

        // GPS timestamp from the trackpoint date
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCalendar.dateComponents([.hour, .minute, .second, .year, .month, .day], from: trackpoint.timestamp)

        // GPSTimeStamp (tag 0x0007): 3 rationals (hour, minute, second)
        if let hour = components.hour, let minute = components.minute, let second = components.second {
            var tsWriter = BinaryWriter(capacity: 24)
            tsWriter.writeUInt32(UInt32(hour), endian: byteOrder)
            tsWriter.writeUInt32(1, endian: byteOrder)
            tsWriter.writeUInt32(UInt32(minute), endian: byteOrder)
            tsWriter.writeUInt32(1, endian: byteOrder)
            tsWriter.writeUInt32(UInt32(second), endian: byteOrder)
            tsWriter.writeUInt32(1, endian: byteOrder)
            entries.append(IFDEntry(
                tag: ExifTag.gpsTimeStamp, type: .rational, count: 3,
                valueData: tsWriter.data
            ))
        }

        // GPSDateStamp (tag 0x001D): "YYYY:MM:DD\0"
        if let year = components.year, let month = components.month, let day = components.day {
            let dateStr = String(format: "%04d:%02d:%02d", year, month, day) + "\0"
            entries.append(IFDEntry(
                tag: ExifTag.gpsDateStamp, type: .ascii,
                count: UInt32(dateStr.utf8.count),
                valueData: Data(dateStr.utf8)
            ))
        }

        return IFD(entries: entries.sorted { $0.tag < $1.tag })
    }

    /// Convert decimal degrees to rational triplet (degrees, minutes, seconds).
    public static func degreesToRationalTriplet(_ decimal: Double) -> [(numerator: UInt32, denominator: UInt32)] {
        let absVal = abs(decimal)
        let degrees = UInt32(absVal)
        let minutesDecimal = (absVal - Double(degrees)) * 60.0
        let minutes = UInt32(minutesDecimal)
        let secondsDecimal = (minutesDecimal - Double(minutes)) * 60.0
        let secondsNum = UInt32(round(secondsDecimal * 10000))
        return [
            (degrees, 1),
            (minutes, 1),
            (secondsNum, 10000),
        ]
    }

    // MARK: - Private

    private static func interpolate(from a: GPXTrackpoint, to b: GPXTrackpoint, factor: Double, at date: Date) -> GPXTrackpoint {
        let lat = a.latitude + factor * (b.latitude - a.latitude)
        let lon = a.longitude + factor * (b.longitude - a.longitude)
        let ele: Double?
        if let ea = a.elevation, let eb = b.elevation {
            ele = ea + factor * (eb - ea)
        } else {
            ele = a.elevation ?? b.elevation
        }
        return GPXTrackpoint(latitude: lat, longitude: lon, elevation: ele, timestamp: date)
    }

    private static func makeASCIIEntry(tag: UInt16, value: String) -> IFDEntry {
        let str = value + "\0"
        let data = Data(str.utf8)
        return IFDEntry(tag: tag, type: .ascii, count: UInt32(data.count), valueData: data)
    }

    private static func makeRationalTripletEntry(
        tag: UInt16,
        triplet: [(numerator: UInt32, denominator: UInt32)],
        byteOrder: ByteOrder
    ) -> IFDEntry {
        var writer = BinaryWriter(capacity: 24)
        for (num, den) in triplet {
            writer.writeUInt32(num, endian: byteOrder)
            writer.writeUInt32(den, endian: byteOrder)
        }
        return IFDEntry(tag: tag, type: .rational, count: 3, valueData: writer.data)
    }

    private static func parseExifDate(_ dateStr: String, timeZoneOffset: TimeInterval) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: dateStr) else { return nil }
        // The EXIF date is in camera local time. Subtract the timezone offset to get UTC.
        return date.addingTimeInterval(-timeZoneOffset)
    }
}
