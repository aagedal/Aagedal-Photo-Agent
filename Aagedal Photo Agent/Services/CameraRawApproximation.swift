import CoreImage
import CoreGraphics

enum CameraRawApproximation {
    nonisolated(unsafe) static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    nonisolated(unsafe) static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: workingColorSpace,
    ])
    nonisolated(unsafe) private static let minKelvin = 2000.0
    nonisolated(unsafe) private static let maxKelvin = 50000.0

    nonisolated static func apply(to input: CIImage, settings: CameraRawSettings?) -> CIImage {
        guard let settings else { return input }
        var output = input

        // 1. White Balance (chromatic adaptation before tonal — matches ACR pipeline order)
        if let target = temperatureTintTarget(for: settings) {
            output = applyFilter(named: "CITemperatureAndTint", input: output, values: [
                "inputNeutral": CIVector(x: target.temperature, y: target.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ]) ?? output
        }

        // 2. Tonal operations via ToneCurveGenerator LUT, approximated as 5-point CIToneCurve.
        //    All tonal ops (exposure, contrast, blacks, shadows, highlights, whites) are
        //    combined into a single curve using the same math as the Metal compute shader's LUT.
        //    Note: 5-point Catmull-Rom approximation — near-exact for moderate adjustments,
        //    slight deviation at extremes. Future: CIKernel with full LUT for exact match.
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

        // 3. Vibrance
        if let vib = settings.vibrance, vib != 0 {
            let amount = min(max(Double(vib) / 100.0, -1.0), 1.0)
            output = applyFilter(named: "CIVibrance", input: output, values: [
                "inputAmount": amount,
            ]) ?? output
        }

        // 4. Saturation
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
        let adjusted = apply(to: input, settings: settings)
        return applyCrop(to: adjusted, originalExtent: originalExtent, settings: settings, exifOrientation: exifOrientation)
    }

    /// Applies crop and rotation from CameraRawSettings to a CIImage.
    nonisolated static func applyCrop(to input: CIImage, originalExtent: CGRect, settings: CameraRawSettings?, exifOrientation: Int = 1) -> CIImage {
        guard let sensorCrop = settings?.crop else { return input }
        let crop = sensorCrop.transformedForDisplay(orientation: exifOrientation)
        let hasCrop = crop.hasCrop ?? false
        let angle = crop.angle ?? 0

        // Inline clamping to avoid calling MainActor-isolated NormalizedCropRegion.clamped()
        let regionTop = min(max(crop.top ?? 0, 0), 1)
        let regionLeft = min(max(crop.left ?? 0, 0), 1)
        let regionBottom = min(max(crop.bottom ?? 1, 0), 1)
        let regionRight = min(max(crop.right ?? 1, 0), 1)

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
        let cropRect = CGRect(x: x, y: y, width: width, height: height).intersection(input.extent)
        guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return input }

        guard hasRotation else {
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

        // 2. Forward-project AABB to actual crop dims (CropOverlayView.forwardProjectDims).
        //    Uses the POSITIVE crop angle, not the negated view rotation.
        let fwdRadians = CGFloat(angle * .pi / 180.0)
        let fwdCos = cos(fwdRadians)
        let fwdSin = sin(fwdRadians)
        let actualWidth = abs(width * fwdCos + height * fwdSin)
        let actualHeight = abs(-width * fwdSin + height * fwdCos)

        // 3. Place crop rect at the rotated AABB center (CropOverlayView.viewCropRect).
        let cropCenter = CGPoint(x: cropRect.midX, y: cropRect.midY)
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
        // "As Shot" means no white balance adjustment
        if settings.whiteBalance == "As Shot" { return nil }

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

        guard temperature != nil || tint != nil else { return nil }
        let finalTemperature = min(max(temperature ?? 6500, minKelvin), maxKelvin)
        let finalTint = min(max(tint ?? 0, -150), 150)
        return (temperature: CGFloat(finalTemperature), tint: CGFloat(finalTint))
    }
}
