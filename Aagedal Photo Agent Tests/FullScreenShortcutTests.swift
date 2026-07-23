import Testing
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
