import Foundation

/// Unzips a user-picked archive with `ditto` without letting a hostile archive ("zip bomb") fill
/// the temporary volume or run forever.
///
/// Two layers, because a ZIP's declared sizes can lie:
/// 1. Preflight: the central directory's entry count and declared uncompressed total must fit the
///    caller's limits and the free space on the destination volume.
/// 2. Watchdog: while `ditto` runs, the destination is measured on a timer and the process is
///    terminated once it holds more than the declared total (plus slack) or the limit, or when
///    the task is cancelled. A final measurement after exit makes the outcome deterministic.
nonisolated enum GuardedZipExtraction {
    struct Limits: Sendable, Equatable {
        var maxTotalBytes: Int64
        var maxEntries: Int

        /// Keyword lists are plain text; real exports are a few files of at most a few MB.
        static let keywordLists = Limits(maxTotalBytes: 512 * 1_048_576, maxEntries: 10_000)
        /// people.json plus one small JPEG per stored face.
        static let knownPeople = Limits(maxTotalBytes: 4 * 1_073_741_824, maxEntries: 400_000)
        /// Analysis projects carry their photos, so only free disk space really bounds them.
        static let analysisProject = Limits(maxTotalBytes: 256 * 1_073_741_824, maxEntries: 200_000)
    }

    enum ExtractionError: LocalizedError, Equatable, Sendable {
        case notAZipArchive
        case tooManyEntries(limit: Int)
        case tooLarge(limit: Int64)
        case notEnoughSpace(needed: Int64, available: Int64)
        case commandFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                "This file isn't a readable archive. It may be damaged or incomplete."
            case .tooManyEntries(let limit):
                "This archive contains more than \(limit.formatted()) files, which is more than it should, so it wasn't opened. It may be damaged or not made by Photo Agent."
            case .tooLarge(let limit):
                "This archive unpacks to more data than it should (over \(Self.format(limit))), so it wasn't opened. It may be damaged or not made by Photo Agent."
            case .notEnoughSpace(let needed, let available):
                "There isn't enough free disk space to open this archive (it needs \(Self.format(needed)), \(Self.format(available)) is free)."
            case .commandFailed(let status):
                "The archive couldn't be opened (error \(status))."
            }
        }

        private static func format(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    struct Summary: Sendable, Equatable {
        var entryCount: Int
        var declaredUncompressedBytes: Int64
    }

    /// Space left free on the destination volume after extraction.
    static let reservedFreeBytes: Int64 = 512 * 1_048_576
    static let pollInterval: DispatchTimeInterval = .milliseconds(250)

    /// Extracts `archive` into the existing `destination` directory. Throws `CancellationError`
    /// when `isCancelled` turns true; the caller owns (and removes) `destination` on failure.
    static func extract(
        _ archive: URL,
        into destination: URL,
        limits: Limits,
        availableBytes: (URL) -> Int64? = Self.availableBytes(at:),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        if isCancelled() { throw CancellationError() }
        let summary = try preflight(archive, limits: limits)
        if let available = availableBytes(destination) {
            let usable = max(0, available - reservedFreeBytes)
            if summary.declaredUncompressedBytes > usable {
                throw ExtractionError.notEnoughSpace(
                    needed: summary.declaredUncompressedBytes, available: available
                )
            }
        }
        // ditto writes AppleDouble (`__MACOSX/._*`) entries as extended attributes, so honest
        // extraction never holds more file data than the declared total.
        let slack = max(Int64(1_048_576), summary.declaredUncompressedBytes / 100)
        let (byteCap, overflowed) = summary.declaredUncompressedBytes.addingReportingOverflow(slack)
        try runWatched(
            arguments: ["-x", "-k", archive.path, destination.path],
            destination: destination,
            byteCap: overflowed ? limits.maxTotalBytes : min(limits.maxTotalBytes, byteCap),
            entryCap: limits.maxEntries,
            isCancelled: isCancelled
        )
    }

    /// The same extraction for async callers: the blocking work runs on a utility queue, and
    /// cancelling the calling task stops `ditto`.
    static func extract(_ archive: URL, into destination: URL, limits: Limits) async throws {
        let cancelled = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try extract(archive, into: destination, limits: limits, isCancelled: { cancelled.isSet })
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
        try Task.checkCancellation()
    }

    // MARK: - Preflight

    /// Reads the ZIP central directory (classic and Zip64) without extracting anything.
    static func preflight(_ archive: URL, limits: Limits) throws -> Summary {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archive)
        } catch {
            throw ExtractionError.notAZipArchive
        }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else {
            throw ExtractionError.notAZipArchive
        }

        // End of central directory: 22 bytes plus a comment of at most 65,535 bytes.
        let tailLength = min(fileSize, 22 + 65_535)
        let tailStart = fileSize - tailLength
        let tail = try read(handle, offset: tailStart, count: Int(tailLength))
        guard let eocdIndex = lastIndex(ofSignature: 0x0605_4B50, in: tail, minimumTrailing: 22) else {
            throw ExtractionError.notAZipArchive
        }
        let eocdOffset = tailStart + UInt64(eocdIndex)
        var entryCount = UInt64(tail.uint16(at: eocdIndex + 10))
        var directorySize = UInt64(tail.uint32(at: eocdIndex + 12))
        var directoryEnd = eocdOffset

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || tail.uint32(at: eocdIndex + 16) == 0xFFFF_FFFF {
            // Zip64: a 20-byte locator sits right before the classic record.
            guard eocdOffset >= 20 else { throw ExtractionError.notAZipArchive }
            let locator = try read(handle, offset: eocdOffset - 20, count: 20)
            guard locator.uint32(at: 0) == 0x0706_4B50 else { throw ExtractionError.notAZipArchive }
            let zip64Offset = locator.uint64(at: 8)
            guard zip64Offset <= eocdOffset - 20, eocdOffset - 20 - zip64Offset >= 56 else {
                throw ExtractionError.notAZipArchive
            }
            let record = try read(handle, offset: zip64Offset, count: 56)
            guard record.uint32(at: 0) == 0x0606_4B50 else { throw ExtractionError.notAZipArchive }
            entryCount = record.uint64(at: 32)
            directorySize = record.uint64(at: 40)
            directoryEnd = zip64Offset
        }

        guard entryCount <= UInt64(limits.maxEntries) else {
            throw ExtractionError.tooManyEntries(limit: limits.maxEntries)
        }
        // A central directory record is at least 46 bytes and at most 46 + 3 × 65,535.
        guard directorySize <= directoryEnd,
              directorySize <= min(entryCount * (46 + 3 * 65_535), 256 * 1_048_576),
              directorySize >= entryCount * 46 else {
            throw ExtractionError.notAZipArchive
        }
        let directory = try read(handle, offset: directoryEnd - directorySize, count: Int(directorySize))

        var total: Int64 = 0
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count, directory.uint32(at: cursor) == 0x0201_4B50 else {
                throw ExtractionError.notAZipArchive
            }
            let uncompressed32 = directory.uint32(at: cursor + 24)
            let nameLength = Int(directory.uint16(at: cursor + 28))
            let extraLength = Int(directory.uint16(at: cursor + 30))
            let commentLength = Int(directory.uint16(at: cursor + 32))
            let extraStart = cursor + 46 + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw ExtractionError.notAZipArchive }

            var uncompressed = UInt64(uncompressed32)
            if uncompressed32 == 0xFFFF_FFFF {
                guard let value = zip64UncompressedSize(
                    in: directory, extraStart: extraStart, extraLength: extraLength
                ) else {
                    throw ExtractionError.notAZipArchive
                }
                uncompressed = value
            }
            guard uncompressed <= UInt64(limits.maxTotalBytes) else {
                throw ExtractionError.tooLarge(limit: limits.maxTotalBytes)
            }
            total += Int64(uncompressed)
            guard total <= limits.maxTotalBytes else {
                throw ExtractionError.tooLarge(limit: limits.maxTotalBytes)
            }
            cursor = next
        }
        return Summary(entryCount: Int(entryCount), declaredUncompressedBytes: total)
    }

    private static func zip64UncompressedSize(in data: Data, extraStart: Int, extraLength: Int) -> UInt64? {
        var cursor = extraStart
        let end = extraStart + extraLength
        while cursor + 4 <= end {
            let id = data.uint16(at: cursor)
            let size = Int(data.uint16(at: cursor + 2))
            guard cursor + 4 + size <= end else { return nil }
            // In the Zip64 field the uncompressed size comes first when it is present.
            if id == 0x0001, size >= 8 {
                return data.uint64(at: cursor + 4)
            }
            cursor += 4 + size
        }
        return nil
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ExtractionError.notAZipArchive
            }
            return data
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.notAZipArchive
        }
    }

    private static func lastIndex(ofSignature signature: UInt32, in data: Data, minimumTrailing: Int) -> Int? {
        guard data.count >= minimumTrailing else { return nil }
        var index = data.count - minimumTrailing
        while index >= 0 {
            if data.uint32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Watched extraction

    static func runWatched(
        arguments: [String],
        destination: URL,
        byteCap: Int64,
        entryCap: Int,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        var stopReason: (any Error)?
        while exited.wait(timeout: .now() + pollInterval) == .timedOut {
            if isCancelled() {
                stopReason = CancellationError()
            } else if let violation = violation(in: destination, byteCap: byteCap, entryCap: entryCap) {
                stopReason = violation
            }
            if stopReason != nil {
                process.terminate()
                exited.wait()
                break
            }
        }
        if let stopReason { throw stopReason }
        if isCancelled() { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ExtractionError.commandFailed(process.terminationStatus)
        }
        if let violation = violation(in: destination, byteCap: byteCap, entryCap: entryCap) {
            throw violation
        }
    }

    private static func violation(in directory: URL, byteCap: Int64, entryCap: Int) -> ExtractionError? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var bytes: Int64 = 0
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            if entries > entryCap { return .tooManyEntries(limit: entryCap) }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            bytes += Int64(size)
            if bytes > byteCap { return .tooLarge(limit: byteCap) }
        }
        return nil
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

nonisolated private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

nonisolated private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
