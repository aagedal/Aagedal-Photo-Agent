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
    static let shared = StructuredKeywordService()

    /// Bumped on any state change so SwiftUI views re-render.
    private(set) var version: Int = 0

    /// Surfaced to Settings if the loaded file failed to parse. nil = no error.
    private(set) var loadError: String?

    private(set) var roots: [StructuredKeyword] = []
    private(set) var sourcePath: String?

    private let bookmarkKey = "structuredKeywords.bookmark"

    init() {
        loadFromBookmark()
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

    func setListURL(_ url: URL) throws {
        let parsed = try parseEntries(at: url)

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            logger.error("Failed to create bookmark for structured keywords: \(String(describing: error))")
            throw error
        }

        roots = parsed
        sourcePath = url.path
        loadError = nil
        bumpVersion()
    }

    func clearList() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
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
        for ancestor in path.ancestors where ancestor.isKeyword {
            result.append(ancestor.name)
        }
        if path.node.isKeyword {
            result.append(path.node.name)
            result.append(contentsOf: path.node.synonyms)
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

    // MARK: - Internals

    private func bumpVersion() { version &+= 1 }

    private func loadFromBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            roots = []
            sourcePath = nil
            return
        }
        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            logger.error("Failed to resolve structured keywords bookmark: \(String(describing: error))")
            roots = []
            sourcePath = nil
            loadError = "Structured keywords file could not be located."
            return
        }

        let didStart = resolved.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.stopAccessingSecurityScopedResource() } }

        if isStale {
            if let refreshed = try? resolved.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
        }

        do {
            let parsed = try StructuredKeywordParser.parse(resolved)
            roots = parsed
            sourcePath = resolved.path
            loadError = nil
        } catch {
            logger.error("Failed to parse structured keywords: \(String(describing: error))")
            roots = []
            sourcePath = nil
            loadError = (error as? LocalizedError)?.errorDescription ?? "Could not load structured keywords file."
        }
    }

    private func parseEntries(at url: URL) throws -> [StructuredKeyword] {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try StructuredKeywordParser.parse(url)
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
