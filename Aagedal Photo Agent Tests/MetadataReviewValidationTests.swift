import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Metadata Review validation presentation")
struct MetadataReviewValidationTests {
    private let imageURL = URL(fileURLWithPath: "/fixtures/review.jpg")

    @Test("Required failures keep a visible reason and explicit blocker severity")
    func requiredFailurePresentation() throws {
        let failure = try #require(MetadataReviewValidation.failures(
            for: .headline,
            in: IPTCMetadata(),
            imageURL: imageURL,
            levels: [.headline: .require],
            minimumLengths: [.headline: 10]
        ).first)

        #expect(failure.severity == .blocker)
        #expect(failure.severityName == "Blocker")
        #expect(failure.systemImageName == "xmark.octagon.fill")
        #expect(failure.accessibleDescription == "Blocker: Headline is required.")
    }

    @Test("Warnings expose severity independently of amber color")
    func warningFailurePresentation() throws {
        let failure = try #require(MetadataReviewValidation.failures(
            for: .description,
            in: IPTCMetadata(),
            imageURL: imageURL,
            levels: [.description: .warnOnEmpty],
            minimumLengths: [:]
        ).first)

        #expect(failure.severity == .warning)
        #expect(failure.systemImageName == "exclamationmark.triangle.fill")
        #expect(failure.accessibleDescription == "Warning: Description is required.")
    }

    @Test("Length failures include actionable current-length detail")
    func minimumLengthFailurePresentation() throws {
        let failure = try #require(MetadataReviewValidation.failures(
            for: .headline,
            in: IPTCMetadata(title: "Short"),
            imageURL: imageURL,
            levels: [.headline: .require],
            minimumLengths: [.headline: 10]
        ).first)

        #expect(failure.accessibleDescription == "Blocker: Headline must contain at least 10 characters. Current length: 5.")
    }

    @Test("Valid fields have no persistent failure presentation")
    func validFieldPresentation() {
        let failures = MetadataReviewValidation.failures(
            for: .headline,
            in: IPTCMetadata(title: "Long enough headline"),
            imageURL: imageURL,
            levels: [.headline: .require],
            minimumLengths: [.headline: 10]
        )

        #expect(failures.isEmpty)
    }
}
