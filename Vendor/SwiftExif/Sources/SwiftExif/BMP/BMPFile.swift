import Foundation

/// Parsed representation of a BMP file header.
/// BMP files have very limited metadata — we extract basic image properties.
public struct BMPFile: Sendable {
    /// The raw file data (preserved for round-trip).
    public var rawData: Data
    /// Image width in pixels.
    public var width: Int32
    /// Image height in pixels (positive = bottom-up, negative = top-down).
    public var height: Int32
    /// Bits per pixel (1, 4, 8, 16, 24, 32).
    public var bitsPerPixel: UInt16
    /// Compression method (0=none, 1=RLE8, 2=RLE4, 3=Bitfields, etc.).
    public var compression: UInt32
    /// Image data size in bytes (may be 0 for uncompressed).
    public var imageSize: UInt32
    /// Horizontal resolution in pixels per meter.
    public var xPixelsPerMeter: Int32
    /// Vertical resolution in pixels per meter.
    public var yPixelsPerMeter: Int32
    /// Number of colors in the palette (0 = default for bit depth).
    public var colorsUsed: UInt32
    /// Number of important colors (0 = all).
    public var colorsImportant: UInt32
    /// Size of the file in bytes.
    public var fileSize: UInt32
    /// DIB header size (determines BMP version: 12=OS/2, 40=BITMAPINFOHEADER, 108=V4, 124=V5).
    public var dibHeaderSize: UInt32
    /// Number of color planes (always 1).
    public var colorPlanes: UInt16

    public init(rawData: Data = Data(), width: Int32 = 0, height: Int32 = 0,
                bitsPerPixel: UInt16 = 0, compression: UInt32 = 0,
                imageSize: UInt32 = 0, xPixelsPerMeter: Int32 = 0, yPixelsPerMeter: Int32 = 0,
                colorsUsed: UInt32 = 0, colorsImportant: UInt32 = 0,
                fileSize: UInt32 = 0, dibHeaderSize: UInt32 = 0, colorPlanes: UInt16 = 1) {
        self.rawData = rawData
        self.width = width
        self.height = height
        self.bitsPerPixel = bitsPerPixel
        self.compression = compression
        self.imageSize = imageSize
        self.xPixelsPerMeter = xPixelsPerMeter
        self.yPixelsPerMeter = yPixelsPerMeter
        self.colorsUsed = colorsUsed
        self.colorsImportant = colorsImportant
        self.fileSize = fileSize
        self.dibHeaderSize = dibHeaderSize
        self.colorPlanes = colorPlanes
    }

    /// Absolute height (BMP height can be negative for top-down images).
    public var absoluteHeight: Int32 {
        abs(height)
    }

    /// Human-readable compression name.
    public var compressionName: String {
        switch compression {
        case 0: return "None"
        case 1: return "RLE8"
        case 2: return "RLE4"
        case 3: return "Bitfields"
        case 4: return "JPEG"
        case 5: return "PNG"
        case 6: return "Alphabitfields"
        default: return "Unknown (\(compression))"
        }
    }

    /// BMP version string based on DIB header size.
    public var bmpVersion: String {
        switch dibHeaderSize {
        case 12: return "OS/2 1.x"
        case 40: return "Windows 3.x"
        case 52: return "BITMAPV2INFOHEADER"
        case 56: return "BITMAPV3INFOHEADER"
        case 108: return "Windows 4.x (V4)"
        case 124: return "Windows 5.x (V5)"
        default: return "Unknown"
        }
    }

    /// Horizontal DPI calculated from pixels per meter.
    public var xDPI: Double {
        Double(xPixelsPerMeter) * 0.0254
    }

    /// Vertical DPI calculated from pixels per meter.
    public var yDPI: Double {
        Double(yPixelsPerMeter) * 0.0254
    }
}
