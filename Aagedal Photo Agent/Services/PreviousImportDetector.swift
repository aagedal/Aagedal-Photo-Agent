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
///    into the copy afterwards. A match counts only when its entry is the latest (finished)
///    record for that destination path and the file there is still that copy: a RAW must be
///    byte-identical, another image unchanged or carrying the same EXIF capture identity. A
///    photo that is no longer in the library, or whose path now holds another file, is never
///    withheld.
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
///    matched counts as imported when the file beside that RAW's copy is the same camera file —
///    byte-identical, or (its bytes may have changed when metadata was embedded) the same EXIF
///    capture identity. An export saved under the original name does not qualify.
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

        // 1. Ledger. Only the latest entry for a destination path speaks for it: a later
        // import that overwrote the path, or reused the name after a delete, supersedes it.
        let ledger = ImportLedger.load(root: destinationBaseURL)
        var latestEntryIndexByPath: [String: Int] = [:]
        for (index, entry) in ledger.enumerated() {
            latestEntryIndexByPath[ImportLedger.pathKey(entry.destination)] = index
        }
        if !ledger.isEmpty {
            let entryIndicesByKey = Dictionary(grouping: Array(ledger.indices)) {
                ImportLedger.lookupKey(name: ledger[$0].name, size: ledger[$0].size)
            }
            for candidate in candidates {
                try Task.checkCancellation()
                guard let size = fileSize(at: candidate.source),
                      let indices = entryIndicesByKey[ImportLedger.lookupKey(
                        name: candidate.source.lastPathComponent,
                        size: Int64(size)
                      )],
                      let hash = sourceHash(candidate.source) else { continue }
                let hex = ImportLedger.hex(hash)
                let captureDate = ImportLedger.captureDateString(candidate.captureDate)
                for index in indices.reversed() where ledger[index].quickHash == hex {
                    let entry = ledger[index]
                    if let captureDate, let recorded = entry.captureDate, recorded != captureDate {
                        continue
                    }
                    guard latestEntryIndexByPath[ImportLedger.pathKey(entry.destination)] == index,
                          entry.finished != false else { continue }
                    let destination = destinationBaseURL.appendingPathComponent(entry.destination)
                    guard copyIsStillThisFile(destination, entry: entry, source: candidate.source) else {
                        continue
                    }
                    duplicates.insert(candidate.source)
                    matchedDestinations[candidate.source] = destination
                    break
                }
            }
        }
        /// The ledger is authoritative for paths it knows; the legacy scan and the RAW-partner
        /// rule only judge files it has no record of.
        func ledgerKnows(_ url: URL) -> Bool {
            guard !latestEntryIndexByPath.isEmpty,
                  let relative = ImportViewModel.relativePath(of: url, under: destinationBaseURL) else {
                return false
            }
            return latestEntryIndexByPath[ImportLedger.pathKey(relative)] != nil
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

                for existing in existingFiles where fileSize(at: existing) == sourceSize && !ledgerKnows(existing) {
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
                guard let rawCopy = rawMatchesByExposure[exposureKey(candidate.source)],
                      let partner = partnerCopy(for: candidate.source, besideRawCopy: rawCopy),
                      !ledgerKnows(partner),
                      // A file that merely shares the name (an export saved beside the RAW)
                      // is not this camera file.
                      ImportImageIdentity.isSameCameraFile(
                        source: candidate.source,
                        destination: partner,
                        isImage: true
                      ) else { continue }
                duplicates.insert(candidate.source)
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

    /// A ledger copy still holds the recorded file: a RAW must be byte-identical to what was
    /// copied; any other image must be unchanged or, if metadata was embedded into it since,
    /// still carry the source's EXIF capture identity.
    private static func copyIsStillThisFile(_ copy: URL, entry: ImportLedger.Entry, source: URL) -> Bool {
        guard let copySize = fileSize(at: copy) else { return false }
        let recordedSize = entry.destinationSize ?? entry.size
        if SupportedImageFormats.isRaw(url: copy) {
            guard Int64(copySize) == recordedSize,
                  let hash = try? HashStream.quickHashFile(at: copy) else { return false }
            return ImportLedger.hex(hash) == (entry.destinationQuickHash ?? entry.quickHash)
        }
        if Int64(copySize) == recordedSize,
           let hash = try? HashStream.quickHashFile(at: copy),
           ImportLedger.hex(hash) == entry.quickHash {
            return true
        }
        return ImportImageIdentity.sameExposure(source, copy)
    }

    /// The partner sits beside the RAW's copy under the copy's stem — in the same folder, or in
    /// the sibling `JPEG` folder of the importer's RAW/JPEG layout.
    private static func partnerCopy(for partner: URL, besideRawCopy rawCopy: URL) -> URL? {
        let stem = rawCopy.deletingPathExtension().lastPathComponent
        let ext = partner.pathExtension
        let name = ext.isEmpty ? stem : "\(stem).\(ext)"
        let rawFolder = rawCopy.deletingLastPathComponent()
        var folders = [rawFolder]
        if rawFolder.lastPathComponent.caseInsensitiveCompare("RAW") == .orderedSame {
            folders.append(rawFolder.deletingLastPathComponent().appendingPathComponent("JPEG"))
        }
        return folders.map { $0.appendingPathComponent(name) }.first { candidate in
            (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
