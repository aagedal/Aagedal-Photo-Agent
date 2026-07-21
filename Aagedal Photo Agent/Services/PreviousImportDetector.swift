import Foundation
import os

private nonisolated let previousImportLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "PreviousImportDetector"
)

/// Finds source files that already exist in an import folder for the same date.
///
/// Detection deliberately requires three increasingly expensive matches:
/// 1. an existing destination folder begins with the same `yyyy-MM-dd` date,
/// 2. a regular file below that folder has the same filename and size, and
/// 3. sampled SHA-256 checksums match.
///
/// Date folders are checked in every layout the importer can create: directly
/// below the destination base, below `<year>`, and below `<year>/<month>`. Files
/// below a matching folder are searched recursively to cover RAW/JPEG and split-
/// shoot subfolders.
nonisolated struct PreviousImportDetector {
    struct Candidate: Sendable {
        let source: URL
        let dateFolderName: String
    }

    static func duplicateSources(
        among candidates: [Candidate],
        destinationBaseURL: URL
    ) throws -> Set<URL> {
        let validCandidates = candidates.filter { isDateFolderName($0.dateFolderName) }
        guard !validCandidates.isEmpty else { return [] }

        var duplicates: Set<URL> = []
        var quickHashes: [URL: Data] = [:]

        for (dateFolderName, dateCandidates) in Dictionary(grouping: validCandidates, by: \Candidate.dateFolderName) {
            try Task.checkCancellation()

            let wantedNames = Set(dateCandidates.map { normalizedFilename($0.source.lastPathComponent) })
            let dateFolders = matchingDateFolders(
                named: dateFolderName,
                under: destinationBaseURL
            )
            let existingByName = matchingFiles(
                below: dateFolders,
                wantedNames: wantedNames
            )

            for candidate in dateCandidates {
                try Task.checkCancellation()

                let filenameKey = normalizedFilename(candidate.source.lastPathComponent)
                guard let existingFiles = existingByName[filenameKey],
                      let sourceSize = fileSize(at: candidate.source) else {
                    continue
                }

                for existing in existingFiles where fileSize(at: existing) == sourceSize {
                    let sourceHash: Data
                    if let cached = quickHashes[candidate.source] {
                        sourceHash = cached
                    } else {
                        guard let hash = try? HashStream.quickHashFile(at: candidate.source) else {
                            break
                        }
                        quickHashes[candidate.source] = hash
                        sourceHash = hash
                    }

                    let existingHash: Data
                    if let cached = quickHashes[existing] {
                        existingHash = cached
                    } else {
                        guard let hash = try? HashStream.quickHashFile(at: existing) else {
                            continue
                        }
                        quickHashes[existing] = hash
                        existingHash = hash
                    }

                    if sourceHash == existingHash {
                        duplicates.insert(candidate.source)
                        break
                    }
                }
            }
        }

        if !duplicates.isEmpty {
            previousImportLog.info("Found \(duplicates.count) duplicate files in matching date folders.")
        }
        return duplicates
    }

    static func folderName(_ folderName: String, matchesDate dateFolderName: String) -> Bool {
        guard isDateFolderName(dateFolderName), folderName.hasPrefix(dateFolderName) else {
            return false
        }
        guard folderName.count > dateFolderName.count else { return true }

        let suffix = folderName.dropFirst(dateFolderName.count)
        return suffix.first.map { !$0.isNumber } ?? true
    }

    /// Existing date folders in any layout supported by the importer. Used both
    /// for duplicate detection and for destination suggestions in the import UI.
    static func matchingDateFolders(named dateFolderName: String, under baseURL: URL) -> [URL] {
        guard isDateFolderName(dateFolderName) else { return [] }

        let year = String(dateFolderName.prefix(4))
        let monthStart = dateFolderName.index(dateFolderName.startIndex, offsetBy: 5)
        let monthEnd = dateFolderName.index(monthStart, offsetBy: 2)
        let month = String(dateFolderName[monthStart..<monthEnd])

        let yearURL = baseURL.appendingPathComponent(year, isDirectory: true)
        let monthURL = yearURL.appendingPathComponent(month, isDirectory: true)
        let parents = [baseURL, yearURL, monthURL]

        var found: [URL] = []
        var seen: Set<URL> = []
        if folderName(baseURL.lastPathComponent, matchesDate: dateFolderName),
           isDirectory(at: baseURL),
           seen.insert(baseURL.standardizedFileURL).inserted {
            found.append(baseURL)
        }

        for parent in parents where isDirectory(at: parent) {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children where folderName(child.lastPathComponent, matchesDate: dateFolderName) {
                guard isDirectory(at: child), !isSymbolicLink(at: child) else { continue }
                let standardized = child.standardizedFileURL
                if seen.insert(standardized).inserted {
                    found.append(child)
                }
            }
        }
        return found.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// Extracts the title from the importer's standard `<date> – <title>` name.
    /// Non-standard same-date folder names remain visible to duplicate detection,
    /// but are not offered as one-click title suggestions because they would not
    /// round-trip to the exact same destination folder.
    static func importTitle(from folderName: String, matchingDate dateFolderName: String) -> String? {
        let prefix = dateFolderName + " – "
        guard folderName.hasPrefix(prefix) else { return nil }
        let title = String(folderName.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func matchingFiles(below folders: [URL], wantedNames: Set<String>) -> [String: [URL]] {
        let fm = FileManager.default
        var matches: [String: [URL]] = [:]

        for folder in folders {
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                if Task.isCancelled { return matches }

                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true {
                    if values?.isSymbolicLink == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }

                let key = normalizedFilename(item.lastPathComponent)
                if wantedNames.contains(key) {
                    matches[key, default: []].append(item)
                }
            }
        }
        return matches
    }

    private static func isDateFolderName(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        for (index, character) in value.enumerated() {
            if index == 4 || index == 7 {
                guard character == "-" else { return false }
            } else if !character.isNumber {
                return false
            }
        }
        return true
    }

    private static func normalizedFilename(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func fileSize(at url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private static func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
