import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Analysis solar position calculator")
struct AnalysisSolarPositionCalculatorTests {
    @Test("J2000 Julian date is exact")
    func j2000JulianDate() throws {
        let instant = try utcDate(2000, 1, 1, 12, 0, 0)
        #expect(abs(AnalysisSolarPositionCalculator.julianDay(for: instant) - 2_451_545) < 1e-9)
    }

    @Test("NREL SPA reference position remains within the NOAA-method tolerance")
    func nrelReferencePosition() throws {
        // NREL TP-560-34302 Appendix A.5: 2003-10-17 12:30:30 at UTC-07:00,
        // 39.742476 N, 105.1786 W. SPA reports azimuth 194.340241° and unrefracted
        // elevation 39.872046°. This calculator intentionally uses the documented NOAA/Meeus
        // approximation rather than copying the licensed SPA implementation.
        let input = AnalysisSolarInput(
            instant: try utcDate(2003, 10, 17, 19, 30, 30),
            coordinate: AnalysisGeoCoordinate(latitude: 39.742476, longitude: -105.1786)
        )

        let result = try AnalysisSolarPositionCalculator.calculate(
            input: input,
            civilDayOffsetMinutes: -7 * 60
        )

        #expect(abs(result.position.azimuthDegrees - 194.340241) < 0.03)
        #expect(abs(result.position.geometricElevationDegrees - 39.872046) < 0.03)
        #expect(result.method == .meeusNOAAV1)
    }

    @Test("NOAA Greenwich solstice events match the published method")
    func noaaGreenwichSolsticeEvents() throws {
        // Cross-checked against NOAA's day spreadsheet (retrieved 2026-08-19). NOAA describes
        // event accuracy as approximately one minute within ±72° latitude.
        let start = try utcDate(2024, 6, 20, 0, 0, 0)
        let input = AnalysisSolarInput(
            instant: try utcDate(2024, 6, 20, 12, 0, 0),
            coordinate: AnalysisGeoCoordinate(latitude: 51.4779, longitude: 0)
        )

        let result = try AnalysisSolarPositionCalculator.calculate(
            input: input,
            civilDayOffsetMinutes: 0
        )

        let sunrise = try #require(result.sunrise?.instant)
        let sunset = try #require(result.sunset?.instant)
        #expect(abs(sunrise.timeIntervalSince(start) / 60 - (3 * 60 + 43)) < 2)
        #expect(abs(result.solarNoon.instant.timeIntervalSince(start) / 60 - (12 * 60 + 2)) < 2)
        #expect(abs(sunset.timeIntervalSince(start) / 60 - (20 * 60 + 21)) < 2)
        #expect(result.polarCondition == nil)
    }

    @Test("Oslo summer and winter calculations have ordered civil-day events", arguments: [
        (2024, 6, 20, 120),
        (2024, 12, 21, 60),
    ])
    func osloEventsAreOrdered(year: Int, month: Int, day: Int, offset: Int) throws {
        let input = AnalysisSolarInput(
            instant: try utcDate(year, month, day, 12, 0, 0),
            coordinate: AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        )

        let result = try AnalysisSolarPositionCalculator.calculate(
            input: input,
            civilDayOffsetMinutes: offset
        )
        let sunrise = try #require(result.sunrise)
        let sunset = try #require(result.sunset)

        #expect(sunrise.instant < result.solarNoon.instant)
        #expect(result.solarNoon.instant < sunset.instant)
        #expect((0..<360).contains(sunrise.azimuthDegrees))
        #expect((0..<360).contains(sunset.azimuthDegrees))
    }

    @Test("Tromsø reports polar day and polar night")
    func polarConditions() throws {
        let coordinate = AnalysisGeoCoordinate(latitude: 69.6492, longitude: 18.9553)
        let summer = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(
                instant: try utcDate(2024, 6, 20, 12, 0, 0),
                coordinate: coordinate
            ),
            civilDayOffsetMinutes: 120
        )
        let winter = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(
                instant: try utcDate(2024, 12, 21, 12, 0, 0),
                coordinate: coordinate
            ),
            civilDayOffsetMinutes: 60
        )

        #expect(summer.polarCondition == .polarDay)
        #expect(summer.sunrise == nil)
        #expect(summer.sunset == nil)
        #expect(winter.polarCondition == .polarNight)
        #expect(winter.sunrise == nil)
        #expect(winter.sunset == nil)
    }

    @Test("Shadow bearing is the normalized opposite direction", arguments: [
        (0.0, 180.0),
        (90.0, 270.0),
        (181.0, 1.0),
        (359.5, 179.5),
    ])
    func shadowBearing(solar: Double, expected: Double) {
        let position = AnalysisSolarPosition(
            azimuthDegrees: solar,
            geometricElevationDegrees: 10,
            apparentElevationDegrees: 10.1
        )
        #expect(abs(position.expectedShadowAzimuthDegrees - expected) < 1e-12)
    }

    @Test("Shadow length uses object height and apparent elevation")
    func shadowLength() throws {
        let position = AnalysisSolarPosition(
            azimuthDegrees: 180,
            geometricElevationDegrees: 45,
            apparentElevationDegrees: 45
        )
        let belowHorizon = AnalysisSolarPosition(
            azimuthDegrees: 180,
            geometricElevationDegrees: -1,
            apparentElevationDegrees: -0.5
        )

        #expect(abs(try #require(
            position.expectedShadowLengthMeters(objectHeightMeters: 2)
        ) - 2) < 1e-12)
        #expect(belowHorizon.expectedShadowLengthMeters(objectHeightMeters: 2) == nil)
        #expect(position.expectedShadowLengthMeters(objectHeightMeters: 0) == nil)
    }

    @Test("Legacy solar overlays decode without a reference-object height")
    func legacyOverlayDecoding() throws {
        let instant = try utcDate(2024, 6, 20, 12, 0, 0)
        let overlay = AnalysisSolarOverlayState(
            timestamp: AnalysisTimestampValue(
                date: instant,
                precision: .minute,
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
        let encoded = try JSONEncoder().encode(overlay)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "shadowObjectHeightMeters")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            AnalysisSolarOverlayState.self,
            from: legacyData
        )

        #expect(decoded.shadowObjectHeightMeters == nil)
        #expect(decoded.validate())
    }

    @Test("Solar overlay rejects invalid reference-object heights")
    func invalidShadowObjectHeight() throws {
        let instant = try utcDate(2024, 6, 20, 12, 0, 0)
        var overlay = AnalysisSolarOverlayState(
            timestamp: AnalysisTimestampValue(
                date: instant,
                precision: .minute,
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        overlay.shadowObjectHeightMeters = 0
        #expect(!overlay.validate())
        overlay.shadowObjectHeightMeters = .infinity
        #expect(!overlay.validate())
    }

    @Test("Absolute position is independent of the selected civil-day offset")
    func positionDoesNotUseCurrentTimeZone() throws {
        let input = AnalysisSolarInput(
            instant: try utcDate(2024, 2, 29, 23, 45, 0),
            coordinate: AnalysisGeoCoordinate(latitude: 0, longitude: 179.9)
        )
        let west = try AnalysisSolarPositionCalculator.calculate(
            input: input,
            civilDayOffsetMinutes: -12 * 60
        )
        let east = try AnalysisSolarPositionCalculator.calculate(
            input: input,
            civilDayOffsetMinutes: 14 * 60
        )

        #expect(west.position == east.position)
    }

    @Test("Supported civil-year boundaries allow events across UTC-year boundaries")
    func supportedCivilYearBoundaries() throws {
        let east = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(
                instant: try utcDate(1799, 12, 31, 12, 30, 0),
                coordinate: AnalysisGeoCoordinate(latitude: 0, longitude: 179.9)
            ),
            civilDayOffsetMinutes: 14 * 60
        )
        let west = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(
                instant: try utcDate(2101, 1, 1, 8, 0, 0),
                coordinate: AnalysisGeoCoordinate(latitude: 0, longitude: -179.9)
            ),
            civilDayOffsetMinutes: -12 * 60
        )

        #expect(east.sunrise != nil)
        #expect(east.sunset != nil)
        #expect(west.sunrise != nil)
        #expect(west.sunset != nil)
    }

    @Test("Concurrent calculations are deterministic")
    func concurrentRepeatability() async throws {
        let input = AnalysisSolarInput(
            instant: try utcDate(2024, 3, 20, 10, 15, 30),
            coordinate: AnalysisGeoCoordinate(latitude: -33.8688, longitude: 151.2093)
        )
        let expected = try AnalysisSolarPositionCalculator.calculate(
            input: input,
            civilDayOffsetMinutes: 11 * 60
        )

        let results = try await withThrowingTaskGroup(of: AnalysisSolarDay.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try AnalysisSolarPositionCalculator.calculate(
                        input: input,
                        civilDayOffsetMinutes: 11 * 60
                    )
                }
            }
            var values: [AnalysisSolarDay] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 == expected })
    }

    @Test("shared map geometry preserves bearing and scales solar rays with the viewport")
    func solarMapGeometryScalesWithViewport() {
        let origin = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        let shortLength = AnalysisMapGeometry.solarRayLengthMeters(
            latitudeDelta: 0.01,
            longitudeDelta: 0.01,
            at: origin
        )
        let longLength = AnalysisMapGeometry.solarRayLengthMeters(
            latitudeDelta: 1,
            longitudeDelta: 1,
            at: origin
        )
        let destination = AnalysisMapGeometry.destinationCoordinate(
            from: origin,
            bearingDegrees: 90,
            distanceMeters: 1_000
        )

        #expect(shortLength != nil)
        #expect(longLength != nil)
        #expect((longLength ?? 0) > (shortLength ?? 0) * 90)
        #expect(abs(
            AnalysisMapGeometry.greatCircleDistanceMeters(from: origin, to: destination) - 1_000
        ) < 0.01)
        #expect(destination.longitude > origin.longitude)
    }

    @Test("solar render model honors ray choices without creating persisted geometry")
    func solarRenderModelBuildsSelectedDirections() throws {
        let instant = try utcDate(2024, 6, 20, 12, 0, 0)
        let origin = AnalysisGeoCoordinate(latitude: 51.4779, longitude: 0)
        let day = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(instant: instant, coordinate: origin),
            civilDayOffsetMinutes: 0
        )
        let overlay = AnalysisSolarOverlayState(
            timestamp: AnalysisTimestampValue(
                date: instant,
                precision: .minute,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            showsShadowDirection: false,
            showsSunsetDirection: false
        )

        let model = try #require(AnalysisSolarMapRenderModel(
            overlay: overlay,
            origin: origin,
            latitudeDelta: 0.2,
            longitudeDelta: 0.2,
            day: day
        ))

        #expect(model.rays.map(\.kind) == [.sun, .sunrise])
        #expect(model.shadowObjectHeightMeters == 1)
        #expect(model.shadowLengthMeters != nil)
        #expect(model.rays.allSatisfy {
            abs(AnalysisMapGeometry.greatCircleDistanceMeters(
                from: $0.origin,
                to: $0.destination
            ) - model.rayLengthMeters) < 0.01
        })
    }

    @Test("below-horizon render model hides current sun and shadow rays")
    func solarRenderModelHidesInactiveCurrentDirections() throws {
        let instant = try utcDate(2024, 6, 20, 0, 0, 0)
        let origin = AnalysisGeoCoordinate(latitude: 51.4779, longitude: 0)
        let day = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(instant: instant, coordinate: origin),
            civilDayOffsetMinutes: 0
        )
        let overlay = AnalysisSolarOverlayState(
            timestamp: AnalysisTimestampValue(
                date: instant,
                precision: .minute,
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        let model = try #require(AnalysisSolarMapRenderModel(
            overlay: overlay,
            origin: origin,
            latitudeDelta: 0.2,
            longitudeDelta: 0.2,
            day: day
        ))

        #expect(model.isBelowHorizon)
        #expect(!model.rays.contains { $0.kind == .sun || $0.kind == .shadow })
        #expect(model.rays.map(\.kind) == [.sunrise, .sunset])
    }

    @Test("Invalid input returns specific errors")
    func invalidInputErrors() throws {
        let instant = try utcDate(2024, 1, 1, 0, 0, 0)
        #expect(throws: AnalysisSolarCalculationError.invalidCoordinate) {
            try AnalysisSolarPositionCalculator.calculate(
                input: AnalysisSolarInput(
                    instant: instant,
                    coordinate: AnalysisGeoCoordinate(latitude: 91, longitude: 0)
                ),
                civilDayOffsetMinutes: 0
            )
        }
        #expect(throws: AnalysisSolarCalculationError.invalidUTCOffset) {
            try AnalysisSolarPositionCalculator.calculate(
                input: AnalysisSolarInput(
                    instant: instant,
                    coordinate: AnalysisGeoCoordinate(latitude: 0, longitude: 0)
                ),
                civilDayOffsetMinutes: 841
            )
        }
        #expect(throws: AnalysisSolarCalculationError.unsupportedYear(1799)) {
            try AnalysisSolarPositionCalculator.calculate(
                input: AnalysisSolarInput(
                    instant: try utcDate(1799, 1, 1, 0, 0, 0),
                    coordinate: AnalysisGeoCoordinate(latitude: 0, longitude: 0)
                ),
                civilDayOffsetMinutes: 0
            )
        }
    }

    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}
