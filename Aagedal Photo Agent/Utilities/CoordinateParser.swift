import Foundation

enum CoordinateFormat: String, CaseIterable {
    case decimalDegrees = "DD"
    case degreesMinutesSeconds = "DMS"
    case degreesDecimalMinutes = "DDM"
}

enum CoordinateParser {

    // MARK: - Parsing

    /// Attempts to parse a coordinate string in DD, DMS, or DDM format.
    /// Returns (latitude, longitude) or nil if parsing fails.
    static func parse(_ input: String) -> (latitude: Double, longitude: Double)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let result = parseDD(trimmed) { return result }
        if let result = parseDMS(trimmed) { return result }
        if let result = parseDDM(trimmed) { return result }
        return nil
    }

    // MARK: - Formatting

    static func format(latitude: Double, longitude: Double, format: CoordinateFormat) -> String {
        // A crafted/corrupt EXIF GPS value (inf/nan, or finite but out of range) would
        // trap Int(_:) in the DMS/DDM formatters below. Reject anything outside valid
        // coordinate bounds up front — `.contains` is already false for nan/inf.
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            return "—"
        }
        switch format {
        case .decimalDegrees:
            return formatDD(latitude: latitude, longitude: longitude)
        case .degreesMinutesSeconds:
            return formatDMS(latitude: latitude, longitude: longitude)
        case .degreesDecimalMinutes:
            return formatDDM(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: - DD Parsing

    /// Parses "59.9139, 10.7522" or "59.9139 10.7522" or "-33.8688, 151.2093", and
    /// decimal-comma pairs such as "59,9139 10,7522" or "59,9139; 10,7522".
    private static func parseDD(_ input: String) -> (latitude: Double, longitude: Double)? {
        let decimalComma = /^\s*(-?\d+,\d+)\s*(?:;|,\s|\s)\s*(-?\d+,\d+)\s*$/
        if let match = input.firstMatch(of: decimalComma) {
            guard let lat = Double(match.1.replacingOccurrences(of: ",", with: ".")),
                  let lon = Double(match.2.replacingOccurrences(of: ",", with: ".")) else {
                return nil
            }
            return validate(latitude: lat, longitude: lon)
        }
        let pattern = /^\s*(-?\d+\.?\d*)\s*([,\s])\s*(-?\d+\.?\d*)\s*$/
        guard let match = input.firstMatch(of: pattern) else { return nil }
        // "59,91" is far more likely one number written with a decimal comma than the
        // whole-degree pair (59, 91); refuse it instead of guessing a location.
        if match.2 == ",", !match.0.contains(" "), !match.1.contains("."), !match.3.contains(".") {
            return nil
        }
        guard let lat = Double(match.1), let lon = Double(match.3) else { return nil }
        return validate(latitude: lat, longitude: lon)
    }

    // MARK: - DMS Parsing

    /// Parses "59°54'50.0"N 10°45'7.9"E" and similar variants
    private static func parseDMS(_ input: String) -> (latitude: Double, longitude: Double)? {
        // The hemisphere letter may lead ("N 59°… E 10°…") or trail ("59°…N 10°…E").
        let dmsComponent = hemisphereLeads(input)
            ? /([NSEWnsew])?\s*(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?()?/
            : /()?(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
        let matches = input.matches(of: dmsComponent)
        guard matches.count == 2 else { return nil }

        guard let latDeg = Int(matches[0].2),
              let latMin = Int(matches[0].3),
              let latSec = Double(matches[0].4) else { return nil }
        guard let lat = dmsToDecimal(
            degrees: latDeg, minutes: latMin, seconds: latSec,
            direction: hemisphere(matches[0].1, matches[0].5)
        ) else { return nil }

        guard let lonDeg = Int(matches[1].2),
              let lonMin = Int(matches[1].3),
              let lonSec = Double(matches[1].4) else { return nil }
        guard let lon = dmsToDecimal(
            degrees: lonDeg, minutes: lonMin, seconds: lonSec,
            direction: hemisphere(matches[1].1, matches[1].5)
        ) else { return nil }

        return validate(latitude: lat, longitude: lon)
    }

    // MARK: - DDM Parsing

    /// Parses "59°54.833'N 10°45.132'E" and similar variants
    private static func parseDDM(_ input: String) -> (latitude: Double, longitude: Double)? {
        let ddmComponent = hemisphereLeads(input)
            ? /([NSEWnsew])?\s*(-?\d+)\s*°\s*([\d.]+)\s*[''′]()?/
            : /()?(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
        let matches = input.matches(of: ddmComponent)
        guard matches.count == 2 else { return nil }

        guard let latDeg = Int(matches[0].2),
              let latMin = Double(matches[0].3) else { return nil }
        guard let lat = ddmToDecimal(
            degrees: latDeg, minutes: latMin,
            direction: hemisphere(matches[0].1, matches[0].4)
        ) else { return nil }

        guard let lonDeg = Int(matches[1].2),
              let lonMin = Double(matches[1].3) else { return nil }
        guard let lon = ddmToDecimal(
            degrees: lonDeg, minutes: lonMin,
            direction: hemisphere(matches[1].1, matches[1].4)
        ) else { return nil }

        return validate(latitude: lat, longitude: lon)
    }

    // MARK: - Helpers

    /// "N 40°41'21\" W 74°2'40\"" writes each hemisphere before its number. Reading such
    /// input with the trailing-letter pattern hands each letter to the wrong component.
    private static func hemisphere(_ leading: Substring?, _ trailing: Substring?) -> String? {
        [leading, trailing].compactMap { $0 }.first { !$0.isEmpty }.map(String.init)
    }

    private static func hemisphereLeads(_ input: String) -> Bool {
        guard let first = input.first else { return false }
        return "NSEWnsew".contains(first)
    }

    private static func dmsToDecimal(degrees: Int, minutes: Int, seconds: Double, direction: String?) -> Double? {
        guard minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        var decimal = Double(abs(degrees)) + Double(minutes) / 60.0 + seconds / 3600.0
        if degrees < 0 { decimal = -decimal }
        if let dir = direction?.uppercased(), dir == "S" || dir == "W" {
            decimal = -abs(decimal)
        }
        return decimal
    }

    private static func ddmToDecimal(degrees: Int, minutes: Double, direction: String?) -> Double? {
        guard minutes >= 0, minutes < 60 else { return nil }
        var decimal = Double(abs(degrees)) + minutes / 60.0
        if degrees < 0 { decimal = -decimal }
        if let dir = direction?.uppercased(), dir == "S" || dir == "W" {
            decimal = -abs(decimal)
        }
        return decimal
    }

    private static func validate(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double)? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }

    // MARK: - Formatting

    private static func formatDD(latitude: Double, longitude: Double) -> String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    private static func formatDMS(latitude: Double, longitude: Double) -> String {
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        let latDMS = decimalToDMS(abs(latitude))
        let lonDMS = decimalToDMS(abs(longitude))
        return "\(latDMS.degrees)°\(latDMS.minutes)'\(String(format: "%.1f", latDMS.seconds))\"\(latDir) \(lonDMS.degrees)°\(lonDMS.minutes)'\(String(format: "%.1f", lonDMS.seconds))\"\(lonDir)"
    }

    private static func formatDDM(latitude: Double, longitude: Double) -> String {
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        let latDDM = decimalToDDM(abs(latitude))
        let lonDDM = decimalToDDM(abs(longitude))
        return "\(latDDM.degrees)°\(String(format: "%.3f", latDDM.minutes))'\(latDir) \(lonDDM.degrees)°\(String(format: "%.3f", lonDDM.minutes))'\(lonDir)"
    }

    /// Rounds to the printed precision (0.1") before splitting, so 59.96" carries into
    /// the next minute instead of printing as 60.0".
    private static func decimalToDMS(_ decimal: Double) -> (degrees: Int, minutes: Int, seconds: Double) {
        let tenths = Int((abs(decimal) * 36_000).rounded())
        let degrees = tenths / 36_000
        let minutes = (tenths % 36_000) / 600
        let seconds = Double(tenths % 600) / 10
        return (degrees, minutes, seconds)
    }

    /// Rounds to the printed precision (0.001') before splitting, so 59.9996' never prints as 60.000'.
    private static func decimalToDDM(_ decimal: Double) -> (degrees: Int, minutes: Double) {
        let thousandths = Int((abs(decimal) * 60_000).rounded())
        let degrees = thousandths / 60_000
        let minutes = Double(thousandths % 60_000) / 1_000
        return (degrees, minutes)
    }
}
