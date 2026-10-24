import Foundation

/// What kind of background operation produced an activity entry.
enum ActivityKind: String, Codable, Sendable {
    case importJob
    case upload
    case faceScan
    case transcription
}

/// Whether a file was confirmed intact after the operation.
/// `nil` means verification did not apply (e.g. uploads, or import with
/// verification turned off) and should render as a neutral dash, not a cross.
enum ActivityVerification: String, Codable, Sendable {
    case verified
    case failed
    case notApplicable
}

/// One file within an activity entry — the Layer 2 detail row.
struct ActivityFileRecord: Codable, Sendable, Identifiable {
    let id: UUID
    /// Source file name (what the user recognises).
    let fileName: String
    /// Where it landed: destination folder path (import) or server/remote path (upload).
    let destination: String
    /// Copy/transfer succeeded.
    let succeeded: Bool
    /// Per-file verification outcome.
    let verification: ActivityVerification
    let statusDetail: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        destination: String,
        succeeded: Bool,
        verification: ActivityVerification,
        statusDetail: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.destination = destination
        self.succeeded = succeeded
        self.verification = verification
        self.statusDetail = statusDetail
    }
}

/// Durable outcome totals for an import. Optional on `ActivityEntry` so history
/// written by older app versions remains decodable.
struct ActivityImportResultCounts: Codable, Sendable, Equatable {
    let replaced: Int
    let backupReplaced: Int
    /// Files intentionally not copied (already at the destination or previously imported).
    /// These are not failures.
    let skipped: Int
    let renamed: Int
    /// Files whose backup leg failed, even when the primary copy succeeded.
    let backupFailed: Int
    /// Copied photos whose template metadata or voice-memo link could not be saved.
    let metadataFailed: Int

    init(
        replaced: Int,
        backupReplaced: Int,
        skipped: Int,
        renamed: Int,
        backupFailed: Int = 0,
        metadataFailed: Int = 0
    ) {
        self.replaced = replaced
        self.backupReplaced = backupReplaced
        self.skipped = skipped
        self.renamed = renamed
        self.backupFailed = backupFailed
        self.metadataFailed = metadataFailed
    }

    private enum CodingKeys: String, CodingKey {
        case replaced, backupReplaced, skipped, renamed, backupFailed, metadataFailed
    }

    /// History written before backup/metadata failures were tracked decodes them as zero.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replaced = try container.decode(Int.self, forKey: .replaced)
        backupReplaced = try container.decode(Int.self, forKey: .backupReplaced)
        skipped = try container.decode(Int.self, forKey: .skipped)
        renamed = try container.decode(Int.self, forKey: .renamed)
        backupFailed = try container.decodeIfPresent(Int.self, forKey: .backupFailed) ?? 0
        metadataFailed = try container.decodeIfPresent(Int.self, forKey: .metadataFailed) ?? 0
    }
}

/// A single completed (or cancelled) background operation — the Layer 1 summary row.
struct ActivityEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let kind: ActivityKind
    /// When the operation finished.
    let date: Date
    /// Import title or server name, when available.
    let title: String?
    /// Files that completed successfully.
    let successCount: Int
    /// Total files attempted.
    let totalCount: Int
    /// Files whose verification failed (mismatch). Import only; 0 otherwise.
    let verificationFailures: Int
    /// Whether copy verification was active for this run (drives the
    /// "with copy verification" summary wording).
    let verificationEnabled: Bool
    /// Whether the run was cancelled before finishing.
    let wasCancelled: Bool
    let importResultCounts: ActivityImportResultCounts?
    /// Credential-free upload transport evidence. `nil` for imports, face scans, and legacy data.
    let deliveryTransportSecurity: DeliveryTransportSecurity?
    /// Durable-write failure, retained separately from per-photo detection counts. For an
    /// import, the error that stopped it after copying had started.
    let persistenceError: String?
    let files: [ActivityFileRecord]
    /// Successful per-file rows dropped from `files` to bound the stored log. The summary counts
    /// above are unaffected. `nil` (legacy data, or nothing dropped) means `files` is complete.
    let omittedSuccessfulFileCount: Int?

    init(
        id: UUID = UUID(),
        kind: ActivityKind,
        date: Date,
        title: String?,
        successCount: Int,
        totalCount: Int,
        verificationFailures: Int = 0,
        verificationEnabled: Bool = false,
        wasCancelled: Bool = false,
        importResultCounts: ActivityImportResultCounts? = nil,
        deliveryTransportSecurity: DeliveryTransportSecurity? = nil,
        persistenceError: String? = nil,
        files: [ActivityFileRecord],
        omittedSuccessfulFileCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.title = title
        self.successCount = successCount
        self.totalCount = totalCount
        self.verificationFailures = verificationFailures
        self.verificationEnabled = verificationEnabled
        self.wasCancelled = wasCancelled
        self.importResultCounts = importResultCounts
        self.deliveryTransportSecurity = deliveryTransportSecurity
        self.persistenceError = persistenceError
        self.files = files
        self.omittedSuccessfulFileCount = omittedSuccessfulFileCount
    }

    /// A copy that keeps every failed row but at most `limit` successful ones, recording how many
    /// successes were dropped. Per-file rows (with full destination paths for imports) are the
    /// bulk of the persisted log; failures are what the user needs to act on.
    func cappingSuccessfulFiles(to limit: Int) -> ActivityEntry {
        let successfulCount = files.lazy.filter(\.succeeded).count
        guard successfulCount > limit else { return self }
        var keptSuccesses = 0
        let kept = files.filter { record in
            guard record.succeeded else { return true }
            keptSuccesses += 1
            return keptSuccesses <= limit
        }
        return ActivityEntry(
            id: id,
            kind: kind,
            date: date,
            title: title,
            successCount: successCount,
            totalCount: totalCount,
            verificationFailures: verificationFailures,
            verificationEnabled: verificationEnabled,
            wasCancelled: wasCancelled,
            importResultCounts: importResultCounts,
            deliveryTransportSecurity: deliveryTransportSecurity,
            persistenceError: persistenceError,
            files: kept,
            omittedSuccessfulFileCount: (omittedSuccessfulFileCount ?? 0) + successfulCount - limit
        )
    }

    /// Failed files (attempted but not completed). Skipped import files were deliberately
    /// not copied and are not failures.
    var failureCount: Int {
        max(0, totalCount - successCount - (importResultCounts?.skipped ?? 0))
    }

    private var backupFailureCount: Int { importResultCounts?.backupFailed ?? 0 }
    private var metadataFailureCount: Int { importResultCounts?.metadataFailed ?? 0 }

    /// One-line headline for the completion banner and the Layer 1 row.
    var summary: String {
        let noun = switch kind {
        case .importJob: "Import"
        case .upload: "Upload"
        case .faceScan: "Face scan"
        case .transcription: "Transcription"
        }
        if wasCancelled {
            let item = kind == .faceScan || kind == .transcription ? "photo" : "file"
            let suffix = persistenceError == nil ? "" : " (save failed)"
            return "\(noun) cancelled — \(successCount) of \(totalCount) \(item)\(totalCount == 1 ? "" : "s")\(suffix)"
        }
        var line: String
        if kind == .transcription {
            line = "Transcription of \(successCount) voice memo\(successCount == 1 ? "" : "s") completed"
        } else if kind == .faceScan {
            line = "Face scan of \(successCount) photo\(successCount == 1 ? "" : "s") completed"
        } else {
            line = "\(noun) of \(successCount) file\(successCount == 1 ? "" : "s") completed"
        }
        if kind == .importJob && verificationEnabled && verificationFailures == 0 && failureCount == 0
            && backupFailureCount == 0 {
            line += " with copy verification"
        }
        var problems: [String] = []
        if let skipped = importResultCounts?.skipped, skipped > 0 { problems.append("\(skipped) skipped") }
        if failureCount > 0 { problems.append("\(failureCount) failed") }
        if verificationFailures > 0 { problems.append("\(verificationFailures) verification issue\(verificationFailures == 1 ? "" : "s")") }
        if backupFailureCount > 0 { problems.append("backup failed for \(backupFailureCount)") }
        if metadataFailureCount > 0 { problems.append("metadata failed for \(metadataFailureCount)") }
        if persistenceError != nil { problems.append(kind == .importJob ? "stopped early" : "save failed") }
        if !problems.isEmpty { line += " (\(problems.joined(separator: ", ")))" }
        return line
    }

    /// True when every attempted file succeeded and nothing failed verification.
    var isClean: Bool {
        !wasCancelled && failureCount == 0 && verificationFailures == 0 && persistenceError == nil
            && backupFailureCount == 0 && metadataFailureCount == 0
    }
}

/// Persisted, capped log of recent imports and uploads, shared by both flows.
@Observable
@MainActor
final class ActivityHistoryStore {
    static let maxEntries = 50
    /// Successful per-file rows kept per entry (all failures are kept). Totals are stored
    /// separately on the entry, so the summary stays exact.
    static let maxSuccessfulFileRecordsPerEntry = 200

    private(set) var entries: [ActivityEntry] = []

    init() {
        load()
    }

    /// Records a finished operation at the front of the log, trimming to the cap.
    func record(_ entry: ActivityEntry) {
        entries.insert(entry.cappingSuccessfulFiles(to: Self.maxSuccessfulFileRecordsPerEntry), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    // MARK: - Persistence (test-safe via AppDefaults.store)

    private func load() {
        guard let data = AppDefaults.store.data(forKey: UserDefaultsKeys.activityHistory),
              let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) else {
            return
        }
        // Logs written before the per-entry cap shrink on their next save.
        entries = decoded.map { $0.cappingSuccessfulFiles(to: Self.maxSuccessfulFileRecordsPerEntry) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            AppDefaults.store.set(data, forKey: UserDefaultsKeys.activityHistory)
        }
    }
}
