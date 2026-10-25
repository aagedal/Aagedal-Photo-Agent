import Foundation

enum ImportFileTypeFilter: String, CaseIterable, Sendable {
    case rawOnly = "RAW Only"
    case jpegOnly = "JPEG Only"
    case both = "Both"
}

enum ImportConflictPolicy: String, CaseIterable, Sendable {
    case skipExisting = "skipExisting"
    case renameWithSuffix = "renameWithSuffix"
    case overwrite = "overwrite"

    var displayName: String {
        switch self {
        case .skipExisting:
            return "Skip Existing"
        case .renameWithSuffix:
            return "Rename"
        case .overwrite:
            return "Overwrite"
        }
    }

    var description: String {
        switch self {
        case .skipExisting:
            return "Skip files that already exist at the destination."
        case .renameWithSuffix:
            return "Keep both files by appending a numeric suffix."
        case .overwrite:
            return "Replace files that already exist at the destination."
        }
    }
}

enum CopyVerificationMode: String, CaseIterable, Sendable {
    case off
    case on

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Skip verification. Faster, but silent corruption can go undetected."
        case .on:
            return "Hash each file with SHA-256 during copy and re-read the destination to confirm. Recommended for memory-card ingest."
        }
    }
}

enum ImportDateFolderGrouping: String, CaseIterable, Sendable {
    case none
    case year
    case month

    var displayName: String {
        switch self {
        case .none: return "None"
        case .year: return "Year"
        case .month: return "Month"
        }
    }

    var description: String {
        switch self {
        case .none:
            return "Each date group will be imported under the destination base."
        case .year:
            return "Each date group will be imported under <year>/<date>."
        case .month:
            return "Each date group will be imported under <year>/<month>/<date>."
        }
    }
}

struct BackupDestination: Sendable, Equatable {
    var url: URL
    var verifyAfterWrite: Bool = true
}

struct ImportConfiguration {
    /// New installs import into ~/Pictures. Earlier versions defaulted to ~/Photos; keep using it
    /// when it already exists so imports and mirrored RAW archives stay in the same tree.
    nonisolated static var defaultDestinationURL: URL {
        let fileManager = FileManager.default
        let legacy = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Photos", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return legacy
        }
        return fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
    }

    var sourceURL: URL?
    /// Optional second media source. Its RAW/JPEG files participate in the selected file-type
    /// filter, and its Sony WAV files can be associated with matching exposures on either source.
    var voiceMemoSourceURL: URL?
    var destinationBaseURL: URL = ImportConfiguration.defaultDestinationURL
    var importTitle: String = ""
    var fileTypeFilter: ImportFileTypeFilter = .both {
        didSet { AppDefaults.store.set(fileTypeFilter.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter) }
    }
    var conflictPolicy: ImportConflictPolicy = .renameWithSuffix {
        didSet { AppDefaults.store.set(conflictPolicy.rawValue, forKey: UserDefaultsKeys.importConflictPolicy) }
    }
    var createSubFolders: Bool = true {
        didSet { AppDefaults.store.set(createSubFolders, forKey: UserDefaultsKeys.importCreateSubFolders) }
    }
    var applyMetadata: Bool = false
    var processVariables: Bool = false
    var metadata: IPTCMetadata = IPTCMetadata()
    var openFolderAfterImport: Bool = true
    var verificationMode: CopyVerificationMode = .on {
        didSet { AppDefaults.store.set(verificationMode.rawValue, forKey: UserDefaultsKeys.importVerificationMode) }
    }
    var backupDestination: BackupDestination? {
        didSet {
            if let backupDestination {
                AppDefaults.store.set(backupDestination.verifyAfterWrite, forKey: UserDefaultsKeys.importBackupVerifyAfterWrite)
            }
        }
    }
    var skipPreviouslyImported: Bool = true {
        didSet { AppDefaults.store.set(skipPreviouslyImported, forKey: UserDefaultsKeys.importSkipPreviouslyImported) }
    }

    var destinationFolderName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let title = importTitle.trimmingCharacters(in: .whitespaces)
        if title.isEmpty {
            return dateStr
        }
        return "\(dateStr) \u{2013} \(title)"
    }

    var destinationFolderURL: URL {
        destinationBaseURL.appendingPathComponent(destinationFolderName)
    }
}
