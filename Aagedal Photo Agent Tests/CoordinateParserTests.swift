import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("CoordinateParser")
struct CoordinateParserTests {

    // MARK: - Crash hardening

    /// A crafted/corrupt EXIF GPS field can surface a non-finite or out-of-range
    /// coordinate. The DMS/DDM formatters convert with `Int(_:)`, which traps on
    /// inf/nan/out-of-range, so `format` must reject these before converting.
    @Test("Non-finite coordinates do not trap and return a placeholder",
          arguments: [Double.nan, .infinity, -.infinity, 1e300, -1e300])
    func nonFiniteCoordinatesAreSafe(_ bad: Double) {
        for format in CoordinateFormat.allCases {
            #expect(CoordinateParser.format(latitude: bad, longitude: 10.0, format: format) == "—")
            #expect(CoordinateParser.format(latitude: 59.0, longitude: bad, format: format) == "—")
            #expect(CoordinateParser.format(latitude: bad, longitude: bad, format: format) == "—")
        }
    }

    @Test("Out-of-range but finite coordinates return a placeholder")
    func outOfRangeCoordinatesAreRejected() {
        for format in CoordinateFormat.allCases {
            #expect(CoordinateParser.format(latitude: 91.0, longitude: 10.0, format: format) == "—")
            #expect(CoordinateParser.format(latitude: 59.0, longitude: 181.0, format: format) == "—")
            #expect(CoordinateParser.format(latitude: -90.5, longitude: 10.0, format: format) == "—")
        }
    }

    // MARK: - Valid formatting

    @Test("Decimal degrees formatting")
    func decimalDegrees() {
        let text = CoordinateParser.format(latitude: 59.9139, longitude: 10.7522, format: .decimalDegrees)
        #expect(text == "59.913900, 10.752200")
    }

    @Test("DMS formatting produces hemisphere suffixes")
    func degreesMinutesSeconds() {
        let text = CoordinateParser.format(latitude: 59.9139, longitude: 10.7522, format: .degreesMinutesSeconds)
        #expect(text.contains("N"))
        #expect(text.contains("E"))
        #expect(text.hasPrefix("59°"))
    }

    @Test("Southern/western coordinates format with S/W")
    func southWestHemisphere() {
        let text = CoordinateParser.format(latitude: -33.8688, longitude: 151.2093, format: .degreesMinutesSeconds)
        #expect(text.contains("S"))
        #expect(text.contains("E"))
    }

    @Test("Boundary coordinates are valid and format")
    func boundaryCoordinates() {
        #expect(CoordinateParser.format(latitude: 90.0, longitude: 180.0, format: .decimalDegrees) != "—")
        #expect(CoordinateParser.format(latitude: -90.0, longitude: -180.0, format: .decimalDegrees) != "—")
        #expect(CoordinateParser.format(latitude: 0.0, longitude: 0.0, format: .degreesDecimalMinutes) != "—")
    }

    // MARK: - Parsing round-trip

    @Test("Parsing rejects non-finite-looking out-of-range input")
    func parseRejectsOutOfRange() {
        #expect(CoordinateParser.parse("199.0, 10.0") == nil)
    }

    @Test("Parsing decimal degrees")
    func parseDecimalDegrees() {
        let result = CoordinateParser.parse("59.9139, 10.7522")
        #expect(result?.latitude == 59.9139)
        #expect(result?.longitude == 10.7522)
    }
}
