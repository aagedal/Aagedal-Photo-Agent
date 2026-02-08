import CoreImage

enum CameraRawApproximation {
    nonisolated(unsafe) static let ciContext = CIContext(options: [.cacheIntermediates: false])
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

        let contrast = min(max(1.0 + Double(settings.contrast2012 ?? 0) / 100.0, 0.25), 4.0)
        var brightness = 0.0
        if let blacks = settings.blacks2012 { brightness += Double(blacks) / 400.0 }
        if abs(brightness) > 0.0001 || settings.contrast2012 != nil {
            output = applyFilter(named: "CIColorControls", input: output, values: [
                kCIInputBrightnessKey: brightness,
                kCIInputContrastKey: contrast,
            ]) ?? output
        }

        if let whites = settings.whites2012, whites != 0 {
            // Whites should primarily affect the top tonal range, not the black level.
            let whiteHighlightAmount = min(max(1.0 + (Double(whites) / 100.0), 0.0), 2.0)
            output = applyFilter(named: "CIHighlightShadowAdjust", input: output, values: [
                "inputHighlightAmount": whiteHighlightAmount,
                "inputShadowAmount": 0.0,
            ]) ?? output
        }

        if settings.highlights2012 != nil || settings.shadows2012 != nil {
            let highlights = Double(settings.highlights2012 ?? 0)
            let shadows = Double(settings.shadows2012 ?? 0)
            let highlightAmount = min(max(1.0 + (highlights / 100.0), 0.0), 2.0)
            let shadowAmount = min(max(shadows / 100.0, -1.0), 1.0)
            output = applyFilter(named: "CIHighlightShadowAdjust", input: output, values: [
                "inputHighlightAmount": highlightAmount,
                "inputShadowAmount": shadowAmount,
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
