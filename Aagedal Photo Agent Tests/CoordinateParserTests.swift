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

    // MARK: - Hemisphere placement and decimal commas

    @Test("Leading hemisphere letters stay with their own component")
    func leadingHemisphereLetters() throws {
        let newYork = try #require(CoordinateParser.parse("N 40°41'21\" W 74°2'40\""))
        #expect(abs(newYork.latitude - 40.689167) < 0.0001)
        #expect(abs(newYork.longitude + 74.044444) < 0.0001)
        let sydney = try #require(CoordinateParser.parse("S 33°52.0' E 151°12.0'"))
        #expect(abs(sydney.latitude + 33.866667) < 0.0001)
        #expect(abs(sydney.longitude - 151.2) < 0.0001)
        let oslo = try #require(CoordinateParser.parse("59°54'50.0\"N 10°45'7.9\"E"))
        #expect(oslo.latitude > 59.9 && oslo.longitude > 10.7)
        let lima = try #require(CoordinateParser.parse("12°2.6'S 77°1.7'W"))
        #expect(lima.latitude < 0 && lima.longitude < 0)
    }

    @Test("Decimal-comma coordinates parse and a bare decimal comma is refused")
    func decimalCommaCoordinates() throws {
        let pair = try #require(CoordinateParser.parse("59,9139 10,7522"))
        #expect(abs(pair.latitude - 59.9139) < 0.00001)
        #expect(abs(pair.longitude - 10.7522) < 0.00001)
        let semicolon = try #require(CoordinateParser.parse("59,9139; 10,7522"))
        #expect(abs(semicolon.longitude - 10.7522) < 0.00001)
        #expect(CoordinateParser.parse("59,91") == nil)
        let noSpace = try #require(CoordinateParser.parse("59.91,10.75"))
        #expect(noSpace.latitude == 59.91 && noSpace.longitude == 10.75)
        let wholeDegrees = try #require(CoordinateParser.parse("59, 10"))
        #expect(wholeDegrees.latitude == 59 && wholeDegrees.longitude == 10)
    }

    @Test("Seconds and minutes that round up carry instead of printing 60")
    func roundingCarries() {
        // 59° 54' 59.96" N rounds to 59° 55' 0.0".
        let latitude = 59 + 54.0 / 60 + 59.96 / 3600
        let dms = CoordinateParser.format(latitude: latitude, longitude: 10, format: .degreesMinutesSeconds)
        #expect(dms.hasPrefix("59°55'0.0\"N"))
        let ddm = CoordinateParser.format(latitude: 59.99999999, longitude: 10, format: .degreesDecimalMinutes)
        #expect(ddm.hasPrefix("60°0.000'N"))
    }
}
