import Foundation
import SwiftExif

/// Serialized filesystem boundary for capture-date discovery used by the Import sheet.
///
/// Foundation and SwiftExif reads are synchronous once entered, so cancellation is sampled
/// before and after each file. The main actor receives immutable evidence and publishes only a
/// complete result belonging to its current request.
actor ImportCaptureDateScanService {
    typealias CaptureDateReader = @Sendable (URL) -> String?
    typealias ModificationDateReader = @Sendable (URL) -> Date?

    struct Group: Sendable, Equatable {
        let dateString: String
        let folderDate: String
        let yearFolder: String?
        let monthFolder: String?
        let files: [URL]
        let captureTimes: [URL: Date]
    }

    struct Evidence: Sendable, Equatable {
        let requestedFileCount: Int
        let processedFileCount: Int
        let groups: [Group]
    }

    enum Result: Sendable, Equatable {
        case complete(Evidence)
        case cancelled(Evidence)
    }

    private let captureDateReader: CaptureDateReader
    private let modificationDateReader: ModificationDateReader

    init(
        captureDateReader: @escaping CaptureDateReader = { url in
            try? ImageMetadata.read(from: url).exif?.dateTimeOriginal
        },
        modificationDateReader: @escaping ModificationDateReader = { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    ) {
        self.captureDateReader = captureDateReader
        self.modificationDateReader = modificationDateReader
    }

    func scan(_ files: [URL]) -> Result {
        var fileToDateKey: [URL: String] = [:]
        var fileToTimestamp: [URL: Date] = [:]
        var processedFiles: [URL] = []
        processedFiles.reserveCapacity(files.count)

        let exifParser = Self.dateFormatter(format: "yyyy:MM:dd HH:mm:ss")
        let keyFromDate = Self.dateFormatter(format: "yyyy:MM:dd")

        for file in files {
            guard !Task.isCancelled else {
                return .cancelled(Self.evidence(
                    requestedFileCount: files.count,
                    processedFiles: processedFiles,
                    dateKeys: fileToDateKey,
                    timestamps: fileToTimestamp
                ))
            }

            let captureDate = captureDateReader(file)
            guard !Task.isCancelled else {
                return .cancelled(Self.evidence(
                    requestedFileCount: files.count,
                    processedFiles: processedFiles,
                    dateKeys: fileToDateKey,
                    timestamps: fileToTimestamp
                ))
            }
            if let dateString = captureDate {
                fileToDateKey[file] = String(dateString.prefix(10))
                if let parsed = exifParser.date(from: dateString) {
                    fileToTimestamp[file] = parsed
                }
            } else {
                let modificationDate = modificationDateReader(file)
                guard !Task.isCancelled else {
                    return .cancelled(Self.evidence(
                        requestedFileCount: files.count,
                        processedFiles: processedFiles,
                        dateKeys: fileToDateKey,
                        timestamps: fileToTimestamp
                    ))
                }
                if let modificationDate {
                    fileToDateKey[file] = keyFromDate.string(from: modificationDate)
                    fileToTimestamp[file] = modificationDate
                }
            }
            processedFiles.append(file)
        }

        let evidence = Self.evidence(
            requestedFileCount: files.count,
            processedFiles: processedFiles,
            dateKeys: fileToDateKey,
            timestamps: fileToTimestamp
        )
        return Task.isCancelled ? .cancelled(evidence) : .complete(evidence)
    }

    private static func evidence(
        requestedFileCount: Int,
        processedFiles: [URL],
        dateKeys: [URL: String],
        timestamps: [URL: Date]
    ) -> Evidence {
        let grouped = Dictionary(grouping: processedFiles) { dateKeys[$0] ?? "Unknown Date" }
        let folderDateFormatter = dateFormatter(format: "yyyy-MM-dd")
        let yearFormatter = dateFormatter(format: "yyyy")
        let monthFormatter = dateFormatter(format: "MM")
        let parseDateFormatter = dateFormatter(format: "yyyy:MM:dd")

        let groups = grouped.keys.sorted().map { dateKey in
            let parsedDate = parseDateFormatter.date(from: dateKey)
            let groupFiles = grouped[dateKey] ?? []
            let groupTimes = Dictionary(uniqueKeysWithValues: groupFiles.compactMap { file in
                timestamps[file].map { (file, $0) }
            })
            return Group(
                dateString: dateKey,
                folderDate: parsedDate.map(folderDateFormatter.string(from:)) ?? dateKey,
                yearFolder: parsedDate.map(yearFormatter.string(from:)),
                monthFolder: parsedDate.map(monthFormatter.string(from:)),
                files: groupFiles,
                captureTimes: groupTimes
            )
        }
        return Evidence(
            requestedFileCount: requestedFileCount,
            processedFileCount: processedFiles.count,
            groups: groups
        )
    }

    private static func dateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

/// Serialized, cancellable inventory of existing Import destination folders.
actor ImportFolderSuggestionService {
    typealias FolderFinder = @Sendable (String, URL) -> [URL]

    struct Evidence: Sendable, Equatable {
        let requestedDates: [String]
        let completedDateCount: Int
        let suggestions: [String: [URL]]
    }

    enum Result: Sendable, Equatable {
        case complete(Evidence)
        case cancelled(Evidence)
    }

    private let folderFinder: FolderFinder

    init(folderFinder: @escaping FolderFinder = { date, destinationBaseURL in
        PreviousImportDetector.matchingDateFolders(named: date, under: destinationBaseURL)
    }) {
        self.folderFinder = folderFinder
    }

    func suggestions(for dates: Set<String>, under destinationBaseURL: URL) -> Result {
        let requestedDates = dates.sorted()
        var completedDateCount = 0
        var suggestions: [String: [URL]] = [:]

        for date in requestedDates {
            guard !Task.isCancelled else {
                return .cancelled(Evidence(
                    requestedDates: requestedDates,
                    completedDateCount: completedDateCount,
                    suggestions: suggestions
                ))
            }
            let folders = folderFinder(date, destinationBaseURL)
            guard !Task.isCancelled else {
                return .cancelled(Evidence(
                    requestedDates: requestedDates,
                    completedDateCount: completedDateCount,
                    suggestions: suggestions
                ))
            }
            completedDateCount += 1
            if !folders.isEmpty {
                suggestions[date] = folders
            }
        }

        let evidence = Evidence(
            requestedDates: requestedDates,
            completedDateCount: completedDateCount,
            suggestions: suggestions
        )
        return Task.isCancelled ? .cancelled(evidence) : .complete(evidence)
    }
}
