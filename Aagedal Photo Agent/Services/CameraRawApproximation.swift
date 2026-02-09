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
    nonisolated(unsafe) private static let maxKelvin = 12000.0

    nonisolated static func apply(to input: CIImage, settings: CameraRawSettings?) -> CIImage {
        guard let settings else { return input }
        var output = input

        if let exposure = settings.exposure2012, abs(exposure) > 0.0001 {
            output = applyFilter(named: "CIExposureAdjust", input: output, values: [
                kCIInputEVKey: exposure,
            ]) ?? output
        }

        let contrast = min(max(1.0 + Double(settings.contrast2012 ?? 0) / 1000.0, 0.25), 4.0)
        var brightness = 0.0
        if let blacks = settings.blacks2012 { brightness += Double(blacks) / 4000.0 }
        if abs(brightness) > 0.0001 || settings.contrast2012 != nil {
            output = applyFilter(named: "CIColorControls", input: output, values: [
                kCIInputBrightnessKey: brightness,
                kCIInputContrastKey: contrast,
            ]) ?? output
        }

        if settings.highlights2012 != nil || settings.shadows2012 != nil
            || settings.whites2012 != nil
        {
            let highlights = Double(settings.highlights2012 ?? 0)
            let whites = Double(settings.whites2012 ?? 0)
            let shadows = Double(settings.shadows2012 ?? 0)

            // CIHighlightShadowAdjust: inputHighlightAmount 0..1 (1 = no change, 0 = full recovery)
            // Negative highlights/whites reduce bright areas; combine both for the recovery direction.
            let negHighlight = min(highlights, 0) / 100.0  // -1..0
            let negWhites = min(whites, 0) / 100.0          // -1..0
            let highlightAmount = max(1.0 + (negHighlight + negWhites) * 0.5, 0.0)
            let shadowAmount = min(max(shadows / 1000.0, -1.0), 1.0)

            output = applyFilter(named: "CIHighlightShadowAdjust", input: output, values: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": shadowAmount,
            ]) ?? output

            // Positive highlights/whites boost the upper tonal range via a tone curve.
            let posHighlight = max(highlights, 0) / 100.0  // 0..1
            let posWhites = max(whites, 0) / 100.0          // 0..1
            let boost = (posHighlight + posWhites) * 0.5
            if boost > 0.001 {
                // Lift the upper quarter of the tone curve to brighten highlights.
                let midPoint = min(0.75 + boost * 0.1, 0.95)
                let topPoint = min(1.0 + boost * 0.15, 1.2)
                output = applyFilter(named: "CIToneCurve", input: output, values: [
                    "inputPoint0": CIVector(x: 0.0, y: 0.0),
                    "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5),
                    "inputPoint3": CIVector(x: CGFloat(midPoint), y: CGFloat(midPoint)),
                    "inputPoint4": CIVector(x: 1.0, y: CGFloat(topPoint)),
                ]) ?? output
            }
        }

        if let sat = settings.saturation, sat != 0 {
            let saturation = min(max(1.0 + Double(sat) / 100.0, 0.0), 2.0)
            output = applyFilter(named: "CIColorControls", input: output, values: [
                kCIInputSaturationKey: saturation,
            ]) ?? output
        }

        if let target = temperatureTintTarget(for: settings) {
            output = applyFilter(named: "CITemperatureAndTint", input: output, values: [
                "inputNeutral": CIVector(x: target.temperature, y: target.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ]) ?? output
        }

        return output
    }

    /// Applies tonal adjustments + crop/rotation in one pass.
    nonisolated static func applyWithCrop(to input: CIImage, settings: CameraRawSettings?) -> CIImage {
        guard let settings else { return input }
        let originalExtent = input.extent
        let adjusted = apply(to: input, settings: settings)
        return applyCrop(to: adjusted, originalExtent: originalExtent, settings: settings)
    }

    /// Applies crop and rotation from CameraRawSettings to a CIImage.
    nonisolated static func applyCrop(to input: CIImage, originalExtent: CGRect, settings: CameraRawSettings?) -> CIImage {
        guard let crop = settings?.crop else { return input }
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

        let radians = CGFloat(-angle * .pi / 180.0)
        let cosA = cos(radians)
        let sinA = sin(radians)
        let actualWidth = abs(width * cosA - height * sinA)
        let actualHeight = abs(width * sinA + height * cosA)

        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)

        let rotated = input.transformed(by: transform)
        let actualCropRect = CGRect(
            x: center.x - actualWidth / 2,
            y: center.y - actualHeight / 2,
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
