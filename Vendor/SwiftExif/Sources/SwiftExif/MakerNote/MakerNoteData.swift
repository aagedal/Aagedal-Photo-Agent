import Foundation

/// Manufacturer identifier for MakerNote data.
public enum MakerNoteManufacturer: String, Sendable, Equatable {
    case canon = "Canon"
    case nikon = "Nikon"
    case sony = "Sony"
    case fujifilm = "Fujifilm"
    case olympus = "Olympus"
    case panasonic = "Panasonic"
    case dji = "DJI"
    case samsung = "Samsung"
    case apple = "Apple"
    case pentax = "Pentax"
    case leica = "Leica"
    case sigma = "Sigma"
    case unknown = "Unknown"
}

/// A single value extracted from a MakerNote tag.
public enum MakerNoteValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case uint(UInt)
    case double(Double)
    case data(Data)
    case intArray([Int])
}

/// Parsed MakerNote data from a camera manufacturer.
/// The raw data is preserved for lossless round-trip serialization.
public struct MakerNoteData: Sendable {
    public let manufacturer: MakerNoteManufacturer
    public var tags: [String: MakerNoteValue]
    public let rawData: Data
    /// Whether tags have been modified since parsing.
    public private(set) var isDirty: Bool

    public init(manufacturer: MakerNoteManufacturer, tags: [String: MakerNoteValue], rawData: Data) {
        self.manufacturer = manufacturer
        self.tags = tags
        self.rawData = rawData
        self.isDirty = false
    }

    /// Set or update a MakerNote tag value.
    public mutating func setTag(_ key: String, value: MakerNoteValue) {
        tags[key] = value
        isDirty = true
    }

    /// Remove a MakerNote tag.
    public mutating func removeTag(_ key: String) {
        tags.removeValue(forKey: key)
        isDirty = true
    }
}

extension MakerNoteData: Equatable {
    public static func == (lhs: MakerNoteData, rhs: MakerNoteData) -> Bool {
        lhs.manufacturer == rhs.manufacturer &&
        lhs.tags == rhs.tags &&
        lhs.rawData == rhs.rawData
        // isDirty intentionally excluded from equality
    }
}
