import CoreImage
import CoreGraphics
import os

/// Test seam: makes every offscreen GPU edit render report failure, as a texture-allocation,
/// command-buffer or upload failure would. Task-local, so it only affects the test that binds
/// it (and work that explicitly re-binds it across a detached hop, like `renderItem`).
nonisolated enum GPURenderFaultInjection {
    @TaskLocal static var forceFailure = false
}

/// An output render refused because the GPU render failed and the CIFilter fallback can't
/// reproduce the edit (it drops masks, the Anonymizer and watermarks). Nothing is written.
nonisolated struct EditRenderRefusedError: LocalizedError, Sendable, Equatable {
    let filename: String?
    let hasRedaction: Bool

    var errorDescription: String? {
        let prefix = filename.map { "\($0): " } ?? ""
        if hasRedaction {
            return prefix + "The edit couldn't be rendered on the GPU; the photo has redactions, so it wasn't exported."
        }
        return prefix + "The edit couldn't be rendered on the GPU; the photo has masks or watermarks that can't be rendered without it, so it wasn't exported."
    }
}

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
        let peak = contentHeadroom(of: image, extent: rect)
        guard peak > 1.0 else { return cg }
        return CGImageCreateCopyWithContentHeadroom(peak, cg) ?? cg
    }

    /// Peak (max) R/G/B channel value over `extent`, via a 1×1 CIAreaMaximum reduction.
    /// This is also used when authoring an Adaptive HDR gain map because ImageIO needs
    /// the edited image's content headroom after the Metal render has discarded the
    /// source CIImage's original headroom property.
    nonisolated static func contentHeadroom(of image: CIImage, extent: CGRect) -> Float {
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

    // MARK: - Render entry points
    //
    // Privacy rule: the CIFilter fallback (used when the GPU render returns nil: Metal
    // unavailable, texture allocation, command buffer or upload failure) renders global
    // adjustments only. It cannot reproduce masks (including Anonymizer face blurs and Black
    // Out), the global Anonymizer, or watermark layers. When the settings carry any of those,
    // the fallback is refused: output renders throw `EditRenderRefusedError` (nothing is
    // encoded), and previews show a neutral placeholder instead of unredacted pixels (a preview
    // can be screen-shared).

    /// Whether the CIFilter fallback can stand in for a failed GPU render of `settings`:
    /// no redaction, no enabled mask layer, no enabled watermark layer.
    nonisolated static func fallbackCanReproduce(_ settings: CameraRawSettings) -> Bool {
        if settings.hasActiveRedaction { return false }
        if settings.localAdjustments?.contains(where: \.enabled) == true { return false }
        if settings.watermarkLayers?.contains(where: \.enabled) == true { return false }
        return true
    }

    /// A neutral mid-grey stand-in with `input`'s extent, shown by previews when the GPU render
    /// failed for settings the fallback can't reproduce. Never derived from the source pixels.
    nonisolated static func redactionSafePlaceholder(for input: CIImage) -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: input.extent)
    }

    /// CGImage form of `redactionSafePlaceholder`, for callers that would otherwise fall back to
    /// the unedited source CGImage when materializing an edit fails.
    nonisolated static func redactionSafePlaceholderCGImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Preview render (Develop scopes, full screen, thumbnails). A refused fallback yields
    /// `redactionSafePlaceholder`, never the unredacted input.
    nonisolated static func apply(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CIImage {
        guard let settings else { return input }
        return applyOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation)
            ?? redactionSafePlaceholder(for: input)
    }

    /// Async sibling of `apply`. Suspends on the dedicated render queue instead of blocking the
    /// caller's thread — use this from `Task`s (prefetch, thumbnail generation) so a slow GPU
    /// render can't starve the cooperative thread pool. Produces identical pixels to `apply`.
    /// Cancellation returns the unchanged input (callers discard their cancelled request),
    /// except for settings the fallback can't reproduce, which get the placeholder.
    nonisolated static func applyAsync(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) async -> CIImage {
        guard let settings else { return input }
        guard !Task.isCancelled else { return cancelledPreviewResult(input, settings: settings) }
        let result = await applyAsyncOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation)
        guard !Task.isCancelled else { return cancelledPreviewResult(input, settings: settings) }
        return result ?? redactionSafePlaceholder(for: input)
    }

    /// GPU render, else the CIFilter fallback when it can reproduce `settings`; nil = refused.
    nonisolated private static func applyOrRefuse(
        to input: CIImage, settings: CameraRawSettings, exifOrientation: Int
    ) -> CIImage? {
        // Primary path: Metal compute shader renders all adjustments in one pass.
        // Uses the exact same shader as the live preview — guarantees pixel-perfect match.
        // `exifOrientation` is the orientation baked into `input`'s pixels; the
        // renderer uses it to move sensor-frame mask geometry into that frame.
        if !GPURenderFaultInjection.forceFailure,
           let metalResult = MetalEditPipeline.renderOffscreen(
               source: input, settings: settings, exifOrientation: exifOrientation
           ) {
            return metalResult
        }
        return fallbackOrRefuse(to: input, settings: settings)
    }

    nonisolated private static func applyAsyncOrRefuse(
        to input: CIImage, settings: CameraRawSettings, exifOrientation: Int
    ) async -> CIImage? {
        if !GPURenderFaultInjection.forceFailure,
           let metalResult = await MetalEditPipeline.renderOffscreenAsync(
               source: input, settings: settings, exifOrientation: exifOrientation
           ) {
            return metalResult
        }
        if Task.isCancelled { return nil }
        return fallbackOrRefuse(to: input, settings: settings)
    }

    nonisolated private static func cancelledPreviewResult(_ input: CIImage, settings: CameraRawSettings) -> CIImage {
        fallbackCanReproduce(settings) ? input : redactionSafePlaceholder(for: input)
    }

    nonisolated private static func fallbackOrRefuse(to input: CIImage, settings: CameraRawSettings) -> CIImage? {
        guard fallbackCanReproduce(settings) else {
            Logger(subsystem: "com.aagedal.photo-agent", category: "CameraRawApproximation")
                .error("GPU render failed; CIFilter fallback refused (redaction=\(settings.hasActiveRedaction, privacy: .public)): it can't render masks, the Anonymizer or watermarks")
            return nil
        }
        return metalUnavailableFallback(to: input, settings: settings)
    }

    /// CIFilter fallback path shared by `apply` / `applyAsync` (used only when the GPU render
    /// failed). It applies global adjustments only and is reached only for settings that pass
    /// `fallbackCanReproduce` (no enabled masks, no Anonymizer, no enabled watermarks), so the
    /// layer order (reorderable global node) has no effect here.
    nonisolated private static func metalUnavailableFallback(to input: CIImage, settings: CameraRawSettings) -> CIImage {
        if !(settings.hslAdjustments?.isEmpty ?? true) {
            Logger(subsystem: "com.aagedal.photo-agent", category: "CameraRawApproximation")
                .warning("CIFilter fallback: HSL adjustments will not be applied")
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
        let needsSDROutputToneMap = settings.sourceHasHDRHeadroom == true && settings.hdrEditMode != 1
        if !ToneCurveGenerator.isIdentity(settings: settings) || needsSDROutputToneMap {
            let (rLUT, _, _) = ToneCurveGenerator.generatePerChannelLUT(
                settings: settings,
                includeOutputToneMap: needsSDROutputToneMap
            )
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

        // 6. Dehaze. The Metal path uses a dark-channel atmospheric model; this fallback
        // keeps the same signed direction with coordinated contrast, saturation, and veil lift.
        if let dehaze = settings.dehaze, dehaze != 0 {
            let amount = min(max(Double(dehaze) / 100.0, -1.0), 1.0)
            output = applyFilter(named: "CIColorControls", input: output, values: [
                kCIInputContrastKey: 1.0 + amount * 0.55,
                kCIInputSaturationKey: 1.0 + amount * 0.20,
                kCIInputBrightnessKey: -amount * 0.04,
            ]) ?? output
        }

        // 7. Clarity and sharpness. Positive clarity is a large-radius unsharp mask;
        // negative clarity softly blends toward a blurred copy. Sharpness remains fine-radius.
        if let clarity = settings.clarity2012, clarity != 0 {
            let amount = min(max(Double(clarity) / 100.0, -1.0), 1.0)
            if amount > 0 {
                let radius = min(max(min(output.extent.width, output.extent.height) * 0.008, 8), 64)
                output = (applyFilter(named: "CIUnsharpMask", input: output, values: [
                    kCIInputRadiusKey: radius,
                    kCIInputIntensityKey: amount * 0.45,
                ]) ?? output).cropped(to: output.extent)
            } else if let blurred = applyFilter(named: "CIGaussianBlur", input: output, values: [
                kCIInputRadiusKey: -amount * 8.0,
            ])?.cropped(to: output.extent) {
                output = applyFilter(named: "CIDissolveTransition", input: output, values: [
                    "inputTargetImage": blurred,
                    kCIInputTimeKey: -amount * 0.15,
                ]) ?? output
            }
        }
        if let sharpness = settings.sharpness, sharpness != 0 {
            let amount = min(max(Double(sharpness) / 150.0, 0.0), 1.0)
            output = applyFilter(named: "CISharpenLuminance", input: output, values: [
                kCIInputSharpnessKey: amount * 2.0,
                kCIInputRadiusKey: 1.0,
            ]) ?? output
        }

        return output
    }

    /// Applies tonal adjustments + crop/rotation in one pass (preview: a refused fallback
    /// yields the placeholder).
    nonisolated static func applyWithCrop(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CIImage {
        guard let settings else { return input }
        return applyWithCropOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation)
            ?? redactionSafePlaceholder(for: input)
    }

    /// Async sibling of `applyWithCrop` — suspends on the render queue for the tonal pass, then
    /// applies the (cheap, CPU-only) crop/rotation. Use from `Task`s to avoid blocking the pool.
    nonisolated static func applyWithCropAsync(to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1) async -> CIImage {
        guard let settings else { return input }
        guard !Task.isCancelled else { return cancelledPreviewResult(input, settings: settings) }
        let result = await applyWithCropAsyncOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation)
        guard !Task.isCancelled else { return cancelledPreviewResult(input, settings: settings) }
        return result ?? redactionSafePlaceholder(for: input)
    }

    /// Output render (export, Save As, Sign, FTP, Develop Save): throws instead of ever
    /// returning pixels that miss a mask, Anonymizer or watermark the settings carry.
    nonisolated static func applyWithCropForOutput(
        to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1, sourceURL: URL? = nil
    ) throws -> CIImage {
        guard let settings else { return input }
        guard let result = applyWithCropOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation) else {
            throw EditRenderRefusedError(filename: sourceURL?.lastPathComponent, hasRedaction: settings.hasActiveRedaction)
        }
        return result
    }

    /// Async sibling of `applyWithCropForOutput`. Cancellation throws `CancellationError`
    /// (never returns the unedited input).
    nonisolated static func applyWithCropForOutputAsync(
        to input: CIImage, settings: CameraRawSettings?, exifOrientation: Int = 1, sourceURL: URL? = nil
    ) async throws -> CIImage {
        try Task.checkCancellation()
        guard let settings else { return input }
        let result = await applyWithCropAsyncOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation)
        try Task.checkCancellation()
        guard let result else {
            throw EditRenderRefusedError(filename: sourceURL?.lastPathComponent, hasRedaction: settings.hasActiveRedaction)
        }
        return result
    }

    nonisolated private static func applyWithCropOrRefuse(
        to input: CIImage, settings: CameraRawSettings, exifOrientation: Int
    ) -> CIImage? {
        if settings.crop?.isEffectiveCrop == true,
           settings.watermarkLayers?.contains(where: { $0.enabled }) == true,
           !GPURenderFaultInjection.forceFailure,
           let croppedMetalResult = MetalEditPipeline.renderOffscreenCropped(
                source: input, settings: settings, exifOrientation: exifOrientation
           ) {
            return croppedMetalResult
        }
        let originalExtent = input.extent
        guard let adjusted = applyOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation) else {
            return nil
        }
        return applyCrop(to: adjusted, originalExtent: originalExtent, settings: settings, exifOrientation: exifOrientation)
    }

    nonisolated private static func applyWithCropAsyncOrRefuse(
        to input: CIImage, settings: CameraRawSettings, exifOrientation: Int
    ) async -> CIImage? {
        if settings.crop?.isEffectiveCrop == true,
           settings.watermarkLayers?.contains(where: { $0.enabled }) == true,
           !GPURenderFaultInjection.forceFailure,
           let croppedMetalResult = await MetalEditPipeline.renderOffscreenCroppedAsync(
                source: input, settings: settings, exifOrientation: exifOrientation
           ) {
            return croppedMetalResult
        }
        if Task.isCancelled { return nil }
        let originalExtent = input.extent
        guard let adjusted = await applyAsyncOrRefuse(to: input, settings: settings, exifOrientation: exifOrientation),
              !Task.isCancelled else {
            return nil
        }
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
