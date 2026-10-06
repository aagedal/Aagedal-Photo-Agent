import Foundation

/// One coordinated file keeps list contents and selection atomic during backup and cloud sync.
/// The original keywords.txt remains at its shipped path and is referenced by `legacyID`.
nonisolated struct StructuredKeywordLibraryDocument: Codable, Equatable, Sendable {
    static let iptcID = "iptc-media-topics"
    static let legacyID = "legacy-keywords"

    enum SelectionMode: String, Codable, CaseIterable, Sendable {
        case single, multiple
    }

    struct List: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var text: String
    }

    /// nil follows the primary system language.
    var languageOverride: String? = nil
    var schemaVersion = 1
    var mode: SelectionMode = .multiple
    var activeIDs: [String] = [iptcID, legacyID]
    var lists: [List] = []

    enum ValidationError: LocalizedError {
        case invalidDocument
        var errorDescription: String? { "The structured keyword library has an unsupported format or invalid list data." }
    }

    static func decode(_ text: String) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        let ids = result.lists.map(\.id)
        let knownIDs = Set(ids + [iptcID, legacyID])
        guard result.schemaVersion == 1,
              result.languageOverride == nil || IPTCMediaTopicsLanguage(rawValue: result.languageOverride!) != nil,
              Set(ids).count == ids.count,
              !ids.contains(iptcID), !ids.contains(legacyID),
              result.lists.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(result.activeIDs).count == result.activeIDs.count,
              result.activeIDs.allSatisfy({ knownIDs.contains($0) }),
              result.mode != .single || result.activeIDs.count <= 1 else {
            throw ValidationError.invalidDocument
        }
        return result
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    mutating func setMode(_ mode: SelectionMode) {
        self.mode = mode
        if mode == .single { activeIDs = Array(activeIDs.prefix(1)) }
    }

    mutating func setActive(_ id: String, active: Bool) {
        activeIDs.removeAll { $0 == id }
        if active {
            if mode == .single { activeIDs = [id] }
            else { activeIDs.append(id) }
        }
    }

    /// Append preserves the destination's selection. Conflicting IDs retain both trees.
    func appending(_ other: Self) -> Self {
        var result = self
        for var list in other.lists {
            if let existing = result.lists.first(where: { $0.id == list.id }) {
                if existing == list { continue }
                list.id = UUID().uuidString
            }
            result.lists.append(list)
        }
        return result
    }
}
