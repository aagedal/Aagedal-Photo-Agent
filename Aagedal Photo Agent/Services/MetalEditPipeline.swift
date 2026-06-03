import Accelerate
import CoreImage
import Metal
import os
import QuartzCore
import simd

nonisolated private let metalPipelineLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "MetalEditPipeline"
)

/// GPU mask parameters matching the Metal `MaskParams` struct.
struct MaskParams {
    var center: SIMD2<Float> = .zero
    var radii: SIMD2<Float> = SIMD2<Float>(0.15, 0.10)
    var rotation: Float = 0
    var feather: Float = 0.5
    var inverted: Float = 0
    var amount: Float = 1.0

    var exposure: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var saturation: Float = 1
    var vibrance: Float = 0
    var activeFlags: UInt32 = 0
    var _pad: UInt32 = 0
}

/// GPU overlay parameters matching the Metal `MaskOverlayParams` struct.
struct MaskOverlayParams {
    var center: SIMD2<Float> = .zero
    var radii: SIMD2<Float> = .zero
    var rotation: Float = 0
    var feather: Float = 0
    var inverted: Float = 0
    var visible: UInt32 = 0

    var scale: SIMD2<Float> = .zero
    var sourceSize: SIMD2<Float> = .zero
    var drawableSize: SIMD2<Float> = .zero

    var viewportOrigin: SIMD2<Float> = .zero
    var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)
}

/// GPU HSL per-color channel parameters matching Metal `HSLChannelParams`.
struct HSLChannelParams {
    var saturation: Float = 0
    var luminance: Float = 0
    var hueShift: Float = 0
    var _pad: Float = 0
}

/// GPU HSL adjustment parameters matching Metal `HSLParams`.
struct HSLParams {
    var channels: (HSLChannelParams, HSLChannelParams, HSLChannelParams,
                   HSLChannelParams, HSLChannelParams, HSLChannelParams,
                   HSLChannelParams) = (
        HSLChannelParams(), HSLChannelParams(), HSLChannelParams(),
        HSLChannelParams(), HSLChannelParams(), HSLChannelParams(),
        HSLChannelParams()
    )
    var activeFlags: UInt32 = 0
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

/// Uniform buffer layout matching the Metal `EditParams` struct.
/// Contains all edit operations: tonal (via LUT), vibrance, saturation, white balance.
struct EditParams {
    var exposure: Float = 0    // Legacy field kept for layout stability (baked into LUT)
    var vibrance: Float = 0
    var saturation: Float = 1
    var gamutClipMode: UInt32 = 0

    var whiteBalanceMatrix: simd_float3x3 = matrix_identity_float3x3

    var activeFlags: UInt32 = 0  // bit0=toneLUT, bit1=vibrance, bit2=saturation, bit3=whiteBalance, bit4=hdrMode
    var maskCount: UInt32 = 0

    var scale: SIMD2<Float> = .zero
    var sourceSize: SIMD2<Float> = .zero
    var drawableSize: SIMD2<Float> = .zero

    var viewportOrigin: SIMD2<Float> = .zero
    var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)

    var lutDomainMin: Float = ToneCurveGenerator.domainMin
    var lutDomainMax: Float = ToneCurveGenerator.domainMax

    // Crop viewport (clean-feed only): rotate sampling around the crop center so the
    // feed shows the confirmed crop+straighten upright. (0.5,0.5)/0 = no rotation.
    var viewportCenter: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    var viewportRotation: Float = 0
    var _padViewport: Float = 0

    // Half-extent of the crop rectangle as a fraction of the drawable, centered. Pixels
    // beyond this get the background color — the actual crop "cut" (the rest of the visible
    // region samples in-bounds image, so without this the crop edges wouldn't show).
    // (0.5, 0.5) = no crop mask (full drawable).
    var cropHalfExtent: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
}

/// Manages the Metal compute pipeline for real-time edit preview.
///
/// NSCache-compatible wrapper for MTLTexture (value types can't be cached directly).
final class MTLTextureWrapper: @unchecked Sendable {
    nonisolated(unsafe) let texture: MTLTexture
    let neutralTemperature: Float
    let neutralTint: Float
    nonisolated init(_ texture: MTLTexture, neutralTemperature: Float = 6500, neutralTint: Float = 0) {
        self.texture = texture
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
    }
}

/// Handles ALL edit operations via a unified shader: tonal adjustments through a 1D LUT
/// (Exposure, Contrast, Blacks, Shadows, Highlights, Whites), plus vibrance, saturation,
/// and white balance. The LUT is regenerated on every slider change (~microseconds).
final class MetalEditPipeline: @unchecked Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState

    private let sourceTextureLock = NSLock()
    nonisolated(unsafe) private var _sourceTexture: MTLTexture?

    nonisolated var sourceTexture: MTLTexture? {
        sourceTextureLock.withLock { _sourceTexture }
    }

    nonisolated private func setSourceTexture(_ value: MTLTexture?) {
        sourceTextureLock.withLock { _sourceTexture = value }
    }
    /// Pre-cached Metal textures for adjacent images (prev/next), keyed by URL.
    /// Limited to 2 entries to bound GPU memory. At full sensor resolution (e.g. 45MP),
    /// each texture is ~363MB rgba16Float, so this cache can use ~726MB.
    nonisolated(unsafe) private let textureCache: NSCache<NSURL, MTLTextureWrapper> = {
        let cache = NSCache<NSURL, MTLTextureWrapper>()
        cache.countLimit = 2
        return cache
    }()
    nonisolated(unsafe) private(set) var paramsBuffer: MTLBuffer?
    nonisolated(unsafe) private(set) var lutTexture: MTLTexture
    nonisolated(unsafe) private let identityLutTexture: MTLTexture
    nonisolated(unsafe) private(set) var maskBuffer: MTLBuffer?
    nonisolated(unsafe) private(set) var hslBuffer: MTLBuffer?

    /// Gamut clipping mode for soft proof preview. 0=off, 1=sRGB, 2=P3, 3=Rec.2020.
    nonisolated(unsafe) var gamutClipMode: UInt32 = 0 {
        didSet { mirror?.gamutClipMode = gamutClipMode }
    }

    /// As-shot white balance from the RAW decoder. Used as the reference point for WB
    /// adjustments so that "Custom at as-shot temperature" produces an identity matrix.
    nonisolated(unsafe) var asShotTemperature: Double = 6500 {
        didSet { mirror?.asShotTemperature = asShotTemperature }
    }
    nonisolated(unsafe) var asShotTint: Double = 0 {
        didSet { mirror?.asShotTint = asShotTint }
    }

    // MARK: - Clean-feed mirror

    /// Optional secondary pipeline (the clean-feed window on a second display) that
    /// mirrors this pipeline's **source texture** (shared by reference — no extra GPU
    /// memory) and **edit parameters**, so the second screen tracks the live edit.
    ///
    /// Only source + params + white-balance reference + gamut-clip mode are forwarded.
    /// Viewport and mask overlays are deliberately NOT forwarded: the mirror keeps its
    /// own viewport (letterboxed for the secondary display's aspect ratio) and a clean
    /// feed never shows mask-editing overlays. Setting/clearing happens on the main
    /// thread from the edit workspace; the weak reference avoids a retain cycle.
    nonisolated(unsafe) weak var mirror: MetalEditPipeline?

    /// Invoked at the end of every `updateParams` so the mirror's view can request a
    /// redraw. Called on whichever thread `updateParams` runs on — the live edit call
    /// sites are all on the main thread, matching the existing coordinator-redraw model.
    nonisolated(unsafe) var onParamsChanged: (() -> Void)?
    nonisolated(unsafe) private var float16Buffer = [UInt16](repeating: 0, count: ToneCurveGenerator.lutSize * 4)
    /// Reusable interleave scratch buffer for uploadLUT — avoids a per-frame heap allocation
    /// while a white-balance/tone slider is being dragged.
    nonisolated(unsafe) private var lutInterleaveBuffer = [Float](repeating: 0, count: ToneCurveGenerator.lutSize * 4)

    nonisolated private static let maxMasks = 8

    // Overlay pipeline (mask overlay rendering)
    private let overlayPipelineState: MTLComputePipelineState?
    nonisolated(unsafe) private let overlayParamsBuffer: MTLBuffer?

    nonisolated private static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Shared pipeline for offscreen (export) renders. Built once and reused so we don't
    /// rebuild the MTLDevice / CIContext / compute pipeline state (expensive — pipeline-state
    /// compilation alone can take hundreds of ms) on every exported image. The pipeline carries
    /// mutable per-render state (LUT, params buffer, cached WB matrix), so `renderOffscreen`
    /// serializes on `offscreenLock`; that also bounds GPU memory during batch export by
    /// preventing many full-resolution textures from being live at once.
    nonisolated private static let sharedOffscreen: (device: MTLDevice, queue: MTLCommandQueue, pipeline: MetalEditPipeline)? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalEditPipeline(device: device, commandQueue: queue) else {
            return nil
        }
        return (device, queue, pipeline)
    }()
    nonisolated private static let offscreenLock = NSLock()

    /// Max 2D texture dimension. Metal exposes no runtime query for this; every macOS GPU
    /// family (Apple and Mac2) caps a 2D texture at 16384 px per side, so we use that.
    nonisolated private static let maxTextureDimension = 16384

    private let ciContext: CIContext
    /// Separate lightweight CIContext for white balance 1×1 pixel renders.
    /// Avoids contention with the main ciContext which handles large texture uploads/precaches.
    private let wbCIContext: CIContext

    // Cached WB matrix — only recompute when temperature/tint or as-shot reference change
    nonisolated(unsafe) private var cachedWBKey: (Double, Double, Double, Double)?
    nonisolated(unsafe) private var cachedWBMatrix: simd_float3x3?

    // Cached viewport — preserved across updateParams() calls
    nonisolated(unsafe) private var cachedViewportOrigin: SIMD2<Float> = .zero
    nonisolated(unsafe) private var cachedViewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)
    // Crop straighten rotation for the clean feed (0 = no rotation). Cached so it
    // survives the full-struct rewrite in updateParams().
    nonisolated(unsafe) private var cachedViewportCenter: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    nonisolated(unsafe) private var cachedViewportRotation: Float = 0
    nonisolated(unsafe) private var cachedCropHalfExtent: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)

    nonisolated var hasSourceTexture: Bool { sourceTexture != nil }

    /// Source texture dimensions for viewport calculations (resolution-stable).
    nonisolated var sourceTextureSize: CGSize? {
        guard let tex = sourceTexture else { return nil }
        return CGSize(width: tex.width, height: tex.height)
    }

    /// Converts an array of `Float` values to IEEE 754 half-precision `UInt16` values
    /// using Accelerate, avoiding `Float16` which is unavailable on macOS.
    nonisolated private static func floatsToHalfs(_ floats: [Float]) -> [UInt16] {
        var input = floats
        var output = [UInt16](repeating: 0, count: floats.count)
        input.withUnsafeMutableBufferPointer { srcPtr in
            output.withUnsafeMutableBufferPointer { dstPtr in
                var src = vImage_Buffer(data: srcPtr.baseAddress!, height: 1,
                                        width: vImagePixelCount(floats.count),
                                        rowBytes: floats.count * MemoryLayout<Float>.size)
                var dst = vImage_Buffer(data: dstPtr.baseAddress!, height: 1,
                                        width: vImagePixelCount(floats.count),
                                        rowBytes: floats.count * MemoryLayout<UInt16>.size)
                vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
            }
        }
        return output
    }

    nonisolated init?(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "editAdjustments") else {
            return nil
        }

        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            return nil
        }

        // Overlay pipeline (optional — graceful degradation if shader missing)
        if let overlayFunc = library.makeFunction(name: "maskOverlay") {
            self.overlayPipelineState = try? device.makeComputePipelineState(function: overlayFunc)
        } else {
            self.overlayPipelineState = nil
        }
        self.overlayParamsBuffer = device.makeBuffer(
            length: MemoryLayout<MaskOverlayParams>.stride,
            options: .storageModeShared
        )

        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: Self.colorSpace,
        ])
        // Separate CIContext for WB extraction — never blocked by large texture renders
        self.wbCIContext = CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: Self.colorSpace,
        ])
        self.paramsBuffer = device.makeBuffer(length: MemoryLayout<EditParams>.stride, options: .storageModeShared)
        self.maskBuffer = device.makeBuffer(
            length: MemoryLayout<MaskParams>.stride * Self.maxMasks,
            options: .storageModeShared
        )
        self.hslBuffer = device.makeBuffer(
            length: MemoryLayout<HSLParams>.stride,
            options: .storageModeShared
        )
        metalPipelineLog.info("MaskParams stride=\(MemoryLayout<MaskParams>.stride) size=\(MemoryLayout<MaskParams>.size) alignment=\(MemoryLayout<MaskParams>.alignment)")
        metalPipelineLog.info("EditParams stride=\(MemoryLayout<EditParams>.stride) size=\(MemoryLayout<EditParams>.size) alignment=\(MemoryLayout<EditParams>.alignment)")
        metalPipelineLog.info("HSLParams stride=\(MemoryLayout<HSLParams>.stride) size=\(MemoryLayout<HSLParams>.size) alignment=\(MemoryLayout<HSLParams>.alignment)")

        // Create a 2-entry identity LUT: maps input → input (linear ramp from domainMin to domainMax).
        // Always bound at texture index 2 to avoid Metal validation errors on unbound textures.
        // rgba16Float: R/G/B channels carry per-channel LUT, A unused.
        let identityDesc = MTLTextureDescriptor()
        identityDesc.textureType = .type1D
        identityDesc.pixelFormat = .rgba16Float
        identityDesc.width = 2
        identityDesc.usage = .shaderRead
        identityDesc.storageMode = .shared
        guard let identityTex = device.makeTexture(descriptor: identityDesc) else { return nil }
        let dMin = ToneCurveGenerator.domainMin
        let dMax = ToneCurveGenerator.domainMax
        var identityData = Self.floatsToHalfs([dMin, dMin, dMin, 0, dMax, dMax, dMax, 0])
        identityTex.replace(region: MTLRegionMake1D(0, 2), mipmapLevel: 0,
                            withBytes: &identityData, bytesPerRow: 2 * 4 * MemoryLayout<UInt16>.size)
        self.identityLutTexture = identityTex

        // Pre-allocate the main LUT texture (4096 entries, rgba16Float, ~32KB).
        // R/G/B channels carry per-channel LUT for curve editor support.
        // Reused on every slider drag via replace(region:) — no per-frame allocation.
        let lutDesc = MTLTextureDescriptor()
        lutDesc.textureType = .type1D
        lutDesc.pixelFormat = .rgba16Float
        lutDesc.width = ToneCurveGenerator.lutSize
        lutDesc.usage = .shaderRead
        lutDesc.storageMode = .shared
        guard let preallocLUT = device.makeTexture(descriptor: lutDesc) else { return nil }
        self.lutTexture = preallocLUT
    }

    // MARK: - Source Texture Upload

    /// Renders the source CIImage to an MTLTexture. Call once per image load (not per frame).
    nonisolated func uploadSourceImage(_ ciImage: CIImage) {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let width = Int(extent.width)
        let height = Int(extent.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let destination = CIRenderDestination(
            width: width,
            height: height,
            pixelFormat: .rgba16Float,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { texture }
        )
        destination.isFlipped = true
        destination.colorSpace = Self.colorSpace

        let translated = ciImage.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x,
            y: -extent.origin.y
        ))

        do {
            try ciContext.startTask(
                toRender: translated,
                from: CGRect(x: 0, y: 0, width: width, height: height),
                to: destination,
                at: .zero
            )
        } catch {
            return
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        setSourceTexture(texture)
        // Share the same texture object with the clean-feed mirror (zero-copy).
        mirror?.setSourceTexture(texture)
    }

    // MARK: - LUT Upload

    /// Updates the pre-allocated 4096-entry RGBA LUT texture in-place (~32KB, no allocation).
    /// R/G/B channels carry independent per-channel tone curves.
    nonisolated private func uploadLUT(r: [Float], g: [Float], b: [Float]) {
        let count = r.count
        // Interleave R, G, B, A(0) into the reusable scratch buffer, then convert to half.
        // Fall back to a fresh allocation if the LUT size ever differs from the preallocation.
        if lutInterleaveBuffer.count != count * 4 {
            lutInterleaveBuffer = [Float](repeating: 0, count: count * 4)
        }
        for i in 0..<count {
            lutInterleaveBuffer[i * 4 + 0] = r[i]
            lutInterleaveBuffer[i * 4 + 1] = g[i]
            lutInterleaveBuffer[i * 4 + 2] = b[i]
            // A channel unused, stays 0
        }
        let totalCount = lutInterleaveBuffer.count
        lutInterleaveBuffer.withUnsafeMutableBufferPointer { srcPtr in
            float16Buffer.withUnsafeMutableBufferPointer { dstPtr in
                var src = vImage_Buffer(data: srcPtr.baseAddress!, height: 1,
                                        width: vImagePixelCount(totalCount),
                                        rowBytes: totalCount * MemoryLayout<Float>.size)
                var dst = vImage_Buffer(data: dstPtr.baseAddress!, height: 1,
                                        width: vImagePixelCount(totalCount),
                                        rowBytes: totalCount * MemoryLayout<UInt16>.size)
                vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
            }
        }
        float16Buffer.withUnsafeBufferPointer { ptr in
            lutTexture.replace(
                region: MTLRegionMake1D(0, count),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: count * 4 * MemoryLayout<UInt16>.size
            )
        }
    }

    // MARK: - Parameter Update

    /// Converts CameraRawSettings into the GPU EditParams buffer.
    /// Generates and uploads a tone LUT when any tonal adjustment is active.
    nonisolated func updateParams(_ settings: CameraRawSettings?) {
        let start = ContinuousClock.now
        guard let buffer = paramsBuffer else { return }
        var params = EditParams()
        var flags: UInt32 = 0

        guard let settings else {
            let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
            ptr.pointee = params
            ptr.pointee.gamutClipMode = gamutClipMode
            ptr.pointee.viewportOrigin = cachedViewportOrigin
            ptr.pointee.viewportSize = cachedViewportSize
            ptr.pointee.viewportCenter = cachedViewportCenter
            ptr.pointee.viewportRotation = cachedViewportRotation
            ptr.pointee.cropHalfExtent = cachedCropHalfExtent
            // Mirror to the clean-feed pipeline (its own viewport is preserved).
            mirror?.updateParams(nil)
            onParamsChanged?()
            return
        }

        // 1. Tone LUT — combines exposure, contrast, blacks, shadows, highlights, whites + custom curve
        if !ToneCurveGenerator.isIdentity(settings: settings) {
            let (rLUT, gLUT, bLUT) = ToneCurveGenerator.generatePerChannelLUT(settings: settings)
            uploadLUT(r: rLUT, g: gLUT, b: bLUT)
            params.lutDomainMin = ToneCurveGenerator.domainMin
            params.lutDomainMax = ToneCurveGenerator.domainMax
            flags |= (1 << 0)
        }

        // 2. Vibrance
        if let vib = settings.vibrance, vib != 0 {
            params.vibrance = Float(min(max(Double(vib) / 100.0, -1.0), 1.0))
            flags |= (1 << 1)
        }

        // 3. Saturation
        if let sat = settings.saturation, sat != 0 {
            params.saturation = Float(min(max(1.0 + Double(sat) / 100.0, 0.0), 2.0))
            flags |= (1 << 2)
        }

        // 4. White balance — cached, only recomputes when temperature/tint change
        if let wbMatrix = computeWhiteBalanceMatrix(settings: settings) {
            params.whiteBalanceMatrix = wbMatrix
            flags |= (1 << 3)
        }

        // 5. HDR mode flag — propagated to Metal shaders for HDR-aware processing
        if settings.hdrEditMode == 1 {
            flags |= (1 << 4)
        }

        params.activeFlags = flags

        // 5. Local mask adjustments
        let masks = settings.localAdjustments?.filter(\.enabled) ?? []
        let maskCount = min(masks.count, Self.maxMasks)
        params.maskCount = UInt32(maskCount)

        if maskCount > 0 {
            metalPipelineLog.debug("updateParams: \(maskCount) mask(s) active")
            for (i, m) in masks.prefix(maskCount).enumerated() {
                metalPipelineLog.debug("  mask[\(i)]: center=(\(m.geometry.centerX),\(m.geometry.centerY)) radii=(\(m.geometry.radiusX),\(m.geometry.radiusY)) feather=\(m.geometry.feather) exp=\(m.exposure ?? 0)")
            }
        }

        if maskCount > 0, let maskBuf = maskBuffer {
            let maskPtr = maskBuf.contents().bindMemory(to: MaskParams.self, capacity: Self.maxMasks)
            for i in 0..<maskCount {
                let mask = masks[i]
                var mp = MaskParams()
                mp.center = SIMD2<Float>(Float(mask.geometry.centerX), Float(mask.geometry.centerY))
                mp.radii = SIMD2<Float>(Float(mask.geometry.radiusX), Float(mask.geometry.radiusY))
                mp.rotation = Float(mask.geometry.rotation * .pi / 180.0)
                mp.feather = Float(mask.geometry.feather / 100.0)
                mp.inverted = mask.inverted ? 1.0 : 0.0
                mp.amount = Float(mask.amount)

                var maskFlags: UInt32 = 0
                if let exp = mask.exposure, exp != 0 {
                    mp.exposure = Float(exp)
                    maskFlags |= (1 << 0)
                }
                if let con = mask.contrast, con != 0 {
                    mp.contrast = Float(Double(con) / 100.0)
                    maskFlags |= (1 << 1)
                }
                if let hi = mask.highlights, hi != 0 {
                    mp.highlights = Float(Double(hi) / 100.0)
                    maskFlags |= (1 << 2)
                }
                if let sh = mask.shadows, sh != 0 {
                    mp.shadows = Float(Double(sh) / 100.0)
                    maskFlags |= (1 << 3)
                }
                if let wh = mask.whites, wh != 0 {
                    mp.whites = Float(Double(wh) / 100.0)
                    maskFlags |= (1 << 4)
                }
                if let bl = mask.blacks, bl != 0 {
                    mp.blacks = Float(Double(bl) / 100.0)
                    maskFlags |= (1 << 5)
                }
                if let sat = mask.saturation, sat != 0 {
                    mp.saturation = Float(min(max(1.0 + Double(sat) / 100.0, 0.0), 2.0))
                    maskFlags |= (1 << 6)
                }
                if let vib = mask.vibrance, vib != 0 {
                    mp.vibrance = Float(Double(vib) / 100.0)
                    maskFlags |= (1 << 7)
                }
                mp.activeFlags = maskFlags
                maskPtr[i] = mp
            }
        }

        // 6. HSL per-color adjustments
        if let hslBuf = hslBuffer {
            var hslP = HSLParams()
            var hslActive = false

            if let hsl = settings.hslAdjustments, !hsl.isEmpty {
                hslActive = true
                withUnsafeMutablePointer(to: &hslP.channels) { tuplePtr in
                    let ptr = UnsafeMutableRawPointer(tuplePtr)
                        .assumingMemoryBound(to: HSLChannelParams.self)
                    func encode(_ adj: HSLColorAdjustment?, at index: Int) {
                        guard let adj, !adj.isEmpty else { return }
                        var ch = HSLChannelParams()
                        if let s = adj.saturation, s != 0 { ch.saturation = Float(s) / 100.0 }
                        if let l = adj.luminance, l != 0 { ch.luminance = Float(l) / 100.0 }
                        if let h = adj.hueShift, h != 0 { ch.hueShift = Float(h) / 100.0 * 30.0 }
                        ptr[index] = ch
                    }
                    encode(hsl.red, at: 0)
                    encode(hsl.yellow, at: 1)
                    encode(hsl.green, at: 2)
                    encode(hsl.cyan, at: 3)
                    encode(hsl.blue, at: 4)
                    encode(hsl.magenta, at: 5)
                    encode(hsl.skinTone, at: 6)
                }
            }
            hslP.activeFlags = hslActive ? 1 : 0
            let hslPtr = hslBuf.contents().bindMemory(to: HSLParams.self, capacity: 1)
            hslPtr.pointee = hslP
        }

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee = params
        ptr.pointee.gamutClipMode = gamutClipMode
        ptr.pointee.viewportOrigin = cachedViewportOrigin
        ptr.pointee.viewportSize = cachedViewportSize
        ptr.pointee.viewportCenter = cachedViewportCenter
        ptr.pointee.viewportRotation = cachedViewportRotation
        ptr.pointee.cropHalfExtent = cachedCropHalfExtent

        // Mirror params to the clean-feed pipeline so the second display tracks the
        // edit live. The mirror computes against its OWN cached viewport, so its
        // letterboxing for the secondary display is preserved.
        mirror?.updateParams(settings)
        onParamsChanged?()

        let elapsed = ContinuousClock.now - start
        if elapsed > .milliseconds(1) {
            metalPipelineLog.debug("updateParams: \(elapsed) (flags: \(flags))")
        }
    }

    // MARK: - Overlay

    /// Updates mask overlay parameters for Metal overlay rendering.
    nonisolated func updateOverlayParams(geometry: EllipseMaskGeometry?, visible: Bool) {
        guard let buffer = overlayParamsBuffer else { return }
        var params = MaskOverlayParams()
        if let geo = geometry, visible {
            params.center = SIMD2<Float>(Float(geo.centerX), Float(geo.centerY))
            params.radii = SIMD2<Float>(Float(geo.radiusX), Float(geo.radiusY))
            params.rotation = Float(geo.rotation * .pi / 180.0)
            params.feather = Float(geo.feather / 100.0)
            params.visible = 1
        }
        let ptr = buffer.contents().bindMemory(to: MaskOverlayParams.self, capacity: 1)
        ptr.pointee = params
    }

    /// Whether the Metal overlay pipeline is available.
    nonisolated var hasOverlayPipeline: Bool { overlayPipelineState != nil }

    // MARK: - Render

    /// Single compute dispatch to drawable. Returns true on success.
    nonisolated(unsafe) private var lastLoggedWidth: Int = 0

    nonisolated func render(to drawable: CAMetalDrawable, drawableSize: CGSize) -> Bool {
        guard let source = sourceTexture,
              let buffer = paramsBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        let w = Int(drawableSize.width)
        if w != lastLoggedWidth {
            metalPipelineLog.debug("Metal render: \(w)×\(Int(drawableSize.height)) (source: \(source.width)×\(source.height))")
            lastLoggedWidth = w
        }

        // Stretch-to-fill: parent SwiftUI .frame() already handles aspect ratio.
        let srcW = Float(source.width)
        let srcH = Float(source.height)
        let dstW = Float(drawableSize.width)
        let dstH = Float(drawableSize.height)

        let scaleX = dstW / srcW
        let scaleY = dstH / srcH

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.scale = SIMD2<Float>(scaleX, scaleY)
        ptr.pointee.sourceSize = SIMD2<Float>(srcW, srcH)
        ptr.pointee.drawableSize = SIMD2<Float>(dstW, dstH)

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(drawable.texture, index: 1)
        encoder.setTexture(lutTexture, index: 2)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        if let maskBuf = maskBuffer {
            encoder.setBuffer(maskBuf, offset: 0, index: 1)
        }
        if let hslBuf = hslBuffer {
            encoder.setBuffer(hslBuf, offset: 0, index: 2)
        }

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width: Int(dstW),
            height: Int(dstH),
            depth: 1
        )
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Overlay pass — composites mask overlay shapes onto the drawable
        if let overlayState = overlayPipelineState, let overlayBuf = overlayParamsBuffer {
            let overlayPtr = overlayBuf.contents().bindMemory(to: MaskOverlayParams.self, capacity: 1)
            if overlayPtr.pointee.visible != 0 {
                overlayPtr.pointee.scale = SIMD2<Float>(scaleX, scaleY)
                overlayPtr.pointee.sourceSize = SIMD2<Float>(srcW, srcH)
                overlayPtr.pointee.drawableSize = SIMD2<Float>(dstW, dstH)

                if let overlayEncoder = commandBuffer.makeComputeCommandEncoder() {
                    overlayEncoder.setComputePipelineState(overlayState)
                    overlayEncoder.setTexture(drawable.texture, index: 0)
                    overlayEncoder.setBuffer(overlayBuf, offset: 0, index: 0)
                    overlayEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
                    overlayEncoder.endEncoding()
                }
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    // MARK: - White Balance

    /// Extracts the effective color transform by rendering basis vectors through CITemperatureAndTint.
    /// Caches the result — only recomputes when temperature/tint values actually change.
    nonisolated private func computeWhiteBalanceMatrix(settings: CameraRawSettings) -> simd_float3x3? {
        if settings.whiteBalance == "As Shot" {
            cachedWBKey = nil
            cachedWBMatrix = nil
            return nil
        }

        let temperature: Double?
        if let absolute = settings.temperature {
            temperature = Double(absolute)
        } else if let incremental = settings.incrementalTemperature {
            // Non-RAW relative WB. Slider range is -135...+100; the negative end maps to the
            // 2000 K floor (6500 - 135*33.33 ≈ 2000), so the slope is 5000/150 ≈ 33.33 K/step.
            temperature = 6500 + (Double(incremental) * (5000.0 / 150.0))
        } else {
            temperature = nil
        }

        let tint: Double?
        if let absolute = settings.tint {
            tint = Double(absolute)
        } else if let incremental = settings.incrementalTint {
            tint = Double(incremental)
        } else {
            tint = nil
        }

        guard temperature != nil || tint != nil else {
            cachedWBKey = nil
            cachedWBMatrix = nil
            return nil
        }
        // CITemperatureAndTint returns an identity transform below 2000 K, so clamp there.
        let finalTemp = min(max(temperature ?? 6500, 2000), 50000)
        let finalTint = min(max(tint ?? 0, -150), 150)

        // Return cached matrix if temperature/tint and as-shot reference haven't changed
        if let key = cachedWBKey,
           key.0 == finalTemp, key.1 == finalTint,
           key.2 == asShotTemperature, key.3 == asShotTint {
            return cachedWBMatrix
        }

        let matrix = extractWBMatrix(temperature: finalTemp, tint: finalTint)
        cachedWBKey = (finalTemp, finalTint, asShotTemperature, asShotTint)
        cachedWBMatrix = matrix
        return matrix
    }

    nonisolated private func extractWBMatrix(temperature: Double, tint: Double) -> simd_float3x3 {
        let colorSpace = Self.colorSpace
        // Use as-shot WB as the target neutral so that "Custom at as-shot" = identity.
        // The CIRAWFilter already decoded the image referenced to the as-shot WB.
        let targetTemp = asShotTemperature
        let targetTint = asShotTint

        func renderBasis(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SIMD3<Float> {
            let ciImage = CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: colorSpace)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

            guard let filter = CIFilter(name: "CITemperatureAndTint") else {
                return SIMD3<Float>(Float(r), Float(g), Float(b))
            }
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: CGFloat(temperature), y: CGFloat(tint)), forKey: "inputNeutral")
            filter.setValue(CIVector(x: CGFloat(targetTemp), y: CGFloat(targetTint)), forKey: "inputTargetNeutral")

            guard let output = filter.outputImage else {
                return SIMD3<Float>(Float(r), Float(g), Float(b))
            }

            var pixel = [Float](repeating: 0, count: 4)
            wbCIContext.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
            return SIMD3<Float>(pixel[0], pixel[1], pixel[2])
        }

        let colR = renderBasis(1, 0, 0)
        let colG = renderBasis(0, 1, 0)
        let colB = renderBasis(0, 0, 1)

        return simd_float3x3(colR, colG, colB)
    }

    /// Pre-warms the CIContext by rendering a dummy CITemperatureAndTint filter.
    /// Core Image JIT-compiles its internal Metal kernels on first use, which takes ~5s.
    /// Call once from a background task after pipeline creation so the user doesn't hit
    /// this cost on their first white balance slider drag.
    nonisolated func warmupCIContext() {
        let colorSpace = Self.colorSpace
        let ciImage = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: colorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 5000, y: 10), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
        guard let output = filter.outputImage else { return }
        var pixel = [Float](repeating: 0, count: 4)
        wbCIContext.render(output, toBitmap: &pixel, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: colorSpace)
        metalPipelineLog.info("CIContext warmup complete (CITemperatureAndTint)")
    }

    nonisolated func clearSourceTexture() {
        setSourceTexture(nil)
        mirror?.clearSourceTexture()
    }

    /// Share this pipeline's current source texture with another pipeline (by
    /// reference — no copy). Used to seed the clean-feed mirror when it is enabled
    /// mid-edit, after the source texture has already been uploaded.
    nonisolated func shareSourceTexture(with other: MetalEditPipeline) {
        other.setSourceTexture(sourceTexture)
    }

    // MARK: - Viewport

    /// Update viewport parameters for zoom/pan rendering.
    /// The viewport defines which region of the source texture is visible in the drawable.
    /// At zoomScale=1 and offset=zero, the full source is shown with aspect-fit letterboxing.
    nonisolated func updateViewport(
        zoomScale: CGFloat,
        offset: CGSize,
        containerSize: CGSize,
        imageSize: CGSize
    ) {
        guard let buffer = paramsBuffer else { return }
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        // Viewport size in normalized source coordinates.
        // At zoom=1, the entire source is visible; at zoom=2, half per axis.
        // Adjust for aspect ratio mismatch so letterboxing is rendered by the shader.
        let vpW: CGFloat
        let vpH: CGFloat
        if containerAspect > imageAspect {
            // Container is wider than image: letterbox sides
            vpH = 1.0 / zoomScale
            vpW = (1.0 / zoomScale) * (containerAspect / imageAspect)
        } else {
            // Container is taller than image: letterbox top/bottom
            vpW = 1.0 / zoomScale
            vpH = (1.0 / zoomScale) * (imageAspect / containerAspect)
        }

        // Convert pan offset from SwiftUI points to normalized source coordinates.
        // fittedSize is the image size in view points at zoom=1.
        let fittedScale = min(containerSize.width / imageSize.width,
                              containerSize.height / imageSize.height)
        let fittedWidth = imageSize.width * fittedScale
        let fittedHeight = imageSize.height * fittedScale

        let offsetNormX = offset.width / (fittedWidth * zoomScale)
        let offsetNormY = offset.height / (fittedHeight * zoomScale)

        // Viewport center: (0.5, 0.5) = source center, shifted by pan offset
        let originX = 0.5 - offsetNormX - vpW / 2
        let originY = 0.5 - offsetNormY - vpH / 2

        cachedViewportOrigin = SIMD2<Float>(Float(originX), Float(originY))
        cachedViewportSize = SIMD2<Float>(Float(vpW), Float(vpH))
        // Zoom/pan viewport is axis-aligned — clear any crop straighten rotation + mask.
        cachedViewportCenter = SIMD2<Float>(Float(originX + vpW / 2), Float(originY + vpH / 2))
        cachedViewportRotation = 0
        cachedCropHalfExtent = SIMD2<Float>(0.5, 0.5)

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.viewportOrigin = cachedViewportOrigin
        ptr.pointee.viewportSize = cachedViewportSize
        ptr.pointee.viewportCenter = cachedViewportCenter
        ptr.pointee.viewportRotation = cachedViewportRotation
        ptr.pointee.cropHalfExtent = cachedCropHalfExtent

        // Also update overlay params
        if let overlayBuf = overlayParamsBuffer {
            let overlayPtr = overlayBuf.contents().bindMemory(to: MaskOverlayParams.self, capacity: 1)
            overlayPtr.pointee.viewportOrigin = cachedViewportOrigin
            overlayPtr.pointee.viewportSize = cachedViewportSize
        }
    }

    /// Clean-feed crop viewport. Renders only the confirmed crop region (with straighten
    /// rotation), aspect-fit to the secondary display. Mirrors the editor's own crop
    /// geometry (`EditWorkspaceView.cropFittedImageRect`): the AABB is forward-projected to
    /// the actual rotated crop dimensions, those are fit to the container, and the shader
    /// rotates sampling around the crop center. Crop edges are normalized [0,1] in
    /// display-oriented source coords (top-left origin), matching the editor's `activeCrop`.
    nonisolated func updateCropViewport(
        containerSize: CGSize,
        imageSize: CGSize,
        cropLeft: Double,
        cropTop: Double,
        cropRight: Double,
        cropBottom: Double,
        angleDegrees: Double
    ) {
        guard let buffer = paramsBuffer else { return }
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return }

        let imgW = Double(imageSize.width)
        let imgH = Double(imageSize.height)

        // Crop AABB dimensions and center in source pixels / normalized coords.
        let aabbW = max((cropRight - cropLeft), 0.0001) * imgW
        let aabbH = max((cropBottom - cropTop), 0.0001) * imgH
        let centerX = (cropLeft + cropRight) / 2
        let centerY = (cropTop + cropBottom) / 2

        // Forward-project the AABB to the actual rotated crop dimensions, then fit those
        // into the container (identical to cropFittedImageRect's baseScale).
        let radians = angleDegrees * .pi / 180.0
        let cosA = cos(radians)
        let sinA = sin(radians)
        let actualW = abs(aabbW * cosA + aabbH * sinA)
        let actualH = abs(-aabbW * sinA + aabbH * cosA)

        let fitScale = min(containerSize.width / max(actualW, 1),
                           containerSize.height / max(actualH, 1))
        guard fitScale > 0 else { return }

        // The source region (in pixels) that maps to the full drawable — larger than the
        // crop by the letterbox margin.
        let visiblePxW = Double(containerSize.width) / fitScale
        let visiblePxH = Double(containerSize.height) / fitScale
        let vpW = visiblePxW / imgW
        let vpH = visiblePxH / imgH

        cachedViewportSize = SIMD2<Float>(Float(vpW), Float(vpH))
        cachedViewportCenter = SIMD2<Float>(Float(centerX), Float(centerY))
        cachedViewportOrigin = SIMD2<Float>(Float(centerX - vpW / 2), Float(centerY - vpH / 2))
        cachedViewportRotation = Float(radians)

        // The crop occupies the central (actual·fitScale / container) fraction of the
        // drawable; the rest is letterbox margin that must be masked to the background.
        let cropHalfX = (actualW * fitScale) / (2 * Double(containerSize.width))
        let cropHalfY = (actualH * fitScale) / (2 * Double(containerSize.height))
        cachedCropHalfExtent = SIMD2<Float>(Float(cropHalfX), Float(cropHalfY))

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.viewportOrigin = cachedViewportOrigin
        ptr.pointee.viewportSize = cachedViewportSize
        ptr.pointee.viewportCenter = cachedViewportCenter
        ptr.pointee.viewportRotation = cachedViewportRotation
        ptr.pointee.cropHalfExtent = cachedCropHalfExtent
    }

    // MARK: - Texture Pre-Caching

    /// Pre-render a CIImage to a Metal texture and cache it by URL.
    /// Call from a background task for adjacent images (prev/next).
    nonisolated func precacheTexture(for url: URL, ciImage: CIImage, neutralTemperature: Float = 6500, neutralTint: Float = 0) {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let width = Int(extent.width)
        let height = Int(extent.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let destination = CIRenderDestination(
            width: width, height: height, pixelFormat: .rgba16Float,
            commandBuffer: commandBuffer, mtlTextureProvider: { texture }
        )
        destination.isFlipped = true
        destination.colorSpace = Self.colorSpace

        let translated = ciImage.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x, y: -extent.origin.y
        ))

        do {
            try ciContext.startTask(
                toRender: translated,
                from: CGRect(x: 0, y: 0, width: width, height: height),
                to: destination, at: .zero
            )
        } catch { return }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        textureCache.setObject(MTLTextureWrapper(texture, neutralTemperature: neutralTemperature, neutralTint: neutralTint), forKey: url as NSURL)
    }

    /// Promote a pre-cached texture to sourceTexture. Returns as-shot WB on hit, nil on miss.
    nonisolated func applyCachedTexture(for url: URL) -> (neutralTemperature: Float, neutralTint: Float)? {
        guard let wrapper = textureCache.object(forKey: url as NSURL) else { return nil }
        setSourceTexture(wrapper.texture)
        mirror?.setSourceTexture(wrapper.texture)
        textureCache.removeObject(forKey: url as NSURL)
        return (neutralTemperature: wrapper.neutralTemperature, neutralTint: wrapper.neutralTint)
    }

    // MARK: - Offscreen Rendering

    /// Renders tonal adjustments via the Metal compute shader and returns the result as CIImage.
    /// Creates an ephemeral pipeline instance — safe to call from any thread.
    /// Uses the exact same shader as the live preview: LUT, vibrance, saturation,
    /// white balance, and highlight desaturation. No CIFilter approximation.
    nonisolated static func renderOffscreen(
        source: CIImage,
        settings: CameraRawSettings?
    ) -> CIImage? {
        guard let settings, !isIdentitySettings(settings) else { return nil }
        let maskCount = settings.localAdjustments?.filter(\.enabled).count ?? 0
        if maskCount > 0 {
            metalPipelineLog.info("renderOffscreen: \(maskCount) mask(s) in settings")
        }

        let originalExtent = source.extent
        guard originalExtent.width > 0, originalExtent.height > 0 else { return nil }

        // Reuse the shared offscreen pipeline (device/queue/CIContext/pipeline-state).
        guard let shared = sharedOffscreen else { return nil }
        let device = shared.device
        let queue = shared.queue
        let pipeline = shared.pipeline

        // OOM / Metal-limit guard: cap to the device's max 2D texture dimension. Stitched
        // panoramas and other oversized inputs would otherwise fail texture allocation or
        // exhaust memory. Downscaling here keeps the export fully edited (masks/HSL included)
        // rather than crashing or silently dropping to the CIFilter fallback.
        let maxDim = CGFloat(maxTextureDimension)
        var working = source
        if originalExtent.width > maxDim || originalExtent.height > maxDim {
            let scale = min(maxDim / originalExtent.width, maxDim / originalExtent.height)
            metalPipelineLog.info("renderOffscreen: downscaling \(Int(originalExtent.width))x\(Int(originalExtent.height)) by \(scale, format: .fixed(precision: 4)) to fit max texture dim \(Int(maxDim))")
            working = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = working.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // Serialize use of the shared pipeline's mutable state (LUT, params, WB cache).
        offscreenLock.lock()
        defer { offscreenLock.unlock() }

        // 1. Upload source CIImage to Metal texture
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        srcDesc.usage = [.shaderRead, .shaderWrite]
        srcDesc.storageMode = .private
        guard let srcTexture = device.makeTexture(descriptor: srcDesc),
              let uploadCmdBuf = queue.makeCommandBuffer() else { return nil }

        let dest = CIRenderDestination(
            width: width, height: height, pixelFormat: .rgba16Float,
            commandBuffer: uploadCmdBuf, mtlTextureProvider: { srcTexture }
        )
        dest.isFlipped = true
        dest.colorSpace = colorSpace

        let translated = working.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x, y: -extent.origin.y
        ))
        do {
            try pipeline.ciContext.startTask(
                toRender: translated,
                from: CGRect(x: 0, y: 0, width: width, height: height),
                to: dest, at: .zero
            )
        } catch {
            metalPipelineLog.error("renderOffscreen: CIImage upload failed: \(error)")
            return nil
        }
        uploadCmdBuf.commit()
        uploadCmdBuf.waitUntilCompleted()

        // 2. Propagate as-shot WB reference so the ephemeral pipeline computes
        //    the same white balance matrix as the live edit preview.
        if let asTemp = settings.asShotNeutralTemperature {
            pipeline.asShotTemperature = asTemp
        }
        if let asTint = settings.asShotNeutralTint {
            pipeline.asShotTint = asTint
        }

        // 3. Generate LUT and set parameters
        pipeline.updateParams(settings)

        // 3. Create output texture (managed — CIImage can create from it)
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        outDesc.storageMode = .shared
        guard let outTexture = device.makeTexture(descriptor: outDesc) else { return nil }

        // 4. Dispatch compute shader
        guard let paramsBuffer = pipeline.paramsBuffer,
              let computeCmdBuf = queue.makeCommandBuffer(),
              let encoder = computeCmdBuf.makeComputeCommandEncoder() else { return nil }

        let ptr = paramsBuffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.scale = SIMD2<Float>(1.0, 1.0)
        ptr.pointee.sourceSize = SIMD2<Float>(Float(width), Float(height))
        ptr.pointee.drawableSize = SIMD2<Float>(Float(width), Float(height))
        ptr.pointee.viewportOrigin = .zero
        ptr.pointee.viewportSize = SIMD2<Float>(1.0, 1.0)

        encoder.setComputePipelineState(pipeline.pipelineState)
        encoder.setTexture(srcTexture, index: 0)
        encoder.setTexture(outTexture, index: 1)

        // Use active LUT if tonal ops are active, otherwise identity
        let flags = ptr.pointee.activeFlags
        let useLUT = (flags & (1 << 0)) != 0
        encoder.setTexture(useLUT ? pipeline.lutTexture : pipeline.identityLutTexture, index: 2)

        encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
        if let maskBuf = pipeline.maskBuffer {
            encoder.setBuffer(maskBuf, offset: 0, index: 1)
        }
        if let hslBuf = pipeline.hslBuffer {
            encoder.setBuffer(hslBuf, offset: 0, index: 2)
        }

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        computeCmdBuf.commit()
        computeCmdBuf.waitUntilCompleted()

        // 5. Create CIImage from output texture
        // CIImage(mtlTexture:) produces a vertically flipped image — correct with orientation
        guard let result = CIImage(mtlTexture: outTexture, options: [
            .colorSpace: colorSpace
        ]) else { return nil }
        return result.oriented(.downMirrored)
    }

    /// Returns true if settings have no visual adjustments (all filters would be identity).
    nonisolated private static func isIdentitySettings(_ settings: CameraRawSettings) -> Bool {
        let noTonal = ToneCurveGenerator.isIdentity(settings: settings)
        let noVibrance = settings.vibrance == nil || settings.vibrance == 0
        let noSaturation = settings.saturation == nil || settings.saturation == 0
        let noWB = settings.whiteBalance == "As Shot"
            || (settings.temperature == nil && settings.incrementalTemperature == nil
                && settings.tint == nil && settings.incrementalTint == nil)
        let noMasks = settings.localAdjustments?.isEmpty ?? true
        let noHSL = settings.hslAdjustments?.isEmpty ?? true
        return noTonal && noVibrance && noSaturation && noWB && noMasks && noHSL
    }
}
