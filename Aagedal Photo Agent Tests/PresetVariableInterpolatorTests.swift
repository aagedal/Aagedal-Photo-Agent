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

    @Test("{field:…} expands variables inside the referenced field")
    func fieldReferenceExpandsNestedVariable() {
        var metadata = IPTCMetadata()
        metadata.event = "{date:yyyy}"
        let result = interpolator.resolve("{field:event}", existingMetadata: metadata)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        #expect(result == formatter.string(from: Date()))
    }

    @Test("{field:…} chains through nested field references")
    func fieldReferenceChains() {
        var metadata = IPTCMetadata()
        metadata.title = "{field:city}"
        metadata.city = "Bergen"
        let result = interpolator.resolve("{field:title}", existingMetadata: metadata)
        #expect(result == "Bergen")
    }

    @Test("A {field:…} reference cycle terminates instead of looping")
    func fieldReferenceCycleTerminates() {
        var metadata = IPTCMetadata()
        metadata.title = "{field:event}"
        metadata.event = "{field:title}"
        // Must terminate; the cycle is broken and an unresolvable token remains.
        let result = interpolator.resolve("{field:title}", existingMetadata: metadata)
        #expect(result.contains("{field:"))
    }

    @Test("Sibling {field:…} references both resolve (cycle guard is per-chain)")
    func siblingFieldReferencesBothResolve() {
        var metadata = IPTCMetadata()
        metadata.city = "Oslo"
        let result = interpolator.resolve("{field:city}/{field:city}", existingMetadata: metadata)
        #expect(result == "Oslo/Oslo")
    }
}
