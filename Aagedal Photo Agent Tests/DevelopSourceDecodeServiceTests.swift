import AppKit
import CoreImage
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop source decode service")
struct DevelopSourceDecodeServiceTests {
    @Test("RAW source requests execute serially")
    func rawRequestsAreSerialized() async {
        let probe = RAWDecodeProbe()
        let service = DevelopSourceDecodeService(
            rawDecoder: { url, _, _ in probe.decode(url) },
            orientationReader: { _ in 1 }
        )

        async let first = service.loadRAW(
            from: URL(fileURLWithPath: "/tmp/foreground.arw"),
            maxPixelSize: 2_048,
            targetOrientation: 1
        )
        async let second = service.loadRAW(
            from: URL(fileURLWithPath: "/tmp/precache.arw"),
            maxPixelSize: 2_048,
            targetOrientation: 1
        )

        let results = await [first, second]

        #expect(results.allSatisfy { $0 != nil })
        #expect(probe.callCount == 2)
        #expect(probe.maximumConcurrentCalls == 1)
    }

    @Test("a pre-cancelled RAW request never reaches the decoder")
    func preCancelledRAWRequestSkipsDecode() async {
        let probe = RAWDecodeProbe()
        let service = DevelopSourceDecodeService(
            rawDecoder: { url, _, _ in probe.decode(url) },
            orientationReader: { _ in 1 }
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.loadRAW(
                from: URL(fileURLWithPath: "/tmp/cancelled.arw"),
                maxPixelSize: 2_048,
                targetOrientation: 1
            )
        }

        let result = await task.value

        #expect(result == nil)
        #expect(probe.callCount == 0)
    }

    @Test("orientation correction keeps Core Image and AppKit frames aligned")
    func orientationCorrectionAlignsRepresentations() throws {
        let source = CIImage(color: .red).cropped(
            to: CGRect(x: 0, y: 0, width: 40, height: 20)
        )
        let cgImage = try #require(CameraRawApproximation.ciContext.createCGImage(
            source,
            from: source.extent
        ))
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )

        let oriented = DevelopSourceDecodeService.orientedToTarget(
            ciImage: source,
            nsImage: image,
            from: 1,
            to: 6
        )

        #expect(oriented.ciImage?.extent.width == 20)
        #expect(oriented.ciImage?.extent.height == 40)
        #expect(oriented.nsImage?.size.width == 20)
        #expect(oriented.nsImage?.size.height == 40)
    }

    @Test("the Develop view delegates concrete decode and materialization")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("DevelopSourceDecodeService.shared.loadEmbeddedRAWPreview("))
        #expect(source.contains("DevelopSourceDecodeService.shared.loadNonRAWPreview("))
        #expect(source.contains("DevelopSourceDecodeService.shared.loadNonRAWFullResolution("))
        #expect(source.contains("DevelopSourceDecodeService.shared.loadRAW("))
        #expect(source.contains("DevelopSourceDecodeService.shared.materialize("))
        #expect(!source.contains("FullScreenImageCache.loadRAWImage("))
        #expect(!source.contains("FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation("))
        #expect(!source.contains("FullScreenImageCache.loadFullResolutionOffPoolWithOrientation("))
        #expect(!source.contains("nonisolated private static func orientedToTarget("))
    }
}

nonisolated private final class RAWDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0
    private var recordedMaximumConcurrentCalls = 0
    private var recordedCallCount = 0

    var maximumConcurrentCalls: Int {
        lock.withLock { recordedMaximumConcurrentCalls }
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func decode(_ url: URL) -> FullScreenImageCache.RAWDecodeResult {
        lock.withLock {
            activeCalls += 1
            recordedCallCount += 1
            recordedMaximumConcurrentCalls = max(recordedMaximumConcurrentCalls, activeCalls)
        }
        Thread.sleep(forTimeInterval: 0.04)
        lock.withLock { activeCalls -= 1 }
        let image = CIImage(color: .gray).cropped(
            to: CGRect(x: 0, y: 0, width: 16, height: 8)
        )
        return FullScreenImageCache.RAWDecodeResult(
            image: image,
            neutralTemperature: Float(url.lastPathComponent.count),
            neutralTint: 0
        )
    }
}
