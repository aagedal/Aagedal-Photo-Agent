import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("Full-screen culling shortcuts")
struct FullScreenShortcutTests {
    private static let numberKeyCodes = [
        29, // 0
        18, // 1
        19, // 2
        20, // 3
        21, // 4
        23, // 5
        22, // 6
        26, // 7
        28, // 8
        25, // 9
    ]

    @Test("Bare digits map 0–5 to ratings and 6–9 to color labels")
    func bareDigitMappings() {
        for (number, keyCode) in Self.numberKeyCodes.enumerated() {
            let expected: FullScreenNumberShortcut = number <= 5
                ? .rating(number)
                : .colorLabel(number - 5)

            #expect(
                FullScreenNumberShortcut.resolve(
                    keyCode: keyCode,
                    command: false,
                    option: false
                ) == expected
            )
        }
    }

    @Test("Command digit mappings retain the menu shortcuts")
    func modifiedDigitMappings() {
        for (number, keyCode) in Self.numberKeyCodes.enumerated() {
            let rating = FullScreenNumberShortcut.resolve(
                keyCode: keyCode,
                command: true,
                option: false
            )
            #expect(rating == (number <= 5 ? .rating(number) : nil))

            let label = FullScreenNumberShortcut.resolve(
                keyCode: keyCode,
                command: true,
                option: true
            )
            #expect(label == (number <= 8 ? .colorLabel(number) : nil))
        }
    }

    @Test("Option-only digits are not intercepted")
    func optionOnlyDigitsAreIgnored() {
        for keyCode in Self.numberKeyCodes {
            #expect(
                FullScreenNumberShortcut.resolve(
                    keyCode: keyCode,
                    command: false,
                    option: true
                ) == nil
            )
        }
    }

    @Test("Rating stars and color-label choices remain semantic buttons")
    func accessibleRatingAndLabelControls() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/FullScreenImageView.swift"
            ),
            encoding: .utf8
        )

        let ratingOverlay = try #require(source.slice(
            from: "private func starRatingOverlay",
            through: "// MARK: - Presenter"
        ))
        #expect(ratingOverlay.contains("ForEach(1...5"))
        #expect(ratingOverlay.contains("Button {"))
        #expect(!ratingOverlay.contains(".onTapGesture"))
        #expect(ratingOverlay.contains(".accessibilityLabel(\"\\(star) star rating\")"))
        #expect(ratingOverlay.contains(".accessibilityValue("))
        #expect(ratingOverlay.contains(".accessibilityIdentifier(\"fullScreen.rating.\\(star)\")"))

        let labelOverlay = try #require(source.slice(
            from: "private func colorLabelOverlay",
            through: "private func starRatingOverlay"
        ))
        #expect(labelOverlay.contains("ForEach(ColorLabel.allCases"))
        #expect(labelOverlay.contains("Button {"))
        #expect(labelOverlay.contains(".accessibilityLabel(\"\\(label.displayName) color label\")"))
        #expect(labelOverlay.contains(".accessibilityValue("))
        #expect(labelOverlay.contains(".accessibilityIdentifier(\"fullScreen.colorLabel.\\(label.rawValue)\")"))
        #expect(labelOverlay.contains("picker \\(showLabelPicker ? \"expanded\" : \"collapsed\")"))
    }
}

private extension String {
    func slice(from startMarker: String, through endMarker: String) -> String? {
        guard let start = range(of: startMarker),
              let end = range(of: endMarker, range: start.upperBound..<endIndex) else {
            return nil
        }
        return String(self[start.lowerBound..<end.lowerBound])
    }
}

@Suite("Full-screen loading recovery")
struct FullScreenLoadingRecoveryTests {
    @Test("High-resolution speed guidance appears only for edited previews")
    func editedPreviewGuidance() {
        #expect(
            FullScreenLoadingGuidance.message(
                isRenderingEdits: true,
                hasEdits: true
            ) == "Edited previews can take longer. Press E to turn off edits when faster high-resolution loading matters."
        )
        #expect(
            FullScreenLoadingGuidance.message(
                isRenderingEdits: false,
                hasEdits: true
            ) == nil
        )
        #expect(
            FullScreenLoadingGuidance.message(
                isRenderingEdits: true,
                hasEdits: false
            ) == nil
        )
    }

    @Test("Failure details identify the file, path, and preview mode")
    func failureDetails() {
        let url = URL(fileURLWithPath: "/Volumes/Archive/News Photos/frame 001.tiff")

        let editedFailure = FullScreenLoadFailure(url: url, isRenderingEdits: true)
        #expect(editedFailure.message == "Unable to load this image at high resolution.")
        #expect(editedFailure.details.contains("File: frame 001.tiff"))
        #expect(editedFailure.details.contains("Path: /Volumes/Archive/News Photos/frame 001.tiff"))
        #expect(editedFailure.details.contains("Preview mode: Edited"))

        let originalFailure = FullScreenLoadFailure(url: url, isRenderingEdits: false)
        #expect(originalFailure.details.contains("Preview mode: Original"))
    }
}
