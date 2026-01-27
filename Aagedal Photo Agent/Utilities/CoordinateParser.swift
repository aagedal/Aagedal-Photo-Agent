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

    /// Parses "59.9139, 10.7522" or "59.9139 10.7522" or "-33.8688, 151.2093"
    private static func parseDD(_ input: String) -> (latitude: Double, longitude: Double)? {
        let pattern = /^\s*(-?\d+\.?\d*)\s*[,\s]\s*(-?\d+\.?\d*)\s*$/
        guard let match = input.firstMatch(of: pattern) else { return nil }
        guard let lat = Double(match.1), let lon = Double(match.2) else { return nil }
        return validate(latitude: lat, longitude: lon)
    }

    // MARK: - DMS Parsing

    /// Parses "59°54'50.0"N 10°45'7.9"E" and similar variants
    private static func parseDMS(_ input: String) -> (latitude: Double, longitude: Double)? {
        let dmsComponent = /(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
        let matches = input.matches(of: dmsComponent)
        guard matches.count == 2 else { return nil }

        guard let lat = dmsToDecimal(
            degrees: Int(matches[0].1)!,
            minutes: Int(matches[0].2)!,
            seconds: Double(matches[0].3)!,
            direction: matches[0].4.map { String($0) }
        ) else { return nil }

        guard let lon = dmsToDecimal(
            degrees: Int(matches[1].1)!,
            minutes: Int(matches[1].2)!,
            seconds: Double(matches[1].3)!,
            direction: matches[1].4.map { String($0) }
        ) else { return nil }

        return validate(latitude: lat, longitude: lon)
    }

    // MARK: - DDM Parsing

    /// Parses "59°54.833'N 10°45.132'E" and similar variants
    private static func parseDDM(_ input: String) -> (latitude: Double, longitude: Double)? {
        let ddmComponent = /(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
        let matches = input.matches(of: ddmComponent)
        guard matches.count == 2 else { return nil }

        guard let lat = ddmToDecimal(
            degrees: Int(matches[0].1)!,
            minutes: Double(matches[0].2)!,
            direction: matches[0].3.map { String($0) }
        ) else { return nil }

        guard let lon = ddmToDecimal(
            degrees: Int(matches[1].1)!,
            minutes: Double(matches[1].2)!,
            direction: matches[1].3.map { String($0) }
        ) else { return nil }

        return validate(latitude: lat, longitude: lon)
    }

    // MARK: - Helpers

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

    private static func decimalToDMS(_ decimal: Double) -> (degrees: Int, minutes: Int, seconds: Double) {
        let degrees = Int(decimal)
        let minutesDecimal = (decimal - Double(degrees)) * 60
        let minutes = Int(minutesDecimal)
        let seconds = (minutesDecimal - Double(minutes)) * 60
        return (degrees, minutes, seconds)
    }

    private static func decimalToDDM(_ decimal: Double) -> (degrees: Int, minutes: Double) {
        let degrees = Int(decimal)
        let minutes = (decimal - Double(degrees)) * 60
        return (degrees, minutes)
    }
}
