import Foundation

/// Persistent list of recently opened folders, shared between the browser
/// (which records every folder open) and the File ▸ Open Recent menu
/// (which displays and clears it).
@Observable
final class RecentFoldersStore {
    static let shared = RecentFoldersStore(defaults: .standard)

    private(set) var folders: [RecentFolder] = []

    private static let maxCount = 10
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    func track(_ url: URL) {
        let normalizedURL = Self.normalizedFolderURL(url)
        folders.removeAll { Self.normalizedFolderURL($0.url) == normalizedURL }
        folders.insert(RecentFolder(url: normalizedURL), at: 0)
        if folders.count > Self.maxCount {
            folders = Array(folders.prefix(Self.maxCount))
        }
        save()
    }

    func clear() {
        folders = []
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: UserDefaultsKeys.recentFolders),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else {
            return
        }
        folders = Self.sanitized(decoded)
        if folders != decoded {
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: UserDefaultsKeys.recentFolders)
        }
    }

    /// Folder pickers can represent the same directory with or without a trailing
    /// slash, and callers can supply lexical `.`/`..` path components. Persist one
    /// stable directory URL so those spellings share a single Open Recent entry.
    private static func normalizedFolderURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return URL(fileURLWithPath: standardized.path, isDirectory: true)
    }

    /// Older or externally edited defaults may contain duplicates, stale display
    /// names, or more entries than the current menu supports. Repair that data once
    /// at load while preserving the first (most recent) entry and its identity.
    private static func sanitized(_ decoded: [RecentFolder]) -> [RecentFolder] {
        var seen: Set<URL> = []
        var result: [RecentFolder] = []
        result.reserveCapacity(min(decoded.count, maxCount))

        for folder in decoded {
            let normalizedURL = normalizedFolderURL(folder.url)
            guard seen.insert(normalizedURL).inserted else { continue }
            result.append(RecentFolder(id: folder.id, url: normalizedURL))
            if result.count == maxCount { break }
        }
        return result
    }
}
