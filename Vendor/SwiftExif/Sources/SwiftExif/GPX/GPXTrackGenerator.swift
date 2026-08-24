import Foundation

/// Generates GPX track files from geotagged images (inverse of geotagging).
public struct GPXTrackGenerator: Sendable {

    /// Generate a GPX XML string from geotagged image files.
    /// Images without GPS data are silently skipped.
    public static func generate(from urls: [URL], name: String? = nil) throws -> String {
        var points: [(lat: Double, lon: Double, alt: Double?, time: Date?)] = []

        for url in urls {
            do {
                let metadata = try ImageMetadata.read(from: url)
                guard let lat = metadata.exif?.gpsLatitude,
                      let lon = metadata.exif?.gpsLongitude else { continue }

                let alt = extractAltitude(from: metadata)
                let time = extractDateTime(from: metadata)
                points.append((lat, lon, alt, time))
            } catch {
                continue // Skip files that can't be read
            }
        }

        return generateGPX(from: points, name: name)
    }

    /// Generate a GPX XML string from already-loaded metadata.
    /// Metadata instances without GPS data are silently skipped.
    public static func generate(from metadata: [ImageMetadata], name: String? = nil) -> String {
        var points: [(lat: Double, lon: Double, alt: Double?, time: Date?)] = []

        for meta in metadata {
            guard let lat = meta.exif?.gpsLatitude,
                  let lon = meta.exif?.gpsLongitude else { continue }

            let alt = extractAltitude(from: meta)
            let time = extractDateTime(from: meta)
            points.append((lat, lon, alt, time))
        }

        return generateGPX(from: points, name: name)
    }

    // MARK: - Private

    private static func generateGPX(
        from points: [(lat: Double, lon: Double, alt: Double?, time: Date?)],
        name: String?
    ) -> String {
        // Sort by time if available
        let sorted = points.sorted { a, b in
            guard let ta = a.time, let tb = b.time else { return false }
            return ta < tb
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="SwiftExif"
             xmlns="http://www.topografix.com/GPX/1/1">
        """

        if let name {
            xml += "\n  <metadata><name>\(escapeXML(name))</name></metadata>"
        }

        xml += "\n  <trk>"
        if let name {
            xml += "\n    <name>\(escapeXML(name))</name>"
        }
        xml += "\n    <trkseg>"

        for point in sorted {
            xml += "\n      <trkpt lat=\"\(String(format: "%.6f", point.lat))\" lon=\"\(String(format: "%.6f", point.lon))\">"
            if let alt = point.alt {
                xml += "\n        <ele>\(String(format: "%.1f", alt))</ele>"
            }
            if let time = point.time {
                xml += "\n        <time>\(isoFormatter.string(from: time))</time>"
            }
            xml += "\n      </trkpt>"
        }

        xml += "\n    </trkseg>"
        xml += "\n  </trk>"
        xml += "\n</gpx>\n"

        return xml
    }

    private static func extractAltitude(from metadata: ImageMetadata) -> Double? {
        guard let gpsIFD = metadata.exif?.gpsIFD,
              let altEntry = gpsIFD.entry(for: ExifTag.gpsAltitude),
              let endian = metadata.exif?.byteOrder else { return nil }

        guard altEntry.valueData.count >= 8 else { return nil }
        var reader = BinaryReader(data: altEntry.valueData)
        guard let num = try? reader.readUInt32(endian: endian),
              let den = try? reader.readUInt32(endian: endian),
              den > 0 else { return nil }

        var alt = Double(num) / Double(den)

        // Check altitude ref (0 = above sea level, 1 = below)
        if let refEntry = gpsIFD.entry(for: ExifTag.gpsAltitudeRef),
           !refEntry.valueData.isEmpty,
           refEntry.valueData[refEntry.valueData.startIndex] == 1 {
            alt = -alt
        }

        return alt
    }

    private static func extractDateTime(from metadata: ImageMetadata) -> Date? {
        guard let dateStr = metadata.exif?.dateTimeOriginal ?? metadata.exif?.dateTime else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateStr)
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
