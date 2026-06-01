import Foundation

/// Where rendered/signed/exported files are written.
nonisolated enum ExportLocationMode: String, CaseIterable, Identifiable, Sendable {
    /// Prompt for a destination folder once per export; write files directly into it.
    case askOnSave = "askOnSave"
    /// Write each file next to its source file.
    case sameAsOriginal = "sameAsOriginal"
    /// Write into a sub-folder of the source folder with an exact user-typed name.
    case customSubfolder = "customSubfolder"
    /// Write into a sub-folder automatically named after the export format (default).
    case formatSubfolder = "formatSubfolder"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askOnSave: return "Ask on Save"
        case .sameAsOriginal: return "Same Folder as Original"
        case .customSubfolder: return "Custom Sub-folder"
        case .formatSubfolder: return "Sub-folder Named After Format"
        }
    }

    var description: String {
        switch self {
        case .askOnSave: return "Choose a destination folder each time you export. Files are written directly into the folder you pick."
        case .sameAsOriginal: return "Write exported files alongside each source file, in the same folder."
        case .customSubfolder: return "Write into a sub-folder of the source folder with a name you choose."
        case .formatSubfolder: return "Write into a sub-folder automatically named after the export format (e.g. Edited_JPEG)."
        }
    }
}
