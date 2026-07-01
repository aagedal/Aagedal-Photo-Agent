import Foundation

/// One named PNG in the reusable, optionally iCloud-synced Watermark library
/// (`WatermarkStore`). The PNG bytes themselves are a co-located sibling file
/// (`image.png`, next to this record's `meta.json`) rather than inline, so
/// `CloudCoordinatedIO` syncs both together and a `WatermarkLayer` can reference
/// this asset by `id` without carrying the image data itself.
nonisolated struct WatermarkAsset: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var createdAt: Date
    var updatedAt: Date

    /// Default placement applied to a newly-added watermark LAYER created from this asset,
    /// so a logo that's always used the same way (e.g. a station bug always at 15% width)
    /// doesn't need re-adjusting every time — rather than always starting from the app-wide
    /// default (20% width / 10% margin).
    var defaultSizeDimension: WatermarkDimension = .width
    var defaultSizeUnit: WatermarkSizeUnit = .percent
    var defaultSizeValue: Double = 20
    var defaultMarginUnit: WatermarkMarginUnit = .percent
    var defaultMarginValue: Double = 10

    var aspectRatio: Double {
        pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1
    }

    init(
        id: UUID = UUID(),
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        defaultSizeDimension: WatermarkDimension = .width,
        defaultSizeUnit: WatermarkSizeUnit = .percent,
        defaultSizeValue: Double = 20,
        defaultMarginUnit: WatermarkMarginUnit = .percent,
        defaultMarginValue: Double = 10
    ) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.defaultSizeDimension = defaultSizeDimension
        self.defaultSizeUnit = defaultSizeUnit
        self.defaultSizeValue = defaultSizeValue
        self.defaultMarginUnit = defaultMarginUnit
        self.defaultMarginValue = defaultMarginValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pixelWidth, pixelHeight, createdAt, updatedAt
        case defaultSizeDimension, defaultSizeUnit, defaultSizeValue, defaultMarginUnit, defaultMarginValue
    }

    /// Custom decoder so `meta.json` files written before the default-placement fields
    /// existed still load — a missing-key decode failure would otherwise make an
    /// already-imported watermark silently vanish from the library after this update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        defaultSizeDimension = try c.decodeIfPresent(WatermarkDimension.self, forKey: .defaultSizeDimension) ?? .width
        defaultSizeUnit = try c.decodeIfPresent(WatermarkSizeUnit.self, forKey: .defaultSizeUnit) ?? .percent
        defaultSizeValue = try c.decodeIfPresent(Double.self, forKey: .defaultSizeValue) ?? 20
        defaultMarginUnit = try c.decodeIfPresent(WatermarkMarginUnit.self, forKey: .defaultMarginUnit) ?? .percent
        defaultMarginValue = try c.decodeIfPresent(Double.self, forKey: .defaultMarginValue) ?? 10
    }
}
