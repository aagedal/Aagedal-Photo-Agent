import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "C2PASigning")

enum C2PASigningError: Error, LocalizedError {
    case c2patoolMissing
    case certificateNotConfigured
    case privateKeyNotConfigured
    case processFailed(String)
    case outputMissing
    case manifestSerializationFailed

    var errorDescription: String? {
        switch self {
        case .c2patoolMissing:
            return "c2patool not found in app bundle"
        case .certificateNotConfigured:
            return "No signing certificate configured. Import one in Settings → Signing."
        case .privateKeyNotConfigured:
            return "No private key found in Keychain for C2PA signing."
        case .processFailed(let message):
            return "c2patool failed: \(message)"
        case .outputMissing:
            return "c2patool produced no output file"
        case .manifestSerializationFailed:
            return "Failed to serialize C2PA manifest JSON"
        }
    }
}

nonisolated enum C2PASigningService {

    // MARK: - Discovery

    static var c2patoolPath: String? {
        Bundle.main.path(forResource: "c2patool", ofType: nil)
    }

    static var isAvailable: Bool {
        c2patoolPath != nil
    }

    // MARK: - Signing

    /// Sign an image with a C2PA manifest (first-time signing, no prior C2PA).
    /// - Parameters:
    ///   - imageURL: The image to sign.
    ///   - certificatePath: Path to the PEM certificate chain file.
    ///   - privateKeyPEM: PEM-encoded private key (from Keychain).
    ///   - author: Author name for the CreativeWork assertion.
    ///   - actions: C2PA action URIs (e.g. "c2pa.created").
    ///   - digitalSourceType: Optional IPTC digital source type URI.
    static func sign(
        imageURL: URL,
        certificatePath: String,
        privateKeyPEM: String,
        author: String?,
        actions: [String] = ["c2pa.created"],
        digitalSourceType: String? = nil
    ) async throws {
        guard let toolPath = c2patoolPath else {
            throw C2PASigningError.c2patoolMissing
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        // Write private key to temp file (c2patool reads it from the path in manifest JSON)
        let tempDir = FileManager.default.temporaryDirectory
        let keyFile = tempDir.appendingPathComponent("c2pa_key_\(UUID().uuidString).pem")
        let manifestFile = tempDir.appendingPathComponent("c2pa_manifest_\(UUID().uuidString).json")
        let outputFile = tempDir.appendingPathComponent("c2pa_output_\(UUID().uuidString)_\(imageURL.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: keyFile)
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        try Data(privateKeyPEM.utf8).write(to: keyFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyFile.path(percentEncoded: false)
        )

        // Build manifest JSON (signing credentials go inside the manifest)
        let manifestData = try buildManifestJSON(
            title: imageURL.lastPathComponent,
            author: author,
            actions: actions,
            digitalSourceType: digitalSourceType,
            certificatePath: certificatePath,
            privateKeyPath: keyFile.path(percentEncoded: false),
            claimGenerator: "Aagedal Photo Agent/\(appVersion)"
        )
        try manifestData.write(to: manifestFile)

        let imagePath = imageURL.path(percentEncoded: false)

        // c2patool <input> -m <manifest.json> -o <output> -f
        let arguments = [
            imagePath,
            "-m", manifestFile.path(percentEncoded: false),
            "-o", outputFile.path(percentEncoded: false),
            "-f",
        ]

        logger.info("Signing: \(imageURL.lastPathComponent, privacy: .public)")

        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: toolPath),
                arguments: arguments
            )
        } catch {
            let message = error.localizedDescription
            logger.error("c2patool failed: \(message, privacy: .public)")
            throw C2PASigningError.processFailed(message)
        }

        guard FileManager.default.fileExists(atPath: outputFile.path(percentEncoded: false)) else {
            throw C2PASigningError.outputMissing
        }

        // Replace original with signed output
        let backupURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(imageURL.lastPathComponent).c2pa_backup")
        defer { try? FileManager.default.removeItem(at: backupURL) }

        // Preserve creation date
        let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath)
        let creationDate = attrs?[.creationDate] as? Date

        try FileManager.default.moveItem(at: imageURL, to: backupURL)
        try FileManager.default.moveItem(at: outputFile, to: imageURL)

        if let creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate],
                ofItemAtPath: imagePath
            )
        }

        logger.info("Signed successfully: \(imageURL.lastPathComponent, privacy: .public)")
    }

    /// Sign an image that already has C2PA, preserving the history chain.
    ///
    /// Uses c2patool's `--ingredient` extraction + `--parent` flag to read the existing
    /// manifest store and embed it as a parent ingredient in the new signature.
    static func signPreservingHistory(
        imageURL: URL,
        certificatePath: String,
        privateKeyPEM: String,
        author: String?,
        actions: [String] = ["c2pa.opened", "c2pa.edited"],
        digitalSourceType: String? = nil
    ) async throws {
        guard let toolPath = c2patoolPath else {
            throw C2PASigningError.c2patoolMissing
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let tempDir = FileManager.default.temporaryDirectory
        let ingredientDir = tempDir.appendingPathComponent("c2pa_ingredient_\(UUID().uuidString)")
        let keyFile = tempDir.appendingPathComponent("c2pa_key_\(UUID().uuidString).pem")
        let manifestFile = tempDir.appendingPathComponent("c2pa_manifest_\(UUID().uuidString).json")
        let outputFile = tempDir.appendingPathComponent("c2pa_output_\(UUID().uuidString)_\(imageURL.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: ingredientDir)
            try? FileManager.default.removeItem(at: keyFile)
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        let imagePath = imageURL.path(percentEncoded: false)

        // Step 1: Extract ingredient data from the existing signed image
        // c2patool <input> --ingredient -o <ingredient_dir>
        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: toolPath),
                arguments: [imagePath, "--ingredient", "-o", ingredientDir.path(percentEncoded: false)]
            )
        } catch {
            let message = error.localizedDescription
            logger.error("c2patool ingredient extraction failed: \(message, privacy: .public)")
            throw C2PASigningError.processFailed("Ingredient extraction failed: \(message)")
        }

        // Step 2: Write private key and build manifest
        try Data(privateKeyPEM.utf8).write(to: keyFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyFile.path(percentEncoded: false)
        )

        let manifestData = try buildManifestJSON(
            title: imageURL.lastPathComponent,
            author: author,
            actions: actions,
            digitalSourceType: digitalSourceType,
            certificatePath: certificatePath,
            privateKeyPath: keyFile.path(percentEncoded: false),
            claimGenerator: "Aagedal Photo Agent/\(appVersion)"
        )
        try manifestData.write(to: manifestFile)

        // Step 3: Sign with parent ingredient
        // c2patool <input> -m <manifest.json> -p <ingredient_dir> -o <output> -f
        let signArguments = [
            imagePath,
            "-m", manifestFile.path(percentEncoded: false),
            "-p", ingredientDir.path(percentEncoded: false),
            "-o", outputFile.path(percentEncoded: false),
            "-f",
        ]

        logger.info("Re-signing with history: \(imageURL.lastPathComponent, privacy: .public)")

        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: toolPath),
                arguments: signArguments
            )
        } catch {
            let message = error.localizedDescription
            logger.error("c2patool signing failed: \(message, privacy: .public)")
            throw C2PASigningError.processFailed(message)
        }

        guard FileManager.default.fileExists(atPath: outputFile.path(percentEncoded: false)) else {
            throw C2PASigningError.outputMissing
        }

        // Replace original with signed output
        let backupURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(imageURL.lastPathComponent).c2pa_backup")
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath)
        let creationDate = attrs?[.creationDate] as? Date

        try FileManager.default.moveItem(at: imageURL, to: backupURL)
        try FileManager.default.moveItem(at: outputFile, to: imageURL)

        if let creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate],
                ofItemAtPath: imagePath
            )
        }

        logger.info("Re-signed successfully: \(imageURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Manifest Builder

    /// Build c2patool manifest definition JSON.
    ///
    /// Signing credentials are embedded in the manifest JSON per c2patool's interface.
    /// The `private_key` and `sign_cert` fields point to file paths that c2patool reads.
    static func buildManifestJSON(
        title: String?,
        author: String?,
        actions: [String],
        digitalSourceType: String?,
        certificatePath: String,
        privateKeyPath: String,
        claimGenerator: String
    ) throws -> Data {
        let version = claimGenerator.components(separatedBy: "/").last ?? "0.0.0"

        var manifest: [String: Any] = [
            "alg": "es256",
            "private_key": privateKeyPath,
            "sign_cert": certificatePath,
            "claim_generator": claimGenerator,
            "claim_generator_info": [
                ["name": "Aagedal Photo Agent", "version": version]
            ],
        ]

        if let title {
            manifest["title"] = title
        }

        // Build assertions
        var assertions: [[String: Any]] = []

        // Author assertion (CreativeWork with schema.org context)
        if let author, !author.isEmpty {
            assertions.append([
                "label": "stds.schema-org.CreativeWork",
                "data": [
                    "@context": "https://schema.org",
                    "@type": "CreativeWork",
                    "author": [["@type": "Person", "name": author]],
                ],
            ])
        }

        // Actions assertion
        let actionEntries: [[String: Any]] = actions.map { action in
            var entry: [String: Any] = ["action": action]
            if let digitalSourceType {
                entry["digitalSourceType"] = digitalSourceType
            }
            return entry
        }
        if !actionEntries.isEmpty {
            assertions.append([
                "label": "c2pa.actions",
                "data": ["actions": actionEntries],
            ])
        }

        manifest["assertions"] = assertions

        guard JSONSerialization.isValidJSONObject(manifest) else {
            throw C2PASigningError.manifestSerializationFailed
        }

        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }
}
