import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "C2PASigning")

// MARK: - C2PA Action Model

nonisolated struct C2PAAction: Sendable {
    let action: String
    let softwareAgent: String?
    let description: String?
    let digitalSourceType: String?

    init(action: String, softwareAgent: String? = nil, description: String? = nil, digitalSourceType: String? = nil) {
        self.action = action
        self.softwareAgent = softwareAgent
        self.description = description
        self.digitalSourceType = digitalSourceType
    }
}

// MainActor extension for building actions from MainActor-isolated CameraRawSettings
extension C2PAAction {
    /// Build detailed C2PA actions describing what edits were applied.
    @MainActor
    static func fromSettings(_ settings: CameraRawSettings?, claimGenerator: String? = nil) -> [C2PAAction] {
        guard let settings, !settings.isEmpty else {
            return [C2PAAction(action: "c2pa.created")]
        }

        var actions: [C2PAAction] = [C2PAAction(action: "c2pa.opened", softwareAgent: claimGenerator)]

        // Color / tonal adjustments
        var colorParts: [String] = []
        if let v = settings.exposure2012, v != 0 { colorParts.append("Exposure \(v >= 0 ? "+" : "")\(String(format: "%.2f", v))") }
        if let v = settings.contrast2012, v != 0 { colorParts.append("Contrast \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.highlights2012, v != 0 { colorParts.append("Highlights \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.shadows2012, v != 0 { colorParts.append("Shadows \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.whites2012, v != 0 { colorParts.append("Whites \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.blacks2012, v != 0 { colorParts.append("Blacks \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.saturation, v != 0 { colorParts.append("Saturation \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.vibrance, v != 0 { colorParts.append("Vibrance \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.globalDensity, v != 0 { colorParts.append("Density \(v > 0 ? "+" : "")\(v)") }

        // White balance
        if let temp = settings.temperature ?? settings.incrementalTemperature,
           let tintVal = settings.tint ?? settings.incrementalTint {
            colorParts.append("White Balance \(temp)K/\(tintVal > 0 ? "+" : "")\(tintVal)")
        } else if let temp = settings.temperature ?? settings.incrementalTemperature {
            colorParts.append("White Balance \(temp)K")
        }

        // Tone curve
        if let curve = settings.toneCurve, !curve.isEmpty {
            colorParts.append("Tone curve adjusted")
        }

        // HDR tone mapping
        if settings.hdrEditMode == 1 {
            colorParts.append("HDR tone mapping")
        }

        if !colorParts.isEmpty {
            actions.append(C2PAAction(
                action: "c2pa.color_adjustments",
                softwareAgent: claimGenerator,
                description: colorParts.joined(separator: ", ")
            ))
        }

        // Crop
        if let crop = settings.crop, !(crop.isEmpty) {
            var cropDesc = "Image cropped"
            if let angle = crop.angle, abs(angle) > 0.01 {
                cropDesc += String(format: ", rotated %.1f°", angle)
            }
            actions.append(C2PAAction(
                action: "c2pa.cropped",
                softwareAgent: claimGenerator,
                description: cropDesc
            ))
        }

        // Local mask adjustments
        if let masks = settings.localAdjustments, !masks.isEmpty {
            let activeMasks = masks.filter { $0.enabled && $0.hasAdjustments }
            if !activeMasks.isEmpty {
                actions.append(C2PAAction(
                    action: "c2pa.edited",
                    softwareAgent: claimGenerator,
                    description: "\(activeMasks.count) local mask adjustment\(activeMasks.count == 1 ? "" : "s")"
                ))
            }
        }

        // General edited action
        actions.append(C2PAAction(action: "c2pa.edited", softwareAgent: claimGenerator))

        return actions
    }
}

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
    static func sign(
        imageURL: URL,
        certificatePath: String,
        privateKeyPEM: String,
        author: String?,
        actions: [C2PAAction] = [C2PAAction(action: "c2pa.created")],
        digitalSourceType: String? = nil
    ) async throws {
        guard let toolPath = c2patoolPath else {
            throw C2PASigningError.c2patoolMissing
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let tempDir = FileManager.default.temporaryDirectory
        let manifestFile = tempDir.appendingPathComponent("c2pa_manifest_\(UUID().uuidString).json")
        let outputFile = tempDir.appendingPathComponent("c2pa_output_\(UUID().uuidString)_\(imageURL.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Build manifest JSON; the private key is passed via the environment, not on disk.
        let claimGenerator = "Aagedal Photo Agent/\(appVersion)"
        let effectiveActions = actions.map { a in
            C2PAAction(
                action: a.action,
                softwareAgent: a.softwareAgent ?? claimGenerator,
                description: a.description,
                digitalSourceType: a.digitalSourceType ?? digitalSourceType
            )
        }
        let manifestData = try buildManifestJSON(
            title: imageURL.lastPathComponent,
            author: author,
            actions: effectiveActions,
            certificatePath: certificatePath,
            claimGenerator: claimGenerator
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
                arguments: arguments,
                environment: ["C2PA_PRIVATE_KEY": privateKeyPEM]
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
        do {
            try FileManager.default.moveItem(at: outputFile, to: imageURL)
        } catch {
            // Restore the original to prevent data loss if the second move fails.
            try? FileManager.default.moveItem(at: backupURL, to: imageURL)
            throw error
        }

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
        actions: [C2PAAction] = [C2PAAction(action: "c2pa.opened"), C2PAAction(action: "c2pa.edited")],
        digitalSourceType: String? = nil
    ) async throws {
        guard let toolPath = c2patoolPath else {
            throw C2PASigningError.c2patoolMissing
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let tempDir = FileManager.default.temporaryDirectory
        let ingredientDir = tempDir.appendingPathComponent("c2pa_ingredient_\(UUID().uuidString)")
        let manifestFile = tempDir.appendingPathComponent("c2pa_manifest_\(UUID().uuidString).json")
        let outputFile = tempDir.appendingPathComponent("c2pa_output_\(UUID().uuidString)_\(imageURL.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: ingredientDir)
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

        // Step 2: Build manifest (the private key is passed via the environment, not on disk)
        let claimGenerator = "Aagedal Photo Agent/\(appVersion)"
        let effectiveActions = actions.map { a in
            C2PAAction(
                action: a.action,
                softwareAgent: a.softwareAgent ?? claimGenerator,
                description: a.description,
                digitalSourceType: a.digitalSourceType ?? digitalSourceType
            )
        }
        let manifestData = try buildManifestJSON(
            title: imageURL.lastPathComponent,
            author: author,
            actions: effectiveActions,
            certificatePath: certificatePath,
            claimGenerator: claimGenerator
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
                arguments: signArguments,
                environment: ["C2PA_PRIVATE_KEY": privateKeyPEM]
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
        do {
            try FileManager.default.moveItem(at: outputFile, to: imageURL)
        } catch {
            try? FileManager.default.moveItem(at: backupURL, to: imageURL)
            throw error
        }

        if let creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate],
                ofItemAtPath: imagePath
            )
        }

        logger.info("Re-signed successfully: \(imageURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Sign Rendered Image with Parent Ingredient

    /// Sign a rendered image, preserving C2PA history from the original source.
    ///
    /// The rendered output is a new file without C2PA. The parent source may have
    /// existing C2PA data that should be preserved as a parent ingredient.
    static func signWithParentIngredient(
        imageURL: URL,
        parentURL: URL,
        certificatePath: String,
        privateKeyPEM: String,
        author: String?,
        actions: [C2PAAction]
    ) async throws {
        guard let toolPath = c2patoolPath else {
            throw C2PASigningError.c2patoolMissing
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let tempDir = FileManager.default.temporaryDirectory
        let ingredientDir = tempDir.appendingPathComponent("c2pa_ingredient_\(UUID().uuidString)")
        let manifestFile = tempDir.appendingPathComponent("c2pa_manifest_\(UUID().uuidString).json")
        let outputFile = tempDir.appendingPathComponent("c2pa_output_\(UUID().uuidString)_\(imageURL.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: ingredientDir)
            try? FileManager.default.removeItem(at: manifestFile)
            try? FileManager.default.removeItem(at: outputFile)
        }

        // Step 1: Extract ingredient data from the parent (original signed) image
        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: toolPath),
                arguments: [parentURL.path(percentEncoded: false), "--ingredient", "-o", ingredientDir.path(percentEncoded: false)]
            )
        } catch {
            let message = error.localizedDescription
            logger.error("c2patool ingredient extraction failed: \(message, privacy: .public)")
            throw C2PASigningError.processFailed("Ingredient extraction failed: \(message)")
        }

        // Step 2: Build manifest (the private key is passed via the environment, not on disk)
        let claimGenerator = "Aagedal Photo Agent/\(appVersion)"
        let effectiveActions = actions.map { a in
            C2PAAction(
                action: a.action,
                softwareAgent: a.softwareAgent ?? claimGenerator,
                description: a.description,
                digitalSourceType: a.digitalSourceType
            )
        }
        let manifestData = try buildManifestJSON(
            title: imageURL.lastPathComponent,
            author: author,
            actions: effectiveActions,
            certificatePath: certificatePath,
            claimGenerator: claimGenerator
        )
        try manifestData.write(to: manifestFile)

        // Step 3: Sign rendered output with parent ingredient
        let imagePath = imageURL.path(percentEncoded: false)
        let signArguments = [
            imagePath,
            "-m", manifestFile.path(percentEncoded: false),
            "-p", ingredientDir.path(percentEncoded: false),
            "-o", outputFile.path(percentEncoded: false),
            "-f",
        ]

        logger.info("Signing rendered image with parent ingredient: \(imageURL.lastPathComponent, privacy: .public)")

        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: toolPath),
                arguments: signArguments,
                environment: ["C2PA_PRIVATE_KEY": privateKeyPEM]
            )
        } catch {
            let message = error.localizedDescription
            logger.error("c2patool signing failed: \(message, privacy: .public)")
            throw C2PASigningError.processFailed(message)
        }

        guard FileManager.default.fileExists(atPath: outputFile.path(percentEncoded: false)) else {
            throw C2PASigningError.outputMissing
        }

        // Replace rendered output with signed version
        let backupURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(imageURL.lastPathComponent).c2pa_backup")
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath)
        let creationDate = attrs?[.creationDate] as? Date

        try FileManager.default.moveItem(at: imageURL, to: backupURL)
        do {
            try FileManager.default.moveItem(at: outputFile, to: imageURL)
        } catch {
            try? FileManager.default.moveItem(at: backupURL, to: imageURL)
            throw error
        }

        if let creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate],
                ofItemAtPath: imagePath
            )
        }

        logger.info("Signed with parent ingredient: \(imageURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Manifest Builder

    /// Build c2patool manifest definition JSON.
    ///
    /// The signing certificate is referenced by path via `sign_cert`. The private key
    /// is intentionally NOT placed here: it is passed to c2patool through the
    /// `C2PA_PRIVATE_KEY` environment variable instead, so it never touches the disk.
    static func buildManifestJSON(
        title: String?,
        author: String?,
        actions: [C2PAAction],
        certificatePath: String,
        claimGenerator: String
    ) throws -> Data {
        let version = claimGenerator.components(separatedBy: "/").last ?? "0.0.0"

        var manifest: [String: Any] = [
            "alg": "es256",
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

        // Actions assertion with structured entries
        let actionEntries: [[String: Any]] = actions.map { action in
            var entry: [String: Any] = ["action": action.action]
            if let softwareAgent = action.softwareAgent {
                entry["softwareAgent"] = softwareAgent
            }
            if let description = action.description {
                entry["parameters"] = ["description": description]
            }
            if let digitalSourceType = action.digitalSourceType {
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
