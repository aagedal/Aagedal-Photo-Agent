import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Analysis scope selection")
struct AnalysisScopeSelectionTests {
    @Test("workspace state retains its layout and active scope choices")
    func workspaceStateRetention() {
        var state = AnalysisScopeWorkspaceState()
        state.layout = .four
        state.waveformPresentation = .image
        state.paradePresentation = .chromaticity
        state.vectorscopePresentation = .waveform
        state.chromaticityPresentation = .parade

        let restoredState = state
        #expect(restoredState.layout == .four)
        #expect(restoredState.waveformPresentation == .image)
        #expect(restoredState.paradePresentation == .chromaticity)
        #expect(restoredState.vectorscopePresentation == .waveform)
        #expect(restoredState.chromaticityPresentation == .parade)
    }

    @Test("drag selection is direction independent and clamped")
    func normalizedSelection() throws {
        let forward = try #require(
            AnalysisScopeSelection.normalizedRect(
                from: CGPoint(x: 0.2, y: 0.3),
                to: CGPoint(x: 0.8, y: 0.9)
            )
        )
        let reverse = try #require(
            AnalysisScopeSelection.normalizedRect(
                from: CGPoint(x: 0.8, y: 0.9),
                to: CGPoint(x: 0.2, y: 0.3)
            )
        )
        #expect(forward == reverse)
        #expect(abs(forward.minX - 0.2) < 0.000_001)
        #expect(abs(forward.minY - 0.3) < 0.000_001)
        #expect(abs(forward.width - 0.6) < 0.000_001)
        #expect(abs(forward.height - 0.6) < 0.000_001)

        let clamped = try #require(
            AnalysisScopeSelection.normalizedRect(
                from: CGPoint(x: -1, y: 0.25),
                to: CGPoint(x: 2, y: 0.75)
            )
        )
        #expect(clamped == CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
    }

    @Test("collapsed and invalid selections are rejected")
    func invalidSelection() {
        #expect(
            AnalysisScopeSelection.normalizedRect(
                from: CGPoint(x: 0.5, y: 0.5),
                to: CGPoint(x: 0.5, y: 0.5)
            ) == nil
        )
        #expect(
            AnalysisScopeSelection.normalizedRect(
                from: CGPoint(x: CGFloat.infinity, y: 0),
                to: CGPoint(x: 1, y: 1)
            ) == nil
        )
    }

    @Test("normalized selection maps outward to top-left image pixels")
    func pixelMapping() {
        #expect(
            AnalysisScopeSelection.pixelRect(
                for: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                imageWidth: 100,
                imageHeight: 50
            ) == CGRect(x: 10, y: 10, width: 30, height: 20)
        )
        #expect(
            AnalysisScopeSelection.pixelRect(
                for: CGRect(x: -0.2, y: 0.8, width: 0.5, height: 0.5),
                imageWidth: 100,
                imageHeight: 50
            ) == CGRect(x: 0, y: 40, width: 30, height: 10)
        )
    }

    @Test("cropped scope input has the selected pixel dimensions")
    func cropDimensions() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: 80,
                height: 60,
                bitsPerComponent: 8,
                bytesPerRow: 80 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let source = try #require(context.makeImage())
        let crop = try #require(
            AnalysisScopeSelection.croppedImage(
                from: source,
                normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            )
        )
        #expect(crop.width == 40)
        #expect(crop.height == 30)
    }
}
