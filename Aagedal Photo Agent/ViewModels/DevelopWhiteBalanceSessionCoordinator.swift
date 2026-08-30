import CoreGraphics
import Foundation
import Observation

nonisolated enum DevelopWhiteBalancePersistenceIntent: Equatable, Sendable {
    case previewOnly
    case commit
}

nonisolated struct DevelopWhiteBalanceNeutral: Equatable, Sendable {
    let temperature: Float
    let tint: Float
}

/// Owns the image-scoped white-balance reference and eyedropper interaction state.
///
/// Pixel sampling and metadata persistence remain at the workspace boundary. The coordinator
/// projects pane geometry into source-image coordinates and mutates a settings value while
/// returning an explicit persistence intent, preventing transient picker state from becoming a
/// metadata commit by accident.
@MainActor
@Observable
final class DevelopWhiteBalanceSessionCoordinator {
    static let minimumKelvin = 2_000.0
    static let maximumKelvin = 50_000.0
    static let incrementalTemperatureRange: ClosedRange<Double> = -135...100
    static let tintRange: ClosedRange<Double> = -150...150

    private(set) var activeImageURL: URL?
    private(set) var asShotNeutral: DevelopWhiteBalanceNeutral?
    private(set) var isPickerActive = false
    private var pickRequestID: UUID?
    var dragRectangle: CGRect?

    var asShotTemperatureKelvin: Double {
        Double(asShotNeutral?.temperature ?? 6_500)
    }

    var asShotTint: Double {
        Double(asShotNeutral?.tint ?? 0)
    }

    func beginImageSession(_ imageURL: URL?) {
        activeImageURL = imageURL
        asShotNeutral = nil
        deactivatePicker()
    }

    func endImageSession() {
        activeImageURL = nil
        asShotNeutral = nil
        deactivatePicker()
    }

    /// Rejects late RAW decode publications from a previous image session.
    @discardableResult
    func publishAsShotNeutral(
        temperature: Float,
        tint: Float,
        for imageURL: URL
    ) -> Bool {
        guard activeImageURL == imageURL else { return false }
        asShotNeutral = DevelopWhiteBalanceNeutral(temperature: temperature, tint: tint)
        return true
    }

    @discardableResult
    func togglePicker() -> Bool {
        isPickerActive.toggle()
        dragRectangle = nil
        return isPickerActive
    }

    func deactivatePicker() {
        isPickerActive = false
        pickRequestID = nil
        dragRectangle = nil
    }

    /// Replaces any in-flight sample solve. A result is accepted only while this exact picker
    /// request still belongs to the active image session.
    func beginPickRequest() -> (id: UUID, imageURL: URL)? {
        guard isPickerActive, let activeImageURL else { return nil }
        let requestID = UUID()
        pickRequestID = requestID
        return (requestID, activeImageURL)
    }

    func consumePickResult(requestID: UUID, imageURL: URL) -> Bool {
        guard isPickerActive,
              activeImageURL == imageURL,
              pickRequestID == requestID else { return false }
        pickRequestID = nil
        return true
    }

    func sourceRegion(
        forPaneRect rect: CGRect,
        paneSize: CGSize,
        viewportOrigin: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        sourceExtent: CGRect
    ) -> CGRect? {
        guard paneSize.width > 0, paneSize.height > 0,
              sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

        func uvX(_ x: CGFloat) -> Double {
            Double(viewportOrigin.x) + Double(x / paneSize.width) * Double(viewportSize.x)
        }
        func uvY(_ y: CGFloat) -> Double {
            Double(viewportOrigin.y) + Double(y / paneSize.height) * Double(viewportSize.y)
        }

        let uvMinX = min(max(uvX(rect.minX), 0), 1)
        let uvMaxX = min(max(uvX(rect.maxX), 0), 1)
        let uvMinY = min(max(uvY(rect.minY), 0), 1)
        let uvMaxY = min(max(uvY(rect.maxY), 0), 1)
        guard uvMaxX > uvMinX, uvMaxY > uvMinY else { return nil }

        return CGRect(
            x: sourceExtent.minX + uvMinX * sourceExtent.width,
            y: sourceExtent.minY + (1 - uvMaxY) * sourceExtent.height,
            width: (uvMaxX - uvMinX) * sourceExtent.width,
            height: (uvMaxY - uvMinY) * sourceExtent.height
        )
    }

    func hasUnrepresentableTemperature(
        in settings: CameraRawSettings?,
        usesIncrementalWhiteBalance: Bool
    ) -> Bool {
        guard let settings, settings.whiteBalance != "As Shot" else { return false }
        if usesIncrementalWhiteBalance, let temperature = settings.incrementalTemperature {
            return Double(temperature) < Self.incrementalTemperatureRange.lowerBound
        }
        if !usesIncrementalWhiteBalance, let temperature = settings.temperature {
            return Double(temperature) < Self.minimumKelvin
        }
        return false
    }

    func displayedTemperature(
        in settings: CameraRawSettings?,
        usesIncrementalWhiteBalance: Bool
    ) -> Double {
        if usesIncrementalWhiteBalance {
            return Double(settings?.incrementalTemperature ?? 0)
        }
        let value = Double(settings?.temperature ?? Int(asShotTemperatureKelvin.rounded()))
        return min(max(value, Self.minimumKelvin), Self.maximumKelvin)
    }

    func displayedTint(
        in settings: CameraRawSettings?,
        usesIncrementalWhiteBalance: Bool
    ) -> Double {
        if usesIncrementalWhiteBalance {
            return Double(settings?.incrementalTint ?? 0)
        }
        return Double(settings?.tint ?? Int(asShotTint.rounded()))
    }

    func setDisplayedTemperature(
        _ value: Double,
        usesIncrementalWhiteBalance: Bool,
        in settings: inout CameraRawSettings
    ) -> DevelopWhiteBalancePersistenceIntent {
        settings.whiteBalance = "Custom"
        if usesIncrementalWhiteBalance {
            settings.incrementalTemperature = Int(value.rounded())
        } else {
            let clamped = min(max(value, Self.minimumKelvin), Self.maximumKelvin)
            settings.temperature = Int(clamped.rounded())
        }
        return .previewOnly
    }

    func setDisplayedTint(
        _ value: Double,
        usesIncrementalWhiteBalance: Bool,
        in settings: inout CameraRawSettings
    ) -> DevelopWhiteBalancePersistenceIntent {
        settings.whiteBalance = "Custom"
        if usesIncrementalWhiteBalance {
            settings.incrementalTint = Int(value.rounded())
        } else {
            settings.tint = Int(value.rounded())
        }
        return .previewOnly
    }

    @discardableResult
    func applyPickedWhiteBalance(
        temperatureKelvin: Double,
        tint: Double,
        usesIncrementalWhiteBalance: Bool,
        in settings: inout CameraRawSettings
    ) -> DevelopWhiteBalancePersistenceIntent {
        settings.whiteBalance = "Custom"
        let clampedTint = min(max(tint, Self.tintRange.lowerBound), Self.tintRange.upperBound)
        if usesIncrementalWhiteBalance {
            // Invert the non-RAW render slope: temp = 6500 + increment * (5000 / 150).
            let increment = (temperatureKelvin - 6_500) * (150.0 / 5_000.0)
            let range = Self.incrementalTemperatureRange
            settings.incrementalTemperature = Int(
                min(max(increment, range.lowerBound), range.upperBound).rounded()
            )
            settings.incrementalTint = Int(clampedTint.rounded())
        } else {
            let clampedTemperature = min(
                max(temperatureKelvin, Self.minimumKelvin),
                Self.maximumKelvin
            )
            settings.temperature = Int(clampedTemperature.rounded())
            settings.tint = Int(clampedTint.rounded())
        }
        return .commit
    }

    func normalizedLogScaleValue(forKelvin kelvin: Double) -> Double {
        let clamped = min(max(kelvin, Self.minimumKelvin), Self.maximumKelvin)
        let minLog = log(Self.minimumKelvin)
        let maxLog = log(Self.maximumKelvin)
        return (log(clamped) - minLog) / (maxLog - minLog)
    }

    func kelvinValue(forNormalizedLogScale normalized: Double) -> Double {
        let t = min(max(normalized, 0), 1)
        let minLog = log(Self.minimumKelvin)
        let maxLog = log(Self.maximumKelvin)
        return exp(minLog + (maxLog - minLog) * t)
    }
}
