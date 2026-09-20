import Foundation

extension TeamKitColor {
    /// Bridge to the colour type used by detection/clustering.
    var colorRGB: ColorRGB { ColorRGB(r: r, g: g, b: b) }

    init(_ color: ColorRGB) {
        self.r = color.r
        self.g = color.g
        self.b = color.b
    }
}

extension Team {
    /// All configured kit colours (primary, secondary, goalkeeper), used to match a sampled
    /// jersey colour to this team regardless of which kit they wore.
    var kitColors: [ColorRGB] {
        [primaryColor.colorRGB, secondaryColor?.colorRGB, goalkeeperColor?.colorRGB].compactMap { $0 }
    }
}

/// Deterministic parser shared by the team-sheet/startlist Paste and File import paths.
/// Imported rows merge by number, preserving a previously confirmed Known-People link when only
/// the display name changes. Invalid/header rows are ignored and the result is number-sorted.
nonisolated enum RosterTextImporter {
    static func merge(_ text: String, into existing: [RosterPlayer]) -> [RosterPlayer] {
        var byNumber = Dictionary(
            existing.map { ($0.number, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSep = trimmed.firstIndex(where: { $0 == " " || $0 == "," || $0 == "\t" }) else {
                continue
            }
            let separators = CharacterSet(charactersIn: " ,\t")
            let numberPart = trimmed[..<firstSep].trimmingCharacters(in: separators)
            let namePart = trimmed[firstSep...].trimmingCharacters(in: separators)
            guard let number = Int(numberPart), (0...9999).contains(number), !namePart.isEmpty else {
                continue
            }
            if var player = byNumber[number] {
                player.playerName = namePart
                byNumber[number] = player
            } else {
                byNumber[number] = RosterPlayer(number: number, playerName: namePart)
            }
        }
        return byNumber.values.sorted { ($0.number, $0.playerName) < ($1.number, $1.playerName) }
    }
}

/// Supplies the trusted value for the Sports `(number)` / `{number}` caption token.
/// Raw OCR suggestions are deliberately excluded: only confirmed number claims, explicit manual
/// assignments, or an identified face mapped through the current roster may contribute.
nonisolated enum SportsCaptionNumberResolver {
    static func value(
        for imageURL: URL,
        faceData: FolderFaceData?,
        match: MatchRoster?
    ) -> String {
        guard let faceData else { return "" }
        let target = imageURL.standardizedFileURL
        var numbers = Set<Int>()

        for detection in faceData.numberDetections ?? [] {
            guard detection.imageURL.standardizedFileURL == target,
                  detection.effectiveClaimState == .confirmed else { continue }
            numbers.insert(detection.number)
        }

        let groupsByID = Dictionary(uniqueKeysWithValues: faceData.groups.map { ($0.id, $0) })
        let groupsInImage = Set(faceData.faces.compactMap { face -> UUID? in
            guard face.imageURL.standardizedFileURL == target else { return nil }
            return face.groupID
        })
        let roster = [match?.homeTeamSnapshot, match?.awayTeamSnapshot]
            .compactMap { $0 }
            .flatMap(\.roster)

        for groupID in groupsInImage {
            guard let group = groupsByID[groupID], !group.isExcludedFromPersonShown else { continue }
            if let manual = group.manualNumber {
                numbers.insert(manual)
                continue
            }
            if let personID = group.knownPersonID,
               let player = roster.first(where: { $0.knownPersonID == personID }) {
                numbers.insert(player.number)
                continue
            }
            let name = group.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }
            let matching = roster.filter {
                $0.playerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame
            }
            if matching.count == 1, let player = matching.first {
                numbers.insert(player.number)
            }
        }

        return numbers.sorted().map(String.init).joined(separator: ", ")
    }
}
