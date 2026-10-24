import Foundation
import ImageIO

/// The capture identity of one exposure, read from a file's EXIF header.
///
/// Used when a destination file is no longer byte-identical to the card file — a JPEG changes
/// when metadata is embedded into it — to decide whether it is still *that* camera file. A
/// different shot, another body, or an export saved under the original name (resized, or
/// written by other software) must not pass, so every field both sides carry has to agree.
nonisolated struct ImportImageIdentity: Sendable, Equatable {
    let captured: String
    let subSecond: String?
    let serial: String?
    let uniqueID: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let software: String?

    static func read(_ url: URL) -> ImportImageIdentity? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            let string: String?
            if let value = value as? String {
                string = value
            } else if let value = value as? NSNumber {
                string = value.stringValue
            } else {
                string = nil
            }
            let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        guard let captured = text(exif[kCGImagePropertyExifDateTimeOriginal]) else { return nil }
        return ImportImageIdentity(
            captured: captured,
            subSecond: text(exif[kCGImagePropertyExifSubsecTimeOriginal]),
            serial: text(exif[kCGImagePropertyExifBodySerialNumber]) ?? text(aux[kCGImagePropertyExifAuxSerialNumber]),
            uniqueID: text(exif[kCGImagePropertyExifImageUniqueID]),
            pixelWidth: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            pixelHeight: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            software: text(tiff[kCGImagePropertyTIFFSoftware])
        )
    }

    /// True only when both carry a capture time plus at least one fine discriminator (sub-second,
    /// body serial or image unique ID), the Software tag is identical, and every other field
    /// present on both sides is equal.
    func isSameExposure(as other: ImportImageIdentity) -> Bool {
        // Software must match exactly, including absence: camera firmware writes it, and an
        // editor that re-encodes an export stamps its own.
        guard captured == other.captured, subSecond == other.subSecond,
              software == other.software else { return false }
        func agrees<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
            guard let lhs, let rhs else { return true }
            return lhs == rhs
        }
        guard agrees(serial, other.serial),
              agrees(uniqueID, other.uniqueID),
              agrees(pixelWidth, other.pixelWidth),
              agrees(pixelHeight, other.pixelHeight) else { return false }
        let hasDiscriminator = subSecond != nil
            || (serial != nil && other.serial != nil)
            || (uniqueID != nil && other.uniqueID != nil)
        return hasDiscriminator
    }

    /// `destination` is the same camera exposure as `source`, judged from EXIF identity.
    ///
    /// Never for RAW: the app never writes into a RAW, so a RAW copy must be byte-identical — a
    /// truncated or bit-rotted copy still carries a readable EXIF header and would otherwise pass
    /// as "already imported" while the good card file is skipped. A non-RAW copy must also decode
    /// completely, for the same reason.
    static func sameExposure(_ source: URL, _ destination: URL) -> Bool {
        guard !SupportedImageFormats.isRaw(url: source),
              !SupportedImageFormats.isRaw(url: destination),
              decodesCompletely(destination),
              let sourceIdentity = read(source), let destinationIdentity = read(destination) else {
            return false
        }
        return sourceIdentity.isSameExposure(as: destinationIdentity)
    }

    static func decodesCompletely(_ url: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

    /// Byte-identical (size + sampled checksum), or — for an image — the same exposure.
    static func isSameCameraFile(source: URL, destination: URL, isImage: Bool) -> Bool {
        ImportCopyService.filesHaveSameIdentity(source, destination)
            || (isImage && sameExposure(source, destination))
    }
}
