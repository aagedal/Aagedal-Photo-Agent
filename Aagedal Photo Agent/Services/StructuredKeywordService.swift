import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "StructuredKeywordService")

/// A flattened reference to a node in the tree along with the path that led to it.
/// Used by search and by the "ancestors + synonyms" expansion when a user double-clicks
/// a node in the picker.
struct StructuredKeywordPath: Hashable {
    /// Ancestors from root → parent of `node` (does NOT include `node` itself).
    /// Container ancestors are present here too; callers decide whether to apply them.
    let ancestors: [StructuredKeyword]
    let node: StructuredKeyword
}

@Observable
final class StructuredKeywordService {
    /// Keyword tree: activation includes keyword-ancestors + node + synonyms.
    static let shared = StructuredKeywordService()
    /// Person Shown tree: activation writes the node name + synonyms only —
    /// category ancestors are navigation-only and never applied as names.
    static let personShown = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)

    /// Which managed list this service reads/writes (keywords vs person-shown tree).
    @ObservationIgnored private let key: KeywordListKey
    /// When true (keywords), `expand` prepends keyword-kind ancestors. When false
    /// (person-shown), only the activated node's name and synonyms are returned.
    @ObservationIgnored private let includesAncestors: Bool

    /// Bumped on any state change so SwiftUI views re-render.
    private(set) var version: Int = 0

    /// Surfaced to Settings if the loaded file failed to parse. nil = no error.
    private(set) var loadError: String?

    private(set) var roots: [StructuredKeyword] = []
    private(set) var sourcePath: String?

    @ObservationIgnored nonisolated(unsafe) private var changeObserver: NSObjectProtocol?

    init(key: KeywordListKey = .structured, includesAncestors: Bool = true) {
        self.key = key
        self.includesAncestors = includesAncestors
        loadFromStore()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .keywordListChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract the changed key on the notification queue (synchronously),
            // then ship the Sendable key into the main-actor Task and compare
            // there — `KeywordListKey`'s Equatable conformance is main-actor
            // isolated under the module's default isolation, so the match can't
            // run in this nonisolated callback.
            guard
                let changed = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey
            else { return }
            Task { @MainActor [weak self] in
                guard let self, changed == self.key else { return }
                self.loadFromStore()
            }
        }
    }

    nonisolated deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // MARK: - Public API

    var isLoaded: Bool {
        _ = version
        return !roots.isEmpty
    }

    var rootCount: Int {
        _ = version
        return roots.count
    }

    /// Total number of keyword (non-container) nodes in the tree.
    var keywordCount: Int {
        _ = version
        var count = 0
        for r in roots { count += countKeywords(in: r) }
        return count
    }

    /// Imports a user-picked tab-indented file into the managed store. The
    /// file's bytes are copied into the store and parsed; the source URL is no
    /// longer referenced.
    func importListURL(_ url: URL) throws {
        let text = try KeywordListsStore.shared.importText(from: url, into: key)
        let parsed = StructuredKeywordParser.parseString(text)
        if parsed.isEmpty {
            throw StructuredKeywordParserError.empty
        }
        roots = parsed
        sourcePath = KeywordListsStore.shared.url(for: key).path
        loadError = nil
        bumpVersion()
    }

    /// Saves an edited tree back to the managed store. Re-serialises through
    /// `StructuredKeywordSerializer` so the on-disk format remains PhotoMechanic-compatible.
    func saveTree(_ tree: [StructuredKeyword]) throws {
        let text = StructuredKeywordSerializer.serialize(tree)
        try KeywordListsStore.shared.writeText(text, to: key)
        roots = tree
        sourcePath = KeywordListsStore.shared.url(for: key).path
        loadError = nil
        bumpVersion()
    }

    func clearList() {
        KeywordListsStore.shared.delete(key)
        roots = []
        sourcePath = nil
        loadError = nil
        bumpVersion()
    }

    /// Computes the keywords to add when the user activates (double-clicks) a node.
    /// Returns the clicked keyword, all keyword-kind ancestors, and the clicked node's
    /// synonyms — in a stable order suitable for appending to an existing keyword list.
    /// Container ancestors and container nodes themselves are skipped.
    func expand(_ path: StructuredKeywordPath) -> [String] {
        var result: [String] = []
        if includesAncestors {
            for ancestor in path.ancestors where ancestor.isKeyword {
                result.append(ancestor.name)
            }
        }
        if path.node.isKeyword {
            result.append(path.node.name)
            result.append(contentsOf: path.node.synonyms)
        }
        return result
    }

    /// Expands the keyword node whose canonical name matches `name`
    /// (case-insensitive) as if it had been activated in the picker — see
    /// `expand(_:)`. Returns nil when no keyword node matches, so callers can
    /// fall back to the plain name. The first match in tree order wins when
    /// the same name appears under multiple categories.
    func expansion(forName name: String) -> [String]? {
        _ = version
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }

        var result: [String]?
        for root in roots {
            walk(root, ancestors: []) { node, ancestors in
                guard node.isKeyword, node.name.lowercased() == needle else { return true }
                result = expand(StructuredKeywordPath(ancestors: ancestors, node: node))
                return false
            }
            if result != nil { break }
        }
        return result
    }

    /// Case-insensitive substring search returning up to `limit` matching keyword (not
    /// container) nodes along with their ancestor paths.
    func search(_ query: String, limit: Int = 200) -> [StructuredKeywordPath] {
        _ = version
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [StructuredKeywordPath] = []
        for root in roots {
            walk(root, ancestors: []) { node, ancestors in
                if results.count >= limit { return false }
                guard node.isKeyword else { return true }
                if node.name.lowercased().contains(needle) ||
                    node.synonyms.contains(where: { $0.lowercased().contains(needle) })
                {
                    results.append(StructuredKeywordPath(ancestors: ancestors, node: node))
                }
                return true
            }
            if results.count >= limit { break }
        }
        return results
    }

    /// All keyword-node names (excluding container categories and synonyms),
    /// de-duplicated case-insensitively, in tree order. Used to populate name
    /// pickers / autocomplete where only the canonical names are wanted.
    func allNodeNames() -> [String] {
        _ = version
        var seen = Set<String>()
        var out: [String] = []
        for root in roots {
            walk(root, ancestors: []) { node, _ in
                if node.isKeyword, !node.name.isEmpty,
                   seen.insert(node.name.lowercased()).inserted {
                    out.append(node.name)
                }
                return true
            }
        }
        return out
    }

    /// Flattens the tree into a list of (node, ancestors) pairs whose nodes are
    /// keyword-kind only. Used by the bypass-toggle flow to enumerate every
    /// keyword the user could pick via the structured tree.
    func allKeywordNames() -> [String] {
        _ = version
        var names: [String] = []
        for root in roots {
            walk(root, ancestors: []) { node, _ in
                if node.isKeyword {
                    names.append(node.name)
                    names.append(contentsOf: node.synonyms)
                }
                return true
            }
        }
        return names
    }

    // MARK: - Internals

    private func bumpVersion() { version &+= 1 }

    private func loadFromStore() {
        let store = KeywordListsStore.shared
        guard store.exists(key) else {
            roots = []
            sourcePath = nil
            loadError = nil
            bumpVersion()
            return
        }
        guard let text = store.readText(key) else {
            roots = []
            sourcePath = nil
            loadError = "Could not read structured keywords file."
            bumpVersion()
            return
        }
        let parsed = StructuredKeywordParser.parseString(text)
        roots = parsed
        sourcePath = store.url(for: key).path
        loadError = parsed.isEmpty ? "File contained no keywords." : nil
        bumpVersion()
    }

    private func countKeywords(in node: StructuredKeyword) -> Int {
        var n = node.isKeyword ? 1 : 0
        for child in node.children {
            n += countKeywords(in: child)
        }
        return n
    }

    /// Depth-first walk. The visitor returns `false` to stop the walk early.
    @discardableResult
    private func walk(
        _ node: StructuredKeyword,
        ancestors: [StructuredKeyword],
        visit: (StructuredKeyword, [StructuredKeyword]) -> Bool
    ) -> Bool {
        if !visit(node, ancestors) { return false }
        let childAncestors = ancestors + [node]
        for child in node.children {
            if !walk(child, ancestors: childAncestors, visit: visit) { return false }
        }
        return true
    }
}
