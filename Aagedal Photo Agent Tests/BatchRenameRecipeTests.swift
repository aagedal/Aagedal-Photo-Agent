import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Batch rename recipe engine")
struct BatchRenameRecipeTests {
    private let renderer = BatchRenameRecipeRenderer()

    @Test("Original-filename metadata is opt-in and legacy recipes remain off")
    func originalFilenameMetadataMigration() throws {
        let optedIn = BatchRenameRecipe(
            name: "Preserve",
            components: [.literal("renamed.jpg")],
            originalFilenameMetadata: .preserveInXMP
        )
        let roundTrip = try JSONDecoder().decode(
            BatchRenameRecipe.self,
            from: JSONEncoder().encode(optedIn)
        )
        #expect(roundTrip.originalFilenameMetadata == .preserveInXMP)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(optedIn)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "originalFilenameMetadata")
        let legacy = try JSONDecoder().decode(
            BatchRenameRecipe.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacy.originalFilenameMetadata == .doNotWrite)
    }

    @Test("Components resolve original name parts and configured sequence")
    func componentsAndSequence() {
        let recipe = BatchRenameRecipe(
            name: "Contact sheet",
            components: [
                .token(.originalStem),
                .literal("-"),
                .token(.sequence(BatchRenameSequence(start: 10, step: 5, padding: 4))),
                .literal("."),
                .token(.originalExtension),
            ],
            sanitization: .disabled
        )

        let result = renderer.evaluate(
            recipe,
            context: BatchRenameContext(originalFilename: "press.day.NEF", sequenceIndex: 2)
        )

        #expect(result.disposition == .rename)
        #expect(result.proposedFilename == "press.day-0020.NEF")
        #expect(result.missingValues.isEmpty)
    }

    @Test("Negative sequences retain their sign outside zero padding")
    func negativeSequencePadding() {
        let recipe = BatchRenameRecipe(
            name: "Countdown",
            components: [.token(.sequence(BatchRenameSequence(start: 1, step: -2, padding: 3)))],
            sanitization: .disabled
        )

        let result = renderer.evaluate(
            recipe,
            context: BatchRenameContext(originalFilename: "a.jpg", sequenceIndex: 2)
        )

        #expect(result.proposedFilename == "-003")
    }

    @Test("Date tokens use POSIX formatting, explicit timezone, aliases, and capture fallback")
    func deterministicDatesAndFallback() {
        let instant = Date(timeIntervalSince1970: 0)
        let recipe = BatchRenameRecipe(
            name: "Dates",
            components: [
                .token(.date(BatchRenameDateToken(
                    source: .capture(fallback: .fileModification),
                    format: "YYYYMMDD-HHmm"
                ))),
            ],
            sanitization: .disabled,
            timeZoneIdentifier: "Europe/Oslo"
        )

        let result = renderer.evaluate(
            recipe,
            context: BatchRenameContext(
                originalFilename: "a.jpg",
                fileModificationDate: instant
            )
        )

        #expect(result.proposedFilename == "19700101-0100")
    }

    @Test("Metadata, job title, and import title are independent typed tokens")
    func metadataAndWorkflowTitles() {
        let recipe = BatchRenameRecipe(
            name: "Desk",
            components: [
                .token(.metadata(.creator)), .literal("_"),
                .token(.metadata(.jobID)), .literal("_"),
                .token(.metadata(.cameraModel)), .literal("_"),
                .token(.metadata(.rating)), .literal("_"),
                .token(.metadata(.colorLabel)), .literal("_"),
                .token(.jobTitle), .literal("_"), .token(.importTitle),
            ],
            sanitization: .disabled
        )
        let context = BatchRenameContext(
            originalFilename: "a.nef",
            metadata: [
                .creator: "A. Reporter",
                .jobID: "JOB-7",
                .cameraModel: "Z 9",
                .rating: "5",
                .colorLabel: "Red",
            ],
            jobTitle: "Finals",
            importTitle: "Card A"
        )

        let result = renderer.evaluate(recipe, context: context)

        #expect(result.proposedFilename == "A. Reporter_JOB-7_Z 9_5_Red_Finals_Card A")
    }

    @Test("Every missing-value policy has an explicit preview outcome")
    func missingValuePolicies() {
        let components: [BatchRenameComponent] = [
            .token(.originalStem), .literal("-"), .token(.metadata(.event)),
        ]
        let context = BatchRenameContext(originalFilename: "original.jpg")

        let empty = renderer.evaluate(
            BatchRenameRecipe(
                name: "Empty",
                components: components,
                sanitization: .disabled,
                missingValuePolicy: .empty
            ),
            context: context
        )
        #expect(empty.disposition == .rename)
        #expect(empty.proposedFilename == "original-")
        #expect(empty.missingValues == [
            BatchRenameMissingValue(componentIndex: 2, token: .metadata(.event)),
        ])

        let fallback = renderer.evaluate(
            BatchRenameRecipe(
                name: "Fallback",
                components: components,
                sanitization: .disabled,
                missingValuePolicy: .fallback("unknown")
            ),
            context: context
        )
        #expect(fallback.disposition == .rename)
        #expect(fallback.proposedFilename == "original-unknown")

        let preserved = renderer.evaluate(
            BatchRenameRecipe(
                name: "Preserve",
                components: components,
                missingValuePolicy: .preserveOriginal
            ),
            context: context
        )
        #expect(preserved.disposition == .preserveOriginal)
        #expect(preserved.proposedFilename == "original.jpg")

        let skipped = renderer.evaluate(
            BatchRenameRecipe(
                name: "Skip",
                components: components,
                missingValuePolicy: .skip
            ),
            context: context
        )
        #expect(skipped.disposition == .skip)
        #expect(skipped.proposedFilename == nil)

        let blocked = renderer.evaluate(
            BatchRenameRecipe(
                name: "Block",
                components: components,
                missingValuePolicy: .block
            ),
            context: context
        )
        #expect(blocked.disposition == .block)
        #expect(blocked.proposedFilename == nil)
        #expect(blocked.problems.isEmpty)
    }

    @Test("Literal and regular-expression substitutions run in declared order")
    func orderedSubstitutions() {
        let recipe = BatchRenameRecipe(
            name: "Ordered replacements",
            components: [.literal("IMG-12-IMG")],
            substitutions: [
                .literal(find: "IMG", replacement: "photo", caseSensitive: true),
                .regularExpression(
                    pattern: #"photo-(\d+)-photo"#,
                    replacement: "frame-$1",
                    caseInsensitive: false,
                    anchorsMatchLines: false
                ),
                .literal(find: "frame", replacement: "asset", caseSensitive: true),
            ],
            sanitization: .disabled
        )

        let result = renderer.evaluate(recipe, context: BatchRenameContext(originalFilename: "a.jpg"))

        #expect(result.proposedFilename == "asset-12")
    }

    @Test("Invalid regular expressions block evaluation with their stage index")
    func invalidRegularExpression() {
        let recipe = BatchRenameRecipe(
            name: "Invalid",
            components: [.literal("photo")],
            substitutions: [
                .literal(find: "x", replacement: "y"),
                .regularExpression(pattern: "(", replacement: ""),
            ]
        )

        let result = renderer.evaluate(recipe, context: BatchRenameContext(originalFilename: "a.jpg"))

        #expect(result.disposition == .block)
        #expect(result.proposedFilename == nil)
        #expect(result.problems == [.invalidRegularExpression(stageIndex: 1, pattern: "(")])
    }

    @Test("Case, whitespace, sanitation, and Unicode normalization have a fixed pipeline")
    func textTransformPipeline() {
        let decomposed = "Cafe\u{301}  /  FINAL\tFile?.JPG"
        let recipe = BatchRenameRecipe(
            name: "Web",
            components: [.literal(decomposed)],
            caseConversion: .lowercase,
            whitespace: .replace(with: "-", collapseRuns: true),
            sanitization: .filesystemSafe(replacement: "_"),
            unicodeNormalization: .canonicalComposed
        )

        let result = renderer.evaluate(recipe, context: BatchRenameContext(originalFilename: "a.jpg"))

        #expect(result.proposedFilename == "café-_-final-file_.jpg")
        #expect(result.proposedFilename?.unicodeScalars.contains("\u{301}") == false)
    }

    @Test("Sanitation handles hidden names, unsafe replacements, controls, and empty results")
    func filesystemSanitizationEdgeCases() {
        let hiddenAllowed = BatchRenameRecipe(
            name: "Hidden",
            components: [.literal(".press")],
            sanitization: .filesystemSafe(allowHiddenFiles: true)
        )
        #expect(renderer.evaluate(
            hiddenAllowed,
            context: BatchRenameContext(originalFilename: "a.jpg")
        ).proposedFilename == ".press")

        let safe = BatchRenameRecipe(
            name: "Safe",
            components: [.literal(" /\u{0}: ")],
            sanitization: .filesystemSafe(replacement: "/", emptyFilenameFallback: "fallback/name")
        )
        #expect(renderer.evaluate(
            safe,
            context: BatchRenameContext(originalFilename: "a.jpg")
        ).proposedFilename == "_")
    }

    @Test("Case conversion is locale-independent")
    func localeIndependentCaseConversion() {
        let recipe = BatchRenameRecipe(
            name: "Invariant case",
            components: [.literal("iı")],
            caseConversion: .uppercase,
            sanitization: .disabled
        )

        let result = renderer.evaluate(recipe, context: BatchRenameContext(originalFilename: "a.jpg"))

        #expect(result.proposedFilename == "II")
    }

    @Test("Recipes round-trip through Codable and reject unknown schema versions")
    func codableVersioning() throws {
        let recipe = BatchRenameRecipe(
            name: "Archive",
            components: [
                .token(.date(BatchRenameDateToken(source: .capture(fallback: .fileCreation)))),
                .literal("-"),
                .token(.metadata(.countryCode)),
            ],
            substitutions: [.literal(find: "NO", replacement: "NOR", caseSensitive: false)],
            caseConversion: .titleCase,
            whitespace: .replace(with: "_", collapseRuns: false),
            sanitization: .filesystemSafe(replacement: "-", allowHiddenFiles: true),
            missingValuePolicy: .fallback("missing"),
            unicodeNormalization: .compatibilityComposed,
            timeZoneIdentifier: "Europe/Oslo"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(recipe)
        let decoded = try JSONDecoder().decode(BatchRenameRecipe.self, from: data)

        #expect(decoded == recipe)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BatchRenameRecipe.self, from: futureData)
        }
    }
}
