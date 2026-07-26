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

/// Where the contextual “Archive RAW as…” command writes its output.
nonisolated enum RAWArchiveLocationMode: String, CaseIterable, Identifiable, Sendable {
    /// Put archives in an `Archive` directory inside each source work folder.
    case workFolderArchive = "workFolderArchive"
    /// Recreate the work folder's path below a separately selected archive root.
    case mirroredArchiveRoot = "mirroredArchiveRoot"
    /// Ask for one destination folder for each archive batch.
    case askEveryTime = "askEveryTime"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .workFolderArchive: return "Archive Sub-folder in Work Folder"
        case .mirroredArchiveRoot: return "Separate Archive with Mirrored Structure"
        case .askEveryTime: return "Ask Every Time"
        }
    }

    var description: String {
        switch self {
        case .workFolderArchive:
            return "Save into an Archive sub-folder inside the folder containing each source RAW."
        case .mirroredArchiveRoot:
            return "Mirror the source folder's path below the main ingest folder into a separate Archive root."
        case .askEveryTime:
            return "Choose one destination folder whenever you start a RAW archive batch."
        }
    }
}
