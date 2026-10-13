import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only face receipt inspection")
struct MCPFaceScanReceiptInspectionTests {
    @Test("Managed absent inspection creates no folders or archives")
    func absent() throws {
        let base = URL(fileURLWithPath: "/private/tmp/face-receipts-\(UUID())")
        let location = try MCPFaceScanReceiptStore.defaultStorageDirectory(applicationSupportDirectory: base, arguments: [])
        #expect(try MCPFaceScanReceiptStore(storageDirectory: location).receipts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("UI testing requires an explicit disposable receipt location")
    func isolatedUITests() throws {
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try MCPFaceScanReceiptStore.defaultStorageDirectory(arguments: ["--ui-testing"])
        }
        #expect(throws: AutomationOperationRegistry.Failure.storageUnavailable) {
            try MCPFaceScanReceiptStore.defaultStorageDirectory(arguments: ["--ui-testing", "--ui-test-face-receipt-root", "relative"])
        }
        let path = "/private/tmp/receipt-\(UUID())"
        #expect(try MCPFaceScanReceiptStore.defaultStorageDirectory(arguments:
            ["--ui-testing", "--ui-test-face-receipt-root", path]).path == path)
    }

    @Test("Corrupt inspection preserves exact bytes and inventory")
    func corrupt() throws {
        let root = URL(fileURLWithPath: "/private/tmp/face-receipts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = root.appendingPathComponent("operations.json")
        let lock = root.appendingPathComponent("operations.lock")
        let original = Data("retained malformed receipt".utf8)
        try original.write(to: archive); try Data().write(to: lock)
        for url in [archive, lock] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        #expect(throws: MCPFaceScanReceiptStore.Failure.invalidStorage) { try MCPFaceScanReceiptStore(storageDirectory: root).receipts() }
        #expect(try Data(contentsOf: archive) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["operations.json", "operations.lock"])
    }
}
