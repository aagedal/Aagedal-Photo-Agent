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
    var allowStructuredBypassKey: String { "approvedList.\(rawValue).allowStructuredBypass" }

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
    /// `KeywordListsStore` is the source of truth on disk; the in-memory cache
    /// is what views observe.
    static let shared = ApprovedListService()

    /// Bumped on any state change (file change, mode change, enable toggle).
    /// Views that need to react read this once to register a dependency.
    private(set) var version: Int = 0

    /// Surfaced to Settings UI when the file backing a list could not be read
    /// or parsed. nil = no error.
    private(set) var loadError: String?

    private struct ParsedList {
        let ordered: [String]
        let lookup: Set<String>
        let canonicalByNormalized: [String: String]
        let sourcePath: String
    }

    @ObservationIgnored private var cache: [ApprovedListField: ParsedList] = [:]
    @ObservationIgnored nonisolated(unsafe) private var changeObserver: NSObjectProtocol?

    init() {
        for field in ApprovedListField.allCases {
            loadFromStore(for: field)
        }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .keywordListChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let key = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey,
                case .approved(let field) = key
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loadFromStore(for: field)
                self.bumpVersion()
            }
        }
    }

    nonisolated deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // MARK: - Public surface

    func isEnabled(_ field: ApprovedListField) -> Bool {
        AppDefaults.store.bool(forKey: field.enabledKey)
    }

    func mode(for field: ApprovedListField) -> ApprovedListMode {
        if let raw = AppDefaults.store.string(forKey: field.modeKey),
           let mode = ApprovedListMode(rawValue: raw) {
            return mode
        }
        return .warn
    }

    /// Whether the structured-tree picker's contributions should bypass approved-list
    /// validation. Default true (matches pre-toggle behaviour).
    func allowStructuredBypass(_ field: ApprovedListField) -> Bool {
        if AppDefaults.store.object(forKey: field.allowStructuredBypassKey) == nil {
            return true
        }
        return AppDefaults.store.bool(forKey: field.allowStructuredBypassKey)
    }

    func displayPath(for field: ApprovedListField) -> String? {
        _ = version  // observation dependency
        return cache[field]?.sourcePath
    }

    func entryCount(for field: ApprovedListField) -> Int {
        _ = version
        return cache[field]?.ordered.count ?? 0
    }

    /// Entries in stored order — used by the in-app editor and by export bundles.
    func orderedEntries(for field: ApprovedListField) -> [String] {
        _ = version
        return cache[field]?.ordered ?? []
    }

    func setEnabled(_ enabled: Bool, for field: ApprovedListField) {
        AppDefaults.store.set(enabled, forKey: field.enabledKey)
        bumpVersion()
    }

    func setMode(_ mode: ApprovedListMode, for field: ApprovedListField) {
        AppDefaults.store.set(mode.rawValue, forKey: field.modeKey)
        bumpVersion()
    }

    func setAllowStructuredBypass(_ enabled: Bool, for field: ApprovedListField) {
        AppDefaults.store.set(enabled, forKey: field.allowStructuredBypassKey)
        bumpVersion()
    }

    /// Imports a user-picked file into the managed store. After this the file
    /// content lives in the store; the source URL is no longer referenced.
    func importListURL(_ url: URL, for field: ApprovedListField) throws {
        let entries = try KeywordListsStore.shared.importEntries(from: url, into: .approved(field))
        installParsed(entries, sourcePath: KeywordListsStore.shared.url(for: .approved(field)).path, for: field)
        loadError = nil
        bumpVersion()
    }

    /// Writes the given entries to the managed store. Used by the editor UI.
    func saveEntries(_ entries: [String], for field: ApprovedListField) throws {
        try KeywordListsStore.shared.writeEntries(entries, to: .approved(field))
        // Reload our cache from the canonical store so casing/dedup matches what
        // future reads will return.
        loadFromStore(for: field)
        bumpVersion()
    }

    func clearList(for field: ApprovedListField) {
        KeywordListsStore.shared.delete(.approved(field))
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

    /// Canonical entries in source-file order. Caption Workspace uses this read-only snapshot to
    /// combine approved values with other typed autocomplete sources without duplicating parsing.
    func allEntries(for field: ApprovedListField) -> [String] {
        _ = version
        return cache[field]?.ordered ?? []
    }

    /// Validate a single value against the configured policy for `field`.
    /// Returns `.accept` when the list is inactive, `.acceptCanonical(canonical)` when
    /// the value is in the list (any mode), or `.reject` in Strict mode for non-approved.
    ///
    /// `source` lets callers declare where the value originated; when it is
    /// `.structuredTree` and the per-field "allow structured bypass" toggle is
    /// on, the result is forced to `.accept`.
    func validate(_ value: String, in field: ApprovedListField, source: KeywordSource = .user) -> KeywordValidation {
        guard isActive(for: field) else { return .accept }
        if source == .structuredTree, allowStructuredBypass(field) {
            return .accept
        }
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
    func validateBulk(_ values: [String], in field: ApprovedListField, source: KeywordSource = .user) -> (accepted: [String], rejected: [String]) {
        var accepted: [String] = []
        var rejected: [String] = []
        var seenAccepted = Set<String>()
        for value in values {
            switch validate(value, in: field, source: source) {
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

    private func loadFromStore(for field: ApprovedListField) {
        let store = KeywordListsStore.shared
        let key = KeywordListKey.approved(field)
        guard store.exists(key) else {
            cache.removeValue(forKey: field)
            return
        }
        let entries = store.readEntries(key)
        if entries.isEmpty {
            // The file exists but parsed to nothing — surface a hint but keep
            // the entry-less cache so `hasListConfigured` returns true.
            installParsed([], sourcePath: store.url(for: key).path, for: field)
            return
        }
        installParsed(entries, sourcePath: store.url(for: key).path, for: field)
        loadError = nil
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
