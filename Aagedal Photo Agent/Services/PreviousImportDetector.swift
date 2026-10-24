import Foundation
import os

private nonisolated let previousImportLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "PreviousImportDetector"
)

/// Finds source files that were already imported into a destination library.
///
/// 1. **Import ledger** (`ImportLedger`): the source identity recorded when the file was
///    copied — original filename, size, sampled checksum (and capture date when both sides
///    know it). It matches regardless of the import date, a `-1` rename, or metadata embedded
///    into the copy afterwards. A ledger match counts only while its recorded destination still
///    exists, so a photo that is no longer in the library is never withheld.
/// 2. **Destination scan** for imports made before the ledger existed. It deliberately requires
///    three increasingly expensive matches:
///    1. an existing destination folder begins with the same `yyyy-MM-dd` date,
///    2. a regular file below that folder has the same filename (or that filename with a
///       `-<n>` conflict suffix) and size, and
///    3. sampled SHA-256 checksums match.
///
///    Date folders are checked in every layout the importer can create: directly below the
///    destination base, below `<year>`, and below `<year>/<month>`. Files below a matching
///    folder are searched recursively to cover RAW/JPEG and split-shoot subfolders.
/// 3. **RAW partner**: a JPEG (or other non-RAW) whose same-stem RAW from the same card folder
///    matched counts as imported when its partner file exists beside that RAW's copy — the
///    JPEG's own bytes may have changed when metadata was embedded into it.
nonisolated struct PreviousImportDetector {
    struct Candidate: Sendable {
        let source: URL
        let dateFolderName: String
        var captureDate: Date? = nil
    }

    static func duplicateSources(
        among candidates: [Candidate],
        destinationBaseURL: URL
    ) throws -> Set<URL> {
        guard !candidates.isEmpty else { return [] }

        var duplicates: Set<URL> = []
        var matchedDestinations: [URL: URL] = [:]
        var quickHashes: [URL: Data] = [:]

        func sourceHash(_ url: URL) -> Data? {
            if let cached = quickHashes[url] { return cached }
            guard let hash = try? HashStream.quickHashFile(at: url) else { return nil }
            quickHashes[url] = hash
            return hash
        }

        // 1. Ledger.
        let ledger = ImportLedger.load(root: destinationBaseURL)
        if !ledger.isEmpty {
            let entriesByKey = Dictionary(grouping: ledger) {
                ImportLedger.lookupKey(name: $0.name, size: $0.size)
            }
            for candidate in candidates {
                try Task.checkCancellation()
                guard let size = fileSize(at: candidate.source),
                      let entries = entriesByKey[ImportLedger.lookupKey(
                        name: candidate.source.lastPathComponent,
                        size: Int64(size)
                      )],
                      let hash = sourceHash(candidate.source) else { continue }
                let hex = hash.map { String(format: "%02x", $0) }.joined()
                let captureDate = ImportLedger.captureDateString(candidate.captureDate)
                for entry in entries where entry.quickHash == hex {
                    if let captureDate, let recorded = entry.captureDate, recorded != captureDate {
                        continue
                    }
                    let destination = destinationBaseURL.appendingPathComponent(entry.destination)
                    guard FileManager.default.fileExists(atPath: destination.path) else { continue }
                    duplicates.insert(candidate.source)
                    matchedDestinations[candidate.source] = destination
                    break
                }
            }
        }

        // 2. Destination scan for imports recorded before the ledger existed.
        let validCandidates = candidates.filter {
            isDateFolderName($0.dateFolderName) && !duplicates.contains($0.source)
        }
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
                    guard let sourceHash = sourceHash(candidate.source) else { break }

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
                        matchedDestinations[candidate.source] = existing
                        break
                    }
                }
            }
        }

        // 3. Partners of matched RAW files.
        let rawMatchesByExposure = Dictionary(
            matchedDestinations.filter { SupportedImageFormats.isRaw(url: $0.key) }
                .map { (exposureKey($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        if !rawMatchesByExposure.isEmpty {
            for candidate in candidates where !duplicates.contains(candidate.source)
                && !SupportedImageFormats.isRaw(url: candidate.source) {
                guard let rawCopy = rawMatchesByExposure[exposureKey(candidate.source)] else { continue }
                if partnerExists(for: candidate.source, besideRawCopy: rawCopy) {
                    duplicates.insert(candidate.source)
                }
            }
        }

        if !duplicates.isEmpty {
            previousImportLog.info("Found \(duplicates.count) previously imported files.")
        }
        return duplicates
    }

    /// Card folder + stem: the files of one exposure on the source.
    private static func exposureKey(_ source: URL) -> String {
        source.deletingLastPathComponent().standardizedFileURL.path.lowercased()
            + "|" + normalizedFilename(source.deletingPathExtension().lastPathComponent)
    }

    /// The partner sits beside the RAW's copy under the copy's stem — in the same folder, or in
    /// the sibling `JPEG` folder of the importer's RAW/JPEG layout.
    private static func partnerExists(for partner: URL, besideRawCopy rawCopy: URL) -> Bool {
        let stem = rawCopy.deletingPathExtension().lastPathComponent
        let ext = partner.pathExtension
        let name = ext.isEmpty ? stem : "\(stem).\(ext)"
        let rawFolder = rawCopy.deletingLastPathComponent()
        var folders = [rawFolder]
        if rawFolder.lastPathComponent.caseInsensitiveCompare("RAW") == .orderedSame {
            folders.append(rawFolder.deletingLastPathComponent().appendingPathComponent("JPEG"))
        }
        return folders.contains { folder in
            let candidate = folder.appendingPathComponent(name)
            return (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
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
                // A copy the importer renamed for a name conflict (`IMG_0001-1.JPG`) still
                // carries the card's bytes; let it match the card's `IMG_0001.JPG`.
                if let unsuffixed = conflictSuffixStripped(key), wantedNames.contains(unsuffixed) {
                    matches[unsuffixed, default: []].append(item)
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

    /// `name-<digits>.ext` → `name.ext`; nil when the stem carries no conflict suffix.
    private static func conflictSuffixStripped(_ filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let digits = stem[stem.index(after: dash)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              dash > stem.startIndex else { return nil }
        let base = String(stem[..<dash])
        return ext.isEmpty ? base : "\(base).\(ext)"
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
