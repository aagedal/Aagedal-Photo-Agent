import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Metadata editing history")
struct MetadataHistoryTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("legacy entries decode with stable identity and remain replayable")
    func legacyEntryMigration() throws {
        let data = Data(
            #"{"timestamp":"2023-11-14T22:13:20Z","fieldName":"Title","oldValue":"Before","newValue":"After"}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(MetadataHistoryEntry.self, from: data)

        #expect(entry.fieldID == .headline)
        #expect(entry.displayName == "Headline")
        #expect(entry.valueStorage == .exact)
        #expect(entry.isRestorable)

        var metadata = IPTCMetadata(title: "Before")
        #expect(entry.apply(to: &metadata))
        #expect(metadata.title == "After")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let migrated = try encoder.encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["fieldID"] as? String == MetadataFieldID.headline.rawValue)
        #expect(object["valueStorage"] as? String == MetadataHistoryValueStorage.exact.rawValue)
    }

    @Test("controlled values use labels while retaining canonical replay values")
    func controlledValueLabels() {
        let source = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldID: .digitalSourceType,
            oldValue: nil,
            newValue: DigitalSourceType.trainedAlgorithmicMedia.newsCodeURI
        )
        #expect(source.displayNewValue == "Created Using Generative AI")
        #expect(source.newValue == DigitalSourceType.trainedAlgorithmicMedia.newsCodeURI)

        let scene = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldID: .sceneCode,
            oldValue: nil,
            newValue: "010100, 011900"
        )
        #expect(scene.displayNewValue == "010100 — Headshot, 011900 — Action")

        let urgency = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldID: .urgency,
            oldValue: "8",
            newValue: "1"
        )
        #expect(urgency.displayOldValue == "8 — Least urgent")
        #expect(urgency.displayNewValue == "1 — Most urgent")

        let country = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldID: .countryCode,
            oldValue: nil,
            newValue: "NOR"
        )
        #expect(country.displayNewValue?.hasPrefix("NOR — ") == true)
    }

    @Test("long and identifying values are not persisted in history")
    func summariesAndRedaction() throws {
        let caption = String(repeating: "private-caption-", count: 20)
        let previous = IPTCMetadata()
        let edited = IPTCMetadata(
            description: caption,
            latitude: 59.9,
            longitude: 10.7,
            digitalImageGUID: "confidential-guid-123",
            creatorContactInfo: CreatorContactInfo(
                addressLines: ["10 Private Street"],
                emails: ["private@example.test"]
            ),
            locationsShown: [EditorialLocation(name: "Protected location", latitude: 59.9, longitude: 10.7)]
        )

        let entries = MetadataHistoryEntry.changes(from: previous, to: edited, timestamp: timestamp)
        let captionEntry = try #require(entries.first { $0.fieldID == .description })
        #expect(captionEntry.valueStorage == .summarized)
        #expect(captionEntry.displayNewValue == "320 characters")
        #expect(!captionEntry.isRestorable)

        let guidEntry = try #require(entries.first { $0.fieldID == .digitalImageGUID })
        #expect(guidEntry.valueStorage == .redacted)
        #expect(guidEntry.displayNewValue == "Present (value hidden)")
        #expect(entries.contains { $0.displayName == "Creator Contact Information" })
        #expect(entries.contains { $0.displayName == "Location Shown" })
        #expect(entries.contains { $0.displayName == "GPS Coordinates" })

        let encoded = try JSONEncoder().encode(entries)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains(caption))
        #expect(!json.contains("confidential-guid-123"))
        #expect(!json.contains("private@example.test"))
        #expect(!json.contains("Protected location"))
        #expect(!json.contains("59.9"))
    }

    @Test("all current metadata groups produce history entries")
    func currentFieldCoverage() {
        let edited = IPTCMetadata(
            title: "Headline",
            urgency: 2,
            sceneCodes: ["010100"],
            captureDate: "2026-08-21T10:00:00Z",
            sublocation: "Newsroom",
            provinceState: "Oslo",
            event: "Election",
            instructions: "Internal handling instructions",
            source: "Wire",
            creatorContactInfo: CreatorContactInfo(city: "Oslo"),
            locationsCreated: [EditorialLocation(name: "City Hall")],
            locationsShown: [EditorialLocation(name: "Harbor")],
            rating: 4,
            label: "Approved"
        )

        let entries = MetadataHistoryEntry.changes(
            from: IPTCMetadata(),
            to: edited,
            timestamp: timestamp
        )

        let fieldIDs = Set(entries.compactMap(\.fieldID))
        #expect(fieldIDs.isSuperset(of: [
            .headline, .urgency, .sceneCode, .sublocation, .provinceState,
            .event, .instructions, .source,
        ]))
        let names = Set(entries.map(\.displayName))
        #expect(names.isSuperset(of: [
            "Capture Date", "Rating", "Label", "Creator Contact Information",
            "Location Created", "Location Shown",
        ]))
    }

    @Test("non-exact entries refuse partial restoration")
    func unsafeRestoreIsRejected() {
        let entry = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldID: .description,
            oldValue: "Before",
            newValue: "After"
        )
        var metadata = IPTCMetadata(description: "Current")

        #expect(!entry.apply(to: &metadata))
        #expect(metadata.description == "Current")
    }

    @Test("repeatable values containing commas restore losslessly")
    func commaInRepeatableValueRoundTrips() throws {
        let previous = IPTCMetadata(keywords: ["before"])
        let edited = IPTCMetadata(keywords: ["Oslo, Norway", "news"])
        let entry = try #require(MetadataHistoryEntry.changes(
            from: previous,
            to: edited,
            timestamp: timestamp
        ).first { $0.fieldID == .keywords })

        #expect(entry.newValue == #"["Oslo, Norway","news"]"#)
        #expect(entry.displayNewValue == "Oslo, Norway, news")

        var restored = previous
        #expect(entry.apply(to: &restored))
        #expect(restored.keywords == ["Oslo, Norway", "news"])

        let migrated = try JSONDecoder().decode(
            MetadataHistoryEntry.self,
            from: JSONEncoder().encode(entry)
        )
        var decodedRestore = previous
        #expect(migrated.apply(to: &decodedRestore))
        #expect(decodedRestore.keywords == ["Oslo, Norway", "news"])

        let legacy = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldName: "Keywords",
            oldValue: "before",
            newValue: "one, two"
        )
        var legacyRestore = previous
        #expect(legacy.apply(to: &legacyRestore))
        #expect(legacyRestore.keywords == ["one", "two"])
    }

    @Test("unknown legacy events fail closed")
    func unknownLegacyRestoreIsRejected() {
        let entry = MetadataHistoryEntry(
            timestamp: timestamp,
            fieldName: "Unknown future event",
            oldValue: nil,
            newValue: "ignored"
        )
        var metadata = IPTCMetadata(title: "Unchanged")

        #expect(!entry.apply(to: &metadata))
        #expect(metadata.title == "Unchanged")
    }
}
