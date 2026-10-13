import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Managed Develop batch storage")
struct DevelopTemplateBatchStorageTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/DevelopStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test("Managed discovery returns empty before first execution without creating storage")
    func absentManagedRoot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try DevelopTemplateBatchCheckpointStore.defaultStorageDirectory(
            applicationSupportDirectory: root, arguments: [])
        #expect(directory.path == root.path + "/Aagedal Photo Agent/Automation/DevelopBatches")
        let service = DevelopTemplateBatchRecoveryService(store: .init(directory: directory))
        #expect(try await service.inspect(allowMissingDirectory: true).isEmpty)
        #expect(try await service.inspect(allowMissingDirectory: true).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: (any Error).self) { try await service.inspect() }
    }

    @Test("Managed capture discovery is read-only and UI tests cannot inspect user storage")
    func admissionStorage() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try DevelopTemplateBatchAdmissionStore.defaultStorageDirectory(
            applicationSupportDirectory: root, arguments: [])
        #expect(directory.path == root.path + "/Aagedal Photo Agent/Automation/DevelopAdmissions")
        let store = DevelopTemplateBatchAdmissionStore(directory: directory)
        #expect(try await store.inspect().isEmpty)
        #expect(try await store.inspect().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(throws: (any Error).self) {
            try DevelopTemplateBatchAdmissionStore.defaultStorageDirectory(arguments: ["--ui-testing"])
        }
        #expect(throws: (any Error).self) {
            try DevelopTemplateBatchAdmissionStore.defaultStorageDirectory(
                arguments: ["--ui-testing", "--ui-test-develop-admission-root", "relative"])
        }
        #expect(try DevelopTemplateBatchAdmissionStore.defaultStorageDirectory(
            arguments: ["--ui-testing", "--ui-test-develop-admission-root", root.path]) == root)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        await #expect(throws: (any Error).self) {
            try await DevelopTemplateBatchAdmissionStore(directory: alias.appendingPathComponent("missing")).inspect()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) { try await DevelopTemplateBatchAdmissionStore(directory: root).inspect() }
    }

    @Test("Missing-tolerant discovery still refuses symlink and public roots")
    func unsafeRoot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        for directory in [alias, alias.appendingPathComponent("missing")] {
            await #expect(throws: (any Error).self) {
                try await DevelopTemplateBatchCheckpointStore(directory: directory)
                    .recoveryInventory(allowMissingDirectory: true)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) {
            try await DevelopTemplateBatchCheckpointStore(directory: root)
                .recoveryInventory(allowMissingDirectory: true)
        }
    }

    @Test("UI test managed storage requires an explicit disposable root")
    func uiTestIsolation() throws {
        #expect(throws: (any Error).self) {
            try DevelopTemplateBatchCheckpointStore.defaultStorageDirectory(arguments: ["--ui-testing"])
        }
        #expect(throws: (any Error).self) {
            try DevelopTemplateBatchCheckpointStore.defaultStorageDirectory(
                arguments: ["--ui-testing", "--ui-test-develop-checkpoint-root", "relative"])
        }
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try DevelopTemplateBatchCheckpointStore.defaultStorageDirectory(
            arguments: ["--ui-testing", "--ui-test-develop-checkpoint-root", root.path]) == root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
