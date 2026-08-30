import Foundation
import Security

/// The complete signing material extracted from an import source before anything is persisted.
nonisolated struct C2PAImportedIdentity: Sendable {
    let certificatePEM: String
    let privateKeyPEM: String
    let subject: String
    let expiry: String
}

nonisolated protocol C2PAIdentityImporting: Sendable {
    func importIdentity(from url: URL, password: String) throws -> C2PAImportedIdentity
}

nonisolated struct SecurityPKCS12IdentityImporter: C2PAIdentityImporting {
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
nonisolated protocol C2PASigningConfigurationPersisting: Sendable {
    var certificateURL: URL { get }
    func stageCertificate(_ pem: String) throws -> URL
    func replaceCertificate(with stagedURL: URL) throws
    func discardStagedCertificate(at stagedURL: URL)
    func restoreCertificate(_ data: Data?) throws
    func currentCertificateData() throws -> Data?
    func loadPrivateKey() -> String?
    func replacePrivateKey(with value: String?) throws
}

nonisolated struct AppC2PASigningConfigurationPersistence: C2PASigningConfigurationPersisting {
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

    func discardStagedCertificate(at stagedURL: URL) {
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

nonisolated struct C2PACertificateFileIO: Sendable {
    let readData: @Sendable (URL) throws -> Data
    let fileExists: @Sendable (URL) -> Bool

    static let system = C2PACertificateFileIO(
        readData: { try Data(contentsOf: $0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) }
    )
}

nonisolated struct C2PACertificateImportCommit: Equatable, Sendable {
    let requestID: UUID
    let certificateURL: URL?
    let subject: String
    let expiry: String
    let configurationChanged: Bool
    let cancellationObservedAfterCommit: Bool
}

nonisolated enum C2PACertificateImportResult: Equatable, Sendable {
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, sourceURL: URL, byteCount: Int?)
    case committed(C2PACertificateImportCommit)
}

nonisolated struct C2PACertificateRemovalCommit: Equatable, Sendable {
    let requestID: UUID
    let certificateURL: URL
    let certificateExisted: Bool
    let privateKeyExisted: Bool
    let cancellationObservedAfterCommit: Bool
}

nonisolated enum C2PACertificateRemovalResult: Equatable, Sendable {
    case cancelledBeforeCommit(requestID: UUID)
    case committed(C2PACertificateRemovalCommit)
}

nonisolated struct C2PACertificateStatusSnapshot: Equatable, Sendable {
    let requestID: UUID
    let configuredPath: String
    let certificateExists: Bool
}

nonisolated enum C2PACertificateStatusResult: Equatable, Sendable {
    case cancelled(requestID: UUID)
    case loaded(C2PACertificateStatusSnapshot)
}

/// Owns Settings certificate reads, parsing, Keychain access, and durable replacement/removal.
/// Foundation and Security calls are synchronous and non-preemptible once entered, so callers get
/// explicit cancellation evidence at the safe boundaries around them. Actor isolation also keeps
/// overlapping certificate mutations serialized.
actor C2PASigningConfigurationService {
    private let persistence: any C2PASigningConfigurationPersisting
    private let pkcs12Importer: any C2PAIdentityImporting
    private let fileIO: C2PACertificateFileIO

    init(
        persistence: any C2PASigningConfigurationPersisting = AppC2PASigningConfigurationPersistence(),
        pkcs12Importer: any C2PAIdentityImporting = SecurityPKCS12IdentityImporter(),
        fileIO: C2PACertificateFileIO = .system
    ) {
        self.persistence = persistence
        self.pkcs12Importer = pkcs12Importer
        self.fileIO = fileIO
    }

    func status(configuredPath: String, requestID: UUID) -> C2PACertificateStatusResult {
        guard !Task.isCancelled else { return .cancelled(requestID: requestID) }
        let exists = !configuredPath.isEmpty
            && fileIO.fileExists(URL(fileURLWithPath: configuredPath))
        guard !Task.isCancelled else { return .cancelled(requestID: requestID) }
        return .loaded(C2PACertificateStatusSnapshot(
            requestID: requestID,
            configuredPath: configuredPath,
            certificateExists: exists
        ))
    }

    func importCertificate(
        from sourceURL: URL,
        password: String,
        requestID: UUID
    ) throws -> C2PACertificateImportResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }

        let ext = sourceURL.pathExtension.lowercased()
        if ext == "p12" || ext == "pfx" {
            let identity = try pkcs12Importer.importIdentity(from: sourceURL, password: password)
            guard !Task.isCancelled else {
                return .cancelledAfterRead(
                    requestID: requestID,
                    sourceURL: sourceURL,
                    byteCount: nil
                )
            }
            return try commitCertificate(
                pem: identity.certificatePEM,
                privateKey: identity.privateKeyPEM,
                subject: identity.subject,
                expiry: identity.expiry,
                sourceURL: sourceURL,
                sourceByteCount: nil,
                requestID: requestID
            )
        }

        let data = try fileIO.readData(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: data.count
            )
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        let privateKey = Self.privateKeyPEM(in: content)
        guard content.contains("-----BEGIN CERTIFICATE-----") else {
            if let privateKey {
                try persistence.replacePrivateKey(with: privateKey)
                return .committed(C2PACertificateImportCommit(
                    requestID: requestID,
                    certificateURL: nil,
                    subject: "",
                    expiry: "",
                    configurationChanged: true,
                    cancellationObservedAfterCommit: Task.isCancelled
                ))
            }
            return .committed(C2PACertificateImportCommit(
                requestID: requestID,
                certificateURL: nil,
                subject: "",
                expiry: "",
                configurationChanged: false,
                cancellationObservedAfterCommit: Task.isCancelled
            ))
        }

        let certificatePEM = privateKey == nil
            ? content
            : Self.pemBlock(in: content, header: "CERTIFICATE") ?? content
        let info = Self.certificateInfo(from: certificatePEM)
        return try commitCertificate(
            pem: certificatePEM,
            privateKey: privateKey,
            subject: info.subject,
            expiry: info.expiry,
            sourceURL: sourceURL,
            sourceByteCount: data.count,
            requestID: requestID
        )
    }

    func removeCertificate(requestID: UUID) throws -> C2PACertificateRemovalResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }

        let previousCertificate = try persistence.currentCertificateData()
        let previousKey = persistence.loadPrivateKey()
        do {
            try persistence.replacePrivateKey(with: nil)
            do {
                try persistence.restoreCertificate(nil)
            } catch {
                try? persistence.replacePrivateKey(with: previousKey)
                throw error
            }
        } catch {
            try? persistence.restoreCertificate(previousCertificate)
            throw error
        }

        return .committed(C2PACertificateRemovalCommit(
            requestID: requestID,
            certificateURL: persistence.certificateURL,
            certificateExisted: previousCertificate != nil,
            privateKeyExisted: previousKey != nil,
            cancellationObservedAfterCommit: Task.isCancelled
        ))
    }

    private func commitCertificate(
        pem: String,
        privateKey: String?,
        subject: String,
        expiry: String,
        sourceURL: URL,
        sourceByteCount: Int?,
        requestID: UUID
    ) throws -> C2PACertificateImportResult {
        let previousCertificate = try persistence.currentCertificateData()
        let previousKey = persistence.loadPrivateKey()
        let stagedCertificate = try persistence.stageCertificate(pem)

        guard !Task.isCancelled else {
            persistence.discardStagedCertificate(at: stagedCertificate)
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                byteCount: sourceByteCount
            )
        }

        do {
            if let privateKey {
                try persistence.replacePrivateKey(with: privateKey)
            }
            do {
                try persistence.replaceCertificate(with: stagedCertificate)
            } catch {
                if privateKey != nil {
                    try? persistence.replacePrivateKey(with: previousKey)
                }
                try? persistence.restoreCertificate(previousCertificate)
                throw error
            }
        } catch {
            persistence.discardStagedCertificate(at: stagedCertificate)
            throw error
        }

        return .committed(C2PACertificateImportCommit(
            requestID: requestID,
            certificateURL: persistence.certificateURL,
            subject: subject,
            expiry: expiry,
            configurationChanged: true,
            cancellationObservedAfterCommit: Task.isCancelled
        ))
    }

    private static func privateKeyPEM(in content: String) -> String? {
        pemBlock(in: content, header: "PRIVATE KEY")
            ?? pemBlock(in: content, header: "RSA PRIVATE KEY")
            ?? pemBlock(in: content, header: "EC PRIVATE KEY")
    }

    private static func pemBlock(in content: String, header: String) -> String? {
        let beginMarker = "-----BEGIN \(header)-----"
        let endMarker = "-----END \(header)-----"
        guard let beginRange = content.range(of: beginMarker),
              let endRange = content.range(of: endMarker) else {
            return nil
        }
        return String(content[beginRange.lowerBound...endRange.upperBound])
    }

    private static func certificateInfo(from pem: String) -> (subject: String, expiry: String) {
        let base64 = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let derData = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            return ("", "")
        }

        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown"
        guard let values = SecCertificateCopyValues(certificate, nil, nil) as? [String: Any],
              let validity = values["2.5.4.24"] as? [String: Any],
              let date = validity[kSecPropertyKeyValue as String] as? Date else {
            return (subject, "")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return (subject, formatter.string(from: date))
    }
}
