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
