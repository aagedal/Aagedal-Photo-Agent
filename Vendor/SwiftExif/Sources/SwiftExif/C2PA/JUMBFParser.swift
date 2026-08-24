import Foundation

/// A parsed JUMBF (JPEG Universal Metadata Box Format, ISO 19566-5) superbox.
public struct JUMBFBox: Sendable {
    /// The description box (jumd) contents.
    public let description: JUMBFDescription
    /// Raw content boxes (non-jumb children).
    public let contentBoxes: [ISOBMFFBox]
    /// Nested JUMBF superboxes.
    public let children: [JUMBFBox]
}

/// A parsed JUMBF description box (jumd).
public struct JUMBFDescription: Sendable {
    /// 16-byte UUID identifying the content type.
    public let uuid: Data
    /// Toggle byte controlling optional fields.
    public let toggles: UInt8
    /// Optional label (null-terminated UTF-8 string, present if bit 1 set).
    public let label: String?
    /// Optional numeric ID (present if bit 2 set).
    public let id: UInt32?

    /// The 4-character ASCII prefix of the UUID (e.g. "c2pa", "c2ma", "c2cl").
    public var uuidPrefix: String? {
        guard uuid.count >= 4 else { return nil }
        return String(data: uuid.prefix(4), encoding: .ascii)
    }
}

/// Parse JUMBF box hierarchies from raw ISOBMFF box data.
public struct JUMBFParser: Sendable {

    /// Maximum nesting depth for JUMBF superboxes. Real-world C2PA trees stay
    /// under ~4 levels (manifest store → manifest → assertion store → assertion);
    /// the cap stops a crafted file from exhausting the stack via deeply nested
    /// `jumb` boxes.
    static let maxDepth = 32

    /// C2PA UUID suffix (bytes 4-15): 0011-0010-8000-00AA00389B71
    static let c2paUUIDSuffix: [UInt8] = [
        0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    // MARK: - C2PA UUID Prefixes

    /// Known C2PA-era UUID prefixes (4-byte ASCII).
    static let manifestStorePrefix = "c2pa"
    static let manifestPrefix = "c2ma"
    static let updateManifestPrefix = "c2um"
    static let assertionStorePrefix = "c2as"
    static let claimPrefix = "c2cl"
    static let signaturePrefix = "c2cs"

    /// Legacy Content Authenticity Initiative (CAI) UUID prefixes.
    static let legacyAssertionStorePrefix = "caas"
    static let legacyClaimPrefix = "cacl"
    static let legacySignaturePrefix = "casg"

    // MARK: - Parsing

    /// Parse a JUMBF superbox from raw box payload data.
    /// The data should be the payload of a `jumb` box (not including the box header).
    public static func parseSuperbox(from data: Data) throws -> JUMBFBox {
        let childBoxes = try ISOBMFFBoxReader.parseBoxes(from: data)
        return try parseSuperbox(from: childBoxes)
    }

    /// Parse a JUMBF superbox from pre-parsed child boxes.
    public static func parseSuperbox(from boxes: [ISOBMFFBox]) throws -> JUMBFBox {
        return try parseSuperbox(from: boxes, depth: 0)
    }

    static func parseSuperbox(from boxes: [ISOBMFFBox], depth: Int) throws -> JUMBFBox {
        guard depth <= Self.maxDepth else {
            throw MetadataError.invalidJUMBF("Nesting depth exceeds limit (\(Self.maxDepth))")
        }
        guard let first = boxes.first, first.type == "jumd" else {
            throw MetadataError.invalidJUMBF("Missing jumd description box")
        }

        let desc = try parseDescription(from: first.data)
        var contentBoxes: [ISOBMFFBox] = []
        var children: [JUMBFBox] = []

        for box in boxes.dropFirst() {
            if box.type == "jumb" {
                // try? matches the original behaviour of tolerating malformed
                // children (don't fail the whole image read for one corrupt
                // assertion). The depth guard above still stops recursion at
                // maxDepth even when this swallows the resulting throw.
                if let childBoxes = try? ISOBMFFBoxReader.parseBoxes(from: box.data),
                   let child = try? parseSuperbox(from: childBoxes, depth: depth + 1) {
                    children.append(child)
                }
            } else {
                contentBoxes.append(box)
            }
        }

        return JUMBFBox(description: desc, contentBoxes: contentBoxes, children: children)
    }

    /// Parse a JUMBF description box (jumd) payload.
    public static func parseDescription(from data: Data) throws -> JUMBFDescription {
        var reader = BinaryReader(data: data)

        guard data.count >= 17 else {
            throw MetadataError.invalidJUMBF("Description box too small")
        }

        let uuid = try reader.readBytes(16)
        let toggles = try reader.readUInt8()

        var label: String?
        var id: UInt32?

        // Bit 1 (0x02): label field present
        if toggles & 0x02 != 0 {
            label = try readNullTerminatedString(from: &reader)
        }

        // Bit 2 (0x04): ID field present
        if toggles & 0x04 != 0 && reader.remainingCount >= 4 {
            id = try reader.readUInt32BigEndian()
        }

        // Bit 3 (0x08): signature/hash present (32 bytes) — skip
        if toggles & 0x08 != 0 && reader.remainingCount >= 32 {
            try reader.skip(32)
        }

        return JUMBFDescription(uuid: uuid, toggles: toggles, label: label, id: id)
    }

    // MARK: - UUID Matching

    /// Check if a UUID matches a C2PA type by its 4-byte ASCII prefix.
    public static func isC2PAUUID(_ uuid: Data, prefix: String) -> Bool {
        guard uuid.count >= 16 else { return false }
        let prefixBytes = [UInt8](prefix.utf8)
        guard prefixBytes.count == 4 else { return false }

        // Check first 4 bytes match the ASCII prefix
        for i in 0..<4 {
            guard uuid[uuid.startIndex + i] == prefixBytes[i] else { return false }
        }

        // Check remaining 12 bytes match the C2PA UUID suffix
        for i in 0..<12 {
            guard uuid[uuid.startIndex + 4 + i] == c2paUUIDSuffix[i] else { return false }
        }

        return true
    }

    /// Check if a description matches a C2PA manifest store.
    public static func isManifestStore(_ desc: JUMBFDescription) -> Bool {
        isC2PAUUID(desc.uuid, prefix: manifestStorePrefix)
    }

    /// Check if a description matches a C2PA manifest.
    public static func isManifest(_ desc: JUMBFDescription) -> Bool {
        isC2PAUUID(desc.uuid, prefix: manifestPrefix)
            || isC2PAUUID(desc.uuid, prefix: updateManifestPrefix)
    }

    /// Check if a description matches a C2PA assertion store.
    public static func isAssertionStore(_ desc: JUMBFDescription) -> Bool {
        isC2PAUUID(desc.uuid, prefix: assertionStorePrefix)
            || isC2PAUUID(desc.uuid, prefix: legacyAssertionStorePrefix)
    }

    /// Check if a description matches a C2PA claim.
    public static func isClaim(_ desc: JUMBFDescription) -> Bool {
        isC2PAUUID(desc.uuid, prefix: claimPrefix)
            || isC2PAUUID(desc.uuid, prefix: legacyClaimPrefix)
    }

    /// Check if a description matches a C2PA claim signature.
    public static func isSignature(_ desc: JUMBFDescription) -> Bool {
        isC2PAUUID(desc.uuid, prefix: signaturePrefix)
            || isC2PAUUID(desc.uuid, prefix: legacySignaturePrefix)
    }

    // MARK: - JPEG APP11 Reassembly

    /// Reassemble JUMBF data from JPEG APP11 segments.
    /// APP11 segments carry fragmented JUMBF per JPEG XT (ISO/IEC 18477-3).
    public static func reassembleFromAPP11(_ segments: [JPEGSegment]) throws -> Data? {
        // Group segments by Box Instance Number
        var instanceGroups: [UInt16: [(seq: UInt32, data: Data)]] = [:]

        for segment in segments {
            guard segment.rawMarker == JPEGMarker.app11.rawValue else { continue }
            guard segment.data.count >= 8 else { continue }

            var reader = BinaryReader(data: segment.data)

            // Common Identifier: "JP" (0x4A50)
            let ci = try reader.readUInt16BigEndian()
            guard ci == 0x4A50 else { continue }

            let instanceNumber = try reader.readUInt16BigEndian()
            let sequenceNumber = try reader.readUInt32BigEndian()

            // First packet: skip 8-byte JPEG XT header, rest is JUMBF data
            // Subsequent packets: skip 8-byte header + 8-byte duplicate box header
            let jumbfData: Data
            if sequenceNumber == 1 {
                jumbfData = Data(segment.data.suffix(from: segment.data.startIndex + 8))
            } else {
                // Skip CI(2) + instance(2) + seq(4) + LBox(4) + TBox(4) = 16
                guard segment.data.count > 16 else { continue }
                jumbfData = Data(segment.data.suffix(from: segment.data.startIndex + 16))
            }

            instanceGroups[instanceNumber, default: []].append((seq: sequenceNumber, data: jumbfData))
        }

        guard !instanceGroups.isEmpty else { return nil }

        // For each instance group, sort by sequence number and concatenate
        // Return the first valid C2PA manifest store found
        for (_, packets) in instanceGroups {
            let sorted = packets.sorted { $0.seq < $1.seq }
            var assembled = Data()
            for packet in sorted {
                assembled.append(packet.data)
            }
            // Check if this looks like a C2PA JUMBF (starts with a jumb box containing c2pa)
            if isC2PAJUMBFData(assembled) {
                return assembled
            }
            // Also return non-C2PA JUMBF for generic JUMBF support
            if assembled.count >= 8 {
                return assembled
            }
        }

        return nil
    }

    /// Check if raw data starts with a jumb box that contains a C2PA manifest store.
    static func isC2PAJUMBFData(_ data: Data) -> Bool {
        guard data.count >= 32 else { return false }
        // Parse the outer box
        guard let boxes = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return false }
        guard let jumb = boxes.first(where: { $0.type == "jumb" }) else { return false }
        // Check for jumd with c2pa UUID inside
        guard let superbox = try? parseSuperbox(from: jumb.data) else { return false }
        return isManifestStore(superbox.description)
    }

    // MARK: - Private

    private static func readNullTerminatedString(from reader: inout BinaryReader) throws -> String {
        var bytes: [UInt8] = []
        while !reader.isAtEnd {
            let byte = try reader.readUInt8()
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
