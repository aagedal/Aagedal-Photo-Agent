import CryptoKit
import Foundation

nonisolated enum DevelopVersionFlushReason: Equatable, Sendable {
    case imageNavigation
    case workspaceExit
    case applicationTermination
}

nonisolated enum DevelopVersionFlushOutcome: Equatable, Sendable {
    case succeeded
    case failed(String)
}

/// Bridges the active Develop workspace to app-level transitions that must wait for its named
/// version JSON to reach durable storage. Registrations are token-owned so a disappearing stale
/// view cannot unregister a newer workspace that has already taken its place.
@MainActor
final class DevelopVersionFlushCoordinator {
    typealias Handler = @MainActor (DevelopVersionFlushReason) async -> DevelopVersionFlushOutcome

    static let shared = DevelopVersionFlushCoordinator()

    private var registration: (id: UUID, handler: Handler)?
    private var inFlightFlush: (id: UUID, task: Task<DevelopVersionFlushOutcome, Never>)?

    var hasRegisteredHandler: Bool { registration != nil }

    @discardableResult
    func register(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        registration = (id, handler)
        return id
    }

    func unregister(_ id: UUID) {
        guard registration?.id == id else { return }
        registration = nil
    }

    func flush(_ reason: DevelopVersionFlushReason) async -> DevelopVersionFlushOutcome {
        if let inFlightFlush {
            return await inFlightFlush.task.value
        }
        guard let handler = registration?.handler else { return .succeeded }
        let id = UUID()
        let task = Task { @MainActor in await handler(reason) }
        inFlightFlush = (id, task)
        let outcome = await task.value
        if inFlightFlush?.id == id {
            inFlightFlush = nil
        }
        return outcome
    }
}

/// An external or embedded resource needed to reproduce a named Develop version.
nonisolated struct DevelopVersionDependency: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case watermark
        case lut
        case aiMask
        case preservedCorrection
    }

    let kind: Kind
    /// Stable library identity for external assets, or a source-local identity for embedded data.
    let identifier: String
    /// Lowercase SHA-256 when bytes are available at snapshot time.
    let sha256: String?
    let isEmbedded: Bool
}

nonisolated enum DevelopVersionDependencyStatus: Equatable, Sendable {
    case resolved
    case changed
    case missing
    case unsupported
}

/// The current resolution state of one dependency recorded by a named Develop snapshot.
nonisolated struct DevelopVersionDependencyDiagnostic: Equatable, Sendable {
    let dependency: DevelopVersionDependency
    let status: DevelopVersionDependencyStatus
}

/// The exact source-bound Develop payload stored by a named version.
///
/// Unlike `DevelopTemplate`, this deliberately retains decoder/process state, as-shot white
/// balance, unknown Adobe corrections, layer identities, and source-bound geometry. Only the
/// transient render hint `sourceHasHDRHeadroom` is removed.
nonisolated struct DevelopVersionSnapshot: Codable, Equatable, Sendable {
    static let currentSettingsSchemaVersion = 1

    let settingsSchemaVersion: Int
    let settings: CameraRawSettings
    let dependencyManifest: [DevelopVersionDependency]

    init(
        settings: CameraRawSettings,
        watermarkDataProvider: (UUID) -> Data? = { _ in nil },
        preservingExternalDependencies previousManifest: [DevelopVersionDependency] = []
    ) {
        var persisted = settings
        persisted.sourceHasHDRHeadroom = nil
        self.settingsSchemaVersion = Self.currentSettingsSchemaVersion
        self.settings = persisted
        var dependencies = Self.dependencies(
            in: persisted,
            watermarkDataProvider: watermarkDataProvider
        )
        // Editing an unrelated slider must not silently bless replacement bytes for an existing
        // external asset. Keep the hash contract captured when the reference was first added;
        // legacy nil hashes are upgraded when bytes are available.
        let previousHashes = previousManifest.reduce(into: [String: String]()) { result, dependency in
            guard !dependency.isEmbedded, let sha256 = dependency.sha256 else { return }
            result["\(dependency.kind.rawValue)|\(dependency.identifier)"] = sha256
        }
        for index in dependencies.indices where !dependencies[index].isEmbedded {
            let key = "\(dependencies[index].kind.rawValue)|\(dependencies[index].identifier)"
            guard let previousHash = previousHashes[key] else { continue }
            dependencies[index] = DevelopVersionDependency(
                kind: dependencies[index].kind,
                identifier: dependencies[index].identifier,
                sha256: previousHash,
                isEmbedded: false
            )
        }
        self.dependencyManifest = dependencies
    }

    func validate() -> Bool {
        guard settingsSchemaVersion == Self.currentSettingsSchemaVersion,
              settings.sourceHasHDRHeadroom == nil else { return false }

        // Embedded payloads must still hash exactly. External watermark hashes cannot be
        // recomputed while decoding a catalog (the library may be offline), so accept either a
        // legacy nil hash or a well-formed recorded hash while still requiring exact identity.
        let expected = Self.dependencies(in: settings)
        guard expected.count == dependencyManifest.count else { return false }
        return zip(expected, dependencyManifest).allSatisfy { expected, recorded in
            guard expected.kind == recorded.kind,
                  expected.identifier == recorded.identifier,
                  expected.isEmbedded == recorded.isEmbedded else { return false }
            if expected.isEmbedded {
                return expected.sha256 == recorded.sha256
            }
            return recorded.sha256 == nil || Self.isValidSHA256(recorded.sha256)
        }
    }

    /// Resolves dependencies without mutating the snapshot. Embedded resources are already
    /// verified by `validate`; watermark bytes are looked up lazily so an offline iCloud library
    /// produces a visible missing state instead of making the catalog unreadable.
    func dependencyDiagnostics(
        watermarkDataProvider: (UUID) -> Data?
    ) -> [DevelopVersionDependencyDiagnostic] {
        dependencyManifest.map { dependency in
            guard dependency.kind == .watermark, !dependency.isEmbedded else {
                return DevelopVersionDependencyDiagnostic(
                    dependency: dependency,
                    status: .resolved
                )
            }
            guard let id = UUID(uuidString: dependency.identifier) else {
                return DevelopVersionDependencyDiagnostic(
                    dependency: dependency,
                    status: .unsupported
                )
            }
            guard let data = watermarkDataProvider(id), !data.isEmpty else {
                return DevelopVersionDependencyDiagnostic(
                    dependency: dependency,
                    status: .missing
                )
            }
            // Catalogs created before watermark hashing remain usable: presence is known, but
            // their historical bytes cannot be reconstructed for a changed-content comparison.
            guard let expectedHash = dependency.sha256 else {
                return DevelopVersionDependencyDiagnostic(
                    dependency: dependency,
                    status: .resolved
                )
            }
            return DevelopVersionDependencyDiagnostic(
                dependency: dependency,
                status: Self.sha256(data) == expectedHash ? .resolved : .changed
            )
        }
    }

    private static func dependencies(
        in settings: CameraRawSettings,
        watermarkDataProvider: (UUID) -> Data? = { _ in nil }
    ) -> [DevelopVersionDependency] {
        var dependencies: [DevelopVersionDependency] = []

        for watermark in settings.watermarkLayers ?? [] {
            let data = watermarkDataProvider(watermark.libraryAssetID)
            dependencies.append(DevelopVersionDependency(
                kind: .watermark,
                identifier: watermark.libraryAssetID.uuidString.lowercased(),
                sha256: data.flatMap { $0.isEmpty ? nil : Self.sha256($0) },
                isEmbedded: false
            ))
        }

        for mask in settings.localAdjustments ?? [] {
            if let transform = mask.colorTransform,
               transform.mode == .lut,
               let data = transform.lutData,
               !data.isEmpty {
                let digest = Self.sha256(data)
                dependencies.append(DevelopVersionDependency(
                    kind: .lut,
                    identifier: transform.lutName?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilIfEmpty ?? digest,
                    sha256: digest,
                    isEmbedded: true
                ))
            }
            if let aiMask = mask.aiMask, !aiMask.pngData.isEmpty {
                dependencies.append(DevelopVersionDependency(
                    kind: .aiMask,
                    identifier: mask.id.uuidString.lowercased(),
                    sha256: Self.sha256(aiMask.pngData),
                    isEmbedded: true
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (index, correction) in (settings.unparsedMaskCorrections ?? []).enumerated() {
            guard let data = try? encoder.encode(correction) else { continue }
            dependencies.append(DevelopVersionDependency(
                kind: .preservedCorrection,
                identifier: "correction-\(index)",
                sha256: Self.sha256(data),
                isEmbedded: true
            ))
        }

        return dependencies.sorted {
            ($0.kind.rawValue, $0.identifier, $0.sha256 ?? "")
                < ($1.kind.rawValue, $1.identifier, $1.sha256 ?? "")
        }
    }

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).lowercaseHexString
    }

    private static func isValidSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }
}

nonisolated struct DevelopNamedVersion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    let createdByAppVersion: String
    let createdByAppBuild: String
    var snapshot: DevelopVersionSnapshot
    var notes: String?

    var summary: String {
        var parts: [String] = []
        if snapshot.settings.hasVersionGlobalAdjustments { parts.append("Global") }
        if snapshot.settings.crop?.isEffectiveCrop == true { parts.append("Crop") }
        if let count = snapshot.settings.localAdjustments?.count, count > 0 {
            parts.append("\(count) layer\(count == 1 ? "" : "s")")
        }
        if let count = snapshot.settings.watermarkLayers?.count, count > 0 {
            parts.append("\(count) watermark\(count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No adjustments" : parts.joined(separator: " • ")
    }
}

nonisolated enum DevelopVersionCatalogValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSourceHash
    case invalidTimestamps
    case duplicateVersionID
    case invalidVersionName
    case invalidVersionSnapshot
    case missingActiveVersion
    case missingDefaultVersion

    var errorDescription: String? {
        switch self {
        case .invalidSourceHash:
            "The version catalog is not bound to a valid SHA-256 source revision."
        case .invalidTimestamps:
            "The version catalog contains invalid creation or modification times."
        case .duplicateVersionID:
            "The version catalog contains duplicate version identifiers."
        case .invalidVersionName:
            "Every named version must have a non-empty name."
        case .invalidVersionSnapshot:
            "A named version contains an unsupported or transient Develop snapshot."
        case .missingActiveVersion:
            "The active named version is not present in the catalog."
        case .missingDefaultVersion:
            "The default named version is not present in the catalog."
        }
    }
}

nonisolated enum DevelopVersionCatalogMutationError: Error, Equatable, LocalizedError, Sendable {
    case versionNotFound
    case invalidName

    var errorDescription: String? {
        switch self {
        case .versionNotFound: "The named version could not be found."
        case .invalidName: "Enter a name for the version."
        }
    }
}

/// The durable catalog state prepared before a named version crosses into the XMP-backed Primary.
/// The recovery version is already part of `catalog`, while the source named version remains
/// intact and active until XMP read-back succeeds.
nonisolated struct DevelopVersionPromotionPreparation: Equatable, Sendable {
    let catalog: DevelopVersionCatalog
    let sourceVersionID: UUID
    let recoveryVersionID: UUID
    let promotedSettings: CameraRawSettings
}

nonisolated enum DevelopVersionGeometryCompatibility: Equatable, Sendable {
    /// None of the catalog's snapshots contain crop, mask, watermark, or preserved correction
    /// state whose meaning depends on the source coordinate system.
    case noSourceBoundGeometry
    /// Both revisions have the same known pixel dimensions and EXIF orientation.
    case compatible
    /// Geometry is present and the revisions either differ or do not contain enough metadata to
    /// prove that their coordinate systems agree.
    case requiresExplicitChoice
}

/// The caller's geometry decision when explicitly copying a catalog to changed source bytes.
nonisolated enum DevelopVersionGeometryReassociationChoice: Equatable, Sendable {
    /// Refuse reassociation unless the old and new coordinate systems are known to match.
    case requireCompatibleGeometry
    /// Keep the catalog's normalized crop and layer coordinates. This is an explicit user choice;
    /// the old source-bound catalog remains available if the result is not meaningful.
    case keepNormalizedCoordinates
}

nonisolated enum DevelopVersionCatalogReassociationError: Error, Equatable, LocalizedError, Sendable {
    case geometryRequiresExplicitChoice

    var errorDescription: String? {
        switch self {
        case .geometryRequiresExplicitChoice:
            "The source dimensions or orientation changed. Choose how to transform the version's crop and layer geometry before reassociating it."
        }
    }
}

/// App-private named Develop versions for one exact source revision.
///
/// Primary remains virtual and XMP-backed; `activeVersionID == nil` means Primary.
nonisolated struct DevelopVersionCatalog: VersionedJSONDocument, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let source: SourceImageRevision
    let createdAt: Date
    var updatedAt: Date
    var activeVersionID: UUID?
    var defaultVersionID: UUID?
    var versions: [DevelopNamedVersion]

    static func create(
        for source: SourceImageRevision,
        now: Date = Date()
    ) -> DevelopVersionCatalog {
        DevelopVersionCatalog(
            schemaVersion: currentSchemaVersion,
            source: source,
            createdAt: now,
            updatedAt: now,
            activeVersionID: nil,
            defaultVersionID: nil,
            versions: []
        )
    }

    /// Describes whether every source-bound snapshot can retain its normalized geometry on a
    /// different source revision without further user input.
    func geometryCompatibility(
        with target: SourceImageRevision
    ) -> DevelopVersionGeometryCompatibility {
        guard versions.contains(where: { $0.snapshot.settings.hasSourceBoundVersionGeometry }) else {
            return .noSourceBoundGeometry
        }
        guard let sourceWidth = source.pixelWidth,
              let sourceHeight = source.pixelHeight,
              let sourceOrientation = source.exifOrientation,
              let targetWidth = target.pixelWidth,
              let targetHeight = target.pixelHeight,
              let targetOrientation = target.exifOrientation else {
            return .requiresExplicitChoice
        }
        return sourceWidth == targetWidth
            && sourceHeight == targetHeight
            && sourceOrientation == targetOrientation
            ? .compatible
            : .requiresExplicitChoice
    }

    /// Produces a catalog bound to `target` without mutating or deleting this source-bound value.
    ///
    /// A rename or move of the exact bytes only refreshes discovery hints. Changed bytes are an
    /// explicit copy operation and must pass the geometry gate (or carry the caller's explicit
    /// normalized-coordinate choice). The repository persists the returned catalog under the new
    /// source hash, leaving the old catalog recoverable.
    func reassociated(
        to target: SourceImageRevision,
        geometryChoice: DevelopVersionGeometryReassociationChoice = .requireCompatibleGeometry,
        now: Date = Date()
    ) throws -> DevelopVersionCatalog {
        if source.sha256 != target.sha256,
           geometryCompatibility(with: target) == .requiresExplicitChoice,
           geometryChoice == .requireCompatibleGeometry {
            throw DevelopVersionCatalogReassociationError.geometryRequiresExplicitChoice
        }

        return DevelopVersionCatalog(
            schemaVersion: schemaVersion,
            source: target,
            createdAt: createdAt,
            updatedAt: max(updatedAt, now),
            activeVersionID: activeVersionID,
            defaultVersionID: defaultVersionID,
            versions: versions
        )
    }

    @discardableResult
    mutating func createVersion(
        name: String,
        settings: CameraRawSettings,
        notes: String? = nil,
        appVersion: String = DevelopVersionCatalog.currentAppVersion,
        appBuild: String = DevelopVersionCatalog.currentAppBuild,
        watermarkDataProvider: (UUID) -> Data? = { _ in nil },
        now: Date = Date()
    ) throws -> UUID {
        let normalizedName = try Self.normalizedName(name)
        let effectiveNow = max(now, createdAt)
        let version = DevelopNamedVersion(
            id: UUID(),
            name: normalizedName,
            createdAt: effectiveNow,
            updatedAt: effectiveNow,
            createdByAppVersion: appVersion,
            createdByAppBuild: appBuild,
            snapshot: DevelopVersionSnapshot(
                settings: settings,
                watermarkDataProvider: watermarkDataProvider
            ),
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        versions.append(version)
        activeVersionID = version.id
        updatedAt = max(updatedAt, effectiveNow)
        return version.id
    }

    @discardableResult
    mutating func duplicateVersion(
        id: UUID,
        name: String,
        appVersion: String = DevelopVersionCatalog.currentAppVersion,
        appBuild: String = DevelopVersionCatalog.currentAppBuild,
        now: Date = Date()
    ) throws -> UUID {
        guard let sourceVersion = versions.first(where: { $0.id == id }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }
        let normalizedName = try Self.normalizedName(name)
        let effectiveNow = max(now, createdAt)
        let duplicate = DevelopNamedVersion(
            id: UUID(),
            name: normalizedName,
            createdAt: effectiveNow,
            updatedAt: effectiveNow,
            createdByAppVersion: appVersion,
            createdByAppBuild: appBuild,
            snapshot: sourceVersion.snapshot,
            notes: sourceVersion.notes
        )
        versions.append(duplicate)
        activeVersionID = duplicate.id
        updatedAt = max(updatedAt, effectiveNow)
        return duplicate.id
    }

    mutating func renameVersion(id: UUID, name: String, now: Date = Date()) throws {
        guard let index = versions.firstIndex(where: { $0.id == id }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }
        versions[index].name = try Self.normalizedName(name)
        versions[index].updatedAt = max(versions[index].updatedAt, now)
        updatedAt = max(updatedAt, versions[index].updatedAt)
    }

    mutating func updateVersion(
        id: UUID,
        settings: CameraRawSettings,
        watermarkDataProvider: (UUID) -> Data? = { _ in nil },
        now: Date = Date()
    ) throws {
        guard let index = versions.firstIndex(where: { $0.id == id }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }
        let previousManifest = versions[index].snapshot.dependencyManifest
        versions[index].snapshot = DevelopVersionSnapshot(
            settings: settings,
            watermarkDataProvider: watermarkDataProvider,
            preservingExternalDependencies: previousManifest
        )
        versions[index].updatedAt = max(versions[index].updatedAt, now)
        updatedAt = max(updatedAt, versions[index].updatedAt)
    }

    @discardableResult
    mutating func deleteVersion(id: UUID, now: Date = Date()) -> Bool {
        guard let index = versions.firstIndex(where: { $0.id == id }) else { return false }
        versions.remove(at: index)
        if activeVersionID == id { activeVersionID = nil }
        if defaultVersionID == id { defaultVersionID = nil }
        updatedAt = max(updatedAt, now)
        return true
    }

    mutating func setActiveVersion(_ id: UUID?, now: Date = Date()) throws {
        try requireVersion(id)
        activeVersionID = id
        updatedAt = max(updatedAt, now)
    }

    mutating func setDefaultVersion(_ id: UUID?, now: Date = Date()) throws {
        try requireVersion(id)
        defaultVersionID = id
        updatedAt = max(updatedAt, now)
    }

    /// Flushes the named source version and adds a recovery copy of the current virtual Primary.
    /// The source version deliberately stays active until the promotion service has written and
    /// verified XMP, so a failed cross-store transaction never claims Primary is active.
    mutating func preparePromotion(
        of sourceVersionID: UUID,
        currentSettings: CameraRawSettings,
        primarySettings: CameraRawSettings?,
        recoveryName: String,
        appVersion: String = DevelopVersionCatalog.currentAppVersion,
        appBuild: String = DevelopVersionCatalog.currentAppBuild,
        watermarkDataProvider: (UUID) -> Data? = { _ in nil },
        now: Date = Date()
    ) throws -> DevelopVersionPromotionPreparation {
        guard versions.contains(where: { $0.id == sourceVersionID }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }

        if activeVersionID == sourceVersionID {
            try updateVersion(
                id: sourceVersionID,
                settings: currentSettings,
                watermarkDataProvider: watermarkDataProvider,
                now: now
            )
        }
        guard let promoted = versions.first(where: { $0.id == sourceVersionID }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }

        let recoveryVersionID = try createVersion(
            name: recoveryName,
            settings: primarySettings ?? CameraRawSettings(),
            appVersion: appVersion,
            appBuild: appBuild,
            watermarkDataProvider: watermarkDataProvider,
            now: now
        )
        try setActiveVersion(sourceVersionID, now: now)

        return DevelopVersionPromotionPreparation(
            catalog: self,
            sourceVersionID: sourceVersionID,
            recoveryVersionID: recoveryVersionID,
            promotedSettings: promoted.snapshot.settings
        )
    }

    /// Captures the version being left and resolves the complete Develop state to install for the
    /// destination. Callers persist the returned catalog before applying the returned settings so
    /// a failed flush cannot silently switch the editor.
    ///
    /// `nil` remains the virtual, XMP-backed Primary entry and is never serialized as a duplicate
    /// named version.
    mutating func prepareSwitch(
        to targetID: UUID?,
        savingCurrentSettings currentSettings: CameraRawSettings?,
        primarySettings: CameraRawSettings?,
        watermarkDataProvider: (UUID) -> Data? = { _ in nil },
        now: Date = Date()
    ) throws -> CameraRawSettings? {
        try requireVersion(targetID)

        if let activeVersionID {
            try updateVersion(
                id: activeVersionID,
                settings: currentSettings ?? CameraRawSettings(),
                watermarkDataProvider: watermarkDataProvider,
                now: now
            )
        }

        try setActiveVersion(targetID, now: now)
        guard let targetID else { return primarySettings }
        guard let target = versions.first(where: { $0.id == targetID }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }
        return target.snapshot.settings
    }

    func validateForPersistence() throws {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard source.sha256.count == 64,
              source.sha256.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw DevelopVersionCatalogValidationError.invalidSourceHash
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt,
              versions.allSatisfy({
                  $0.createdAt.timeIntervalSinceReferenceDate.isFinite
                      && $0.updatedAt.timeIntervalSinceReferenceDate.isFinite
                      && $0.createdAt >= createdAt
                      && $0.updatedAt >= $0.createdAt
                      && $0.updatedAt <= updatedAt
              }) else {
            throw DevelopVersionCatalogValidationError.invalidTimestamps
        }
        guard Set(versions.map(\.id)).count == versions.count else {
            throw DevelopVersionCatalogValidationError.duplicateVersionID
        }
        guard versions.allSatisfy({
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw DevelopVersionCatalogValidationError.invalidVersionName
        }
        guard versions.allSatisfy({ $0.snapshot.validate() }) else {
            throw DevelopVersionCatalogValidationError.invalidVersionSnapshot
        }
        let versionIDs = Set(versions.map(\.id))
        if let activeVersionID, !versionIDs.contains(activeVersionID) {
            throw DevelopVersionCatalogValidationError.missingActiveVersion
        }
        if let defaultVersionID, !versionIDs.contains(defaultVersionID) {
            throw DevelopVersionCatalogValidationError.missingDefaultVersion
        }
    }

    private func requireVersion(_ id: UUID?) throws {
        guard let id else { return }
        guard versions.contains(where: { $0.id == id }) else {
            throw DevelopVersionCatalogMutationError.versionNotFound
        }
    }

    private static func normalizedName(_ name: String) throws -> String {
        guard let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw DevelopVersionCatalogMutationError.invalidName
        }
        return normalized
    }

    private static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    private static var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

private nonisolated extension CameraRawSettings {
    var hasSourceBoundVersionGeometry: Bool {
        (crop?.isEffectiveCrop ?? false)
            || !(localAdjustments?.isEmpty ?? true)
            || !(watermarkLayers?.isEmpty ?? true)
            || !(unparsedMaskCorrections?.isEmpty ?? true)
    }

    var hasVersionGlobalAdjustments: Bool {
        var copy = self
        copy.crop = nil
        copy.localAdjustments = nil
        copy.watermarkLayers = nil
        copy.unparsedMaskCorrections = nil
        copy.asShotNeutralTemperature = nil
        copy.asShotNeutralTint = nil
        copy.sourceHasHDRHeadroom = nil
        return !copy.isEmpty
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
