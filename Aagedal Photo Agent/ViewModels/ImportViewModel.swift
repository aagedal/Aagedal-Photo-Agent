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
    /// 4-digit year derived from the parsed capture date. `nil` when the date could
    /// not be parsed; such groups stay flat under the destination base even when
    /// "Group by year" is enabled, to avoid creating a bogus year folder.
    var yearFolder: String?
    var files: [URL]
    /// Full per-file capture timestamps (EXIF `DateTimeOriginal`, or file mtime as a
    /// fallback). A file may be absent here when no timestamp could be read. Used for
    /// chronological ordering, evenly-spread thumbnail sampling, and gap detection —
    /// never persisted, so it is safe to anchor parsing to UTC.
    var captureTimes: [URL: Date] = [:]

    /// Files ordered by capture time. Files without a timestamp fall back to a stable
    /// filename ordering and sort after timestamped files of equal standing.
    var chronologicalFiles: [URL] {
        files.sorted { a, b in
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
}

@Observable
final class ImportViewModel {
    var configuration = ImportConfiguration()
    var sourceFiles: [URL] = []
    var importPhase: ImportPhase = .idle
    var copiedFiles: Int = 0
    var totalFiles: Int = 0
    var skippedFiles: Int = 0
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

    /// Capture-date groups detected from source files.
    var dateGroups: [ImportDateGroup] = []
    /// Whether the user wants to sort files into per-date folders.
    var sortByDate: Bool = false
    /// When `sortByDate` is on, wrap each date folder in a `yyyy/` parent.
    var groupByYear: Bool = false {
        didSet {
            UserDefaults.standard.set(groupByYear, forKey: UserDefaultsKeys.importGroupByYear)
        }
    }
    /// Whether date scanning is in progress.
    var isScanningDates: Bool = false

    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    private let interpolator = PresetVariableInterpolator()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var dateScanTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private let copyService = ImportCopyService()
    private let importLog = Logger(subsystem: "com.aagedal.photo-agent", category: "Import")

    init(readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine) {
        self.readService = readService
        self.writeEngine = writeEngine

        // Restore last-used verification mode (default = .on).
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.importVerificationMode),
           let mode = CopyVerificationMode(rawValue: raw) {
            self.configuration.verificationMode = mode
        }

        // Restore last-used year-grouping preference (default = false).
        self.groupByYear = UserDefaults.standard.bool(forKey: UserDefaultsKeys.importGroupByYear)
    }

    deinit {
        scanTask?.cancel()
        dateScanTask?.cancel()
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

    // MARK: - Source Selection

    func selectSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to import photos from"

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
        panel.message = "Select base folder for imports"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.destinationBaseURL = url
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
            case "digitalSourceType":
                configuration.metadata.digitalSourceType = DigitalSourceType(rawValue: value)
            case "creator": configuration.metadata.creator = value
            case "credit": configuration.metadata.credit = value
            case "copyright": configuration.metadata.copyright = value
            case "dateCreated": configuration.metadata.dateCreated = value
            case "city": configuration.metadata.city = value
            case "country": configuration.metadata.country = value
            case "event": configuration.metadata.event = value
            default: break
            }
        }
    }

    // MARK: - Import Execution

    func startImport() {
        let filesToCopy = filteredSourceFiles
        guard !filesToCopy.isEmpty else {
            errorMessage = "No files to import."
            return
        }

        // Guard against two date groups (e.g. split sub-shoots, or a manual rename)
        // resolving to the same destination folder, which would silently merge them.
        if sortByDate {
            ensureUniqueFolderNames()
        }

        importPhase = .copying
        copiedFiles = 0
        totalFiles = filesToCopy.count
        skippedFiles = 0
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

        // Persist verification mode for next run.
        UserDefaults.standard.set(configuration.verificationMode.rawValue, forKey: UserDefaultsKeys.importVerificationMode)

        // Determine the primary destination folder (first date group or single folder).
        let primaryDestURL: URL
        if sortByDate, let first = dateGroups.first {
            primaryDestURL = configuration.destinationBaseURL.appendingPathComponent(first.folderName)
        } else {
            primaryDestURL = configuration.destinationFolderURL
        }

        // Immediately close the sheet and open the destination folder so the
        // browser can show thumbnails arriving via auto-refresh.
        NotificationCenter.default.post(name: .importStarted, object: primaryDestURL)

        // Capture configuration values for the background copy.
        let createSubFolders = configuration.createSubFolders
        let conflictPolicy = configuration.conflictPolicy
        let verificationMode = configuration.verificationMode
        let backupDestination = configuration.backupDestination
        let applyMetadata = configuration.applyMetadata
        let processVariables = configuration.processVariables
        let sortByDate = self.sortByDate
        let groupByYear = self.groupByYear
        let dateGroups = self.dateGroups
        let destURL = configuration.destinationFolderURL
        let baseURL = configuration.destinationBaseURL

        // Sync import title as metadata title before capturing.
        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            configuration.metadata.title = trimmedTitle
        }
        let metadata = configuration.metadata

        // Pre-compute file→date-group folder name (and optional year prefix) for O(1) lookup.
        var fileDateFolder: [URL: String] = [:]
        var fileDateYear: [URL: String] = [:]
        if sortByDate {
            for group in dateGroups {
                for file in group.files {
                    fileDateFolder[file] = group.folderName
                    if let year = group.yearFolder {
                        fileDateYear[file] = year
                    }
                }
            }
        }

        // Pre-compute file→target folder on main actor (SupportedImageFormats is MainActor).
        // Returns: (primaryFolder, backupFolder?). Backup mirrors the primary folder structure
        // under the chosen backup root.
        var jobs: [ImportCopyService.CopyJob] = []
        var allDestFolders: Set<URL> = []
        for file in filesToCopy {
            let baseFolder: URL
            if sortByDate {
                if let folderName = fileDateFolder[file] {
                    if groupByYear, let year = fileDateYear[file] {
                        baseFolder = baseURL
                            .appendingPathComponent(year)
                            .appendingPathComponent(folderName)
                    } else {
                        baseFolder = baseURL.appendingPathComponent(folderName)
                    }
                } else {
                    baseFolder = destURL
                }
            } else {
                baseFolder = destURL
            }

            let primaryFolder: URL
            if configuration.fileTypeFilter == .both && createSubFolders {
                if SupportedImageFormats.isRaw(url: file) {
                    primaryFolder = baseFolder.appendingPathComponent("RAW")
                } else if SupportedImageFormats.isJPEG(url: file) {
                    primaryFolder = baseFolder.appendingPathComponent("JPEG")
                } else {
                    primaryFolder = baseFolder
                }
            } else {
                primaryFolder = baseFolder
            }
            allDestFolders.insert(primaryFolder)

            let primaryURL = primaryFolder.appendingPathComponent(file.lastPathComponent)

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
        }

        let allFolders = allDestFolders
        let verifyBackup = backupDestination?.verifyAfterWrite ?? true
        let copyService = self.copyService

        importTask = Task.detached(priority: .userInitiated) { [readService, interpolator, importLog, weak self] in
            guard let self else { return }
            _ = readService

            do {
                let fm = FileManager.default
                for folder in allFolders {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }

                let results = try await copyService.run(
                    jobs: jobs,
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
                        } else if self.failedFiles > 0 || self.mismatchedFiles > 0 {
                            self.importPhase = .complete
                            self.importSummary = self.buildImportSummary()
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
                                try await self.writeEngine.writeFields(fields, to: [url])
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
                                try await self.writeEngine.writeFields(fields, to: batch)
                            }
                        }
                    }
                }

                await MainActor.run {
                    self.importPhase = .complete
                    self.importSummary = self.buildImportSummary()
                    importLog.info("Import complete: \(self.importSummary)")
                    NotificationCenter.default.post(name: .importCompleted, object: destURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.importPhase = .cancelled
                    self.importSummary = self.buildImportSummary()
                    importLog.info("Import cancelled: \(self.importSummary)")
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

        switch result.primary {
        case .copied(_, let renamed, _):
            copiedFiles += 1
            if renamed { renamedFiles += 1 }
        case .skipped:
            skippedFiles += 1
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
            case .skipped:
                break
            }
        }
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

    private func buildImportSummary() -> String {
        var parts: [String] = []
        parts.append("Imported \(copiedFiles)")
        if renamedFiles > 0 { parts.append("renamed \(renamedFiles)") }
        if skippedFiles > 0 { parts.append("skipped \(skippedFiles)") }
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

        var resolved = metadata
        resolved.title = Self.resolveField(metadata.title, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.description = Self.resolveField(metadata.description, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.extendedDescription = Self.resolveField(metadata.extendedDescription, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.creator = Self.resolveField(metadata.creator, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.credit = Self.resolveField(metadata.credit, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.copyright = Self.resolveField(metadata.copyright, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.jobId = Self.resolveField(metadata.jobId, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.dateCreated = Self.resolveField(metadata.dateCreated, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.city = Self.resolveField(metadata.city, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.country = Self.resolveField(metadata.country, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)
        resolved.event = Self.resolveField(metadata.event, filename: filename, ref: reference, interpolator: interpolator, sequenceIndex: sequenceIndex)

        return resolved
    }

    private static func resolveField(_ value: String?, filename: String, ref: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int = 1) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex)
        return resolved.isEmpty ? nil : resolved
    }

    static func buildMetadataFields(from meta: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]

        if let v = meta.title, !v.isEmpty { fields[.headline] = v }
        if let v = meta.description, !v.isEmpty { fields[.description] = v }
        if let v = meta.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }
        if !meta.keywords.isEmpty { fields[.subject] = meta.keywords.joined(separator: ", ") }
        if !meta.personShown.isEmpty { fields[.personInImage] = meta.personShown.joined(separator: ", ") }
        if let v = meta.digitalSourceType { fields[.digitalSourceType] = v.rawValue }
        if let v = meta.creator, !v.isEmpty { fields[.creator] = v }
        if let v = meta.credit, !v.isEmpty { fields[.credit] = v }
        if let v = meta.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = meta.jobId, !v.isEmpty { fields[.transmissionReference] = v }
        if let v = meta.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
        if let v = meta.city, !v.isEmpty { fields[.city] = v }
        if let v = meta.country, !v.isEmpty { fields[.country] = v }
        if let v = meta.event, !v.isEmpty { fields[.event] = v }

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
            let parseDateFormatter = DateFormatter()
            parseDateFormatter.dateFormat = "yyyy:MM:dd"

            let groups = grouped.keys.sorted().map { dateKey -> ImportDateGroup in
                let folderDate: String
                let yearFolder: String?
                if let parsed = parseDateFormatter.date(from: dateKey) {
                    folderDate = folderDateFormatter.string(from: parsed)
                    yearFolder = yearFormatter.string(from: parsed)
                } else {
                    folderDate = dateKey
                    yearFolder = nil
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
                    yearFolder: yearFolder,
                    files: groupFiles,
                    captureTimes: groupTimes
                )
            }

            await MainActor.run {
                self.dateGroups = groups
                self.isScanningDates = false
            }
        }
    }

    // MARK: - Thumbnail Sampling & Gap Detection

    /// Default minimum gap between consecutive shots that suggests a new shoot.
    static let defaultShootGapThreshold: TimeInterval = 2 * 3600

    /// Picks up to `max` files spread evenly across a group's shooting day
    /// (chronologically), for a compact preview strip. Returns all files when the
    /// group has `max` or fewer. Pure and synchronous.
    static func representativeFiles(from group: ImportDateGroup, max n: Int = 8) -> [URL] {
        let ordered = group.chronologicalFiles
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
            let name = newGroups.isEmpty
                ? group.folderName
                : "\(group.folderName) \u{2013} Shoot \(newGroups.count + 1)"
            newGroups.append(ImportDateGroup(
                dateString: group.dateString,
                folderName: name,
                yearFolder: group.yearFolder,
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

        let suffix = (newSuffix?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let baseName = suffix.map { "\(source.folderName) \u{2013} \($0)" }
            ?? "\(source.folderName) \u{2013} Shoot 2"
        let newGroup = ImportDateGroup(
            dateString: source.dateString,
            folderName: baseName,
            yearFolder: source.yearFolder,
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
        var used = Set<String>()
        for i in dateGroups.indices {
            var name = dateGroups[i].folderName
            if name.isEmpty { name = dateGroups[i].dateString }
            var candidate = name
            var counter = 2
            while !used.insert(candidate).inserted {
                candidate = "\(name) (\(counter))"
                counter += 1
            }
            if candidate != dateGroups[i].folderName {
                dateGroups[i].folderName = candidate
            }
        }
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
        let preservedVerificationMode = configuration.verificationMode
        let preservedBackup = configuration.backupDestination
        configuration = ImportConfiguration()
        // Preserve the user's verification + backup choices across "Import More".
        configuration.verificationMode = preservedVerificationMode
        configuration.backupDestination = preservedBackup
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
        currentFile = ""
        importSummary = ""
        errorMessage = nil
        failureRecords = []
        dateGroups = []
        sortByDate = false
        isScanningDates = false
        dateScanTask?.cancel()
        importTask?.cancel()
    }

    // MARK: - Backup Destination

    func selectBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a secondary backup folder for this import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if configuration.backupDestination == nil {
            configuration.backupDestination = BackupDestination(url: url)
        } else {
            configuration.backupDestination?.url = url
        }
    }

    func clearBackupDestination() {
        configuration.backupDestination = nil
    }
}
