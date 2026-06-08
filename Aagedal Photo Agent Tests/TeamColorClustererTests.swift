import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("TeamColorClusterer")
struct TeamColorClustererTests {

    /// Two clearly separated kit colours (white vs red) cluster correctly and map
    /// each cluster to the right configured kit.
    @Test("Separates two distinct kit colours and maps to sides")
    func separatesTwoKits() throws {
        let clusterer = TeamColorClusterer()
        let white = ColorRGB(r: 0.95, g: 0.95, b: 0.95)
        let red = ColorRGB(r: 0.82, g: 0.10, b: 0.12)

        // A handful of noisy samples around each kit.
        var colors: [ColorRGB] = []
        for d in stride(from: -0.03, through: 0.03, by: 0.015) {
            colors.append(ColorRGB(r: white.r + d, g: white.g - d, b: white.b))
            colors.append(ColorRGB(r: red.r - d, g: red.g + d, b: red.b + d))
        }

        let result = try #require(clusterer.cluster(colors: colors, homeKit: white, awayKit: red))

        // Home cluster should be near white, away near red.
        #expect(result.homeCentroid.r > 0.7 && result.homeCentroid.g > 0.7)
        #expect(result.awayCentroid.r > 0.5 && result.awayCentroid.g < 0.4)
        #expect(result.confidence > 0.5)

        // A white sample → home, a red sample → away.
        #expect(clusterer.side(for: white, in: result, flipped: false) == .home)
        #expect(clusterer.side(for: red, in: result, flipped: false) == .away)

        // Flipping swaps the mapping.
        #expect(clusterer.side(for: white, in: result, flipped: true) == .away)
        #expect(clusterer.side(for: red, in: result, flipped: true) == .home)
    }

    @Test("Returns nil when there aren't enough colours")
    func nilForTooFewColours() {
        let clusterer = TeamColorClusterer()
        #expect(clusterer.cluster(colors: [], homeKit: ColorRGB(r: 1, g: 1, b: 1), awayKit: ColorRGB(r: 0, g: 0, b: 0)) == nil)
        #expect(clusterer.cluster(colors: [ColorRGB(r: 0.5, g: 0.5, b: 0.5)], homeKit: ColorRGB(r: 1, g: 1, b: 1), awayKit: ColorRGB(r: 0, g: 0, b: 0)) == nil)
    }
}
