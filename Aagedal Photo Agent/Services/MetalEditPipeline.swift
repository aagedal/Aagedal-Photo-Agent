import Accelerate
import CoreImage
import Metal
import MetalKit
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
    var activeFlags: UInt32 = 0  // bit8=anonymizer, bit9=temperature, bit10=tint; see EditAdjustments.metal MaskParams
    var anonymizerAmount: Float = 0
    var anonymizerBlackOut: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var cornerRadius: Float = 1 // 1 = ACR ellipse, 0 = Photo Agent rectangle
    var maskType: UInt32 = 0   // 0 = ellipse, 1 = raster alpha, 2 = full-frame
    var brushLayer: UInt32 = 0 // slice into the brush alpha array (maskType == 1 only)
}

/// GPU brush-dab parameters matching the Metal `BrushDabParams` struct. One dispatch per dab,
/// uploaded via `setBytes` (not a shared buffer) so consecutive dabs in one command buffer
/// don't alias each other's parameters.
struct BrushDabParams {
    var center: SIMD2<Float> = .zero
    var radiusPx: Float = 0
    var hardness: Float = 0.5
    var flow: Float = 1.0
    var density: Float = 1.0
    var erase: UInt32 = 0
    var layer: UInt32 = 0
    var originPx: SIMD2<UInt32> = .zero
}

/// One slice in the shared raster-alpha array. Brush strokes and AI-selected subject mattes use
/// the same downstream sampling path; they differ only in how a slice is populated.
nonisolated enum MaskAlphaSource: Sendable, Equatable {
    case brush(BrushMaskGeometry)
    case ai(AIMaskGeometry)
}

nonisolated struct ParsedCubeLUT: Sendable, Equatable {
    var title: String?
    var size: Int
    var domainMin: SIMD3<Float>
    var domainMax: SIMD3<Float>
    /// IRIDAS/Resolve `.cube` ordering: red changes fastest, then green, then blue.
    var values: [SIMD3<Float>]

    func value(red: Int, green: Int, blue: Int) -> SIMD3<Float> {
        values[red + green * size + blue * size * size]
    }

    /// Resamples arbitrary supported cube dimensions into the pipeline's fixed-size texture.
    /// Each returned item is one blue-axis slice containing RGBA floats in row-major red/green.
    func resampledSlices(size outputSize: Int) -> [[Float]] {
        let sourceMax = Float(size - 1)
        let outputMax = Float(max(outputSize - 1, 1))
        var slices: [[Float]] = []
        slices.reserveCapacity(outputSize)
        for blue in 0..<outputSize {
            var slice = [Float](repeating: 0, count: outputSize * outputSize * 4)
            let bz = Float(blue) / outputMax * sourceMax
            let b0 = min(Int(floor(bz)), size - 1)
            let b1 = min(b0 + 1, size - 1)
            let bt = bz - Float(b0)
            for green in 0..<outputSize {
                let gy = Float(green) / outputMax * sourceMax
                let g0 = min(Int(floor(gy)), size - 1)
                let g1 = min(g0 + 1, size - 1)
                let gt = gy - Float(g0)
                for red in 0..<outputSize {
                    let rx = Float(red) / outputMax * sourceMax
                    let r0 = min(Int(floor(rx)), size - 1)
                    let r1 = min(r0 + 1, size - 1)
                    let rt = rx - Float(r0)
                    func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
                        a + (b - a) * t
                    }
                    let c00 = mix(value(red: r0, green: g0, blue: b0),
                                  value(red: r1, green: g0, blue: b0), rt)
                    let c10 = mix(value(red: r0, green: g1, blue: b0),
                                  value(red: r1, green: g1, blue: b0), rt)
                    let c01 = mix(value(red: r0, green: g0, blue: b1),
                                  value(red: r1, green: g0, blue: b1), rt)
                    let c11 = mix(value(red: r0, green: g1, blue: b1),
                                  value(red: r1, green: g1, blue: b1), rt)
                    let result = mix(mix(c00, c10, gt), mix(c01, c11, gt), bt)
                    let offset = (green * outputSize + red) * 4
                    slice[offset] = result.x
                    slice[offset + 1] = result.y
                    slice[offset + 2] = result.z
                    slice[offset + 3] = 1
                }
            }
            slices.append(slice)
        }
        return slices
    }
}

nonisolated enum CubeLUTParser {
    enum ParseError: LocalizedError {
        case notUTF8
        case missingSize
        case unsupportedSize(Int)
        case malformedDirective(String)
        case wrongEntryCount(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .notUTF8: return "The LUT is not a UTF-8 .cube file."
            case .missingSize: return "The LUT has no LUT_3D_SIZE directive."
            case .unsupportedSize(let size): return "The LUT size \(size) is unsupported (2…65 expected)."
            case .malformedDirective(let line): return "Malformed LUT directive: \(line)"
            case .wrongEntryCount(let expected, let actual):
                return "The LUT contains \(actual) color rows; \(expected) were expected."
            }
        }
    }

    static func parse(_ data: Data) throws -> ParsedCubeLUT {
        guard data.count <= 8_000_000, let text = String(data: data, encoding: .utf8) else {
            throw ParseError.notUTF8
        }
        var title: String?
        var size: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var values: [SIMD3<Float>] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1).first ?? rawLine[...]
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE":
                if let firstQuote = line.firstIndex(of: "\""),
                   let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote {
                    title = String(line[line.index(after: firstQuote)..<lastQuote])
                }
            case "LUT_3D_SIZE":
                guard parts.count == 2, let parsed = Int(parts[1]) else {
                    throw ParseError.malformedDirective(line)
                }
                guard (2...65).contains(parsed) else { throw ParseError.unsupportedSize(parsed) }
                size = parsed
                values.reserveCapacity(parsed * parsed * parsed)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4,
                      let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]),
                      x.isFinite, y.isFinite, z.isFinite else {
                    throw ParseError.malformedDirective(line)
                }
                if first.uppercased() == "DOMAIN_MIN" {
                    domainMin = SIMD3<Float>(x, y, z)
                } else {
                    domainMax = SIMD3<Float>(x, y, z)
                }
            default:
                guard parts.count == 3,
                      let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]),
                      r.isFinite, g.isFinite, b.isFinite else {
                    // Ignore metadata directives this first implementation doesn't consume.
                    if first.first?.isLetter == true { continue }
                    throw ParseError.malformedDirective(line)
                }
                values.append(SIMD3<Float>(r, g, b))
            }
        }

        guard let size else { throw ParseError.missingSize }
        let expected = size * size * size
        guard values.count == expected else {
            throw ParseError.wrongEntryCount(expected: expected, actual: values.count)
        }
        guard all(domainMax .> domainMin) else {
            throw ParseError.malformedDirective("DOMAIN_MAX must be greater than DOMAIN_MIN")
        }
        return ParsedCubeLUT(
            title: title,
            size: size,
            domainMin: domainMin,
            domainMax: domainMax,
            values: values
        )
    }
}

/// Parameters for scaling an AI mask PNG into one full-resolution alpha-array slice.
struct RasterMaskBlitParams {
    var layer: UInt32 = 0
    var rotationSteps: UInt32 = 0
}

/// Shared CPU/cursor description of the Gaussian radial profile implemented by `stampBrush`.
/// The nominal radius is the 50%-coverage circle. Lower hardness moves the full-strength inner
/// radius inward and lengthens the outer tail; rasterization clips only below 1/1024 coverage.
nonisolated enum BrushDabProfile {
    static let minimumAntialiasRadiusPixels = 0.5
    static let gaussianCutoffDistance = 3.1622776601683795 // sqrt(log2(1024))
    static let tenPercentGaussianDistance = 1.8226157288049947 // sqrt(log2(10))

    static func softnessRadius(nominalRadius: Double, hardness: Double) -> Double {
        let clampedHardness = min(max(hardness, 0), 1)
        return nominalRadius * (1 - clampedHardness)
    }

    static func innerRadius(nominalRadius: Double, hardness: Double) -> Double {
        nominalRadius - softnessRadius(nominalRadius: nominalRadius, hardness: hardness)
    }

    static func outerRadius(nominalRadius: Double, hardness: Double) -> Double {
        let softness = softnessRadius(nominalRadius: nominalRadius, hardness: hardness)
        guard softness > minimumAntialiasRadiusPixels else {
            return nominalRadius + minimumAntialiasRadiusPixels
        }
        return innerRadius(nominalRadius: nominalRadius, hardness: hardness)
            + gaussianCutoffDistance * softness
    }

    static func tenPercentRadius(nominalRadius: Double, hardness: Double) -> Double {
        let softness = softnessRadius(nominalRadius: nominalRadius, hardness: hardness)
        return innerRadius(nominalRadius: nominalRadius, hardness: hardness)
            + tenPercentGaussianDistance * softness
    }
}

/// GPU stroke-composite parameters matching the Metal `BrushCompositeParams` struct.
struct BrushCompositeParams {
    var layer: UInt32 = 0
    var erase: UInt32 = 0
    var originPx: SIMD2<UInt32> = .zero
}

/// GPU watermark-layer parameters matching the Metal `WatermarkParams` struct.
struct WatermarkParams {
    var center: SIMD2<Float> = .zero
    var halfExtent: SIMD2<Float> = .zero   // (0,0) = degenerate/missing asset; shader no-ops
    var opacity: Float = 1.0
    var textureLayer: UInt32 = 0
}

/// GPU overlay parameters matching the Metal `MaskOverlayParams` struct.
struct MaskOverlayParams {
    var center: SIMD2<Float> = .zero
    var radii: SIMD2<Float> = .zero
    var rotation: Float = 0
    var feather: Float = 0
    var cornerRadius: Float = 1
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
/// Contains all edit operations: tonal (via LUT), vibrance, saturation, density, white balance.
struct EditParams {
    var globalDensity: Float = 0
    var vibrance: Float = 0
    var saturation: Float = 1
    var gamutClipMode: UInt32 = 0

    var sharpness: Float = 0
    var clarity: Float = 0
    var dehaze: Float = 0
    var _padDetail: Float = 0

    var whiteBalanceMatrix: simd_float3x3 = matrix_identity_float3x3

    var activeFlags: UInt32 = 0  // bit0=toneLUT, bit1=vibrance, bit2=saturation, bit3=whiteBalance, bit4=hdrMode, bit5=anonymizer, bit6=globalDensity, bit7=sourceHeadroom, bit8=sharpness, bit9=clarity, bit10=dehaze
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

    // Number of entries in the layer-order buffer (buffer index 3). Each entry is either
    // `globalOrderSentinel` (run the global adjustment block) or a mask index into the mask
    // buffer. Drives the per-pixel processing sequence so the global node can be reordered
    // among the masks. Always ≥ 1 (the global node is always present).
    var orderCount: UInt32 = 0
    var anonymizerAmount: Float = 0   // 0-1 global slider strength, gated by activeFlags bit5
    var anonymizerBlackOut: Float = 0 // 0 or 1

    var maskOverlayIndex: Int32 = -1  // mask buffer index to visualize, or -1 = none
    var maskOverlayOpacity: Float = 0 // 0-1 red-tint strength (matte mode replaces the image)

    var watermarkCount: UInt32 = 0    // number of active watermark layers (0-4)
    var watermarkFrame: UInt32 = 0    // 0 = source UV, 1 = crop-output UV
    var useNearestNeighbor: UInt32 = 0
    var maskOverlayMode: UInt32 = 0   // 0 = red coverage tint, 1 = black/white matte

    // Multi-pass execution. `orderOffset` selects the first entry in the shared layer-order
    // buffer for this dispatch; `orderCount` above is the number of entries in this pass.
    // executionFlags: bit0=intermediate (skip output transforms/overlays),
    // bit1=input texture is in drawable/output coordinates,
    // bit2=render in the full source frame (identity viewport).
    var orderOffset: UInt32 = 0
    var executionFlags: UInt32 = 0
    var _padExecution0: UInt32 = 0
    var _padExecution1: UInt32 = 0

    var filmGrain: Float = 0
    var filmHalation: Float = 0
    var filmBloom: Float = 0
    var filmVignette: Float = 0
    var filmEdgeBlur: Float = 0
    var _padFilm0: Float = 0
    var _padFilm1: Float = 0
    var _padFilm2: Float = 0
}

/// One compute segment in the compiled edit graph. Adjacent pointwise layers share a segment;
/// an Anonymizer node is isolated because it samples neighboring pixels from the fully-rendered
/// output of every upstream segment.
nonisolated struct EditRenderPass: Sendable, Equatable {
    var orderOffset: Int
    var orderCount: Int
    var requiresMipmappedInput: Bool
}

/// Pure layer-order compiler kept separate from Metal resource management so ordering behavior
/// can be unit-tested without a GPU. The encoded order grammar matches `uploadLayerOrder`.
nonisolated enum EditRenderPassPlanner {
    static let globalOrderSentinel: UInt32 = 0xFFFF_FFFF
    static let watermarkOrderFlag: UInt32 = 0x8000_0000

    static func makePlan(
        orderEntries: [UInt32],
        globalSpatialEffectsActive: Bool,
        anonymizerMaskIndices: Set<Int>
    ) -> [EditRenderPass] {
        guard !orderEntries.isEmpty else { return [] }

        func isSpatial(_ entry: UInt32) -> Bool {
            if entry == globalOrderSentinel {
                return globalSpatialEffectsActive
            }
            guard entry & watermarkOrderFlag == 0 else { return false }
            return anonymizerMaskIndices.contains(Int(entry))
        }

        var result: [EditRenderPass] = []
        var pointwiseStart = 0
        for (index, entry) in orderEntries.enumerated() where isSpatial(entry) {
            if pointwiseStart < index {
                result.append(EditRenderPass(
                    orderOffset: pointwiseStart,
                    orderCount: index - pointwiseStart,
                    requiresMipmappedInput: false
                ))
            }
            result.append(EditRenderPass(
                orderOffset: index,
                orderCount: 1,
                requiresMipmappedInput: true
            ))
            pointwiseStart = index + 1
        }
        if pointwiseStart < orderEntries.count {
            result.append(EditRenderPass(
                orderOffset: pointwiseStart,
                orderCount: orderEntries.count - pointwiseStart,
                requiresMipmappedInput: false
            ))
        }
        return result
    }
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
    /// EXIF orientation baked into the source texture's pixels. Mask geometry
    /// arrives in the sensor (XMP) frame, so `updateParams` uses this to
    /// transform masks into the texture's display frame. Guarded by
    /// `sourceTextureLock` like the texture it describes.
    nonisolated(unsafe) private var _sourceOrientation: Int = 1

    nonisolated var sourceTexture: MTLTexture? {
        sourceTextureLock.withLock { _sourceTexture }
    }

    nonisolated var sourceOrientation: Int {
        sourceTextureLock.withLock { _sourceOrientation }
    }

    nonisolated private func setSourceTexture(_ value: MTLTexture?) {
        sourceTextureLock.withLock { _sourceTexture = value }
    }

    nonisolated private func setSourceOrientation(_ value: Int) {
        sourceTextureLock.withLock { _sourceOrientation = value }
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
    /// Layer-processing order (buffer index 3): a sequence of `orderCount` UInt32 entries,
    /// each either `globalOrderSentinel` or a mask index into `maskBuffer`. Populated by
    /// `updateParams` from `CameraRawSettings.resolvedLayerOrder()`.
    nonisolated(unsafe) private(set) var orderBuffer: MTLBuffer?
    /// Compiled compute segments for the currently uploaded order. A single entry retains the
    /// historical one-dispatch fast path; two or more entries use ping-pong intermediate
    /// textures so each spatial node samples the complete upstream composite.
    nonisolated(unsafe) private var renderPassPlan: [EditRenderPass] = []

    /// Gamut clipping mode for soft proof preview. 0=off, 1=sRGB, 2=P3, 3=Rec.2020.
    nonisolated(unsafe) var gamutClipMode: UInt32 = 0 {
        didSet { mirror?.gamutClipMode = gamutClipMode }
    }

    /// When set, `updateParams` red-tints this mask's coverage (ACR-style) so a freshly painted
    /// brush mask is visible before any adjustment. The kernel auto-hides it once the mask gains
    /// an adjustment. Set by the editor from selection / paint-mode state.
    nonisolated(unsafe) var maskOverlayMaskID: UUID? = nil

    /// When set, the selected mask replaces the editor image with a black/white coverage matte.
    /// This is intentionally not mirrored to the clean-feed pipeline: it is a transient editor
    /// hover aid rather than part of the rendered develop state.
    nonisolated(unsafe) var maskMattePreviewMaskID: UUID? = nil

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
    /// Every imported cube is CPU-resampled to this dimension, then packed into 33 consecutive
    /// slices of one 2D-array texture. This supports several independently ordered LUT nodes
    /// without declaring a variable number of Metal texture arguments.
    nonisolated static let colorLUTSize = 33
    /// Max simultaneous watermark layers (and, since each references one library asset,
    /// also the texture array's slice cap — fewer if several layers share one asset).
    nonisolated private static let maxWatermarks = 4
    /// Max layer-order entries: every mask, every watermark layer, plus the single global node.
    nonisolated private static let maxOrderEntries = maxMasks + maxWatermarks + 1
    /// Order-buffer entry meaning "run the global adjustment block here".
    nonisolated private static let globalOrderSentinel =
        EditRenderPassPlanner.globalOrderSentinel
    /// Order-buffer high bit meaning "the low 31 bits are a watermark-layer index", so a
    /// watermark entry and the global sentinel (which also has this bit set) stay
    /// distinguishable from a plain mask index (always < maxMasks). See EditAdjustments.metal.
    nonisolated private static let watermarkOrderFlag =
        EditRenderPassPlanner.watermarkOrderFlag
    nonisolated private static let executionIntermediate: UInt32 = 1 << 0
    nonisolated private static let executionInputInDrawableFrame: UInt32 = 1 << 1
    nonisolated private static let executionIdentitySourceFrame: UInt32 = 1 << 2

    // Overlay pipeline (mask overlay rendering)
    private let overlayPipelineState: MTLComputePipelineState?
    nonisolated(unsafe) private let overlayParamsBuffer: MTLBuffer?

    // Brush-mask rasterization (Phase 2). Optional — graceful degradation if the shaders are
    // missing, matching the overlay pipeline.
    private let stampBrushPipelineState: MTLComputePipelineState?
    private let clearBrushAlphaPipelineState: MTLComputePipelineState?
    private let clearBrushRegionPipelineState: MTLComputePipelineState?
    private let compositeBrushPipelineState: MTLComputePipelineState?
    private let blitRasterMaskPipelineState: MTLComputePipelineState?
    /// Single-slice scratch texture holding one stroke's coverage envelope during a rebuild:
    /// dabs are max-stamped here, then source-over composited into `brushAlphaTexture` so
    /// separate strokes accumulate. Lazily sized to match the alpha array.
    nonisolated(unsafe) private var brushEnvScratch: MTLTexture?
    /// Per-brush-mask alpha coverage: one `texture2d_array` R16Float slice per brush mask,
    /// lazily (re)built by `rebuildBrushAlpha`. Nil when there are no brush masks, so non-brush
    /// edits pay zero GPU memory (an unconditional 8-slice array at export resolution would be
    /// ~1-1.5GB). Sized to the render source so the compositing kernel (Phase 3) can sample it
    /// in source UV space. Not yet read by `editAdjustments` — wired in Phase 3.
    nonisolated(unsafe) private(set) var brushAlphaTexture: MTLTexture?
    /// A 1×1×1 zeroed R16Float array bound to `editAdjustments`' brush-alpha slot whenever there
    /// are no brush masks, so the kernel's `texture2d_array` argument is always satisfied (Metal
    /// requires every declared texture bound) — it's never sampled in that case (no mask sets
    /// maskType == 1).
    nonisolated(unsafe) private let emptyBrushAlpha: MTLTexture
    /// Cache guarding `refreshBrushAlpha`: the brush masks + resolution the current
    /// `brushAlphaTexture` was rasterized from. `updateParams` runs per slider drag, but strokes
    /// only change on paint/undo/image-load — comparing against this skips the full-res rebuild
    /// (a synchronous GPU rasterization) on every unrelated tonal edit.
    nonisolated(unsafe) private var lastBuiltMaskAlphaSources: [MaskAlphaSource] = []
    nonisolated(unsafe) private var lastBuiltBrushSize = MTLSize(width: 0, height: 0, depth: 0)

    // MARK: - Watermark layers

    /// Per-layer watermark parameters (buffer index 4) — center/halfExtent/opacity/textureLayer,
    /// up to `maxWatermarks` entries. Rewritten (cheaply) on every `updateParams`/
    /// `refreshWatermarkParams` call; the texture array behind it is only reloaded when the
    /// referenced asset IDs actually change (see `lastBuiltWatermarkAssetIDs`).
    nonisolated(unsafe) private(set) var watermarkParamsBuffer: MTLBuffer?
    /// Deduped-by-asset watermark texture array (texture index 4), one RGBA8 premultiplied
    /// slice per distinct library asset referenced by the active watermark layers. Nil when
    /// there are none, so non-watermark edits pay zero extra GPU memory.
    nonisolated(unsafe) private(set) var watermarkTexture: MTLTexture?
    /// A 1×1×1 fully-transparent placeholder bound to `editAdjustments`' watermark-texture slot
    /// whenever there are no active watermark layers, so the kernel's texture argument is
    /// always satisfied (mirrors `emptyBrushAlpha`).
    nonisolated(unsafe) private let emptyWatermarkTexture: MTLTexture
    /// Cache guarding the texture (re)decode in `loadWatermarkTextures`: the distinct asset IDs
    /// the current `watermarkTexture` was built from.
    nonisolated(unsafe) private var lastBuiltWatermarkAssetIDs: [UUID] = []
    /// Per-asset (slice index, decoded aspect ratio) from the last texture build — reused by
    /// `refreshWatermarkParams` when the asset-ID cache above hits, so a position/size/opacity-only
    /// change doesn't force a redecode.
    nonisolated(unsafe) private var lastBuiltWatermarkAspects: [UUID: (slice: Int, aspect: Double)] = [:]
    /// Active display-frame watermark layers from the most recent params upload. Viewport-only
    /// changes do not call `updateParams`, so crop/uncrop viewport updates reuse these layers to
    /// recompute watermark sizes against the frame currently being displayed.
    nonisolated(unsafe) private var activeDisplayWatermarkLayers: [WatermarkLayer] = []
    nonisolated(unsafe) private var cachedWatermarkFrame: UInt32 = 0
    nonisolated(unsafe) private var cachedWatermarkImageSize = MTLSize(width: 0, height: 0, depth: 0)

    // MARK: - Color Transform layers

    /// Fixed 33³ LUT slots packed as `[mask slot × 33 blue slices]`. Identity data occupies
    /// slots without a valid imported cube, so malformed/missing LUTs safely no-op.
    nonisolated(unsafe) private(set) var colorLUTTexture: MTLTexture
    /// Cache of source cube payloads by mask-buffer slot. Avoids parsing and uploading ~2 MB
    /// while unrelated sliders are dragged.
    nonisolated(unsafe) private var lastBuiltColorLUTData: [Data?] =
        Array(repeating: nil, count: maxMasks)
    nonisolated(unsafe) private var parsedColorLUTs: [ParsedCubeLUT?] =
        Array(repeating: nil, count: maxMasks)

    nonisolated private static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Shared pipeline for offscreen (export) renders. Built once and reused so we don't
    /// rebuild the MTLDevice / CIContext / compute pipeline state (expensive — pipeline-state
    /// compilation alone can take hundreds of ms) on every exported image. The pipeline carries
    /// mutable per-render state (LUT, params buffer, cached WB matrix), so all renders are
    /// serialized on `offscreenRenderQueue`; that also bounds GPU memory during batch export by
    /// preventing many full-resolution textures from being live at once.
    nonisolated private static let sharedOffscreen: (device: MTLDevice, queue: MTLCommandQueue, pipeline: MetalEditPipeline)? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = MetalEditPipeline(device: device, commandQueue: queue) else {
            return nil
        }
        return (device, queue, pipeline)
    }()

    /// Dedicated serial queue that owns the shared offscreen pipeline. This replaces the
    /// old `NSLock`: serializing on a real, dedicated thread (rather than blocking whichever
    /// caller thread holds a lock across `waitUntilCompleted`) lets async callers `await`
    /// `renderOffscreenAsync` and *suspend* instead of blocking. A slow or stalled GPU wait
    /// can then never tie up — and exhaust — Swift concurrency's fixed-width cooperative
    /// thread pool, which was the cause of the freeze-on-rotate hang.
    nonisolated private static let offscreenRenderQueue = DispatchQueue(
        label: "com.aagedal.photo-agent.offscreen-render", qos: .userInitiated
    )

    /// Carries a non-Sendable `CIImage` across the render-queue hop. The render only reads the
    /// image and the box is never shared, so transferring the reference is safe.
    nonisolated private struct CIImageBox: @unchecked Sendable {
        let image: CIImage?
    }

    /// Thread-safe cancellation flag for `renderOffscreenAsync`. The serial queue runs FIFO, so
    /// a cancelled job (e.g. a prefetch the user navigated past) would otherwise still execute its
    /// full GPU render once it reached the head — letting a backlog of stale renders starve the
    /// foreground. Checking this flag when the job dequeues lets cancelled renders bail in µs.
    nonisolated private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

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

        // Brush-mask rasterization pipelines (optional — graceful degradation if missing).
        if let stampFunc = library.makeFunction(name: "stampBrush") {
            self.stampBrushPipelineState = try? device.makeComputePipelineState(function: stampFunc)
        } else {
            self.stampBrushPipelineState = nil
        }
        if let clearFunc = library.makeFunction(name: "clearBrushAlpha") {
            self.clearBrushAlphaPipelineState = try? device.makeComputePipelineState(function: clearFunc)
        } else {
            self.clearBrushAlphaPipelineState = nil
        }
        if let clearRegionFunc = library.makeFunction(name: "clearBrushRegion") {
            self.clearBrushRegionPipelineState = try? device.makeComputePipelineState(function: clearRegionFunc)
        } else {
            self.clearBrushRegionPipelineState = nil
        }
        if let compositeFunc = library.makeFunction(name: "compositeBrushStroke") {
            self.compositeBrushPipelineState = try? device.makeComputePipelineState(function: compositeFunc)
        } else {
            self.compositeBrushPipelineState = nil
        }
        if let blitFunc = library.makeFunction(name: "blitRasterMask") {
            self.blitRasterMaskPipelineState = try? device.makeComputePipelineState(function: blitFunc)
        } else {
            self.blitRasterMaskPipelineState = nil
        }

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
        self.orderBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride * Self.maxOrderEntries,
            options: .storageModeShared
        )
        self.watermarkParamsBuffer = device.makeBuffer(
            length: MemoryLayout<WatermarkParams>.stride * Self.maxWatermarks,
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

        // 1×1×1 zeroed brush-alpha placeholder (always-bound fallback; see property doc).
        let emptyBrushDesc = MTLTextureDescriptor()
        emptyBrushDesc.textureType = .type2DArray
        emptyBrushDesc.pixelFormat = .r16Float
        emptyBrushDesc.width = 1
        emptyBrushDesc.height = 1
        emptyBrushDesc.arrayLength = 1
        emptyBrushDesc.usage = .shaderRead
        emptyBrushDesc.storageMode = .shared
        guard let emptyBrushTex = device.makeTexture(descriptor: emptyBrushDesc) else { return nil }
        var zeroHalf: UInt16 = 0
        emptyBrushTex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0,
                              withBytes: &zeroHalf, bytesPerRow: MemoryLayout<UInt16>.size,
                              bytesPerImage: MemoryLayout<UInt16>.size)
        self.emptyBrushAlpha = emptyBrushTex

        // 1×1×1 fully-transparent watermark-texture placeholder (always-bound fallback; see
        // property doc). Zeroed — alpha 0 means applyWatermark's blend is a no-op even if a
        // stray order-buffer entry somehow pointed at it. Same sRGB-tagged format as the real
        // watermark texture array (see loadWatermarkTextures) so binding either one is valid
        // for the same shader texture argument.
        let emptyWatermarkDesc = MTLTextureDescriptor()
        emptyWatermarkDesc.textureType = .type2DArray
        emptyWatermarkDesc.pixelFormat = .rgba8Unorm_srgb
        emptyWatermarkDesc.width = 1
        emptyWatermarkDesc.height = 1
        emptyWatermarkDesc.arrayLength = 1
        emptyWatermarkDesc.usage = .shaderRead
        emptyWatermarkDesc.storageMode = .shared
        guard let emptyWatermarkTex = device.makeTexture(descriptor: emptyWatermarkDesc) else { return nil }
        var zeroRGBA: UInt32 = 0
        emptyWatermarkTex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0,
                                  withBytes: &zeroRGBA, bytesPerRow: MemoryLayout<UInt32>.size,
                                  bytesPerImage: MemoryLayout<UInt32>.size)
        self.emptyWatermarkTexture = emptyWatermarkTex

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

        let colorDesc = MTLTextureDescriptor()
        colorDesc.textureType = .type2DArray
        colorDesc.pixelFormat = .rgba16Float
        colorDesc.width = Self.colorLUTSize
        colorDesc.height = Self.colorLUTSize
        colorDesc.arrayLength = Self.maxMasks * Self.colorLUTSize
        colorDesc.usage = .shaderRead
        colorDesc.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDesc) else { return nil }
        self.colorLUTTexture = colorTexture
        for slot in 0..<Self.maxMasks {
            uploadIdentityColorLUT(slot: slot)
        }
    }

    // MARK: - Source Texture Upload

    /// Generates a full mip chain for a just-populated source texture, synchronously. The
    /// Anonymizer effect's mosaic/blur sampling fetches an explicit LOD (compute kernels have
    /// no implicit screen-space derivatives the way fragment shaders do), so every source
    /// texture the edit kernel might read from needs mips, not just level 0. Cheap relative to
    /// the CIContext render that just populated level 0 — a one-time cost per image load/export,
    /// not per frame.
    nonisolated private static func generateMipmaps(for texture: MTLTexture, commandQueue: MTLCommandQueue) {
        guard texture.mipmapLevelCount > 1,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Renders the source CIImage to an MTLTexture. Call once per image load (not per frame).
    /// `exifOrientation` is the orientation already baked into the CIImage's pixels —
    /// used by `updateParams` to transform sensor-frame mask geometry to match.
    nonisolated func uploadSourceImage(_ ciImage: CIImage, exifOrientation: Int = 1) {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let width = Int(extent.width)
        let height = Int(extent.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: true
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
        Self.generateMipmaps(for: texture, commandQueue: commandQueue)
        setSourceTexture(texture)
        setSourceOrientation(exifOrientation)
        // Share the same texture object with the clean-feed mirror (zero-copy).
        mirror?.setSourceTexture(texture)
        mirror?.setSourceOrientation(exifOrientation)
    }

    // MARK: - LUT Upload

    nonisolated private func uploadIdentityColorLUT(slot: Int) {
        let size = Self.colorLUTSize
        let maximum = Float(size - 1)
        for blue in 0..<size {
            var floats = [Float](repeating: 0, count: size * size * 4)
            for green in 0..<size {
                for red in 0..<size {
                    let offset = (green * size + red) * 4
                    floats[offset] = Float(red) / maximum
                    floats[offset + 1] = Float(green) / maximum
                    floats[offset + 2] = Float(blue) / maximum
                    floats[offset + 3] = 1
                }
            }
            var halfs = Self.floatsToHalfs(floats)
            colorLUTTexture.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                slice: slot * size + blue,
                withBytes: &halfs,
                bytesPerRow: size * 4 * MemoryLayout<UInt16>.size,
                bytesPerImage: size * size * 4 * MemoryLayout<UInt16>.size
            )
        }
    }

    /// Parses/resamples only changed `.cube` payloads and uploads them into the mask slot used
    /// by the layer-order buffer. Invalid data becomes identity; the UI reports validation errors
    /// before committing imports, but this defensive fallback also protects hand-edited XMP.
    nonisolated private func refreshColorLUTs(_ masks: [MaskAdjustment]) {
        for slot in 0..<Self.maxMasks {
            let data: Data? = masks.indices.contains(slot)
                && masks[slot].colorTransform?.mode == .lut
                ? masks[slot].colorTransform?.lutData
                : nil
            guard data != lastBuiltColorLUTData[slot] else { continue }
            lastBuiltColorLUTData[slot] = data
            parsedColorLUTs[slot] = nil
            guard let data else {
                uploadIdentityColorLUT(slot: slot)
                continue
            }
            do {
                let parsed = try CubeLUTParser.parse(data)
                parsedColorLUTs[slot] = parsed
                for (blue, floats) in parsed.resampledSlices(size: Self.colorLUTSize).enumerated() {
                    var halfs = Self.floatsToHalfs(floats)
                    colorLUTTexture.replace(
                        region: MTLRegionMake2D(0, 0, Self.colorLUTSize, Self.colorLUTSize),
                        mipmapLevel: 0,
                        slice: slot * Self.colorLUTSize + blue,
                        withBytes: &halfs,
                        bytesPerRow: Self.colorLUTSize * 4 * MemoryLayout<UInt16>.size,
                        bytesPerImage: Self.colorLUTSize * Self.colorLUTSize * 4
                            * MemoryLayout<UInt16>.size
                    )
                }
            } catch {
                metalPipelineLog.error("Invalid color LUT in slot \(slot): \(error.localizedDescription)")
                uploadIdentityColorLUT(slot: slot)
            }
        }
    }

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
            // No settings → the chain is just the (no-op) global node; drop any brush alpha
            // and watermark textures.
            refreshBrushAlpha([], size: MTLSize(width: 0, height: 0, depth: 0))
            refreshWatermarkParams([], imageSize: MTLSize(width: 0, height: 0, depth: 0))
            activeDisplayWatermarkLayers = []
            let orderEntries = uploadLayerOrder(
                [.global], maskIndexByID: [:], watermarkIndexByID: [:]
            )
            params.orderCount = UInt32(orderEntries.count)
            renderPassPlan = EditRenderPassPlanner.makePlan(
                orderEntries: orderEntries,
                globalSpatialEffectsActive: false,
                anonymizerMaskIndices: []
            )
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

        // 3.5. Global density
        if let density = settings.globalDensity, density != 0 {
            params.globalDensity = Float(min(max(Double(density) / 100.0, -1.0), 1.0))
            flags |= (1 << 6)
        }

        // 3.6. Detail. Sharpness follows ACR's 0...150 amount scale; Clarity and
        // Dehaze use the standard signed -100...100 scale.
        if let sharpness = settings.sharpness, sharpness != 0 {
            params.sharpness = Float(min(max(Double(sharpness) / 150.0, 0.0), 1.0))
            flags |= (1 << 8)
        }
        if let clarity = settings.clarity2012, clarity != 0 {
            params.clarity = Float(min(max(Double(clarity) / 100.0, -1.0), 1.0))
            flags |= (1 << 9)
        }
        if let dehaze = settings.dehaze, dehaze != 0 {
            params.dehaze = Float(min(max(Double(dehaze) / 100.0, -1.0), 1.0))
            flags |= (1 << 10)
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

        // Scene-referred RAW decodes retain values above SDR white. The shader applies their
        // SDR display roll-off only after the complete layer chain so later layers can recover
        // highlights raised by an earlier layer.
        if settings.sourceHasHDRHeadroom == true {
            flags |= (1 << 7)
        }

        // 6. Anonymizer (global) — multi-layer redaction effect or full Black Out.
        if let anon = settings.anonymizer, !anon.isEmpty {
            params.anonymizerAmount = Float(min(max((anon.amount ?? 0) / 100.0, 0.0), 1.0))
            params.anonymizerBlackOut = (anon.blackOut == true) ? 1.0 : 0.0
            flags |= (1 << 5)
        }

        if let film = settings.filmEmulation, !film.isEmpty {
            params.filmGrain = Float(min(max((film.grain ?? 0) / 100.0, 0.0), 1.0))
            params.filmHalation = Float(min(max((film.halation ?? 0) / 100.0, 0.0), 1.0))
            params.filmBloom = Float(min(max((film.bloom ?? 0) / 100.0, 0.0), 1.0))
            params.filmVignette = Float(min(max((film.vignette ?? 0) / 100.0, 0.0), 1.0))
            params.filmEdgeBlur = Float(min(max((film.edgeBlur ?? 0) / 100.0, 0.0), 1.0))
        }

        params.activeFlags = flags

        // 5. Local mask adjustments. Mask geometry is stored in the sensor (XMP)
        // frame; the source texture is display-oriented (decoders bake the
        // orientation in before upload) — transform here so every texture-backed
        // consumer gets oriented masks. The mirror forward below passes the
        // UNTRANSFORMED settings: the mirror transforms with its own state.
        let displaySettings: CameraRawSettings = {
            let orientation = sourceOrientation
            guard orientation > 1, let size = sourceTextureSize, size.height > 0 else { return settings }
            return settings
                .masksTransformedForDisplay(orientation: orientation, displayAspect: size.width / size.height)
                .watermarksTransformedForDisplay(orientation: orientation)
        }()
        // Analytic, raster, and full-frame adjustments participate together. Brush and AI masks
        // resolve coverage from a shared pre-rasterized alpha array (maskType 1);
        // ellipse/rounded-rectangle masks use the analytic SDF (0), and Secondary Globals use
        // exact full-frame coverage (2).
        let enabledMasks = displaySettings.localAdjustments?.filter { $0.enabled } ?? []
        var masks = enabledMasks
        // A muted mask normally has no GPU slot. Include the hovered matte target solely for
        // coverage visualization, while keeping it out of the processing-order map below so its
        // adjustments remain muted. Put it first so it remains previewable at the mask limit.
        if let previewID = maskMattePreviewMaskID,
           !masks.contains(where: { $0.id == previewID }),
           let previewMask = displaySettings.localAdjustments?.first(where: { $0.id == previewID }) {
            masks.insert(previewMask, at: 0)
        }
        let maskCount = min(masks.count, Self.maxMasks)
        params.maskCount = UInt32(maskCount)
        refreshColorLUTs(Array(masks.prefix(maskCount)))

        if maskCount > 0 {
            metalPipelineLog.debug("updateParams: \(maskCount) mask(s) active")
            for (i, m) in masks.prefix(maskCount).enumerated() {
                metalPipelineLog.debug("  mask[\(i)]: center=(\(m.geometry.centerX),\(m.geometry.centerY)) radii=(\(m.geometry.radiusX),\(m.geometry.radiusY)) feather=\(m.geometry.feather) exp=\(m.exposure ?? 0)")
            }
        }

        // Maps each enabled mask's UUID → its slot in the mask buffer, so the layer-order
        // build below can translate `.mask(id)` refs into GPU mask indices. Raster masks are
        // collected in the same iteration order so their `brushLayer` slice indices line up
        // with the shared alpha array rasterized below.
        var maskIndexByID: [UUID: Int] = [:]
        var enabledMaskIndexByID: [UUID: Int] = [:]
        var anonymizerMaskIndices = Set<Int>()
        var maskAlphaSources: [MaskAlphaSource] = []
        if maskCount > 0, let maskBuf = maskBuffer {
            let maskPtr = maskBuf.contents().bindMemory(to: MaskParams.self, capacity: Self.maxMasks)
            for i in 0..<maskCount {
                let mask = masks[i]
                maskIndexByID[mask.id] = i
                if mask.enabled { enabledMaskIndexByID[mask.id] = i }
                var mp = MaskParams()
                mp.center = SIMD2<Float>(Float(mask.geometry.centerX), Float(mask.geometry.centerY))
                mp.radii = SIMD2<Float>(Float(mask.geometry.radiusX), Float(mask.geometry.radiusY))
                mp.rotation = Float(mask.geometry.rotation * .pi / 180.0)
                mp.feather = Float(mask.geometry.feather / 100.0)
                mp.inverted = mask.inverted ? 1.0 : 0.0
                mp.amount = Float(mask.amount)
                mp.cornerRadius = Float(mask.geometry.normalizedCornerRadius)
                if let transform = mask.colorTransform {
                    mp.maskType = 3
                    mp.brushLayer = UInt32(i * Self.colorLUTSize)
                    mp.activeFlags = transform.mode == .lut ? 1 : 2
                    mp.temperature = Float(transform.inputSpace.gpuIndex)
                    mp.tint = Float(transform.outputSpace.gpuIndex)
                    if let cube = parsedColorLUTs[i] {
                        mp.center = SIMD2<Float>(cube.domainMin.x, cube.domainMin.y)
                        mp.rotation = cube.domainMin.z
                        mp.radii = SIMD2<Float>(cube.domainMax.x, cube.domainMax.y)
                        mp.feather = cube.domainMax.z
                    } else {
                        mp.center = .zero
                        mp.rotation = 0
                        mp.radii = SIMD2<Float>(repeating: 1)
                        mp.feather = 1
                    }
                    maskPtr[i] = mp
                    continue
                } else if mask.isFullFrame {
                    mp.maskType = 2
                } else if let brush = mask.brush {
                    mp.maskType = 1
                    mp.brushLayer = UInt32(maskAlphaSources.count)
                    maskAlphaSources.append(.brush(brush))
                } else if let aiMask = mask.aiMask, aiMask.isValid {
                    mp.maskType = 1
                    mp.brushLayer = UInt32(maskAlphaSources.count)
                    maskAlphaSources.append(.ai(aiMask))
                }

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
                if let anon = mask.anonymizer, !anon.isEmpty {
                    mp.anonymizerAmount = Float(min(max((anon.amount ?? 0) / 100.0, 0.0), 1.0))
                    mp.anonymizerBlackOut = (anon.blackOut == true) ? 1.0 : 0.0
                    maskFlags |= (1 << 8)
                    if mask.enabled {
                        anonymizerMaskIndices.insert(i)
                    }
                }
                if let temp = mask.temperature, temp != 0 {
                    mp.temperature = Float(min(max(temp / 100.0, -1.0), 1.0))
                    maskFlags |= (1 << 9)
                }
                if let tnt = mask.tint, tnt != 0 {
                    mp.tint = Float(min(max(tnt / 100.0, -1.0), 1.0))
                    maskFlags |= (1 << 10)
                }
                mp.activeFlags = maskFlags
                maskPtr[i] = mp
            }
        }

        // Rebuild the raster alpha array (cached — only when geometry/resolution changes) so the
        // compositing kernel can sample it. Sized to the source texture, which the kernel
        // samples in source UV space. The offscreen (export) pipeline has no persistent source
        // texture, so `sourceTextureSize` is nil there and it rebuilds explicitly at the working
        // resolution in `renderOffscreenSerial` instead.
        if let texSize = sourceTextureSize {
            refreshMaskAlpha(
                maskAlphaSources,
                size: MTLSize(width: Int(texSize.width), height: Int(texSize.height), depth: 1)
            )
        }

        // The hover matte takes precedence over the automatic red paint-coverage tint. Both use
        // the same selected-mask slot, with an explicit mode so the shader can either replace the
        // image with coverage or blend the legacy red overlay.
        if let previewID = maskMattePreviewMaskID, let idx = maskIndexByID[previewID] {
            params.maskOverlayIndex = Int32(idx)
            params.maskOverlayOpacity = 1
            params.maskOverlayMode = 1
        } else if let oid = maskOverlayMaskID, let idx = maskIndexByID[oid] {
            params.maskOverlayIndex = Int32(idx)
            params.maskOverlayOpacity = 0.5
            params.maskOverlayMode = 0
        } else {
            params.maskOverlayIndex = -1
            params.maskOverlayOpacity = 0
            params.maskOverlayMode = 0
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

        // 7. Watermark layers — app-only compositing, no ACR equivalent. Order-buffer slot
        // assignment happens unconditionally below (needed regardless of resolution); the
        // GPU-resident texture + geometry data is only refreshed here when a persistent source
        // texture size is already known (live preview). The offscreen/export path (no
        // persistent source texture at this point) assigns the same slots by iteration order
        // and lets `renderOffscreenSerial` call `refreshWatermarkParams` again explicitly once
        // its working resolution is known — mirroring `rebuildBrushAlpha`'s split exactly.
        let displayWatermarks = (displaySettings.watermarkLayers ?? []).filter(\.enabled)
        let activeWatermarks = Array(displayWatermarks.prefix(Self.maxWatermarks))
        activeDisplayWatermarkLayers = activeWatermarks
        params.watermarkCount = UInt32(activeWatermarks.count)
        params.watermarkFrame = cachedWatermarkFrame
        var watermarkIndexByID: [UUID: Int] = [:]
        if !activeWatermarks.isEmpty {
            if let texSize = sourceTextureSize {
                let watermarkSize = cachedWatermarkFrame == 1 && cachedWatermarkImageSize.width > 0 && cachedWatermarkImageSize.height > 0
                    ? cachedWatermarkImageSize
                    : MTLSize(width: Int(texSize.width), height: Int(texSize.height), depth: 1)
                watermarkIndexByID = refreshWatermarkParams(
                    activeWatermarks,
                    imageSize: watermarkSize
                )
            } else {
                for (i, layer) in activeWatermarks.enumerated() { watermarkIndexByID[layer.id] = i }
            }
        } else {
            refreshWatermarkParams([], imageSize: MTLSize(width: 0, height: 0, depth: 0))
        }

        // Build the processing order: interleave the global node among the masks and
        // watermark layers per the resolved layer order. Refs to disabled/overflow/missing
        // layers (absent from the index maps) are skipped; the global node is always present.
        let orderEntries = uploadLayerOrder(
            displaySettings.resolvedLayerOrder(),
            maskIndexByID: enabledMaskIndexByID,
            watermarkIndexByID: watermarkIndexByID
        )
        params.orderCount = UInt32(orderEntries.count)
        let globalAnonymizerActive = flags & (1 << 5) != 0
        let globalFilmSpatialActive = settings.filmEmulation?.hasSpatialEffects ?? false
        if globalAnonymizerActive,
           params.anonymizerBlackOut > 0.5,
           let globalIndex = orderEntries.firstIndex(of: EditRenderPassPlanner.globalOrderSentinel) {
            // Preserve the privacy guarantee of global Black Out: it is terminal and cannot
            // be lifted by a later tone curve, mask, or watermark.
            renderPassPlan = [EditRenderPass(
                orderOffset: globalIndex,
                orderCount: 1,
                requiresMipmappedInput: false
            )]
        } else {
            renderPassPlan = EditRenderPassPlanner.makePlan(
                orderEntries: orderEntries,
                globalSpatialEffectsActive: globalAnonymizerActive || globalFilmSpatialActive,
                anonymizerMaskIndices: anonymizerMaskIndices
            )
        }

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee = params
        ptr.pointee.gamutClipMode = gamutClipMode
        ptr.pointee.viewportOrigin = cachedViewportOrigin
        ptr.pointee.viewportSize = cachedViewportSize
        ptr.pointee.viewportCenter = cachedViewportCenter
        ptr.pointee.viewportRotation = cachedViewportRotation
        ptr.pointee.cropHalfExtent = cachedCropHalfExtent
        ptr.pointee.watermarkFrame = cachedWatermarkFrame

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

    /// Writes the layer-processing order into `orderBuffer` and returns the entry count.
    /// Each resolved `.global` becomes `globalOrderSentinel`; each `.mask(id)` becomes its GPU
    /// mask index via `maskIndexByID`; each `.watermark(id)` becomes its GPU watermark-params
    /// index via `watermarkIndexByID`, flagged with `watermarkOrderFlag` so the shader can tell
    /// it apart from a plain mask index (see EditAdjustments.metal's order-buffer encoding
    /// comment). Refs with no mapping — disabled or overflow layers — are skipped. Capped at
    /// `maxOrderEntries`.
    nonisolated private func uploadLayerOrder(
        _ resolved: [LayerRef],
        maskIndexByID: [UUID: Int],
        watermarkIndexByID: [UUID: Int]
    ) -> [UInt32] {
        guard let orderBuf = orderBuffer else { return [] }
        let ptr = orderBuf.contents().bindMemory(to: UInt32.self, capacity: Self.maxOrderEntries)
        var entries: [UInt32] = []
        entries.reserveCapacity(min(resolved.count, Self.maxOrderEntries))
        for ref in resolved where entries.count < Self.maxOrderEntries {
            let entry: UInt32
            switch ref {
            case .global:
                entry = Self.globalOrderSentinel
            case .mask(let id):
                guard let idx = maskIndexByID[id] else { continue }
                entry = UInt32(idx)
            case .watermark(let id):
                guard let idx = watermarkIndexByID[id] else { continue }
                entry = Self.watermarkOrderFlag | UInt32(idx)
            }
            ptr[entries.count] = entry
            entries.append(entry)
        }
        return entries
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
            params.cornerRadius = Float(geo.normalizedCornerRadius)
            params.visible = 1
        }
        let ptr = buffer.contents().bindMemory(to: MaskOverlayParams.self, capacity: 1)
        ptr.pointee = params
    }

    /// Whether the Metal overlay pipeline is available.
    nonisolated var hasOverlayPipeline: Bool { overlayPipelineState != nil }

    // MARK: - Brush Mask Rasterization (Phase 2)

    /// Whether the brush rasterization pipelines compiled.
    nonisolated var hasBrushPipeline: Bool {
        stampBrushPipelineState != nil && clearBrushAlphaPipelineState != nil
            && clearBrushRegionPipelineState != nil && compositeBrushPipelineState != nil
            && blitRasterMaskPipelineState != nil
    }

    /// The pixel bounding box (originX, originY, width, height) a stroke's dabs cover, clipped to
    /// `size`, or nil if empty. Used to bound the per-stroke clear/composite dispatches so cost is
    /// the painted area, not the whole slice.
    nonisolated private static func strokeBoundingBox(_ stroke: BrushStroke, size: MTLSize) -> (Int, Int, Int, Int)? {
        let nominalRadius = Double(brushRadiusPixels(normalized: stroke.radius, size: size))
        guard nominalRadius > 0, !stroke.dabs.isEmpty else { return nil }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for dab in stroke.dabs {
            let cx = dab.x * Double(size.width), cy = dab.y * Double(size.height)
            let outerRadius = BrushDabProfile.outerRadius(
                nominalRadius: nominalRadius,
                hardness: dab.hardness
            )
            minX = min(minX, cx - outerRadius); minY = min(minY, cy - outerRadius)
            maxX = max(maxX, cx + outerRadius); maxY = max(maxY, cy + outerRadius)
        }
        let x0 = max(0, Int(minX.rounded(.down))), y0 = max(0, Int(minY.rounded(.down)))
        let x1 = min(size.width, Int(maxX.rounded(.up))), y1 = min(size.height, Int(maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// Converts a normalized brush radius (ACR `Radius`) into the nominal 50%-coverage radius
    /// in pixels for a texture of the given dimensions. The normalization reference is the long edge — self-consistent with
    /// `anonymizerBlockSize` and the other long-edge-relative sizing in the pipeline, which is
    /// what makes a stroke rebuild identically into a 1500px preview or a 9000px export texture.
    /// The absolute scale vs. Lightroom's own brush-size display is one of the two constants
    /// flagged for the Phase 6 calibration pass.
    nonisolated static func brushRadiusPixels(normalized radius: Double, size: MTLSize) -> Float {
        let longEdge = Double(max(size.width, size.height))
        return Float(radius * longEdge)
    }

    /// Builds the compact source texture for a refined AI matte. Levels are applied before blur:
    /// the endpoints first clean/fill Vision confidence values, then Gaussian blur softens the
    /// resulting contour. Processing remains at the stored mask's ≤1024 px resolution, so export
    /// only pays the existing one-sample scaling blit rather than a full-resolution blur.
    nonisolated private func refinedAIMaskTexture(_ mask: AIMaskGeometry) -> MTLTexture? {
        guard mask.isValid,
              var image = CIImage(data: mask.pngData, options: [.colorSpace: NSNull()])
        else { return nil }

        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        let black = mask.resolvedBlackPoint
        let white = max(mask.resolvedWhitePoint, black + 0.01)
        if black > 0.000001 || white < 0.999999 {
            let scale = CGFloat(1 / (white - black))
            let bias = CGFloat(-black) * scale
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ]).cropped(to: extent)
        }

        let blurPixels = CGFloat(mask.resolvedBlurRadius) * max(extent.width, extent.height)
        if blurPixels > 0.01 {
            image = image.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: blurPixels,
            ]).cropped(to: extent)
        }

        var bytes = [UInt8](repeating: 0, count: width * height)
        ciContext.render(
            image,
            toBitmap: &bytes,
            rowBytes: width,
            bounds: extent,
            format: .R8,
            colorSpace: nil
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }
        return texture
    }

    /// (Re)builds the shared raster alpha texture from brush strokes and AI matte PNGs, one array
    /// slice per raster mask. Brush dabs are stamped at the target resolution; AI masks are
    /// linearly scaled on-GPU from their compact persisted resolution. Not per-frame: callers use
    /// the cached wrapper below on geometry/resolution changes only.
    @discardableResult
    nonisolated func rebuildMaskAlpha(_ sources: [MaskAlphaSource], size: MTLSize) -> MTLTexture? {
        guard let stampState = stampBrushPipelineState,
              let clearState = clearBrushAlphaPipelineState,
              let clearRegionState = clearBrushRegionPipelineState,
              let compositeState = compositeBrushPipelineState,
              let blitState = blitRasterMaskPipelineState,
              !sources.isEmpty, size.width > 0, size.height > 0 else {
            brushAlphaTexture = nil
            return nil
        }
        let layers = min(sources.count, Self.maxMasks)

        // Lazily (re)allocate only when the slice count or resolution changes; otherwise reuse
        // the existing texture and just re-clear + re-stamp into it.
        let tex: MTLTexture
        if let existing = brushAlphaTexture,
           existing.width == size.width, existing.height == size.height,
           existing.arrayLength == layers {
            tex = existing
        } else {
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2DArray
            desc.pixelFormat = .r16Float
            desc.width = size.width
            desc.height = size.height
            desc.arrayLength = layers
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .shared
            guard let newTex = device.makeTexture(descriptor: desc) else {
                brushAlphaTexture = nil
                return nil
            }
            tex = newTex
        }

        // Single-slice envelope scratch, reused across strokes; (re)allocated to match `size`.
        let scratch: MTLTexture
        if let existing = brushEnvScratch, existing.width == size.width, existing.height == size.height {
            scratch = existing
        } else {
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2DArray
            desc.pixelFormat = .r16Float
            desc.width = size.width
            desc.height = size.height
            desc.arrayLength = 1
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .shared
            guard let newScratch = device.makeTexture(descriptor: desc) else { return nil }
            scratch = newScratch
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        // Clear every slice first. The default serial-dispatch encoder inserts a barrier between
        // dispatches, so the clear completes before the first stamp reads the alpha.
        encoder.setComputePipelineState(clearState)
        encoder.setTexture(tex, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: size.width, height: size.height, depth: layers),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )

        // Per stroke: build its coverage envelope in the scratch (dabs max-blended, so within a
        // stroke it's a flat cap at the stroke's flow), then source-over composite it into the
        // mask's slice — so separate strokes ACCUMULATE (clicking the same spot builds up) rather
        // than clamping at one stroke's flow. Bounded to each stroke's bbox to keep cost local.
        let stampTG = MTLSize(width: 16, height: 16, depth: 1)
        // The command encoder retains every source texture through completion. Keeping this
        // array alive until the synchronous wait also makes that lifetime explicit.
        var rasterSourceTextures: [MTLTexture] = []
        let textureLoader = MTKTextureLoader(device: device)
        for (layer, source) in sources.prefix(layers).enumerated() {
            switch source {
            case .ai(let mask):
                guard mask.isValid else { continue }
                let sourceTexture = mask.hasRefinements
                    ? refinedAIMaskTexture(mask)
                    : nil
                guard let sourceTexture = sourceTexture ?? (try? textureLoader.newTexture(
                    data: mask.pngData,
                    options: [
                        .SRGB: false,
                        .origin: MTKTextureLoader.Origin.topLeft,
                        .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    ]
                )) else { continue }
                rasterSourceTextures.append(sourceTexture)
                encoder.setComputePipelineState(blitState)
                encoder.setTexture(sourceTexture, index: 0)
                encoder.setTexture(tex, index: 1)
                var params = RasterMaskBlitParams(
                    layer: UInt32(layer),
                    rotationSteps: UInt32(ImageFile.rotationDelta(
                        from: mask.sourceOrientation,
                        to: mask.displayOrientation
                    ))
                )
                encoder.setBytes(&params, length: MemoryLayout<RasterMaskBlitParams>.stride, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: size.width, height: size.height, depth: 1),
                    threadsPerThreadgroup: stampTG
                )

            case .brush(let mask):
              for stroke in mask.strokes {
                guard let (bx, by, bw, bh) = Self.strokeBoundingBox(stroke, size: size) else { continue }
                var origin = SIMD2<UInt32>(UInt32(bx), UInt32(by))
                let bbox = MTLSize(width: bw, height: bh, depth: 1)

                // 1. Clear the scratch over this stroke's bbox.
                encoder.setComputePipelineState(clearRegionState)
                encoder.setTexture(scratch, index: 0)
                encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
                encoder.dispatchThreads(bbox, threadsPerThreadgroup: stampTG)

                // 2. Stamp the stroke's dabs into scratch slice 0 as a max envelope (forceAdd).
                encoder.setComputePipelineState(stampState)
                encoder.setTexture(scratch, index: 0)
                Self.encodeStroke(stroke, layer: 0, size: size, forceAdd: true, into: encoder)

                // 3. Source-over (or multiplicative-erase) composite scratch → alpha slice.
                encoder.setComputePipelineState(compositeState)
                encoder.setTexture(tex, index: 0)
                encoder.setTexture(scratch, index: 1)
                var cp = BrushCompositeParams(layer: UInt32(layer),
                                              erase: stroke.erase ? 1 : 0,
                                              originPx: origin)
                encoder.setBytes(&cp, length: MemoryLayout<BrushCompositeParams>.stride, index: 0)
                encoder.dispatchThreads(bbox, threadsPerThreadgroup: stampTG)
              }
            }
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        brushAlphaTexture = tex
        brushEnvScratch = scratch
        return tex
    }

    /// Test/backward-compatible brush-only entry point. Production rendering uses
    /// `rebuildMaskAlpha` so brush and AI masks preserve one shared slice order.
    @discardableResult
    nonisolated func rebuildBrushAlpha(_ brushMasks: [BrushMaskGeometry], size: MTLSize) -> MTLTexture? {
        rebuildMaskAlpha(brushMasks.map(MaskAlphaSource.brush), size: size)
    }

    /// Encodes one stroke's dabs as `stampBrush` dispatches into `encoder` (which must already
    /// have the stamp pipeline state + target texture bound), each bounded to that dab's bounding
    /// box. `forceAdd` stamps a plain max envelope (used to build the per-stroke scratch, where
    /// erase is applied by the composite step instead). Shared by the full rebuild and the
    /// incremental live-paint path.
    nonisolated private static func encodeStroke(
        _ stroke: BrushStroke, layer: Int, size: MTLSize, forceAdd: Bool = false,
        into encoder: MTLComputeCommandEncoder
    ) {
        let radiusPx = brushRadiusPixels(normalized: stroke.radius, size: size)
        guard radiusPx > 0 else { return }
        let density = Float(stroke.density)
        let erase: UInt32 = (forceAdd || !stroke.erase) ? 0 : 1
        let stampTG = MTLSize(width: 16, height: 16, depth: 1)
        for dab in stroke.dabs {
            let cx = Double(dab.x) * Double(size.width)
            let cy = Double(dab.y) * Double(size.height)
            let outerRadius = BrushDabProfile.outerRadius(
                nominalRadius: Double(radiusPx),
                hardness: dab.hardness
            )
            let minX = max(0, Int((cx - outerRadius).rounded(.down)))
            let minY = max(0, Int((cy - outerRadius).rounded(.down)))
            let maxX = min(size.width, Int((cx + outerRadius).rounded(.up)))
            let maxY = min(size.height, Int((cy + outerRadius).rounded(.up)))
            let boxW = maxX - minX
            let boxH = maxY - minY
            guard boxW > 0, boxH > 0 else { continue }
            var p = BrushDabParams()
            p.center = SIMD2<Float>(Float(dab.x), Float(dab.y))
            p.radiusPx = radiusPx
            p.hardness = Float(dab.hardness)
            p.flow = Float(dab.flow)
            p.density = density
            p.erase = erase
            p.layer = UInt32(layer)
            p.originPx = SIMD2<UInt32>(UInt32(minX), UInt32(minY))
            encoder.setBytes(&p, length: MemoryLayout<BrushDabParams>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: boxW, height: boxH, depth: 1),
                threadsPerThreadgroup: stampTG
            )
        }
    }

    /// Live-paint entry: stamps `stroke`'s dabs into an EXISTING slice of `brushAlphaTexture`
    /// without a clear/rebuild, for immediate feedback while the user drags. The slice must
    /// already exist (allocated by a prior `refreshBrushAlpha`, e.g. because an empty brush mask
    /// was committed on gesture start). Transient: the authoritative alpha is rebuilt from the
    /// model on `mouseUp` when the finished stroke is committed and `updateParams` runs. No-op if
    /// the pipeline/texture is missing or `layer` is out of range. Returns true if it dispatched.
    @discardableResult
    nonisolated func stampBrushStroke(_ stroke: BrushStroke, layer: Int) -> Bool {
        guard let stampState = stampBrushPipelineState,
              let tex = brushAlphaTexture,
              layer >= 0, layer < tex.arrayLength,
              !stroke.dabs.isEmpty,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        let size = MTLSize(width: tex.width, height: tex.height, depth: 1)
        encoder.setComputePipelineState(stampState)
        encoder.setTexture(tex, index: 0)
        Self.encodeStroke(stroke, layer: layer, size: size, into: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    /// Frees the brush alpha texture (e.g. when the last brush mask is removed).
    nonisolated func clearBrushAlpha() {
        brushAlphaTexture = nil
        brushEnvScratch = nil
        lastBuiltMaskAlphaSources = []
        lastBuiltBrushSize = MTLSize(width: 0, height: 0, depth: 0)
    }

    /// Cached wrapper around `rebuildMaskAlpha` for the live path: a full-resolution rebuild is
    /// skipped on unrelated tonal slider changes.
    nonisolated func refreshMaskAlpha(_ sources: [MaskAlphaSource], size: MTLSize) {
        guard !sources.isEmpty else {
            if brushAlphaTexture != nil { clearBrushAlpha() }
            return
        }
        if brushAlphaTexture != nil,
           sources == lastBuiltMaskAlphaSources,
           size.width == lastBuiltBrushSize.width,
           size.height == lastBuiltBrushSize.height {
            return
        }
        rebuildMaskAlpha(sources, size: size)
        lastBuiltMaskAlphaSources = sources
        lastBuiltBrushSize = size
    }

    /// Brush-only compatibility wrapper retained for focused rasterization tests and live-paint
    /// call sites that intentionally deal only in brush geometry.
    nonisolated func refreshBrushAlpha(_ brushMasks: [BrushMaskGeometry], size: MTLSize) {
        refreshMaskAlpha(brushMasks.map(MaskAlphaSource.brush), size: size)
    }

    // MARK: - Watermark textures

    /// (Re)builds the deduped-by-asset watermark texture array from `assetIDs` (which may
    /// contain duplicates — several layers can reference the same library asset). Reads each
    /// asset's PNG directly off disk via `WatermarkStore.resolvedImageURL`/`CloudCoordinatedIO`
    /// — NOT through `WatermarkStore.shared`'s actor-isolated `assets` list — so this is safe to
    /// call from the offscreen (background-queue) export path as well as the live main-thread
    /// path. Decodes with `CGContext` using a Y-flip so row 0 lands at the texture's v=0 (top),
    /// matching this pipeline's UV convention; premultiplied alpha throughout (see
    /// `applyWatermark` in EditAdjustments.metal), since `CGContext` bitmap targets require it.
    /// Cached against `lastBuiltWatermarkAssetIDs` — a position/size/opacity-only change (the
    /// common case while dragging a slider) skips the redecode entirely.
    @discardableResult
    nonisolated private func loadWatermarkTextures(_ assetIDs: [UUID]) -> [UUID: (slice: Int, aspect: Double)] {
        var distinctIDs: [UUID] = []
        var seen = Set<UUID>()
        for id in assetIDs where !seen.contains(id) {
            seen.insert(id)
            distinctIDs.append(id)
        }
        guard !distinctIDs.isEmpty else {
            watermarkTexture = nil
            lastBuiltWatermarkAssetIDs = []
            lastBuiltWatermarkAspects = [:]
            return [:]
        }
        if watermarkTexture != nil, distinctIDs == lastBuiltWatermarkAssetIDs {
            return lastBuiltWatermarkAspects
        }

        var decoded: [(id: UUID, image: CGImage)] = []
        for id in distinctIDs {
            guard let data = try? CloudCoordinatedIO.readData(at: WatermarkStore.resolvedImageURL(forAssetID: id)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  cgImage.width > 0, cgImage.height > 0
            else { continue }
            decoded.append((id, cgImage))
        }
        guard !decoded.isEmpty else {
            watermarkTexture = nil
            lastBuiltWatermarkAssetIDs = []
            lastBuiltWatermarkAspects = [:]
            return [:]
        }

        let maxW = decoded.map(\.image.width).max() ?? 1
        let maxH = decoded.map(\.image.height).max() ?? 1
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        // sRGB-tagged format: Metal automatically linearizes the gamma-encoded bytes on
        // sample, matching the rest of this pipeline (which composites in linear light).
        // Plain .rgba8Unorm would treat the stored sRGB bytes as already-linear, visibly
        // shifting the watermark's color/brightness wherever it isn't pure black/white.
        desc.pixelFormat = .rgba8Unorm_srgb
        desc.width = maxW
        desc.height = maxH
        desc.arrayLength = decoded.count
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            watermarkTexture = nil
            lastBuiltWatermarkAssetIDs = []
            lastBuiltWatermarkAspects = [:]
            return [:]
        }

        let rgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var mapping: [UUID: (slice: Int, aspect: Double)] = [:]
        for (slice, entry) in decoded.enumerated() {
            let w = entry.image.width, h = entry.image.height
            guard let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            // No extra flip: `context.draw` already writes the image right-side-up into the
            // raw buffer (row 0 = the image's own top row), matching Metal's texture v=0 —
            // confirmed empirically after an earlier version of this code added an (incorrect)
            // flip here and rendered every watermark upside down.
            context.draw(entry.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let pixelData = context.data else { continue }
            tex.replace(
                region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: slice,
                withBytes: pixelData, bytesPerRow: w * 4, bytesPerImage: w * h * 4
            )
            mapping[entry.id] = (slice, Double(w) / Double(h))
        }

        watermarkTexture = tex
        lastBuiltWatermarkAssetIDs = distinctIDs
        lastBuiltWatermarkAspects = mapping
        return mapping
    }

    /// Builds the per-layer `WatermarkParams` (center/halfExtent/opacity/textureLayer) for
    /// `layers` at `imageSize` (the render target's pixel dimensions — the same frame the
    /// kernel samples `uv` in), (re)loading the texture array as needed, and returns each
    /// layer's assigned order-buffer slot index. Mirrors `refreshBrushAlpha`'s split from
    /// `updateParams`: called there directly when a persistent source texture size is already
    /// known (live preview), and again explicitly by `renderOffscreenSerial` once the export's
    /// working resolution is known (the ephemeral offscreen pipeline has no persistent source
    /// texture at `updateParams` time).
    @discardableResult
    nonisolated func refreshWatermarkParams(_ layers: [WatermarkLayer], imageSize: MTLSize) -> [UUID: Int] {
        guard !layers.isEmpty, imageSize.width > 0, imageSize.height > 0,
              let wmBuf = watermarkParamsBuffer else {
            watermarkTexture = nil
            lastBuiltWatermarkAssetIDs = []
            lastBuiltWatermarkAspects = [:]
            return [:]
        }
        let capped = Array(layers.prefix(Self.maxWatermarks))
        let assetMapping = loadWatermarkTextures(capped.map(\.libraryAssetID))

        var indexByID: [UUID: Int] = [:]
        let wmPtr = wmBuf.contents().bindMemory(to: WatermarkParams.self, capacity: Self.maxWatermarks)
        for (i, layer) in capped.enumerated() {
            indexByID[layer.id] = i
            var wp = WatermarkParams()
            wp.opacity = Float(layer.opacity)
            if let (slice, aspect) = assetMapping[layer.libraryAssetID] {
                let half = layer.geometry.renderedHalfExtentUV(
                    assetAspect: aspect,
                    imageWidth: Double(imageSize.width),
                    imageHeight: Double(imageSize.height)
                )
                wp.center = SIMD2<Float>(Float(layer.geometry.centerX), Float(layer.geometry.centerY))
                wp.halfExtent = SIMD2<Float>(Float(half.halfWidthUV), Float(half.halfHeightUV))
                wp.textureLayer = UInt32(slice)
            }
            // Missing asset (deleted from the library): halfExtent stays (0,0), which
            // `applyWatermark` treats as a no-op rather than sampling garbage.
            wmPtr[i] = wp
        }
        return indexByID
    }

    // MARK: - Render

    /// Allocates one transient half-float working texture. Mipmaps are generated only when the
    /// following pass is spatial, so pointwise-only segments do not pay the blit cost.
    nonisolated private func makeRenderGraphTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: true
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    /// Encodes one edit-kernel dispatch using an immutable parameter snapshot. `setBytes` is
    /// important here: every pass has a different order range/execution mode, while the shared
    /// `paramsBuffer` remains the canonical state consumed by scopes and future redraws.
    nonisolated private func encodeEditPass(
        source: MTLTexture,
        destination: MTLTexture,
        params: EditParams,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var passParams = params
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setTexture(lutTexture, index: 2)
        encoder.setTexture(brushAlphaTexture ?? emptyBrushAlpha, index: 3)
        encoder.setTexture(watermarkTexture ?? emptyWatermarkTexture, index: 4)
        encoder.setTexture(colorLUTTexture, index: 5)
        encoder.setBytes(&passParams, length: MemoryLayout<EditParams>.stride, index: 0)
        if let maskBuffer {
            encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        }
        if let hslBuffer {
            encoder.setBuffer(hslBuffer, offset: 0, index: 2)
        }
        if let orderBuffer {
            encoder.setBuffer(orderBuffer, offset: 0, index: 3)
        }
        if let watermarkParamsBuffer {
            encoder.setBuffer(watermarkParamsBuffer, offset: 0, index: 4)
        }
        encoder.dispatchThreads(
            MTLSize(
                width: Int(params.drawableSize.x),
                height: Int(params.drawableSize.y),
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        return true
    }

    /// Encodes either the historical one-dispatch fast path or the compiled multi-pass graph.
    /// Source-frame graphs render stable full-image intermediates; crop-output graphs retain the
    /// current drawable mapping so crop-relative watermarks preserve their existing semantics.
    nonisolated private func encodeRenderGraph(
        source: MTLTexture,
        destination: MTLTexture,
        baseParams: EditParams,
        workingInOutputFrame: Bool,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard renderPassPlan.count > 1 else {
            var params = baseParams
            params.orderOffset = UInt32(renderPassPlan.first?.orderOffset ?? 0)
            params.orderCount = UInt32(
                renderPassPlan.first?.orderCount ?? Int(baseParams.orderCount)
            )
            params.executionFlags = 0
            return encodeEditPass(
                source: source,
                destination: destination,
                params: params,
                commandBuffer: commandBuffer
            )
        }

        let workingWidth = workingInOutputFrame
            ? Int(baseParams.drawableSize.x)
            : source.width
        let workingHeight = workingInOutputFrame
            ? Int(baseParams.drawableSize.y)
            : source.height
        guard workingWidth > 0, workingHeight > 0,
              let ping = makeRenderGraphTexture(width: workingWidth, height: workingHeight)
        else { return false }
        let pong: MTLTexture?
        if renderPassPlan.count > 2 {
            pong = makeRenderGraphTexture(width: workingWidth, height: workingHeight)
            guard pong != nil else { return false }
        } else {
            pong = nil
        }

        var current = source
        var writeToPing = true
        for (index, renderPass) in renderPassPlan.enumerated() {
            let isLast = index == renderPassPlan.count - 1
            let output: MTLTexture
            if isLast {
                output = destination
            } else if writeToPing {
                output = ping
            } else if let pong {
                output = pong
            } else {
                return false
            }
            var params = baseParams
            params.orderOffset = UInt32(renderPass.orderOffset)
            params.orderCount = UInt32(renderPass.orderCount)
            if isLast {
                // The last layer segment also serves as presentation: it maps a source-frame
                // intermediate through the current viewport (or samples an output-frame
                // intermediate directly) and applies output transforms exactly once.
                params.executionFlags = workingInOutputFrame
                    ? Self.executionInputInDrawableFrame
                    : 0
            } else {
                params.drawableSize = SIMD2<Float>(Float(workingWidth), Float(workingHeight))
                params.scale = SIMD2<Float>(
                    Float(workingWidth) / Float(max(source.width, 1)),
                    Float(workingHeight) / Float(max(source.height, 1))
                )
                params.executionFlags = Self.executionIntermediate
                if workingInOutputFrame {
                    if index > 0 {
                        params.executionFlags |= Self.executionInputInDrawableFrame
                    }
                } else {
                    params.viewportOrigin = .zero
                    params.viewportSize = SIMD2<Float>(1, 1)
                    params.viewportCenter = SIMD2<Float>(0.5, 0.5)
                    params.viewportRotation = 0
                    params.cropHalfExtent = SIMD2<Float>(0.5, 0.5)
                    params.watermarkFrame = 0
                    params.executionFlags |= Self.executionIdentitySourceFrame
                }
            }
            if isLast, workingInOutputFrame {
                // The current texture is already in output coordinates after the first
                // intermediate segment; preserve the source UV mapping only for mask geometry.
                if index > 0 {
                    params.executionFlags |= Self.executionInputInDrawableFrame
                }
            }

            guard encodeEditPass(
                source: current,
                destination: output,
                params: params,
                commandBuffer: commandBuffer
            ) else { return false }
            current = output
            if !isLast {
                writeToPing.toggle()
            }

            if index + 1 < renderPassPlan.count,
               renderPassPlan[index + 1].requiresMipmappedInput {
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
                blit.generateMipmaps(for: current)
                blit.endEncoding()
            }
        }
        return true
    }

    /// Renders the compiled graph to a drawable. Returns true on success.
    nonisolated(unsafe) private var lastLoggedWidth: Int = 0

    nonisolated func render(
        to drawable: CAMetalDrawable,
        drawableSize: CGSize,
        useNearestNeighbor: Bool = false
    ) -> Bool {
        guard let source = sourceTexture,
              let buffer = paramsBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

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
        ptr.pointee.useNearestNeighbor = useNearestNeighbor ? 1 : 0

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width: Int(dstW),
            height: Int(dstH),
            depth: 1
        )
        guard encodeRenderGraph(
            source: source,
            destination: drawable.texture,
            baseParams: ptr.pointee,
            workingInOutputFrame: ptr.pointee.watermarkFrame == 1,
            commandBuffer: commandBuffer
        ) else { return false }

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

        guard let target = settings.resolvedWhiteBalanceTarget(
            absoluteDefaultTemperature: asShotTemperature,
            absoluteDefaultTint: asShotTint
        ) else {
            cachedWBKey = nil
            cachedWBMatrix = nil
            return nil
        }

        // Return cached matrix if temperature/tint and as-shot reference haven't changed
        if let key = cachedWBKey,
           key.0 == target.temperature, key.1 == target.tint,
           key.2 == asShotTemperature, key.3 == asShotTint {
            return cachedWBMatrix
        }

        let matrix = extractWBMatrix(temperature: target.temperature, tint: target.tint)
        cachedWBKey = (target.temperature, target.tint, asShotTemperature, asShotTint)
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

    /// White-balance eyedropper: solves for the (temperature, tint) that renders the
    /// supplied linear extended-sRGB color neutral under the current as-shot reference.
    /// `rgb` is the averaged source-pixel value the user clicked/dragged over (sampled
    /// BEFORE the WB matrix, matching how Camera Raw's eyedropper works on the underlying
    /// data, so the same patch always yields the same WB regardless of the current slider
    /// position). Returns absolute Kelvin (clamped to the representable 2000–50000 K range)
    /// and tint (−150…150), or nil for a degenerate (near-black) sample. Coarse-to-fine
    /// grid over a log-temperature / linear-tint space minimizing post-transform chroma.
    ///
    /// Candidates are evaluated with `extractWBMatrix` — the SAME linearized 3×3 the live
    /// pipeline applies in the shader — not by pushing the colour through CITemperatureAndTint
    /// directly. CITemperatureAndTint is not a pure linear matrix, so the two diverge for
    /// bright samples; matching the pipeline's matrix is what makes the solved WB actually
    /// neutralise the displayed pixel (a single-colour render left a green cast on highlights).
    nonisolated func solveWhiteBalance(forNeutralLinearRGB rgb: SIMD3<Float>) -> (temperature: Double, tint: Double)? {
        guard max(rgb.x, max(rgb.y, rgb.z)) > 1e-5 else { return nil }
        let sample = rgb

        // Search floor sits ABOVE CITemperatureAndTint's 2000 K identity clamp: at that floor
        // the matrix is rank-deficient and can map a mild-cast sample *exactly* to grey (chroma
        // 0), beating any well-behaved interior matrix — so near-neutral picks railed to 2000 K.
        // 2500 K stays clear of the degenerate edge while still covering real tungsten (~2800 K+);
        // the final value is clamped to the representable range by the caller.
        let logMin = log(2500.0), logMax = log(50000.0)
        let logNeutral = log(6500.0)
        let logSpan = log(50000.0) - log(2000.0)
        // Regularization toward neutral. Among candidates that neutralize comparably, prefer the
        // smallest correction (as ACR does) — this also stops a degenerate near-zero chroma from
        // winning over a sane interior solution. λ is far below any real cast's chroma gradient,
        // so genuine tungsten/shade corrections are unaffected.
        let lambda: Float = 0.006

        // Matrix-transformed chroma (0 when R == G == B) plus the neutral regularizer.
        func cost(_ temp: Double, _ tint: Double) -> Float {
            let o = extractWBMatrix(temperature: temp, tint: tint) * sample
            let mean = (o.x + o.y + o.z) / 3
            guard mean > 1e-6 else { return .greatestFiniteMagnitude }
            let dr = o.x - o.y, db = o.z - o.y
            let chroma = (dr * dr + db * db) / (mean * mean)
            let dLogT = Float((log(temp) - logNeutral) / logSpan)
            let nTint = Float(tint / 150)
            return chroma + lambda * (dLogT * dLogT + nTint * nTint)
        }

        var bestTemp = 6500.0, bestTint = 0.0
        var loLogT = logMin, hiLogT = logMax
        var loTint = -150.0, hiTint = 150.0

        // Decreasing grid resolution per pass: a coarse global sweep, then two refinements
        // that zoom into a ±1-step window around the running best.
        let passes: [(temp: Int, tint: Int)] = [(14, 14), (8, 8), (8, 8)]
        for grid in passes {
            var bestCost = Float.greatestFiniteMagnitude
            for i in 0...grid.temp {
                let temp = exp(loLogT + (hiLogT - loLogT) * Double(i) / Double(grid.temp))
                for j in 0...grid.tint {
                    let tint = loTint + (hiTint - loTint) * Double(j) / Double(grid.tint)
                    let c = cost(temp, tint)
                    if c < bestCost {
                        bestCost = c; bestTemp = temp; bestTint = tint
                    }
                }
            }
            let tStep = (hiLogT - loLogT) / Double(grid.temp)
            let nStep = (hiTint - loTint) / Double(grid.tint)
            loLogT = max(logMin, log(bestTemp) - tStep); hiLogT = min(logMax, log(bestTemp) + tStep)
            loTint = max(-150, bestTint - nStep); hiTint = min(150, bestTint + nStep)
        }
        return (bestTemp, bestTint)
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
        other.setSourceOrientation(sourceOrientation)
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
        cachedWatermarkFrame = 0
        let watermarkReferenceSize = sourceTextureSize ?? imageSize
        cachedWatermarkImageSize = MTLSize(
            width: max(1, Int(watermarkReferenceSize.width.rounded())),
            height: max(1, Int(watermarkReferenceSize.height.rounded())),
            depth: 1
        )

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.viewportOrigin = cachedViewportOrigin
        ptr.pointee.viewportSize = cachedViewportSize
        ptr.pointee.viewportCenter = cachedViewportCenter
        ptr.pointee.viewportRotation = cachedViewportRotation
        ptr.pointee.cropHalfExtent = cachedCropHalfExtent
        ptr.pointee.watermarkFrame = cachedWatermarkFrame
        if !activeDisplayWatermarkLayers.isEmpty {
            refreshWatermarkParams(activeDisplayWatermarkLayers, imageSize: cachedWatermarkImageSize)
        }

        // Also update overlay params
        if let overlayBuf = overlayParamsBuffer {
            let overlayPtr = overlayBuf.contents().bindMemory(to: MaskOverlayParams.self, capacity: 1)
            overlayPtr.pointee.viewportOrigin = cachedViewportOrigin
            overlayPtr.pointee.viewportSize = cachedViewportSize
        }
    }

    /// Clean-feed crop viewport. Renders only the confirmed crop region (with straighten
    /// rotation), aspect-fit to the secondary display. Mirrors the editor's own crop
    /// geometry (`EditWorkspaceView.cropFittedImageRect`): the stored region is the upright
    /// crop rectangle, so its dimensions are the actual crop dimensions; those are fit to the
    /// container, and the shader rotates sampling around the crop center. Crop edges are
    /// normalized [0,1] in display-oriented source coords (top-left origin), matching the
    /// editor's `activeCrop`.
    nonisolated func updateCropViewport(
        containerSize: CGSize,
        imageSize: CGSize,
        cropLeft: Double,
        cropTop: Double,
        cropRight: Double,
        cropBottom: Double,
        angleDegrees: Double,
        zoomScale: CGFloat = 1.0,
        offset: CGSize = .zero,
        handlePadding: CGFloat = 0
    ) {
        guard let buffer = paramsBuffer else { return }
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return }

        let imgW = Double(imageSize.width)
        let imgH = Double(imageSize.height)

        // The stored region is the upright crop rectangle, so its dimensions are the actual
        // (straightened) crop dimensions directly.
        let actualW = max((cropRight - cropLeft), 0.0001) * imgW
        let actualH = max((cropBottom - cropTop), 0.0001) * imgH
        let centerX = (cropLeft + cropRight) / 2
        let centerY = (cropTop + cropBottom) / 2

        // Fit the actual crop into the container (identical to cropFittedImageRect's baseScale).
        let radians = angleDegrees * .pi / 180.0

        let availW = max(Double(containerSize.width - handlePadding * 2), 1)
        let availH = max(Double(containerSize.height - handlePadding * 2), 1)
        let fitScale = min(availW / max(actualW, 1),
                           availH / max(actualH, 1)) * max(Double(zoomScale), 0.0001)
        guard fitScale > 0 else { return }

        // The source region (in pixels) that maps to the full drawable — larger than the
        // crop by the letterbox margin.
        let visiblePxW = Double(containerSize.width) / fitScale
        let visiblePxH = Double(containerSize.height) / fitScale
        let vpW = visiblePxW / imgW
        let vpH = visiblePxH / imgH

        cachedViewportSize = SIMD2<Float>(Float(vpW), Float(vpH))

        let offsetPxX = Double(offset.width) / fitScale
        let offsetPxY = Double(offset.height) / fitScale
        let cosA = cos(radians)
        let sinA = sin(radians)
        let rotatedOffsetX = offsetPxX * cosA - offsetPxY * sinA
        let rotatedOffsetY = offsetPxX * sinA + offsetPxY * cosA
        let viewportCenterX = centerX - rotatedOffsetX / imgW
        let viewportCenterY = centerY - rotatedOffsetY / imgH

        cachedViewportCenter = SIMD2<Float>(Float(viewportCenterX), Float(viewportCenterY))
        cachedViewportOrigin = SIMD2<Float>(Float(viewportCenterX - vpW / 2), Float(viewportCenterY - vpH / 2))
        cachedViewportRotation = Float(radians)

        // The crop occupies the central (actual·fitScale / container) fraction of the
        // drawable; the rest is letterbox margin that must be masked to the background.
        let cropHalfX = (actualW * fitScale) / (2 * Double(containerSize.width))
        let cropHalfY = (actualH * fitScale) / (2 * Double(containerSize.height))
        cachedCropHalfExtent = SIMD2<Float>(Float(cropHalfX), Float(cropHalfY))
        cachedWatermarkFrame = 1
        cachedWatermarkImageSize = MTLSize(
            width: max(1, Int(actualW.rounded())),
            height: max(1, Int(actualH.rounded())),
            depth: 1
        )

        let ptr = buffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.viewportOrigin = cachedViewportOrigin
        ptr.pointee.viewportSize = cachedViewportSize
        ptr.pointee.viewportCenter = cachedViewportCenter
        ptr.pointee.viewportRotation = cachedViewportRotation
        ptr.pointee.cropHalfExtent = cachedCropHalfExtent
        ptr.pointee.watermarkFrame = cachedWatermarkFrame
        if !activeDisplayWatermarkLayers.isEmpty {
            refreshWatermarkParams(activeDisplayWatermarkLayers, imageSize: cachedWatermarkImageSize)
        }
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
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true
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
        // Pre-cached textures get promoted to sourceTexture on navigation (applyCachedTexture),
        // so they need mips too — the Anonymizer effect can't tell a promoted texture apart
        // from a freshly-uploaded one.
        Self.generateMipmaps(for: texture, commandQueue: commandQueue)
        textureCache.setObject(MTLTextureWrapper(texture, neutralTemperature: neutralTemperature, neutralTint: neutralTint), forKey: url as NSURL)
    }

    /// Promote a pre-cached texture to sourceTexture. Returns as-shot WB on hit, nil on miss.
    /// `exifOrientation` is the orientation baked into the cached texture's pixels.
    nonisolated func applyCachedTexture(for url: URL, exifOrientation: Int = 1) -> (neutralTemperature: Float, neutralTint: Float)? {
        guard let wrapper = textureCache.object(forKey: url as NSURL) else { return nil }
        setSourceTexture(wrapper.texture)
        setSourceOrientation(exifOrientation)
        mirror?.setSourceTexture(wrapper.texture)
        mirror?.setSourceOrientation(exifOrientation)
        textureCache.removeObject(forKey: url as NSURL)
        return (neutralTemperature: wrapper.neutralTemperature, neutralTint: wrapper.neutralTint)
    }

    // MARK: - Offscreen Rendering

    /// Renders adjustments via the Metal compute shader and returns the result as CIImage.
    /// `outputSize` is primarily useful for exercising the live preview's downsampled footprint;
    /// nil preserves the source dimensions used by normal offscreen/export callers.
    /// Synchronous entry: serializes on `offscreenRenderQueue` and **blocks** the caller until
    /// the render completes. Safe, but from an async context prefer `renderOffscreenAsync` so the
    /// caller suspends rather than tying up a cooperative-pool thread across the GPU wait.
    nonisolated static func renderOffscreen(
        source: CIImage,
        settings: CameraRawSettings?,
        exifOrientation: Int = 1,
        outputSize: CGSize? = nil
    ) -> CIImage? {
        offscreenRenderQueue.sync {
            renderOffscreenSerial(
                source: source,
                settings: settings,
                exifOrientation: exifOrientation,
                outputSize: outputSize
            )
        }
    }

    /// Renders the confirmed crop directly, so watermark coordinates and margins resolve
    /// against the cropped output frame instead of the full source image.
    nonisolated static func renderOffscreenCropped(
        source: CIImage,
        settings: CameraRawSettings?,
        exifOrientation: Int = 1
    ) -> CIImage? {
        offscreenRenderQueue.sync {
            renderOffscreenSerial(
                source: source, settings: settings, exifOrientation: exifOrientation, cropToOutput: true
            )
        }
    }

    /// Asynchronous entry: runs the render on `offscreenRenderQueue` and **suspends** the caller
    /// while it executes, so the blocking GPU wait happens on the dedicated render thread and
    /// never starves Swift concurrency's cooperative thread pool. Prefer this from any `Task`.
    ///
    /// Honors cancellation: because the queue is FIFO and unbounded, a cancelled job (e.g. a
    /// prefetch the user navigated past) would otherwise still run its full GPU render once it
    /// reached the head, letting a backlog of stale renders starve the foreground. We instead
    /// short-circuit such jobs in µs when they dequeue.
    nonisolated static func renderOffscreenAsync(
        source: CIImage,
        settings: CameraRawSettings?,
        exifOrientation: Int = 1
    ) async -> CIImage? {
        if Task.isCancelled { return nil }
        let inBox = CIImageBox(image: source)
        let flag = CancelFlag()
        let outBox: CIImageBox = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                offscreenRenderQueue.async {
                    guard !flag.isCancelled else {
                        continuation.resume(returning: CIImageBox(image: nil))
                        return
                    }
                    let result = renderOffscreenSerial(
                        source: inBox.image, settings: settings, exifOrientation: exifOrientation
                    )
                    continuation.resume(returning: CIImageBox(image: result))
                }
            }
        } onCancel: {
            flag.cancel()
        }
        return outBox.image
    }

    /// Async sibling of `renderOffscreenCropped`.
    nonisolated static func renderOffscreenCroppedAsync(
        source: CIImage,
        settings: CameraRawSettings?,
        exifOrientation: Int = 1
    ) async -> CIImage? {
        if Task.isCancelled { return nil }
        let inBox = CIImageBox(image: source)
        let flag = CancelFlag()
        let outBox: CIImageBox = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                offscreenRenderQueue.async {
                    guard !flag.isCancelled else {
                        continuation.resume(returning: CIImageBox(image: nil))
                        return
                    }
                    let result = renderOffscreenSerial(
                        source: inBox.image,
                        settings: settings,
                        exifOrientation: exifOrientation,
                        cropToOutput: true
                    )
                    continuation.resume(returning: CIImageBox(image: result))
                }
            }
        } onCancel: {
            flag.cancel()
        }
        return outBox.image
    }

    /// The actual render. Assumes it is running on `offscreenRenderQueue` (the serial owner of
    /// the shared pipeline's mutable LUT/params/WB-cache state); never call it directly off-queue.
    /// Uses the exact same shader as the live preview: LUT, vibrance, saturation,
    /// white balance, and highlight desaturation. No CIFilter approximation.
    nonisolated private static func renderOffscreenSerial(
        source: CIImage?,
        settings: CameraRawSettings?,
        exifOrientation: Int = 1,
        cropToOutput: Bool = false,
        outputSize: CGSize? = nil
    ) -> CIImage? {
        guard let source else { return nil }
        guard var settings, !isIdentitySettings(settings) else { return nil }
        // `source` is display-oriented but mask geometry is sensor-frame —
        // transform before the params upload (the ephemeral pipeline has no
        // source texture of its own, so updateParams can't do it there).
        if source.extent.height > 0 {
            settings = settings
                .masksTransformedForDisplay(
                    orientation: exifOrientation,
                    displayAspect: source.extent.width / source.extent.height
                )
                .watermarksTransformedForDisplay(orientation: exifOrientation)
        }
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
        let outputCrop: CameraRawCrop?
        if cropToOutput {
            guard let crop = settings.crop, crop.isEffectiveCrop else { return nil }
            outputCrop = crop
        } else {
            outputCrop = nil
        }
        let outputWidth: Int
        let outputHeight: Int
        if let crop = outputCrop {
            let left = min(crop.left ?? 0, crop.right ?? 1)
            let right = max(crop.left ?? 0, crop.right ?? 1)
            let top = min(crop.top ?? 0, crop.bottom ?? 1)
            let bottom = max(crop.top ?? 0, crop.bottom ?? 1)
            outputWidth = max(1, Int((Double(width) * max(right - left, 0.0001)).rounded()))
            outputHeight = max(1, Int((Double(height) * max(bottom - top, 0.0001)).rounded()))
        } else if let outputSize,
                  outputSize.width.isFinite, outputSize.height.isFinite,
                  outputSize.width > 0, outputSize.height > 0 {
            outputWidth = max(1, Int(min(outputSize.width.rounded(), CGFloat(maxTextureDimension))))
            outputHeight = max(1, Int(min(outputSize.height.rounded(), CGFloat(maxTextureDimension))))
        } else {
            outputWidth = width
            outputHeight = height
        }

        // Serialized by `offscreenRenderQueue` (this function only runs there), so the shared
        // pipeline's mutable state (LUT, params, WB cache) is never touched concurrently.

        // 1. Upload source CIImage to Metal texture
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true
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
        // Export must mosaic/blur at the same fidelity as the live preview — the Anonymizer
        // kernel fetches an explicit mip level, so this texture needs a full mip chain too.
        generateMipmaps(for: srcTexture, commandQueue: queue)

        // 2. Propagate as-shot WB reference so the ephemeral pipeline computes
        //    the same white balance matrix as the live edit preview.
        if let asTemp = settings.asShotNeutralTemperature {
            pipeline.asShotTemperature = asTemp
        }
        if let asTint = settings.asShotNeutralTint {
            pipeline.asShotTint = asTint
        }

        // 3. Generate LUT and set parameters
        pipeline.cachedWatermarkFrame = outputCrop == nil ? 0 : 1
        pipeline.cachedWatermarkImageSize = MTLSize(width: outputWidth, height: outputHeight, depth: 1)
        pipeline.updateParams(settings)

        // The offscreen pipeline has no persistent source texture, so `updateParams` can't size
        // raster alpha — rebuild it explicitly at the working resolution. Sources use the same
        // enabled-mask order `updateParams` used to assign each `brushLayer` slice.
        let alphaSourcesForExport = (settings.localAdjustments?.filter { $0.enabled } ?? [])
            .prefix(Self.maxMasks)
            .compactMap { mask -> MaskAlphaSource? in
                if let brush = mask.brush { return .brush(brush) }
                if let aiMask = mask.aiMask, aiMask.isValid { return .ai(aiMask) }
                return nil
            }
        pipeline.rebuildMaskAlpha(
            Array(alphaSourcesForExport),
            size: MTLSize(width: width, height: height, depth: 1)
        )

        // Same reasoning for watermark layers: `updateParams` (just above) had no persistent
        // source texture to size against, so it only assigned order-buffer slots. Refresh the
        // actual texture + geometry data now, at the export's real working resolution, before
        // the dispatch below reads it.
        let watermarkLayersForExport = (settings.watermarkLayers ?? [])
            .filter(\.enabled)
            .prefix(Self.maxWatermarks)
        pipeline.refreshWatermarkParams(
            Array(watermarkLayersForExport),
            imageSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1)
        )

        // 3. Create output texture (managed — CIImage can create from it)
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: outputWidth, height: outputHeight, mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        outDesc.storageMode = .shared
        guard let outTexture = device.makeTexture(descriptor: outDesc) else { return nil }

        // 4. Dispatch the same compiled render graph used by the live preview.
        guard let paramsBuffer = pipeline.paramsBuffer,
              let computeCmdBuf = queue.makeCommandBuffer() else { return nil }

        let ptr = paramsBuffer.contents().bindMemory(to: EditParams.self, capacity: 1)
        ptr.pointee.scale = SIMD2<Float>(
            Float(outputWidth) / Float(width),
            Float(outputHeight) / Float(height)
        )
        ptr.pointee.sourceSize = SIMD2<Float>(Float(width), Float(height))
        ptr.pointee.drawableSize = SIMD2<Float>(Float(outputWidth), Float(outputHeight))
        if let crop = outputCrop {
            let left = min(crop.left ?? 0, crop.right ?? 1)
            let right = max(crop.left ?? 0, crop.right ?? 1)
            let top = min(crop.top ?? 0, crop.bottom ?? 1)
            let bottom = max(crop.top ?? 0, crop.bottom ?? 1)
            pipeline.updateCropViewport(
                containerSize: CGSize(width: outputWidth, height: outputHeight),
                imageSize: CGSize(width: width, height: height),
                cropLeft: left,
                cropTop: top,
                cropRight: right,
                cropBottom: bottom,
                angleDegrees: crop.angle ?? 0
            )
            ptr.pointee.sourceSize = SIMD2<Float>(Float(width), Float(height))
            ptr.pointee.drawableSize = SIMD2<Float>(Float(outputWidth), Float(outputHeight))
        } else {
            ptr.pointee.viewportOrigin = .zero
            ptr.pointee.viewportSize = SIMD2<Float>(1.0, 1.0)
            ptr.pointee.watermarkFrame = 0
        }

        guard pipeline.encodeRenderGraph(
            source: srcTexture,
            destination: outTexture,
            baseParams: ptr.pointee,
            workingInOutputFrame: outputCrop != nil,
            commandBuffer: computeCmdBuf
        ) else { return nil }
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
        let noOutputToneMap = settings.sourceHasHDRHeadroom != true || settings.hdrEditMode == 1
        let noVibrance = settings.vibrance == nil || settings.vibrance == 0
        let noSaturation = settings.saturation == nil || settings.saturation == 0
        let noDensity = settings.globalDensity == nil || settings.globalDensity == 0
        let noSharpness = settings.sharpness == nil || settings.sharpness == 0
        let noClarity = settings.clarity2012 == nil || settings.clarity2012 == 0
        let noDehaze = settings.dehaze == nil || settings.dehaze == 0
        let noWB = settings.whiteBalance == "As Shot"
            || (settings.temperature == nil && settings.incrementalTemperature == nil
                && settings.tint == nil && settings.incrementalTint == nil)
        let noMasks = settings.localAdjustments?.isEmpty ?? true
        let noWatermarks = settings.watermarkLayers?.isEmpty ?? true
        let noHSL = settings.hslAdjustments?.isEmpty ?? true
        let noAnonymizer = settings.anonymizer?.isEmpty ?? true
        let noFilmEmulation = settings.filmEmulation?.isEmpty ?? true
        return noTonal && noOutputToneMap && noVibrance && noSaturation && noDensity
            && noSharpness && noClarity && noDehaze && noWB && noMasks
            && noWatermarks && noHSL && noAnonymizer && noFilmEmulation
    }
}
