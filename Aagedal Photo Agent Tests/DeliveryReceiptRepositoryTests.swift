import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery receipts")
struct DeliveryReceiptRepositoryTests {
    @Test("Render evidence preserves a byte ceiling while legacy evidence defaults to no limit")
    func renderSettingsMaximumOutputMigration() throws {
        let limited = DeliveryRenderSettings(
            formatIdentifier: "jpeg",
            colorSpaceIdentifier: "sRGB",
            pixelWidth: 4_000,
            pixelHeight: 2_667,
            bitDepth: 8,
            quality: 90,
            maximumOutputByteCount: 2_500_000
        )
        let encoded = try JSONEncoder().encode(limited)
        #expect(try JSONDecoder().decode(DeliveryRenderSettings.self, from: encoded) == limited)

        let legacy = Data(#"""
        {
          "formatIdentifier":"jpeg",
          "colorSpaceIdentifier":"sRGB",
          "pixelWidth":4000,
          "pixelHeight":2667,
          "bitDepth":8,
          "quality":90
        }
        """#.utf8)
        #expect(try JSONDecoder().decode(DeliveryRenderSettings.self, from: legacy)
            .maximumOutputByteCount == nil)
    }

    @Test("receipt JSON is deterministic, versioned, and contains no editorial values or credentials")
    func privacyAndDeterministicCoding() throws {
        let receipt = makeReceipt(
            itemNames: ["zulu.jpg", "alpha.jpg"],
            warnings: ["warning.z", "warning.a"]
        ).deterministicallyOrdered
        try receipt.validateForPersistence()

        let data = try encode(receipt)
        let decoded = try decode(DeliveryReceipt.self, from: data)
        #expect(decoded == receipt)
        #expect(decoded.schemaVersion == DeliveryReceipt.currentSchemaVersion)
        #expect(decoded.items.map(\.deliveredFilename) == ["alpha.jpg", "zulu.jpg"])
        #expect(decoded.items.allSatisfy {
            $0.acceptedWarningIdentifiers == ["warning.a", "warning.z"]
        })

        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("a sensitive caption"))
        #expect(!json.contains("private person"))
        #expect(!json.contains("secret location"))
        #expect(!json.contains("password"))
        #expect(!json.contains("credential"))
        #expect(!json.contains("sourcefilename"))
        #expect(!json.contains("sourcepath"))
    }

    @Test("summary is concise and omits hashes, filenames, and metadata values")
    func privacyPreservingSummary() {
        let receipt = makeReceipt(
            itemNames: ["wire-a.jpg", "wire-b.jpg"],
            warnings: ["warning.shared"]
        )
        let summary = DeliveryReceiptSummaryGenerator().summary(for: receipt)

        #expect(summary.contains("Items: 2"))
        #expect(summary.contains("upload acknowledged: 2"))
        #expect(summary.contains("remote size matched: 2"))
        #expect(summary.contains("accepted warnings: 1"))
        #expect(summary.contains(receipt.destination.identifier))
        #expect(!summary.contains(String(repeating: "a", count: 64)))
        #expect(!summary.contains(String(repeating: "b", count: 64)))
        #expect(!summary.contains("wire.jpg"))
    }

    @Test("validation rejects path-like filenames and incoherent acknowledgements")
    func strictEvidenceValidation() throws {
        let pathItem = makeItem(filename: "folder/wire.jpg")
        let pathReceipt = makeReceipt(items: [pathItem])
        #expect(throws: DeliveryReceiptValidationError.invalidDeliveredFilename("folder/wire.jpg")) {
            try pathReceipt.validateForPersistence()
        }

        let incoherentItem = DeliveryReceiptItem(
            sourceIdentity: DeliveryReceiptSourceIdentity(
                sha256: String(repeating: "a", count: 64),
                byteSize: 900
            ),
            deliveredFilename: "wire.jpg",
            deliveredSHA256: String(repeating: "b", count: 64),
            deliveredByteSize: 800,
            metadataVerification: DeliveryMetadataVerificationResult(outcome: .verified),
            renderSettings: defaultRenderSettings,
            uploadAcknowledgement: DeliveryUploadAcknowledgement(
                status: .protocolAcknowledged
            ),
            remoteStatAcknowledgement: DeliveryRemoteStatAcknowledgement(
                status: .matchesDeliveredByteSize,
                checkedAt: instant(15),
                observedByteSize: 799
            )
        )
        let receipt = makeReceipt(items: [incoherentItem])
        #expect(throws: DeliveryReceiptValidationError.incoherentUploadAcknowledgement) {
            try receipt.validateForPersistence()
        }
    }

    @Test("destination identifiers accept only canonical UUIDs, never URLs or query tokens")
    func destinationIdentifierCannotCarryCredentials() {
        let base = makeReceipt()
        for identifier in [
            "https://desk.example/upload?token=secret",
            "ftp://user:password@desk.example",
            uuid("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").uuidString,
        ] {
            let receipt = DeliveryReceipt(
                id: base.id,
                batchIdentifier: base.batchIdentifier,
                profileIdentifier: base.profileIdentifier,
                applicationVersion: base.applicationVersion,
                startedAt: base.startedAt,
                completedAt: base.completedAt,
                destination: DeliveryReceiptDestination(
                    identifier: identifier,
                    path: "/incoming/wire"
                ),
                acceptedWarningIdentifiers: base.acceptedWarningIdentifiers,
                items: base.items
            )
            #expect(throws: DeliveryReceiptValidationError.invalidDestinationIdentifier) {
                try receipt.validateForPersistence()
            }
        }
    }

    @Test("record, deterministic list, read, and manual delete preserve stable identities")
    func repositoryLifecycle() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)
        let older = makeReceipt(
            receiptID: uuid("10000000-0000-0000-0000-000000000001"),
            batchID: uuid("20000000-0000-0000-0000-000000000001"),
            completedAt: instant(20),
            itemNames: ["older.jpg"]
        )
        let newer = makeReceipt(
            receiptID: uuid("10000000-0000-0000-0000-000000000002"),
            batchID: uuid("20000000-0000-0000-0000-000000000002"),
            completedAt: instant(30),
            itemNames: ["newer-a.jpg", "newer-b.jpg"]
        )

        try await repository.record(older, now: instant(30))
        try await repository.record(newer, now: instant(30))

        let entries = try await repository.list()
        #expect(entries.map(\.id) == [newer.id, older.id])
        #expect(entries.first?.itemCount == 2)
        #expect(entries.first?.uploadAcknowledgedCount == 2)
        #expect(entries.first?.warningCount == 1)
        #expect(try await repository.read(id: older.id) == older.deterministicallyOrdered)

        try await repository.delete(id: older.id)
        #expect(try await repository.list().map(\.id) == [newer.id])
        await #expect(throws: DeliveryReceiptRepositoryError.receiptNotFound(older.id)) {
            _ = try await repository.read(id: older.id)
        }
    }

    @Test("count and age retention are deterministic and can be applied explicitly")
    func retention() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let repository = DeliveryReceiptRepository(
            documentURL: fixture.documentURL,
            retentionPolicy: DeliveryReceiptRetentionPolicy(
                maximumReceiptCount: 2,
                maximumAgeDays: 10
            )
        )
        let first = makeReceipt(
            receiptID: uuid("30000000-0000-0000-0000-000000000001"),
            batchID: uuid("40000000-0000-0000-0000-000000000001"),
            completedAt: day(0),
            itemNames: ["one.jpg"]
        )
        let second = makeReceipt(
            receiptID: uuid("30000000-0000-0000-0000-000000000002"),
            batchID: uuid("40000000-0000-0000-0000-000000000002"),
            completedAt: day(12),
            itemNames: ["two.jpg"]
        )
        let third = makeReceipt(
            receiptID: uuid("30000000-0000-0000-0000-000000000003"),
            batchID: uuid("40000000-0000-0000-0000-000000000003"),
            completedAt: day(15),
            itemNames: ["three.jpg"]
        )

        try await repository.record(first, now: day(0))
        try await repository.record(second, now: day(12))
        try await repository.record(third, now: day(15))
        #expect(try await repository.list().map(\.id) == [third.id, second.id])

        let removed = try await repository.enforceRetention(now: day(30))
        #expect(removed == 2)
        #expect(try await repository.list().isEmpty)
    }

    @Test("duplicate receipt and batch identities never overwrite stored bytes")
    func duplicateNoOverwrite() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)
        let first = makeReceipt(itemNames: ["first.jpg"])
        try await repository.record(first, now: first.completedAt)
        let original = try Data(contentsOf: fixture.documentURL)

        await #expect(throws: DeliveryReceiptRepositoryError.receiptAlreadyExists(first.id)) {
            try await repository.record(first, now: first.completedAt)
        }
        #expect(try Data(contentsOf: fixture.documentURL) == original)

        let duplicateBatch = makeReceipt(
            receiptID: UUID(),
            batchID: first.batchIdentifier,
            itemNames: ["replacement.jpg"]
        )
        await #expect(
            throws: DeliveryReceiptRepositoryError.duplicateBatchIdentifier(first.batchIdentifier)
        ) {
            try await repository.record(duplicateBatch, now: duplicateBatch.completedAt)
        }
        #expect(try Data(contentsOf: fixture.documentURL) == original)
    }

    @Test("concurrent receipt records serialize the complete read-modify-write transaction")
    func concurrentRecordsRetainEveryReceipt() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)
        let receipts = (0..<32).map { index in
            makeReceipt(
                receiptID: UUID(),
                batchID: UUID(),
                completedAt: instant(TimeInterval(100 + index)),
                itemNames: ["wire-\(index).jpg"]
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for receipt in receipts {
                group.addTask {
                    try await repository.record(receipt, now: instant(1_000))
                }
            }
            try await group.waitForAll()
        }

        let persistedIDs = Set(try await repository.list().map(\.id))
        #expect(persistedIDs == Set(receipts.map(\.id)))
    }

    @Test("version one catalogs and receipts migrate atomically to current schemas")
    func legacyMigration() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let receipt = makeReceipt(itemNames: ["legacy.jpg"])
        try fixture.writeCatalog(schemaVersion: 1, receipts: [receipt], receiptSchemaVersion: 1)

        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)
        #expect(try await repository.list().map(\.id) == [receipt.id])

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.documentURL))
                as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 2)
        let receipts = try #require(object["receipts"] as? [[String: Any]])
        #expect(receipts.first?["schemaVersion"] as? Int == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }

    @Test("newer catalog fails closed and remains byte-for-byte intact")
    func newerCatalogNoOverwrite() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let future = Data(#"{"schemaVersion":99,"receipts":[],"future":{"keep":true}}"#.utf8)
        try future.write(to: fixture.documentURL)
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)

        await #expect(
            throws: AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                found: 99,
                supported: 2
            )
        ) {
            try await repository.record(makeReceipt(), now: instant(20))
        }
        #expect(try Data(contentsOf: fixture.documentURL) == future)
    }

    @Test("a newer nested receipt is rejected without rewriting its catalog")
    func newerReceiptNoOverwrite() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        try fixture.writeCatalog(
            schemaVersion: 2,
            receipts: [makeReceipt()],
            receiptSchemaVersion: 99
        )
        let original = try Data(contentsOf: fixture.documentURL)
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)

        await #expect(
            throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "delivery receipt",
                found: 99,
                supported: 2
            )
        ) {
            _ = try await repository.list()
        }
        #expect(try Data(contentsOf: fixture.documentURL) == original)
    }

    @Test("a newer nested receipt is never downgraded through an older valid backup")
    func newerReceiptCannotFallBackToBackup() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)
        let first = makeReceipt(
            receiptID: uuid("b0000000-0000-0000-0000-000000000001"),
            batchID: uuid("c0000000-0000-0000-0000-000000000001"),
            itemNames: ["first.jpg"]
        )
        let second = makeReceipt(
            receiptID: uuid("b0000000-0000-0000-0000-000000000002"),
            batchID: uuid("c0000000-0000-0000-0000-000000000002"),
            itemNames: ["second.jpg"]
        )
        try await repository.record(first, now: first.completedAt)
        try await repository.record(second, now: second.completedAt)
        let backup = try Data(contentsOf: fixture.backupURL)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.documentURL))
                as? [String: Any]
        )
        var receipts = try #require(object["receipts"] as? [[String: Any]])
        receipts[0]["schemaVersion"] = 99
        object["receipts"] = receipts
        let future = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try future.write(to: fixture.documentURL)

        await #expect(
            throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "delivery receipt",
                found: 99,
                supported: 2
            )
        ) {
            try await repository.record(
                makeReceipt(receiptID: UUID(), batchID: UUID()),
                now: instant(20)
            )
        }
        #expect(try Data(contentsOf: fixture.documentURL) == future)
        #expect(try Data(contentsOf: fixture.backupURL) == backup)
    }

    @Test("corrupt primary recovers the last valid bounded backup without rewriting files")
    func corruptRecovery() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let repository = DeliveryReceiptRepository(documentURL: fixture.documentURL)
        let first = makeReceipt(
            receiptID: uuid("50000000-0000-0000-0000-000000000001"),
            batchID: uuid("60000000-0000-0000-0000-000000000001"),
            itemNames: ["first.jpg"]
        )
        let second = makeReceipt(
            receiptID: uuid("50000000-0000-0000-0000-000000000002"),
            batchID: uuid("60000000-0000-0000-0000-000000000002"),
            itemNames: ["second.jpg"]
        )
        try await repository.record(first, now: first.completedAt)
        try await repository.record(second, now: second.completedAt)
        let backup = try Data(contentsOf: fixture.backupURL)
        try Data("{".utf8).write(to: fixture.documentURL)

        let recovered = try await repository.list()
        #expect(recovered.map(\.id) == [first.id])
        #expect(try Data(contentsOf: fixture.documentURL) == Data("{".utf8))
        #expect(try Data(contentsOf: fixture.backupURL) == backup)
    }
}

private let defaultRenderSettings = DeliveryRenderSettings(
    formatIdentifier: "public.jpeg",
    colorSpaceIdentifier: "sRGB",
    pixelWidth: 2_400,
    pixelHeight: 1_600,
    bitDepth: 8,
    quality: 90
)

private func makeReceipt(
    receiptID: UUID = uuid("70000000-0000-0000-0000-000000000001"),
    batchID: UUID = uuid("80000000-0000-0000-0000-000000000001"),
    profileID: UUID = uuid("90000000-0000-0000-0000-000000000001"),
    completedAt: Date = instant(20),
    itemNames: [String] = ["wire.jpg"],
    warnings: [String] = ["warning.accepted"],
    items explicitItems: [DeliveryReceiptItem]? = nil
) -> DeliveryReceipt {
    let items = explicitItems ?? itemNames.enumerated().map { index, filename in
        makeItem(
            filename: filename,
            sourceHashCharacter: index.isMultiple(of: 2) ? "a" : "c",
            deliveredHashCharacter: index.isMultiple(of: 2) ? "b" : "d",
            warnings: warnings,
            completedAt: completedAt
        )
    }
    return DeliveryReceipt(
        id: receiptID,
        batchIdentifier: batchID,
        profileIdentifier: profileID,
        applicationVersion: DeliveryApplicationVersion(
            marketingVersion: "3.0.0",
            buildNumber: "738"
        ),
        startedAt: completedAt.addingTimeInterval(-10),
        completedAt: completedAt,
        destination: DeliveryReceiptDestination(
            identifier: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            path: "/incoming/wire"
        ),
        acceptedWarningIdentifiers: warnings,
        items: items
    )
}

private func makeItem(
    filename: String,
    sourceHashCharacter: Character = "a",
    deliveredHashCharacter: Character = "b",
    warnings: [String] = ["warning.accepted"],
    completedAt: Date = instant(20)
) -> DeliveryReceiptItem {
    DeliveryReceiptItem(
        sourceIdentity: DeliveryReceiptSourceIdentity(
            sha256: String(repeating: sourceHashCharacter, count: 64),
            byteSize: 900
        ),
        deliveredFilename: filename,
        deliveredSHA256: String(repeating: deliveredHashCharacter, count: 64),
        deliveredByteSize: 800,
        metadataVerification: DeliveryMetadataVerificationResult(
            outcome: .verifiedWithWarnings,
            controlledFieldIdentifiers: [.headline, .description],
            issueIdentifiers: ["metadata.readback.normalized"]
        ),
        renderSettings: defaultRenderSettings,
        uploadAcknowledgement: DeliveryUploadAcknowledgement(
            status: .protocolAcknowledged,
            acknowledgedAt: completedAt.addingTimeInterval(-5)
        ),
        remoteStatAcknowledgement: DeliveryRemoteStatAcknowledgement(
            status: .matchesDeliveredByteSize,
            checkedAt: completedAt.addingTimeInterval(-4),
            observedByteSize: 800
        ),
        acceptedWarningIdentifiers: warnings
    )
}

private func instant(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + seconds)
}

private func day(_ offset: Int) -> Date {
    instant(TimeInterval(offset * 86_400))
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
}

private struct ReceiptFixture {
    let directoryURL: URL
    let documentURL: URL
    let backupURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-delivery-receipts-\(UUID().uuidString)",
            isDirectory: true
        )
        documentURL = directoryURL.appendingPathComponent("delivery-receipts.json")
        backupURL = documentURL.appendingPathExtension("backup")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func writeCatalog(
        schemaVersion: Int,
        receipts: [DeliveryReceipt],
        receiptSchemaVersion: Int
    ) throws {
        var receiptObjects = try receipts.map { receipt in
            var object = try #require(
                JSONSerialization.jsonObject(with: encode(receipt)) as? [String: Any]
            )
            object["schemaVersion"] = receiptSchemaVersion
            return object
        }
        // Keep fixture bytes deterministic even if the caller supplies unordered receipts.
        receiptObjects.sort {
            ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "receipts": receiptObjects,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: documentURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
