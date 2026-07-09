import Foundation
import Security

/// The complete signing material extracted from an import source before anything is persisted.
struct C2PAImportedIdentity {
    let certificatePEM: String
    let privateKeyPEM: String
    let subject: String
    let expiry: String
}

protocol C2PAIdentityImporting {
    func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity
}

struct SecurityPKCS12IdentityImporter: C2PAIdentityImporting {
    func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity {
        let data = try Data(contentsOf: url)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first else {
            throw C2PASigningError.processFailed("Failed to import PKCS#12 file (status: \(status))")
        }
        guard let identityValue = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw C2PASigningError.processFailed("PKCS#12 file did not contain a signing identity")
        }
        let identity = identityValue as! SecIdentity

        var certRef: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certRef)
        guard certificateStatus == errSecSuccess, let cert = certRef else {
            throw C2PASigningError.processFailed("Failed to read certificate from PKCS#12 file (status: \(certificateStatus))")
        }
        var keyRef: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &keyRef)
        guard keyStatus == errSecSuccess, let key = keyRef else {
            throw C2PASigningError.processFailed("Failed to read private key from PKCS#12 file (status: \(keyStatus))")
        }
        guard let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw C2PASigningError.processFailed("Failed to export private key from PKCS#12 file")
        }

        let certificatePEM = pem(data: SecCertificateCopyData(cert) as Data, type: "CERTIFICATE")
        let privateKeyPEM = pem(data: keyData, type: "PRIVATE KEY")
        let subject = SecCertificateCopySubjectSummary(cert) as String? ?? "Unknown"
        let expiry: String
        if let values = SecCertificateCopyValues(cert, nil, nil) as? [String: Any],
           let validity = values["2.5.4.24"] as? [String: Any],
           let date = validity[kSecPropertyKeyValue as String] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            expiry = formatter.string(from: date)
        } else {
            expiry = ""
        }
        return C2PAImportedIdentity(certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM, subject: subject, expiry: expiry)
    }

    private func pem(data: Data, type: String) -> String {
        "-----BEGIN \(type)-----\n" + data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) + "\n-----END \(type)-----\n"
    }
}

/// Persistence boundary for a signing pair. Keeping this injectable lets failures be tested
/// without touching the user's Keychain or Application Support directory.
protocol C2PASigningConfigurationPersisting {
    var certificateURL: URL { get }
    func stageCertificate(_ pem: String) throws -> URL
    func replaceCertificate(with stagedURL: URL) throws
    func restoreCertificate(_ data: Data?) throws
    func currentCertificateData() throws -> Data?
    func loadPrivateKey() -> String?
    func replacePrivateKey(with value: String?) throws
}

struct AppC2PASigningConfigurationPersistence: C2PASigningConfigurationPersisting {
    let certificateURL: URL

    init(certificateURL: URL = AppPaths.certificatesDirectory.appendingPathComponent("signing_cert.pem")) {
        self.certificateURL = certificateURL
    }

    func stageCertificate(_ pem: String) throws -> URL {
        try FileManager.default.createDirectory(at: certificateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stagedURL = certificateURL.deletingLastPathComponent().appendingPathComponent(".signing_cert.\(UUID().uuidString).pem")
        try pem.write(to: stagedURL, atomically: true, encoding: .utf8)
        return stagedURL
    }

    func replaceCertificate(with stagedURL: URL) throws {
        let data = try Data(contentsOf: stagedURL)
        try data.write(to: certificateURL, options: .atomic)
        try? FileManager.default.removeItem(at: stagedURL)
    }

    func restoreCertificate(_ data: Data?) throws {
        if let data {
            try data.write(to: certificateURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: certificateURL.path) {
            try FileManager.default.removeItem(at: certificateURL)
        }
    }

    func currentCertificateData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: certificateURL.path) else { return nil }
        return try Data(contentsOf: certificateURL)
    }

    func loadPrivateKey() -> String? { KeychainService.load(forKey: "c2pa_private_key") }

    func replacePrivateKey(with value: String?) throws {
        if let value {
            try KeychainService.save(password: value, forKey: "c2pa_private_key")
        } else {
            try KeychainService.deleteThrowing(forKey: "c2pa_private_key")
        }
    }
}
