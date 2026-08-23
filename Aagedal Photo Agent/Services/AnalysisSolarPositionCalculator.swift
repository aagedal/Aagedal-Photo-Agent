import Foundation

/// Versioned calculation method persisted with a solar overlay and frozen in reports.
nonisolated enum AnalysisSolarCalculationMethod: String, Codable, CaseIterable, Sendable {
    case meeusNOAAV1

    var displayName: String {
        switch self {
        case .meeusNOAAV1: "Meeus/NOAA v1"
        }
    }
}

nonisolated struct AnalysisSolarInput: Equatable, Sendable {
    let instant: Date
    let coordinate: AnalysisGeoCoordinate
}

nonisolated struct AnalysisSolarPosition: Codable, Equatable, Sendable {
    let azimuthDegrees: Double
    let geometricElevationDegrees: Double
    let apparentElevationDegrees: Double

    var isBelowHorizon: Bool { apparentElevationDegrees < 0 }

    var expectedShadowAzimuthDegrees: Double {
        AnalysisSolarPositionCalculator.normalizedDegrees(azimuthDegrees + 180)
    }

    /// Estimated shadow length for a vertical object on level ground. Apparent elevation is used
    /// so the result follows the same horizon/refraction boundary as the visible map rays.
    func expectedShadowLengthMeters(objectHeightMeters: Double) -> Double? {
        guard objectHeightMeters.isFinite,
              objectHeightMeters > 0,
              !isBelowHorizon,
              apparentElevationDegrees > 0 else { return nil }
        let length = objectHeightMeters / tan(apparentElevationDegrees * .pi / 180)
        guard length.isFinite, length >= 0 else { return nil }
        return length
    }
}

nonisolated struct AnalysisSolarEvent: Codable, Equatable, Sendable {
    let instant: Date
    let azimuthDegrees: Double
}

nonisolated enum AnalysisSolarPolarCondition: String, Codable, Equatable, Sendable {
    case polarDay
    case polarNight
}

nonisolated struct AnalysisSolarDay: Codable, Equatable, Sendable {
    let position: AnalysisSolarPosition
    let sunrise: AnalysisSolarEvent?
    let solarNoon: AnalysisSolarEvent
    let sunset: AnalysisSolarEvent?
    let polarCondition: AnalysisSolarPolarCondition?
    let method: AnalysisSolarCalculationMethod
}

nonisolated enum AnalysisSolarCalculationError: Error, Equatable, Sendable, LocalizedError {
    case invalidCoordinate
    case invalidInstant
    case invalidUTCOffset
    case unsupportedYear(Int)
    case nonConvergence(String)

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate:
            "The solar calculation requires a finite WGS-84 coordinate."
        case .invalidInstant:
            "The solar calculation requires a finite absolute instant."
        case .invalidUTCOffset:
            "The civil-day UTC offset must be between UTC-14:00 and UTC+14:00."
        case .unsupportedYear(let year):
            "The year \(year) is outside the supported 1800–2100 calculation range."
        case .nonConvergence(let event):
            "The \(event) calculation did not converge."
        }
    }
}

/// Foundation-only solar position and civil-day event calculator.
///
/// The equations follow NOAA's published adaptation of Jean Meeus' solar equations. They use a
/// proleptic Gregorian calendar, WGS-84 coordinates, and no process locale or current timezone.
/// Sunrise and sunset use the NOAA apparent-horizon convention of -0.833° geometric elevation.
nonisolated enum AnalysisSolarPositionCalculator {
    static let supportedYears = 1800...2100
    static let method = AnalysisSolarCalculationMethod.meeusNOAAV1

    private static let secondsPerDay = 86_400.0
    private static let julianDayAtUnixEpoch = 2_440_587.5
    private static let apparentHorizonZenithDegrees = 90.833
    private static let maximumIterations = 12
    private static let convergenceMinutes = 0.000_1

    static func calculate(
        input: AnalysisSolarInput,
        civilDayOffsetMinutes: Int
    ) throws -> AnalysisSolarDay {
        guard input.coordinate.isValid else {
            throw AnalysisSolarCalculationError.invalidCoordinate
        }
        guard input.instant.timeIntervalSinceReferenceDate.isFinite else {
            throw AnalysisSolarCalculationError.invalidInstant
        }
        guard (-14 * 60...14 * 60).contains(civilDayOffsetMinutes),
              let timeZone = TimeZone(secondsFromGMT: civilDayOffsetMinutes * 60) else {
            throw AnalysisSolarCalculationError.invalidUTCOffset
        }

        let civilDayStart = try startOfCivilDay(containing: input.instant, timeZone: timeZone)
        try validateSupportedYear(of: civilDayStart, timeZone: timeZone)

        let position = positionUnchecked(at: input.instant, coordinate: input.coordinate)
        let solarNoon = try event(
            kind: .solarNoon,
            civilDayStart: civilDayStart,
            utcOffsetMinutes: civilDayOffsetMinutes,
            coordinate: input.coordinate
        )

        let noonParameters = parameters(at: solarNoon.instant)
        let polarCondition = polarCondition(
            latitudeDegrees: input.coordinate.latitude,
            declinationDegrees: noonParameters.declinationDegrees
        )

        let sunrise: AnalysisSolarEvent?
        let sunset: AnalysisSolarEvent?
        if polarCondition == nil {
            sunrise = try event(
                kind: .sunrise,
                civilDayStart: civilDayStart,
                utcOffsetMinutes: civilDayOffsetMinutes,
                coordinate: input.coordinate
            )
            sunset = try event(
                kind: .sunset,
                civilDayStart: civilDayStart,
                utcOffsetMinutes: civilDayOffsetMinutes,
                coordinate: input.coordinate
            )
        } else {
            sunrise = nil
            sunset = nil
        }

        return AnalysisSolarDay(
            position: position,
            sunrise: sunrise,
            solarNoon: solarNoon,
            sunset: sunset,
            polarCondition: polarCondition,
            method: method
        )
    }

    static func position(
        at instant: Date,
        coordinate: AnalysisGeoCoordinate
    ) throws -> AnalysisSolarPosition {
        guard coordinate.isValid else {
            throw AnalysisSolarCalculationError.invalidCoordinate
        }
        guard instant.timeIntervalSinceReferenceDate.isFinite else {
            throw AnalysisSolarCalculationError.invalidInstant
        }
        try validateSupportedYear(of: instant, timeZone: TimeZone(secondsFromGMT: 0)!)

        return positionUnchecked(at: instant, coordinate: coordinate)
    }

    private static func positionUnchecked(
        at instant: Date,
        coordinate: AnalysisGeoCoordinate
    ) -> AnalysisSolarPosition {
        let values = parameters(at: instant)
        let utcMinutes = positiveRemainder(
            (julianDay(for: instant) + 0.5) * 1_440,
            divisor: 1_440
        )
        let trueSolarMinutes = positiveRemainder(
            utcMinutes + values.equationOfTimeMinutes + 4 * coordinate.longitude,
            divisor: 1_440
        )
        var hourAngleDegrees = trueSolarMinutes / 4 - 180
        if hourAngleDegrees < -180 {
            hourAngleDegrees += 360
        }

        let latitude = radians(coordinate.latitude)
        let declination = radians(values.declinationDegrees)
        let hourAngle = radians(hourAngleDegrees)
        let cosineZenith = clamped(
            sin(latitude) * sin(declination)
                + cos(latitude) * cos(declination) * cos(hourAngle),
            lower: -1,
            upper: 1
        )
        let geometricElevation = 90 - degrees(acos(cosineZenith))

        let azimuth: Double
        let denominator = cos(hourAngle) * sin(latitude) - tan(declination) * cos(latitude)
        if abs(sin(hourAngle)) < 1e-14, abs(denominator) < 1e-14 {
            azimuth = coordinate.latitude >= 0 ? 180 : 0
        } else {
            azimuth = normalizedDegrees(degrees(atan2(sin(hourAngle), denominator)) + 180)
        }

        return AnalysisSolarPosition(
            azimuthDegrees: azimuth,
            geometricElevationDegrees: geometricElevation,
            apparentElevationDegrees: geometricElevation
                + atmosphericRefractionDegrees(geometricElevationDegrees: geometricElevation)
        )
    }

    /// Julian date of an absolute instant. J2000.0 is 2451545.0.
    static func julianDay(for instant: Date) -> Double {
        instant.timeIntervalSince1970 / secondsPerDay + julianDayAtUnixEpoch
    }

    static func normalizedDegrees(_ value: Double) -> Double {
        positiveRemainder(value, divisor: 360)
    }

    private enum EventKind: String {
        case sunrise
        case solarNoon = "solar noon"
        case sunset
    }

    private struct SolarParameters {
        let equationOfTimeMinutes: Double
        let declinationDegrees: Double
    }

    private static func event(
        kind: EventKind,
        civilDayStart: Date,
        utcOffsetMinutes: Int,
        coordinate: AnalysisGeoCoordinate
    ) throws -> AnalysisSolarEvent {
        var localMinutes = normalizedLocalMinutes(
            720 - 4 * coordinate.longitude + Double(utcOffsetMinutes)
        )
        var converged = false

        for _ in 0..<maximumIterations {
            let candidate = civilDayStart.addingTimeInterval(localMinutes * 60)
            let values = parameters(at: candidate)
            let hourAngle: Double
            switch kind {
            case .solarNoon:
                hourAngle = 0
            case .sunrise, .sunset:
                guard let magnitude = sunriseHourAngleDegrees(
                    latitudeDegrees: coordinate.latitude,
                    declinationDegrees: values.declinationDegrees
                ) else {
                    throw AnalysisSolarCalculationError.nonConvergence(kind.rawValue)
                }
                hourAngle = kind == .sunrise ? magnitude : -magnitude
            }

            let next = normalizedLocalMinutes(
                720
                    - 4 * (coordinate.longitude + hourAngle)
                    - values.equationOfTimeMinutes
                    + Double(utcOffsetMinutes)
            )
            if circularMinuteDistance(next, localMinutes) <= convergenceMinutes {
                localMinutes = next
                converged = true
                break
            }
            localMinutes = next
        }

        guard converged else {
            throw AnalysisSolarCalculationError.nonConvergence(kind.rawValue)
        }
        let instant = civilDayStart.addingTimeInterval(localMinutes * 60)
        let solarPosition = positionUnchecked(at: instant, coordinate: coordinate)
        return AnalysisSolarEvent(instant: instant, azimuthDegrees: solarPosition.azimuthDegrees)
    }

    private static func parameters(at instant: Date) -> SolarParameters {
        let julianCentury = (julianDay(for: instant) - 2_451_545) / 36_525
        let geometricMeanLongitude = normalizedDegrees(
            280.46646 + julianCentury * (36_000.76983 + julianCentury * 0.0003032)
        )
        let geometricMeanAnomaly = 357.52911
            + julianCentury * (35_999.05029 - 0.0001537 * julianCentury)
        let eccentricity = 0.016708634
            - julianCentury * (0.000042037 + 0.0000001267 * julianCentury)

        let anomaly = radians(geometricMeanAnomaly)
        let equationOfCenter = sin(anomaly)
            * (1.914602 - julianCentury * (0.004817 + 0.000014 * julianCentury))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * julianCentury)
            + sin(3 * anomaly) * 0.000289
        let trueLongitude = geometricMeanLongitude + equationOfCenter
        let omega = 125.04 - 1_934.136 * julianCentury
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(radians(omega))

        let seconds = 21.448 - julianCentury
            * (46.815 + julianCentury * (0.00059 - julianCentury * 0.001813))
        let meanObliquity = 23 + (26 + seconds / 60) / 60
        let correctedObliquity = meanObliquity + 0.00256 * cos(radians(omega))
        let obliquity = radians(correctedObliquity)
        let declination = degrees(asin(sin(obliquity) * sin(radians(apparentLongitude))))

        let y = pow(tan(obliquity / 2), 2)
        let longitude = radians(geometricMeanLongitude)
        let equationOfTime = 4 * degrees(
            y * sin(2 * longitude)
                - 2 * eccentricity * sin(anomaly)
                + 4 * eccentricity * y * sin(anomaly) * cos(2 * longitude)
                - 0.5 * y * y * sin(4 * longitude)
                - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)
        )

        return SolarParameters(
            equationOfTimeMinutes: equationOfTime,
            declinationDegrees: declination
        )
    }

    private static func sunriseHourAngleDegrees(
        latitudeDegrees: Double,
        declinationDegrees: Double
    ) -> Double? {
        let latitude = radians(latitudeDegrees)
        let declination = radians(declinationDegrees)
        let cosineHourAngle = cos(radians(apparentHorizonZenithDegrees))
            / (cos(latitude) * cos(declination))
            - tan(latitude) * tan(declination)
        guard (-1...1).contains(cosineHourAngle) else { return nil }
        return degrees(acos(cosineHourAngle))
    }

    private static func polarCondition(
        latitudeDegrees: Double,
        declinationDegrees: Double
    ) -> AnalysisSolarPolarCondition? {
        let latitude = radians(latitudeDegrees)
        let declination = radians(declinationDegrees)
        let cosineHourAngle = cos(radians(apparentHorizonZenithDegrees))
            / (cos(latitude) * cos(declination))
            - tan(latitude) * tan(declination)
        if cosineHourAngle > 1 { return .polarNight }
        if cosineHourAngle < -1 { return .polarDay }
        return nil
    }

    private static func atmosphericRefractionDegrees(
        geometricElevationDegrees elevation: Double
    ) -> Double {
        guard elevation <= 85 else { return 0 }
        if elevation > 5 {
            let tangent = tan(radians(elevation))
            return (58.1 / tangent - 0.07 / pow(tangent, 3) + 0.000086 / pow(tangent, 5)) / 3_600
        }
        if elevation > -0.575 {
            return (1_735
                - 518.2 * elevation
                + 103.4 * pow(elevation, 2)
                - 12.79 * pow(elevation, 3)
                + 0.711 * pow(elevation, 4)) / 3_600
        }
        return -20.774 / tan(radians(elevation)) / 3_600
    }

    private static func startOfCivilDay(
        containing instant: Date,
        timeZone: TimeZone
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let start = calendar.date(from: components) else {
            throw AnalysisSolarCalculationError.invalidInstant
        }
        return start
    }

    private static func validateSupportedYear(of date: Date, timeZone: TimeZone) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: date)
        guard supportedYears.contains(year) else {
            throw AnalysisSolarCalculationError.unsupportedYear(year)
        }
    }

    private static func normalizedLocalMinutes(_ minutes: Double) -> Double {
        positiveRemainder(minutes, divisor: 1_440)
    }

    private static func circularMinuteDistance(_ first: Double, _ second: Double) -> Double {
        let direct = abs(first - second)
        return min(direct, 1_440 - direct)
    }

    private static func positiveRemainder(_ value: Double, divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private static func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
