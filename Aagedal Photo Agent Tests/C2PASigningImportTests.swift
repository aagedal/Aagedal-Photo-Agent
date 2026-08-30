import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("C2PA signing import transaction", .serialized)
@MainActor
struct C2PASigningImportTests {
    @Test("Test signer manifest omits the user certificate")
    func testSignerManifestOmitsCertificate() throws {
        let data = try C2PASigningService.buildManifestJSON(
            title: "test.jpg",
            author: nil,
            actions: [],
            certificatePath: "",
            claimGenerator: "Aagedal Photo Agent/1.0"
        )
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["sign_cert"] == nil)
        #expect(manifest["alg"] as? String == "es256")
    }

    @Test("Private-key export failure leaves the prior pair untouched")
    func keyExportFailurePreservesExistingPair() async throws {
        let fixture = try Fixture(importer: .failure)
        defer { fixture.cleanUp() }

        await #expect(throws: TestError.self) {
            try await fixture.viewModel.importC2PACertificate(
                from: fixture.importURL,
                password: "wrong",
                requestID: UUID()
            )
        }
        fixture.assertPriorPair()
    }

    @Test("Keychain save failure leaves the prior pair untouched")
    func keychainFailurePreservesExistingPair() async throws {
        let fixture = try Fixture(persistenceFailure: .keySave)
        defer { fixture.cleanUp() }

        await #expect(throws: TestError.self) {
            try await fixture.viewModel.importC2PACertificate(
                from: fixture.importURL,
                password: "password",
                requestID: UUID()
            )
        }
        fixture.assertPriorPair()
    }

    @Test("Certificate replacement failure rolls back the private key")
    func certificateFailureRollsBackPrivateKey() async throws {
        let fixture = try Fixture(persistenceFailure: .certificateReplace)
        defer { fixture.cleanUp() }

        await #expect(throws: TestError.self) {
            try await fixture.viewModel.importC2PACertificate(
                from: fixture.importURL,
                password: "password",
                requestID: UUID()
            )
        }
        fixture.assertPriorPair()
    }

    @Test("Successful import replaces certificate and private key together")
    func successfulImportReplacesExistingPair() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let requestID = UUID()
        let task = Task {
            try await fixture.viewModel.importC2PACertificate(
                from: fixture.importURL,
                password: "password",
                requestID: requestID
            )
        }
        let result = try await task.value

        #expect(result == .committed(C2PACertificateImportCommit(
            requestID: requestID,
            certificateURL: fixture.persistence.certificateURL,
            subject: "New signer",
            expiry: "Jan 1, 2030",
            configurationChanged: true,
            cancellationObservedAfterCommit: false
        )))
        #expect(fixture.persistence.certificateData == Data("new certificate".utf8))
        #expect(fixture.persistence.privateKey == "new key")
        #expect(fixture.viewModel.c2paCertificatePath == fixture.persistence.certificateURL.path)
        #expect(fixture.viewModel.c2paCertificateSubject == "New signer")
        #expect(fixture.viewModel.c2paCertificateExpiry == "Jan 1, 2030")
    }

    @Test("Certificate parsing runs away from the main actor")
    func certificateParsingRunsOffMainActor() async throws {
        let certificateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2pa-off-main-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: certificateURL.appendingPathExtension("staged")) }
        let persistence = TestPersistence(certificateURL: certificateURL, failure: nil)
        let importer = ImporterProbe()
        let service = C2PASigningConfigurationService(
            persistence: persistence,
            pkcs12Importer: importer
        )

        _ = try await Task { @MainActor in
            try await service.importCertificate(
                from: URL(fileURLWithPath: "/virtual/import.p12"),
                password: "password",
                requestID: UUID()
            )
        }.value

        #expect(importer.invocationCount == 1)
        #expect(!importer.ranOnMainThread)
    }

    @Test("Queued cancellation does not enter a second certificate read")
    func queuedCancellationIsExplicitAndSerialized() async throws {
        let certificateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2pa-serialized-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: certificateURL.appendingPathExtension("staged")) }
        let persistence = TestPersistence(certificateURL: certificateURL, failure: nil)
        let importer = BlockingImporterProbe()
        let service = C2PASigningConfigurationService(
            persistence: persistence,
            pkcs12Importer: importer
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            try await service.importCertificate(
                from: URL(fileURLWithPath: "/virtual/first.p12"),
                password: "password",
                requestID: firstID
            )
        }
        try await importer.waitUntilFirstImportStarts()
        let second = Task {
            try await service.importCertificate(
                from: URL(fileURLWithPath: "/virtual/second.p12"),
                password: "password",
                requestID: secondID
            )
        }
        second.cancel()
        importer.releaseFirstImport()

        _ = try await first.value
        let secondResult = try await second.value

        #expect(secondResult == .cancelledBeforeRead(requestID: secondID))
        #expect(importer.invocationCount == 1)
        #expect(importer.maximumConcurrentImports == 1)
    }

    @Test("Cancellation after replacement returns durable commit evidence")
    func cancellationAfterCommitIsDurable() async throws {
        let fixture = try Fixture(cancelAfterCertificateReplace: true)
        defer { fixture.cleanUp() }
        let requestID = UUID()

        let task = Task {
            try await fixture.viewModel.importC2PACertificate(
                from: fixture.importURL,
                password: "password",
                requestID: requestID
            )
        }
        let result = try await task.value

        guard case .committed(let commit) = result else {
            Issue.record("Expected a durable commit")
            return
        }
        #expect(commit.cancellationObservedAfterCommit)
        #expect(fixture.persistence.certificateData == Data("new certificate".utf8))
        #expect(fixture.viewModel.c2paCertificateSubject == "New signer")
    }

    @Test("App-scoped status refresh publishes availability and fails closed when the file disappears")
    func statusRefreshOwnsAvailability() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let presentID = UUID()
        let present = await fixture.viewModel.refreshC2PACertificateStatus(
            requestID: presentID
        )
        #expect(present == .loaded(C2PACertificateStatusSnapshot(
            requestID: presentID,
            configuredPath: fixture.certificateURL.path,
            certificateExists: true
        )))
        #expect(fixture.viewModel.c2paHasCertificate)

        try FileManager.default.removeItem(at: fixture.certificateURL)
        let missingID = UUID()
        let missing = await fixture.viewModel.refreshC2PACertificateStatus(
            requestID: missingID
        )
        #expect(missing == .loaded(C2PACertificateStatusSnapshot(
            requestID: missingID,
            configuredPath: fixture.certificateURL.path,
            certificateExists: false
        )))
        #expect(!fixture.viewModel.c2paHasCertificate)
        #expect(fixture.viewModel.c2paCertificatePath.isEmpty)
    }

    @Test("Settings owns request identity and contains no direct certificate filesystem calls")
    func settingsSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/SettingsViewModel.swift"
            ),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ContentView.swift"
            ),
            encoding: .utf8
        )
        let ftpSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/FTP/FTPUploadView.swift"
            ),
            encoding: .utf8
        )
        let start = try #require(modelSource.range(of: "// MARK: - C2PA Signing"))
        let end = try #require(modelSource.range(of: "    var detectedEditors:"))
        let c2paModelSource = String(modelSource[start.lowerBound..<end.lowerBound])

        #expect(viewSource.contains("guard c2paOperationRequestID == requestID else { return }"))
        #expect(viewSource.contains("c2paOperationTask?.cancel()"))
        #expect(c2paModelSource.contains("await c2paConfigurationService.importCertificate("))
        #expect(!c2paModelSource.contains("Data(contentsOf:"))
        #expect(!c2paModelSource.contains("FileManager.default"))
        #expect(!c2paModelSource.contains("String(contentsOf:"))
        #expect(contentSource.contains("await settingsViewModel.refreshC2PACertificateStatus("))
        #expect(contentSource.contains("hasC2PASigningCertificate: settingsViewModel.c2paHasCertificate"))
        #expect(ftpSource.contains("if hasC2PASigningCertificate"))
        #expect(!ftpSource.contains("SettingsViewModel.hasC2PASigningCertificate"))
    }

    private final class Fixture {
        let certificateURL: URL
        let importURL: URL
        let persistence: TestPersistence
        let viewModel: SettingsViewModel
        private let originalDefaults: [String: Any]

        init(
            importer: TestImporter.Mode = .success,
            persistenceFailure: TestPersistence.Failure? = nil,
            cancelAfterCertificateReplace: Bool = false
        ) throws {
            let certificateURL = FileManager.default.temporaryDirectory.appendingPathComponent("c2pa-import-test-\(UUID().uuidString).pem")
            let importURL = URL(fileURLWithPath: "/tmp/import.p12")
            try Data("old certificate".utf8).write(to: certificateURL)
            let persistence = TestPersistence(
                certificateURL: certificateURL,
                failure: persistenceFailure,
                cancelAfterCertificateReplace: cancelAfterCertificateReplace
            )
            let keys = [
                UserDefaultsKeys.c2paCertificatePath,
                UserDefaultsKeys.c2paCertificateSubject,
                UserDefaultsKeys.c2paCertificateExpiry,
                UserDefaultsKeys.c2paUseTestCertificate
            ]
            let originalDefaults = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
            UserDefaults.standard.set(certificateURL.path, forKey: UserDefaultsKeys.c2paCertificatePath)
            UserDefaults.standard.set("Old signer", forKey: UserDefaultsKeys.c2paCertificateSubject)
            UserDefaults.standard.set("Jan 1, 2020", forKey: UserDefaultsKeys.c2paCertificateExpiry)
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.c2paUseTestCertificate)
            self.certificateURL = certificateURL
            self.importURL = importURL
            self.persistence = persistence
            self.originalDefaults = originalDefaults
            viewModel = SettingsViewModel(c2paPersistence: persistence, pkcs12Importer: TestImporter(mode: importer))
        }

        func assertPriorPair() {
            #expect(persistence.certificateData == Data("old certificate".utf8))
            #expect(persistence.privateKey == "old key")
            #expect(viewModel.c2paCertificatePath == certificateURL.path)
            #expect(viewModel.c2paCertificateSubject == "Old signer")
            #expect(viewModel.c2paCertificateExpiry == "Jan 1, 2020")
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: certificateURL)
            try? FileManager.default.removeItem(at: certificateURL.appendingPathExtension("staged"))
            for key in [
                UserDefaultsKeys.c2paCertificatePath,
                UserDefaultsKeys.c2paCertificateSubject,
                UserDefaultsKeys.c2paCertificateExpiry,
                UserDefaultsKeys.c2paUseTestCertificate
            ] {
                if let value = originalDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private struct TestImporter: C2PAIdentityImporting {
        enum Mode: Sendable { case success, failure }
        let mode: Mode
        func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity {
            if mode == .failure { throw TestError.failed }
            return C2PAImportedIdentity(certificatePEM: "new certificate", privateKeyPEM: "new key", subject: "New signer", expiry: "Jan 1, 2030")
        }
    }

    private final class TestPersistence: C2PASigningConfigurationPersisting, @unchecked Sendable {
        enum Failure { case keySave, certificateReplace }
        let certificateURL: URL
        var certificateData = Data("old certificate".utf8)
        var privateKey: String? = "old key"
        let failure: Failure?
        let cancelAfterCertificateReplace: Bool

        init(
            certificateURL: URL,
            failure: Failure?,
            cancelAfterCertificateReplace: Bool = false
        ) {
            self.certificateURL = certificateURL
            self.failure = failure
            self.cancelAfterCertificateReplace = cancelAfterCertificateReplace
        }
        func stageCertificate(_ pem: String) throws -> URL {
            let url = certificateURL.appendingPathExtension("staged")
            try Data(pem.utf8).write(to: url)
            return url
        }
        func replaceCertificate(with stagedURL: URL) throws {
            if failure == .certificateReplace { throw TestError.failed }
            certificateData = try Data(contentsOf: stagedURL)
            if cancelAfterCertificateReplace {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        func discardStagedCertificate(at stagedURL: URL) {
            try? FileManager.default.removeItem(at: stagedURL)
        }
        func restoreCertificate(_ data: Data?) throws { certificateData = data ?? Data() }
        func currentCertificateData() throws -> Data? { certificateData }
        func loadPrivateKey() -> String? { privateKey }
        func replacePrivateKey(with value: String?) throws {
            if failure == .keySave { throw TestError.failed }
            privateKey = value
        }
    }

    private enum TestError: Error { case failed }
}

private nonisolated final class ImporterProbe: C2PAIdentityImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var observedMainThread = false

    func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity {
        _ = url
        _ = password
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return C2PAImportedIdentity(
            certificatePEM: "new certificate",
            privateKeyPEM: "new key",
            subject: "New signer",
            expiry: "Jan 1, 2030"
        )
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private enum C2PAImportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingImporterProbe: C2PAIdentityImporting, @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var activeImports = 0
    private var maximumActive = 0
    private var firstImportReleased = false

    func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity {
        _ = url
        _ = password
        condition.lock()
        count += 1
        activeImports += 1
        maximumActive = max(maximumActive, activeImports)
        condition.broadcast()
        if count == 1 {
            while !firstImportReleased {
                condition.wait()
            }
        }
        activeImports -= 1
        condition.unlock()
        return C2PAImportedIdentity(
            certificatePEM: "new certificate",
            privateKeyPEM: "new key",
            subject: "New signer",
            expiry: "Jan 1, 2030"
        )
    }

    func waitUntilFirstImportStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else { throw C2PAImportProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstImport() {
        condition.lock()
        firstImportReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    var maximumConcurrentImports: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActive
    }
}
