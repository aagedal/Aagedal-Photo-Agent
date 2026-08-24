import Foundation

/// Parsed representation of a JPEG XL file.
public struct JXLFile: Sendable {
    /// Whether this is a container format (true) or bare codestream (false).
    public let isContainer: Bool
    /// Top-level boxes (only present in container format).
    public var boxes: [ISOBMFFBox]
    /// Pixel dimensions decoded from the JXL codestream SizeHeader, if
    /// available. Set at parse time so callers don't need access to the
    /// raw codestream bytes.
    public let imageDimensions: (width: Int, height: Int)?
    /// The full bare-codestream bytes (including the `FF 0A` signature),
    /// retained only for bare files (`isContainer == false`). The writer
    /// uses these to losslessly wrap the codestream into container format
    /// when metadata boxes must be added; nil for container files.
    public let rawCodestream: Data?

    public init(isContainer: Bool, boxes: [ISOBMFFBox] = [],
                imageDimensions: (width: Int, height: Int)? = nil,
                rawCodestream: Data? = nil) {
        self.isContainer = isContainer
        self.boxes = boxes
        self.imageDimensions = imageDimensions
        self.rawCodestream = rawCodestream
    }

    /// Find the first box of the given type.
    public func findBox(_ type: String) -> ISOBMFFBox? {
        boxes.first { $0.type == type }
    }

    // MARK: - Box Mutation

    /// Replace the first box of the given type, or append if not present.
    public mutating func replaceOrAddBox(_ type: String, data: Data) {
        let newBox = ISOBMFFBox(type: type, data: data)
        if let index = boxes.firstIndex(where: { $0.type == type }) {
            boxes[index] = newBox
        } else {
            boxes.append(newBox)
        }
    }

    /// Remove all boxes of the given type.
    public mutating func removeBox(_ type: String) {
        boxes.removeAll { $0.type == type }
    }
}
