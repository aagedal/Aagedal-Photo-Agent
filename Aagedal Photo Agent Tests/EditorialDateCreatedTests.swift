import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Editorial Date Created")
struct EditorialDateCreatedTests {
    struct AcceptedCase: Sendable {
        let lexical: String
        let canonical: String
        let precision: EditorialDateCreated.Precision
        let timeZone: EditorialDateCreated.TimeZoneSemantics
    }

    private nonisolated static let accepted: [AcceptedCase] = [
        .init(lexical: "2026", canonical: "2026", precision: .year, timeZone: .absent),
        .init(lexical: "2026-08", canonical: "2026-08", precision: .month, timeZone: .absent),
        .init(lexical: "2024-02-29", canonical: "2024-02-29", precision: .day, timeZone: .absent),
        .init(lexical: "2026-08-21 10:15", canonical: "2026-08-21T10:15", precision: .minute, timeZone: .unknown),
        .init(lexical: "2026-08-21T10:15:30", canonical: "2026-08-21T10:15:30", precision: .second, timeZone: .unknown),
        .init(lexical: "2026-08-21t10:15:30.1200z", canonical: "2026-08-21T10:15:30.1200Z", precision: .fractionalSecond, timeZone: .offsetMinutes(0)),
        .init(lexical: "2026-08-21T10:15Z", canonical: "2026-08-21T10:15Z", precision: .minute, timeZone: .offsetMinutes(0)),
        .init(lexical: "2026-08-21T10:15:30+0530", canonical: "2026-08-21T10:15:30+05:30", precision: .second, timeZone: .offsetMinutes(330)),
        .init(lexical: "2026-08-21T10:15:30-02:30", canonical: "2026-08-21T10:15:30-02:30", precision: .second, timeZone: .offsetMinutes(-150)),
        .init(lexical: "2026-08-21T10:15:30-00:00", canonical: "2026-08-21T10:15:30-00:00", precision: .second, timeZone: .unknown),
        .init(lexical: "2026-08-21T10:15:30+14:00", canonical: "2026-08-21T10:15:30+14:00", precision: .second, timeZone: .offsetMinutes(840)),
    ]

    @Test("accepted ISO 8601 forms preserve exact spelling and expose canonical facts", arguments: accepted)
    func acceptedForms(testCase: AcceptedCase) throws {
        let value = try EditorialDateCreated(parsing: testCase.lexical)

        #expect(value.lexicalValue == testCase.lexical)
        #expect(value.canonicalLexicalValue == testCase.canonical)
        #expect(value.precision == testCase.precision)
        #expect(value.timeZone == testCase.timeZone)
        #expect(value.isTimeZoneKnown == testCase.timeZone.isKnown)
        #expect(value.timeZoneOffsetMinutes == testCase.timeZone.offsetMinutes)
    }

    private nonisolated static let rejected = [
        "",
        " 2026-08-21",
        "2026-08-21 ",
        "0000-01-01",
        "2026-00",
        "2026-13",
        "2025-02-29",
        "2026-04-31",
        "2026-08-21T24:00",
        "2026-08-21T10:60",
        "2026-08-21T10:15:60",
        "2026-08-21T10:15:30.",
        "2026-08-21T10:15:30.1234567890Z",
        "2026-08-21T10:15:30+14:01",
        "2026-08-21T10:15:30+15:00",
        "20260821",
    ]

    @Test("invalid and ambiguous forms fail closed", arguments: rejected)
    func rejectedForms(lexical: String) {
        #expect(throws: EditorialDateCreated.ParseError.self) {
            try EditorialDateCreated.parse(lexical)
        }
    }

    @Test("Codable round-trip retains the exact lexical form")
    func codableRoundTrip() throws {
        let value = try EditorialDateCreated(parsing: "2026-08-21t10:15:30.1200+0530")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(EditorialDateCreated.self, from: data)

        #expect(decoded == value)
        #expect(decoded.lexicalValue == "2026-08-21t10:15:30.1200+0530")
        #expect(decoded.canonicalLexicalValue == "2026-08-21T10:15:30.1200+05:30")
    }

    @Test("Codable rejects invalid persisted lexical data")
    func codableRejectsInvalidData() {
        let data = Data(#"{"lexicalValue":"2026-02-30"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditorialDateCreated.self, from: data)
        }
    }

    @Test("exact equality does not erase spelling precision or timezone evidence")
    func exactEquality() throws {
        let utc = try EditorialDateCreated(parsing: "2026-08-21T10:15:30Z")
        let equivalentOffset = try EditorialDateCreated(parsing: "2026-08-21T12:15:30+02:00")
        let lessPrecise = try EditorialDateCreated(parsing: "2026-08-21T10:15Z")
        let unknownZone = try EditorialDateCreated(parsing: "2026-08-21T10:15:30")

        #expect(utc != equivalentOffset)
        #expect(utc != lessPrecise)
        #expect(utc != unknownZone)
        #expect(utc.isTimeZoneKnown)
        #expect(!unknownZone.isTimeZoneKnown)
    }

    @Test("the public value is statically Sendable")
    func sendableConformance() throws {
        let value = try EditorialDateCreated(parsing: "2026-08-21")
        requireSendable(value)
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
