import AppKit
import CoreImage
import Foundation
import ImageIO
import Metal
import Observation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop source decode service")
struct DevelopSourceDecodeServiceTests {
    @Test("passive RAW previews share the serialized draft decoder")
    func passiveRAWPreviewUsesSerializedDraftDecoder() async {
        let probe = RAWDecodeProbe()
        let service = DevelopSourceDecodeService(
            rawDecoder: { url, draftMode, _ in probe.decode(url, draftMode: draftMode) },
            orientationReader: { _ in 1 }
        )

        async let first = service.loadRAWPreviewSource(
            from: URL(fileURLWithPath: "/tmp/clean-feed.arw"),
            maxPixelSize: 2_048
        )
        async let second = service.loadRAWPreviewSource(
            from: URL(fileURLWithPath: "/tmp/develop-precache.arw"),
            maxPixelSize: 2_048
        )

        let results = await [first, second]

        #expect(results.allSatisfy { $0 != nil })
        #expect(probe.callCount == 2)
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.draftModes == [true, true])
    }

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

    /// Navigation promotes an adjacent-image precache instead of decoding the RAW again. That is
    /// only correct when the cached texture is interchangeable with the foreground decode: same
    /// decode size and orientation (anything else is a miss) and identical pixels.
    @Test("a precached RAW texture is promoted without decoding only for the matching decode")
    @MainActor
    func precachedRAWTextureMatchesForegroundDecode() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalLivePreviewPipeline(device: device, commandQueue: queue)
        else { return }
        let counter = DecodeCounter()
        let service = DevelopSourceDecodeService(
            rawDecoder: { _, _, _ in
                counter.increment()
                return FullScreenImageCache.RAWDecodeResult(
                    image: Self.twoToneImage(),
                    neutralTemperature: 5_100,
                    neutralTint: 7
                )
            },
            orientationReader: { _ in 1 }
        )
        let url = URL(fileURLWithPath: "/tmp/develop-precache-neighbour.arw")
        pipeline.uploadSourceImage(Self.twoToneImage())

        #expect(await service.precacheRAWTexture(
            for: url, targetOrientation: 1, maxPixelSize: 2_048, into: pipeline
        ))
        #expect(counter.count == 1)
        // Rotated since the precache: miss.
        #expect(pipeline.applyCachedTexture(for: url, exifOrientation: 6, decodeMaxPixelSize: 2_048) == nil)

        _ = await service.precacheRAWTexture(
            for: url, targetOrientation: 1, maxPixelSize: 2_048, into: pipeline
        )
        // Different preview size (another display): miss.
        #expect(pipeline.applyCachedTexture(for: url, exifOrientation: 1, decodeMaxPixelSize: 1_600) == nil)

        _ = await service.precacheRAWTexture(
            for: url, targetOrientation: 1, maxPixelSize: 2_048, into: pipeline
        )
        #expect(counter.count == 3)
        let whiteBalance = try #require(
            pipeline.applyCachedTexture(for: url, exifOrientation: 1, decodeMaxPixelSize: 2_048)
        )
        #expect(whiteBalance.neutralTemperature == 5_100)
        #expect(whiteBalance.neutralTint == 7)
        #expect(counter.count == 3, "Promotion must not decode")
        let promoted = try #require(Self.readBack(pipeline))

        // What Phase 2 would have produced for the same request.
        let foreground = try #require(
            await service.loadRAW(from: url, maxPixelSize: 2_048, targetOrientation: 1)
        )
        pipeline.uploadSourceImage(foreground.image, exifOrientation: 1)
        let uploaded = try #require(Self.readBack(pipeline))

        #expect(promoted.width == uploaded.width && promoted.height == uploaded.height)
        #expect(promoted.dataProvider?.data as Data? == uploaded.dataProvider?.data as Data?)
        // The readback keeps the source frame upright (texture row 0 = image top).
        let readBackImage = CIImage(cgImage: promoted)
        #expect(Self.red(readBackImage, x: 4, y: 28) > 0.9)
        #expect(Self.red(readBackImage, x: 4, y: 3) < 0.1)
    }

    /// A RAW decode-settings change while a neighbour is mid-decode must not let that old-settings
    /// decode into the cache after the purge: the permit is taken before decoding.
    @Test("a decode-settings change during a precache decode rejects the stale texture")
    @MainActor
    func decodeSettingsChangeDuringPrecacheDecodeRejectsResult() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalLivePreviewPipeline(device: device, commandQueue: queue)
        else { return }
        let discardDuringDecode = DecodeCounter()
        let service = DevelopSourceDecodeService(
            rawDecoder: { _, _, _ in
                if discardDuringDecode.count > 0 {
                    // `.rawDecodeSettingsDidChange` lands while CIRAWFilter is decoding.
                    pipeline.discardSpeculativeTextures()
                }
                return FullScreenImageCache.RAWDecodeResult(
                    image: Self.twoToneImage(),
                    neutralTemperature: 5_000,
                    neutralTint: 0
                )
            },
            orientationReader: { _ in 1 }
        )
        let url = URL(fileURLWithPath: "/tmp/develop-precache-settings-change.arw")
        pipeline.uploadSourceImage(Self.twoToneImage())

        discardDuringDecode.increment()
        _ = await service.precacheRAWTexture(
            for: url, targetOrientation: 1, maxPixelSize: 2_048, into: pipeline
        )
        #expect(pipeline.applyCachedTexture(for: url, exifOrientation: 1, decodeMaxPixelSize: 2_048) == nil)

        // Control: the same precache without a concurrent settings change is stored.
        let control = DevelopSourceDecodeService(
            rawDecoder: { _, _, _ in
                FullScreenImageCache.RAWDecodeResult(
                    image: Self.twoToneImage(),
                    neutralTemperature: 5_000,
                    neutralTint: 0
                )
            },
            orientationReader: { _ in 1 }
        )
        _ = await control.precacheRAWTexture(
            for: url, targetOrientation: 1, maxPixelSize: 2_048, into: pipeline
        )
        #expect(pipeline.applyCachedTexture(for: url, exifOrientation: 1, decodeMaxPixelSize: 2_048) != nil)
    }

    /// The scope panel picks the Metal scope from non-observable pipeline state; the observable
    /// revision must move whenever the source texture is uploaded, promoted or cleared.
    @Test("source texture upload, promotion and clear advance the observable scope revision")
    @MainActor
    func sourceTextureChangesAdvanceScopeRevision() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalLivePreviewPipeline(device: device, commandQueue: queue)
        else { return }
        let scope = ScopeViewModel(scopeMode: .waveform, persistsScopeMode: false)
        scope.metalEditPipeline = pipeline
        scope.refreshMetalSourceRevision()
        #expect(!scope.isMetalScopeActive)

        func expectRevisionChange(_ label: String, _ change: () -> Void) {
            let before = scope.metalSourceRevision
            let notifications = DecodeCounter()
            withObservationTracking {
                _ = scope.isMetalScopeActive
            } onChange: {
                notifications.increment()
            }
            change()
            scope.refreshMetalSourceRevision()
            #expect(scope.metalSourceRevision != before, Comment(rawValue: label))
            #expect(notifications.count > 0, Comment(rawValue: label))
        }

        expectRevisionChange("upload") { pipeline.uploadSourceImage(Self.twoToneImage()) }

        let url = URL(fileURLWithPath: "/tmp/develop-scope-revision.arw")
        pipeline.precacheTexture(for: url, ciImage: Self.twoToneImage())
        expectRevisionChange("promotion") { _ = pipeline.applyCachedTexture(for: url) }
        expectRevisionChange("clear") { pipeline.clearSourceTexture() }

        // No texture change: no notification churn.
        let settled = scope.metalSourceRevision
        scope.refreshMetalSourceRevision()
        #expect(scope.metalSourceRevision == settled)
    }

    /// Non-RAW Develop sources are uploaded at screen resolution like RAW; zoom upgrades to the
    /// full-resolution decode (`loadFullResEditTextureIfNeeded` compares the native long side
    /// with 1.5x the texture). All Develop geometry is normalized, so only detail changes.
    @Test("non-RAW sources load at screen resolution and upgrade to full resolution on zoom")
    @MainActor
    func nonRAWScreenResolutionTextureAndZoomUpgrade() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalLivePreviewPipeline(device: device, commandQueue: queue)
        else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("develop-nonraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.jpg")
        try Self.writeJPEG(width: 3_000, height: 2_000, to: url)

        let service = DevelopSourceDecodeService()
        let preview = try #require(
            await service.loadNonRAWPreview(from: url, maxPixelSize: 1_000, targetOrientation: 1)
        )
        let screenSource = try #require(preview.ciImage)
        pipeline.uploadSourceImage(screenSource)
        let screenSize = try #require(pipeline.sourceTextureSize)
        #expect(max(screenSize.width, screenSize.height) == 1_000)

        let nativeLongestSide = try #require(FullScreenImageCache.nativeLongestSide(of: url))
        #expect(nativeLongestSide == 3_000)
        #expect(nativeLongestSide > max(screenSize.width, screenSize.height) * 1.5)

        let fullResolution = try #require(
            await service.loadNonRAWFullResolution(from: url, targetOrientation: 1)
        )
        pipeline.uploadSourceImage(fullResolution)
        #expect(pipeline.sourceTextureSize == CGSize(width: 3_000, height: 2_000))
        let screenAspect = screenSize.width / screenSize.height
        #expect(abs(screenAspect - 1.5) < 0.005)
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
        #expect(source.contains("DevelopSourceDecodeService.shared.precacheRAWTexture("))
        // The retained CI source is read back from the uploaded texture rather than rendering
        // the decode graph a second time.
        #expect(source.contains("pipeline.readBackSourceTexture("))
        #expect(!source.contains("DevelopSourceDecodeService.shared.materialize("))
        #expect(!source.contains("FullScreenImageCache.loadRAWImage("))
        #expect(!source.contains("FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation("))
        #expect(!source.contains("FullScreenImageCache.loadFullResolutionOffPoolWithOrientation("))
        #expect(!source.contains("nonisolated private static func orientedToTarget("))
    }

    /// 48×32, red top half / blue bottom half (Core Image y-up: top = y ≥ 16).
    nonisolated private static func twoToneImage() -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 16, width: 48, height: 16))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 16))
        return red.composited(over: blue)
    }

    @MainActor
    private static func readBack(_ pipeline: MetalLivePreviewPipeline) -> CGImage? {
        pipeline.sourceTextureHandle().flatMap {
            pipeline.readBackSourceTexture($0, maxPixelSize: 2_048)
        }
    }

    private static func red(_ image: CIImage, x: Int, y: Int) -> Float {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var pixel = [Float](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: space]).render(
            image,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: space
        )
        return pixel[0]
    }

    private static func writeJPEG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

nonisolated private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

nonisolated private final class RAWDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCalls = 0
    private var recordedMaximumConcurrentCalls = 0
    private var recordedCallCount = 0
    private var recordedDraftModes: [Bool] = []

    var maximumConcurrentCalls: Int {
        lock.withLock { recordedMaximumConcurrentCalls }
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    var draftModes: [Bool] {
        lock.withLock { recordedDraftModes }
    }

    func decode(
        _ url: URL,
        draftMode: Bool = false
    ) -> FullScreenImageCache.RAWDecodeResult {
        lock.withLock {
            activeCalls += 1
            recordedCallCount += 1
            recordedDraftModes.append(draftMode)
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
