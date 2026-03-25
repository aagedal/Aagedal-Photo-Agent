import Accelerate
import CoreImage
import Metal
import os
import QuartzCore
import simd

nonisolated(unsafe) private let metalPipelineLog = Logger(
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
}

/// Uniform buffer layout matching the Metal `EditParams` struct.
/// Contains all edit operations: tonal (via LUT), vibrance, saturation, white balance.
struct EditParams {
    var exposure: Float = 0    // Legacy field kept for layout stability (baked into LUT)
    var vibrance: Float = 0
    var saturation: Float = 1
    var pad0: Float = 0

    var whiteBalanceMatrix: simd_float3x3 = matrix_identity_float3x3

    var activeFlags: UInt32 = 0  // bit0=toneLUT, bit1=vibrance, bit2=saturation, bit3=whiteBalance, bit4=hdrMode
    var maskCount: UInt32 = 0

    var scale: SIMD2<Float> = .zero
    var sourceSize: SIMD2<Float> = .zero
    var drawableSize: SIMD2<Float> = .zero

    var lutDomainMin: Float = ToneCurveGenerator.domainMin
    var lutDomainMax: Float = ToneCurveGenerator.domainMax
}

/// Manages the Metal compute pipeline for real-time edit preview.
///
/// NSCache-compatible wrapper for MTLTexture (value types can't be cached directly).
final class MTLTextureWrapper: @unchecked Sendable {
    nonisolated(unsafe) let texture: MTLTexture
    nonisolated init(_ texture: MTLTexture) { self.texture = texture }
}

/// Handles ALL edit operations via a unified shader: tonal adjustments through a 1D LUT
/// (Exposure, Contrast, Blacks, Shadows, Highlights, Whites), plus vibrance, saturation,
/// and white balance. The LUT is regenerated on every slider change (~microseconds).
final class MetalEditPipeline: @unchecked Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState

    nonisolated(unsafe) private(set) var sourceTexture: MTLTexture?
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
    nonisolated(unsafe) private var float16Buffer = [UInt16](repeating: 0, count: ToneCurveGenerator.lutSize * 4)

    nonisolated(unsafe) private static let maxMasks = 8

    // Overlay pipeline (mask overlay rendering)
    private let overlayPipelineState: MTLComputePipelineState?
    nonisolated(unsafe) private let overlayParamsBuffer: MTLBuffer?

    nonisolated(unsafe) private static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private let ciContext: CIContext
    /// Separate lightweight CIContext for white balance 1×1 pixel renders.
    /// Avoids contention with the main ciContext which handles large texture uploads/precaches.
    private let wbCIContext: CIContext

    // Cached WB matrix — only recompute when temperature/tint actually change
    nonisolated(unsafe) private var cachedWBKey: (Double, Double)?
    nonisolated(unsafe) private var cachedWBMatrix: simd_float3x3?

    nonisolated var hasSourceTexture: Bool { sourceTexture != nil }

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
        metalPipelineLog.info("MaskParams stride=\(MemoryLayout<MaskParams>.stride) size=\(MemoryLayout<MaskParams>.size) alignment=\(MemoryLayout<MaskParams>.alignment)")
        metalPipelineLog.info("EditParams stride=\(MemoryLayout<EditParams>.stride) size=\(MemoryLayout<EditParams>.size) alignment=\(MemoryLayout<EditParams>.alignment)")

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
        sourceTexture = texture
    }

    // MARK: - LUT Upload

    /// Updates the pre-allocated 4096-entry RGBA LUT texture in-place (~32KB, no allocation).
    /// R/G/B channels carry independent per-channel tone curves.
    nonisolated private func uploadLUT(r: [Float], g: [Float], b: [Float]) {
        let count = r.count
        // Interleave R, G, B, A(0) into a single float array, then convert to half
        var interleaved = [Float](repeating: 0, count: count * 4)
        for i in 0..<count {
            interleaved[i * 4 + 0] = r[i]
            interleaved[i * 4 + 1] = g[i]
            interleaved[i * 4 + 2] = b[i]
            // A channel unused, stays 0
        }
        let totalCount = interleaved.count
        interleaved.withUnsafeMutableBufferPointer { srcPtr in
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
                if let sat = mask.saturation, sat != 0 {
                    mp.saturation = Float(min(max(1.0 + Double(sat) / 100.0, 0.0), 2.0))
                    maskFlags |= (1 << 6)
                }
                mp.activeFlags = maskFlags
                maskPtr[i] = mp
            }
        }

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee = params

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
            temperature = 6500 + (Double(incremental) * 50)
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
        let finalTemp = min(max(temperature ?? 6500, 2000), 50000)
        let finalTint = min(max(tint ?? 0, -150), 150)

        // Return cached matrix if temperature/tint haven't changed
        if let key = cachedWBKey, key.0 == finalTemp, key.1 == finalTint {
            return cachedWBMatrix
        }

        let matrix = extractWBMatrix(temperature: finalTemp, tint: finalTint)
        cachedWBKey = (finalTemp, finalTint)
        cachedWBMatrix = matrix
        return matrix
    }

    nonisolated private func extractWBMatrix(temperature: Double, tint: Double) -> simd_float3x3 {
        let colorSpace = Self.colorSpace

        func renderBasis(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SIMD3<Float> {
            let ciImage = CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: colorSpace)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

            guard let filter = CIFilter(name: "CITemperatureAndTint") else {
                return SIMD3<Float>(Float(r), Float(g), Float(b))
            }
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: CGFloat(temperature), y: CGFloat(tint)), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")

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
        sourceTexture = nil
    }

    // MARK: - Texture Pre-Caching

    /// Pre-render a CIImage to a Metal texture and cache it by URL.
    /// Call from a background task for adjacent images (prev/next).
    nonisolated func precacheTexture(for url: URL, ciImage: CIImage) {
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
        textureCache.setObject(MTLTextureWrapper(texture), forKey: url as NSURL)
    }

    /// Promote a pre-cached texture to sourceTexture. Returns true if cache hit.
    nonisolated func applyCachedTexture(for url: URL) -> Bool {
        guard let wrapper = textureCache.object(forKey: url as NSURL) else { return false }
        sourceTexture = wrapper.texture
        textureCache.removeObject(forKey: url as NSURL)
        return true
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

        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let width = Int(extent.width)
        let height = Int(extent.height)

        // Create ephemeral pipeline (isolated from preview pipeline)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalEditPipeline(device: device, commandQueue: queue) else {
            return nil
        }

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

        let translated = source.transformed(by: CGAffineTransform(
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

        // 2. Generate LUT and set parameters
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
        return noTonal && noVibrance && noSaturation && noWB && noMasks
    }
}
