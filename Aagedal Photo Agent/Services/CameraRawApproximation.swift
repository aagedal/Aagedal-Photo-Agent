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

        if let target = temperatureTintTarget(for: settings) {
            output = applyFilter(named: "CITemperatureAndTint", input: output, values: [
                "inputNeutral": CIVector(x: target.temperature, y: target.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ]) ?? output
        }

        return output
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
