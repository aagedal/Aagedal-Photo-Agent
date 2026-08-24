import Foundation

/// Render an `MCAAudioLabeling` graph back into bmxtools `--audio-labels`
/// input format (the same format as the test fixture's `labels.txt`).
///
/// Layout, one block per track that carries an MCA channel label:
/// ```
/// <trackIndex>
/// <channelSymbol>                                  e.g. chL
/// <sgSymbol>, id=sg<N>[, lang=<rfc5646>][, repeat=false]
/// <ggSymbol>, id=gosg<N>[, lang=<rfc5646>][, repeat=false]
/// <blank line>
/// ```
///
/// Soundfield-group IDs (`sg1`, `sg2`, …) and group-of-groups IDs (`gosg1`,
/// `gosg2`, …) are synthesized by enumerating distinct `MCALinkID` UUIDs in
/// first-seen order across the channel list. When a later track references a
/// UUID that's already been emitted, we attach `repeat=false` per bmxtools
/// semantics — that's how bmx writes Track 1 (sgST shared with Track 0) in
/// the canonical AS-11 stereo-pair example.
public enum MCALabelsRenderer {

    /// Render the labelling as a UTF-8 string. Newlines are LF; channels are
    /// emitted in `trackIndex` order. Channels with no `trackIndex` are
    /// skipped (they're orphan subdescriptors that aren't reachable from any
    /// sound descriptor's SubDescriptors strong-reference array — they would
    /// have no track number to attach to in bmx's input format).
    public static func render(_ labeling: MCAAudioLabeling) -> String {
        let sgByLinkID = Dictionary(grouping: labeling.soundfieldGroups, by: { $0.linkID })
            .compactMapValues(\.first)
        let ggByLinkID = Dictionary(grouping: labeling.groupsOfSoundfieldGroups, by: { $0.linkID })
            .compactMapValues(\.first)

        var sgIndex: [UUID: Int] = [:]
        var ggIndex: [UUID: Int] = [:]
        var nextSGIndex = 1
        var nextGGIndex = 1

        let trackedChannels = labeling.channels
            .filter { $0.trackIndex != nil }
            .sorted { ($0.trackIndex ?? 0) < ($1.trackIndex ?? 0) }

        var lines: [String] = []
        for channel in trackedChannels {
            // Track index + channel symbol.
            if let trackIndex = channel.trackIndex {
                lines.append("\(trackIndex)")
            }
            if let symbol = channel.symbol {
                lines.append(symbol)
            }

            // Soundfield-group line (e.g. "sgST, id=sg1, lang=en").
            if let sgUID = channel.soundfieldGroupLinkID,
               let sg = sgByLinkID[sgUID] {
                let isRepeat = sgIndex[sgUID] != nil
                let n: Int
                if let existing = sgIndex[sgUID] {
                    n = existing
                } else {
                    n = nextSGIndex
                    sgIndex[sgUID] = n
                    nextSGIndex += 1
                }
                lines.append(formatLabelLine(
                    symbol: sg.symbol,
                    idPrefix: "sg",
                    idNumber: n,
                    language: isRepeat ? nil : sg.language,
                    isRepeat: isRepeat
                ))

                // Group-of-soundfield-groups line — pick the first GoG link
                // referenced by the soundfield group.
                if let ggUID = sg.groupOfGroupsLinkIDs.first,
                   let gg = ggByLinkID[ggUID] {
                    let ggIsRepeat = ggIndex[ggUID] != nil
                    let m: Int
                    if let existing = ggIndex[ggUID] {
                        m = existing
                    } else {
                        m = nextGGIndex
                        ggIndex[ggUID] = m
                        nextGGIndex += 1
                    }
                    lines.append(formatLabelLine(
                        symbol: gg.symbol,
                        idPrefix: "gosg",
                        idNumber: m,
                        language: ggIsRepeat ? nil : gg.language,
                        isRepeat: ggIsRepeat
                    ))
                }
            }

            // Blank line between track blocks.
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatLabelLine(
        symbol: String?,
        idPrefix: String,
        idNumber: Int,
        language: String?,
        isRepeat: Bool
    ) -> String {
        var parts: [String] = []
        parts.append(symbol ?? "?")
        parts.append("id=\(idPrefix)\(idNumber)")
        if let lang = language, !lang.isEmpty {
            parts.append("lang=\(lang)")
        }
        if isRepeat {
            parts.append("repeat=false")
        }
        return parts.joined(separator: ", ")
    }
}
