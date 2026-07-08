import CoreImage
import CoreGraphics
import os

enum CameraRawApproximation {
    nonisolated static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    nonisolated static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: workingColorSpace,
    ])
    // 2000 K floor matches CITemperatureAndTint's neutral limit (it returns an identity
    // transform below 2000 K). Adobe Camera RAW allows down to 1500 K; colder imported values
    // are clamped here. Non-RAW files use a relative WB slider (see incrementalTemperature below).
    nonisolated private static let minKelvin = 2000.0
    nonisolated private static let maxKelvin = 50000.0

    /// Render a processed CIImage to an HDR CGImage that *advertises its content headroom*.
    ///
    /// A plain `CALayer` (e.g. the full-screen `HDRImageView`) decides whether to engage EDR
    /// from the CGImage's content-headroom **metadata**, not from a scan of the pixel values.
    /// A CGImage created from a Metal-texture-backed CIImage has *unknown* headroom (0.0), and
    /// per CoreGraphics "an image with unknown content headroom is excluded from tone mapping"
    /// — so an edited HDR image displays clamped to SDR even though it holds >1.0 float values,
    /// while the decoded original (which carries the file's headroom) engages EDR normally.
    ///
    /// We measure the peak channel value (extendedLinearSRGB reference white = 1.0, so the peak
    /// IS the headroom) and stamp it onto the CGImage so the edited preview engages EDR too.
    /// The live develop view is unaffected — it presents the float texture via CAMetalLayer.
    nonisolated static func createDisplayCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        guard let cg = ciContext.createCGImage(
            image, from: rect, format: .RGBAh, colorSpace: workingColorSpace
        ) else { return nil }
        guard #available(macOS 15.0, *) else { return cg }
        let peak = peakChannelValue(of: image, extent: rect)
        guard peak > 1.0 else { return cg }
        return CGImageCreateCopyWithContentHeadroom(peak, cg) ?? cg
    }

    /// Peak (max) R/G/B channel value over `extent`, via a 1×1 CIAreaMaximum reduction.
    nonisolated private static func peakChannelValue(of image: CIImage, extent: CGRect) -> Float {
        guard let maxFilter = CIFilter(name: "CIAreaMaximum", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ]), let maxOut = maxFilter.outputImage else { return 0 }
        var px: [Float] = [0, 0, 0, 0]
        ciContext.render(
            maxOut, toBitmap: &px, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: workingColorSpace
        )
        return max(px[0], px[1], px[2])
    }

    nonisolated static func apply(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CIImage {
        guard let settings else { return input }

        // Primary path: Metal compute shader renders all adjustments in one pass.
        // Uses the exact same shader as the live preview — guarantees pixel-perfect match.
        // `exifOrientation` is the orientation baked into `input`'s pixels; the
        // renderer uses it to move sensor-frame mask geometry into that frame.
        if let metalResult = MetalEditPipeline.renderOffscreen(
            source: input, settings: settings, exifOrientation: exifOrientation
        ) {
            return metalResult
        }
        return metalUnavailableFallback(to: input, settings: settings)
    }

    /// Async sibling of `apply`. Suspends on the dedicated render queue instead of blocking the
    /// caller's thread — use this from `Task`s (prefetch, thumbnail generation) so a slow GPU
    /// render can't starve the cooperative thread pool. Produces identical pixels to `apply`.
    nonisolated static func applyAsync(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) async -> CIImage {
        guard let settings else { return input }
        if let metalResult = await MetalEditPipeline.renderOffscreenAsync(
            source: input, settings: settings, exifOrientation: exifOrientation
        ) {
            return metalResult
        }
        return metalUnavailableFallback(to: input, settings: settings)
    }

    /// CIFilter fallback path shared by `apply` / `applyAsync` (used only when Metal is unavailable).
    /// This path applies global adjustments only — it already drops masks entirely, so the
    /// layer-order (reorderable global node) has no effect here. True layer ordering is a
    /// Metal-only feature; the fallback always renders global-as-base.
    nonisolated private static func metalUnavailableFallback(to input: CIImage, settings: CameraRawSettings) -> CIImage {
        if !(settings.localAdjustments?.isEmpty ?? true) {
            Logger(subsystem: "com.aagedal.photo-agent", category: "CameraRawApproximation")
                .warning("CIFilter fallback: mask adjustments will not be applied")
        }
        if !(settings.hslAdjustments?.isEmpty ?? true) {
            Logger(subsystem: "com.aagedal.photo-agent", category: "CameraRawApproximation")
                .warning("CIFilter fallback: HSL adjustments will not be applied")
        }
        if !(settings.watermarkLayers?.isEmpty ?? true) {
            Logger(subsystem: "com.aagedal.photo-agent", category: "CameraRawApproximation")
                .warning("CIFilter fallback: watermark layers will not be applied")
        }
        return applyCIFilters(to: input, settings: settings)
    }

    /// CIFilter-based fallback for systems without Metal support.
    nonisolated private static func applyCIFilters(to input: CIImage, settings: CameraRawSettings) -> CIImage {
        var output = input

        // 1. White Balance (chromatic adaptation before tonal — matches ACR pipeline order)
        if let target = temperatureTintTarget(for: settings) {
            let targetTemp = CGFloat(settings.asShotNeutralTemperature ?? 6500)
            let targetTint = CGFloat(settings.asShotNeutralTint ?? 0)
            output = applyFilter(named: "CITemperatureAndTint", input: output, values: [
                "inputNeutral": CIVector(x: target.temperature, y: target.tint),
                "inputTargetNeutral": CIVector(x: targetTemp, y: targetTint),
            ]) ?? output
        }

        // 2. Tonal operations via ToneCurveGenerator LUT, approximated as 5-point CIToneCurve.
        if !ToneCurveGenerator.isIdentity(settings: settings) {
            let (rLUT, _, _) = ToneCurveGenerator.generatePerChannelLUT(settings: settings)
            let points = ToneCurveGenerator.sampleForToneCurve(rLUT)
            output = applyFilter(named: "CIToneCurve", input: output, values: [
                "inputPoint0": CIVector(x: points[0].x, y: points[0].y),
                "inputPoint1": CIVector(x: points[1].x, y: points[1].y),
                "inputPoint2": CIVector(x: points[2].x, y: points[2].y),
                "inputPoint3": CIVector(x: points[3].x, y: points[3].y),
                "inputPoint4": CIVector(x: points[4].x, y: points[4].y),
            ]) ?? output
        }

        // 3. Global Density
        if let density = settings.globalDensity, density != 0 {
            let amount = min(max(Double(density) / 100.0, -1.0), 1.0)
            let gain = pow(2.0, -amount)
            let delta = gain - 1.0
            let wr = 0.2126
            let wg = 0.7152
            let wb = 0.0722
            output = applyFilter(named: "CIColorMatrix", input: output, values: [
                "inputRVector": CIVector(x: 1.0 + delta * wr, y: delta * wg, z: delta * wb, w: 0),
                "inputGVector": CIVector(x: delta * wr, y: 1.0 + delta * wg, z: delta * wb, w: 0),
                "inputBVector": CIVector(x: delta * wr, y: delta * wg, z: 1.0 + delta * wb, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]) ?? output
        }

        // 4. Vibrance
        if let vib = settings.vibrance, vib != 0 {
            let amount = min(max(Double(vib) / 100.0, -1.0), 1.0)
            output = applyFilter(named: "CIVibrance", input: output, values: [
                "inputAmount": amount,
            ]) ?? output
        }

        // 5. Saturation
        if let sat = settings.saturation, sat != 0 {
            let saturation = min(max(1.0 + Double(sat) / 100.0, 0.0), 2.0)
            output = applyFilter(named: "CIColorControls", input: output, values: [
                kCIInputSaturationKey: saturation,
            ]) ?? output
        }

        return output
    }

    /// Applies tonal adjustments + crop/rotation in one pass.
    nonisolated static func applyWithCrop(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CIImage {
        guard let settings else { return input }
        let originalExtent = input.extent
        let adjusted = apply(to: input, settings: settings, exifOrientation: exifOrientation)
        return applyCrop(to: adjusted, originalExtent: originalExtent, settings: settings, exifOrientation: exifOrientation)
    }

    /// Async sibling of `applyWithCrop` — suspends on the render queue for the tonal pass, then
    /// applies the (cheap, CPU-only) crop/rotation. Use from `Task`s to avoid blocking the pool.
    nonisolated static func applyWithCropAsync(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) async -> CIImage {
        guard let settings else { return input }
        let originalExtent = input.extent
        let adjusted = await applyAsync(to: input, settings: settings, exifOrientation: exifOrientation)
        return applyCrop(to: adjusted, originalExtent: originalExtent, settings: settings, exifOrientation: exifOrientation)
    }

    /// Applies crop and rotation from CameraRawSettings to a CIImage.
    nonisolated static func applyCrop(to input: CIImage, originalExtent: CGRect, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CIImage {
        guard let sensorCrop = settings?.crop else { return input }
        let crop = sensorCrop.transformedForDisplay(orientation: exifOrientation)
        let hasCrop = crop.hasCrop ?? false
        let angle = crop.angle ?? 0

        // Normalize edge ordering. Do NOT clamp to [0,1]: the stored region is the upright
        // crop rectangle, which — once straightened — can legitimately extend past the image
        // box. The final `.intersection(rotated.extent)` clamps safely instead.
        let rawTop = crop.top ?? 0, rawLeft = crop.left ?? 0
        let rawBottom = crop.bottom ?? 1, rawRight = crop.right ?? 1
        let regionTop = min(rawTop, rawBottom)
        let regionLeft = min(rawLeft, rawRight)
        let regionBottom = max(rawTop, rawBottom)
        let regionRight = max(rawLeft, rawRight)

        let epsilon = 0.0001
        let hasNonDefaultBounds = abs(regionTop) > epsilon
            || abs(regionLeft) > epsilon
            || abs(regionBottom - 1) > epsilon
            || abs(regionRight - 1) > epsilon
        let hasRotation = abs(angle) > epsilon

        guard hasCrop || hasNonDefaultBounds || hasRotation else { return input }
        guard regionRight > regionLeft, regionBottom > regionTop else { return input }

        let extent = originalExtent
        let x = extent.minX + (regionLeft * extent.width)
        let y = extent.minY + ((1 - regionBottom) * extent.height)
        let width = (regionRight - regionLeft) * extent.width
        let height = (regionBottom - regionTop) * extent.height
        guard width > 1, height > 1 else { return input }
        // The full (un-clipped) upright crop rectangle. For a straightened crop this may extend
        // past the image box; the true center stays valid and intersection is applied later.
        let fullCropRect = CGRect(x: x, y: y, width: width, height: height)

        guard hasRotation else {
            let cropRect = fullCropRect.intersection(input.extent)
            guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return input }
            return input.cropped(to: cropRect)
        }

        // Replicate EditWorkspaceView / CropOverlayView crop geometry exactly.
        // 1. Rotate full image around IMAGE center (matches .rotationEffect on the Image view).
        //    CIImage is y-up; SwiftUI is y-down. The y-flip reverses rotation direction,
        //    so we use +angle here to match SwiftUI's .rotationEffect(.degrees(-angle)).
        let viewRadians = CGFloat(angle * .pi / 180.0)
        let imageCenter = CGPoint(x: extent.midX, y: extent.midY)
        let transform = CGAffineTransform(translationX: imageCenter.x, y: imageCenter.y)
            .rotated(by: viewRadians)
            .translatedBy(x: -imageCenter.x, y: -imageCenter.y)
        let rotated = input.transformed(by: transform)

        // 2. The stored region is the upright crop rectangle, so its dimensions are the actual
        //    (straightened) crop dimensions directly — no projection needed.
        let actualWidth = width
        let actualHeight = height

        // 3. Place crop rect at the rotated crop center (CropOverlayView.viewCropRect).
        let cropCenter = CGPoint(x: fullCropRect.midX, y: fullCropRect.midY)
        let newCenter = cropCenter.applying(transform)

        let actualCropRect = CGRect(
            x: newCenter.x - actualWidth / 2,
            y: newCenter.y - actualHeight / 2,
            width: actualWidth,
            height: actualHeight
        ).intersection(rotated.extent)
        guard !actualCropRect.isNull, actualCropRect.width > 1, actualCropRect.height > 1 else { return input }

        return rotated.cropped(to: actualCropRect)
    }

    nonisolated private static func applyFilter(named name: String, input: CIImage, values: [String: Any]) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        for (key, value) in values {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage
    }

    nonisolated private static func temperatureTintTarget(for settings: CameraRawSettings) -> (temperature: CGFloat, tint: CGFloat)? {
        guard let target = settings.resolvedWhiteBalanceTarget(
            absoluteDefaultTemperature: settings.asShotNeutralTemperature ?? 6500,
            absoluteDefaultTint: settings.asShotNeutralTint ?? 0
        ) else { return nil }
        let finalTemperature = min(max(target.temperature, minKelvin), maxKelvin)
        return (temperature: CGFloat(finalTemperature), tint: CGFloat(target.tint))
    }
}
