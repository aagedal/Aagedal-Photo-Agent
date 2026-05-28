import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "ApprovedListService")

enum ApprovedListField: String, CaseIterable {
    case keywords
    // v1 ships only .keywords. The enum exists so v2 can add .personShown / .city / etc.
    // without changing the service's public API.

    var displayName: String {
        switch self {
        case .keywords: return "Keywords"
        }
    }

    var bookmarkKey: String { "approvedList.\(rawValue).bookmark" }
    var enabledKey: String  { "approvedList.\(rawValue).enabled" }
    var modeKey: String     { "approvedList.\(rawValue).mode" }

    // v2 slots — declared but not read in v1.
    var remoteURLKey: String       { "approvedList.\(rawValue).remoteURL" }
    var refreshIntervalKey: String { "approvedList.\(rawValue).refreshInterval" }
    var lastRefreshedKey: String   { "approvedList.\(rawValue).lastRefreshed" }
}

enum ApprovedListMode: String, CaseIterable, Identifiable {
    case suggest
    case warn
    case strict

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .suggest: return "Suggest only"
        case .warn:    return "Warn"
        case .strict:  return "Strict — reject"
        }
    }

    var description: String {
        switch self {
        case .suggest:
            return "Show suggestions while typing. Any keyword can be added; no warning for non-approved entries."
        case .warn:
            return "Show suggestions and visually flag any keyword that is not in the approved list. Non-approved keywords are still allowed."
        case .strict:
            return "Show suggestions and reject any keyword not in the approved list. Existing non-approved keywords on a photo are flagged but not removed."
        }
    }
}

struct ApprovedListSuggestion: Hashable, Identifiable {
    enum MatchKind: Hashable { case prefix, substring }
    let canonical: String
    let matchKind: MatchKind
    var id: String { canonical }
}

enum KeywordValidation {
    case accept
    case acceptCanonical(String)
    case reject(reason: String)
}

@Observable
final class ApprovedListService {
    /// Shared instance so SwiftUI views referenced from different `SettingsViewModel`
    /// instances (Settings window, ContentView) see the same parsed list + state.
    /// UserDefaults stays the source of truth; the in-memory cache is what views observe.
    static let shared = ApprovedListService()

    /// Bumped on any state change (file change, mode change, enable toggle).
    /// Views that need to react read this once to register a dependency.
    private(set) var version: Int = 0

    /// Surfaced to Settings UI when the bookmark resolved but the file could not be parsed
    /// or is no longer accessible. nil = no error.
    private(set) var loadError: String?

    private struct ParsedList {
        let ordered: [String]
        let lookup: Set<String>
        let canonicalByNormalized: [String: String]
        let sourcePath: String
    }

    @ObservationIgnored private var cache: [ApprovedListField: ParsedList] = [:]

    init() {
        for field in ApprovedListField.allCases {
            loadFromBookmark(for: field)
        }
    }

    // MARK: - Public surface

    func isEnabled(_ field: ApprovedListField) -> Bool {
        UserDefaults.standard.bool(forKey: field.enabledKey)
    }

    func mode(for field: ApprovedListField) -> ApprovedListMode {
        if let raw = UserDefaults.standard.string(forKey: field.modeKey),
           let mode = ApprovedListMode(rawValue: raw) {
            return mode
        }
        return .warn
    }

    func displayPath(for field: ApprovedListField) -> String? {
        _ = version  // observation dependency
        return cache[field]?.sourcePath
    }

    func entryCount(for field: ApprovedListField) -> Int {
        _ = version
        return cache[field]?.ordered.count ?? 0
    }

    func setEnabled(_ enabled: Bool, for field: ApprovedListField) {
        UserDefaults.standard.set(enabled, forKey: field.enabledKey)
        bumpVersion()
    }

    func setMode(_ mode: ApprovedListMode, for field: ApprovedListField) {
        UserDefaults.standard.set(mode.rawValue, forKey: field.modeKey)
        bumpVersion()
    }

    func setListURL(_ url: URL, for field: ApprovedListField) throws {
        // Parse first so we don't persist a bookmark for a file we can't read.
        let entries = try parseEntries(at: url)

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: field.bookmarkKey)
        } catch {
            logger.error("Failed to create bookmark for approved list: \(String(describing: error))")
            throw error
        }

        installParsed(entries, sourcePath: url.path, for: field)
        loadError = nil
        bumpVersion()
    }

    func clearList(for field: ApprovedListField) {
        UserDefaults.standard.removeObject(forKey: field.bookmarkKey)
        cache.removeValue(forKey: field)
        loadError = nil
        bumpVersion()
    }

    /// True if a list is loaded with at least one entry AND the toggle is on.
    func isActive(for field: ApprovedListField) -> Bool {
        _ = version
        return isEnabled(field) && (cache[field]?.ordered.isEmpty == false)
    }

    /// Whether a list file is configured (regardless of enabled toggle).
    func hasListConfigured(for field: ApprovedListField) -> Bool {
        _ = version
        return cache[field] != nil
    }

    func contains(_ value: String, in field: ApprovedListField) -> Bool {
        _ = version
        guard let parsed = cache[field] else { return false }
        return parsed.lookup.contains(Self.normalize(value))
    }

    func canonicalCasing(of value: String, in field: ApprovedListField) -> String? {
        _ = version
        guard let parsed = cache[field] else { return nil }
        return parsed.canonicalByNormalized[Self.normalize(value)]
    }

    func suggestions(prefix: String, in field: ApprovedListField, limit: Int = 12) -> [ApprovedListSuggestion] {
        _ = version
        guard let parsed = cache[field] else { return [] }
        return Self.suggestions(prefix: prefix, in: parsed.ordered, limit: limit)
    }

    /// Validate a single value against the configured policy for `field`.
    /// Returns `.accept` when the list is inactive, `.acceptCanonical(canonical)` when
    /// the value is in the list (any mode), or `.reject` in Strict mode for non-approved.
    func validate(_ value: String, in field: ApprovedListField) -> KeywordValidation {
        guard isActive(for: field) else { return .accept }
        if let canonical = canonicalCasing(of: value, in: field) {
            return .acceptCanonical(canonical)
        }
        return mode(for: field) == .strict
            ? .reject(reason: "Not in approved list")
            : .accept
    }

    /// Validate many values in one pass. `accepted` is canonicalised and deduped
    /// (case-/diacritic-insensitive); `rejected` preserves the input casing for
    /// user-facing messages. Both arrays follow input order.
    func validateBulk(_ values: [String], in field: ApprovedListField) -> (accepted: [String], rejected: [String]) {
        var accepted: [String] = []
        var rejected: [String] = []
        var seenAccepted = Set<String>()
        for value in values {
            switch validate(value, in: field) {
            case .accept:
                if seenAccepted.insert(Self.normalize(value)).inserted {
                    accepted.append(value)
                }
            case .acceptCanonical(let canonical):
                if seenAccepted.insert(Self.normalize(canonical)).inserted {
                    accepted.append(canonical)
                }
            case .reject:
                rejected.append(value)
            }
        }
        return (accepted, rejected)
    }

    /// Static helper so the same scoring is used for Quick List fallback (caller passes the array).
    static func suggestions(prefix: String, in entries: [String], limit: Int = 12) -> [ApprovedListSuggestion] {
        let p = normalize(prefix)
        guard !p.isEmpty else { return [] }

        var prefixMatches: [String] = []
        var substringMatches: [String] = []
        for entry in entries {
            let n = normalize(entry)
            if n.hasPrefix(p) {
                prefixMatches.append(entry)
            } else if n.contains(p) {
                substringMatches.append(entry)
            }
            if prefixMatches.count + substringMatches.count >= limit * 4 {
                // Soft early-exit for very large lists once we've collected enough candidates to sort.
                break
            }
        }

        prefixMatches.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        substringMatches.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let prefixSugs = prefixMatches.prefix(limit).map { ApprovedListSuggestion(canonical: $0, matchKind: .prefix) }
        let remaining = limit - prefixSugs.count
        let substringSugs = remaining > 0
            ? substringMatches.prefix(remaining).map { ApprovedListSuggestion(canonical: $0, matchKind: .substring) }
            : []
        return prefixSugs + substringSugs
    }

    // MARK: - Internals

    private func bumpVersion() { version &+= 1 }

    private func loadFromBookmark(for field: ApprovedListField) {
        guard let data = UserDefaults.standard.data(forKey: field.bookmarkKey) else {
            cache.removeValue(forKey: field)
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
            logger.error("Failed to resolve approved-list bookmark for \(field.rawValue): \(String(describing: error))")
            cache.removeValue(forKey: field)
            loadError = "Approved list file could not be located."
            return
        }

        let didStart = resolved.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.stopAccessingSecurityScopedResource() } }

        if isStale {
            if let refreshed = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: field.bookmarkKey)
            }
        }

        do {
            let entries = try ApprovedListParser.parse(resolved)
            installParsed(entries, sourcePath: resolved.path, for: field)
            loadError = nil
        } catch {
            logger.error("Failed to parse approved list for \(field.rawValue): \(String(describing: error))")
            cache.removeValue(forKey: field)
            loadError = (error as? LocalizedError)?.errorDescription ?? "Could not load approved list file."
        }
    }

    private func parseEntries(at url: URL) throws -> [String] {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try ApprovedListParser.parse(url)
    }

    private func installParsed(_ entries: [String], sourcePath: String, for field: ApprovedListField) {
        var lookup = Set<String>()
        var canonical: [String: String] = [:]
        var ordered: [String] = []
        ordered.reserveCapacity(entries.count)
        for entry in entries {
            let n = Self.normalize(entry)
            guard !n.isEmpty else { continue }
            if lookup.insert(n).inserted {
                canonical[n] = entry
                ordered.append(entry)
            }
        }
        cache[field] = ParsedList(
            ordered: ordered,
            lookup: lookup,
            canonicalByNormalized: canonical,
            sourcePath: sourcePath
        )
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
