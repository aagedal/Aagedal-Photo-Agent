import Foundation

/// Persistent list of recently opened folders, shared between the browser
/// (which records every folder open) and the File ▸ Open Recent menu
/// (which displays and clears it).
@Observable
final class RecentFoldersStore {
    static let shared = RecentFoldersStore()

    private(set) var folders: [RecentFolder] = []

    private let maxCount = 10

    private init() {
        load()
    }

    func track(_ url: URL) {
        folders.removeAll { $0.url == url }
        folders.insert(RecentFolder(url: url), at: 0)
        if folders.count > maxCount {
            folders = Array(folders.prefix(maxCount))
        }
        save()
    }

    func clear() {
        folders = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.recentFolders),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else {
            return
        }
        folders = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.recentFolders)
        }
    }
}
