import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Caption Copy Previous")
struct CaptionCopyPreviousServiceTests {
    private let service = CaptionCopyPreviousService()

    @Test("Default selection copies only caption, headline, persons, and keywords")
    func defaultSelectionIsNarrow() {
        let previous = IPTCMetadata(
            title: "Previous headline",
            description: "Previous caption",
            keywords: ["news"],
            personShown: ["Ada Lovelace"],
            creator: "Must not copy by default",
            dateCreated: "2026-08-20T10:15:00+02:00"
        )
        let current = IPTCMetadata(title: "Current", creator: "Current creator")

        let result = service.copy(previous: previous, current: current)

        #expect(result.status == .completed)
        #expect(Set(result.appliedFields) == CaptionCopyPreviousField.defaultSelection)
        #expect(result.metadata?.title == "Previous headline")
        #expect(result.metadata?.description == "Previous caption")
        #expect(result.metadata?.keywords == ["news"])
        #expect(result.metadata?.personShown == ["Ada Lovelace"])
        #expect(result.metadata?.creator == "Current creator")
        #expect(result.metadata?.dateCreated == nil)
    }

    @Test("Capture-specific fields remain protected even when selected and allowlisted")
    func protectedFieldsCannotBeOverwritten() {
        var previous = IPTCMetadata(
            latitude: 59.91,
            longitude: 10.75,
            digitalImageGUID: "previous-guid",
            imageSupplierImageID: "previous-supplier-id",
            dateCreated: "2026-08-20T10:15:00+02:00",
            captureDate: "2026-08-20T10:14:59+02:00",
            city: "Previous city",
            sublocation: "Previous sublocation",
            provinceState: "Previous region",
            country: "Previous country",
            countryCode: "NOR",
            rating: 5,
            label: "Red",
            exifOrientation: 8
        )
        previous.locationsCreated = [EditorialLocation(name: "Previous capture location")]
        previous.cameraRaw = CameraRawSettings()

        var current = IPTCMetadata(
            latitude: 60.0,
            longitude: 11.0,
            digitalImageGUID: "current-guid",
            imageSupplierImageID: "current-supplier-id",
            dateCreated: "2026-08-21T09:00:00+02:00",
            captureDate: "2026-08-21T08:59:59+02:00",
            city: "Current city",
            rating: 1,
            label: "Blue",
            exifOrientation: 1
        )
        current.locationsCreated = [EditorialLocation(name: "Current capture location")]
        let currentSnapshot = current
        let previousSnapshot = previous
        let protected = CaptionCopyPreviousField.protectedFields
        let configuration = CaptionCopyPreviousConfiguration(
            selectedFields: protected,
            allowedFields: protected,
            defaultMode: .replace
        )

        let result = service.copy(previous: previous, current: current, configuration: configuration)

        #expect(result.metadata == currentSnapshot)
        #expect(previous == previousSnapshot)
        #expect(Set(result.protectedFields) == protected)
        #expect(result.fields.allSatisfy {
            $0.disposition == CaptionCopyPreviousDisposition.protected
        })
        #expect(!result.changed)
    }

    @Test("Append preserves current list order and deduplicates repeated values")
    func appendLists() {
        let previous = IPTCMetadata(
            keywords: ["sport", "night", "night", "final"],
            personShown: ["Ada", "Grace", "Grace"]
        )
        let current = IPTCMetadata(
            keywords: ["breaking", "sport"],
            personShown: ["Lin", "Ada"]
        )
        let configuration = CaptionCopyPreviousConfiguration(
            selectedFields: [.keywords, .persons],
            defaultMode: .append
        )

        let result = service.copy(previous: previous, current: current, configuration: configuration)

        #expect(result.metadata?.keywords == ["breaking", "sport", "night", "final"])
        #expect(result.metadata?.personShown == ["Lin", "Ada", "Grace"])
        #expect(result.appliedFields == [.keywords, .persons])
    }

    @Test("Replace normalizes duplicate source list entries without changing source")
    func replaceLists() {
        let previous = IPTCMetadata(keywords: ["one", "one", "two"], personShown: ["A", "A"])
        let previousSnapshot = previous
        let current = IPTCMetadata(keywords: ["old"], personShown: ["Old"])
        let configuration = CaptionCopyPreviousConfiguration(
            selectedFields: [.keywords, .persons],
            defaultMode: .replace
        )

        let result = service.copy(previous: previous, current: current, configuration: configuration)

        #expect(result.metadata?.keywords == ["one", "two"])
        #expect(result.metadata?.personShown == ["A"])
        #expect(previous == previousSnapshot)
    }

    @Test("Scalar replace and append modes are selected per field")
    func scalarModes() {
        let previous = IPTCMetadata(title: "Source headline", description: "Source caption")
        let current = IPTCMetadata(title: "Current headline", description: "Current caption")
        let configuration = CaptionCopyPreviousConfiguration(
            selectedFields: [.headline, .caption],
            defaultMode: .replace,
            modeByField: [.caption: .append],
            scalarAppendSeparator: " | "
        )

        let result = service.copy(previous: previous, current: current, configuration: configuration)

        #expect(result.metadata?.title == "Source headline")
        #expect(result.metadata?.description == "Current caption | Source caption")
    }

    @Test("Allowlist rejects a selected but unapproved field")
    func allowlistIsEnforced() {
        let previous = IPTCMetadata(description: "Caption", keywords: ["news"])
        let current = IPTCMetadata(description: "Current", keywords: ["current"])
        let configuration = CaptionCopyPreviousConfiguration(
            selectedFields: [.caption, .keywords],
            allowedFields: [.caption]
        )

        let result = service.copy(previous: previous, current: current, configuration: configuration)

        #expect(result.metadata?.description == "Caption")
        #expect(result.metadata?.keywords == ["current"])
        #expect(result.fields.first { $0.field == .keywords }?.disposition == .skippedNotAllowed)
    }

    @Test("Empty source values are skipped instead of clearing current data")
    func missingFieldValueIsSkipped() {
        let previous = IPTCMetadata(description: "   ", keywords: [])
        let current = IPTCMetadata(description: "Keep", keywords: ["keep"])

        let result = service.copy(previous: previous, current: current)

        #expect(result.metadata?.description == "Keep")
        #expect(result.metadata?.keywords == ["keep"])
        #expect(result.fields.first { $0.field == .caption }?.disposition == .skippedNoSourceValue)
        #expect(result.fields.first { $0.field == .keywords }?.disposition == .skippedNoSourceValue)
    }

    @Test("Missing previous and current records return structured non-mutating results")
    func missingRecords() {
        let current = IPTCMetadata(title: "Keep")
        let missingPrevious = service.copy(previous: nil, current: current)
        #expect(missingPrevious.status == .missingPrevious)
        #expect(missingPrevious.metadata == current)
        #expect(missingPrevious.fields.allSatisfy { $0.disposition == .missingPrevious })

        let missingCurrent = service.copy(previous: IPTCMetadata(title: "Previous"), current: nil)
        #expect(missingCurrent.status == .missingCurrent)
        #expect(missingCurrent.metadata == nil)
        #expect(missingCurrent.fields.allSatisfy { $0.disposition == .missingCurrent })
    }
}
