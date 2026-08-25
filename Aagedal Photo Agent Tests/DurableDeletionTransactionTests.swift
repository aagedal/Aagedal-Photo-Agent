import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable deletion transaction")
struct DurableDeletionTransactionTests {
    private struct Marker: Codable {
        let id: UUID
    }

    private struct ThrowingMarker: Codable {
        let id: UUID

        init(id: UUID) { self.id = id }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            id = try container.decode(UUID.self)
        }

        func encode(to encoder: Encoder) throws {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func fixture() throws -> (root: URL, record: URL, marker: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("record.json")
        let marker = root.appendingPathComponent("record.deleted")
        try Data("original".utf8).write(to: record)
        return (root, record, marker)
    }

    private var liveLocalIO: DurableDeletionIO {
        DurableDeletionIO(
            writeData: { try $0.write(to: $1, options: .atomic) },
            readData: { try Data(contentsOf: $0) },
            removeItem: {
                if FileManager.default.fileExists(atPath: $0.path) {
                    try FileManager.default.removeItem(at: $0)
                }
            }
        )
    }

    @Test("encoding failure never writes a marker or removes the original")
    func encodingFailurePreservesOriginal() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        var wrote = false
        var removed = false
        let io = DurableDeletionIO(
            writeData: { _, _ in wrote = true },
            readData: { _ in Data() },
            removeItem: { _ in removed = true }
        )

        #expect(throws: DurableDeletionError.self) {
            try DurableDeletionTransaction.execute(
                marker: ThrowingMarker(id: UUID()),
                markerURL: urls.marker,
                recordURL: urls.record,
                markerMatches: { _ in true },
                io: io
            )
        }
        #expect(!wrote)
        #expect(!removed)
        #expect(FileManager.default.fileExists(atPath: urls.record.path))
    }

    @Test("marker write failure preserves the original and reports a recoverable typed error")
    func markerWriteFailurePreservesOriginal() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        let expectedID = UUID()
        let io = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: liveLocalIO.readData,
            removeItem: liveLocalIO.removeItem
        )

        do {
            try DurableDeletionTransaction.execute(
                marker: Marker(id: expectedID),
                markerURL: urls.marker,
                recordURL: urls.record,
                markerMatches: { $0.id == expectedID },
                io: io
            )
            Issue.record("Expected marker write failure")
        } catch let error as DurableDeletionError {
            guard case .markerWriteFailed = error else {
                Issue.record("Unexpected deletion error: \(error)")
                return
            }
            #expect(error.localizedDescription.contains("original item was kept"))
        }
        #expect(FileManager.default.fileExists(atPath: urls.record.path))
        #expect(!FileManager.default.fileExists(atPath: urls.marker.path))
    }

    @Test("read-back failure rolls the marker back and preserves the original")
    func readBackFailurePreservesOriginal() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        let expectedID = UUID()
        let io = DurableDeletionIO(
            writeData: liveLocalIO.writeData,
            readData: { _ in throw CocoaError(.fileReadCorruptFile) },
            removeItem: liveLocalIO.removeItem
        )

        #expect(throws: DurableDeletionError.self) {
            try DurableDeletionTransaction.execute(
                marker: Marker(id: expectedID), markerURL: urls.marker,
                recordURL: urls.record, markerMatches: { $0.id == expectedID }, io: io
            )
        }
        #expect(FileManager.default.fileExists(atPath: urls.record.path))
        #expect(!FileManager.default.fileExists(atPath: urls.marker.path))
    }

    @Test("marker rollback failure reports the documented retryable interrupted state")
    func rollbackFailureIsExplicitAndRetryable() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        let expectedID = UUID()
        let privateDiagnostic = "/private/customer/path/that-must-not-reach-the-ui"
        let io = DurableDeletionIO(
            writeData: liveLocalIO.writeData,
            readData: { _ in throw NSError(domain: privateDiagnostic, code: 1) },
            removeItem: { _ in throw NSError(domain: privateDiagnostic, code: 2) }
        )

        do {
            try DurableDeletionTransaction.execute(
                marker: Marker(id: expectedID), markerURL: urls.marker,
                recordURL: urls.record, markerMatches: { $0.id == expectedID }, io: io
            )
            Issue.record("Expected rollback failure")
        } catch let error as DurableDeletionError {
            guard case .markerRollbackFailed = error else {
                Issue.record("Unexpected deletion error: \(error)")
                return
            }
            #expect(error.localizedDescription.contains("retry the deletion"))
            #expect(!error.localizedDescription.contains(privateDiagnostic))
        }
        #expect(FileManager.default.fileExists(atPath: urls.record.path))
        #expect(FileManager.default.fileExists(atPath: urls.marker.path))
    }

    @Test("a mismatched decoded marker is removed before aborting")
    func markerMismatchPreservesOriginal() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        let expectedID = UUID()
        let wrongData = try JSONEncoder().encode(Marker(id: UUID()))
        let io = DurableDeletionIO(
            writeData: liveLocalIO.writeData,
            readData: { _ in wrongData },
            removeItem: liveLocalIO.removeItem
        )

        #expect(throws: DurableDeletionError.self) {
            try DurableDeletionTransaction.execute(
                marker: Marker(id: expectedID), markerURL: urls.marker,
                recordURL: urls.record, markerMatches: { $0.id == expectedID }, io: io
            )
        }
        #expect(FileManager.default.fileExists(atPath: urls.record.path))
        #expect(!FileManager.default.fileExists(atPath: urls.marker.path))
    }

    @Test("record removal failure rolls the marker back and leaves the original usable")
    func recordRemovalFailurePreservesOriginal() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        let expectedID = UUID()
        let io = DurableDeletionIO(
            writeData: liveLocalIO.writeData,
            readData: liveLocalIO.readData,
            removeItem: { url in
                if url == urls.record { throw CocoaError(.fileWriteNoPermission) }
                try liveLocalIO.removeItem(url)
            }
        )

        #expect(throws: DurableDeletionError.self) {
            try DurableDeletionTransaction.execute(
                marker: Marker(id: expectedID), markerURL: urls.marker,
                recordURL: urls.record, markerMatches: { $0.id == expectedID }, io: io
            )
        }
        #expect(FileManager.default.fileExists(atPath: urls.record.path))
        #expect(!FileManager.default.fileExists(atPath: urls.marker.path))
        #expect(String(data: try Data(contentsOf: urls.record), encoding: .utf8) == "original")
    }

    @Test("success leaves a decodable matching marker before removing the source")
    func successIsDurableAndSuppressesResurrection() throws {
        let urls = try fixture()
        defer { try? FileManager.default.removeItem(at: urls.root) }
        let expectedID = UUID()

        try DurableDeletionTransaction.execute(
            marker: Marker(id: expectedID), markerURL: urls.marker,
            recordURL: urls.record, markerMatches: { $0.id == expectedID }, io: liveLocalIO
        )

        #expect(!FileManager.default.fileExists(atPath: urls.record.path))
        let installed = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: urls.marker))
        #expect(installed.id == expectedID)
    }
}
