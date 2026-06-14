import Foundation

/// What kind of background operation produced an activity entry.
enum ActivityKind: String, Codable, Sendable {
    case importJob
    case upload
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

    init(
        id: UUID = UUID(),
        fileName: String,
        destination: String,
        succeeded: Bool,
        verification: ActivityVerification
    ) {
        self.id = id
        self.fileName = fileName
        self.destination = destination
        self.succeeded = succeeded
        self.verification = verification
    }
}

/// A single completed (or cancelled) import or upload — the Layer 1 summary row.
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
    let files: [ActivityFileRecord]

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
        files: [ActivityFileRecord]
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
        self.files = files
    }

    /// Failed files (attempted but not completed).
    var failureCount: Int { max(0, totalCount - successCount) }

    /// One-line headline for the completion banner and the Layer 1 row.
    var summary: String {
        let noun = kind == .importJob ? "Import" : "Upload"
        if wasCancelled {
            return "\(noun) cancelled — \(successCount) of \(totalCount) file\(totalCount == 1 ? "" : "s")"
        }
        var line = "\(noun) of \(successCount) file\(successCount == 1 ? "" : "s") completed"
        if kind == .importJob && verificationEnabled && verificationFailures == 0 && failureCount == 0 {
            line += " with copy verification"
        }
        var problems: [String] = []
        if failureCount > 0 { problems.append("\(failureCount) failed") }
        if verificationFailures > 0 { problems.append("\(verificationFailures) verification issue\(verificationFailures == 1 ? "" : "s")") }
        if !problems.isEmpty { line += " (\(problems.joined(separator: ", ")))" }
        return line
    }

    /// True when every attempted file succeeded and nothing failed verification.
    var isClean: Bool {
        !wasCancelled && failureCount == 0 && verificationFailures == 0
    }
}

/// Persisted, capped log of recent imports and uploads, shared by both flows.
@Observable
@MainActor
final class ActivityHistoryStore {
    static let maxEntries = 50

    private(set) var entries: [ActivityEntry] = []

    init() {
        load()
    }

    /// Records a finished operation at the front of the log, trimming to the cap.
    func record(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
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
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            AppDefaults.store.set(data, forKey: UserDefaultsKeys.activityHistory)
        }
    }
}
