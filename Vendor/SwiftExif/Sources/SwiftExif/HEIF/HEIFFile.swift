import Foundation

/// Parsed representation of a HEIF/HEIC file.
public struct HEIFFile: Sendable {
    /// Top-level ISOBMFF boxes.
    public var boxes: [ISOBMFFBox]
    /// Major brand from the ftyp box (e.g. "heic", "heix", "mif1").
    public let brand: String

    public init(boxes: [ISOBMFFBox] = [], brand: String = "heic") {
        self.boxes = boxes
        self.brand = brand
    }

    /// Find the first top-level box of the given type.
    public func findBox(_ type: String) -> ISOBMFFBox? {
        boxes.first { $0.type == type }
    }
}
