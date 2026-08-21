import AppKit
import Foundation
import SwiftExif
import os

enum ImportPhase: Equatable {
    case idle
    case scanning
    case copying
    case applyingMetadata
    case complete
    case cancelled
    case failed(String)
}

/// Surfaced to the UI to render mismatch and backup-failure rows in the summary.
struct ImportFailureRecord: Identifiable, Sendable, Hashable {
    let id = UUID()
    let source: URL
    let kind: Kind
    let detail: String

    enum Kind: String, Sendable {
        case copyFailed
        case verificationMismatch
        case backupFailed
    }
}

/// Per-date group for sorting source files into separate destination folders.
struct ImportDateGroup: Identifiable {
    let id = UUID()
    let dateString: String
    var folderName: String
    var shootFolderName: String?
    var isIncluded: Bool = true
    /// 4-digit year derived from the parsed capture date. `nil` when the date could
    /// not be parsed; such groups stay flat under the destination base even when
    /// "Group by year" is enabled, to avoid creating a bogus year folder.
    var yearFolder: String?
    /// Month folder derived from the parsed capture date. Used below `yearFolder`
    /// when month grouping is enabled.
    var monthFolder: String? = nil
    var files: [URL]
    /// Full per-file capture timestamps (EXIF `DateTimeOriginal`, or file mtime as a
    /// fallback). A file may be absent here when no timestamp could be read. Used for
    /// chronological ordering, evenly-spread thumbnail sampling, and gap detection —
    /// never persisted, so it is safe to anchor parsing to UTC.
    var captureTimes: [URL: Date] = [:]

    /// Files ordered by capture time. Files without a timestamp fall back to a stable
    /// filename ordering and sort after timestamped files of equal standing.
    var chronologicalFiles: [URL] {
        ImportViewModel.chronologicalOrder(of: files, captureTimes: captureTimes)
    }
}

@Observable
final class ImportViewModel {
    var configuration = ImportConfiguration()
    var sourceFiles: [URL] = []
    var importPhase: ImportPhase = .idle
    var copiedFiles: Int = 0
    var totalFiles: Int = 0
    var skippedFiles: Int = 0
    var duplicateSkippedFiles: Int = 0
    var renamedFiles: Int = 0
    var failedFiles: Int = 0
    var verifiedFiles: Int = 0
    var mismatchedFiles: Int = 0
    var backupCopiedFiles: Int = 0
    var backupFailedFiles: Int = 0
    var currentFile: String = ""
    var importSummary: String = ""
    var errorMessage: String?
    var failureRecords: [ImportFailureRecord] = []

    /// Sticky completion banner shown in the inspector until the user confirms it.
    /// A new import clears any previous (un-dismissed) banner.
    var showCompletionBanner: Bool = false
    /// Backs the current completion banner (summary text + clean/problem state).
    private(set) var lastCompletionEntry: ActivityEntry?

    /// Capture-date groups detected from source files.
    var dateGroups: [ImportDateGroup] = []
    /// Whether the user wants to sort files into per-date folders.
    var sortByDate: Bool = false {
        didSet {
            UserDefaults.standard.set(sortByDate, forKey: UserDefaultsKeys.importSortByDate)
        }
    }
    /// When `sortByDate` is on, optionally wrap date folders in a parent folder.
    var dateFolderGrouping: ImportDateFolderGrouping = .none {
        didSet {
            UserDefaults.standard.set(dateFolderGrouping.rawValue, forKey: UserDefaultsKeys.importDateFolderGrouping)
            UserDefaults.standard.set(dateFolderGrouping == .year, forKey: UserDefaultsKeys.importGroupByYear)
        }
    }
    /// When a single capture date is split into multiple shoots, import the shoots
    /// as subfolders inside that date folder instead of sibling date folders.
    var splitShootsIntoSubfolders: Bool = false {
        didSet {
            UserDefaults.standard.set(splitShootsIntoSubfolders, forKey: UserDefaultsKeys.importSplitShootsIntoSubfolders)
            normalizeSplitFolderLayout()
        }
    }
    /// Whether date scanning is in progress.
    var isScanningDates: Bool = false
    /// Existing destination folders keyed by their `yyyy-MM-dd` prefix. Populated
    /// asynchronously so browsing a large photo destination never blocks the sheet.
    private(set) var previousImportFolderSuggestions: [String: [URL]] = [:]
    var isScanningPreviousImportFolders: Bool = false

    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    @ObservationIgnored private let activityHistory: ActivityHistoryStore?
    /// Per-file copy results accumulated during the current run, used to build the
    /// activity-history entry (per-file destination + verification) on finish.
    @ObservationIgnored private var copyResults: [ImportCopyService.CopyResult] = []
    private let interpolator = PresetVariableInterpolator()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var dateScanTask: Task<Void, Never>?
    @ObservationIgnored private var folderSuggestionTask: Task<Void, Never>?
    @ObservationIgnored private var folderSuggestionRequestID = UUID()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private let copyService = ImportCopyService()
    private let importLog = Logger(subsystem: "com.aagedal.photo-agent", category: "Import")

    init(readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine, activityHistory: ActivityHistoryStore? = nil) {
        self.readService = readService
        self.writeEngine = writeEngine
        self.activityHistory = activityHistory

        // Restore last-used verification mode (default = .on).
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.importVerificationMode),
           let mode = CopyVerificationMode(rawValue: raw) {
            self.configuration.verificationMode = mode
        }
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.importFileTypeFilter),
           let filter = ImportFileTypeFilter(rawValue: raw) {
            self.configuration.fileTypeFilter = filter
        }
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.importConflictPolicy),
           let policy = ImportConflictPolicy(rawValue: raw) {
            self.configuration.conflictPolicy = policy
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.importCreateSubFolders) != nil {
            self.configuration.createSubFolders = UserDefaults.standard.bool(forKey: UserDefaultsKeys.importCreateSubFolders)
        }
        if let destinationURL = Self.resolveBookmark(
            key: UserDefaultsKeys.importDestinationBookmark
        ) {
            self.configuration.destinationBaseURL = destinationURL
        }

        // Restore last-used date-folder grouping. Fall back to the legacy year
        // toggle so existing installs keep their previous behavior.
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.importSortByDate) != nil {
            self.sortByDate = UserDefaults.standard.bool(forKey: UserDefaultsKeys.importSortByDate)
        }
        if let rawGrouping = UserDefaults.standard.string(forKey: UserDefaultsKeys.importDateFolderGrouping),
           let grouping = ImportDateFolderGrouping(rawValue: rawGrouping) {
            self.dateFolderGrouping = grouping
        } else {
            self.dateFolderGrouping = UserDefaults.standard.bool(forKey: UserDefaultsKeys.importGroupByYear) ? .year : .none
        }
        self.splitShootsIntoSubfolders = UserDefaults.standard.bool(forKey: UserDefaultsKeys.importSplitShootsIntoSubfolders)
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.importSkipPreviouslyImported) != nil {
            self.configuration.skipPreviouslyImported = UserDefaults.standard.bool(forKey: UserDefaultsKeys.importSkipPreviouslyImported)
        }
        if let backupURL = Self.resolveBookmark(key: UserDefaultsKeys.importBackupBookmark) {
            let verifyAfterWrite = UserDefaults.standard.object(forKey: UserDefaultsKeys.importBackupVerifyAfterWrite) as? Bool ?? true
            self.configuration.backupDestination = BackupDestination(url: backupURL, verifyAfterWrite: verifyAfterWrite)
        }
    }

    deinit {
        scanTask?.cancel()
        dateScanTask?.cancel()
        folderSuggestionTask?.cancel()
        importTask?.cancel()
    }

    var isImporting: Bool {
        switch importPhase {
        case .copying, .applyingMetadata:
            return true
        default:
            return false
        }
    }

    var filteredSourceFiles: [URL] {
        switch configuration.fileTypeFilter {
        case .rawOnly:
            return sourceFiles.filter { SupportedImageFormats.isRaw(url: $0) }
        case .jpegOnly:
            return sourceFiles.filter { SupportedImageFormats.isJPEG(url: $0) }
        case .both:
            return sourceFiles
        }
    }

    var selectedSourceFiles: [URL] {
        let filtered = filteredSourceFiles
        guard sortByDate else { return filtered }
        let includedFiles = Set(dateGroups.filter(\.isIncluded).flatMap(\.files))
        return filtered.filter { includedFiles.contains($0) }
    }

    /// Explains why the import cannot start, in the same priority order the
    /// user encounters the setup steps. Keeping this validation in the view
    /// model ensures the button state, its explanation, and `startImport()`
    /// cannot drift apart.
    var importBlockingReason: String? {
        if importPhase == .scanning {
            return "Scanning the source folder…"
        }
        if configuration.sourceURL == nil {
            return "Choose a memory card or folder to import from."
        }
        if sourceFiles.isEmpty {
            return "No supported images were found in the source folder."
        }
        if filteredSourceFiles.isEmpty {
            return "No images match the \(configuration.fileTypeFilter.rawValue) filter."
        }

        if sortByDate {
            if isScanningDates {
                return "Scanning capture dates…"
            }
            if dateGroups.isEmpty {
                return "Scan capture dates before importing."
            }
            if selectedSourceFiles.isEmpty {
                return "Select at least one date folder to import."
            }
        } else if configuration.importTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an import title."
        }

        return nil
    }

    // MARK: - Source Selection

    func selectSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a memory card or folder to import photos from"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.sourceURL = url
        scanSource(url: url)
    }

    private func scanSource(url: URL) {
        scanTask?.cancel()
        // A new source folder invalidates any previously detected date groups
        // (and any manual shoot splits); clear them so the list never shows stale
        // entries from the old folder.
        dateScanTask?.cancel()
        importPhase = .scanning
        sourceFiles = []
        dateGroups = []

        scanTask = Task.detached(priority: .userInitiated) {
            let allURLs = Self.enumerateFiles(at: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.sourceFiles = allURLs
                    .filter { SupportedImageFormats.isSupported(url: $0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                self.importPhase = .idle
                // Re-detect capture dates for the new folder when date sorting is on.
                if self.sortByDate {
                    self.scanCaptureDates()
                }
            }
        }
    }

    /// Enumerate all regular files under `url` off the main actor.
    nonisolated private static func enumerateFiles(at url: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var found: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            found.append(fileURL)
        }
        return found
    }

    // MARK: - Destination Selection

    func selectDestinationBase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the destination root folder for imports"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.destinationBaseURL = url
        Self.saveBookmark(
            for: url,
            key: UserDefaultsKeys.importDestinationBookmark
        )
        refreshPreviousImportFolderSuggestions()
    }

    // MARK: - Existing Date-Folder Suggestions

    var currentImportDateFolderName: String {
        String(configuration.destinationFolderName.prefix(10))
    }

    /// Rebuilds the lightweight list of existing same-date folders. This only
    /// inspects the importer-supported folder levels; it does not enumerate or
    /// checksum their files until an import actually starts.
    func refreshPreviousImportFolderSuggestions() {
        folderSuggestionTask?.cancel()
        let requestID = UUID()
        folderSuggestionRequestID = requestID

        let dates: Set<String>
        if sortByDate {
            dates = Set(dateGroups.map { displayDate(for: $0) })
        } else {
            dates = [currentImportDateFolderName]
        }

        guard !dates.isEmpty else {
            previousImportFolderSuggestions = [:]
            isScanningPreviousImportFolders = false
            return
        }

        let destinationBaseURL = configuration.destinationBaseURL
        previousImportFolderSuggestions = [:]
        isScanningPreviousImportFolders = true

        folderSuggestionTask = Task.detached(priority: .utility) { [weak self] in
            var suggestions: [String: [URL]] = [:]
            for date in dates.sorted() {
                guard !Task.isCancelled else { return }
                let folders = PreviousImportDetector.matchingDateFolders(
                    named: date,
                    under: destinationBaseURL
                )
                if !folders.isEmpty {
                    suggestions[date] = folders
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.folderSuggestionRequestID == requestID else { return }
                self.previousImportFolderSuggestions = suggestions
                self.isScanningPreviousImportFolders = false
            }
        }
    }

    /// Standard flat-import folders directly below the current destination base.
    /// Only app-generated `<date> – <title>` names are selectable because those
    /// can be represented exactly by `ImportConfiguration.importTitle`.
    func suggestedFoldersForCurrentImportDate() -> [URL] {
        let date = currentImportDateFolderName
        let expectedParent = configuration.destinationBaseURL.standardizedFileURL
        return (previousImportFolderSuggestions[date] ?? []).filter { url in
            url.deletingLastPathComponent().standardizedFileURL == expectedParent
                && PreviousImportDetector.importTitle(
                    from: url.lastPathComponent,
                    matchingDate: date
                ) != nil
        }
    }

    /// Same-date folders at the exact grouping level currently selected for a
    /// capture-date group, so choosing one always targets the folder being shown.
    func suggestedFolders(for group: ImportDateGroup) -> [URL] {
        let date = displayDate(for: group)
        let expectedParent = Self.appendingPathComponents(
            folderGroupingComponents(for: group, grouping: dateFolderGrouping),
            to: configuration.destinationBaseURL
        ).standardizedFileURL
        return (previousImportFolderSuggestions[date] ?? []).filter {
            $0.deletingLastPathComponent().standardizedFileURL == expectedParent
        }
    }

    func useSuggestedFolderForCurrentImport(_ folder: URL) {
        let date = currentImportDateFolderName
        guard suggestedFoldersForCurrentImportDate().contains(folder),
              let title = PreviousImportDetector.importTitle(
                from: folder.lastPathComponent,
                matchingDate: date
              ) else { return }
        configuration.importTitle = title
    }

    func useSuggestedFolder(_ folder: URL, for groupID: UUID) {
        guard let index = dateGroups.firstIndex(where: { $0.id == groupID }),
              suggestedFolders(for: dateGroups[index]).contains(folder) else { return }
        dateGroups[index].folderName = folder.lastPathComponent
        ensureUniqueFolderNames()
    }

    // MARK: - Template Application

    func applyTemplate(_ template: MetadataTemplate) {
        for field in template.fields {
            let value = field.templateValue
            switch field.fieldKey {
            case "title": configuration.metadata.title = value
            case "description": configuration.metadata.description = value
            case "keywords":
                configuration.metadata.keywords = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "personShown":
                configuration.metadata.personShown = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "organisationShownName":
                configuration.metadata.organisationsShownNames = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "organisationShownCode":
                configuration.metadata.organisationsShownCodes = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "digitalSourceType":
                configuration.metadata.digitalSourceType = DigitalSourceType(metadataValue: value)
            case "urgency":
                configuration.metadata.urgency = Int(value)
            case "sceneCode":
                configuration.metadata.sceneCodes = IPTCSceneCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
            case "subjectCode":
                configuration.metadata.subjectCodes = IPTCSubjectCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
            case "mediaTopic":
                configuration.metadata.mediaTopics = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
                )
            case "genre":
                configuration.metadata.genres = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
                )
            case "creator":
                configuration.metadata.creators = IPTCMetadata.creators(fromTransportValue: value)
            case "creatorJobTitle": configuration.metadata.creatorJobTitle = value
            case "descriptionWriter": configuration.metadata.descriptionWriter = value
            case "credit": configuration.metadata.credit = value
            case "copyright": configuration.metadata.copyright = value
            case "rightsUsageTerms": configuration.metadata.rightsUsageTerms = value
            case "webStatementOfRights": configuration.metadata.webStatementOfRights = value
            case "digitalImageGUID": configuration.metadata.digitalImageGUID = value
            case "imageSupplierImageID": configuration.metadata.imageSupplierImageID = value
            case "imageSupplier":
                if let values = EditorialImageSupplier.values(fromCanonicalJSONString: value) {
                    configuration.metadata.imageSuppliers = values
                }
            case "dateCreated":
                if MetadataTemplatePlaceholderDetector.containsPlaceholder(value)
                    || (try? EditorialDateCreated(parsing: value)) != nil {
                    configuration.metadata.dateCreated = value
                }
            case "city": configuration.metadata.city = value
            case "sublocation": configuration.metadata.sublocation = value
            case "provinceState": configuration.metadata.provinceState = value
            case "country": configuration.metadata.country = value
            case "countryCode": configuration.metadata.countryCode = ISO3166Country.normalizedAlpha3(value)
            case "event": configuration.metadata.event = value
            case "instructions": configuration.metadata.instructions = value
            case "source": configuration.metadata.source = value
            default: break
            }
        }
    }

    // MARK: - Import Execution

    func startImport() {
        if let importBlockingReason {
            errorMessage = importBlockingReason
            return
        }

        let filesToCopy = selectedSourceFiles

        // Guard against two date groups (e.g. split sub-shoots, or a manual rename)
        // resolving to the same destination folder, which would silently merge them.
        if sortByDate {
            ensureUniqueFolderNames()
        }

        let baseURL = configuration.destinationBaseURL.standardizedFileURL
        let destURL: URL
        do {
            destURL = try SafePathComponent.appending(
                configuration.destinationFolderName,
                label: "Import folder name",
                to: baseURL
            )
            if sortByDate {
                for group in dateGroups where group.isIncluded {
                    _ = try SafePathComponent.validate(group.folderName, label: "Date folder name")
                    if let shoot = group.shootFolderName,
                       !shoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try SafePathComponent.validate(shoot, label: "Shoot folder name")
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        importPhase = .copying
        copiedFiles = 0
        totalFiles = filesToCopy.count
        skippedFiles = 0
        duplicateSkippedFiles = 0
        renamedFiles = 0
        failedFiles = 0
        verifiedFiles = 0
        mismatchedFiles = 0
        backupCopiedFiles = 0
        backupFailedFiles = 0
        currentFile = ""
        importSummary = ""
        errorMessage = nil
        failureRecords = []
        // A fresh import replaces any previous (un-dismissed) completion banner.
        copyResults = []
        showCompletionBanner = false
        lastCompletionEntry = nil

        // Persist verification mode for next run.
        UserDefaults.standard.set(configuration.verificationMode.rawValue, forKey: UserDefaultsKeys.importVerificationMode)
        UserDefaults.standard.set(configuration.fileTypeFilter.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter)
        UserDefaults.standard.set(configuration.skipPreviouslyImported, forKey: UserDefaultsKeys.importSkipPreviouslyImported)

        // Capture configuration values for the background copy.
        let createSubFolders = configuration.createSubFolders
        let conflictPolicy = configuration.conflictPolicy
        let verificationMode = configuration.verificationMode
        let backupDestination = configuration.backupDestination
        let applyMetadata = configuration.applyMetadata
        let processVariables = configuration.processVariables
        let sortByDate = self.sortByDate
        let dateFolderGrouping = self.dateFolderGrouping
        let dateGroups = self.dateGroups
        // Sync import title as metadata title before capturing.
        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            configuration.metadata.title = trimmedTitle
        }
        let metadata = configuration.metadata

        // Pre-compute file→date-group folder name (and optional year prefix) for O(1) lookup.
        var fileDateFolder: [URL: String] = [:]
        var fileDateGroupingFolders: [URL: [String]] = [:]
        var fileShootFolder: [URL: String] = [:]
        var fileImportDate: [URL: String] = [:]
        if sortByDate {
            for group in dateGroups where group.isIncluded {
                for file in group.files {
                    fileDateFolder[file] = group.folderName
                    fileDateGroupingFolders[file] = folderGroupingComponents(for: group, grouping: dateFolderGrouping)
                    fileImportDate[file] = displayDate(for: group)
                    if let shoot = group.shootFolderName?.trimmingCharacters(in: .whitespaces), !shoot.isEmpty {
                        fileShootFolder[file] = shoot
                    }
                }
            }
        }

        // Pre-compute file→target folder on main actor (SupportedImageFormats is MainActor).
        // Returns: (primaryFolder, backupFolder?). Backup mirrors the primary folder structure
        // under the chosen backup root.
        var jobs: [ImportCopyService.CopyJob] = []
        var previousImportCandidates: [PreviousImportDetector.Candidate] = []
        var allDestFolders: Set<URL> = []
        var allRevealFolders: Set<URL> = []
        let flatImportDate = String(destURL.lastPathComponent.prefix(10))
        for file in filesToCopy {
            let baseFolder: URL
            if sortByDate {
                if let folderName = fileDateFolder[file] {
                    baseFolder = Self.appendingPathComponents(fileDateGroupingFolders[file] ?? [], to: baseURL)
                        .appendingPathComponent(folderName)
                } else {
                    baseFolder = destURL
                }
            } else {
                baseFolder = destURL
            }
            let shootBaseFolder = fileShootFolder[file].map { baseFolder.appendingPathComponent($0) } ?? baseFolder

            let primaryFolder: URL
            if configuration.fileTypeFilter == .both && createSubFolders {
                if SupportedImageFormats.isRaw(url: file) {
                    primaryFolder = shootBaseFolder.appendingPathComponent("RAW")
                } else if SupportedImageFormats.isJPEG(url: file) {
                    primaryFolder = shootBaseFolder.appendingPathComponent("JPEG")
                } else {
                    primaryFolder = shootBaseFolder
                }
            } else {
                primaryFolder = shootBaseFolder
            }
            allRevealFolders.insert(shootBaseFolder)
            allDestFolders.insert(primaryFolder)

            let primaryURL = primaryFolder.appendingPathComponent(file.lastPathComponent)
            guard SafePathComponent.isContained(primaryURL, in: baseURL) else {
                importPhase = .failed("An import destination escaped the selected folder.")
                errorMessage = "An import folder name resolves outside the selected destination."
                return
            }

            // Mirror the relative path (under destinationBaseURL) into the backup destination.
            var backupURL: URL?
            if let backupRoot = backupDestination?.url {
                if let relative = Self.relativePath(of: primaryURL, under: baseURL) {
                    let backupTarget = backupRoot.appendingPathComponent(relative)
                    backupURL = backupTarget
                    allDestFolders.insert(backupTarget.deletingLastPathComponent())
                }
            }

            jobs.append(ImportCopyService.CopyJob(
                source: file,
                desiredPrimaryDest: primaryURL,
                desiredBackupDest: backupURL
            ))
            previousImportCandidates.append(PreviousImportDetector.Candidate(
                source: file,
                dateFolderName: fileImportDate[file] ?? flatImportDate
            ))
        }

        let allFolders = allDestFolders
        let folderToOpen = Self.commonAncestor(of: Array(allRevealFolders)) ?? destURL
        // Immediately close the sheet and open the most useful common destination
        // so the browser can show thumbnails arriving via auto-refresh without
        // expanding every imported date or shoot folder.
        NotificationCenter.default.post(name: .importStarted, object: folderToOpen)
        let verifyBackup = backupDestination?.verifyAfterWrite ?? true
        let skipPreviouslyImported = configuration.skipPreviouslyImported
        let copyService = self.copyService

        importTask = Task.detached(priority: .userInitiated) { [readService, interpolator, importLog, weak self] in
            guard let self else { return }
            _ = readService
            let didStartAccessingDestination =
                baseURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessingDestination {
                    baseURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                var jobsToRun = jobs
                if skipPreviouslyImported {
                    await MainActor.run {
                        self.currentFile = "Checking same-date folders for duplicates…"
                    }
                    let duplicateSources = try PreviousImportDetector.duplicateSources(
                        among: previousImportCandidates,
                        destinationBaseURL: baseURL
                    )
                    if !duplicateSources.isEmpty {
                        jobsToRun = jobs.map { job in
                            var updated = job
                            if duplicateSources.contains(job.source) {
                                updated.preflightSkipReason = .previouslyImported
                            }
                            return updated
                        }
                    }
                }

                let didStartAccessingBackup = backupDestination?.url.startAccessingSecurityScopedResource() ?? false
                defer {
                    if didStartAccessingBackup {
                        backupDestination?.url.stopAccessingSecurityScopedResource()
                    }
                }

                let fm = FileManager.default
                for folder in allFolders {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }

                let results = try await copyService.run(
                    jobs: jobsToRun,
                    conflictPolicy: conflictPolicy,
                    verificationMode: verificationMode,
                    verifyBackup: verifyBackup,
                    progress: { [weak self] result in
                        await MainActor.run {
                            self?.applyProgress(result)
                        }
                    }
                )
                // Pull successful primary URLs (verified or verification disabled) for metadata pass.
                let copiedURLs = results.compactMap { $0.primaryURL }

                if copiedURLs.isEmpty {
                    await MainActor.run {
                        if self.skippedFiles > 0 {
                            self.importPhase = .complete
                            self.importSummary = self.buildImportSummary()
                            self.recordCompletion(cancelled: false)
                        } else if self.failedFiles > 0 || self.mismatchedFiles > 0 {
                            self.importPhase = .complete
                            self.importSummary = self.buildImportSummary()
                            self.recordCompletion(cancelled: false)
                        } else {
                            self.importPhase = .failed("No files were imported.")
                            self.errorMessage = "No files were imported."
                        }
                    }
                    return
                }

                // Apply metadata if configured
                if applyMetadata {
                    await MainActor.run { self.importPhase = .applyingMetadata }

                    if processVariables {
                        var sequenceNumber = 1
                        for url in copiedURLs {
                            try Task.checkCancellation()
                            let resolved = await self.resolveMetadataForFile(url, metadata: metadata, interpolator: interpolator, sequenceIndex: sequenceNumber)
                            sequenceNumber += 1
                            let fields = await Self.buildMetadataFields(from: resolved)
                            if !fields.isEmpty {
                                try await self.writeEngine.writeFields(
                                    fields,
                                    to: [url],
                                    structuredData: StructuredWriteData(
                                        editorial: EditorialStructuredWriteData(metadata: resolved)
                                    )
                                )
                            }
                        }
                    } else {
                        let fields = await Self.buildMetadataFields(from: metadata)
                        if !fields.isEmpty {
                            let batchSize = 20
                            for batchStart in stride(from: 0, to: copiedURLs.count, by: batchSize) {
                                try Task.checkCancellation()
                                let batchEnd = min(batchStart + batchSize, copiedURLs.count)
                                let batch = Array(copiedURLs[batchStart..<batchEnd])
                                try await self.writeEngine.writeFields(
                                    fields,
                                    to: batch,
                                    structuredData: StructuredWriteData(
                                        editorial: EditorialStructuredWriteData(metadata: metadata)
                                    )
                                )
                            }
                        }
                    }
                }

                await MainActor.run {
                    self.importPhase = .complete
                    self.importSummary = self.buildImportSummary()
                    importLog.info("Import complete: \(self.importSummary)")
                    self.recordCompletion(cancelled: false)
                    NotificationCenter.default.post(name: .importCompleted, object: destURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.importPhase = .cancelled
                    self.importSummary = self.buildImportSummary()
                    importLog.info("Import cancelled: \(self.importSummary)")
                    self.recordCompletion(cancelled: true)
                    NotificationCenter.default.post(name: .importCompleted, object: destURL)
                }
            } catch {
                await MainActor.run {
                    self.importPhase = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                    importLog.error("Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Cancel a running import. The actor sees the cancellation between files
    /// (and inside the chunk loop) and tears down any partial files before
    /// the result is returned.
    func cancelImport() {
        importTask?.cancel()
    }

    @MainActor
    private func applyProgress(_ result: ImportCopyService.CopyResult) {
        currentFile = result.source.lastPathComponent
        copyResults.append(result)

        switch result.primary {
        case .copied(_, let renamed, _):
            copiedFiles += 1
            if renamed { renamedFiles += 1 }
        case .skipped(let reason):
            skippedFiles += 1
            if reason == .previouslyImported { duplicateSkippedFiles += 1 }
        case .failed(let detail):
            failedFiles += 1
            failureRecords.append(ImportFailureRecord(source: result.source, kind: .copyFailed, detail: detail))
        }

        switch result.primaryVerification {
        case .verified:
            verifiedFiles += 1
        case .mismatch(let expected, let got):
            mismatchedFiles += 1
            failureRecords.append(ImportFailureRecord(
                source: result.source,
                kind: .verificationMismatch,
                detail: "expected \(expected.shortHex), got \(got.shortHex)"
            ))
        case .skipped, .failed:
            break
        }

        if let backup = result.backup {
            switch backup {
            case .copied:
                backupCopiedFiles += 1
            case .failed(let detail):
                backupFailedFiles += 1
                failureRecords.append(ImportFailureRecord(source: result.source, kind: .backupFailed, detail: detail))
            case .skipped(_):
                break
            }
        }
    }

    /// Builds an activity-history entry from the accumulated per-file results,
    /// records it to the shared history, and raises the sticky completion banner.
    @MainActor
    private func recordCompletion(cancelled: Bool) {
        let verificationEnabled = configuration.verificationMode == .on
        let files: [ActivityFileRecord] = copyResults.map { result in
            let destination: String
            let succeeded: Bool
            if let url = result.primaryURL {
                destination = url.deletingLastPathComponent().path
                succeeded = true
            } else {
                destination = ""
                succeeded = false
            }
            let verification: ActivityVerification
            switch result.primaryVerification {
            case .verified: verification = .verified
            case .mismatch, .failed: verification = .failed
            case .skipped: verification = .notApplicable
            }
            return ActivityFileRecord(
                fileName: result.source.lastPathComponent,
                destination: destination,
                succeeded: succeeded,
                verification: verification
            )
        }

        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
        let entry = ActivityEntry(
            kind: .importJob,
            date: Date(),
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            successCount: copiedFiles,
            totalCount: totalFiles,
            verificationFailures: mismatchedFiles,
            verificationEnabled: verificationEnabled,
            wasCancelled: cancelled,
            files: files
        )

        activityHistory?.record(entry)
        lastCompletionEntry = entry
        showCompletionBanner = true
    }

    /// Dismisses the sticky completion banner (the green-check confirm action).
    func dismissCompletionBanner() {
        showCompletionBanner = false
    }

    nonisolated static func relativePath(of url: URL, under root: URL) -> String? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return nil }
        for (i, c) in rootComponents.enumerated() where urlComponents[i] != c {
            return nil
        }
        return urlComponents[rootComponents.count..<urlComponents.count].joined(separator: "/")
    }

    nonisolated static func commonAncestor(of urls: [URL]) -> URL? {
        guard var commonComponents = urls.first?.standardizedFileURL.pathComponents else { return nil }
        for url in urls.dropFirst() {
            let components = url.standardizedFileURL.pathComponents
            var sharedCount = 0
            while sharedCount < commonComponents.count,
                  sharedCount < components.count,
                  commonComponents[sharedCount] == components[sharedCount] {
                sharedCount += 1
            }
            commonComponents = Array(commonComponents.prefix(sharedCount))
            if commonComponents.isEmpty { return nil }
        }
        guard !commonComponents.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: commonComponents))
    }

    private func buildImportSummary() -> String {
        var parts: [String] = []
        parts.append("Imported \(copiedFiles)")
        if renamedFiles > 0 { parts.append("renamed \(renamedFiles)") }
        let otherSkipped = skippedFiles - duplicateSkippedFiles
        if otherSkipped > 0 { parts.append("skipped \(otherSkipped)") }
        if duplicateSkippedFiles > 0 { parts.append("already imported \(duplicateSkippedFiles)") }
        if failedFiles > 0 { parts.append("failed \(failedFiles)") }
        if mismatchedFiles > 0 { parts.append("verification failures \(mismatchedFiles)") }
        if backupCopiedFiles > 0 || backupFailedFiles > 0 {
            parts.append("backup \(backupCopiedFiles) of \(backupCopiedFiles + backupFailedFiles)")
        }
        return parts.joined(separator: ", ") + "."
    }

    private func resolveMetadataForFile(_ url: URL, metadata: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int = 1) async -> IPTCMetadata {
        let filename = url.lastPathComponent
        var reference = metadata

        if let fileMetadata = try? await readService.readFullMetadata(url: url) {
            reference = fileMetadata.merged(preferring: metadata)
        }

        // Import presets usually don't carry GPS themselves; use coordinates read from the
        // source file/map-backed reference while resolving the preset's place variables.
        var variableMetadata = metadata
        variableMetadata.latitude = variableMetadata.latitude ?? reference.latitude
        variableMetadata.longitude = variableMetadata.longitude ?? reference.longitude
        let metadata = await interpolator.resolvingGPSPlaceVariables(in: variableMetadata)
        var resolved = metadata
        resolved.title = Self.resolveField(metadata.title, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.description = Self.resolveField(metadata.description, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.extendedDescription = Self.resolveField(metadata.extendedDescription, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.creators = IPTCMetadata.normalizedCreators(metadata.creators.compactMap {
            Self.resolveField($0, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        })
        resolved.creatorJobTitle = Self.resolveField(metadata.creatorJobTitle, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.descriptionWriter = Self.resolveField(metadata.descriptionWriter, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.credit = Self.resolveField(metadata.credit, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.copyright = Self.resolveField(metadata.copyright, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.rightsUsageTerms = Self.resolveField(metadata.rightsUsageTerms, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.webStatementOfRights = Self.resolveField(metadata.webStatementOfRights, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.digitalImageGUID = Self.resolveField(metadata.digitalImageGUID, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.imageSupplierImageID = Self.resolveField(metadata.imageSupplierImageID, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.imageSuppliers = EditorialImageSupplier.normalizedValues(
            metadata.imageSuppliers.map { supplier in
                EditorialImageSupplier(
                    identifier: Self.resolveField(
                        supplier.identifier,
                        filename: filename,
                        ref: reference,
                        interpolator: interpolator,
                        sequenceIndex: sequenceIndex
                    ),
                    name: Self.resolveField(
                        supplier.name,
                        filename: filename,
                        ref: reference,
                        interpolator: interpolator,
                        sequenceIndex: sequenceIndex
                    )
                )
            }
        )
        resolved.jobId = Self.resolveField(metadata.jobId, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.dateCreated = Self.resolveField(metadata.dateCreated, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.city = Self.resolveField(metadata.city, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.sublocation = Self.resolveField(metadata.sublocation, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.provinceState = Self.resolveField(metadata.provinceState, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.country = Self.resolveField(metadata.country, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.countryCode = ISO3166Country.normalizedAlpha3(metadata.countryCode)
        resolved.event = Self.resolveField(metadata.event, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.instructions = Self.resolveField(metadata.instructions, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.source = Self.resolveField(metadata.source, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.organisationsShownNames = Self.resolveListField(metadata.organisationsShownNames, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.organisationsShownCodes = Self.resolveListField(metadata.organisationsShownCodes, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.sceneCodes = IPTCSceneCode.normalizedValues(
            Self.resolveListField(metadata.sceneCodes, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        )
        resolved.subjectCodes = IPTCSubjectCode.normalizedValues(
            Self.resolveListField(metadata.subjectCodes, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        )

        return resolved
    }

    private static func resolveField(_ value: String?, filename: String, ref: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int = 1) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex)
        return resolved.isEmpty ? nil : resolved
    }

    private static func resolveListField(_ values: [String], filename: String, ref: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int) -> [String] {
        values.flatMap { value in
            interpolator.resolve(
                value,
                filename: filename,
                existingMetadata: ref,
                sequenceIndex: sequenceIndex
            )
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        }.uniqued()
    }

    static func buildMetadataFields(from meta: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]

        if let v = meta.title, !v.isEmpty { fields[.headline] = v }
        if let v = meta.description, !v.isEmpty { fields[.description] = v }
        if let v = meta.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }
        if !meta.keywords.isEmpty { fields[.subject] = meta.keywords.joined(separator: ", ") }
        if !meta.personShown.isEmpty { fields[.personInImage] = meta.personShown.joined(separator: ", ") }
        if !meta.organisationsShownNames.isEmpty { fields[.organisationInImageName] = meta.organisationsShownNames.joined(separator: ", ") }
        if !meta.organisationsShownCodes.isEmpty { fields[.organisationInImageCode] = meta.organisationsShownCodes.joined(separator: ", ") }
        if !meta.sceneCodes.isEmpty { fields[.scene] = meta.sceneCodes.joined(separator: ", ") }
        if !meta.subjectCodes.isEmpty { fields[.subjectCode] = meta.subjectCodes.joined(separator: ", ") }
        if !meta.mediaTopics.isEmpty { fields[.mediaTopic] = meta.mediaTopics.map(\.termIdentifier).joined(separator: ", ") }
        if !meta.genres.isEmpty { fields[.genre] = meta.genres.map(\.termIdentifier).joined(separator: ", ") }
        if let v = meta.digitalSourceType { fields[.digitalSourceType] = v.newsCodeURI }
        if let v = meta.creatorTransportValue { fields[.creator] = v }
        if let v = meta.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
        if let v = meta.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
        if let v = meta.credit, !v.isEmpty { fields[.credit] = v }
        if let v = meta.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = meta.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
        if let v = meta.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
        if let v = meta.digitalImageGUID, !v.isEmpty { fields[.digitalImageGUID] = v }
        if let v = meta.imageSupplierImageID, !v.isEmpty { fields[.imageSupplierImageID] = v }
        if let v = EditorialImageSupplier.canonicalJSONString(for: meta.imageSuppliers) {
            fields[.imageSupplier] = v
        }
        if let v = meta.jobId, !v.isEmpty { fields[.transmissionReference] = v }
        if let v = meta.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
        if let v = meta.city, !v.isEmpty { fields[.city] = v }
        if let v = meta.sublocation, !v.isEmpty { fields[.sublocation] = v }
        if let v = meta.provinceState, !v.isEmpty { fields[.provinceState] = v }
        if let v = meta.country, !v.isEmpty { fields[.country] = v }
        if let v = meta.countryCode, !v.isEmpty { fields[.countryCode] = v }
        if let v = meta.event, !v.isEmpty { fields[.event] = v }
        if let v = meta.instructions, !v.isEmpty { fields[.instructions] = v }
        if let v = meta.source, !v.isEmpty { fields[.source] = v }

        return fields
    }

    // MARK: - Capture Date Scanning

    func scanCaptureDates() {
        let files = filteredSourceFiles
        guard !files.isEmpty else {
            dateGroups = []
            return
        }

        dateScanTask?.cancel()
        isScanningDates = true

        // Snapshot the trimmed Import Title so the per-date leaf folder name can
        // include it (e.g. "2026-05-12 – Vacation"). Title changes after scanning
        // are not propagated to existing groups — the user can re-scan or edit.
        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)

        dateScanTask = Task.detached(priority: .userInitiated) {
            // Read DateTimeOriginal for all files via SwiftExif. SwiftExif reads
            // are in-process and fast; a serial scan is simpler and avoids
            // shipping non-Sendable captures across a task group.
            //
            // We keep the full timestamp (not just the date) so the UI can order
            // files within a day, sample evenly-spread thumbnails, and detect
            // shoot-boundary gaps. The date-only key still drives grouping.
            var fileToDateKey: [URL: String] = [:]
            var fileToTimestamp: [URL: Date] = [:]
            let fm = FileManager.default

            // EXIF DateTimeOriginal is local wall-clock with no zone. Anchor parsing
            // to UTC + POSIX locale so ordering and gap math are stable (no DST skew).
            // These times are only used relatively and for HH:mm display, never stored.
            let exifParser = DateFormatter()
            exifParser.locale = Locale(identifier: "en_US_POSIX")
            exifParser.timeZone = TimeZone(secondsFromGMT: 0)
            exifParser.dateFormat = "yyyy:MM:dd HH:mm:ss"

            let keyFromDate = DateFormatter()
            keyFromDate.locale = Locale(identifier: "en_US_POSIX")
            keyFromDate.timeZone = TimeZone(secondsFromGMT: 0)
            keyFromDate.dateFormat = "yyyy:MM:dd"

            for file in files {
                if Task.isCancelled { return }
                if let metadata = try? ImageMetadata.read(from: file),
                   let dateStr = metadata.exif?.dateTimeOriginal {
                    fileToDateKey[file] = String(dateStr.prefix(10))
                    if let parsed = exifParser.date(from: dateStr) {
                        fileToTimestamp[file] = parsed
                    }
                    continue
                }
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    fileToDateKey[file] = keyFromDate.string(from: modDate)
                    fileToTimestamp[file] = modDate
                }
            }

            // Group files by date
            var grouped: [String: [URL]] = [:]
            for file in files {
                let dateKey = fileToDateKey[file] ?? "Unknown Date"
                grouped[dateKey, default: []].append(file)
            }

            // Build groups sorted by date
            let folderDateFormatter = DateFormatter()
            folderDateFormatter.dateFormat = "yyyy-MM-dd"
            let yearFormatter = DateFormatter()
            yearFormatter.dateFormat = "yyyy"
            let monthFormatter = DateFormatter()
            monthFormatter.dateFormat = "MM"
            let parseDateFormatter = DateFormatter()
            parseDateFormatter.dateFormat = "yyyy:MM:dd"

            let groups = grouped.keys.sorted().map { dateKey -> ImportDateGroup in
                let folderDate: String
                let yearFolder: String?
                let monthFolder: String?
                if let parsed = parseDateFormatter.date(from: dateKey) {
                    folderDate = folderDateFormatter.string(from: parsed)
                    yearFolder = yearFormatter.string(from: parsed)
                    monthFolder = monthFormatter.string(from: parsed)
                } else {
                    folderDate = dateKey
                    yearFolder = nil
                    monthFolder = nil
                }
                let leaf = trimmedTitle.isEmpty
                    ? folderDate
                    : "\(folderDate) \u{2013} \(trimmedTitle)"
                let groupFiles = grouped[dateKey] ?? []
                var groupTimes: [URL: Date] = [:]
                for file in groupFiles {
                    if let t = fileToTimestamp[file] { groupTimes[file] = t }
                }
                return ImportDateGroup(
                    dateString: dateKey,
                    folderName: leaf,
                    shootFolderName: nil,
                    isIncluded: true,
                    yearFolder: yearFolder,
                    monthFolder: monthFolder,
                    files: groupFiles,
                    captureTimes: groupTimes
                )
            }

            await MainActor.run {
                self.dateGroups = groups
                self.isScanningDates = false
                self.refreshPreviousImportFolderSuggestions()
            }
        }
    }

    // MARK: - Thumbnail Sampling & Gap Detection

    /// Default minimum gap between consecutive shots that suggests a new shoot.
    static let defaultShootGapThreshold: TimeInterval = 2 * 3600

    /// Orders files by capture time, falling back to a stable filename comparison for
    /// files that share (or lack) a timestamp.
    static func chronologicalOrder(of files: [URL], captureTimes: [URL: Date]) -> [URL] {
        // With no timestamps at all, the caller's order (already filename-sorted in
        // practice) is the chronological order — skip the expensive locale-aware sort,
        // which matters for the flat whole-import preview over thousands of files.
        guard !captureTimes.isEmpty else { return files }
        return files.sorted { a, b in
            switch (captureTimes[a], captureTimes[b]) {
            case let (ta?, tb?):
                if ta != tb { return ta < tb }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }
    }

    /// Picks up to `max` files spread evenly across a chronological sequence, for a
    /// compact preview strip. Returns all files when there are `max` or fewer. Pure.
    static func representativeFiles(from files: [URL], captureTimes: [URL: Date], max n: Int = 8) -> [URL] {
        let ordered = chronologicalOrder(of: files, captureTimes: captureTimes)
        guard ordered.count > n else { return ordered }
        guard n > 1 else { return ordered.isEmpty ? [] : [ordered[0]] }
        var picked: [URL] = []
        var seen = Set<URL>()
        for i in 0..<n {
            let idx = Int((Double(i) * Double(ordered.count - 1) / Double(n - 1)).rounded())
            let url = ordered[idx]
            if seen.insert(url).inserted { picked.append(url) }
        }
        return picked
    }

    /// Convenience overload for a date group.
    static func representativeFiles(from group: ImportDateGroup, max n: Int = 8) -> [URL] {
        representativeFiles(from: group.files, captureTimes: group.captureTimes, max: n)
    }

    /// Indices into `group.chronologicalFiles` where the gap to the previous shot
    /// exceeds `gapThreshold` — i.e. suggested start-of-new-shoot boundaries.
    /// Files lacking a timestamp never trigger a boundary.
    static func suggestedSplitBoundaries(
        for group: ImportDateGroup,
        gapThreshold: TimeInterval = ImportViewModel.defaultShootGapThreshold
    ) -> [Int] {
        let ordered = group.chronologicalFiles
        guard ordered.count > 1 else { return [] }
        var boundaries: [Int] = []
        for i in 1..<ordered.count {
            guard let prev = group.captureTimes[ordered[i - 1]],
                  let cur = group.captureTimes[ordered[i]] else { continue }
            if cur.timeIntervalSince(prev) > gapThreshold {
                boundaries.append(i)
            }
        }
        return boundaries
    }

    // MARK: - Folder Name Preview & Title

    /// "yyyy-MM-dd" display form derived from a group's "yyyy:MM:dd" capture-date key.
    func displayDate(for group: ImportDateGroup) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy:MM:dd"
        let display = DateFormatter()
        display.dateFormat = "yyyy-MM-dd"
        if let parsed = parse.date(from: group.dateString) { return display.string(from: parsed) }
        return group.dateString
    }

    /// The auto-generated leaf folder name for a group given an import title.
    private func autoLeafName(for group: ImportDateGroup, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? displayDate(for: group) : "\(displayDate(for: group)) \u{2013} \(trimmed)"
    }

    /// Re-applies a changed import title to every group whose folder name still matches
    /// the auto-generated pattern, so the title stays in sync without a re-scan. This
    /// includes split sub-shoots, whose names are the auto base plus a " – Shoot N"
    /// suffix — the suffix is preserved. Groups the user renamed by hand no longer match
    /// the pattern and are left untouched.
    func updateGroupFolderTitles(from oldTitle: String, to newTitle: String) {
        guard !dateGroups.isEmpty else { return }
        for i in dateGroups.indices {
            let oldBase = autoLeafName(for: dateGroups[i], title: oldTitle)
            let newBase = autoLeafName(for: dateGroups[i], title: newTitle)
            let current = dateGroups[i].folderName
            if current == oldBase {
                dateGroups[i].folderName = newBase
            } else {
                // Split sub-shoot: "<auto base> – Shoot N". Swap the base, keep the rest.
                let shootPrefix = oldBase + " \u{2013} Shoot "
                if current.hasPrefix(shootPrefix) {
                    dateGroups[i].folderName = newBase + String(current.dropFirst(oldBase.count))
                }
            }
        }
        ensureUniqueFolderNames()
    }

    /// Full destination path preview for a group, e.g. "Photos / 2026 / 2026-05-12 – Vacation".
    func folderPathPreview(for group: ImportDateGroup) -> String {
        var parts = [configuration.destinationBaseURL.lastPathComponent]
        parts.append(contentsOf: folderGroupingComponents(for: group, grouping: dateFolderGrouping))
        parts.append(group.folderName)
        if let shoot = group.shootFolderName?.trimmingCharacters(in: .whitespaces), !shoot.isEmpty {
            parts.append(shoot)
        }
        return parts.joined(separator: " / ")
    }

    func folderPathGroupingPrefix(for group: ImportDateGroup) -> String {
        folderGroupingComponents(for: group, grouping: dateFolderGrouping).joined(separator: "/")
    }

    private func destinationFolderURL(for group: ImportDateGroup) -> URL {
        var url = Self.appendingPathComponents(
            folderGroupingComponents(for: group, grouping: dateFolderGrouping),
            to: configuration.destinationBaseURL
        )
        url = url.appendingPathComponent(group.folderName)
        if let shoot = group.shootFolderName?.trimmingCharacters(in: .whitespaces), !shoot.isEmpty {
            url = url.appendingPathComponent(shoot)
        }
        return url
    }

    private func folderGroupingComponents(for group: ImportDateGroup, grouping: ImportDateFolderGrouping) -> [String] {
        switch grouping {
        case .none:
            return []
        case .year:
            return group.yearFolder.map { [$0] } ?? []
        case .month:
            guard let year = group.yearFolder, let month = group.monthFolder else { return [] }
            return [year, month]
        }
    }

    nonisolated private static func appendingPathComponents(_ components: [String], to baseURL: URL) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    // MARK: - Shoot Splitting

    /// Splits one date group into contiguous segments at the given boundary indices
    /// (indices into the group's `chronologicalFiles`). The first segment keeps the
    /// original folder name; later segments get a " – Shoot N" suffix (user-editable
    /// afterward). No-op when there are fewer than two resulting segments.
    func splitGroup(_ groupID: UUID, boundaries: [Int]) {
        guard let gIdx = dateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = dateGroups[gIdx]
        let ordered = group.chronologicalFiles

        // Sanitize + sort boundaries; drop out-of-range and duplicates.
        let bounds = Set(boundaries.filter { $0 > 0 && $0 < ordered.count }).sorted()
        guard !bounds.isEmpty else { return }

        // Build contiguous segment ranges: [0, b0), [b0, b1), … [bn, count).
        var starts = [0]
        starts.append(contentsOf: bounds)
        var newGroups: [ImportDateGroup] = []
        for (segIndex, start) in starts.enumerated() {
            let end = segIndex + 1 < starts.count ? starts[segIndex + 1] : ordered.count
            let segFiles = Array(ordered[start..<end])
            guard !segFiles.isEmpty else { continue }
            var segTimes: [URL: Date] = [:]
            for f in segFiles { if let t = group.captureTimes[f] { segTimes[f] = t } }
            // Every segment — including the first — gets a "Shoot N" suffix so the
            // resulting folders are named consistently (Shoot 1, Shoot 2, …).
            let segmentNumber = newGroups.count + 1
            let shootName = "Shoot \(segmentNumber)"
            let name = splitShootsIntoSubfolders
                ? baseDateFolderName(for: group)
                : "\(group.folderName) \u{2013} \(shootName)"
            newGroups.append(ImportDateGroup(
                dateString: group.dateString,
                folderName: name,
                shootFolderName: splitShootsIntoSubfolders ? shootName : nil,
                isIncluded: group.isIncluded,
                yearFolder: group.yearFolder,
                monthFolder: group.monthFolder,
                files: segFiles,
                captureTimes: segTimes
            ))
        }

        guard newGroups.count > 1 else { return }
        dateGroups.replaceSubrange(gIdx...gIdx, with: newGroups)
        ensureUniqueFolderNames()
    }

    /// Moves an arbitrary (possibly non-contiguous) selection of files out of a group
    /// into a new sub-shoot inserted right after it. The source group keeps the rest.
    func splitOff(_ groupID: UUID, fileURLs: Set<URL>, newSuffix: String? = nil) {
        guard let gIdx = dateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var source = dateGroups[gIdx]
        let moved = source.files.filter { fileURLs.contains($0) }
        guard !moved.isEmpty, moved.count < source.files.count else { return }

        var movedTimes: [URL: Date] = [:]
        for f in moved { if let t = source.captureTimes[f] { movedTimes[f] = t } }

        source.files.removeAll { fileURLs.contains($0) }
        for f in moved { source.captureTimes.removeValue(forKey: f) }
        if splitShootsIntoSubfolders, source.shootFolderName == nil {
            source.folderName = baseDateFolderName(for: source)
            source.shootFolderName = "Shoot 1"
        }

        let suffix = (newSuffix?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let shootName = suffix ?? "Shoot 2"
        let baseName = splitShootsIntoSubfolders
            ? baseDateFolderName(for: source)
            : "\(source.folderName) \u{2013} \(shootName)"
        let newGroup = ImportDateGroup(
            dateString: source.dateString,
            folderName: baseName,
            shootFolderName: splitShootsIntoSubfolders ? shootName : nil,
            isIncluded: source.isIncluded,
            yearFolder: source.yearFolder,
            monthFolder: source.monthFolder,
            files: moved,
            captureTimes: movedTimes
        )

        dateGroups[gIdx] = source
        dateGroups.insert(newGroup, at: gIdx + 1)
        ensureUniqueFolderNames()
    }

    /// Merges the given groups (which should share a `dateString`) back into the
    /// chronologically-earliest one, resetting its folder name to a clean base.
    func mergeGroups(_ groupIDs: [UUID]) {
        let idSet = Set(groupIDs)
        let indices = dateGroups.indices.filter { idSet.contains(dateGroups[$0].id) }
        guard indices.count > 1 else { return }

        // Earliest by first capture time, falling back to current order.
        let targetIdx = indices.min { lhs, rhs in
            let l = dateGroups[lhs].captureTimes.values.min()
            let r = dateGroups[rhs].captureTimes.values.min()
            switch (l, r) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs < rhs
            }
        } ?? indices[0]

        var merged = dateGroups[targetIdx]
        for idx in indices where idx != targetIdx {
            let other = dateGroups[idx]
            merged.files.append(contentsOf: other.files)
            for (url, t) in other.captureTimes { merged.captureTimes[url] = t }
        }

        // Reset folder name to a clean date-derived base (drop " – Shoot N").
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy:MM:dd"
        let display = DateFormatter()
        display.dateFormat = "yyyy-MM-dd"
        if let parsed = parse.date(from: merged.dateString) {
            let title = configuration.importTitle.trimmingCharacters(in: .whitespaces)
            merged.folderName = title.isEmpty
                ? display.string(from: parsed)
                : "\(display.string(from: parsed)) \u{2013} \(title)"
        }
        merged.shootFolderName = nil

        // Remove merged-away groups (highest index first) and write back the target.
        dateGroups[targetIdx] = merged
        for idx in indices.sorted(by: >) where idx != targetIdx {
            dateGroups.remove(at: idx)
        }
        ensureUniqueFolderNames()
    }

    /// Whether other groups share this group's capture date (i.e. it has been split
    /// into multiple shoots that could be merged back).
    func hasSiblingGroups(_ group: ImportDateGroup) -> Bool {
        dateGroups.contains { $0.id != group.id && $0.dateString == group.dateString }
    }

    /// Merges all groups sharing this group's capture date back into one.
    func mergeSiblings(of group: ImportDateGroup) {
        let ids = dateGroups.filter { $0.dateString == group.dateString }.map(\.id)
        mergeGroups(ids)
    }

    /// Guarantees every group has a distinct `folderName` by auto-suffixing collisions
    /// with " (2)", " (3)", … This protects the import copy step, which maps each file
    /// to its destination by folder name. Call after any split/merge or name edit.
    func ensureUniqueFolderNames() {
        // Folder names become on-disk directories under a volume that is
        // case-insensitive by default (APFS and HFS+), so uniqueness must be
        // enforced case-insensitively. A case-sensitive check would let "Beach"
        // and "beach" both pass, then `appendingPathComponent` would resolve them
        // to the *same* physical folder — silently merging two groups' files (and
        // overwriting same-named files under the .overwrite conflict policy).
        // First occurrence keeps its original casing; later collisions get suffixed.
        var used = Set<String>()
        for i in dateGroups.indices {
            var name = dateGroups[i].folderName
            if name.isEmpty { name = dateGroups[i].dateString }
            let shoot = dateGroups[i].shootFolderName?.trimmingCharacters(in: .whitespaces)
            var candidate = name
            var counter = 2
            var uniqueKey = folderUniquenessKey(for: dateGroups[i], folderName: candidate, shootFolderName: shoot)
            while !used.insert(uniqueKey).inserted {
                candidate = "\(name) (\(counter))"
                counter += 1
                uniqueKey = folderUniquenessKey(for: dateGroups[i], folderName: candidate, shootFolderName: shoot)
            }
            if candidate != dateGroups[i].folderName {
                dateGroups[i].folderName = candidate
            }
        }
    }

    private func folderUniquenessKey(for group: ImportDateGroup, folderName: String, shootFolderName: String?) -> String {
        var parts = folderGroupingComponents(for: group, grouping: dateFolderGrouping).map { $0.lowercased() }
        parts.append(folderName.lowercased())
        if let shootFolderName, !shootFolderName.isEmpty { parts.append(shootFolderName.lowercased()) }
        return parts.joined(separator: "/")
    }

    private func baseDateFolderName(for group: ImportDateGroup) -> String {
        let base = autoLeafName(for: group, title: configuration.importTitle)
        if group.folderName == base || group.shootFolderName != nil {
            return base
        }
        if let range = group.folderName.range(of: " \u{2013} Shoot ", options: [.backwards]) {
            return String(group.folderName[..<range.lowerBound])
        }
        return group.folderName
    }

    private func normalizeSplitFolderLayout() {
        guard sortByDate, !dateGroups.isEmpty else { return }
        var normalizedGroups = dateGroups
        var dateCounters: [String: Int] = [:]
        for i in normalizedGroups.indices {
            let siblings = normalizedGroups.filter { $0.dateString == normalizedGroups[i].dateString }
            guard siblings.count > 1 || normalizedGroups[i].shootFolderName != nil else { continue }

            dateCounters[normalizedGroups[i].dateString, default: 0] += 1
            let shootName = normalizedGroups[i].shootFolderName ?? "Shoot \(dateCounters[normalizedGroups[i].dateString] ?? 1)"
            if splitShootsIntoSubfolders {
                normalizedGroups[i].folderName = baseDateFolderName(for: normalizedGroups[i])
                normalizedGroups[i].shootFolderName = shootName
            } else {
                let baseName = baseDateFolderName(for: normalizedGroups[i])
                normalizedGroups[i].folderName = "\(baseName) \u{2013} \(shootName)"
                normalizedGroups[i].shootFolderName = nil
            }
        }
        dateGroups = normalizedGroups
        ensureUniqueFolderNames()
    }

    // MARK: - Reset

    /// Prepares the view model for a freshly-opened import sheet. Resets to a clean
    /// form unless a copy is currently in progress — in that case the sheet should
    /// show the running import's progress rather than wipe it.
    func prepareForNewSession() {
        switch importPhase {
        case .copying, .applyingMetadata:
            return
        default:
            reset()
        }
    }

    func reset() {
        let preservedFileTypeFilter = configuration.fileTypeFilter
        let preservedConflictPolicy = configuration.conflictPolicy
        let preservedCreateSubFolders = configuration.createSubFolders
        let preservedVerificationMode = configuration.verificationMode
        let preservedBackup = configuration.backupDestination
        let preservedSkipPreviouslyImported = configuration.skipPreviouslyImported
        let preservedSortByDate = sortByDate
        configuration = ImportConfiguration()
        // Preserve the user's import-mode choices across "Import More".
        configuration.fileTypeFilter = preservedFileTypeFilter
        configuration.conflictPolicy = preservedConflictPolicy
        configuration.createSubFolders = preservedCreateSubFolders
        configuration.verificationMode = preservedVerificationMode
        configuration.backupDestination = preservedBackup
        configuration.skipPreviouslyImported = preservedSkipPreviouslyImported
        sourceFiles = []
        importPhase = .idle
        copiedFiles = 0
        totalFiles = 0
        skippedFiles = 0
        renamedFiles = 0
        failedFiles = 0
        verifiedFiles = 0
        mismatchedFiles = 0
        backupCopiedFiles = 0
        backupFailedFiles = 0
        duplicateSkippedFiles = 0
        currentFile = ""
        importSummary = ""
        errorMessage = nil
        failureRecords = []
        dateGroups = []
        sortByDate = preservedSortByDate
        isScanningDates = false
        dateScanTask?.cancel()
        folderSuggestionTask?.cancel()
        importTask?.cancel()
        refreshPreviousImportFolderSuggestions()
    }

    // MARK: - Backup Destination

    func selectBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder for the additional import copy"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if configuration.backupDestination == nil {
            let verifyAfterWrite = UserDefaults.standard.object(forKey: UserDefaultsKeys.importBackupVerifyAfterWrite) as? Bool ?? true
            configuration.backupDestination = BackupDestination(url: url, verifyAfterWrite: verifyAfterWrite)
        } else {
            configuration.backupDestination?.url = url
        }
        Self.saveBookmark(for: url, key: UserDefaultsKeys.importBackupBookmark)
    }

    func clearBackupDestination() {
        configuration.backupDestination = nil
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.importBackupBookmark)
    }

    private static func saveBookmark(for url: URL, key: String) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: key)
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func resolveBookmark(key: String) -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: url, key: key)
            }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
    }
}
