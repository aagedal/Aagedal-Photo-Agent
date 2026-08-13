import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Portable Image Analysis Project. The payload is an ordinary ZIP archive.
    static let photoIntelligenceProject = UTType(
        exportedAs: "com.aagedal.photo-intelligence-project",
        conformingTo: .zip
    )
}

/// Creates and restores portable Image Analysis Projects (`.pint`).
///
/// Archives contain the images in the working folder, their XMP sidecars, and the
/// folder-local Photo Agent documents needed to continue an investigation. A manifest
/// records every payload file and its SHA-256 so import can validate the complete archive
/// before writing anything into the chosen destination.
enum ImageAnalysisProjectArchive {
    static let currentSchemaVersion = 1

    nonisolated enum FileKind: String, Codable, Sendable {
        case image
        case xmpSidecar
        case analysisMetadata
        case photoMetadata
        case developVersionMetadata
    }

    nonisolated struct Manifest: Codable, Equatable, Sendable {
        nonisolated struct File: Codable, Equatable, Sendable {
            let path: String
            let kind: FileKind
            let byteCount: Int64
            let sha256: String
        }

        let schemaVersion: Int
        let projectID: UUID
        let title: String
        let exportedAt: Date
        let exportedByAppVersion: String
        let exportedByAppBuild: String
        let files: [File]
    }

    nonisolated struct Preview: Equatable, Sendable {
        let title: String
        let exportedAt: Date
        let imageCount: Int
        let fileCount: Int
    }

    nonisolated enum ArchiveError: LocalizedError, Equatable, Sendable {
        case noImages
        case sourceOutsideWorkingFolder(String)
        case invalidSource(String)
        case archiveCommandFailed(Int32)
        case manifestMissing
        case malformedManifest(String)
        case unsupportedSchemaVersion(Int)
        case unsafePath(String)
        case missingPayloadFile(String)
        case unexpectedPayloadFile(String)
        case fileSizeMismatch(String)
        case checksumMismatch(String)
        case destinationNotEmpty

        var errorDescription: String? {
            switch self {
            case .noImages:
                "The working folder does not contain any images to export."
            case .sourceOutsideWorkingFolder(let name):
                "\(name) is outside the working folder and cannot be included."
            case .invalidSource(let name):
                "\(name) is not a regular project file."
            case .archiveCommandFailed(let status):
                "The project archive operation failed with status \(status)."
            case .manifestMissing:
                "This archive does not contain a Photo Intelligence manifest."
            case .malformedManifest(let reason):
                "The project manifest could not be read: \(reason)"
            case .unsupportedSchemaVersion(let version):
                "This project uses archive schema \(version), which is newer than this version of Photo Agent supports."
            case .unsafePath(let path):
                "The project contains an unsafe path: \(path)"
            case .missingPayloadFile(let path):
                "The project is incomplete because \(path) is missing."
            case .unexpectedPayloadFile(let path):
                "The project contains an undeclared file: \(path)"
            case .fileSizeMismatch(let path):
                "The size of \(path) does not match the project manifest."
            case .checksumMismatch(let path):
                "The checksum of \(path) does not match the project manifest."
            case .destinationNotEmpty:
                "Choose a new or empty folder for the imported project."
            }
        }
    }

    private static let payloadDirectoryName = "payload"
    private static let manifestFileName = "manifest.json"
    private static let metadataDirectories: [(name: String, kind: FileKind)] = [
        (".photo_analysis", .analysisMetadata),
        (MetadataSidecarService.sidecarDirectoryName, .photoMetadata),
        (".photo_versions", .developVersionMetadata),
    ]

    @discardableResult
    static func export(
        sourceFolderURL: URL,
        imageURLs: [URL],
        title: String,
        destinationURL: URL,
        appVersion: String,
        appBuild: String
    ) async throws -> Manifest {
        let sourceRoot = sourceFolderURL.resolvingSymlinksInPath().standardizedFileURL
        let images = try normalizedImageURLs(imageURLs, inside: sourceRoot)
        guard !images.isEmpty else { throw ArchiveError.noImages }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pint-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let payloadRoot = stagingRoot.appendingPathComponent(payloadDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)

        var entries: [Manifest.File] = []
        for imageURL in images {
            try Task.checkCancellation()
            try await stageFile(
                at: imageURL,
                relativePath: imageURL.lastPathComponent,
                kind: .image,
                payloadRoot: payloadRoot,
                entries: &entries
            )

            let xmpURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")
            if FileManager.default.fileExists(atPath: xmpURL.path) {
                try await stageFile(
                    at: xmpURL,
                    relativePath: xmpURL.lastPathComponent,
                    kind: .xmpSidecar,
                    payloadRoot: payloadRoot,
                    entries: &entries
                )
            }
        }

        for metadataDirectory in metadataDirectories {
            let directoryURL = sourceRoot.appendingPathComponent(
                metadataDirectory.name,
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { continue }
            for fileURL in try regularFilesRecursively(in: directoryURL) {
                try Task.checkCancellation()
                let suffix = String(fileURL.path.dropFirst(directoryURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                try await stageFile(
                    at: fileURL,
                    relativePath: "\(metadataDirectory.name)/\(suffix)",
                    kind: metadataDirectory.kind,
                    payloadRoot: payloadRoot,
                    entries: &entries
                )
            }
        }

        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = Manifest(
            schemaVersion: currentSchemaVersion,
            projectID: UUID(),
            title: cleanedTitle.isEmpty ? sourceRoot.lastPathComponent : cleanedTitle,
            exportedAt: Date(),
            exportedByAppVersion: appVersion,
            exportedByAppBuild: appBuild,
            files: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: stagingRoot.appendingPathComponent(manifestFileName),
            options: .atomic
        )

        try createZipAtomically(from: stagingRoot, at: destinationURL)
        return manifest
    }

    static func inspect(_ archiveURL: URL) async throws -> Preview {
        let extracted = try extractArchive(archiveURL)
        defer { try? FileManager.default.removeItem(at: extracted.stagingRoot) }
        let manifest = try readManifest(in: extracted.archiveRoot)
        try await validatePayload(manifest: manifest, archiveRoot: extracted.archiveRoot)
        return Preview(
            title: manifest.title,
            exportedAt: manifest.exportedAt,
            imageCount: manifest.files.count { $0.kind == .image },
            fileCount: manifest.files.count
        )
    }

    /// Validates the complete archive before creating or modifying the destination.
    @discardableResult
    static func importProject(from archiveURL: URL, to destinationURL: URL) async throws -> Manifest {
        let extracted = try extractArchive(archiveURL)
        defer { try? FileManager.default.removeItem(at: extracted.stagingRoot) }
        let manifest = try readManifest(in: extracted.archiveRoot)
        try await validatePayload(manifest: manifest, archiveRoot: extracted.archiveRoot)

        let destination = destinationURL.standardizedFileURL
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
        if destinationExisted {
            let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            guard contents.isEmpty else { throw ArchiveError.destinationNotEmpty }
        }

        let importStaging = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).importing",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: importStaging) }
        try FileManager.default.createDirectory(at: importStaging, withIntermediateDirectories: true)
        let payloadRoot = extracted.archiveRoot
            .appendingPathComponent(payloadDirectoryName, isDirectory: true)
        for entry in manifest.files {
            try Task.checkCancellation()
            guard let source = safeURL(for: entry.path, inside: payloadRoot),
                  let target = safeURL(for: entry.path, inside: importStaging) else {
                throw ArchiveError.unsafePath(entry.path)
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: target)
        }
        try rebaseImportedAnalysisCases(
            in: importStaging,
            finalDestination: destination,
            manifest: manifest
        )
        if destinationExisted {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: importStaging, to: destination)
        return manifest
    }

    private static func rebaseImportedAnalysisCases(
        in importedRoot: URL,
        finalDestination: URL,
        manifest: Manifest
    ) throws {
        let imagesByHash = Dictionary(
            grouping: manifest.files.filter { $0.kind == .image },
            by: { $0.sha256.lowercased() }
        )
        let caseEntries = manifest.files.filter {
            $0.kind == .analysisMetadata
                && $0.path.hasPrefix(".photo_analysis/cases/")
                && $0.path.hasSuffix(".analysis.json")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for entry in caseEntries {
            guard let caseURL = safeURL(for: entry.path, inside: importedRoot) else {
                throw ArchiveError.unsafePath(entry.path)
            }
            var analysisCase: AnalysisCase
            do {
                analysisCase = try decoder.decode(
                    AnalysisCase.self,
                    from: Data(contentsOf: caseURL)
                )
            } catch {
                throw ArchiveError.malformedManifest(
                    "The analysis case \(entry.path) is invalid: \(error.localizedDescription)"
                )
            }
            let candidates = imagesByHash[analysisCase.source.sha256.lowercased()] ?? []
            let imagePath = candidates.first {
                URL(fileURLWithPath: $0.path).lastPathComponent
                    == analysisCase.source.filenameAtCreation
            }?.path ?? (candidates.count == 1 ? candidates[0].path : nil)
            guard let imagePath,
                  let importedImageURL = safeURL(for: imagePath, inside: finalDestination) else {
                throw ArchiveError.missingPayloadFile(analysisCase.source.filenameAtCreation)
            }
            analysisCase.relocateSource(to: importedImageURL)
            try analysisCase.validateForPersistence()
            try encoder.encode(analysisCase).write(to: caseURL, options: .atomic)
        }
    }

    private static func normalizedImageURLs(_ urls: [URL], inside root: URL) throws -> [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []
        for url in urls {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.deletingLastPathComponent() == root else {
                throw ArchiveError.sourceOutsideWorkingFolder(url.lastPathComponent)
            }
            guard SupportedImageFormats.isSupported(url: resolved) else { continue }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ArchiveError.invalidSource(url.lastPathComponent)
            }
            if seen.insert(resolved).inserted { result.append(resolved) }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func regularFilesRecursively(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func stageFile(
        at source: URL,
        relativePath: String,
        kind: FileKind,
        payloadRoot: URL,
        entries: inout [Manifest.File]
    ) async throws {
        if entries.contains(where: { $0.path == relativePath }) { return }
        guard let target = safeURL(for: relativePath, inside: payloadRoot) else {
            throw ArchiveError.unsafePath(relativePath)
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            throw ArchiveError.invalidSource(source.lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: target)
        let digest = try await HashStream.hashFile(at: target).lowercaseHexString
        entries.append(Manifest.File(
            path: relativePath,
            kind: kind,
            byteCount: Int64(fileSize),
            sha256: digest
        ))
    }

    private static func validatePayload(manifest: Manifest, archiveRoot: URL) async throws {
        let payloadRoot = archiveRoot.appendingPathComponent(payloadDirectoryName, isDirectory: true)
        let declaredPaths = Set(manifest.files.map(\.path))
        guard declaredPaths.count == manifest.files.count else {
            throw ArchiveError.malformedManifest("It contains duplicate file paths.")
        }

        for entry in manifest.files {
            try Task.checkCancellation()
            guard entry.byteCount >= 0,
                  entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }),
                  let fileURL = safeURL(for: entry.path, inside: payloadRoot) else {
                throw ArchiveError.unsafePath(entry.path)
            }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
            } catch {
                throw ArchiveError.missingPayloadFile(entry.path)
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ArchiveError.missingPayloadFile(entry.path)
            }
            guard values.fileSize.map(Int64.init) == entry.byteCount else {
                throw ArchiveError.fileSizeMismatch(entry.path)
            }
            let digest = try await HashStream.hashFile(at: fileURL).lowercaseHexString
            guard digest == entry.sha256.lowercased() else {
                throw ArchiveError.checksumMismatch(entry.path)
            }
        }

        for fileURL in try regularFilesRecursively(in: payloadRoot) {
            let suffix = String(fileURL.path.dropFirst(payloadRoot.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard declaredPaths.contains(suffix) else {
                throw ArchiveError.unexpectedPayloadFile(suffix)
            }
        }
    }

    private static func safeURL(for relativePath: String, inside root: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              relativePath.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else {
            return nil
        }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedPath = candidate.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolvedPath.hasPrefix(prefix) else { return nil }
        return candidate
    }

    private static func readManifest(in archiveRoot: URL) throws -> Manifest {
        let manifestURL = archiveRoot.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.manifestMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion <= currentSchemaVersion else {
                throw ArchiveError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.malformedManifest(error.localizedDescription)
        }
    }

    private static func createZipAtomically(from source: URL, at destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try runDitto(["-c", "-k", "--keepParent", source.path, temporary.path])
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func extractArchive(_ source: URL) throws -> (stagingRoot: URL, archiveRoot: URL) {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pint-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try runDitto(["-x", "-k", source.path, stagingRoot.path])
            let archiveRoot = try resolveArchiveRoot(in: stagingRoot)
            return (stagingRoot, archiveRoot)
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    private static func resolveArchiveRoot(in stagingRoot: URL) throws -> URL {
        if FileManager.default.fileExists(
            atPath: stagingRoot.appendingPathComponent(manifestFileName).path
        ) {
            return stagingRoot
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        if children.count == 1,
           let child = children.first,
           (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           FileManager.default.fileExists(
               atPath: child.appendingPathComponent(manifestFileName).path
           ) {
            return child
        }
        throw ArchiveError.manifestMissing
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiveError.archiveCommandFailed(process.terminationStatus)
        }
    }
}
