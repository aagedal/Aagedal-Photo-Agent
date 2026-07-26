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
        if let v = settings.sharpness, v != 0 { colorParts.append("Sharpness +\(v)") }
        if let v = settings.clarity2012, v != 0 { colorParts.append("Clarity \(v > 0 ? "+" : "")\(v)") }
        if let v = settings.dehaze, v != 0 { colorParts.append("Dehaze \(v > 0 ? "+" : "")\(v)") }

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

enum C2PAValidationError: Error, LocalizedError {
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .malformedOutput:
            return "c2patool returned unsupported validation output"
        }
    }
}

/// Small, file-version-aware cache. Validation is deliberately opt-in from the
/// inspector; no metadata or thumbnail path reads this cache.
private actor C2PAValidationCache {
    struct FileVersion: Equatable {
        let modificationDate: Date?
        let size: UInt64
        /// A changed trust list can turn an otherwise identical asset from
        /// "trust not checked" or "untrusted" into trusted, so it is part of
        /// the cache identity as well as the asset's own file version.
        let trustListModificationDates: [Date?]
    }

    private var values: [URL: (FileVersion, C2PAValidationResult)] = [:]

    func value(for url: URL, version: FileVersion) -> C2PAValidationResult? {
        guard let cached = values[url], cached.0 == version else { return nil }
        return cached.1
    }

    func store(_ result: C2PAValidationResult, for url: URL, version: FileVersion) {
        values[url] = (version, result)
    }

    func removeValue(for url: URL) {
        values.removeValue(forKey: url)
    }
}

nonisolated enum C2PASigningService {

    private static let validationCache = C2PAValidationCache()

    // MARK: - Discovery

    static var c2patoolPath: String? {
        Bundle.main.path(forResource: "c2patool", ofType: nil)
    }

    static var isAvailable: Bool {
        c2patoolPath != nil
    }

    // MARK: - Validation

    /// Validates the C2PA store using the bundled `c2patool` and local C2PA trust
    /// lists. The current official list is primary; the frozen interim list is a
    /// compatibility fallback for credentials created before the official program.
    static func validate(imageURL: URL) async throws -> C2PAValidationResult {
        try await validate(imageURL: imageURL, forceRefresh: false)
    }

    static func validate(imageURL: URL, forceRefresh: Bool) async throws -> C2PAValidationResult {
        guard let toolPath = c2patoolPath else {
            throw C2PASigningError.c2patoolMissing
        }

        let normalizedURL = imageURL.standardizedFileURL
        let trustConfigurations = await C2PATrustListService.shared.cachedTrustConfigurations()
        let attributes = try FileManager.default.attributesOfItem(atPath: normalizedURL.path(percentEncoded: false))
        let trustListModificationDates = trustConfigurations.flatMap(\.fileURLs).map {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let version = C2PAValidationCache.FileVersion(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            trustListModificationDates: trustListModificationDates
        )
        if !forceRefresh, let cached = await validationCache.value(for: normalizedURL, version: version) {
            return cached
        }

        var result: C2PAValidationResult
        if let primaryConfiguration = trustConfigurations.first {
            result = try await validationResult(
                toolPath: toolPath,
                imageURL: normalizedURL,
                trustConfiguration: primaryConfiguration
            )
            if result.status == .trusted {
                result = withTrustSource(result, primaryConfiguration.source)
            }
            // Existing credentials often predate the official program. Check the
            // frozen interim list only when the official list did not recognize an
            // otherwise valid signature, never to override an invalid result.
            if result.status == .untrusted {
                for compatibilityConfiguration in trustConfigurations.dropFirst() {
                    let compatibilityResult = try await validationResult(
                        toolPath: toolPath,
                        imageURL: normalizedURL,
                        trustConfiguration: compatibilityConfiguration
                    )
                    if compatibilityResult.status == .trusted {
                        result = C2PAValidationResult(
                            status: .trusted,
                            signer: compatibilityResult.signer,
                            issuer: compatibilityResult.issuer,
                            message: "The signature is valid and trusted by the legacy C2PA compatibility list.",
                            rawValidationCodes: compatibilityResult.rawValidationCodes,
                            trustSource: compatibilityConfiguration.source
                        )
                        break
                    }
                }
            }
        } else {
            result = try await validationResult(toolPath: toolPath, imageURL: normalizedURL, trustConfiguration: nil)
        }
        if trustConfigurations.isEmpty, result.status == .untrusted {
            result = C2PAValidationResult(
                status: .trustNotConfigured,
                signer: result.signer,
                issuer: result.issuer,
                message: "The signature is valid, but no C2PA trust list is available to check its signer.",
                rawValidationCodes: result.rawValidationCodes
            )
        }
        await validationCache.store(result, for: normalizedURL, version: version)
        return result
    }

    private static func validationResult(
        toolPath: String,
        imageURL: URL,
        trustConfiguration: C2PATrustConfiguration?
    ) async throws -> C2PAValidationResult {
        var arguments = [imageURL.path(percentEncoded: false)]
        if let trustConfiguration {
            arguments.append("trust")
            arguments.append(contentsOf: trustConfiguration.arguments)
        }
        // Process.run is cancellation-aware and terminates c2patool when the detail
        // sheet closes. Validation failures may use a non-zero status while still
        // supplying a useful JSON report on stdout.
        let output = try await Process.run(
            executableURL: URL(fileURLWithPath: toolPath),
            arguments: arguments,
            allowNonZeroExit: true
        )
        try Task.checkCancellation()
        guard !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw C2PASigningError.processFailed(detail.isEmpty ? "c2patool produced no validation report" : detail)
        }
        do {
            return try parseValidationInfoJSON(Data(output.stdout.utf8))
        } catch {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                throw C2PASigningError.processFailed(detail)
            }
            throw error
        }
    }

    static func invalidateValidationCache(for imageURL: URL) async {
        await validationCache.removeValue(for: imageURL.standardizedFileURL)
    }

    private static func withTrustSource(_ result: C2PAValidationResult, _ source: C2PATrustSource) -> C2PAValidationResult {
        C2PAValidationResult(
            status: result.status,
            signer: result.signer,
            issuer: result.issuer,
            message: result.message,
            rawValidationCodes: result.rawValidationCodes,
            trustSource: source
        )
    }

    /// Parses the default `c2patool <image>` JSON report. Kept independent of SwiftExif's
    /// manifest decoding so c2patool format changes cannot affect metadata display.
    static func parseValidationInfoJSON(_ data: Data) throws -> C2PAValidationResult {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let root = jsonObject as? [String: Any] else {
            throw C2PAValidationError.malformedOutput
        }

        let state = (root["validation_state"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let entries = validationEntries(in: root["validation_status"])
        let codes = entries.compactMap(\.code)
        // `signingCredential.untrusted` is a trust warning, not proof that the
        // signature is broken. c2patool versions may report that warning as false.
        let hasFailures = entries.contains {
            $0.success == false && !($0.code?.lowercased().contains("signingcredential.untrusted") ?? false)
        }
            || state == "invalid"
            || state == "failed"
            || state == "failure"
        let isTrusted = codes.contains { $0.caseInsensitiveCompare("signingCredential.trusted") == .orderedSame }
        let isUntrusted = codes.contains { $0.caseInsensitiveCompare("signingCredential.untrusted") == .orderedSame }
        let signer = stringValue(in: root, keys: ["signer", "signer_name", "signerName", "subject"])
        let issuer = stringValue(in: root, keys: ["issuer", "issuer_name", "issuerName"])
        let explanation = entries.compactMap(\.explanation).first

        if state == nil && entries.isEmpty {
            throw C2PAValidationError.malformedOutput
        }
        if state == "not present" || state == "no manifest" {
            return C2PAValidationResult(status: .notPresent, signer: signer, issuer: issuer, message: "No Content Credentials were found.", rawValidationCodes: codes)
        }
        if hasFailures {
            return C2PAValidationResult(status: .invalid, signer: signer, issuer: issuer, message: explanation ?? "The Content Credentials signature did not validate.", rawValidationCodes: codes)
        }
        // An explicit untrusted credential always wins over a generic state string.
        // Never use substring matching here: "untrusted" itself contains "trusted".
        if isUntrusted || state == "untrusted" || state == "not trusted" || state == "not_trusted" {
            let message = explanation.map {
                "The signature is valid, but signer trust could not be established. \($0)"
            } ?? "The signature is valid, but signer trust could not be established."
            return C2PAValidationResult(status: .untrusted, signer: signer, issuer: issuer, message: message, rawValidationCodes: codes)
        }
        if state == "trusted" || isTrusted {
            return C2PAValidationResult(status: .trusted, signer: signer, issuer: issuer, message: explanation ?? "The signature is valid and the signer is trusted.", rawValidationCodes: codes)
        }
        if state == "valid" {
            return C2PAValidationResult(status: .untrusted, signer: signer, issuer: issuer, message: explanation ?? "The signature is valid, but signer trust could not be established.", rawValidationCodes: codes)
        }
        return C2PAValidationResult(status: .unsupported, signer: signer, issuer: issuer, message: explanation ?? "This c2patool validation format is not supported.", rawValidationCodes: codes)
    }

    private struct ValidationEntry {
        let code: String?
        let success: Bool?
        let explanation: String?
    }

    private static func validationEntries(in value: Any?) -> [ValidationEntry] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.map { value in
            ValidationEntry(
                code: value["code"] as? String,
                success: value["success"] as? Bool ?? value["passed"] as? Bool,
                explanation: value["explanation"] as? String ?? value["message"] as? String
            )
        }
    }

    private static func stringValue(in root: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = root[key] as? String, !value.isEmpty { return value }
        }
        return nil
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
                environment: signingEnvironment(privateKeyPEM)
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
                environment: signingEnvironment(privateKeyPEM)
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
                environment: signingEnvironment(privateKeyPEM)
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
    /// Empty credentials select c2patool's built-in test credential. It is useful for
    /// exercising the workflow but is not trusted by C2PA validators.
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
            "claim_generator": claimGenerator,
            "claim_generator_info": [
                ["name": "Aagedal Photo Agent", "version": version]
            ],
        ]
        if !certificatePath.isEmpty {
            manifest["sign_cert"] = certificatePath
        }

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

    private static func signingEnvironment(_ privateKeyPEM: String) -> [String: String]? {
        privateKeyPEM.isEmpty ? nil : ["C2PA_PRIVATE_KEY": privateKeyPEM]
    }
}

/// Immutable credentials captured before an FTP upload. Rendered derivatives are
/// created after the upload sheet closes, so the view model carries this value into
/// the render pipeline and signs the actual files that will be transferred.
nonisolated struct C2PAUploadSigningConfiguration: Sendable {
    let certificatePath: String
    let privateKeyPEM: String
    let author: String?
    let usesTestCertificate: Bool

    func sign(_ imageURL: URL) async throws {
        try await C2PASigningService.sign(
            imageURL: imageURL,
            certificatePath: usesTestCertificate ? "" : certificatePath,
            privateKeyPEM: privateKeyPEM,
            author: author?.isEmpty == true ? nil : author
        )
    }
}

/// Immutable credentials captured before archiving a C2PA-protected RAW.
/// The archive receives a new signature and links the source credential as its
/// parent ingredient, preserving provenance without copying an invalid signature.
nonisolated struct C2PAArchiveSigningConfiguration: Sendable {
    let certificatePath: String
    let privateKeyPEM: String
    let author: String?
    let usesTestCertificate: Bool

    func sign(
        archiveURL: URL,
        parentURL: URL,
        format: RAWArchiveFormat
    ) async throws {
        try await C2PASigningService.signWithParentIngredient(
            imageURL: archiveURL,
            parentURL: parentURL,
            certificatePath: usesTestCertificate ? "" : certificatePath,
            privateKeyPEM: privateKeyPEM,
            author: author?.isEmpty == true ? nil : author,
            actions: [
                C2PAAction(
                    action: format.c2paActionName,
                    description: format.c2paActionDescription
                )
            ]
        )
    }
}
