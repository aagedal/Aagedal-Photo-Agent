import Foundation
import os.log

private let exifToolLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "ExifToolService")

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

    var exifToolPath: String? {
        let sourceRaw = UserDefaults.standard.string(forKey: "exifToolSource") ?? "bundled"

        switch sourceRaw {
        case "bundled":
            return bundledExifToolPath
        case "homebrew":
            return homebrewExifToolPath
        case "custom":
            if let customPath = UserDefaults.standard.string(forKey: "exifToolCustomPath"),
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

        try proc.run()
        isRunning = true
        runningPath = path
    }

    func stop() {
        guard isRunning else { return }
        // Only try to send stop command if process is still running
        if process?.isRunning == true {
            sendCommand(["-stay_open", "False"])
        }
        try? stdinPipe?.fileHandleForWriting.close()
        process?.waitUntilExit()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        isRunning = false
        runningPath = nil
    }

    private func handleOutput(_ str: String) {
        accumulatedOutput += str

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
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        let command = arguments.joined(separator: "\n") + "\n-execute\n"
        if let data = command.data(using: .utf8) {
            handle.write(data)
        }
    }

    // MARK: - High-Level Operations

    /// Read basic metadata (rating, label, C2PA) for a batch of files.
    func readBatchBasicMetadata(urls: [URL]) async throws -> [[String: Any]] {
        guard !urls.isEmpty else { return [] }

        var args = ["-json", "-XMP:Rating", "-XMP:Label", "-XMP-iptcExt:PersonInImage", "-JUMBF:All"]
        args += urls.map(\.path)

        let output = try await execute(args)
        return parseJSON(output)
    }

    /// Read full metadata for a single file.
    func readFullMetadata(url: URL) async throws -> IPTCMetadata {
        exifToolLog.debug("readFullMetadata: \(url.lastPathComponent, privacy: .public)")
        let args = ["-json", "-n", "-IPTC:All", "-XMP:All", "-EXIF:GPSLatitude", "-EXIF:GPSLongitude", "-struct", url.path]
        let output = try await execute(args)
        exifToolLog.debug("readFullMetadata completed: \(url.lastPathComponent, privacy: .public)")
        let results = parseJSON(output)

        guard let dict = results.first else {
            return IPTCMetadata()
        }

        return IPTCMetadata(
            title: dict["Headline"] as? String
                ?? dict["Title"] as? String
                ?? dict["ObjectName"] as? String,
            description: dict["Description"] as? String ?? dict["Caption-Abstract"] as? String,
            extendedDescription: dict["ExtDescrAccessibility"] as? String,
            keywords: parseStringOrArray(dict["Subject"] ?? dict["Keywords"]),
            personShown: parseStringOrArray(dict["PersonInImage"]),
            digitalSourceType: (dict["DigitalSourceType"] as? String).flatMap { DigitalSourceType(rawValue: $0) },
            latitude: dict["GPSLatitude"] as? Double,
            longitude: dict["GPSLongitude"] as? Double,
            creator: parseFirstString(dict["Creator"] ?? dict["By-line"]),
            credit: dict["Credit"] as? String,
            copyright: dict["Rights"] as? String ?? dict["CopyrightNotice"] as? String,
            jobId: dict["TransmissionReference"] as? String
                ?? dict["JobID"] as? String
                ?? dict["OriginalTransmissionReference"] as? String,
            dateCreated: dict["DateCreated"] as? String ?? dict["CreateDate"] as? String,
            captureDate: dict["DateTimeOriginal"] as? String,
            city: dict["City"] as? String,
            country: dict["Country"] as? String ?? dict["Country-PrimaryLocationName"] as? String,
            event: dict["Event"] as? String,
            rating: dict["Rating"] as? Int,
            label: ColorLabel.canonicalMetadataLabel(dict["Label"] as? String)
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
        if let subject = normalizedFields["XMP:Subject"], normalizedFields["IPTC:Keywords"] == nil {
            normalizedFields["IPTC:Keywords"] = subject
        }
        if let rights = normalizedFields["XMP:Rights"], normalizedFields["IPTC:CopyrightNotice"] == nil {
            normalizedFields["IPTC:CopyrightNotice"] = rights
        }
        if let title = normalizedFields["XMP:Title"], normalizedFields["XMP-photoshop:Headline"] == nil {
            normalizedFields["XMP-photoshop:Headline"] = title
        }
        if let headline = normalizedFields["XMP-photoshop:Headline"], normalizedFields["IPTC:Headline"] == nil {
            normalizedFields["IPTC:Headline"] = headline
        }
        if let creator = normalizedFields["XMP:Creator"], normalizedFields["IPTC:By-line"] == nil {
            normalizedFields["IPTC:By-line"] = creator
        }
        if let jobId = normalizedFields["XMP-photoshop:TransmissionReference"] {
            if normalizedFields["IPTC:OriginalTransmissionReference"] == nil {
                normalizedFields["IPTC:OriginalTransmissionReference"] = jobId
            }
            if normalizedFields["IPTC:JobID"] == nil {
                normalizedFields["IPTC:JobID"] = jobId
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
        try await writeFields(["XMP:Rating": value], to: urls)
    }

    /// Write color label to files.
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {
        try await writeFields(["XMP:Label": label.xmpLabelValue ?? ""], to: urls)
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
        return TechnicalMetadata(from: dict)
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

}
