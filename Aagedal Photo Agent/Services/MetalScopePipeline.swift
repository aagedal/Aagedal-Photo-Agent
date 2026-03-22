import Metal
import os
import QuartzCore

nonisolated(unsafe) private let scopePipelineLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "MetalScopePipeline"
)

/// Swift-side mirror of the Metal `ScopeParams` struct.
struct ScopeParams {
    var outputWidth: UInt32 = 0
    var outputHeight: UInt32 = 0
    var dataWidth: UInt32 = 0
    var levels: UInt32 = 0
    var labelMargin: UInt32 = 0
    var verticalMargin: UInt32 = 0
    var sampleWidth: UInt32 = 0
    var sampleHeight: UInt32 = 0
    var scaleMode: UInt32 = 0
    var channelCount: UInt32 = 0
    var channelWidth: UInt32 = 0
    var channelGap: UInt32 = 0
}

/// Manages Metal compute pipelines for real-time scope rendering (waveform, parade, vectorscope).
///
/// Reads from MetalEditPipeline's shared source texture and edit params to avoid
/// GPU→CPU readback. Renders scope at 720×720 to an intermediate texture, then
/// blits to the drawable at whatever size the MTKView provides.
final class MetalScopePipeline: @unchecked Sendable {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Compute pipeline states
    private let waveformAccumulateState: MTLComputePipelineState
    private let paradeAccumulateState: MTLComputePipelineState
    private let vectorscopeAccumulateState: MTLComputePipelineState
    private let waveformRenderState: MTLComputePipelineState
    private let paradeRenderState: MTLComputePipelineState
    private let vectorscopeRenderState: MTLComputePipelineState
    private let findMaxCountState: MTLComputePipelineState

    // Render pipeline for blit
    private let blitPipelineState: MTLRenderPipelineState

    // Buffers
    nonisolated(unsafe) private let binBuffer: MTLBuffer
    nonisolated(unsafe) private let scopeParamsBuffer: MTLBuffer
    nonisolated(unsafe) private let maxCountBuffer: MTLBuffer
    nonisolated(unsafe) private let binCountBuffer: MTLBuffer

    // Output texture (720×720, reused)
    nonisolated(unsafe) private(set) var outputTexture: MTLTexture

    private let outputSize: Int = 720

    /// Reference size the layout constants were designed for.
    private static nonisolated let refSize: Float = 720

    nonisolated init?(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary() else {
            scopePipelineLog.error("MetalScopePipeline: no default Metal library")
            return nil
        }

        // Compute pipeline states
        guard let wfAccum = library.makeFunction(name: "waveformAccumulate"),
              let parAccum = library.makeFunction(name: "paradeAccumulate"),
              let vsAccum = library.makeFunction(name: "vectorscopeAccumulate"),
              let wfRender = library.makeFunction(name: "waveformRender"),
              let parRender = library.makeFunction(name: "paradeRender"),
              let vsRender = library.makeFunction(name: "vectorscopeRender"),
              let findMax = library.makeFunction(name: "scopeFindMaxCount"),
              let blitVert = library.makeFunction(name: "scopeBlitVertex"),
              let blitFrag = library.makeFunction(name: "scopeBlitFragment")
        else {
            scopePipelineLog.error("MetalScopePipeline: missing shader functions")
            return nil
        }

        do {
            self.waveformAccumulateState = try device.makeComputePipelineState(function: wfAccum)
            self.paradeAccumulateState = try device.makeComputePipelineState(function: parAccum)
            self.vectorscopeAccumulateState = try device.makeComputePipelineState(function: vsAccum)
            self.waveformRenderState = try device.makeComputePipelineState(function: wfRender)
            self.paradeRenderState = try device.makeComputePipelineState(function: parRender)
            self.vectorscopeRenderState = try device.makeComputePipelineState(function: vsRender)
            self.findMaxCountState = try device.makeComputePipelineState(function: findMax)
        } catch {
            scopePipelineLog.error("MetalScopePipeline: compute pipeline error: \(error)")
            return nil
        }

        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = blitVert
        blitDesc.fragmentFunction = blitFrag
        blitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.blitPipelineState = try device.makeRenderPipelineState(descriptor: blitDesc)
        } catch {
            scopePipelineLog.error("MetalScopePipeline: blit pipeline error: \(error)")
            return nil
        }

        // Allocate buffers — sized for worst case (vectorscope: 720×720 × 4 sections)
        let maxBinBytes = outputSize * outputSize * 4 * MemoryLayout<UInt32>.size
        guard let binBuf = device.makeBuffer(length: maxBinBytes, options: .storageModeShared),
              let paramsBuf = device.makeBuffer(length: MemoryLayout<ScopeParams>.stride, options: .storageModeShared),
              let maxBuf = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let binCountBuf = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        else {
            scopePipelineLog.error("MetalScopePipeline: buffer allocation failed")
            return nil
        }
        self.binBuffer = binBuf
        self.scopeParamsBuffer = paramsBuf
        self.maxCountBuffer = maxBuf
        self.binCountBuffer = binCountBuf

        // Output texture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: outputSize,
            height: outputSize,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead, .shaderWrite]
        texDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: texDesc) else {
            scopePipelineLog.error("MetalScopePipeline: output texture creation failed")
            return nil
        }
        self.outputTexture = outTex
    }

    // MARK: - Public Render

    /// Renders scope to drawable. Reads source texture and edit params from the edit pipeline.
    /// All GPU work is encoded in a single command buffer (no CPU waits).
    nonisolated func renderToDrawable(
        sourceTexture: MTLTexture,
        editParamsBuffer: MTLBuffer,
        lutTexture: MTLTexture,
        mode: ScopeViewModel.ScopeMode,
        scale: WaveformScale,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let outW = UInt32(outputSize)
        let outH = UInt32(outputSize)
        let srcAspect = Float(sourceTexture.height) / Float(sourceTexture.width)

        // Layout metrics (matches CPU ScopeRenderService)
        let scaleF = Float(outW) / Self.refSize
        let labelMargin = UInt32(max(68 * scaleF, 24))
        let verticalMargin = UInt32(max(16 * scaleF, 4))
        let dataWidth = outW - labelMargin

        var params = ScopeParams()
        params.outputWidth = outW
        params.outputHeight = outH
        params.labelMargin = labelMargin
        params.verticalMargin = verticalMargin
        params.levels = outH
        params.scaleMode = scale == .nits ? 1 : 0

        switch mode {
        case .waveform:
            params.dataWidth = dataWidth
            params.sampleWidth = dataWidth
            params.sampleHeight = UInt32(max(Float(dataWidth) * srcAspect, 1))
            return encodeWaveform(commandBuffer: commandBuffer, params: params,
                                 sourceTexture: sourceTexture, editParamsBuffer: editParamsBuffer,
                                 lutTexture: lutTexture, drawable: drawable, drawableSize: drawableSize)

        case .parade:
            let channelCount: UInt32 = 4
            let gap: UInt32 = 2
            let totalGaps = gap * (channelCount - 1)
            let channelW = (dataWidth - totalGaps) / channelCount
            params.dataWidth = dataWidth
            params.channelWidth = channelW
            params.channelGap = gap
            params.channelCount = channelCount
            params.sampleWidth = channelW
            params.sampleHeight = UInt32(max(Float(channelW) * srcAspect, 1))
            return encodeParade(commandBuffer: commandBuffer, params: params,
                               sourceTexture: sourceTexture, editParamsBuffer: editParamsBuffer,
                               lutTexture: lutTexture, drawable: drawable, drawableSize: drawableSize)

        case .vectorscope:
            let workSize = UInt32(min(min(outW, outH), 360))
            params.sampleWidth = workSize
            params.sampleHeight = UInt32(max(Float(workSize) * srcAspect, 1))
            return encodeVectorscope(commandBuffer: commandBuffer, params: params,
                                    sourceTexture: sourceTexture, editParamsBuffer: editParamsBuffer,
                                    lutTexture: lutTexture, drawable: drawable, drawableSize: drawableSize)
        }
    }

    // MARK: - Waveform

    private nonisolated func encodeWaveform(
        commandBuffer: MTLCommandBuffer,
        params: ScopeParams,
        sourceTexture: MTLTexture,
        editParamsBuffer: MTLBuffer,
        lutTexture: MTLTexture,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) -> Bool {
        let binCount = Int(params.dataWidth * params.levels)
        let binBufferSize = binCount * 4 * MemoryLayout<UInt32>.size  // counts + 3 color channels

        // Write scope params
        let paramsPtr = scopeParamsBuffer.contents().bindMemory(to: ScopeParams.self, capacity: 1)
        paramsPtr.pointee = params

        // Step 1: Clear bins + maxCount
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.fill(buffer: binBuffer, range: 0..<binBufferSize, value: 0)
        blit.fill(buffer: maxCountBuffer, range: 0..<MemoryLayout<UInt32>.size, value: 0)
        blit.endEncoding()

        // Step 2: Accumulate
        guard let accum = commandBuffer.makeComputeCommandEncoder() else { return false }
        accum.setComputePipelineState(waveformAccumulateState)
        accum.setTexture(sourceTexture, index: 0)
        accum.setTexture(lutTexture, index: 1)
        accum.setBuffer(binBuffer, offset: 0, index: 0)
        accum.setBuffer(editParamsBuffer, offset: 0, index: 1)
        accum.setBuffer(scopeParamsBuffer, offset: 0, index: 2)
        let accumGrid = MTLSize(width: Int(params.sampleWidth), height: Int(params.sampleHeight), depth: 1)
        let accumTG = MTLSize(width: 16, height: 16, depth: 1)
        accum.dispatchThreads(accumGrid, threadsPerThreadgroup: accumTG)
        accum.endEncoding()

        // Step 3: Find max count
        encodeFindMax(commandBuffer: commandBuffer, binCount: binCount)

        // Step 4: Render to output texture
        guard let render = commandBuffer.makeComputeCommandEncoder() else { return false }
        render.setComputePipelineState(waveformRenderState)
        render.setTexture(outputTexture, index: 0)
        render.setBuffer(binBuffer, offset: 0, index: 0)
        render.setBuffer(scopeParamsBuffer, offset: 0, index: 1)
        render.setBuffer(maxCountBuffer, offset: 0, index: 2)
        let renderGrid = MTLSize(width: Int(params.outputWidth), height: Int(params.outputHeight), depth: 1)
        render.dispatchThreads(renderGrid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        render.endEncoding()

        // Step 5: Blit to drawable
        return encodeBlitToDrawable(commandBuffer: commandBuffer, drawable: drawable, drawableSize: drawableSize)
    }

    // MARK: - Parade

    private nonisolated func encodeParade(
        commandBuffer: MTLCommandBuffer,
        params: ScopeParams,
        sourceTexture: MTLTexture,
        editParamsBuffer: MTLBuffer,
        lutTexture: MTLTexture,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) -> Bool {
        let channelBinCount = Int(params.channelWidth * params.levels)
        let binBufferSize = channelBinCount * 4 * MemoryLayout<UInt32>.size  // 4 channels

        let paramsPtr = scopeParamsBuffer.contents().bindMemory(to: ScopeParams.self, capacity: 1)
        paramsPtr.pointee = params

        // Step 1: Clear
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.fill(buffer: binBuffer, range: 0..<binBufferSize, value: 0)
        blit.fill(buffer: maxCountBuffer, range: 0..<MemoryLayout<UInt32>.size, value: 0)
        blit.endEncoding()

        // Step 2: Accumulate
        guard let accum = commandBuffer.makeComputeCommandEncoder() else { return false }
        accum.setComputePipelineState(paradeAccumulateState)
        accum.setTexture(sourceTexture, index: 0)
        accum.setTexture(lutTexture, index: 1)
        accum.setBuffer(binBuffer, offset: 0, index: 0)
        accum.setBuffer(editParamsBuffer, offset: 0, index: 1)
        accum.setBuffer(scopeParamsBuffer, offset: 0, index: 2)
        let accumGrid = MTLSize(width: Int(params.channelWidth), height: Int(params.sampleHeight), depth: 1)
        accum.dispatchThreads(accumGrid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        accum.endEncoding()

        // Step 3: Find max (across all 4 channel bins)
        encodeFindMax(commandBuffer: commandBuffer, binCount: channelBinCount * 4)

        // Step 4: Render
        guard let render = commandBuffer.makeComputeCommandEncoder() else { return false }
        render.setComputePipelineState(paradeRenderState)
        render.setTexture(outputTexture, index: 0)
        render.setBuffer(binBuffer, offset: 0, index: 0)
        render.setBuffer(scopeParamsBuffer, offset: 0, index: 1)
        render.setBuffer(maxCountBuffer, offset: 0, index: 2)
        let renderGrid = MTLSize(width: Int(params.outputWidth), height: Int(params.outputHeight), depth: 1)
        render.dispatchThreads(renderGrid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        render.endEncoding()

        return encodeBlitToDrawable(commandBuffer: commandBuffer, drawable: drawable, drawableSize: drawableSize)
    }

    // MARK: - Vectorscope

    private nonisolated func encodeVectorscope(
        commandBuffer: MTLCommandBuffer,
        params: ScopeParams,
        sourceTexture: MTLTexture,
        editParamsBuffer: MTLBuffer,
        lutTexture: MTLTexture,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) -> Bool {
        let pixelCount = Int(params.outputWidth * params.outputHeight)
        let binBufferSize = pixelCount * 4 * MemoryLayout<UInt32>.size

        let paramsPtr = scopeParamsBuffer.contents().bindMemory(to: ScopeParams.self, capacity: 1)
        paramsPtr.pointee = params

        // Step 1: Clear
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.fill(buffer: binBuffer, range: 0..<binBufferSize, value: 0)
        blit.fill(buffer: maxCountBuffer, range: 0..<MemoryLayout<UInt32>.size, value: 0)
        blit.endEncoding()

        // Step 2: Accumulate
        guard let accum = commandBuffer.makeComputeCommandEncoder() else { return false }
        accum.setComputePipelineState(vectorscopeAccumulateState)
        accum.setTexture(sourceTexture, index: 0)
        accum.setTexture(lutTexture, index: 1)
        accum.setBuffer(binBuffer, offset: 0, index: 0)
        accum.setBuffer(editParamsBuffer, offset: 0, index: 1)
        accum.setBuffer(scopeParamsBuffer, offset: 0, index: 2)
        let accumGrid = MTLSize(width: Int(params.sampleWidth), height: Int(params.sampleHeight), depth: 1)
        accum.dispatchThreads(accumGrid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        accum.endEncoding()

        // Step 3: Find max
        encodeFindMax(commandBuffer: commandBuffer, binCount: pixelCount)

        // Step 4: Render
        guard let render = commandBuffer.makeComputeCommandEncoder() else { return false }
        render.setComputePipelineState(vectorscopeRenderState)
        render.setTexture(outputTexture, index: 0)
        render.setBuffer(binBuffer, offset: 0, index: 0)
        render.setBuffer(scopeParamsBuffer, offset: 0, index: 1)
        render.setBuffer(maxCountBuffer, offset: 0, index: 2)
        let renderGrid = MTLSize(width: Int(params.outputWidth), height: Int(params.outputHeight), depth: 1)
        render.dispatchThreads(renderGrid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        render.endEncoding()

        return encodeBlitToDrawable(commandBuffer: commandBuffer, drawable: drawable, drawableSize: drawableSize)
    }

    // MARK: - Shared Encode Helpers

    private nonisolated func encodeFindMax(commandBuffer: MTLCommandBuffer, binCount: Int) {
        let binCountPtr = binCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1)
        binCountPtr.pointee = UInt32(binCount)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(findMaxCountState)
        encoder.setBuffer(binBuffer, offset: 0, index: 0)
        encoder.setBuffer(maxCountBuffer, offset: 0, index: 1)
        encoder.setBuffer(binCountBuffer, offset: 0, index: 2)
        let tgSize = MTLSize(width: 256, height: 1, depth: 1)
        let gridSize = MTLSize(width: ((binCount + 255) / 256) * 256, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
    }

    private nonisolated func encodeBlitToDrawable(
        commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable,
        drawableSize: CGSize
    ) -> Bool {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return false }
        encoder.setRenderPipelineState(blitPipelineState)
        encoder.setFragmentTexture(outputTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }
}
