import Foundation

@Observable
final class SettingsViewModel {
    var exifToolPathOverride: String {
        get { UserDefaults.standard.string(forKey: "exifToolPath") ?? "" }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "exifToolPath") }
    }

    var defaultExternalEditor: String {
        get { UserDefaults.standard.string(forKey: "defaultExternalEditor") ?? "" }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "defaultExternalEditor") }
    }

    var defaultExternalEditorName: String {
        guard !defaultExternalEditor.isEmpty else { return "Not set" }
        return URL(fileURLWithPath: defaultExternalEditor).deletingPathExtension().lastPathComponent
    }

    var detectedExifToolPath: String? {
        let paths = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
