import Foundation

nonisolated protocol DeliveryReceiptLibraryRepository: Sendable {
    func list() async throws -> [DeliveryReceiptListEntry]
    func read(id: UUID) async throws -> DeliveryReceipt
    func delete(id: UUID) async throws
}

extension DeliveryReceiptRepository: DeliveryReceiptLibraryRepository {}

nonisolated enum DeliveryReceiptActivityStatus: String, Equatable, Sendable {
    case complete
    case warnings
    case incomplete
    case needsReview

    var title: String {
        switch self {
        case .complete: "Complete evidence"
        case .warnings: "Completed with accepted warnings"
        case .incomplete: "Evidence incomplete"
        case .needsReview: "Needs review"
        }
    }
}

/// The compact, privacy-preserving shape exposed to Activity.
///
/// There is deliberately no filename, content hash, source path, credential, or editorial value.
nonisolated struct DeliveryReceiptActivitySummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let batchIdentifier: UUID
    let profileIdentifier: UUID
    let completedAt: Date
    let destinationIdentifier: String
    let destinationPath: String
    let itemCount: Int
    let uploadAcknowledgedCount: Int
    let remoteSizeMatchedCount: Int
    let warningCount: Int
    let status: DeliveryReceiptActivityStatus

    var evidenceSummary: String {
        let itemWord = itemCount == 1 ? "item" : "items"
        return "\(itemCount) \(itemWord) · \(uploadAcknowledgedCount)/\(itemCount) upload acknowledged · \(remoteSizeMatchedCount)/\(itemCount) remote size matched"
    }
}

/// Safe evidence for one anonymous delivered item. Its numeric ID only reflects the receipt's
/// deterministic item ordering; the identifying filename and hashes never leave the model layer.
nonisolated struct DeliveryReceiptActivityItemEvidence: Equatable, Identifiable, Sendable {
    let id: Int
    let status: DeliveryReceiptActivityStatus
    let deliveredByteSize: Int64
    let metadataOutcome: DeliveryMetadataVerificationOutcome
    let controlledFieldIdentifiers: [IPTCMetadataVerificationField]
    let metadataIssueIdentifiers: [String]
    let renderSettings: DeliveryRenderSettings
    let uploadAcknowledgement: DeliveryUploadAcknowledgement
    let remoteStatAcknowledgement: DeliveryRemoteStatAcknowledgement
    let acceptedWarningIdentifiers: [String]
}

/// Full Activity detail, still constrained to the receipt's human-readable privacy contract.
nonisolated struct DeliveryReceiptActivityDetail: Equatable, Identifiable, Sendable {
    let id: UUID
    let batchIdentifier: UUID
    let profileIdentifier: UUID
    let applicationVersion: DeliveryApplicationVersion
    let startedAt: Date
    let completedAt: Date
    let destinationIdentifier: String
    let destinationPath: String
    let transportSecurity: DeliveryTransportSecurity?
    let acceptedWarningIdentifiers: [String]
    let status: DeliveryReceiptActivityStatus
    let items: [DeliveryReceiptActivityItemEvidence]
    let summaryText: String
}

nonisolated enum DeliveryReceiptLibraryError: Error, Equatable, LocalizedError, Sendable {
    case loadFailed(reason: String)
    case detailLoadFailed(receiptID: UUID, reason: String)
    case deleteFailed(receiptID: UUID, reason: String)
    case summaryExportFailed(receiptID: UUID, reason: String)

    var errorDescription: String? {
        switch self {
        case let .loadFailed(reason):
            "Delivery receipts could not be loaded. \(reason)"
        case let .detailLoadFailed(receiptID, reason):
            "Receipt \(receiptID.uuidString.lowercased()) could not be opened. \(reason)"
        case let .deleteFailed(receiptID, reason):
            "Receipt \(receiptID.uuidString.lowercased()) could not be deleted. \(reason)"
        case let .summaryExportFailed(receiptID, reason):
            "The summary for receipt \(receiptID.uuidString.lowercased()) could not be exported. \(reason)"
        }
    }
}

@MainActor
@Observable
final class DeliveryReceiptLibraryModel {
    private(set) var receipts: [DeliveryReceiptActivitySummary] = []
    private(set) var isLoaded = false
    private(set) var isReloading = false
    private(set) var loadingDetailIDs: Set<UUID> = []
    private(set) var deletingReceiptIDs: Set<UUID> = []
    private(set) var details: [UUID: DeliveryReceiptActivityDetail] = [:]
    var error: DeliveryReceiptLibraryError?

    @ObservationIgnored private let repository: any DeliveryReceiptLibraryRepository
    @ObservationIgnored private let summaryGenerator: DeliveryReceiptSummaryGenerator

    init(
        repository: (any DeliveryReceiptLibraryRepository)? = nil,
        summaryGenerator: DeliveryReceiptSummaryGenerator = DeliveryReceiptSummaryGenerator()
    ) {
        self.repository = repository ?? DeliveryReceiptRepository(
            documentURL: AppPaths.applicationSupport
                .appendingPathComponent("DeliveryReceipts", isDirectory: true)
                .appendingPathComponent("receipts.json")
        )
        self.summaryGenerator = summaryGenerator
    }

    /// Reloads every time Activity appears as well as at app launch. A failed refresh keeps the
    /// last good snapshot visible and exposes a typed error instead of turning it into an empty log.
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer {
            isReloading = false
            isLoaded = true
        }
        do {
            let entries = try await repository.list()
            receipts = entries.map(Self.makeSummary).sorted(by: Self.summaryOrder)
            let currentIDs = Set(receipts.map(\.id))
            details = details.filter { currentIDs.contains($0.key) }
            error = nil
        } catch {
            self.error = .loadFailed(reason: Self.reason(for: error))
        }
    }

    func detail(for id: UUID) -> DeliveryReceiptActivityDetail? {
        details[id]
    }

    func loadDetail(id: UUID) async {
        guard details[id] == nil, !loadingDetailIDs.contains(id) else { return }
        loadingDetailIDs.insert(id)
        defer { loadingDetailIDs.remove(id) }
        do {
            details[id] = Self.makeDetail(
                try await repository.read(id: id),
                summaryGenerator: summaryGenerator
            )
            error = nil
        } catch {
            self.error = .detailLoadFailed(receiptID: id, reason: Self.reason(for: error))
        }
    }

    /// The UI requires a confirmation before calling this method. Once persistence confirms the
    /// deletion, the immutable local snapshot can be updated without a second fallible read.
    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard !deletingReceiptIDs.contains(id) else { return false }
        deletingReceiptIDs.insert(id)
        defer { deletingReceiptIDs.remove(id) }
        do {
            try await repository.delete(id: id)
            receipts.removeAll { $0.id == id }
            details[id] = nil
            error = nil
            return true
        } catch {
            self.error = .deleteFailed(receiptID: id, reason: Self.reason(for: error))
            return false
        }
    }

    /// Writes only the repository's human-readable aggregate summary and refuses replacement.
    func exportSummary(id: UUID, to destination: URL) async -> Bool {
        do {
            let text: String
            if let detail = details[id] {
                text = detail.summaryText
            } else {
                let receipt = try await repository.read(id: id)
                text = summaryGenerator.summary(for: receipt)
            }
            // Foundation does not support combining `.atomic` and `.withoutOverwriting`.
            // The latter uses an exclusive create, which is the important safety boundary here:
            // an export can never replace bytes already present at the chosen destination.
            try Data((text + "\n").utf8).write(to: destination, options: .withoutOverwriting)
            error = nil
            return true
        } catch {
            self.error = .summaryExportFailed(receiptID: id, reason: Self.reason(for: error))
            return false
        }
    }

    private nonisolated static func makeSummary(
        _ entry: DeliveryReceiptListEntry
    ) -> DeliveryReceiptActivitySummary {
        let status: DeliveryReceiptActivityStatus
        if entry.uploadAcknowledgedCount < entry.itemCount {
            status = .incomplete
        } else if entry.warningCount > 0 {
            status = .warnings
        } else {
            status = .complete
        }
        return DeliveryReceiptActivitySummary(
            id: entry.id,
            batchIdentifier: entry.batchIdentifier,
            profileIdentifier: entry.profileIdentifier,
            completedAt: entry.completedAt,
            destinationIdentifier: entry.destinationIdentifier,
            destinationPath: entry.destinationPath,
            itemCount: entry.itemCount,
            uploadAcknowledgedCount: entry.uploadAcknowledgedCount,
            remoteSizeMatchedCount: entry.remoteSizeMatchedCount,
            warningCount: entry.warningCount,
            status: status
        )
    }

    private nonisolated static func makeDetail(
        _ receipt: DeliveryReceipt,
        summaryGenerator: DeliveryReceiptSummaryGenerator
    ) -> DeliveryReceiptActivityDetail {
        let items = receipt.deterministicallyOrdered.items.enumerated().map { index, item in
            DeliveryReceiptActivityItemEvidence(
                id: index + 1,
                status: itemStatus(item),
                deliveredByteSize: item.deliveredByteSize,
                metadataOutcome: item.metadataVerification.outcome,
                controlledFieldIdentifiers: item.metadataVerification.controlledFieldIdentifiers,
                metadataIssueIdentifiers: item.metadataVerification.issueIdentifiers,
                renderSettings: item.renderSettings,
                uploadAcknowledgement: item.uploadAcknowledgement,
                remoteStatAcknowledgement: item.remoteStatAcknowledgement,
                acceptedWarningIdentifiers: item.acceptedWarningIdentifiers
            )
        }
        return DeliveryReceiptActivityDetail(
            id: receipt.id,
            batchIdentifier: receipt.batchIdentifier,
            profileIdentifier: receipt.profileIdentifier,
            applicationVersion: receipt.applicationVersion,
            startedAt: receipt.startedAt,
            completedAt: receipt.completedAt,
            destinationIdentifier: receipt.destination.identifier,
            destinationPath: receipt.destination.path,
            transportSecurity: receipt.destination.transportSecurity,
            acceptedWarningIdentifiers: receipt.acceptedWarningIdentifiers,
            status: detailStatus(
                items,
                acceptedWarningIdentifiers: receipt.acceptedWarningIdentifiers
            ),
            items: items,
            summaryText: summaryGenerator.summary(for: receipt)
        )
    }

    private nonisolated static func itemStatus(
        _ item: DeliveryReceiptItem
    ) -> DeliveryReceiptActivityStatus {
        if item.metadataVerification.outcome == .failed
            || item.uploadAcknowledgement.status == .rejected
            || item.remoteStatAcknowledgement.status == .doesNotMatchDeliveredByteSize {
            return .needsReview
        }
        if !item.acceptedWarningIdentifiers.isEmpty
            || item.metadataVerification.outcome == .verifiedWithWarnings {
            return .warnings
        }
        if item.metadataVerification.outcome == .notPerformed
            || item.uploadAcknowledgement.status == .notAttempted {
            return .incomplete
        }
        return .complete
    }

    private nonisolated static func detailStatus(
        _ items: [DeliveryReceiptActivityItemEvidence],
        acceptedWarningIdentifiers: [String]
    ) -> DeliveryReceiptActivityStatus {
        if items.contains(where: { $0.status == .needsReview }) { return .needsReview }
        if items.contains(where: { $0.status == .incomplete }) { return .incomplete }
        if !acceptedWarningIdentifiers.isEmpty
            || items.contains(where: { $0.status == .warnings }) {
            return .warnings
        }
        return .complete
    }

    private nonisolated static func summaryOrder(
        _ lhs: DeliveryReceiptActivitySummary,
        _ rhs: DeliveryReceiptActivitySummary
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private nonisolated static func reason(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}
