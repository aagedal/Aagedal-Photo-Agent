import AppKit

/// Resolves the once-per-batch destination folder for the export location modes that
/// write directly into a folder outside the source tree (`.askOnSave`, `.specificFolder`).
enum ExportDestinationPrompt {
    enum Outcome: Equatable {
        /// The user dismissed a folder prompt; abort the export.
        case cancelled
        /// Pass as `askedFolder`; nil when the mode derives its folder from each source.
        case folder(URL?)
    }

    /// `.askOnSave` always prompts. `.specificFolder` uses the folder chosen in Settings, and
    /// prompts (saving the answer as the new specific folder) only when none is set or the
    /// saved one is missing — e.g. on an unmounted drive — so exports never land in the
    /// source folder by surprise.
    static func resolve(
        for mode: ExportLocationMode,
        startingAt directoryURL: URL?,
        message: String = "Choose a destination folder for exported files"
    ) -> Outcome {
        switch mode {
        case .askOnSave:
            guard let chosen = chooseFolder(startingAt: directoryURL, message: message) else {
                return .cancelled
            }
            return .folder(chosen)
        case .specificFolder:
            if let saved = EditedImageRenderer.specificExportFolderURL,
               FileManager.default.fileExists(atPath: saved.path) {
                return .folder(saved)
            }
            guard let chosen = chooseFolder(
                startingAt: directoryURL,
                message: "Choose the folder all exports are saved to. You can change it in Settings → Locations."
            ) else {
                return .cancelled
            }
            saveSpecificFolder(chosen)
            return .folder(chosen)
        case .sameAsOriginal, .customSubfolder, .formatSubfolder:
            return .folder(nil)
        }
    }

    static func saveSpecificFolder(_ url: URL) {
        RAWArchiveService.saveBookmark(for: url, key: UserDefaultsKeys.exportSpecificFolderBookmark)
    }

    static func chooseFolder(startingAt directoryURL: URL?, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = directoryURL
        return panel.runModal() == .OK ? panel.url : nil
    }
}
