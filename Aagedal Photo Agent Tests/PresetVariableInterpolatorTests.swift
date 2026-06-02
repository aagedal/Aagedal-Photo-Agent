import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("PresetVariableInterpolator")
struct PresetVariableInterpolatorTests {
    private let interpolator = PresetVariableInterpolator()

    @Test("{initials} is replaced with the passed value")
    func initialsReplaced() {
        let result = interpolator.resolve("{initials}", initials: "TA")
        #expect(result == "TA")
    }

    @Test("{initials} resolves to empty string when unset")
    func initialsEmptyWhenUnset() {
        let result = interpolator.resolve("{initials}")
        #expect(result == "")
    }

    @Test("{initials} combines with a date format into a single keyword")
    func initialsWithDate() {
        let result = interpolator.resolve("{initials}{date:yyMMdd}", initials: "TA")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        let expected = "TA" + formatter.string(from: Date())
        #expect(result == expected)
    }

    @Test("Existing variables still resolve alongside {initials}")
    func existingVariablesUnaffected() {
        var metadata = IPTCMetadata()
        metadata.city = "Oslo"
        let result = interpolator.resolve("{initials}-{field:city}", existingMetadata: metadata, initials: "TA")
        #expect(result == "TA-Oslo")
    }
}
