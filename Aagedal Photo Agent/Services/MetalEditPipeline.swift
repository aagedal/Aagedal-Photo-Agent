import Accelerate
import CoreImage
import Metal
import os
import QuartzCore
import simd

nonisolated(unsafe) private let metalPipelineLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "MetalEditPipeline"
)

/// Uniform buffer layout matching the Metal `EditParams` struct.
/// Contains all edit operations: tonal (via LUT), vibrance, saturation, white balance.
struct EditParams {
    var exposure: Float = 0    // Legacy field kept for layout stability (baked into LUT)
    var vibrance: Float = 0
    var saturation: Float = 1
    var pad0: Float = 0

    var whiteBalanceMatrix: simd_float3x3 = matrix_identity_float3x3

    var activeFlags: UInt32 = 0
    var _pad1: UInt32 = 0 // align to 8 bytes for SIMD2<Float>

    var scale: SIMD2<Float> = .zero
    var sourceSize: SIMD2<Float> = .zero
    var drawableSize: SIMD2<Float> = .zero

    var lutDomainMin: Float = ToneCurveGenerator.domainMin
    var lutDomainMax: Float = ToneCurveGenerator.domainMax
}

/// Manages the Metal compute pipeline for real-time edit preview.
///
/// Handles ALL edit operations via a unified shader: tonal adjustments through a 1D LUT
/// (Exposure, Contrast, Blacks, Shadows, Highlights, Whites), plus vibrance, saturation,
/// and white balance. The LUT is regenerated on every slider change (~microseconds).
final class MetalEditPipeline: @unchecked Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState

    nonisolated(unsafe) private var sourceTexture: MTLTexture?
    nonisolated(unsafe) private var paramsBuffer: MTLBuffer?
    nonisolated(unsafe) private var lutTexture: MTLTexture?
    nonisolated(unsafe) private let identityLutTexture: MTLTexture

    nonisolated(unsafe) private static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private let ciContext: CIContext

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

    init?(device: MTLDevice, commandQueue: MTLCommandQueue) {
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

        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: Self.colorSpace,
        ])
        self.paramsBuffer = device.makeBuffer(length: MemoryLayout<EditParams>.stride, options: .storageModeShared)

        // Create a 2-entry identity LUT: maps input → input (linear ramp from domainMin to domainMax).
        // Always bound at texture index 2 to avoid Metal validation errors on unbound textures.
        let identityDesc = MTLTextureDescriptor()
        identityDesc.textureType = .type1D
        identityDesc.pixelFormat = .r16Float
        identityDesc.width = 2
        identityDesc.usage = .shaderRead
        identityDesc.storageMode = .shared
        guard let identityTex = device.makeTexture(descriptor: identityDesc) else { return nil }
        var identityData = Self.floatsToHalfs([ToneCurveGenerator.domainMin, ToneCurveGenerator.domainMax])
        identityTex.replace(region: MTLRegionMake1D(0, 2), mipmapLevel: 0,
                            withBytes: &identityData, bytesPerRow: 2 * MemoryLayout<UInt16>.size)
        self.identityLutTexture = identityTex
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

    /// Uploads a 4096-entry LUT as a 1D r16Float Metal texture (~8KB).
    nonisolated private func uploadLUT(_ data: [Float]) {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D
        desc.pixelFormat = .r16Float
        desc.width = data.count
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else { return }

        var float16Data = Self.floatsToHalfs(data)
        texture.replace(
            region: MTLRegionMake1D(0, data.count),
            mipmapLevel: 0,
            withBytes: &float16Data,
            bytesPerRow: data.count * MemoryLayout<UInt16>.size
        )

        lutTexture = texture
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

        // 1. Tone LUT — combines exposure, contrast, blacks, shadows, highlights, whites
        if !ToneCurveGenerator.isIdentity(settings: settings) {
            let lutData = ToneCurveGenerator.generateLUT(settings: settings)
            uploadLUT(lutData)
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

        params.activeFlags = flags
        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee = params

        let elapsed = ContinuousClock.now - start
        if elapsed > .milliseconds(1) {
            metalPipelineLog.debug("updateParams: \(elapsed) (flags: \(flags))")
        }
    }

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
        encoder.setTexture(lutTexture ?? identityLutTexture, index: 2)
        encoder.setBuffer(buffer, offset: 0, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width: Int(dstW),
            height: Int(dstH),
            depth: 1
        )
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)

        encoder.endEncoding()
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
            ciContext.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
            return SIMD3<Float>(pixel[0], pixel[1], pixel[2])
        }

        let colR = renderBasis(1, 0, 0)
        let colG = renderBasis(0, 1, 0)
        let colB = renderBasis(0, 0, 1)

        return simd_float3x3(colR, colG, colB)
    }

    nonisolated func clearSourceTexture() {
        sourceTexture = nil
    }
}
