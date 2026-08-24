import Foundation

/// Parsed representation of an AVIF file.
public struct AVIFFile: Sendable {
    /// Top-level ISOBMFF boxes.
    public var boxes: [ISOBMFFBox]
    /// Major brand from the ftyp box.
    public let brand: String

    public init(boxes: [ISOBMFFBox] = [], brand: String = "avif") {
        self.boxes = boxes
        self.brand = brand
    }

    /// Find the first top-level box of the given type.
    public func findBox(_ type: String) -> ISOBMFFBox? {
        boxes.first { $0.type == type }
    }
}
