import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery receipt Activity library")
@MainActor
struct DeliveryReceiptLibraryModelTests {
    @Test("reload publishes deterministic privacy-preserving summaries")
    func deterministicSummaries() async {
        let earlierID = testUUID("10000000-0000-0000-0000-000000000001")
        let laterTieA = testUUID("20000000-0000-0000-0000-000000000001")
        let laterTieB = testUUID("20000000-0000-0000-0000-000000000002")
        let entries = [
            makeEntry(id: laterTieB, completedAt: testInstant(20), warnings: 2),
            makeEntry(id: earlierID, completedAt: testInstant(10), remoteMatches: 0),
            makeEntry(id: laterTieA, completedAt: testInstant(20), uploads: 0),
        ]
        let repository = ReceiptLibraryStub(entries: entries)
        let model = DeliveryReceiptLibraryModel(repository: repository)

        await model.reload()

        #expect(model.receipts.map(\.id) == [laterTieA, laterTieB, earlierID])
        #expect(model.receipts.map(\.status) == [.incomplete, .warnings, .complete])
        #expect(model.receipts[0].evidenceSummary == "1 item · 0/1 upload acknowledged · 1/1 remote size matched")
        #expect(model.isLoaded)
        #expect(model.error == nil)
    }

    @Test("optional remote-stat evidence does not downgrade an acknowledged delivery")
    func optionalRemoteStatIsNeutral() async throws {
        let receipt = makeActivityReceipt(
            filename: "private-source-name.jpg",
            metadataOutcome: .verified,
            warnings: [],
            remoteStatus: .notRequested
        )
        let repository = ReceiptLibraryStub(
            entries: [entry(for: receipt)],
            receipts: [receipt.id: receipt]
        )
        let model = DeliveryReceiptLibraryModel(repository: repository)

        await model.reload()
        await model.loadDetail(id: receipt.id)

        #expect(model.receipts.first?.status == .complete)
        let detail = try #require(model.detail(for: receipt.id))
        #expect(detail.items.first?.status == .complete)
        #expect(detail.status == .complete)
    }

    @Test("detail exposes evidence but never filenames, hashes, source paths, or editorial values")
    func safeDetailProjection() async throws {
        let receipt = makeActivityReceipt(filename: "private-source-name.jpg")
        let repository = ReceiptLibraryStub(
            entries: [entry(for: receipt)],
            receipts: [receipt.id: receipt]
        )
        let model = DeliveryReceiptLibraryModel(repository: repository)

        await model.reload()
        await model.loadDetail(id: receipt.id)

        let detail = try #require(model.detail(for: receipt.id))
        #expect(detail.items.map(\.id) == [1])
        #expect(detail.items[0].metadataOutcome == .verifiedWithWarnings)
        #expect(
            detail.items[0].controlledFieldIdentifiers == [
                .captureDate,
                .creatorContactInfo,
                .description,
                .headline,
                .label,
                .latitude,
                .locationsCreated,
                .rating,
            ]
        )
        #expect(detail.items[0].status == .warnings)
        #expect(detail.acceptedWarningIdentifiers == ["warning.accepted"])
        #expect(detail.status == .warnings)

        let reflected = String(reflecting: detail).lowercased()
        #expect(!reflected.contains("private-source-name.jpg"))
        #expect(!reflected.contains(String(repeating: "a", count: 64)))
        #expect(!reflected.contains(String(repeating: "b", count: 64)))
        #expect(!reflected.contains("a sensitive caption"))
        #expect(!detail.summaryText.contains("private-source-name.jpg"))
    }

    @Test("list and detail failures remain typed and preserve the last good snapshot")
    func typedLoadFailures() async {
        let id = testUUID("30000000-0000-0000-0000-000000000001")
        let repository = ReceiptLibraryStub(entries: [makeEntry(id: id)])
        let model = DeliveryReceiptLibraryModel(repository: repository)

        await model.reload()
        await repository.setListFailure(.catalogUnavailable)
        await model.reload()

        #expect(model.receipts.map(\.id) == [id])
        #expect(model.error == .loadFailed(reason: "catalog unavailable"))

        await repository.setListFailure(nil)
        await repository.setReadFailure(.receiptUnavailable)
        model.error = nil
        await model.loadDetail(id: id)
        #expect(
            model.error == .detailLoadFailed(
                receiptID: id,
                reason: "receipt unavailable"
            )
        )
    }

    @Test("manual delete updates only after persistence succeeds and reports typed failure")
    func manualDelete() async {
        let id = testUUID("40000000-0000-0000-0000-000000000001")
        let successRepository = ReceiptLibraryStub(entries: [makeEntry(id: id)])
        let successModel = DeliveryReceiptLibraryModel(repository: successRepository)
        await successModel.reload()

        #expect(await successModel.delete(id: id))
        #expect(successModel.receipts.isEmpty)
        #expect(await successRepository.deletedReceiptIDs() == [id])

        let failureRepository = ReceiptLibraryStub(
            entries: [makeEntry(id: id)],
            deleteFailure: .deleteDenied
        )
        let failureModel = DeliveryReceiptLibraryModel(repository: failureRepository)
        await failureModel.reload()

        #expect(!(await failureModel.delete(id: id)))
        #expect(failureModel.receipts.map(\.id) == [id])
        #expect(
            failureModel.error == .deleteFailed(
                receiptID: id,
                reason: "delete denied"
            )
        )
    }

    @Test("summary export is privacy-safe and never overwrites an existing file")
    func summaryExportNoOverwrite() async throws {
        let receipt = makeActivityReceipt(filename: "embargoed-final.jpg")
        let repository = ReceiptLibraryStub(
            entries: [entry(for: receipt)],
            receipts: [receipt.id: receipt]
        )
        let model = DeliveryReceiptLibraryModel(repository: repository)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "receipt-activity-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("existing.txt")
        try Data("keep me".utf8).write(to: existing)
        #expect(!(await model.exportSummary(id: receipt.id, to: existing)))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
        guard case let .summaryExportFailed(failedID, _) = model.error else {
            Issue.record("Expected a typed summary export error")
            return
        }
        #expect(failedID == receipt.id)

        let destination = directory.appendingPathComponent("summary.txt")
        #expect(await model.exportSummary(id: receipt.id, to: destination))
        let summary = try String(contentsOf: destination, encoding: .utf8)
        #expect(summary.contains("Items: 1"))
        #expect(summary.contains(receipt.destination.identifier))
        #expect(!summary.contains("embargoed-final.jpg"))
        #expect(!summary.contains(String(repeating: "a", count: 64)))
        #expect(!summary.contains(String(repeating: "b", count: 64)))
    }

    @Test("pre-cancelled summary export leaves no destination and reports cancellation")
    func summaryExportPreCancellation() async throws {
        let receipt = makeActivityReceipt(filename: "cancelled-source.jpg")
        let repository = ReceiptLibraryStub(receipts: [receipt.id: receipt])
        let model = DeliveryReceiptLibraryModel(repository: repository)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "receipt-activity-cancelled-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("summary.txt")

        let export = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.exportSummary(id: receipt.id, to: destination)
        }

        #expect(!(await export.value))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(model.error == .summaryExportCancelled(receiptID: receipt.id))
    }

    @Test("summary writer returns immutable commit evidence")
    func summaryWriterCommitEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "receipt-summary-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("summary.txt")
        let boundary = DeliveryReceiptSummaryExportBoundary()

        let result = try await boundary.write("Summary", to: destination)

        #expect(result == .committed(DeliveryReceiptSummaryExportCommit(
            destinationURL: destination,
            byteCount: 8,
            cancellationRequestedAfterCommit: false
        )))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Summary\n")
    }

    @Test("overlapping summary writes serialize off-main and cancellation stops queued work")
    func summaryWriterSerializationAndQueuedCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "receipt-summary-serialized-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BlockingReceiptSummaryWriter()
        let boundary = DeliveryReceiptSummaryExportBoundary(writer: DeliveryReceiptSummaryFileWriter(
            write: { data, destination in
                try probe.write(data, to: destination)
            }
        ))
        let firstDestination = directory.appendingPathComponent("first.txt")
        let secondDestination = directory.appendingPathComponent("second.txt")
        let first = Task {
            try await boundary.write("First", to: firstDestination)
        }
        try await probe.waitUntilFirstWriteStarts()
        let second = Task {
            try await boundary.write("Second", to: secondDestination)
        }
        second.cancel()
        probe.releaseFirstWrite()

        let firstResult = try await first.value
        let secondResult = try await second.value

        guard case .committed(let commit) = firstResult else {
            Issue.record("Expected the first summary to commit")
            return
        }
        #expect(commit.destinationURL == firstDestination)
        #expect(secondResult == .cancelledBeforeWrite)
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentWrites == 1)
        #expect(!probe.ranOnMainThread)
        #expect(try String(contentsOf: firstDestination, encoding: .utf8) == "First\n")
        #expect(!FileManager.default.fileExists(atPath: secondDestination.path))
    }

    @Test("cancellation during the synchronous summary commit reports durable success")
    func summaryWriterCancellationAfterCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "receipt-summary-durable-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("summary.txt")
        let boundary = DeliveryReceiptSummaryExportBoundary(writer: DeliveryReceiptSummaryFileWriter(
            write: { data, destination in
                try data.write(to: destination, options: .withoutOverwriting)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        ))
        let task = Task {
            try await boundary.write("Durable", to: destination)
        }

        let result = try await task.value

        #expect(result == .committed(DeliveryReceiptSummaryExportCommit(
            destinationURL: destination,
            byteCount: 8,
            cancellationRequestedAfterCommit: true
        )))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Durable\n")
    }

    @Test("a superseded export failure cannot replace the latest result")
    func staleSummaryExportFailureIsIgnored() async throws {
        let receipt = makeActivityReceipt(filename: "stale-export.jpg")
        let repository = ReceiptLibraryStub(receipts: [receipt.id: receipt])
        let exporter = ControllableReceiptSummaryExporter()
        let model = DeliveryReceiptLibraryModel(
            repository: repository,
            summaryExporter: exporter
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "receipt-summary-stale-result-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staleDestination = directory.appendingPathComponent("stale.txt")
        let latestDestination = directory.appendingPathComponent("latest.txt")

        let stale = Task { @MainActor in
            await model.exportSummary(id: receipt.id, to: staleDestination)
        }
        try await exporter.waitForInvocationCount(1)
        let latest = Task { @MainActor in
            await model.exportSummary(id: receipt.id, to: latestDestination)
        }
        try await exporter.waitForInvocationCount(2)
        await exporter.complete(
            destination: latestDestination,
            with: .success(.committed(DeliveryReceiptSummaryExportCommit(
                destinationURL: latestDestination,
                byteCount: 7,
                cancellationRequestedAfterCommit: false
            )))
        )
        #expect(await latest.value)
        await exporter.complete(
            destination: staleDestination,
            with: .failure(ReceiptLibraryStubError.exportDenied)
        )

        #expect(!(await stale.value))
        #expect(model.error == nil)
    }
}

private enum ReceiptLibraryStubError: Error, LocalizedError, Sendable {
    case catalogUnavailable
    case receiptUnavailable
    case deleteDenied
    case exportDenied

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable: "catalog unavailable"
        case .receiptUnavailable: "receipt unavailable"
        case .deleteDenied: "delete denied"
        case .exportDenied: "export denied"
        }
    }
}

private enum ReceiptSummaryWriterProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingReceiptSummaryWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var writeCount = 0
    private var activeWrites = 0
    private var maximumActiveWrites = 0
    private var firstWriteReleased = false
    private var observedMainThread = false

    func write(_ data: Data, to destination: URL) throws {
        condition.lock()
        writeCount += 1
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        observedMainThread = observedMainThread || Thread.isMainThread
        condition.broadcast()
        if writeCount == 1 {
            while !firstWriteReleased {
                condition.wait()
            }
        }
        activeWrites -= 1
        condition.unlock()
        try data.write(to: destination, options: .withoutOverwriting)
    }

    func waitUntilFirstWriteStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw ReceiptSummaryWriterProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstWrite() {
        condition.lock()
        firstWriteReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return writeCount
    }

    var maximumConcurrentWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveWrites
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedMainThread
    }
}

private actor ControllableReceiptSummaryExporter: DeliveryReceiptSummaryExporting {
    private var continuations: [URL: CheckedContinuation<DeliveryReceiptSummaryExportResult, any Error>] = [:]
    private var invocationCount = 0

    func write(
        _ text: String,
        to destination: URL
    ) async throws -> DeliveryReceiptSummaryExportResult {
        _ = text
        invocationCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[destination] = continuation
        }
    }

    func waitForInvocationCount(_ expectedCount: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount < expectedCount {
            guard ContinuousClock.now < deadline else {
                throw ReceiptSummaryWriterProbeError.timedOut
            }
            await Task.yield()
        }
    }

    func complete(
        destination: URL,
        with result: Result<DeliveryReceiptSummaryExportResult, any Error>
    ) {
        guard let continuation = continuations.removeValue(forKey: destination) else {
            Issue.record("No suspended receipt export for \(destination.lastPathComponent)")
            return
        }
        continuation.resume(with: result)
    }
}

private actor ReceiptLibraryStub: DeliveryReceiptLibraryRepository {
    private var entries: [DeliveryReceiptListEntry]
    private var receipts: [UUID: DeliveryReceipt]
    private var listFailure: ReceiptLibraryStubError?
    private var readFailure: ReceiptLibraryStubError?
    private var deleteFailure: ReceiptLibraryStubError?
    private var deletedIDs: [UUID] = []

    init(
        entries: [DeliveryReceiptListEntry] = [],
        receipts: [UUID: DeliveryReceipt] = [:],
        listFailure: ReceiptLibraryStubError? = nil,
        readFailure: ReceiptLibraryStubError? = nil,
        deleteFailure: ReceiptLibraryStubError? = nil
    ) {
        self.entries = entries
        self.receipts = receipts
        self.listFailure = listFailure
        self.readFailure = readFailure
        self.deleteFailure = deleteFailure
    }

    func list() async throws -> [DeliveryReceiptListEntry] {
        if let listFailure { throw listFailure }
        return entries
    }

    func read(id: UUID) async throws -> DeliveryReceipt {
        if let readFailure { throw readFailure }
        guard let receipt = receipts[id] else {
            throw DeliveryReceiptRepositoryError.receiptNotFound(id)
        }
        return receipt
    }

    func delete(id: UUID) async throws {
        if let deleteFailure { throw deleteFailure }
        deletedIDs.append(id)
        entries.removeAll { $0.id == id }
        receipts[id] = nil
    }

    func setListFailure(_ failure: ReceiptLibraryStubError?) {
        listFailure = failure
    }

    func setReadFailure(_ failure: ReceiptLibraryStubError?) {
        readFailure = failure
    }

    func deletedReceiptIDs() -> [UUID] {
        deletedIDs
    }
}

private func makeEntry(
    id: UUID,
    completedAt: Date = testInstant(10),
    uploads: Int = 1,
    remoteMatches: Int = 1,
    warnings: Int = 0
) -> DeliveryReceiptListEntry {
    DeliveryReceiptListEntry(
        id: id,
        batchIdentifier: testUUID("50000000-0000-0000-0000-000000000001"),
        profileIdentifier: testUUID("60000000-0000-0000-0000-000000000001"),
        completedAt: completedAt,
        destinationIdentifier: "70000000-0000-0000-0000-000000000001",
        destinationPath: "/incoming/wire",
        itemCount: 1,
        uploadAcknowledgedCount: uploads,
        remoteSizeMatchedCount: remoteMatches,
        warningCount: warnings
    )
}

private func entry(for receipt: DeliveryReceipt) -> DeliveryReceiptListEntry {
    DeliveryReceiptListEntry(
        id: receipt.id,
        batchIdentifier: receipt.batchIdentifier,
        profileIdentifier: receipt.profileIdentifier,
        completedAt: receipt.completedAt,
        destinationIdentifier: receipt.destination.identifier,
        destinationPath: receipt.destination.path,
        itemCount: receipt.items.count,
        uploadAcknowledgedCount: receipt.items.count {
            $0.uploadAcknowledgement.status == .protocolAcknowledged
        },
        remoteSizeMatchedCount: receipt.items.count {
            $0.remoteStatAcknowledgement.status == .matchesDeliveredByteSize
        },
        warningCount: receipt.acceptedWarningIdentifiers.count
    )
}

private func makeActivityReceipt(
    filename: String,
    metadataOutcome: DeliveryMetadataVerificationOutcome = .verifiedWithWarnings,
    warnings: [String] = ["warning.accepted"],
    remoteStatus: DeliveryRemoteStatAcknowledgement.Status = .matchesDeliveredByteSize
) -> DeliveryReceipt {
    let completedAt = testInstant(30)
    let remoteAcknowledgement: DeliveryRemoteStatAcknowledgement
    switch remoteStatus {
    case .notRequested:
        remoteAcknowledgement = DeliveryRemoteStatAcknowledgement(status: .notRequested)
    case .unavailable:
        remoteAcknowledgement = DeliveryRemoteStatAcknowledgement(
            status: .unavailable,
            checkedAt: completedAt.addingTimeInterval(-4)
        )
    case .matchesDeliveredByteSize:
        remoteAcknowledgement = DeliveryRemoteStatAcknowledgement(
            status: .matchesDeliveredByteSize,
            checkedAt: completedAt.addingTimeInterval(-4),
            observedByteSize: 800
        )
    case .doesNotMatchDeliveredByteSize:
        remoteAcknowledgement = DeliveryRemoteStatAcknowledgement(
            status: .doesNotMatchDeliveredByteSize,
            checkedAt: completedAt.addingTimeInterval(-4),
            observedByteSize: 799
        )
    }
    return DeliveryReceipt(
        id: testUUID("80000000-0000-0000-0000-000000000001"),
        batchIdentifier: testUUID("90000000-0000-0000-0000-000000000001"),
        profileIdentifier: testUUID("a0000000-0000-0000-0000-000000000001"),
        applicationVersion: DeliveryApplicationVersion(
            marketingVersion: "3.0.0",
            buildNumber: "900"
        ),
        startedAt: completedAt.addingTimeInterval(-10),
        completedAt: completedAt,
        destination: DeliveryReceiptDestination(
            identifier: "b0000000-0000-0000-0000-000000000001",
            path: "/incoming/wire"
        ),
        acceptedWarningIdentifiers: warnings,
        items: [
            DeliveryReceiptItem(
                sourceIdentity: DeliveryReceiptSourceIdentity(
                    sha256: String(repeating: "a", count: 64),
                    byteSize: 900
                ),
                deliveredFilename: filename,
                deliveredSHA256: String(repeating: "b", count: 64),
                deliveredByteSize: 800,
                metadataVerification: DeliveryMetadataVerificationResult(
                    outcome: metadataOutcome,
                    controlledFieldIdentifiers: [
                        .headline,
                        .description,
                        .captureDate,
                        .creatorContactInfo,
                        .locationsCreated,
                        .latitude,
                        .rating,
                        .label,
                    ],
                    issueIdentifiers: metadataOutcome == .verifiedWithWarnings
                        ? ["metadata.readback.normalized"]
                        : []
                ),
                renderSettings: DeliveryRenderSettings(
                    formatIdentifier: "public.jpeg",
                    colorSpaceIdentifier: "sRGB",
                    pixelWidth: 2_400,
                    pixelHeight: 1_600,
                    bitDepth: 8,
                    quality: 90
                ),
                uploadAcknowledgement: DeliveryUploadAcknowledgement(
                    status: .protocolAcknowledged,
                    acknowledgedAt: completedAt.addingTimeInterval(-5)
                ),
                remoteStatAcknowledgement: remoteAcknowledgement,
                acceptedWarningIdentifiers: warnings
            ),
        ]
    )
}

private func testInstant(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_900_000_000 + offset)
}

private func testUUID(_ value: String) -> UUID {
    UUID(uuidString: value)!
}
