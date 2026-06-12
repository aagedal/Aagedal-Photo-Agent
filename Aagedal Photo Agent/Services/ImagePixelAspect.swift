import Foundation
import ImageIO

/// Sensor-frame (un-oriented) pixel aspect ratio of an image file, read from the
/// container header without decoding pixels. Camera Raw's crs crop and mask
/// values are normalized in this frame, so the ACR XMP boundary conversion
/// (`CameraRawCrop.encodedForACR`/`decodedFromACR`) keys off this aspect — not
/// the orientation-corrected display aspect.
nonisolated enum ImagePixelAspect {
    /// width/height of the stored (un-oriented) primary image, or nil when the
    /// file can't be opened as an image.
    static func aspect(at url: URL) -> Double? {
        guard let size = pixelSize(at: url) else { return nil }
        return size.width / size.height
    }

    /// Stored (un-oriented) pixel dimensions from the container header.
    static func pixelSize(at url: URL) -> (width: Double, height: Double)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }
}
