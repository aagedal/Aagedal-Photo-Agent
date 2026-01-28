import AppKit
import Foundation

struct DetectedEditor: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

enum ExifToolSource: String, CaseIterable {
    case bundled = "bundled"
    case homebrew = "homebrew"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .bundled: return "Bundled"
        case .homebrew: return "Homebrew"
        case .custom: return "Custom"
        }
    }
}

@Observable
final class SettingsViewModel {
    var exifToolSource: ExifToolSource {
        didSet { UserDefaults.standard.set(exifToolSource.rawValue, forKey: "exifToolSource") }
    }

    var exifToolCustomPath: String {
        didSet { UserDefaults.standard.set(exifToolCustomPath.isEmpty ? nil : exifToolCustomPath, forKey: "exifToolCustomPath") }
    }

    var defaultExternalEditor: String {
        didSet { UserDefaults.standard.set(defaultExternalEditor.isEmpty ? nil : defaultExternalEditor, forKey: "defaultExternalEditor") }
    }

    var defaultExternalEditorName: String {
        guard !defaultExternalEditor.isEmpty else { return "Not set" }
        return URL(fileURLWithPath: defaultExternalEditor).deletingPathExtension().lastPathComponent
    }

    var faceCleanupPolicy: FaceCleanupPolicy {
        didSet { UserDefaults.standard.set(faceCleanupPolicy.rawValue, forKey: "faceCleanupPolicy") }
    }

    var detectedEditors: [DetectedEditor] = []

    var bundledExifToolPath: String? {
        // Try ExifTool folder first, then direct resource
        if let bundledDir = Bundle.main.path(forResource: "ExifTool", ofType: nil) {
            return (bundledDir as NSString).appendingPathComponent("exiftool")
        }
        return Bundle.main.path(forResource: "exiftool", ofType: nil)
    }

    var homebrewExifToolPath: String? {
        let paths = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var selectedExifToolPath: String? {
        switch exifToolSource {
        case .bundled:
            return bundledExifToolPath
        case .homebrew:
            return homebrewExifToolPath
        case .custom:
            let path = exifToolCustomPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
    }

    init() {
        let sourceRaw = UserDefaults.standard.string(forKey: "exifToolSource") ?? "bundled"
        self.exifToolSource = ExifToolSource(rawValue: sourceRaw) ?? .bundled
        self.exifToolCustomPath = UserDefaults.standard.string(forKey: "exifToolCustomPath") ?? ""
        self.defaultExternalEditor = UserDefaults.standard.string(forKey: "defaultExternalEditor") ?? ""
        let raw = UserDefaults.standard.string(forKey: "faceCleanupPolicy") ?? "never"
        self.faceCleanupPolicy = FaceCleanupPolicy(rawValue: raw) ?? .never
        self.detectedEditors = Self.detectEditors()
    }

    static func detectEditors() -> [DetectedEditor] {
        let candidates: [(name: String, bundleIDs: [String])] = [
            ("Adobe Photoshop", [
                "com.adobe.Photoshop",
                "com.adobe.Photoshop2024",
                "com.adobe.Photoshop2025",
                "com.adobe.Photoshop2026",
            ]),
            ("Affinity Photo", [
                "com.seriflabs.affinityphoto2",
                "com.seriflabs.affinityphoto",
            ]),
            ("GIMP", [
                "org.gimp.gimp-2.10",
                "org.gimp.GIMP",
                "org.gimp.gimp",
            ]),
        ]

        var editors: [DetectedEditor] = []
        for candidate in candidates {
            for bundleID in candidate.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    editors.append(DetectedEditor(name: candidate.name, path: url.path))
                    break
                }
            }
        }
        return editors
    }
}
