import Foundation

/// Parsed PSD/PSB file container for metadata access.
/// Only stores metadata-relevant parts; pixel data is preserved via rawData.
public struct PSDFile: Sendable, Equatable {
    /// PSD version: 1 = PSD, 2 = PSB (Large Document).
    public var version: UInt16
    /// Number of channels.
    public var channels: UInt16
    /// Image height in pixels.
    public var height: UInt32
    /// Image width in pixels.
    public var width: UInt32
    /// Bits per channel.
    public var depth: UInt16
    /// Color mode (0=Bitmap, 1=Grayscale, 2=Indexed, 3=RGB, 4=CMYK, 7=Multichannel, 8=Duotone, 9=Lab).
    public var colorMode: UInt16

    /// The raw file data (preserved for byte-for-byte reconstruction).
    public var rawData: Data

    /// Byte ranges of the four PSD sections (for surgical reconstruction).
    public var colorModeDataRange: Range<Int>
    public var imageResourcesRange: Range<Int>
    public var layerMaskDataRange: Range<Int>
    public var imageDataOffset: Int

    /// Parsed IRB blocks from the image resources section.
    public var irbBlocks: [IRBBlock]

    /// Well-known PSD image resource IDs.
    public static let iptcResourceID: UInt16    = 0x0404  // 1028
    public static let exifResourceID: UInt16    = 0x0422  // 1058
    public static let xmpResourceID: UInt16     = 0x0424  // 1060
    public static let iccProfileResourceID: UInt16 = 0x040F // 1039
}
