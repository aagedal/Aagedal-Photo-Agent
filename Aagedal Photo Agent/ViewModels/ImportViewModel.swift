import AppKit
import Foundation
import os

enum ImportPhase: Equatable {
    case idle
    case scanning
    case copying
    case applyingMetadata
    case complete
    case failed(String)
}

/// Per-date group for sorting source files into separate destination folders.
struct ImportDateGroup: Identifiable {
    let id = UUID()
    let dateString: String
    var folderName: String
    var files: [URL]
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
    var importSummary: String = ""
    var errorMessage: String?

    /// Capture-date groups detected from source files.
    var dateGroups: [ImportDateGroup] = []
    /// Whether the user wants to sort files into per-date folders.
    var sortByDate: Bool = false
    /// Whether date scanning is in progress.
    var isScanningDates: Bool = false

    private let exifToolService: ExifToolService
    private let writeEngine: any MetadataWriteEngine
    private let interpolator = PresetVariableInterpolator()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var dateScanTask: Task<Void, Never>?
    private let importLog = Logger(subsystem: "com.aagedal.photo-agent", category: "Import")

    init(exifToolService: ExifToolService, writeEngine: any MetadataWriteEngine) {
        self.exifToolService = exifToolService
        self.writeEngine = writeEngine
    }

    deinit {
        scanTask?.cancel()
        dateScanTask?.cancel()
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
        importPhase = .scanning
        sourceFiles = []

        scanTask = Task.detached(priority: .userInitiated) {
            let allURLs = Self.enumerateFiles(at: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.sourceFiles = allURLs
                    .filter { SupportedImageFormats.isSupported(url: $0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                self.importPhase = .idle
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

        importPhase = .copying
        copiedFiles = 0
        totalFiles = filesToCopy.count
        skippedFiles = 0
        renamedFiles = 0
        failedFiles = 0
        importSummary = ""
        errorMessage = nil

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
        let applyMetadata = configuration.applyMetadata
        let processVariables = configuration.processVariables
        let sortByDate = self.sortByDate
        let dateGroups = self.dateGroups
        let destURL = configuration.destinationFolderURL
        let baseURL = configuration.destinationBaseURL

        // Sync import title as metadata title before capturing.
        let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            configuration.metadata.title = trimmedTitle
        }
        let metadata = configuration.metadata

        // Pre-compute file→date-group folder name for O(1) lookup (avoids O(N×M) linear scan).
        var fileDateFolder: [URL: String] = [:]
        if sortByDate {
            for group in dateGroups {
                for file in group.files {
                    fileDateFolder[file] = group.folderName
                }
            }
        }

        // Pre-compute file→target folder on main actor (SupportedImageFormats is MainActor).
        var fileTargetFolder: [URL: URL] = [:]
        for file in filesToCopy {
            let baseFolder: URL
            if sortByDate {
                if let folderName = fileDateFolder[file] {
                    baseFolder = baseURL.appendingPathComponent(folderName)
                } else {
                    baseFolder = destURL
                }
            } else {
                baseFolder = destURL
            }

            if configuration.fileTypeFilter == .both && createSubFolders {
                if SupportedImageFormats.isRaw(url: file) {
                    fileTargetFolder[file] = baseFolder.appendingPathComponent("RAW")
                } else if SupportedImageFormats.isJPEG(url: file) {
                    fileTargetFolder[file] = baseFolder.appendingPathComponent("JPEG")
                } else {
                    fileTargetFolder[file] = baseFolder
                }
            } else {
                fileTargetFolder[file] = baseFolder
            }
        }

        // Collect all unique destination folders to create.
        let allDestFolders = Set(fileTargetFolder.values)

        Task.detached(priority: .userInitiated) { [exifToolService, interpolator, importLog] in
            do {
                let fm = FileManager.default

                // 1. Create all destination folders
                for folder in allDestFolders {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }

                // 2. Copy files
                var copiedURLs: [URL] = []
                for file in filesToCopy {
                    let targetFolder = fileTargetFolder[file] ?? destURL
                    let desiredTargetURL = targetFolder.appendingPathComponent(file.lastPathComponent)

                    do {
                        let resolution = try Self.resolveDestinationURL(
                            desiredURL: desiredTargetURL,
                            policy: conflictPolicy,
                            fileManager: fm
                        )

                        switch resolution {
                        case .skipped:
                            await MainActor.run { self.skippedFiles += 1 }
                            continue
                        case .resolved(let targetURL, let wasRenamed):
                            try fm.copyItem(at: file, to: targetURL)
                            copiedURLs.append(targetURL)
                            await MainActor.run {
                                self.copiedFiles += 1
                                if wasRenamed { self.renamedFiles += 1 }
                            }
                        }
                    } catch {
                        importLog.error("Failed to copy \(file.lastPathComponent): \(error.localizedDescription)")
                        await MainActor.run { self.failedFiles += 1 }
                        continue
                    }
                }

                if copiedURLs.isEmpty {
                    await MainActor.run {
                        if self.skippedFiles > 0 {
                            self.importPhase = .complete
                            self.importSummary = self.buildImportSummary()
                        } else {
                            self.importPhase = .failed("No files were imported.")
                            self.errorMessage = "No files were imported."
                        }
                    }
                    return
                }

                // 3. Apply metadata if configured
                if applyMetadata {
                    await MainActor.run { self.importPhase = .applyingMetadata }

                    try await exifToolService.start()

                    if processVariables {
                        var sequenceNumber = 1
                        for url in copiedURLs {
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
                                let batchEnd = min(batchStart + batchSize, copiedURLs.count)
                                let batch = Array(copiedURLs[batchStart..<batchEnd])
                                try await self.writeEngine.writeFields(fields, to: batch)
                            }
                        }
                    }
                }

                // 4. Complete
                await MainActor.run {
                    self.importPhase = .complete
                    self.importSummary = self.buildImportSummary()
                    importLog.info("Import complete: \(self.importSummary)")
                }

                await MainActor.run {
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

    private enum DestinationResolution {
        case skipped
        case resolved(URL, wasRenamed: Bool)
    }

    nonisolated private static func resolveDestinationURL(
        desiredURL: URL,
        policy: ImportConflictPolicy,
        fileManager: FileManager
    ) throws -> DestinationResolution {
        guard fileManager.fileExists(atPath: desiredURL.path) else {
            return .resolved(desiredURL, wasRenamed: false)
        }

        switch policy {
        case .skipExisting:
            return .skipped
        case .overwrite:
            try fileManager.removeItem(at: desiredURL)
            return .resolved(desiredURL, wasRenamed: false)
        case .renameWithSuffix:
            let directory = desiredURL.deletingLastPathComponent()
            let basename = desiredURL.deletingPathExtension().lastPathComponent
            let ext = desiredURL.pathExtension
            let maxAttempts = 10_000

            for index in 1...maxAttempts {
                let candidateName = ext.isEmpty
                    ? "\(basename)-\(index)"
                    : "\(basename)-\(index).\(ext)"
                let candidate = directory.appendingPathComponent(candidateName)
                if !fileManager.fileExists(atPath: candidate.path) {
                    return .resolved(candidate, wasRenamed: true)
                }
            }
            throw NSError(
                domain: "ImportViewModel", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve filename conflict for \(desiredURL.lastPathComponent) after \(maxAttempts) attempts"]
            )
        }
    }

    private func buildImportSummary() -> String {
        "Imported \(copiedFiles), renamed \(renamedFiles), skipped \(skippedFiles), failed \(failedFiles)."
    }

    private func resolveMetadataForFile(_ url: URL, metadata: IPTCMetadata, interpolator: PresetVariableInterpolator, sequenceIndex: Int = 1) async -> IPTCMetadata {
        let filename = url.lastPathComponent
        var reference = metadata

        if let fileMetadata = try? await exifToolService.readFullMetadata(url: url) {
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

        dateScanTask = Task.detached(priority: .userInitiated) { [exifToolService] in
            // Read DateTimeOriginal for all files in one batch call
            var fileToDate: [URL: String] = [:]
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy:MM:dd"

            do {
                try await exifToolService.start()

                // Batch read using ExifTool JSON mode — process in chunks to avoid
                // exceeding command-line length limits on large cards.
                let chunkSize = 200
                for chunkStart in stride(from: 0, to: files.count, by: chunkSize) {
                    guard !Task.isCancelled else { return }
                    let chunkEnd = min(chunkStart + chunkSize, files.count)
                    let chunk = Array(files[chunkStart..<chunkEnd])
                    let args = ["-json", "-n", "-EXIF:DateTimeOriginal"] + chunk.map(\.path)
                    let output = try await exifToolService.execute(args)

                    // Parse JSON ourselves since parseJSON is private
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let data = trimmed.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        continue
                    }

                    for dict in json {
                        guard let sourceFile = dict["SourceFile"] as? String else { continue }
                        let url = URL(fileURLWithPath: sourceFile)
                        if let dateStr = dict["DateTimeOriginal"] as? String {
                            let dateOnly = String(dateStr.prefix(10))
                            fileToDate[url] = dateOnly
                        }
                    }
                }
            } catch {
                // Fall back to file modification dates
                let fm = FileManager.default
                for file in files {
                    if let attrs = try? fm.attributesOfItem(atPath: file.path),
                       let modDate = attrs[.modificationDate] as? Date {
                        fileToDate[file] = dateFormatter.string(from: modDate)
                    }
                }
            }

            // Group files by date
            var grouped: [String: [URL]] = [:]
            for file in files {
                let dateKey = fileToDate[file] ?? "Unknown Date"
                grouped[dateKey, default: []].append(file)
            }

            // Build groups sorted by date
            let folderDateFormatter = DateFormatter()
            folderDateFormatter.dateFormat = "yyyy-MM-dd"
            let parseDateFormatter = DateFormatter()
            parseDateFormatter.dateFormat = "yyyy:MM:dd"

            let groups = grouped.keys.sorted().map { dateKey -> ImportDateGroup in
                let folderDate: String
                if let parsed = parseDateFormatter.date(from: dateKey) {
                    folderDate = folderDateFormatter.string(from: parsed)
                } else {
                    folderDate = dateKey
                }
                return ImportDateGroup(
                    dateString: dateKey,
                    folderName: folderDate,
                    files: grouped[dateKey] ?? []
                )
            }

            await MainActor.run {
                self.dateGroups = groups
                self.isScanningDates = false
            }
        }
    }

    // MARK: - Reset

    func reset() {
        configuration = ImportConfiguration()
        sourceFiles = []
        importPhase = .idle
        copiedFiles = 0
        totalFiles = 0
        skippedFiles = 0
        renamedFiles = 0
        failedFiles = 0
        importSummary = ""
        errorMessage = nil
        dateGroups = []
        sortByDate = false
        isScanningDates = false
        dateScanTask?.cancel()
    }
}
