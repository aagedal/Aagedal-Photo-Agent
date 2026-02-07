import Foundation
import os.log

private let exifToolLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "ExifToolService")

enum ExifToolReadKey {
    static let sourceFile = "SourceFile"
    static let headline = "Headline"
    static let title = "Title"
    static let objectName = "ObjectName"
    static let description = "Description"
    static let captionAbstract = "Caption-Abstract"
    static let extDescrAccessibility = "ExtDescrAccessibility"
    static let subject = "Subject"
    static let keywords = "Keywords"
    static let personInImage = "PersonInImage"
    static let digitalSourceType = "DigitalSourceType"
    static let gpsLatitude = "GPSLatitude"
    static let gpsLongitude = "GPSLongitude"
    static let creator = "Creator"
    static let byLine = "By-line"
    static let credit = "Credit"
    static let rights = "Rights"
    static let copyrightNotice = "CopyrightNotice"
    static let transmissionReference = "TransmissionReference"
    static let jobID = "JobID"
    static let originalTransmissionReference = "OriginalTransmissionReference"
    static let dateCreated = "DateCreated"
    static let createDate = "CreateDate"
    static let dateTimeOriginal = "DateTimeOriginal"
    static let city = "City"
    static let country = "Country"
    static let countryPrimaryLocationName = "Country-PrimaryLocationName"
    static let event = "Event"
    static let rating = "Rating"
    static let label = "Label"
    static let claimGenerator = "Claim_generator"

    // Camera Raw (crs)
    static let crsWhiteBalance = "WhiteBalance"
    static let crsTemperature = "Temperature"
    static let crsTint = "Tint"
    static let crsIncrementalTemperature = "IncrementalTemperature"
    static let crsIncrementalTint = "IncrementalTint"
    static let crsExposure2012 = "Exposure2012"
    static let crsContrast2012 = "Contrast2012"
    static let crsHighlights2012 = "Highlights2012"
    static let crsShadows2012 = "Shadows2012"
    static let crsWhites2012 = "Whites2012"
    static let crsBlacks2012 = "Blacks2012"
    static let crsHasSettings = "HasSettings"
    static let crsCropTop = "CropTop"
    static let crsCropLeft = "CropLeft"
    static let crsCropBottom = "CropBottom"
    static let crsCropRight = "CropRight"
    static let crsCropAngle = "CropAngle"
    static let crsHasCrop = "HasCrop"
}

/// Manages a persistent ExifTool process in `-stay_open` mode for fast batch operations.
@Observable
final class ExifToolService {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var isRunning = false
    private var runningPath: String?
    private var accumulatedOutput = ""
    private var pendingContinuation: CheckedContinuation<String, any Error>?
    private var commandQueue: [() -> Void] = []
    private var isExecuting = false
    private let maxQueueSize = 100

    deinit {
        MainActor.assumeIsolated {
            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    var exifToolPath: String? {
        let sourceRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.exifToolSource) ?? "bundled"

        switch sourceRaw {
        case "bundled":
            return bundledExifToolPath
        case "homebrew":
            return homebrewExifToolPath
        case "custom":
            if let customPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.exifToolCustomPath),
               FileManager.default.isExecutableFile(atPath: customPath) {
                return customPath
            }
            return nil
        default:
            return bundledExifToolPath
        }
    }

    private var bundledExifToolPath: String? {
        // Try ExifTool folder first, then direct resource
        if let bundledDir = Bundle.main.path(forResource: "ExifTool", ofType: nil) {
            let path = (bundledDir as NSString).appendingPathComponent("exiftool")
            exifToolLog.info("Found bundled ExifTool folder at: \(bundledDir, privacy: .public)")
            return path
        }
        if let path = Bundle.main.path(forResource: "exiftool", ofType: nil) {
            exifToolLog.info("Found bundled exiftool directly at: \(path, privacy: .public)")
            return path
        }
        exifToolLog.warning("No bundled ExifTool found")
        return nil
    }

    private var homebrewExifToolPath: String? {
        let paths = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { exifToolPath != nil }

    func start() throws {
        guard !isRunning, let path = exifToolPath else {
            exifToolLog.error("Cannot start: isRunning=\(self.isRunning), path=\(self.exifToolPath ?? "nil", privacy: .public)")
            return
        }

        exifToolLog.info("Starting ExifTool at: \(path, privacy: .public)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-stay_open", "True", "-@", "-"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Read stdout asynchronously
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleOutput(str)
            }
        }

        // Detect unexpected process termination to resume pending continuations
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination()
            }
        }

        try proc.run()
        isRunning = true
        runningPath = path
    }

    /// Called when the ExifTool process terminates unexpectedly.
    /// Resumes any pending continuation and drains the command queue.
    private func handleProcessTermination() {
        guard isRunning else { return }
        exifToolLog.warning("ExifTool process terminated unexpectedly")

        pendingContinuation?.resume(throwing: NSError(
            domain: "ExifToolService", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "ExifTool process terminated unexpectedly"]
        ))
        pendingContinuation = nil

        let queuedCommands = commandQueue
        commandQueue = []
        isExecuting = false

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        isRunning = false
        runningPath = nil

        // Drain queued commands — each runs sendCommand which will see the nil pipe and resume
        for command in queuedCommands {
            command()
        }
    }

    func stop() {
        guard isRunning else { return }

        // Resume pending continuation and drain command queue to prevent hanging callers
        let pendingError = CancellationError()
        pendingContinuation?.resume(throwing: pendingError)
        pendingContinuation = nil

        let queuedCommands = commandQueue
        commandQueue = []
        isExecuting = false

        // Only try to send stop command if process is still running
        if process?.isRunning == true {
            sendCommand(["-stay_open", "False"])
        }
        try? stdinPipe?.fileHandleForWriting.close()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        isRunning = false
        runningPath = nil

        // Drain queued commands — each closure captures a continuation that must be resumed.
        // Execute closures so they run against `self` (now stopped), which will immediately
        // resume the continuation with an error via the guard in the closure.
        for command in queuedCommands {
            command()
        }
    }

    /// Safety limit for accumulated output (10 MB). If ExifTool sends a malformed
    /// response without a {ready} sentinel, this prevents unbounded memory growth.
    private let maxAccumulatedOutputSize = 10 * 1024 * 1024

    private func handleOutput(_ str: String) {
        accumulatedOutput += str

        // Guard against unbounded growth from a missing sentinel
        if accumulatedOutput.utf8.count > maxAccumulatedOutputSize {
            exifToolLog.error("ExifTool output exceeded \(self.maxAccumulatedOutputSize) bytes without sentinel — restarting")
            let overflow = accumulatedOutput
            accumulatedOutput = ""
            pendingContinuation?.resume(returning: overflow)
            pendingContinuation = nil
            isExecuting = false
            stop()
            return
        }

        // Check for {ready} sentinel — ExifTool sends "{readyNNN}\n" after each command
        if let readyRange = accumulatedOutput.range(of: "{ready", options: .backwards) {
            // Find the end of the ready line
            if let newlineAfterReady = accumulatedOutput[readyRange.upperBound...].firstIndex(of: "\n") {
                let result = String(accumulatedOutput[..<readyRange.lowerBound])
                accumulatedOutput = String(accumulatedOutput[accumulatedOutput.index(after: newlineAfterReady)...])
                pendingContinuation?.resume(returning: result)
                pendingContinuation = nil
                isExecuting = false
                dequeueNext()
            }
        }
    }

    private func dequeueNext() {
        guard !isExecuting, !commandQueue.isEmpty else { return }
        isExecuting = true
        let next = commandQueue.removeFirst()
        next()
    }

    /// Execute an ExifTool command and return the response.
    /// Commands are serialized to prevent concurrent access to the single ExifTool process.
    func execute(_ arguments: [String]) async throws -> String {
        // Restart if path changed (user changed settings)
        if isRunning, let current = exifToolPath, current != runningPath {
            stop()
        }
        if !isRunning {
            try start()
        }

        let label = arguments.first(where: { $0.hasSuffix(".path") || !$0.hasPrefix("-") }) ?? arguments.prefix(3).joined(separator: " ")
        exifToolLog.debug("Queuing command: \(label, privacy: .public) (queue depth: \(self.commandQueue.count))")

        guard commandQueue.count < maxQueueSize else {
            throw NSError(domain: "ExifToolService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Command queue full — ExifTool may be unresponsive"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.commandQueue.append { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                exifToolLog.debug("Executing command: \(label, privacy: .public)")
                self.accumulatedOutput = ""
                self.pendingContinuation = continuation
                self.sendCommand(arguments)
            }
            if !self.isExecuting {
                self.dequeueNext()
            }
        }
    }

    private func sendCommand(_ arguments: [String]) {
        guard let handle = stdinPipe?.fileHandleForWriting,
              process?.isRunning == true else {
            exifToolLog.error("Cannot send command: ExifTool process is not running")
            pendingContinuation?.resume(throwing: NSError(
                domain: "ExifToolService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ExifTool process is not running"]
            ))
            pendingContinuation = nil
            isExecuting = false
            dequeueNext()
            return
        }
        let command = arguments.joined(separator: "\n") + "\n-execute\n"
        if let data = command.data(using: .utf8) {
            handle.write(data)
        }
    }

    // MARK: - High-Level Operations

    /// Read basic metadata (rating, label, C2PA) for a batch of files.
    func readBatchBasicMetadata(urls: [URL]) async throws -> [[String: Any]] {
        guard !urls.isEmpty else { return [] }

        var args = [
            "-json",
            "-XMP:Rating",
            "-XMP:Label",
            "-XMP-iptcExt:PersonInImage",
            "-XMP-crs:HasSettings",
            "-XMP-crs:HasCrop",
            "-XMP-crs:Exposure2012",
            "-XMP-crs:Contrast2012",
            "-XMP-crs:Highlights2012",
            "-XMP-crs:Shadows2012",
            "-XMP-crs:Whites2012",
            "-XMP-crs:Blacks2012",
            "-XMP-crs:Temperature",
            "-XMP-crs:Tint",
            "-XMP-crs:IncrementalTemperature",
            "-XMP-crs:IncrementalTint",
            "-XMP-crs:CropTop",
            "-XMP-crs:CropLeft",
            "-XMP-crs:CropBottom",
            "-XMP-crs:CropRight",
            "-JUMBF:All"
        ]
        args += urls.map(\.path)

        let output = try await execute(args)
        return parseJSON(output)
    }

    /// Read full metadata for a single file.
    func readFullMetadata(url: URL) async throws -> IPTCMetadata {
        exifToolLog.debug("readFullMetadata: \(url.lastPathComponent, privacy: .public)")
        let args = [
            "-json", "-n",
            "-IPTC:All", "-XMP:All",
            "-EXIF:DateTimeOriginal",
            "-EXIF:GPSLatitude", "-EXIF:GPSLongitude",
            "-struct",
            url.path
        ]
        let output = try await execute(args)
        exifToolLog.debug("readFullMetadata completed: \(url.lastPathComponent, privacy: .public)")
        let results = parseJSON(output)

        guard let dict = results.first else {
            return IPTCMetadata()
        }

        return metadataFromDict(dict)
    }

    /// Read full metadata for multiple files in a single ExifTool invocation.
    /// Returns results keyed by URL. Files that fail to parse are omitted from the result.
    func readBatchFullMetadata(urls: [URL]) async throws -> [URL: IPTCMetadata] {
        guard !urls.isEmpty else { return [:] }

        var args = [
            "-json", "-n",
            "-IPTC:All", "-XMP:All",
            "-EXIF:DateTimeOriginal",
            "-EXIF:GPSLatitude", "-EXIF:GPSLongitude",
            "-struct"
        ]
        args += urls.map(\.path)

        let output = try await execute(args)
        let results = parseJSON(output)

        var metadataByURL: [URL: IPTCMetadata] = [:]
        metadataByURL.reserveCapacity(results.count)
        for dict in results {
            guard let sourcePath = dict[ExifToolReadKey.sourceFile] as? String else { continue }
            let url = URL(fileURLWithPath: sourcePath)
            metadataByURL[url] = metadataFromDict(dict)
        }
        return metadataByURL
    }

    private func metadataFromDict(_ dict: [String: Any]) -> IPTCMetadata {
        let crop = CameraRawCrop(
            top: parseDoubleValue(dict[ExifToolReadKey.crsCropTop]),
            left: parseDoubleValue(dict[ExifToolReadKey.crsCropLeft]),
            bottom: parseDoubleValue(dict[ExifToolReadKey.crsCropBottom]),
            right: parseDoubleValue(dict[ExifToolReadKey.crsCropRight]),
            angle: parseDoubleValue(dict[ExifToolReadKey.crsCropAngle]),
            hasCrop: parseBoolValue(dict[ExifToolReadKey.crsHasCrop])
        )
        let cropValue = crop.isEmpty ? nil : crop

        let cameraRaw = CameraRawSettings(
            whiteBalance: dict[ExifToolReadKey.crsWhiteBalance] as? String,
            temperature: parseIntValue(dict[ExifToolReadKey.crsTemperature]),
            tint: parseIntValue(dict[ExifToolReadKey.crsTint]),
            incrementalTemperature: parseIntValue(dict[ExifToolReadKey.crsIncrementalTemperature]),
            incrementalTint: parseIntValue(dict[ExifToolReadKey.crsIncrementalTint]),
            exposure2012: parseDoubleValue(dict[ExifToolReadKey.crsExposure2012]),
            contrast2012: parseIntValue(dict[ExifToolReadKey.crsContrast2012]),
            highlights2012: parseIntValue(dict[ExifToolReadKey.crsHighlights2012]),
            shadows2012: parseIntValue(dict[ExifToolReadKey.crsShadows2012]),
            whites2012: parseIntValue(dict[ExifToolReadKey.crsWhites2012]),
            blacks2012: parseIntValue(dict[ExifToolReadKey.crsBlacks2012]),
            hasSettings: parseBoolValue(dict[ExifToolReadKey.crsHasSettings]),
            crop: cropValue
        )

        return IPTCMetadata(
            title: dict[ExifToolReadKey.headline] as? String
                ?? dict[ExifToolReadKey.title] as? String
                ?? dict[ExifToolReadKey.objectName] as? String,
            description: dict[ExifToolReadKey.description] as? String ?? dict[ExifToolReadKey.captionAbstract] as? String,
            extendedDescription: dict[ExifToolReadKey.extDescrAccessibility] as? String,
            keywords: parseStringOrArray(dict[ExifToolReadKey.subject] ?? dict[ExifToolReadKey.keywords]),
            personShown: parseStringOrArray(dict[ExifToolReadKey.personInImage]),
            digitalSourceType: (dict[ExifToolReadKey.digitalSourceType] as? String).flatMap { DigitalSourceType(rawValue: $0) },
            latitude: dict[ExifToolReadKey.gpsLatitude] as? Double,
            longitude: dict[ExifToolReadKey.gpsLongitude] as? Double,
            creator: parseFirstString(dict[ExifToolReadKey.creator] ?? dict[ExifToolReadKey.byLine]),
            credit: dict[ExifToolReadKey.credit] as? String,
            copyright: dict[ExifToolReadKey.rights] as? String ?? dict[ExifToolReadKey.copyrightNotice] as? String,
            jobId: dict[ExifToolReadKey.transmissionReference] as? String
                ?? dict[ExifToolReadKey.jobID] as? String
                ?? dict[ExifToolReadKey.originalTransmissionReference] as? String,
            dateCreated: dict[ExifToolReadKey.dateCreated] as? String ?? dict[ExifToolReadKey.createDate] as? String,
            captureDate: dict[ExifToolReadKey.dateTimeOriginal] as? String,
            city: dict[ExifToolReadKey.city] as? String,
            country: dict[ExifToolReadKey.country] as? String ?? dict[ExifToolReadKey.countryPrimaryLocationName] as? String,
            event: dict[ExifToolReadKey.event] as? String,
            rating: dict[ExifToolReadKey.rating] as? Int,
            label: ColorLabel.canonicalMetadataLabel(dict[ExifToolReadKey.label] as? String),
            cameraRaw: cameraRaw.isEmpty ? nil : cameraRaw
        )
    }

    /// Write metadata fields to one or more files.
    /// Multi-line values are written via temp files using exiftool's `-TAG<=FILE` syntax,
    /// since the `-stay_open` argfile mode treats each line as a separate argument.
    func writeFields(_ fields: [String: String], to urls: [URL]) async throws {
        guard !urls.isEmpty, !fields.isEmpty else { return }

        var normalizedFields = fields
        // Bridge tends to prioritize IPTC Keywords/Copyright over XMP for some formats.
        // Mirror XMP writes into IPTC when not explicitly provided.
        if let subject = normalizedFields[ExifToolWriteTag.subject], normalizedFields[ExifToolWriteTag.iptcKeywords] == nil {
            normalizedFields[ExifToolWriteTag.iptcKeywords] = subject
        }
        if let rights = normalizedFields[ExifToolWriteTag.rights], normalizedFields[ExifToolWriteTag.iptcCopyrightNotice] == nil {
            normalizedFields[ExifToolWriteTag.iptcCopyrightNotice] = rights
        }
        if let title = normalizedFields[ExifToolWriteTag.xmpTitle], normalizedFields[ExifToolWriteTag.headline] == nil {
            normalizedFields[ExifToolWriteTag.headline] = title
        }
        if let headline = normalizedFields[ExifToolWriteTag.headline], normalizedFields[ExifToolWriteTag.iptcHeadline] == nil {
            normalizedFields[ExifToolWriteTag.iptcHeadline] = headline
        }
        if let creator = normalizedFields[ExifToolWriteTag.creator], normalizedFields[ExifToolWriteTag.iptcByLine] == nil {
            normalizedFields[ExifToolWriteTag.iptcByLine] = creator
        }
        if let jobId = normalizedFields[ExifToolWriteTag.transmissionReference] {
            if normalizedFields[ExifToolWriteTag.iptcOriginalTransmissionReference] == nil {
                normalizedFields[ExifToolWriteTag.iptcOriginalTransmissionReference] = jobId
            }
            if normalizedFields[ExifToolWriteTag.iptcJobID] == nil {
                normalizedFields[ExifToolWriteTag.iptcJobID] = jobId
            }
        }

        let creationDates = captureCreationDates(for: urls)
        defer { restoreCreationDates(creationDates) }

        var args = ["-overwrite_original", "-sep", ", "]
        var tempFiles: [URL] = []

        for (key, value) in normalizedFields {
            if value.contains("\n") || value.contains("\r") {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".txt")
                try value.write(to: tempURL, atomically: true, encoding: .utf8)
                tempFiles.append(tempURL)
                args.append("-\(key)<=\(tempURL.path)")
            } else {
                args.append("-\(key)=\(value)")
            }
        }
        args += urls.map(\.path)

        do {
            _ = try await execute(args)
        } catch {
            for file in tempFiles {
                try? FileManager.default.removeItem(at: file)
            }
            throw error
        }
        for file in tempFiles {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func captureCreationDates(for urls: [URL]) -> [URL: Date] {
        var result: [URL: Date] = [:]
        for url in urls {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let creationDate = attrs[.creationDate] as? Date else {
                continue
            }
            result[url] = creationDate
        }
        return result
    }

    private func restoreCreationDates(_ creationDates: [URL: Date]) {
        guard !creationDates.isEmpty else { return }
        for (url, creationDate) in creationDates {
            do {
                try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
            } catch {
                exifToolLog.debug("Failed to restore creation date for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Write rating to files.
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {
        let value = rating == .none ? "" : String(rating.rawValue)
        try await writeFields([ExifToolWriteTag.rating: value], to: urls)
    }

    /// Write color label to files.
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {
        try await writeFields([ExifToolWriteTag.label: label.xmpLabelValue ?? ""], to: urls)
    }

    /// Read technical/EXIF metadata for a single file.
    func readTechnicalMetadata(url: URL) async throws -> TechnicalMetadata {
        exifToolLog.debug("readTechnicalMetadata: \(url.lastPathComponent, privacy: .public)")
        let args = [
            "-json", "-n",
            "-EXIF:Make", "-EXIF:Model", "-EXIF:LensModel",
            "-EXIF:DateTimeOriginal", "-EXIF:FocalLength",
            "-EXIF:FNumber", "-EXIF:ExposureTime", "-EXIF:ISO",
            "-EXIF:ImageWidth", "-EXIF:ImageHeight",
            "-EXIF:BitsPerSample", "-EXIF:ColorSpace",
            "-ICC_Profile:ProfileDescription",
            "-File:FileModifyDate",
            "-File:ImageWidth", "-File:ImageHeight",
            "-JUMBF:All",
            url.path
        ]
        let output = try await execute(args)
        exifToolLog.debug("readTechnicalMetadata completed: \(url.lastPathComponent, privacy: .public)")
        let results = parseJSON(output)
        guard let dict = results.first else {
            exifToolLog.warning("readTechnicalMetadata: no data returned for \(url.lastPathComponent, privacy: .public)")
            return TechnicalMetadata(from: [:])
        }
        return TechnicalMetadata(from: dict, fileURL: url)
    }

    /// Read detailed C2PA metadata using -G3 to separate multi-manifest chains.
    func readC2PAMetadata(url: URL) async throws -> C2PAMetadata {
        let args = ["-json", "-G3", "-JUMBF:All", url.path]
        let output = try await execute(args)
        let results = parseJSON(output)
        guard let dict = results.first else {
            return C2PAMetadata(from: [:])
        }
        return C2PAMetadata(from: dict)
    }

    // MARK: - Parsing Helpers

    private func parseJSON(_ string: String) -> [[String: Any]] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return json
    }

    private func parseStringOrArray(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let str = value as? String { return [str] }
        return []
    }

    private func parseFirstString(_ value: Any?) -> String? {
        if let str = value as? String { return str }
        if let arr = value as? [String] { return arr.first }
        return nil
    }

    private func parseIntValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func parseDoubleValue(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let intValue = value as? Int { return Double(intValue) }
        if let stringValue = value as? String {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func parseBoolValue(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int {
            if intValue == 0 { return false }
            if intValue == 1 { return true }
        }
        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

}
