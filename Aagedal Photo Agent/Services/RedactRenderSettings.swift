import Foundation
import simd

/// Host-side mirror of `RedactPassParams` in RedactAnonymizer.metal (all 32-bit scalars, same
/// order — keep the two in sync).
nonisolated struct RedactPassParams {
    var width: Int32 = 0
    var height: Int32 = 0
    var blurRadius: Int32 = 0
    var blurDir: Int32 = 0
    var blurSigma: Float = 0.1
    var mosaicShape: Int32 = 0
    var mosaicSize: Float = 1
    var distortAmount: Float = 0
    var distortScale: Float = 2
    var seed: UInt32 = 0
    var cellSeed: UInt32 = 0
    var biasDx: Float = 0
    var biasDy: Float = 0
    var desaturate: Float = 0
    var cellNoise: Float = 0
    var colorNoise: Float = 0
    var frostAmount: Float = 0
    var frostGrainSize: Float = 1
    var frostR: Float = 0.75
    var frostG: Float = 0.75
    var frostB: Float = 0.75
    var a00: Float = 1, a01: Float = 0, a10: Float = 0, a11: Float = 1
    var b0: Float = 0, b1: Float = 0
    var i00: Float = 1, i01: Float = 0, i10: Float = 0, i11: Float = 1
    /// Downsample / upsample stages: full-size texture pixels per reduced pixel.
    var scaleFactor: Int32 = 1
}

/// Maps working-texture pixels to image pixels (the full source frame of the render), so the
/// Redact warp, mosaic cells and grain stay anchored to the photo when a pass works in a
/// cropped / viewport frame. `image = linear * tex + offset`.
nonisolated struct RedactFrameTransform: Sendable, Equatable {
    var linear: simd_float2x2
    var offset: SIMD2<Float>

    static let identity = RedactFrameTransform(linear: matrix_identity_float2x2, offset: .zero)

    /// The edit kernel's drawable → source mapping (`viewportOrigin/Size`, or the rotated
    /// crop around `viewportCenter`), expressed in pixels.
    static func viewport(
        drawableSize: SIMD2<Float>,
        sourceSize: SIMD2<Float>,
        viewportOrigin: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        viewportCenter: SIMD2<Float>,
        viewportRotation: Float
    ) -> RedactFrameTransform {
        let drawable = simd_max(drawableSize, SIMD2(1, 1))
        let perPixel = viewportSize * sourceSize / drawable
        if viewportRotation == 0 {
            return RedactFrameTransform(
                linear: simd_float2x2(diagonal: perPixel),
                offset: viewportOrigin * sourceSize
            )
        }
        let c = cos(viewportRotation)
        let s = sin(viewportRotation)
        // Shader: off = (p/drawable - 0.5) * viewportSize * sourceSize; r = R * off;
        // image = viewportCenter * sourceSize + r, with R = [[c, -s], [s, c]] (row-major).
        let rotation = simd_float2x2(rows: [SIMD2(c, -s), SIMD2(s, c)])
        let linear = rotation * simd_float2x2(diagonal: perPixel)
        let offset = viewportCenter * sourceSize - rotation * (0.5 * viewportSize * sourceSize)
        return RedactFrameTransform(linear: linear, offset: offset)
    }

    /// Texture pixels per image pixel (geometric mean of the two axes).
    var textureScale: Float {
        let det = abs(linear.determinant)
        return det > 0 ? 1 / det.squareRoot() : 1
    }
}

/// The Redact chain for one anonymizer node, in image pixels (the plugin's `LayerSettings`).
nonisolated struct RedactRenderSettings: Sendable, Equatable {
    var distortAmount: Float
    var distortScale: Float
    var blurRadius: Float
    var mosaicSize: Float
    var mosaicShape: Int32
    var blurAfterMosaic: Bool
    var desaturate: Float
    var cellNoise: Float
    var colorNoise: Float
    var frostedGlass: Bool
    var frostAmount: Float
    var frostColor: SIMD3<Float>
    var frostBlurRadius: Float
    var frostGrainSize: Float
    var seed: UInt32
    var cellSeed: UInt32
    var biasDx: Float
    var biasDy: Float

    /// Scales the 1080p-reference parameters to an image of `imageSize` pixels (short side)
    /// and derives the warp/cell seeds and the displacement field's mean.
    init(_ p: RedactParameters, imageSize: SIMD2<Float>) {
        let shortSide = max(min(imageSize.x, imageSize.y), 1)
        let ds = shortSide / Float(RedactDefaults.referenceShortSide)
        distortAmount = p.distortionEnabled ? Float(p.distortionAmount) * ds : 0
        distortScale = max(Float(p.distortionScale) * ds, 2)
        blurRadius = p.blurEnabled ? Float(p.blurRadius) * ds : 0
        mosaicSize = p.mosaicEnabled ? max(Float(p.mosaicSize) * ds, 1) : 1
        mosaicShape = p.mosaicShape.shaderIndex
        blurAfterMosaic = p.blurAfterMosaic
        desaturate = Float(min(max(p.desaturate, 0), 100) / 100)
        cellNoise = Float(p.cellNoise / 100)
        var color = Float(p.colorNoise / 100)
        if p.blurAfterMosaic, blurRadius >= 1, !p.frostedGlass {
            color *= Float(RedactDefaults.colorNoiseBlurredGain)
        }
        colorNoise = color
        frostedGlass = p.frostedGlass
        frostAmount = Float(min(max(p.frostAmount, 0), 100) / 100)
        frostColor = SIMD3(Float(p.frostColor.red), Float(p.frostColor.green), Float(p.frostColor.blue))
        frostBlurRadius = Float(RedactDefaults.frostBlurCells)
            * max(mosaicSize, Float(RedactDefaults.mosaicSize) * ds)
        frostGrainSize = max((1.5 * ds).rounded(), 1)
        seed = RedactDisplacement.warpSeed(p.seed)
        cellSeed = RedactDisplacement.cellSeed(warpSeed: seed)
        let bias = distortAmount > 0.001
            ? RedactDisplacement.bias(width: Int(imageSize.x), height: Int(imageSize.y),
                                      scale: distortScale, seed: seed)
            : .zero
        biasDx = bias.x
        biasDy = bias.y
    }

    /// The params for one pass over a `width`×`height` texture in `frame`.
    func passParams(width: Int, height: Int, frame: RedactFrameTransform) -> RedactPassParams {
        var p = RedactPassParams()
        p.width = Int32(width)
        p.height = Int32(height)
        p.mosaicShape = mosaicShape
        p.mosaicSize = mosaicSize
        p.distortAmount = distortAmount
        p.distortScale = distortScale
        p.seed = seed
        p.cellSeed = cellSeed
        p.biasDx = biasDx
        p.biasDy = biasDy
        p.desaturate = desaturate
        p.cellNoise = cellNoise
        p.colorNoise = colorNoise
        p.frostAmount = frostAmount
        p.frostGrainSize = frostGrainSize
        p.frostR = frostColor.x
        p.frostG = frostColor.y
        p.frostB = frostColor.z
        let m = frame.linear
        // simd matrices are column-major: m[column][row].
        p.a00 = m[0][0]; p.a01 = m[1][0]; p.a10 = m[0][1]; p.a11 = m[1][1]
        p.b0 = frame.offset.x; p.b1 = frame.offset.y
        let inv = m.inverse
        p.i00 = inv[0][0]; p.i01 = inv[1][0]; p.i10 = inv[0][1]; p.i11 = inv[1][1]
        return p
    }
}

/// CPU mirror of the Redact displacement field (AnonAlgo in the plugin), used for the
/// zero-mean bias: value noise has a non-zero mean over a finite frame, which would shift the
/// whole region. Keep in sync with `redactDisplacement` in RedactAnonymizer.metal.
nonisolated enum RedactDisplacement {
    static func iHash(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x = x &* 0x7feb_352d
        x ^= x >> 15
        x = x &* 0x846c_a68b
        x ^= x >> 16
        return x
    }

    /// AnonComputeSeed(seed, jitter: false, frame: 0, sessionKey: 0).
    static func warpSeed(_ seed: Int) -> UInt32 {
        let s = UInt32(clamping: max(seed, 0))
        return iHash(s &* 0x9E37_79B1 ^ 0x5BD1_E995)
    }

    static func cellSeed(warpSeed: UInt32) -> UInt32 {
        iHash(warpSeed ^ 0xA5C3_E1F7)
    }

    static func rand01(_ ix: Int32, _ iy: Int32, _ seed: UInt32, _ channel: UInt32) -> Float {
        let h = iHash(UInt32(bitPattern: ix) &* 0x9E37_79B1
            ^ UInt32(bitPattern: iy) &* 0x85EB_CA77
            ^ seed &* 0xC2B2_AE3D
            ^ channel &* 0x27D4_EB2F)
        return Float(h) * (1.0 / 4_294_967_295.0)
    }

    static func vNoise(_ px: Float, _ py: Float, _ seed: UInt32, _ channel: UInt32) -> Float {
        let fx = px.rounded(.down)
        let fy = py.rounded(.down)
        let ix = Int32(fx)
        let iy = Int32(fy)
        func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
        let tx = smooth(px - fx)
        let ty = smooth(py - fy)
        let a = rand01(ix, iy, seed, channel)
        let b = rand01(ix &+ 1, iy, seed, channel)
        let c = rand01(ix, iy &+ 1, seed, channel)
        let d = rand01(ix &+ 1, iy &+ 1, seed, channel)
        let ab = a + (b - a) * tx
        let cd = c + (d - c) * tx
        return ab + (cd - ab) * ty
    }

    static func field(x: Float, y: Float, invScale: Float, seed: UInt32) -> SIMD2<Float> {
        let px = x * invScale
        let py = y * invScale
        let qx = (px * 0.8 - py * 0.6) * 2.7
        let qy = (px * 0.6 + py * 0.8) * 2.7
        let n0 = vNoise(px, py, seed, 0) * 2 - 1
        let n1 = vNoise(px, py, seed, 1) * 2 - 1
        let n2 = vNoise(qx, qy, seed, 2) * 2 - 1
        let n3 = vNoise(qx, qy, seed, 3) * 2 - 1
        return SIMD2((n0 + n2 * 0.5) * 0.6666667, (n1 + n3 * 0.5) * 0.6666667)
    }

    /// Mean of the field over a sparse grid of the image (AnonAlgo::DisplacementBias).
    static func bias(width: Int, height: Int, scale: Float, seed: UInt32) -> SIMD2<Float> {
        guard width > 0, height > 0 else { return .zero }
        let invScale = 1 / max(scale, 2)
        let step = max(1, max(width, height) / 64)
        var sum = SIMD2<Float>.zero
        var count = 0
        var sy = step / 2
        while sy < height {
            var sx = step / 2
            while sx < width {
                sum += field(x: Float(sx), y: Float(sy), invScale: invScale, seed: seed)
                count += 1
                sx += step
            }
            sy += step
        }
        return count > 0 ? sum / Float(count) : .zero
    }
}

/// The Redact compute kernels, in `MetalEditPipeline.redactPipelineStates` order.
nonisolated enum RedactKernel: Int, CaseIterable {
    case distort, blur, mosaic, frost, downsample, upsample

    var functionName: String {
        switch self {
        case .distort: "redactDistort"
        case .blur: "redactBlur"
        case .mosaic: "redactMosaic"
        case .frost: "redactFrost"
        case .downsample: "redactDownsample"
        case .upsample: "redactUpsample"
        }
    }
}

/// One dispatch of the Redact chain.
nonisolated struct RedactStage: Equatable {
    var kernel: RedactKernel
    var blurDirection: Int32 = 0
    /// Texture pixels of the texture the stage works on (blur stages only).
    var blurRadius: Float = 0
    var blurSigma: Float = 0.1
    /// Blur stages between a downsample and an upsample work on a texture reduced by this
    /// factor; the downsample/upsample stages carry it too. 1 = full size.
    var scaleFactor: Int = 1

    /// Largest blur radius run at full size. A wider Gaussian is computed on a box-downsampled
    /// copy and scaled back up: same result to within a fraction of a level, without a
    /// thousand-tap kernel per pixel (or the plugin's 512 px cap, which made large exports
    /// blur less than their preview).
    static let maximumDirectBlurRadius: Float = 256

    /// The plugin's pass order: distort → blur → mosaic (or distort → mosaic → blur with Blur
    /// After Mosaic), then the frost blur and finish. The mosaic stage always runs: it also
    /// desaturates, and passes pixels through when the mosaic layer is off. Blur radii are in
    /// texture pixels; the kernel is truncated at 2 sigma like the plugin.
    static func stages(for settings: RedactRenderSettings, textureScale: Float) -> [RedactStage] {
        var result: [RedactStage] = []
        func addBlur(_ imageRadius: Float) {
            let radius = imageRadius * textureScale
            guard Int(radius.rounded(.up)) >= 1 else { return }
            let sigma = max(radius * 0.5, 0.1)
            guard radius > maximumDirectBlurRadius else {
                result.append(RedactStage(kernel: .blur, blurDirection: 0, blurRadius: radius, blurSigma: sigma))
                result.append(RedactStage(kernel: .blur, blurDirection: 1, blurRadius: radius, blurSigma: sigma))
                return
            }
            let factor = Int((radius / maximumDirectBlurRadius).rounded(.up))
            let f = Float(factor)
            // The f×f box average (variance f²/12) and the bilinear upsample (f²/6) already
            // blur by f²/4; the reduced Gaussian supplies the rest.
            let reducedSigma = max((sigma * sigma - f * f / 4).squareRoot(), 0.25 * f) / f
            let reducedRadius = 2 * reducedSigma
            result.append(RedactStage(kernel: .downsample, scaleFactor: factor))
            result.append(RedactStage(kernel: .blur, blurDirection: 0, blurRadius: reducedRadius,
                                      blurSigma: reducedSigma, scaleFactor: factor))
            result.append(RedactStage(kernel: .blur, blurDirection: 1, blurRadius: reducedRadius,
                                      blurSigma: reducedSigma, scaleFactor: factor))
            result.append(RedactStage(kernel: .upsample, scaleFactor: factor))
        }
        if settings.distortAmount > 0.001 {
            result.append(RedactStage(kernel: .distort))
        }
        if settings.blurAfterMosaic {
            result.append(RedactStage(kernel: .mosaic))
            addBlur(settings.blurRadius)
        } else {
            addBlur(settings.blurRadius)
            result.append(RedactStage(kernel: .mosaic))
        }
        if settings.frostedGlass {
            addBlur(settings.frostBlurRadius)
            result.append(RedactStage(kernel: .frost))
        }
        return result
    }
}
