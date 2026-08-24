import Foundation

/// Normalized area coordinates for an XMP region.
/// Values are in the range 0-1, relative to image dimensions.
public struct XMPRegionArea: Equatable, Sendable {
    /// Center X coordinate (0-1).
    public var x: Double
    /// Center Y coordinate (0-1).
    public var y: Double
    /// Width (0-1).
    public var w: Double
    /// Height (0-1).
    public var h: Double
    /// Unit type (default: "normalized").
    public var unit: String

    public init(x: Double, y: Double, w: Double, h: Double, unit: String = "normalized") {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.unit = unit
    }
}

/// Type of an XMP region.
public enum XMPRegionType: String, Sendable, CaseIterable, Equatable {
    case face = "Face"
    case pet = "Pet"
    case focus = "Focus"
    case barCode = "BarCode"
}

/// A single region within an image, following the MWG Regions specification.
public struct XMPRegion: Equatable, Sendable {
    /// Name of the person/subject in the region.
    public var name: String?
    /// Region type (Face, Pet, Focus, BarCode).
    public var type: XMPRegionType?
    /// Area coordinates in normalized form.
    public var area: XMPRegionArea
    /// Optional description.
    public var description: String?

    public init(name: String? = nil, type: XMPRegionType? = nil, area: XMPRegionArea, description: String? = nil) {
        self.name = name
        self.type = type
        self.area = area
        self.description = description
    }
}

/// A list of regions associated with an image, following the MWG Regions specification.
public struct XMPRegionList: Equatable, Sendable {
    /// The regions in the image.
    public var regions: [XMPRegion]
    /// Image width the regions were applied to (pixels).
    public var appliedToDimensionsW: Int?
    /// Image height the regions were applied to (pixels).
    public var appliedToDimensionsH: Int?
    /// Unit for applied dimensions (typically "pixel").
    public var appliedToDimensionsUnit: String?

    public init(
        regions: [XMPRegion] = [],
        appliedToDimensionsW: Int? = nil,
        appliedToDimensionsH: Int? = nil,
        appliedToDimensionsUnit: String? = nil
    ) {
        self.regions = regions
        self.appliedToDimensionsW = appliedToDimensionsW
        self.appliedToDimensionsH = appliedToDimensionsH
        self.appliedToDimensionsUnit = appliedToDimensionsUnit
    }
}
