import Foundation
import UniformTypeIdentifiers

nonisolated enum BrowserFileVisibility: String, CaseIterable, Sendable {
    case photos, media, all
    var title: String {
        switch self {
        case .photos: "Photos"
        case .media: "All media files"
        case .all: "All files"
        }
    }
    static func saved() -> Self {
        if let value = AppDefaults.store.string(forKey: UserDefaultsKeys.browserFileVisibility), let mode = Self(rawValue: value) { return mode }
        return AppDefaults.store.bool(forKey: UserDefaultsKeys.showAllFiles) ? .all : .photos
    }
    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }
}
