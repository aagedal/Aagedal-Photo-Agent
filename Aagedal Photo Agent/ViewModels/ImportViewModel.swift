import AppKit
import Foundation

enum ImportPhase: Equatable {
    case idle
    case scanning
    case copying
    case applyingMetadata
    case complete
    case failed(String)
}

@Observable
final class ImportViewModel {
    var configuration = ImportConfiguration()
    var sourceFiles: [URL] = []
    var importPhase: ImportPhase = .idle
    var copiedFiles: Int = 0
    var totalFiles: Int = 0
    var errorMessage: String?

    private let exifToolService: ExifToolService
    private let interpolator = PresetVariableInterpolator()

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
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
        importPhase = .scanning
        sourceFiles = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            importPhase = .idle
            return
        }

        var found: [URL] = []
        for case let fileURL as URL in enumerator {
            if SupportedImageFormats.isSupported(url: fileURL) {
                found.append(fileURL)
            }
        }

        sourceFiles = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        importPhase = .idle
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
        errorMessage = nil

        Task {
            do {
                // 1. Create destination folders
                let destURL = configuration.destinationFolderURL
                let fm = FileManager.default

                if configuration.fileTypeFilter == .both && configuration.createSubFolders {
                    try fm.createDirectory(at: destURL.appendingPathComponent("RAW"), withIntermediateDirectories: true)
                    try fm.createDirectory(at: destURL.appendingPathComponent("JPEG"), withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                }

                // 2. Copy files
                var copiedURLs: [URL] = []
                for file in filesToCopy {
                    let targetFolder: URL
                    if configuration.fileTypeFilter == .both && configuration.createSubFolders {
                        if SupportedImageFormats.isRaw(url: file) {
                            targetFolder = destURL.appendingPathComponent("RAW")
                        } else if SupportedImageFormats.isJPEG(url: file) {
                            targetFolder = destURL.appendingPathComponent("JPEG")
                        } else {
                            targetFolder = destURL
                        }
                    } else {
                        targetFolder = destURL
                    }

                    let targetURL = targetFolder.appendingPathComponent(file.lastPathComponent)
                    try fm.copyItem(at: file, to: targetURL)
                    copiedURLs.append(targetURL)

                    copiedFiles += 1
                }

                // 3. Apply metadata if configured
                if configuration.applyMetadata {
                    importPhase = .applyingMetadata

                    // Sync import title as metadata title
                    let trimmedTitle = configuration.importTitle.trimmingCharacters(in: .whitespaces)
                    if !trimmedTitle.isEmpty {
                        configuration.metadata.title = trimmedTitle
                    }

                    try exifToolService.start()

                    if configuration.processVariables {
                        // Per-file resolution: variables like {filename} differ per file
                        for url in copiedURLs {
                            let resolved = resolveMetadataForFile(url)
                            let fields = buildMetadataFields(from: resolved)
                            if !fields.isEmpty {
                                try await exifToolService.writeFields(fields, to: [url])
                            }
                        }
                    } else {
                        let fields = buildMetadataFields(from: configuration.metadata)
                        if !fields.isEmpty {
                            let batchSize = 20
                            for batchStart in stride(from: 0, to: copiedURLs.count, by: batchSize) {
                                let batchEnd = min(batchStart + batchSize, copiedURLs.count)
                                let batch = Array(copiedURLs[batchStart..<batchEnd])
                                try await exifToolService.writeFields(fields, to: batch)
                            }
                        }
                    }
                }

                // 4. Complete
                importPhase = .complete

                // Post notification with folder URL
                NotificationCenter.default.post(name: .importCompleted, object: destURL)

            } catch {
                importPhase = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolveMetadataForFile(_ url: URL) -> IPTCMetadata {
        let filename = url.lastPathComponent
        let meta = configuration.metadata
        var resolved = meta

        resolved.title = resolveField(meta.title, filename: filename, ref: meta)
        resolved.description = resolveField(meta.description, filename: filename, ref: meta)
        resolved.creator = resolveField(meta.creator, filename: filename, ref: meta)
        resolved.credit = resolveField(meta.credit, filename: filename, ref: meta)
        resolved.copyright = resolveField(meta.copyright, filename: filename, ref: meta)
        resolved.dateCreated = resolveField(meta.dateCreated, filename: filename, ref: meta)
        resolved.city = resolveField(meta.city, filename: filename, ref: meta)
        resolved.country = resolveField(meta.country, filename: filename, ref: meta)
        resolved.event = resolveField(meta.event, filename: filename, ref: meta)

        return resolved
    }

    private func resolveField(_ value: String?, filename: String, ref: IPTCMetadata) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref)
        return resolved.isEmpty ? nil : resolved
    }

    private func buildMetadataFields(from meta: IPTCMetadata) -> [String: String] {
        var fields: [String: String] = [:]

        if let v = meta.title, !v.isEmpty { fields["XMP-photoshop:Headline"] = v }
        if let v = meta.description, !v.isEmpty { fields["XMP:Description"] = v }
        if !meta.keywords.isEmpty { fields["XMP:Subject"] = meta.keywords.joined(separator: ", ") }
        if !meta.personShown.isEmpty { fields["XMP-iptcExt:PersonInImage"] = meta.personShown.joined(separator: ", ") }
        if let v = meta.digitalSourceType { fields["XMP-iptcExt:DigitalSourceType"] = v.rawValue }
        if let v = meta.creator, !v.isEmpty { fields["XMP:Creator"] = v }
        if let v = meta.credit, !v.isEmpty { fields["XMP-photoshop:Credit"] = v }
        if let v = meta.copyright, !v.isEmpty { fields["XMP:Rights"] = v }
        if let v = meta.dateCreated, !v.isEmpty { fields["XMP:DateCreated"] = v }
        if let v = meta.city, !v.isEmpty { fields["XMP-photoshop:City"] = v }
        if let v = meta.country, !v.isEmpty { fields["XMP-photoshop:Country"] = v }
        if let v = meta.event, !v.isEmpty { fields["XMP-iptcExt:Event"] = v }

        return fields
    }

    // MARK: - Reset

    func reset() {
        configuration = ImportConfiguration()
        sourceFiles = []
        importPhase = .idle
        copiedFiles = 0
        totalFiles = 0
        errorMessage = nil
    }
}
