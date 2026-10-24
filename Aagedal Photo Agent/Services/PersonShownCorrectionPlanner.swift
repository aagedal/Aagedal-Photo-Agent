import Foundation

/// Per-group, per-photo changes to the recorded applied Person Shown names (photo filename →
/// new exact name, or nil to drop the record). Applied only for photos whose write completed.
typealias AppliedPersonShownChanges = [UUID: [String: String?]]

/// A pending offer to correct Person Shown after a face edit (rename, move, merge, delete, or a
/// Known People change) made a name this app wrote wrong for some photos.
nonisolated struct PersonShownUpdateProposal: Identifiable, Sendable, Equatable {
    let id: UUID
    let folderURL: URL
    /// Ordered exact-string corrections per photo; applied in sequence by `.replacePersons`.
    var replacementsByURL: [URL: [MetadataPersonReplacement]]
    /// How each group's per-photo applied records change once the photo's write completes.
    var appliedNameUpdates: AppliedPersonShownChanges
    /// Offered again on folder load for an edit whose offer was never answered (e.g. the app
    /// quit with the prompt open), rather than created by an edit just now.
    var isReoffer: Bool = false

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
}

/// Computes which app-written Person Shown names a face edit invalidated.
///
/// Only the exact string this app wrote for a group into a specific photo (its per-photo applied
/// record) is ever replaced or removed, and only in that photo. A name is never removed from a
/// photo where another face still shows that person, and the write itself skips photos that no
/// longer contain the name, so names typed by hand are untouched.
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
        var appliedNameUpdates: AppliedPersonShownChanges = [:]
        for key in photoURLs.keys.sorted() {
            guard let url = photoURLs[key] else { continue }
            let filename = url.lastPathComponent
            let beforeIDs = beforeByPhoto[key] ?? []
            let afterIDs = afterByPhoto[key] ?? []
            let shownAfter = Set(afterIDs.compactMap { shownName(afterGroups[$0]) })

            // Names this app wrote into this photo for a group present before the edit.
            var applied: [(groupID: UUID, name: String)] = []
            for groupID in beforeIDs {
                guard let group = beforeGroups[groupID], !group.isExcludedFromPersonShown,
                      let name = clean(group.appliedPersonShownName(forPhoto: filename)) else { continue }
                applied.append((groupID, name))
            }
            applied.sort { ($0.name, $0.groupID.uuidString) < ($1.name, $1.groupID.uuidString) }
            let appliedNames = Set(applied.map(\.name))

            var replacements: [MetadataPersonReplacement] = []
            var removed: Set<String> = []
            for (groupID, name) in applied {
                if afterIDs.contains(groupID), let group = afterGroups[groupID] {
                    // Same group still in the photo: renamed, cleared or excluded by this edit.
                    // A mismatch the user already chose to leave is not offered again.
                    let newName = shownName(group)
                    guard newName != name, newName != shownName(beforeGroups[groupID]) else { continue }
                    let stillShown = afterIDs.contains { $0 != groupID && shownName(afterGroups[$0]) == name }
                    if let newName {
                        replacements.append(.init(old: name, new: newName, keepsOld: stillShown))
                        appliedNameUpdates[groupID, default: [:]][filename] = .some(newName)
                    } else if !stillShown, removed.insert(name).inserted {
                        replacements.append(.init(old: name, new: nil))
                        appliedNameUpdates[groupID, default: [:]][filename] = .some(nil)
                    }
                } else if !shownAfter.contains(name), removed.insert(name).inserted {
                    // The group's face left this photo (moved, merged, ungrouped or deleted)
                    // and no remaining face here shows that person.
                    replacements.append(.init(old: name, new: nil))
                    appliedNameUpdates[groupID, default: [:]][filename] = .some(nil)
                }
            }
            // Faces that joined a group whose name this app has written add that name here.
            var added: Set<String> = []
            for groupID in afterIDs.sorted(by: { $0.uuidString < $1.uuidString }) where !beforeIDs.contains(groupID) {
                guard let group = afterGroups[groupID], group.hasAppliedPersonShownName,
                      let name = shownName(group), !appliedNames.contains(name),
                      added.insert(name).inserted else { continue }
                replacements.append(.init(old: nil, new: name))
                appliedNameUpdates[groupID, default: [:]][filename] = .some(name)
            }
            if !replacements.isEmpty { replacementsByURL[url] = replacements }
        }
        guard !replacementsByURL.isEmpty else { return nil }
        return PersonShownUpdateProposal(id: UUID(), folderURL: after.folderURL,
            replacementsByURL: replacementsByURL, appliedNameUpdates: appliedNameUpdates)
    }

    /// The shown name as compared with `FaceGroup.declinedPersonShownName` ("" = no name).
    static func declineToken(for group: FaceGroup) -> String {
        guard !group.isExcludedFromPersonShown else { return "" }
        return group.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// An offer for corrections a previous session left unanswered: groups that still have a
    /// face in a photo whose app-written name differs from the group's current shown name, and
    /// whose current name was not explicitly declined. Returns the synthetic "before" snapshot
    /// (those groups carrying a name the photos received) so later edits re-plan from it, and
    /// the proposal planned from it with the regular planner. Nil when nothing is outstanding.
    static func unansweredProposal(in data: FolderFaceData) -> (base: FolderFaceData, proposal: PersonShownUpdateProposal)? {
        var presentPhotos: [UUID: Set<String>] = [:]
        for face in data.faces {
            guard let groupID = face.groupID else { continue }
            presentPhotos[groupID, default: []].insert(face.imageURL.lastPathComponent)
        }
        var base = data
        var changed = false
        for index in base.groups.indices {
            let group = base.groups[index]
            let current = declineToken(for: group)
            guard group.declinedPersonShownName != current else { continue }
            let photos = presentPhotos[group.id] ?? []
            // A name this app wrote into a photo the group is still in, that differs from what
            // the group shows now. Sorted for a deterministic synthetic name.
            let stale = (group.appliedPersonShownNames ?? [:])
                .filter { photos.contains($0.key) }
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != current }
                .sorted()
            guard let previous = stale.first else { continue }
            base.groups[index].name = previous
            base.groups[index].excludedFromPersonShown = nil
            changed = true
        }
        guard changed, var proposal = proposal(before: base, after: data) else { return nil }
        proposal.isReoffer = true
        return (base, proposal)
    }

    /// Applies per-photo applied-name changes to `data`, optionally only for `photos`.
    static func applying(_ changes: AppliedPersonShownChanges, to data: inout FolderFaceData,
                         onlyPhotos photos: Set<String>? = nil) {
        for (groupID, perPhoto) in changes {
            guard let index = data.groups.firstIndex(where: { $0.id == groupID }) else { continue }
            for (photo, name) in perPhoto where photos?.contains(photo) ?? true {
                data.groups[index].setAppliedPersonShownName(name, forPhoto: photo)
            }
        }
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
