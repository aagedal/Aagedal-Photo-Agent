import Foundation
import SwiftMediaMetadata

/// Shared vocabulary for metadata readers and writers; independent of write services.
nonisolated enum XMPMetadataNamespace {
    static let app = "http://aagedal.me/ns/photo/1.0/"
    static let rights = "http://ns.adobe.com/xap/1.0/rights/"
    static let localizedTitleClearedProperty = "LocalizedTitleCleared"
}

/// Decodes captured XMP bytes without filesystem access or write-service dependencies.
/// Callers supply any sensor aspect needed for angled crops. Automation callers additionally
/// validate document completeness before treating the decoded values as authoritative.
nonisolated enum XMPMetadataReader {
    static func read(_ data: Data, imageAspect: () -> Double? = { nil }) -> IPTCMetadata? {
        guard let xmp = try? XMPReader.readFromXML(data) else { return nil }
        return parseMetadata(from: xmp, imageAspect: imageAspect)
    }

    static func parseMetadata(from xmp: XMPData, imageAspect: () -> Double?) -> IPTCMetadata {
        var dict = ImageMetadata(xmp: xmp).asMetadataDict()
        fillXMPOnlyGaps(&dict, xmp: xmp, imageAspect: imageAspect)
        var metadata = iptcMetadataFromDict(dict)
        if metadata.localizedTitles == nil,
           xmp.simpleValue(
               namespace: XMPMetadataNamespace.app,
               property: XMPMetadataNamespace.localizedTitleClearedProperty
           ) == "True" {
            metadata.localizedTitles = []
        }
        return metadata
    }

    /// `asMetadataDict` sources Orientation, GPS and the IPTC date only from the EXIF segment, which
    /// a sidecar-only `ImageMetadata(xmp:)` lacks. Fill those three from XMP, and seed the sensor
    /// dimensions for the angled-crop conversion (which otherwise reads dimensions a sidecar dict
    /// has none of) — all the other descriptive + crs fields `asMetadataDict` already covers.
    private static func fillXMPOnlyGaps(_ dict: inout [String: Any], xmp: XMPData, imageAspect: () -> Double?) {
        // Orientation — tiff authoritative, exif fallback (matches the old reader).
        let orientationString = xmp.tiffOrientation
            ?? xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
        if let orientationString, let orientation = Int(orientationString) {
            dict[MetadataDictKey.orientation] = orientation
        }

        // GPS — the sidecar stores decimal degrees in exif:GPSLatitude/Longitude; the reader expects
        // a Double. parseCoordinateComponent also tolerates the DMS / N-S-E-W forms other tools write.
        if let latString = xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSLatitude"),
           let lat = parseCoordinateComponent(latString) {
            dict[MetadataDictKey.gpsLatitude] = lat
        }
        if let lonString = xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSLongitude"),
           let lon = parseCoordinateComponent(lonString) {
            dict[MetadataDictKey.gpsLongitude] = lon
        }

        // photoshop:DateCreated (the IPTC date) — asMetadataDict only surfaces xmp:CreateDate.
        if dict[MetadataDictKey.dateCreated] == nil,
           let dateCreated = xmp.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated") {
            dict[MetadataDictKey.dateCreated] = dateCreated
        }

        // Angled-crop ACR→upright conversion needs the sensor aspect; iptcMetadataFromDict derives it
        // from image dimensions that a sidecar dict lacks. Seed them from the service's aspect closure
        // — only when the crop is actually angled, keeping the closure's file read lazy.
        if let angle = parseDoubleValue(dict[MetadataDictKey.crsCropAngle]), abs(angle) > 0.0001,
           dict[MetadataDictKey.imageWidth] == nil, dict[MetadataDictKey.imageHeight] == nil,
           let aspect = imageAspect(), aspect > 0 {
            dict[MetadataDictKey.imageWidth] = aspect * 10000.0
            dict[MetadataDictKey.imageHeight] = 10000.0
        }
    }

    /// Parses a GPS coordinate string — decimal, decimal + N/S/E/W, DMS, or DDM — into signed
    /// decimal degrees. (Ported from the old NSXML reader; sidecars we write use plain `%.6f`
    /// decimal, but third-party sidecars may use the other forms.)
    private static func parseCoordinateComponent(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) {
            return direct
        }

        let decimalWithDir = /^\s*(-?\d+\.?\d*)\s*([NSEWnsew])\s*$/
        if let match = trimmed.firstMatch(of: decimalWithDir),
           let base = Double(match.1) {
            let dir = String(match.2).uppercased()
            if dir == "S" || dir == "W" { return -abs(base) }
            return abs(base)
        }

        let dms = /(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: dms),
           let degrees = Int(match.1),
           let minutes = Int(match.2),
           let seconds = Double(match.3) {
            var decimal = Double(abs(degrees)) + Double(minutes) / 60.0 + seconds / 3600.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.4.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        let ddm = /(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: ddm),
           let degrees = Int(match.1),
           let minutes = Double(match.2) {
            var decimal = Double(abs(degrees)) + minutes / 60.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.3.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        return nil
    }

}
