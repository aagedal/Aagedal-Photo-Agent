import Foundation

/// A single key-value pair in a CBOR map.
public struct CBORMapEntry: Sendable {
    public let key: CBORValue
    public let value: CBORValue

    public init(key: CBORValue, value: CBORValue) {
        self.key = key
        self.value = value
    }
}

/// A decoded CBOR (RFC 8949) value.
public enum CBORValue: Sendable {
    case unsignedInt(UInt64)
    case negativeInt(Int64)
    case byteString(Data)
    case textString(String)
    case array([CBORValue])
    case map([CBORMapEntry])
    indirect case tagged(UInt64, CBORValue)
    case boolean(Bool)
    case null
    case undefined
    case float(Double)
    case simple(UInt8)
}

// MARK: - Convenience Accessors

extension CBORValue {

    /// Extract a text string value, or nil.
    public var textStringValue: String? {
        if case .textString(let s) = self { return s }
        return nil
    }

    /// Extract a byte string value, or nil.
    public var byteStringValue: Data? {
        if case .byteString(let d) = self { return d }
        return nil
    }

    /// Extract an unsigned integer value, or nil.
    public var unsignedIntValue: UInt64? {
        if case .unsignedInt(let n) = self { return n }
        return nil
    }

    /// Extract a negative integer value, or nil.
    public var negativeIntValue: Int64? {
        if case .negativeInt(let n) = self { return n }
        return nil
    }

    /// Extract an integer value (signed), handling both unsigned and negative cases.
    public var intValue: Int64? {
        switch self {
        case .unsignedInt(let n): return Int64(exactly: n)
        case .negativeInt(let n): return n
        default: return nil
        }
    }

    /// Extract an array value, or nil.
    public var arrayValue: [CBORValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Extract map entries, or nil.
    public var mapEntries: [CBORMapEntry]? {
        if case .map(let m) = self { return m }
        return nil
    }

    /// Extract a boolean value, or nil.
    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    /// Extract the tagged value and tag number, or nil.
    public var taggedValue: (tag: UInt64, value: CBORValue)? {
        if case .tagged(let tag, let value) = self { return (tag, value) }
        return nil
    }

    /// Look up a value by text string key in a map.
    public subscript(key: String) -> CBORValue? {
        guard case .map(let entries) = self else { return nil }
        return entries.first(where: { $0.key.textStringValue == key })?.value
    }

    /// Look up a value by integer key in a map (used for COSE headers).
    public subscript(intKey key: Int64) -> CBORValue? {
        guard case .map(let entries) = self else { return nil }
        return entries.first(where: { $0.key.intValue == key })?.value
    }
}
