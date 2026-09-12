import Foundation
import Observation

nonisolated enum KnownPeopleInterchangeAvailability: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case iCloudEnabled, routing }
    case available
    case unavailable(Reason)
}

nonisolated enum KnownPeopleInterchangeFormat: Sendable { case directory, zip }

/// Opaque handle: only the adapter retains the exact replacement plan behind this ID.
nonisolated struct KnownPeopleInterchangeImportToken: Hashable, Sendable {
    let id: UUID
    init() { id = UUID() }
}

nonisolated struct KnownPeopleInterchangeImportPrompt: Sendable {
    enum Relationship: Sendable { case sameLibrary, differentLibrary, untracked }
    let token: KnownPeopleInterchangeImportToken
    let sourceURL: URL
    let libraryID: UUID
    let relationship: Relationship
    let peopleCount: Int
    let embeddingCount: Int
    let currentLibraryID: UUID?
    /// Nil is explicitly unknown, not an empty current library.
    let currentPeopleCount: Int?
    let currentEmbeddingCount: Int?
    let missingEditorMetadata: Bool
    var replacesWithEmptyLibrary: Bool { peopleCount == 0 }

    init(token: KnownPeopleInterchangeImportToken, sourceURL: URL, libraryID: UUID,
         relationship: Relationship, peopleCount: Int, embeddingCount: Int,
         currentLibraryID: UUID? = nil, currentPeopleCount: Int? = nil,
         currentEmbeddingCount: Int? = nil, missingEditorMetadata: Bool = false) {
        self.token = token; self.sourceURL = sourceURL; self.libraryID = libraryID
        self.relationship = relationship; self.peopleCount = peopleCount; self.embeddingCount = embeddingCount
        self.currentLibraryID = currentLibraryID; self.currentPeopleCount = currentPeopleCount
        self.currentEmbeddingCount = currentEmbeddingCount; self.missingEditorMetadata = missingEditorMetadata
    }
}

nonisolated struct KnownPeopleInterchangeCommitEvidence: Sendable {
    enum RecoveryMeaning: Sendable { case rollbackBackup, unresolved }
    let committed: Bool
    let verified: Bool
    let wasCancelled: Bool
    let detail: String?
    let recoveryURLs: [URL]
    let recoveryMeaning: RecoveryMeaning
    var requiresAttention: Bool {
        (!recoveryURLs.isEmpty && recoveryMeaning == .unresolved) || (committed && (!verified || wasCancelled || detail != nil))
    }
    init(committed: Bool, verified: Bool, wasCancelled: Bool, detail: String?, recoveryURLs: [URL],
         recoveryMeaning: RecoveryMeaning = .unresolved) {
        self.committed = committed; self.verified = verified; self.wasCancelled = wasCancelled
        self.detail = detail; self.recoveryURLs = recoveryURLs; self.recoveryMeaning = recoveryMeaning
    }
}

nonisolated struct KnownPeopleInterchangeProblem: Sendable {
    enum Category: Sendable {
        case unavailable(KnownPeopleInterchangeAvailability.Reason)
        case admissionFailed, importPreparationFailed, importCommitFailed, invalidToken
        case invalidDestination, overwriteRequired, exportPreparationFailed, exportWriteFailed
        case cancelled, zipRequiresDirectory
    }
    let category: Category
    let detail: String?
    let recoveryURLs: [URL]
    let identityAssignment: KnownPeopleInterchangeCommitEvidence?

    init(_ category: Category, detail: String? = nil, recoveryURLs: [URL] = [],
         identityAssignment: KnownPeopleInterchangeCommitEvidence? = nil) {
        self.category = category; self.detail = detail; self.recoveryURLs = recoveryURLs
        self.identityAssignment = identityAssignment
    }
}

nonisolated enum KnownPeopleInterchangeImportPreparation: Sendable {
    case ready(KnownPeopleInterchangeImportPrompt)
    case failed(KnownPeopleInterchangeProblem)
    case cancelled(KnownPeopleInterchangeProblem)
}

nonisolated enum KnownPeopleInterchangeImportCommitOutcome: Sendable {
    case committed(KnownPeopleInterchangeCommitEvidence)
    case failed(KnownPeopleInterchangeProblem)
    case cancelled(KnownPeopleInterchangeProblem)
}

nonisolated struct KnownPeopleInterchangeExportEvidence: Sendable {
    let destinationURL: URL
    let write: KnownPeopleInterchangeCommitEvidence
    let identityAssignment: KnownPeopleInterchangeCommitEvidence?
}

nonisolated enum KnownPeopleInterchangeExportOutcome: Sendable {
    case written(KnownPeopleInterchangeExportEvidence)
    case failed(KnownPeopleInterchangeProblem)
    case cancelled(KnownPeopleInterchangeProblem)
    case requiresDirectory(KnownPeopleInterchangeProblem)
}

@MainActor
protocol KnownPeopleInterchangeOperating: AnyObject {
    var availability: KnownPeopleInterchangeAvailability { get }
    func prepareImport(at sourceURL: URL) async -> KnownPeopleInterchangeImportPreparation
    func commitImport(_ token: KnownPeopleInterchangeImportToken) async -> KnownPeopleInterchangeImportCommitOutcome
    func discardImport(_ token: KnownPeopleInterchangeImportToken)
    /// The caller must obtain this concrete destination before requesting export preparation.
    func export(to destinationURL: URL, format: KnownPeopleInterchangeFormat,
                overwrite: Bool) async -> KnownPeopleInterchangeExportOutcome
}

nonisolated struct KnownPeopleInterchangeNotice: Identifiable, Sendable {
    enum Kind: Sendable { case success, warning, failure, cancelled, guidance }
    let id: UUID
    let requestID: UUID
    let presenterID: UUID
    let kind: Kind
    let title: String
    let detail: String?
    let recoveryURLs: [URL]
    let identityAssignment: KnownPeopleInterchangeCommitEvidence?
}

/// One instance is shared by all presenters. A pending confirmation owns the same global
/// busy slot as a running task. Cancellation never frees that slot before I/O settles.
@Observable @MainActor
final class KnownPeopleInterchangeController {
    struct Request: Identifiable {
        enum Operation { case prepareImport, commitImport, export }
        let id: UUID
        let presenterID: UUID
        let operation: Operation
        var cancellationRequested = false
    }
    struct PendingImport: Identifiable {
        let id: UUID
        let presenterID: UUID
        let prompt: KnownPeopleInterchangeImportPrompt
    }
    private(set) var activeRequest: Request?
    private(set) var pendingImport: PendingImport?
    private var notices: [UUID: KnownPeopleInterchangeNotice] = [:]
    @ObservationIgnored private let operations: any KnownPeopleInterchangeOperating
    @ObservationIgnored private var task: Task<Void, Never>?

    init(operations: any KnownPeopleInterchangeOperating) { self.operations = operations }
    var isBusy: Bool { activeRequest != nil || pendingImport != nil }
    var availability: KnownPeopleInterchangeAvailability { operations.availability }
    func notice(for presenterID: UUID) -> KnownPeopleInterchangeNotice? { notices[presenterID] }

    func dismissNotice(id: UUID, presenterID: UUID) {
        guard notices[presenterID]?.id == id else { return }
        notices.removeValue(forKey: presenterID)
    }

    @discardableResult
    func beginImport(at url: URL, presenterID: UUID) -> UUID? {
        guard let request = begin(.prepareImport, presenterID: presenterID) else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            let result = await operations.prepareImport(at: url)
            guard activeRequest?.id == request.id else {
                if case .ready(let prompt) = result { operations.discardImport(prompt.token) }
                return
            }
            let cancelled = activeRequest?.cancellationRequested == true || Task.isCancelled
            switch result {
            case .ready(let prompt):
                if cancelled {
                    operations.discardImport(prompt.token)
                    publish(problem: .init(.cancelled), request: request)
                } else {
                    pendingImport = .init(id: request.id, presenterID: presenterID, prompt: prompt)
                }
            case .failed(let problem), .cancelled(let problem): publish(problem: problem, request: request)
            }
            finish(request.id)
        }
        return request.id
    }

    @discardableResult
    func confirmImport(promptID: UUID, presenterID: UUID) -> UUID? {
        guard activeRequest == nil, let pending = pendingImport,
              pending.id == promptID, pending.presenterID == presenterID else { return nil }
        pendingImport = nil
        let request = Request(id: UUID(), presenterID: presenterID, operation: .commitImport)
        activeRequest = request
        task = Task { [weak self] in
            guard let self else { return }
            let result = await operations.commitImport(pending.prompt.token)
            guard activeRequest?.id == request.id else { return }
            switch result {
            case .committed(let evidence):
                publish(request: request, kind: evidence.requiresAttention ? .warning : .success,
                    title: evidence.requiresAttention ? "Library replaced; follow-up required" : "Known People library replaced",
                    detail: evidence.detail, recovery: evidence.recoveryURLs)
            case .failed(let problem), .cancelled(let problem): publish(problem: problem, request: request)
            }
            finish(request.id)
        }
        return request.id
    }

    func cancelPendingImport(promptID: UUID, presenterID: UUID) {
        guard activeRequest == nil, let pending = pendingImport,
              pending.id == promptID, pending.presenterID == presenterID else { return }
        operations.discardImport(pending.prompt.token)
        pendingImport = nil
    }

    @discardableResult
    func beginExport(to destinationURL: URL, format: KnownPeopleInterchangeFormat,
                     overwrite: Bool, presenterID: UUID) -> UUID? {
        guard let request = begin(.export, presenterID: presenterID) else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            let result = await operations.export(to: destinationURL, format: format, overwrite: overwrite)
            guard activeRequest?.id == request.id else { return }
            switch result {
            case .written(let evidence):
                let warning = evidence.write.requiresAttention || evidence.identityAssignment?.requiresAttention == true
                publish(request: request, kind: warning ? .warning : .success,
                    title: warning ? "Package written; follow-up required" : "Known People package exported",
                    detail: [evidence.write.detail, evidence.identityAssignment?.detail].compactMap { $0 }.joined(separator: "\n"),
                    recovery: evidence.write.recoveryURLs + (evidence.identityAssignment?.recoveryURLs ?? []),
                    identity: evidence.identityAssignment)
            case .failed(let problem), .cancelled(let problem), .requiresDirectory(let problem):
                publish(problem: problem, request: request)
            }
            finish(request.id)
        }
        return request.id
    }

    func cancelActiveRequest() {
        guard activeRequest != nil else { return }
        activeRequest?.cancellationRequested = true
        task?.cancel()
    }

    func waitForCurrentRequest() async { await task?.value }

    private func begin(_ operation: Request.Operation, presenterID: UUID) -> Request? {
        guard !isBusy else { return nil }
        let request = Request(id: UUID(), presenterID: presenterID, operation: operation)
        if case .unavailable(let reason) = availability {
            publish(problem: .init(.unavailable(reason)), request: request)
            return nil
        }
        activeRequest = request
        return request
    }
    private func finish(_ id: UUID) {
        guard activeRequest?.id == id else { return }
        activeRequest = nil; task = nil
    }

    private func publish(problem: KnownPeopleInterchangeProblem, request: Request) {
        let kind: KnownPeopleInterchangeNotice.Kind
        let title: String
        switch problem.category {
        case .cancelled: kind = .cancelled; title = "Operation cancelled"
        case .zipRequiresDirectory: kind = .guidance; title = "Use a directory package for this library"
        case .unavailable(.iCloudEnabled): kind = .guidance; title = "Turn off Known People iCloud sync to use local interchange"
        case .unavailable(.routing): kind = .guidance; title = "Wait for Known People storage routing to finish"
        case .overwriteRequired: kind = .guidance; title = "Confirm replacing the selected export destination"
        default: kind = .failure; title = "Known People interchange did not finish"
        }
        let assigned = problem.identityAssignment?.committed == true
        publish(request: request, kind: assigned ? .warning : kind,
            title: assigned ? "Local library identity assigned; export did not finish" : title,
            detail: [problem.detail, problem.identityAssignment?.detail].compactMap { $0 }.joined(separator: "\n"),
            recovery: problem.recoveryURLs + (problem.identityAssignment?.recoveryURLs ?? []),
            identity: problem.identityAssignment)
    }

    private func publish(request: Request, kind: KnownPeopleInterchangeNotice.Kind, title: String,
                         detail: String?, recovery: [URL], identity: KnownPeopleInterchangeCommitEvidence? = nil) {
        notices[request.presenterID] = .init(id: UUID(), requestID: request.id, presenterID: request.presenterID,
            kind: kind, title: title, detail: detail, recoveryURLs: recovery, identityAssignment: identity)
    }
}
