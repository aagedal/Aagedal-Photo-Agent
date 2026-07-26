import Foundation

/// A reusable snapshot of the controls in the Develop workspace.
///
/// Image-specific decoder state is deliberately excluded when a template is
/// created and restored from the destination image when it is applied.
struct DevelopTemplate: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var settings: CameraRawSettings
    var shortcutSlot: Int?
    var includesCrop: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        settings: CameraRawSettings = CameraRawSettings(),
        shortcutSlot: Int? = nil,
        includesCrop: Bool = true
    ) {
        self.id = id
        self.name = name
        self.settings = settings.settingsForDevelopTemplate
        self.shortcutSlot = shortcutSlot
        self.includesCrop = includesCrop
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, settings, shortcutSlot, includesCrop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        settings = try container.decode(CameraRawSettings.self, forKey: .settings).settingsForDevelopTemplate
        shortcutSlot = try container.decodeIfPresent(Int.self, forKey: .shortcutSlot)
        // Templates saved before crop inclusion became configurable always
        // applied their stored crop, so preserve that behavior when migrating.
        includesCrop = try container.decodeIfPresent(Bool.self, forKey: .includesCrop) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(shortcutSlot, forKey: .shortcutSlot)
        try container.encode(includesCrop, forKey: .includesCrop)
    }

    /// A compact description used by the selector and Settings list.
    var summary: String {
        var parts: [String] = []
        if settings.hasTemplateGlobalAdjustments { parts.append("Global") }
        if includesCrop, settings.crop?.isEffectiveCrop == true { parts.append("Crop") }
        if let count = settings.localAdjustments?.count, count > 0 {
            parts.append("\(count) mask\(count == 1 ? "" : "s")")
        }
        if let count = settings.watermarkLayers?.count, count > 0 {
            parts.append("\(count) watermark\(count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No adjustments" : parts.joined(separator: " • ")
    }

    /// Returns a copy suitable for a different image. Layer identifiers are
    /// regenerated so every application owns independent masks/watermarks, while
    /// decoder state and unknown ACR corrections remain attached to the target.
    func settingsForApplication(preserving target: CameraRawSettings?) -> CameraRawSettings {
        var applied = settings.settingsForDevelopTemplate

        var maskIDMap: [UUID: UUID] = [:]
        if let masks = applied.localAdjustments {
            applied.localAdjustments = masks.map { mask in
                var copy = mask
                let newID = UUID()
                maskIDMap[mask.id] = newID
                copy.id = newID
                return copy
            }
        }

        var watermarkIDMap: [UUID: UUID] = [:]
        if let watermarks = applied.watermarkLayers {
            applied.watermarkLayers = watermarks.map { watermark in
                var copy = watermark
                let newID = UUID()
                watermarkIDMap[watermark.id] = newID
                copy.id = newID
                return copy
            }
        }

        if let order = applied.layerOrder {
            applied.layerOrder = order.compactMap { ref in
                switch ref {
                case .global:
                    return .global
                case .mask(let id):
                    return maskIDMap[id].map(LayerRef.mask)
                case .watermark(let id):
                    return watermarkIDMap[id].map(LayerRef.watermark)
                }
            }
        }

        applied.asShotNeutralTemperature = target?.asShotNeutralTemperature
        applied.asShotNeutralTint = target?.asShotNeutralTint
        applied.sourceHasHDRHeadroom = target?.sourceHasHDRHeadroom
        applied.unparsedMaskCorrections = target?.unparsedMaskCorrections
        if !includesCrop {
            applied.crop = target?.crop
        }
        return applied
    }
}

private extension CameraRawSettings {
    var settingsForDevelopTemplate: CameraRawSettings {
        var copy = self
        copy.asShotNeutralTemperature = nil
        copy.asShotNeutralTint = nil
        copy.sourceHasHDRHeadroom = nil
        copy.unparsedMaskCorrections = nil
        return copy
    }

    var hasTemplateGlobalAdjustments: Bool {
        (whiteBalance != nil && whiteBalance != "As Shot")
            || temperature != nil
            || tint != nil
            || incrementalTemperature != nil
            || incrementalTint != nil
            || exposure2012 != nil
            || contrast2012 != nil
            || highlights2012 != nil
            || shadows2012 != nil
            || whites2012 != nil
            || blacks2012 != nil
            || saturation != nil
            || vibrance != nil
            || globalDensity != nil
            || sharpness != nil
            || clarity2012 != nil
            || dehaze != nil
            || hdrEditMode != nil
            || hdrMaxValue != nil
            || sdrBrightness != nil
            || sdrContrast != nil
            || sdrClarity != nil
            || sdrHighlights != nil
            || sdrShadows != nil
            || sdrWhites != nil
            || sdrBlend != nil
            || toneCurve != nil
            || !(hslAdjustments?.isEmpty ?? true)
            || (anonymizer?.isEmpty == false)
            || (filmEmulation?.isEmpty == false)
    }
}
