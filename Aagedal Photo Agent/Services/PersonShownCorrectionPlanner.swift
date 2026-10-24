import Foundation

/// A pending offer to correct Person Shown after a face edit (rename, move, merge, delete, or a
/// Known People change) made a name this app applied wrong for some photos.
nonisolated struct PersonShownUpdateProposal: Identifiable, Sendable, Equatable {
    let id: UUID
    let folderURL: URL
    /// Ordered exact-string corrections per photo; applied in sequence by `.replacePersons`.
    var replacementsByURL: [URL: [MetadataPersonReplacement]]
    /// Groups whose `appliedPersonShownName` becomes the new value once the update is written
    /// (nil clears it: the group's name was removed).
    var appliedNameUpdates: [UUID: String?]

    var photoCount: Int { replacementsByURL.count }

    /// Short human description of the distinct changes, e.g. "Replace “Store” with “Støre”".
    var summary: String {
        var seen: Set<String> = []
        var lines: [String] = []
        for replacement in replacementsByURL.keys.sorted(by: { $0.path < $1.path }).flatMap({ replacementsByURL[$0] ?? [] }) {
            let line: String
            switch (replacement.old, replacement.new) {
            case (let old?, let new?) where replacement.keepsOld: line = "Add “\(new)” next to “\(old)”"
            case (let old?, let new?): line = "Replace “\(old)” with “\(new)”"
            case (let old?, nil): line = "Remove “\(old)”"
            case (nil, let new?): line = "Add “\(new)”"
            case (nil, nil): continue
            }
            if seen.insert(line).inserted { lines.append(line) }
        }
        let shown = lines.prefix(4).joined(separator: "\n")
        return lines.count > 4 ? shown + "\n…and \(lines.count - 4) more" : shown
    }

    /// Later proposals append their corrections: sequential exact replacements compose
    /// (Store → Støre, then Støre → Stoere), so nothing confirmed earlier is lost.
    func merged(with later: PersonShownUpdateProposal) -> PersonShownUpdateProposal {
        var result = self
        for (url, replacements) in later.replacementsByURL {
            result.replacementsByURL[url, default: []].append(contentsOf: replacements)
        }
        for (groupID, name) in later.appliedNameUpdates { result.appliedNameUpdates[groupID] = name }
        return PersonShownUpdateProposal(id: later.id, folderURL: later.folderURL,
            replacementsByURL: result.replacementsByURL, appliedNameUpdates: result.appliedNameUpdates)
    }
}

/// Computes which app-applied Person Shown names a face edit invalidated.
///
/// Only a group's `appliedPersonShownName` — the exact string this app wrote — is ever replaced
/// or removed, and only in photos where one of that group's faces was before the edit. A name is
/// never removed from a photo where another face still shows that person, and the write itself
/// skips photos that no longer contain the name, so manual entries are untouched.
nonisolated enum PersonShownCorrectionPlanner {
    static func proposal(before: FolderFaceData, after: FolderFaceData) -> PersonShownUpdateProposal? {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        func shownName(_ group: FaceGroup?) -> String? {
            guard let group, !group.isExcludedFromPersonShown else { return nil }
            return clean(group.name)
        }
        let beforeGroups = Dictionary(before.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterGroups = Dictionary(after.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var photoURLs: [String: URL] = [:]
        var beforeByPhoto: [String: Set<UUID>] = [:]
        var afterByPhoto: [String: Set<UUID>] = [:]
        for face in before.faces {
            let key = face.imageURL.standardizedFileURL.path
            photoURLs[key] = photoURLs[key] ?? face.imageURL
            if let groupID = face.groupID { beforeByPhoto[key, default: []].insert(groupID) }
        }
        for face in after.faces {
            let key = face.imageURL.standardizedFileURL.path
            photoURLs[key] = face.imageURL
            if let groupID = face.groupID { afterByPhoto[key, default: []].insert(groupID) }
        }

        var replacementsByURL: [URL: [MetadataPersonReplacement]] = [:]
        var appliedNameUpdates: [UUID: String?] = [:]
        for key in photoURLs.keys.sorted() {
            guard let url = photoURLs[key] else { continue }
            let beforeIDs = beforeByPhoto[key] ?? []
            let afterIDs = afterByPhoto[key] ?? []
            let shownAfter = Set(afterIDs.compactMap { shownName(afterGroups[$0]) })

            // Names this app applied to this photo through a group present before the edit.
            var applied: [(groupID: UUID, name: String)] = []
            for groupID in beforeIDs {
                guard let group = beforeGroups[groupID], !group.isExcludedFromPersonShown,
                      let name = clean(group.appliedPersonShownName) else { continue }
                applied.append((groupID, name))
            }
            applied.sort { ($0.name, $0.groupID.uuidString) < ($1.name, $1.groupID.uuidString) }
            let appliedNames = Set(applied.map(\.name))

            var replacements: [MetadataPersonReplacement] = []
            var removed: Set<String> = []
            for (groupID, name) in applied {
                if afterIDs.contains(groupID), let group = afterGroups[groupID] {
                    // Same group still in the photo: it was renamed, cleared or excluded by this
                    // edit. A mismatch the user already chose to leave is not offered again.
                    let newName = shownName(group)
                    guard newName != name, newName != shownName(beforeGroups[groupID]) else { continue }
                    let stillShown = afterIDs.contains { $0 != groupID && shownName(afterGroups[$0]) == name }
                    if let newName {
                        replacements.append(.init(old: name, new: newName, keepsOld: stillShown))
                    } else if !stillShown, removed.insert(name).inserted {
                        replacements.append(.init(old: name, new: nil))
                    }
                    appliedNameUpdates[groupID] = .some(newName)
                } else if !shownAfter.contains(name), removed.insert(name).inserted {
                    // The group's face left this photo (moved, merged, ungrouped or deleted)
                    // and no remaining face here shows that person.
                    replacements.append(.init(old: name, new: nil))
                }
            }
            // Faces that joined an applied group add that group's name to their photo.
            var added: Set<String> = []
            for groupID in afterIDs.sorted(by: { $0.uuidString < $1.uuidString }) where !beforeIDs.contains(groupID) {
                guard let group = afterGroups[groupID], clean(group.appliedPersonShownName) != nil,
                      let name = shownName(group), !appliedNames.contains(name),
                      added.insert(name).inserted else { continue }
                replacements.append(.init(old: nil, new: name))
            }
            if !replacements.isEmpty { replacementsByURL[url] = replacements }
        }
        guard !replacementsByURL.isEmpty else { return nil }
        return PersonShownUpdateProposal(id: UUID(), folderURL: after.folderURL,
            replacementsByURL: replacementsByURL, appliedNameUpdates: appliedNameUpdates)
    }
}

/// Structured identity changes published with `.knownPeopleDatabaseDidChange` (userInfo key
/// `KnownPeopleIdentityChange.userInfoKey`), so folder face groups linked by `knownPersonID`
/// can follow renames, merges and deletions made in Known People.
nonisolated enum KnownPeopleIdentityChange: Sendable, Equatable {
    case renamed(personID: UUID, newName: String)
    case merged(sourceID: UUID, targetID: UUID, targetName: String)
    case deleted(personID: UUID)

    static let userInfoKey = "knownPeopleIdentityChange"

    var userInfo: [String: Any] { [Self.userInfoKey: self] }
}
