import Foundation

nonisolated struct BatchRenameRecipePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var recipe: BatchRenameRecipe
    var collisionChoice: BatchRenameCollisionChoice

    init(
        id: UUID = UUID(),
        recipe: BatchRenameRecipe,
        collisionChoice: BatchRenameCollisionChoice = .block
    ) {
        self.id = id
        self.recipe = recipe
        self.collisionChoice = collisionChoice
    }

    var name: String { recipe.name }
}

nonisolated struct BatchRenameRecipeRepositorySnapshot: Equatable, Sendable {
    let presets: [BatchRenameRecipePreset]
    let selectedPresetID: UUID?

    var selectedPreset: BatchRenameRecipePreset? {
        guard let selectedPresetID else { return nil }
        return presets.first { $0.id == selectedPresetID }
    }
}

nonisolated enum BatchRenameRecipeValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case emptyComponents
    case unsupportedRecipeSchema(found: Int, supported: Int)
    case invalidTimeZone(String)
    case negativeSequencePadding(componentIndex: Int)
    case emptyDateFormat(componentIndex: Int)
    case invalidRegularExpression(substitutionIndex: Int, pattern: String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "A rename recipe must have a name."
        case .emptyComponents:
            "A rename recipe must contain at least one component."
        case let .unsupportedRecipeSchema(found, supported):
            "Rename recipe schema " + String(found) + " is not supported; this app supports "
                + String(supported) + "."
        case let .invalidTimeZone(identifier):
            "The rename recipe timezone is invalid: " + identifier
        case let .negativeSequencePadding(index):
            "Rename component " + String(index + 1) + " has negative sequence padding."
        case let .emptyDateFormat(index):
            "Rename component " + String(index + 1) + " has an empty date format."
        case let .invalidRegularExpression(index, pattern):
            "Rename substitution " + String(index + 1)
                + " has an invalid regular expression: " + pattern
        }
    }
}

nonisolated enum BatchRenameRecipeRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case presetNotFound(UUID)
    case presetAlreadyExists(UUID)
    case duplicatePresetName(String)
    case selectedPresetMissing(UUID)
    case selectionRequired
    case exportDestinationExists(URL)
    case fileTooLarge(found: Int, limit: Int)
    case invalidExportDocument
    case unsupportedExportSchema(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case let .presetNotFound(id):
            "No rename preset exists with ID " + id.uuidString.lowercased() + "."
        case let .presetAlreadyExists(id):
            "A rename preset with ID " + id.uuidString.lowercased() + " already exists."
        case let .duplicatePresetName(name):
            "A rename preset named “" + name + "” already exists."
        case let .selectedPresetMissing(id):
            "The selected rename preset " + id.uuidString.lowercased() + " does not exist."
        case .selectionRequired:
            "A non-empty rename recipe library must have a selected preset."
        case let .exportDestinationExists(url):
            "The export destination already exists: " + url.path
        case let .fileTooLarge(found, limit):
            "The rename preset file is " + String(found) + " bytes; the limit is "
                + String(limit) + " bytes."
        case .invalidExportDocument:
            "The rename preset file is not a supported JSON document."
        case let .unsupportedExportSchema(found, supported):
            "Rename preset file schema " + String(found)
                + " is not supported; this app supports " + String(supported) + "."
        }
    }
}

/// Strict, portable JSON boundary for one recipe preset. Its schema contains recipe data and a
/// stable ID only; it has no place to persist credentials, bookmarks, or other app settings.
nonisolated struct BatchRenameRecipePresetIO: Sendable {
    static let maximumFileSize = 1_048_576

    func encode(_ preset: BatchRenameRecipePreset) throws -> Data {
        try validate(preset)
        let document = ExportDocument(preset: preset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    func decode(_ data: Data) throws -> BatchRenameRecipePreset {
        guard data.count <= Self.maximumFileSize else {
            throw BatchRenameRecipeRepositoryError.fileTooLarge(
                found: data.count,
                limit: Self.maximumFileSize
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw BatchRenameRecipeRepositoryError.invalidExportDocument
        }
        guard version == ExportDocument.currentSchemaVersion else {
            throw BatchRenameRecipeRepositoryError.unsupportedExportSchema(
                found: version,
                supported: ExportDocument.currentSchemaVersion
            )
        }
        let preset = try JSONDecoder().decode(ExportDocument.self, from: data).preset
        try validate(preset)
        return preset
    }

    func importPreset(from source: URL) throws -> BatchRenameRecipePreset {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > Self.maximumFileSize {
            throw BatchRenameRecipeRepositoryError.fileTooLarge(
                found: size,
                limit: Self.maximumFileSize
            )
        }
        return try decode(Data(contentsOf: source, options: .mappedIfSafe))
    }

    func validate(_ preset: BatchRenameRecipePreset) throws {
        try validate(preset.recipe)
    }

    func validate(_ recipe: BatchRenameRecipe) throws {
        guard recipe.schemaVersion == BatchRenameRecipe.currentSchemaVersion else {
            throw BatchRenameRecipeValidationError.unsupportedRecipeSchema(
                found: recipe.schemaVersion,
                supported: BatchRenameRecipe.currentSchemaVersion
            )
        }
        guard !normalizedRenameRecipeName(recipe.name).isEmpty else {
            throw BatchRenameRecipeValidationError.emptyName
        }
        guard !recipe.components.isEmpty else {
            throw BatchRenameRecipeValidationError.emptyComponents
        }
        guard TimeZone(identifier: recipe.timeZoneIdentifier) != nil else {
            throw BatchRenameRecipeValidationError.invalidTimeZone(recipe.timeZoneIdentifier)
        }

        for (index, component) in recipe.components.enumerated() {
            guard case let .token(token) = component else { continue }
            switch token {
            case let .sequence(sequence) where sequence.padding < 0:
                throw BatchRenameRecipeValidationError.negativeSequencePadding(
                    componentIndex: index
                )
            case let .date(date) where date.format.isEmpty:
                throw BatchRenameRecipeValidationError.emptyDateFormat(componentIndex: index)
            default:
                break
            }
        }

        for (index, substitution) in recipe.substitutions.enumerated() {
            guard case let .regularExpression(pattern, _, caseInsensitive, anchorsMatchLines) = substitution else {
                continue
            }
            var options: NSRegularExpression.Options = []
            if caseInsensitive { options.insert(.caseInsensitive) }
            if anchorsMatchLines { options.insert(.anchorsMatchLines) }
            do {
                _ = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                throw BatchRenameRecipeValidationError.invalidRegularExpression(
                    substitutionIndex: index,
                    pattern: pattern
                )
            }
        }
    }

    private struct ExportDocument: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion = Self.currentSchemaVersion
        let preset: BatchRenameRecipePreset
    }
}

/// Atomic local persistence for reusable batch-rename recipes.
actor BatchRenameRecipeRepository {
    let documentURL: URL

    private let presetIO: BatchRenameRecipePresetIO
    private let store: AtomicJSONDocumentStore<BatchRenameRecipeRepositoryDocument>
    private let testingPauseAfterLoad: (@Sendable () async -> Void)?
    private var hasExclusiveAccess = false
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        documentURL: URL,
        presetIO: BatchRenameRecipePresetIO = BatchRenameRecipePresetIO(),
        testingPauseAfterLoad: (@Sendable () async -> Void)? = nil
    ) {
        self.documentURL = documentURL
        self.presetIO = presetIO
        self.testingPauseAfterLoad = testingPauseAfterLoad
        store = AtomicJSONDocumentStore(documentURL: documentURL)
    }

    func snapshot() async throws -> BatchRenameRecipeRepositorySnapshot {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        return snapshot(from: try await loadDocument())
    }

    @discardableResult
    func create(
        recipe: BatchRenameRecipe,
        collisionChoice: BatchRenameCollisionChoice = .block,
        id: UUID = UUID()
    ) async throws -> BatchRenameRecipePreset {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        await testingPauseAfterLoad?()
        guard !document.presets.contains(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetAlreadyExists(id)
        }
        var normalizedRecipe = recipe
        normalizedRecipe.name = normalizedRenameRecipeName(recipe.name)
        let preset = BatchRenameRecipePreset(
            id: id,
            recipe: normalizedRecipe,
            collisionChoice: collisionChoice
        )
        try validateUniqueName(preset.name, excluding: nil, in: document.presets)
        try presetIO.validate(preset)
        document.presets.append(preset)
        document.selectedPresetID = document.selectedPresetID ?? id
        try await save(document)
        return preset
    }

    func update(
        id: UUID,
        recipe: BatchRenameRecipe,
        collisionChoice: BatchRenameCollisionChoice
    ) async throws -> BatchRenameRecipePreset {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard let index = document.presets.firstIndex(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetNotFound(id)
        }
        var normalizedRecipe = recipe
        normalizedRecipe.name = normalizedRenameRecipeName(recipe.name)
        let preset = BatchRenameRecipePreset(
            id: id,
            recipe: normalizedRecipe,
            collisionChoice: collisionChoice
        )
        try validateUniqueName(preset.name, excluding: id, in: document.presets)
        try presetIO.validate(preset)
        document.presets[index] = preset
        try await save(document)
        return preset
    }

    @discardableResult
    func duplicate(
        id: UUID,
        newName: String? = nil,
        newID: UUID = UUID()
    ) async throws -> BatchRenameRecipePreset {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard let source = document.presets.first(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetNotFound(id)
        }
        guard !document.presets.contains(where: { $0.id == newID }) else {
            throw BatchRenameRecipeRepositoryError.presetAlreadyExists(newID)
        }
        let name: String
        if let newName {
            name = normalizedRenameRecipeName(newName)
            try validateUniqueName(name, excluding: nil, in: document.presets)
        } else {
            name = nextCopyName(for: source.name, presets: document.presets)
        }
        var recipe = source.recipe
        recipe.name = name
        let duplicate = BatchRenameRecipePreset(
            id: newID,
            recipe: recipe,
            collisionChoice: source.collisionChoice
        )
        try presetIO.validate(duplicate)
        document.presets.append(duplicate)
        try await save(document)
        return duplicate
    }

    @discardableResult
    func rename(id: UUID, to name: String) async throws -> BatchRenameRecipePreset {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard let index = document.presets.firstIndex(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetNotFound(id)
        }
        let normalized = normalizedRenameRecipeName(name)
        try validateUniqueName(normalized, excluding: id, in: document.presets)
        var preset = document.presets[index]
        preset.recipe.name = normalized
        try presetIO.validate(preset)
        document.presets[index] = preset
        try await save(document)
        return preset
    }

    @discardableResult
    func importPreset(from source: URL) async throws -> BatchRenameRecipePreset {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        let imported = try presetIO.importPreset(from: source)
        var document = try await loadDocument()
        guard !document.presets.contains(where: { $0.id == imported.id }) else {
            throw BatchRenameRecipeRepositoryError.presetAlreadyExists(imported.id)
        }
        try validateUniqueName(imported.name, excluding: nil, in: document.presets)
        document.presets.append(imported)
        document.selectedPresetID = document.selectedPresetID ?? imported.id
        try await save(document)
        return imported
    }

    func exportPreset(id: UUID, to destination: URL) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        let document = try await loadDocument()
        guard let preset = document.presets.first(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetNotFound(id)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BatchRenameRecipeRepositoryError.exportDestinationExists(destination)
        }

        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).export-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try presetIO.encode(preset).write(to: stagingURL, options: .atomic)
        do {
            try FileManager.default.moveItem(at: stagingURL, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw BatchRenameRecipeRepositoryError.exportDestinationExists(destination)
        }
    }

    func delete(id: UUID) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard document.presets.contains(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetNotFound(id)
        }
        document.presets.removeAll { $0.id == id }
        if document.selectedPresetID == id {
            document.selectedPresetID = sortedRenamePresets(document.presets).first?.id
        }
        try await save(document)
    }

    func select(id: UUID) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard document.presets.contains(where: { $0.id == id }) else {
            throw BatchRenameRecipeRepositoryError.presetNotFound(id)
        }
        document.selectedPresetID = id
        try await save(document)
    }

    private func beginExclusiveAccess() async {
        if !hasExclusiveAccess {
            hasExclusiveAccess = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
        }
    }

    private func endExclusiveAccess() {
        guard !accessWaiters.isEmpty else {
            hasExclusiveAccess = false
            return
        }
        accessWaiters.removeFirst().resume()
    }

    private func loadDocument() async throws -> BatchRenameRecipeRepositoryDocument {
        // A future recipe nested inside a current catalog must not be mistaken for corruption;
        // otherwise the atomic store could expose an older backup which this build then saves
        // over the future primary.
        try rejectNewerRecipeSchemaInPrimary()
        do {
            switch try await store.load() {
            case let .document(document, source):
                if document.migratedFromSchemaVersion != nil, source == .primary {
                    let migrated = document.readyForPersistence
                    try await store.save(migrated)
                    return migrated
                }
                return document.readyForPersistence
            case let .newerSchema(schemaVersion, _, _):
                throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                    found: schemaVersion,
                    supported: BatchRenameRecipeRepositoryDocument.currentSchemaVersion
                )
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return BatchRenameRecipeRepositoryDocument()
        }
    }

    private func rejectNewerRecipeSchemaInPrimary() throws {
        guard FileManager.default.fileExists(atPath: documentURL.path),
              let data = try? Data(contentsOf: documentURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let presets = object["presets"] as? [[String: Any]] else {
            return
        }
        for preset in presets {
            guard let recipe = preset["recipe"] as? [String: Any],
                  let version = recipe["schemaVersion"] as? Int,
                  version > BatchRenameRecipe.currentSchemaVersion else { continue }
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "batch rename recipe",
                found: version,
                supported: BatchRenameRecipe.currentSchemaVersion
            )
        }
    }

    private func save(_ document: BatchRenameRecipeRepositoryDocument) async throws {
        var deterministic = document.readyForPersistence
        deterministic.presets = sortedRenamePresets(document.presets)
        try await store.save(deterministic)
    }

    private func snapshot(
        from document: BatchRenameRecipeRepositoryDocument
    ) -> BatchRenameRecipeRepositorySnapshot {
        BatchRenameRecipeRepositorySnapshot(
            presets: sortedRenamePresets(document.presets),
            selectedPresetID: document.selectedPresetID
        )
    }

    private func validateUniqueName(
        _ name: String,
        excluding excludedID: UUID?,
        in presets: [BatchRenameRecipePreset]
    ) throws {
        let key = canonicalRenameRecipeName(name)
        if presets.contains(where: { $0.id != excludedID && canonicalRenameRecipeName($0.name) == key }) {
            throw BatchRenameRecipeRepositoryError.duplicatePresetName(name)
        }
    }

    private func nextCopyName(
        for sourceName: String,
        presets: [BatchRenameRecipePreset]
    ) -> String {
        let existing = Set(presets.map { canonicalRenameRecipeName($0.name) })
        let first = "\(sourceName) Copy"
        if !existing.contains(canonicalRenameRecipeName(first)) { return first }
        var suffix = 2
        while existing.contains(canonicalRenameRecipeName("\(first) \(suffix)")) {
            suffix += 1
        }
        return "\(first) \(suffix)"
    }
}

private nonisolated struct BatchRenameRecipeRepositoryDocument: VersionedJSONDocument, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var presets: [BatchRenameRecipePreset]
    var selectedPresetID: UUID?
    var migratedFromSchemaVersion: Int?

    init(
        presets: [BatchRenameRecipePreset] = [],
        selectedPresetID: UUID? = nil,
        migratedFromSchemaVersion: Int? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.presets = presets
        self.selectedPresetID = selectedPresetID
        self.migratedFromSchemaVersion = migratedFromSchemaVersion
    }

    var readyForPersistence: Self {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.migratedFromSchemaVersion = nil
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, presets, selectedPresetID
    }

    static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> Self {
        switch schemaVersion {
        case 1:
            let legacy = try decoder.decode(VersionOne.self, from: data)
            let presets = legacy.recipes.map {
                BatchRenameRecipePreset(recipe: $0, collisionChoice: .block)
            }
            let selectedID = legacy.selectedRecipeName.flatMap { selectedName in
                presets.first { canonicalRenameRecipeName($0.name) == canonicalRenameRecipeName(selectedName) }?.id
            } ?? sortedRenamePresets(presets).first?.id
            return Self(
                presets: presets,
                selectedPresetID: selectedID,
                migratedFromSchemaVersion: 1
            )
        case Self.currentSchemaVersion:
            return try decoder.decode(Self.self, from: data)
        default:
            throw AtomicJSONDocumentStoreError.unsupportedOlderSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
    }

    func validateForPersistence() throws {
        var ids = Set<UUID>()
        var names = Set<String>()
        let io = BatchRenameRecipePresetIO()
        for preset in presets {
            try io.validate(preset)
            guard ids.insert(preset.id).inserted else {
                throw BatchRenameRecipeRepositoryError.presetAlreadyExists(preset.id)
            }
            guard names.insert(canonicalRenameRecipeName(preset.name)).inserted else {
                throw BatchRenameRecipeRepositoryError.duplicatePresetName(preset.name)
            }
        }
        if presets.isEmpty {
            if let selectedPresetID {
                throw BatchRenameRecipeRepositoryError.selectedPresetMissing(selectedPresetID)
            }
        } else if let selectedPresetID {
            guard ids.contains(selectedPresetID) else {
                throw BatchRenameRecipeRepositoryError.selectedPresetMissing(selectedPresetID)
            }
        } else {
            throw BatchRenameRecipeRepositoryError.selectionRequired
        }
    }

    private struct VersionOne: Decodable {
        let recipes: [BatchRenameRecipe]
        let selectedRecipeName: String?
    }
}

private nonisolated func normalizedRenameRecipeName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
}

private nonisolated func canonicalRenameRecipeName(_ name: String) -> String {
    normalizedRenameRecipeName(name).folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
}

private nonisolated func sortedRenamePresets(
    _ presets: [BatchRenameRecipePreset]
) -> [BatchRenameRecipePreset] {
    presets.sorted { lhs, rhs in
        let leftKey = canonicalRenameRecipeName(lhs.name)
        let rightKey = canonicalRenameRecipeName(rhs.name)
        if leftKey != rightKey { return leftKey < rightKey }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
