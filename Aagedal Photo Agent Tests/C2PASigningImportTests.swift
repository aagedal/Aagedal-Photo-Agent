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
    func keyExportFailurePreservesExistingPair() throws {
        let fixture = try Fixture(importer: .failure)
        defer { fixture.cleanUp() }

        #expect(throws: TestError.self) {
            try fixture.viewModel.importC2PACertificate(from: fixture.importURL, password: "wrong")
        }
        fixture.assertPriorPair()
    }

    @Test("Keychain save failure leaves the prior pair untouched")
    func keychainFailurePreservesExistingPair() throws {
        let fixture = try Fixture(persistenceFailure: .keySave)
        defer { fixture.cleanUp() }

        #expect(throws: TestError.self) {
            try fixture.viewModel.importC2PACertificate(from: fixture.importURL, password: "password")
        }
        fixture.assertPriorPair()
    }

    @Test("Certificate replacement failure rolls back the private key")
    func certificateFailureRollsBackPrivateKey() throws {
        let fixture = try Fixture(persistenceFailure: .certificateReplace)
        defer { fixture.cleanUp() }

        #expect(throws: TestError.self) {
            try fixture.viewModel.importC2PACertificate(from: fixture.importURL, password: "password")
        }
        fixture.assertPriorPair()
    }

    @Test("Successful import replaces certificate and private key together")
    func successfulImportReplacesExistingPair() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.viewModel.importC2PACertificate(from: fixture.importURL, password: "password")

        #expect(fixture.persistence.certificateData == Data("new certificate".utf8))
        #expect(fixture.persistence.privateKey == "new key")
        #expect(fixture.viewModel.c2paCertificatePath == fixture.persistence.certificateURL.path)
        #expect(fixture.viewModel.c2paCertificateSubject == "New signer")
        #expect(fixture.viewModel.c2paCertificateExpiry == "Jan 1, 2030")
    }

    private final class Fixture {
        let certificateURL: URL
        let importURL: URL
        let persistence: TestPersistence
        let viewModel: SettingsViewModel
        private let originalDefaults: [String: Any]

        init(importer: TestImporter.Mode = .success, persistenceFailure: TestPersistence.Failure? = nil) throws {
            let certificateURL = FileManager.default.temporaryDirectory.appendingPathComponent("c2pa-import-test-\(UUID().uuidString).pem")
            let importURL = URL(fileURLWithPath: "/tmp/import.p12")
            try Data("old certificate".utf8).write(to: certificateURL)
            let persistence = TestPersistence(certificateURL: certificateURL, failure: persistenceFailure)
            let keys = [UserDefaultsKeys.c2paCertificatePath, UserDefaultsKeys.c2paCertificateSubject, UserDefaultsKeys.c2paCertificateExpiry]
            let originalDefaults = Dictionary(uniqueKeysWithValues: keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
            UserDefaults.standard.set(certificateURL.path, forKey: UserDefaultsKeys.c2paCertificatePath)
            UserDefaults.standard.set("Old signer", forKey: UserDefaultsKeys.c2paCertificateSubject)
            UserDefaults.standard.set("Jan 1, 2020", forKey: UserDefaultsKeys.c2paCertificateExpiry)
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
            for key in [UserDefaultsKeys.c2paCertificatePath, UserDefaultsKeys.c2paCertificateSubject, UserDefaultsKeys.c2paCertificateExpiry] {
                if let value = originalDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private struct TestImporter: C2PAIdentityImporting {
        enum Mode { case success, failure }
        let mode: Mode
        func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity {
            if mode == .failure { throw TestError.failed }
            return C2PAImportedIdentity(certificatePEM: "new certificate", privateKeyPEM: "new key", subject: "New signer", expiry: "Jan 1, 2030")
        }
    }

    private final class TestPersistence: C2PASigningConfigurationPersisting {
        enum Failure { case keySave, certificateReplace }
        let certificateURL: URL
        var certificateData = Data("old certificate".utf8)
        var privateKey: String? = "old key"
        let failure: Failure?

        init(certificateURL: URL, failure: Failure?) { self.certificateURL = certificateURL; self.failure = failure }
        func stageCertificate(_ pem: String) throws -> URL {
            let url = certificateURL.appendingPathExtension("staged")
            try Data(pem.utf8).write(to: url)
            return url
        }
        func replaceCertificate(with stagedURL: URL) throws {
            if failure == .certificateReplace { throw TestError.failed }
            certificateData = try Data(contentsOf: stagedURL)
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
