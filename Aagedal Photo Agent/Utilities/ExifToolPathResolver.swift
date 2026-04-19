import Foundation
import OSLog

nonisolated private let exifToolPathLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "ExifToolPathResolver")

nonisolated enum ExifToolPathResolver {
    static var bundledPath: String? {
        if let bundledDir = Bundle.main.path(forResource: "ExifTool", ofType: nil) {
            return (bundledDir as NSString).appendingPathComponent("exiftool")
        }
        return Bundle.main.path(forResource: "exiftool", ofType: nil)
    }

    static var homebrewPath: String? {
        let paths = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var customPath: String? {
        guard let path = UserDefaults.standard.string(forKey: UserDefaultsKeys.exifToolCustomPath),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    static func path(for source: ExifToolSource) -> String? {
        switch source {
        case .bundled: return bundledPath
        case .homebrew: return homebrewPath
        case .custom: return customPath
        }
    }

    static var configuredSource: ExifToolSource {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.exifToolSource) ?? ExifToolSource.bundled.rawValue
        return ExifToolSource(rawValue: raw) ?? .bundled
    }

    /// Resolves the ExifTool path honoring the user's current setting.
    static func resolve() -> String? {
        path(for: configuredSource)
    }

    /// Same as `resolve()`, but logs which path was chosen. Use at long-lived entry points (e.g. service startup).
    static func resolveAndLog() -> String? {
        let source = configuredSource
        let result = path(for: source)
        if let result {
            exifToolPathLog.info("Using \(source.rawValue, privacy: .public) ExifTool at: \(result, privacy: .public)")
        } else {
            exifToolPathLog.warning("No ExifTool found for source '\(source.rawValue, privacy: .public)'")
        }
        return result
    }
}
