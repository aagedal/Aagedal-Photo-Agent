import Foundation

// MXF Multi-Channel Audio (MCA) labelling — SMPTE ST 377-4 + ST 2020-1.
//
// MCA labels live in subdescriptors hung off a Sound Essence Descriptor's
// `SubDescriptors` strong-reference array. Three subdescriptor kinds matter:
//
//   byte-14 = 0x6B  AudioChannelLabelSubDescriptor             (chL, chR, …)
//   byte-14 = 0x6C  SoundfieldGroupLabelSubDescriptor          (sgST, sgM, …)
//   byte-14 = 0x6D  GroupOfSoundfieldGroupsLabelSubDescriptor  (ggMPg, ggDcm, …)
//
// All three carry a common set of properties: MCALinkID (the UUID by which
// other subdescriptors point at this one), MCATagSymbol / MCATagName, an
// optional RFC 5646 spoken-language tag, and the appropriate "where do I
// belong" link IDs (channels point at one soundfield group; soundfield groups
// point at one or more groups-of-groups).
//
// The local tags used to hold these properties are NOT static — bmxtools and
// most modern MXF writers allocate them dynamically via the Primer Pack at
// the start of the header partition. We therefore parse the Primer first to
// build a tag → property map, then decode each MCA subdescriptor body using
// that map. The only fixed local tag we rely on is 0x3C0A for InstanceUID
// (universal across MXF SMPTE-defined sets).

extension MXFReader {

    // MARK: - Public entry-point

    /// State carried across the header-metadata KLV scan. Driven from
    /// `MXFReader.parse` — see the Primer / MCA / SubDescriptors hooks in
    /// the main loop, plus `assembleAudioLabeling` after the loop.
    struct MCAState {
        var primer = PrimerContext()
        var channels: [UUID: MCASetFields] = [:]
        var soundfields: [UUID: MCASetFields] = [:]
        var groupsOfGroups: [UUID: MCASetFields] = [:]
        /// One entry per audio stream, in the order audio streams were
        /// emitted by the parser. Each entry is the SubDescriptors strong-
        /// reference array decoded from the corresponding Sound Essence
        /// Descriptor's local set. Empty arrays are kept so indices line up.
        var soundDescriptorSubUIDs: [[UUID]] = []
    }

    /// MCA subdescriptor kinds (byte 14 of the KLV key). Returns nil for keys
    /// that aren't MCA subdescriptors.
    static func mcaSubDescriptorKind(_ key: Data) -> UInt8? {
        guard key.count >= 15 else { return nil }
        let s = key.startIndex
        let prefix: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
            0x0D, 0x01, 0x01, 0x01, 0x01, 0x01,
        ]
        for (i, b) in prefix.enumerated() where key[s + i] != b { return nil }
        let kind = key[s + 14]
        return (kind == 0x6B || kind == 0x6C || kind == 0x6D) ? kind : nil
    }

    /// True if `key` is the Primer Pack KLV key.
    static func isPrimerPackKey(_ key: Data) -> Bool {
        guard key.count >= 13 else { return false }
        let s = key.startIndex
        // 06.0E.2B.34.02.05.01.01.0D.01.02.01.01.05.01.00 (last byte varies in
        // some drafts; first 13 bytes are the stable signature).
        let prefix: [UInt8] = [
            0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
            0x0D, 0x01, 0x02, 0x01, 0x01,
        ]
        for (i, b) in prefix.enumerated() where key[s + i] != b { return false }
        return true
    }

    /// Decode one MCA subdescriptor's local set into a `MCASetFields`. Returns
    /// nil if the set has no usable InstanceUID.
    static func parseMCASubDescriptor(
        _ data: Data,
        kind: UInt8,
        primer: PrimerContext
    ) -> MCASetFields? {
        var fields = MCASetFields()
        walkLocalSet(data) { tag, value in
            // InstanceUID has a fixed local tag in every SMPTE-defined set.
            if tag == 0x3C0A, let uid = decodeUUID(value) {
                fields.instanceUID = uid
                return
            }
            guard let property = primer.property(for: tag) else { return }
            switch property {
            case .instanceUID:
                fields.instanceUID = decodeUUID(value)
            case .mcaLinkID:
                fields.linkID = decodeUUID(value)
            case .mcaTagSymbol:
                fields.symbol = decodeUTF16BEString(value)
            case .mcaTagName:
                fields.name = decodeUTF16BEString(value)
            case .mcaChannelID:
                fields.channelID = parseUInt32(value).map(Int.init)
            case .soundfieldGroupLinkID:
                fields.soundfieldGroupLinkID = decodeUUID(value)
            case .groupOfGroupsLinkID:
                fields.groupOfGroupsLinkIDs = decodeUUIDArray(value)
            case .rfc5646SpokenLanguage:
                fields.language = decodeASCIIOrUTF8(value)
            case .subDescriptors, .mcaLabelDictionaryID:
                break
            }
        }
        guard fields.instanceUID != nil else { return nil }
        _ = kind
        return fields
    }

    /// Pull the SubDescriptors strong-reference array out of a Sound Essence
    /// Descriptor body. Tag is whatever the Primer Pack mapped to the
    /// SubDescriptors UL; falls back to the SMPTE RP 210 conventional tag
    /// 0x3F01 when the Primer didn't carry an explicit mapping.
    static func extractSubDescriptorUIDs(
        from data: Data,
        primer: PrimerContext
    ) -> [UUID] {
        let primaryTag = primer.subDescriptorsTag()
        var uids: [UUID] = []
        walkLocalSet(data) { tag, value in
            if tag == primaryTag || (primer.subDescriptorsTagWasMapped == false && tag == 0x3F01) {
                uids.append(contentsOf: decodeUUIDArray(value))
            }
        }
        return uids
    }

    /// Build the final `MCAAudioLabeling` after all KLVs have been scanned.
    static func assembleAudioLabeling(state: MCAState) -> MCAAudioLabeling {
        // First materialize the soundfield-group and group-of-groups arrays
        // in a stable order so JSON output is reproducible.
        let soundfieldOrder = state.soundfields.keys.sorted { lhs, rhs in
            lhs.uuidString < rhs.uuidString
        }
        let groupOrder = state.groupsOfGroups.keys.sorted { lhs, rhs in
            lhs.uuidString < rhs.uuidString
        }

        var soundfieldGroups: [MCASoundfieldGroup] = []
        for uid in soundfieldOrder {
            guard let fields = state.soundfields[uid] else { continue }
            var sg = MCASoundfieldGroup()
            sg.symbol = fields.symbol
            sg.name = fields.name
            sg.linkID = fields.linkID ?? uid
            sg.groupOfGroupsLinkIDs = fields.groupOfGroupsLinkIDs
            sg.language = fields.language
            soundfieldGroups.append(sg)
        }

        var groupsOfGroups: [MCAGroupOfSoundfieldGroups] = []
        for uid in groupOrder {
            guard let fields = state.groupsOfGroups[uid] else { continue }
            var gg = MCAGroupOfSoundfieldGroups()
            gg.symbol = fields.symbol
            gg.name = fields.name
            gg.linkID = fields.linkID ?? uid
            gg.language = fields.language
            groupsOfGroups.append(gg)
        }

        // Resolve channels via the SubDescriptors UID arrays the parse loop
        // collected per audio stream. A subdescriptor only ever belongs to
        // one descriptor, so as soon as we match an MCA channel UUID against
        // a track's sub-list we lock it in.
        var channels: [MCAChannelLabel] = []
        var seenChannelUIDs: Set<UUID> = []

        for (trackIndex, subUIDs) in state.soundDescriptorSubUIDs.enumerated() {
            for subUID in subUIDs {
                guard let fields = state.channels[subUID],
                      seenChannelUIDs.insert(subUID).inserted else { continue }
                var ch = MCAChannelLabel()
                ch.trackIndex = trackIndex
                ch.symbol = fields.symbol
                ch.name = fields.name
                ch.channelID = fields.channelID
                ch.linkID = fields.linkID ?? subUID
                ch.soundfieldGroupLinkID = fields.soundfieldGroupLinkID
                ch.language = fields.language
                channels.append(ch)
            }
        }
        // Pick up any channel labels that weren't reachable from a
        // SubDescriptors array (permissive — covers files that omit the back-
        // reference or pre-allocate channel labels to a different descriptor
        // chain than we parse). They get nil trackIndex.
        for (uid, fields) in state.channels where !seenChannelUIDs.contains(uid) {
            var ch = MCAChannelLabel()
            ch.symbol = fields.symbol
            ch.name = fields.name
            ch.channelID = fields.channelID
            ch.linkID = fields.linkID ?? uid
            ch.soundfieldGroupLinkID = fields.soundfieldGroupLinkID
            ch.language = fields.language
            channels.append(ch)
        }
        channels.sort { lhs, rhs in
            switch (lhs.trackIndex, rhs.trackIndex) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return (lhs.linkID?.uuidString ?? "") < (rhs.linkID?.uuidString ?? "")
            }
        }

        return MCAAudioLabeling(
            channels: channels,
            soundfieldGroups: soundfieldGroups,
            groupsOfSoundfieldGroups: groupsOfGroups
        )
    }

    // MARK: - Primer Pack

    /// Decoded Primer Pack — maps local tags to MCA-relevant properties.
    struct PrimerContext {
        private var byTag: [UInt16: MCAProperty] = [:]
        private(set) var subDescriptorsTagWasMapped = false
        private var subDescriptorsTagValue: UInt16 = 0x3F01

        mutating func ingest(_ value: Data) {
            // Primer Pack body: UInt32 count, UInt32 itemLen, count × (UInt16
            // tag + 16-byte UL).
            guard value.count >= 8 else { return }
            var r = BinaryReader(data: value)
            guard let count = try? r.readUInt32BigEndian(),
                  let itemLen = try? r.readUInt32BigEndian(),
                  itemLen == 18 else { return }
            // Cap the iteration so a malformed count can't stall us.
            let safeCount = min(Int(count), 8192)
            for _ in 0..<safeCount {
                guard let tag = try? r.readUInt16BigEndian(),
                      let ul = try? r.readBytes(16) else { return }
                if let property = MXFReader.mcaProperty(forUL: ul) {
                    byTag[tag] = property
                    if property == .subDescriptors {
                        subDescriptorsTagValue = tag
                        subDescriptorsTagWasMapped = true
                    }
                }
            }
        }

        func property(for tag: UInt16) -> MCAProperty? { byTag[tag] }

        func subDescriptorsTag() -> UInt16 { subDescriptorsTagValue }
    }

    /// Bag of fields populated from one MCA subdescriptor body. Channels,
    /// soundfield groups, and groups-of-groups all share this representation
    /// — irrelevant fields stay nil.
    struct MCASetFields {
        var instanceUID: UUID?
        var linkID: UUID?
        var symbol: String?
        var name: String?
        var channelID: Int?
        var soundfieldGroupLinkID: UUID?
        var groupOfGroupsLinkIDs: [UUID] = []
        var language: String?
    }

    /// Properties we recognize. Each maps to a registered SMPTE UL identified
    /// by its trailing 6 bytes (bytes 10-15 of the UL — uniquely distinguish
    /// these properties even across minor SMPTE-dictionary version changes).
    enum MCAProperty {
        case instanceUID
        case subDescriptors
        case mcaLabelDictionaryID
        case mcaTagSymbol
        case mcaTagName
        case mcaChannelID
        case mcaLinkID
        case soundfieldGroupLinkID
        case groupOfGroupsLinkID
        case rfc5646SpokenLanguage
    }

    static func mcaProperty(forUL ul: Data) -> MCAProperty? {
        guard ul.count >= 16 else { return nil }
        let s = ul.startIndex
        // Require the SMPTE UL prefix.
        guard ul[s] == 0x06, ul[s + 1] == 0x0E, ul[s + 2] == 0x2B, ul[s + 3] == 0x34 else {
            return nil
        }
        // Match on bytes 8..15. Two MXF dictionary layouts are in active use
        // for MCA properties: the original SMPTE ST 377-4 layout (dictionary
        // version 0x0D, byte 8 = 0x03) and the newer SMPTE Public Registers
        // layout (dictionary version 0x0E, byte 8 = 0x01) that bmxtools and
        // libMXF++ have been emitting since ~2019. We accept both.
        let body = (
            ul[s + 8],  ul[s + 9],  ul[s + 10], ul[s + 11],
            ul[s + 12], ul[s + 13], ul[s + 14], ul[s + 15]
        )
        switch body {

        // --- Universal (any dictionary version) ---
        case (0x01, 0x01, 0x15, 0x02, 0x00, 0x00, 0x00, 0x00):
            return .instanceUID
        case (0x06, 0x01, 0x01, 0x04, 0x06, 0x10, 0x00, 0x00):
            return .subDescriptors

        // --- Dictionary v0x0D (SMPTE ST 377-4, original release) ---
        case (0x03, 0x02, 0x01, 0x02, 0x01, 0x00, 0x00, 0x00):
            return .mcaLabelDictionaryID
        case (0x03, 0x02, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00):
            return .mcaTagSymbol
        case (0x03, 0x02, 0x01, 0x02, 0x04, 0x00, 0x00, 0x00):
            return .mcaTagName
        case (0x03, 0x02, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00):
            return .mcaChannelID
        case (0x01, 0x01, 0x15, 0x10, 0x00, 0x00, 0x00, 0x00):
            return .mcaLinkID
        case (0x01, 0x01, 0x15, 0x11, 0x00, 0x00, 0x00, 0x00):
            return .soundfieldGroupLinkID
        case (0x01, 0x04, 0x15, 0x12, 0x00, 0x00, 0x00, 0x00):
            return .groupOfGroupsLinkID
        case (0x03, 0x01, 0x01, 0x02, 0x03, 0x15, 0x00, 0x00):
            return .rfc5646SpokenLanguage

        // --- Dictionary v0x0E (SMPTE Public Registers / bmxtools) ---
        case (0x01, 0x03, 0x07, 0x01, 0x01, 0x00, 0x00, 0x00):
            return .mcaLabelDictionaryID
        case (0x01, 0x03, 0x07, 0x01, 0x02, 0x00, 0x00, 0x00):
            return .mcaTagSymbol
        case (0x01, 0x03, 0x07, 0x01, 0x03, 0x00, 0x00, 0x00):
            return .mcaTagName
        case (0x01, 0x03, 0x07, 0x01, 0x04, 0x00, 0x00, 0x00):
            return .groupOfGroupsLinkID
        case (0x01, 0x03, 0x07, 0x01, 0x05, 0x00, 0x00, 0x00):
            return .mcaLinkID
        case (0x01, 0x03, 0x07, 0x01, 0x06, 0x00, 0x00, 0x00):
            return .soundfieldGroupLinkID
        case (0x01, 0x03, 0x07, 0x01, 0x07, 0x00, 0x00, 0x00):
            return .mcaChannelID

        default: return nil
        }
    }

    // MARK: - Value decoding

    static func decodeUUID(_ data: Data) -> UUID? {
        guard data.count >= 16 else { return nil }
        let s = data.startIndex
        let bytes: uuid_t = (
            data[s], data[s + 1], data[s + 2], data[s + 3],
            data[s + 4], data[s + 5], data[s + 6], data[s + 7],
            data[s + 8], data[s + 9], data[s + 10], data[s + 11],
            data[s + 12], data[s + 13], data[s + 14], data[s + 15]
        )
        return UUID(uuid: bytes)
    }

    /// Decode a BatchOf<UUID> — `count` (UInt32 BE) + `itemLen` (UInt32 BE,
    /// always 16) + count × 16-byte UUID. Tolerates truncated arrays.
    static func decodeUUIDArray(_ data: Data) -> [UUID] {
        guard data.count >= 8 else { return [] }
        var r = BinaryReader(data: data)
        guard let count = try? r.readUInt32BigEndian(),
              let itemLen = try? r.readUInt32BigEndian(),
              itemLen == 16 else { return [] }
        let safeCount = min(Int(count), 4096)
        var uids: [UUID] = []
        uids.reserveCapacity(safeCount)
        for _ in 0..<safeCount {
            guard let chunk = try? r.readBytes(16),
                  let uid = decodeUUID(chunk) else { break }
            uids.append(uid)
        }
        return uids
    }

    /// Decode a UTF-16BE string with optional trailing NUL terminator. Many
    /// MXF writers (notably bmx) pad to even byte counts and append a U+0000.
    static func decodeUTF16BEString(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        // Trim a trailing UTF-16 NUL if present so consumers don't see it.
        var byteCount = data.count - (data.count % 2)
        while byteCount >= 2 {
            let s = data.startIndex
            if data[s + byteCount - 2] == 0 && data[s + byteCount - 1] == 0 {
                byteCount -= 2
                continue
            }
            break
        }
        guard byteCount > 0 else { return "" }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(byteCount / 2)
        let s = data.startIndex
        var i = 0
        while i < byteCount {
            let hi = UInt16(data[s + i])
            let lo = UInt16(data[s + i + 1])
            codeUnits.append((hi << 8) | lo)
            i += 2
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    /// Decode a NUL-terminated 7-bit ASCII / UTF-8 string. Used for
    /// RFC 5646 language tags, which are pure ASCII in practice.
    static func decodeASCIIOrUTF8(_ data: Data) -> String? {
        // Strip every trailing NUL byte (MXF pads strings).
        var slice = data
        while let last = slice.last, last == 0 {
            slice = slice.dropLast()
        }
        guard !slice.isEmpty else { return nil }
        return String(data: slice, encoding: .utf8)
    }
}
