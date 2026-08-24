import Foundation

/// Vorbis Comment metadata (used in FLAC, OGG).
/// Comments are key=value pairs with case-insensitive keys.
public struct VorbisComment: Sendable, Equatable {
    public var vendor: String
    public var comments: [(key: String, value: String)]

    public init(vendor: String = "", comments: [(key: String, value: String)] = []) {
        self.vendor = vendor
        self.comments = comments
    }

    /// Get the first value for a case-insensitive key.
    public func value(for key: String) -> String? {
        let lowerKey = key.lowercased()
        return comments.first { $0.key.lowercased() == lowerKey }?.value
    }

    /// Set a value (replaces first match or appends).
    public mutating func setValue(_ value: String, for key: String) {
        let lowerKey = key.lowercased()
        if let idx = comments.firstIndex(where: { $0.key.lowercased() == lowerKey }) {
            comments[idx] = (key: key, value: value)
        } else {
            comments.append((key: key, value: value))
        }
    }

    /// Remove all values for a case-insensitive key.
    public mutating func removeValue(for key: String) {
        let lowerKey = key.lowercased()
        comments.removeAll { $0.key.lowercased() == lowerKey }
    }

    // MARK: - Parsing

    /// Parse Vorbis Comment from binary data (little-endian length-prefixed format).
    public static func parse(_ data: Data) throws -> VorbisComment {
        guard data.count >= 8 else {
            throw MetadataError.invalidFLAC("Vorbis comment too short")
        }

        var offset = 0

        // Vendor string
        guard offset + 4 <= data.count else { throw MetadataError.invalidFLAC("Truncated vendor length") }
        let vendorLen = readUInt32LE(data, at: offset)
        offset += 4
        guard offset + Int(vendorLen) <= data.count else { throw MetadataError.invalidFLAC("Truncated vendor string") }
        let vendor = String(data: data[offset..<offset + Int(vendorLen)], encoding: .utf8) ?? ""
        offset += Int(vendorLen)

        // Comment count
        guard offset + 4 <= data.count else { throw MetadataError.invalidFLAC("Truncated comment count") }
        let commentCount = readUInt32LE(data, at: offset)
        offset += 4

        var comments: [(key: String, value: String)] = []
        for _ in 0..<commentCount {
            guard offset + 4 <= data.count else { break }
            let commentLen = readUInt32LE(data, at: offset)
            offset += 4
            guard offset + Int(commentLen) <= data.count else { break }
            let commentStr = String(data: data[offset..<offset + Int(commentLen)], encoding: .utf8) ?? ""
            offset += Int(commentLen)

            if let eqIdx = commentStr.firstIndex(of: "=") {
                let key = String(commentStr[commentStr.startIndex..<eqIdx])
                let value = String(commentStr[commentStr.index(after: eqIdx)...])
                comments.append((key: key, value: value))
            }
        }

        return VorbisComment(vendor: vendor, comments: comments)
    }

    // MARK: - Serialization

    /// Serialize Vorbis Comment to binary data.
    public func serialize() -> Data {
        var result = Data()

        // Vendor string
        let vendorData = Data(vendor.utf8)
        result.append(contentsOf: writeUInt32LE(UInt32(vendorData.count)))
        result.append(vendorData)

        // Comment count
        result.append(contentsOf: writeUInt32LE(UInt32(comments.count)))

        // Comments
        for comment in comments {
            let str = "\(comment.key)=\(comment.value)"
            let strData = Data(str.utf8)
            result.append(contentsOf: writeUInt32LE(UInt32(strData.count)))
            result.append(strData)
        }

        return result
    }

    // MARK: - Helpers

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private func writeUInt32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

extension VorbisComment {
    public static func == (lhs: VorbisComment, rhs: VorbisComment) -> Bool {
        guard lhs.vendor == rhs.vendor, lhs.comments.count == rhs.comments.count else { return false }
        for (l, r) in zip(lhs.comments, rhs.comments) {
            if l.key != r.key || l.value != r.value { return false }
        }
        return true
    }
}
