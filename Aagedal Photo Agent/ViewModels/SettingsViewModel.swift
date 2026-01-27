import AppKit
import Foundation

struct DetectedEditor: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

@Observable
final class SettingsViewModel {
    var exifToolPathOverride: String {
        didSet { UserDefaults.standard.set(exifToolPathOverride.isEmpty ? nil : exifToolPathOverride, forKey: "exifToolPath") }
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

    var detectedExifToolPath: String? {
        let paths = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init() {
        self.exifToolPathOverride = UserDefaults.standard.string(forKey: "exifToolPath") ?? ""
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
