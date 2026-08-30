import Foundation

nonisolated enum CodeReplacementSettingsStoreError: Error, Equatable, LocalizedError, Sendable {
    case unreadableConfiguration
    case newerSchema(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableConfiguration:
            "The saved code-replacement settings cannot be read and were left unchanged."
        case let .newerSchema(found, supported):
            "Code-replacement settings schema \(found) is newer than supported schema \(supported) and is read-only."
        }
    }
}

nonisolated struct CodeReplacementBookmarkResolution: Equatable, Sendable {
    var url: URL
    var isStale: Bool
}

/// Injectable boundary around security-scoped bookmark bytes and source-file reads.
/// Bookmark bytes stay in the dedicated defaults key and never enter Codable configuration.
nonisolated struct CodeReplacementSourceAccess: Sendable {
    var createBookmark: @Sendable (URL) throws -> Data
    var resolveBookmark: @Sendable (Data) throws -> CodeReplacementBookmarkResolution
    var readData: @Sendable (URL) throws -> Data
    var modificationDate: @Sendable (URL) throws -> Date?

    init(
        createBookmark: @escaping @Sendable (URL) throws -> Data,
        resolveBookmark: @escaping @Sendable (Data) throws -> CodeReplacementBookmarkResolution,
        readData: @escaping @Sendable (URL) throws -> Data,
        modificationDate: @escaping @Sendable (URL) throws -> Date? = { url in
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    ) {
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
        self.readData = readData
        self.modificationDate = modificationDate
    }

    static let live = Self(
        createBookmark: { url in
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: { data in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return CodeReplacementBookmarkResolution(url: url, isStale: stale)
        },
        readData: { url in
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        },
        modificationDate: { url in
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    )
}

nonisolated enum CodeReplacementSourceOperation: Equatable, Sendable {
    case select
    case reload
}

nonisolated enum CodeReplacementSourceOperationStage: Equatable, Sendable {
    case bookmarkCreated
    case bookmarkResolved
    case sourceRead
    case bookmarkRefreshed
    case resourceValuesRead
}

/// Immutable evidence returned when cooperative cancellation is observed between synchronous
/// Foundation calls. No partially loaded source from this evidence is safe to publish.
nonisolated struct CodeReplacementSourceCancellation: Equatable, Sendable {
    let requestID: UUID
    let operation: CodeReplacementSourceOperation
    let completedStage: CodeReplacementSourceOperationStage?
    let sourceURL: URL?
    let byteCount: Int?
}

nonisolated struct CodeReplacementSourceSnapshot: Equatable, Sendable {
    let requestID: UUID
    let operation: CodeReplacementSourceOperation
    let source: CodeReplacementSourceReference
    let list: CodeReplacementList
    /// Present for a new selection or when a stale bookmark was refreshed after a successful read.
    let bookmarkDataToPersist: Data?
}

nonisolated enum CodeReplacementSourceOperationResult: Equatable, Sendable {
    case loaded(CodeReplacementSourceSnapshot)
    case cancelled(CodeReplacementSourceCancellation)
}

/// Serializes bookmark creation/resolution, source reads, and resource-value reads away from
/// MainActor. Those Foundation calls cannot be interrupted once entered, so cancellation is
/// checked between them and returned as immutable evidence instead of partial publishable state.
actor CodeReplacementSourceService {
    private let access: CodeReplacementSourceAccess
    private let parser = CodeReplacementParser()

    init(access: CodeReplacementSourceAccess = .live) {
        self.access = access
    }

    func selectSource(
        _ url: URL,
        sourceID: UUID,
        bookmarkID: UUID,
        timestamp: Date,
        requestID: UUID
    ) throws -> CodeReplacementSourceOperationResult {
        guard !Task.isCancelled else {
            return cancelled(requestID: requestID, operation: .select)
        }

        let bookmarkData = try access.createBookmark(url)
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .select,
                stage: .bookmarkCreated,
                url: url
            )
        }

        let data = try access.readData(url)
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .select,
                stage: .sourceRead,
                url: url,
                byteCount: data.count
            )
        }

        let modificationDate = try? access.modificationDate(url)
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .select,
                stage: .resourceValuesRead,
                url: url,
                byteCount: data.count
            )
        }

        let source = CodeReplacementSourceReference(
            id: sourceID,
            displayName: url.lastPathComponent,
            path: url.path,
            bookmark: CodeReplacementBookmarkReference(
                id: bookmarkID,
                createdAt: timestamp,
                lastResolvedAt: timestamp,
                wasStaleWhenLastResolved: false
            ),
            fingerprint: CodeReplacementSourceFingerprint(
                byteCount: Int64(data.count),
                modificationDate: modificationDate
            )
        )
        return .loaded(CodeReplacementSourceSnapshot(
            requestID: requestID,
            operation: .select,
            source: source,
            list: parser.parse(data, source: source),
            bookmarkDataToPersist: bookmarkData
        ))
    }

    func reloadSource(
        source originalSource: CodeReplacementSourceReference,
        bookmarkData: Data,
        timestamp: Date,
        requestID: UUID
    ) throws -> CodeReplacementSourceOperationResult {
        guard !Task.isCancelled else {
            return cancelled(requestID: requestID, operation: .reload)
        }

        let resolution = try access.resolveBookmark(bookmarkData)
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .reload,
                stage: .bookmarkResolved,
                url: resolution.url
            )
        }

        let data = try access.readData(resolution.url)
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .reload,
                stage: .sourceRead,
                url: resolution.url,
                byteCount: data.count
            )
        }

        let refreshedBookmark = try resolution.isStale
            ? access.createBookmark(resolution.url)
            : nil
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .reload,
                stage: resolution.isStale ? .bookmarkRefreshed : .sourceRead,
                url: resolution.url,
                byteCount: data.count
            )
        }

        let modificationDate = try? access.modificationDate(resolution.url)
        guard !Task.isCancelled else {
            return cancelled(
                requestID: requestID,
                operation: .reload,
                stage: .resourceValuesRead,
                url: resolution.url,
                byteCount: data.count
            )
        }

        var source = originalSource
        source.displayName = resolution.url.lastPathComponent
        source.path = resolution.url.path
        source.bookmark?.lastResolvedAt = timestamp
        source.bookmark?.wasStaleWhenLastResolved = resolution.isStale
        source.fingerprint?.byteCount = Int64(data.count)
        source.fingerprint?.modificationDate = modificationDate

        return .loaded(CodeReplacementSourceSnapshot(
            requestID: requestID,
            operation: .reload,
            source: source,
            list: parser.parse(data, source: source),
            bookmarkDataToPersist: refreshedBookmark
        ))
    }

    private func cancelled(
        requestID: UUID,
        operation: CodeReplacementSourceOperation,
        stage: CodeReplacementSourceOperationStage? = nil,
        url: URL? = nil,
        byteCount: Int? = nil
    ) -> CodeReplacementSourceOperationResult {
        .cancelled(CodeReplacementSourceCancellation(
            requestID: requestID,
            operation: operation,
            completedStage: stage,
            sourceURL: url,
            byteCount: byteCount
        ))
    }
}

@MainActor
@Observable
final class CodeReplacementSettingsStore {
    private(set) var configuration: CodeReplacementConfiguration
    private(set) var list: CodeReplacementList
    private(set) var sourceLoadError: String?
    private(set) var configurationLoadError: CodeReplacementSettingsStoreError?
    private(set) var isConfigurationReadOnly: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sourceService: CodeReplacementSourceService
    @ObservationIgnored private let configurationKey: String
    @ObservationIgnored private let bookmarkKey: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var sourceOperationTask: Task<CodeReplacementSourceOperationResult, Error>?
    @ObservationIgnored private var sourceOperationRequestID = UUID()

    init(
        defaults: UserDefaults = .standard,
        access: CodeReplacementSourceAccess = .live,
        configurationKey: String = UserDefaultsKeys.codeReplacementConfiguration,
        bookmarkKey: String = UserDefaultsKeys.codeReplacementSourceBookmark,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        sourceService = CodeReplacementSourceService(access: access)
        self.configurationKey = configurationKey
        self.bookmarkKey = bookmarkKey
        self.now = now

        let load = Self.loadConfiguration(defaults.data(forKey: configurationKey))
        let restoredConfiguration = load.configuration
        configuration = restoredConfiguration
        configurationLoadError = load.error
        isConfigurationReadOnly = load.error != nil
        list = CodeReplacementList(source: restoredConfiguration.source)

        // Establish request identity synchronously, then observe the actor work without making
        // initialization wait for bookmark or filesystem access.
        if let operation = prepareReloadSource() {
            Task { [weak self] in
                await self?.completeReloadSource(operation)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isConfigurationReadOnly else { return }
        guard configuration.isEnabled != enabled else { return }
        configuration.isEnabled = enabled
        saveConfiguration()
    }

    func setStartDelimiter(_ delimiter: String) {
        guard !isConfigurationReadOnly else { return }
        guard configuration.startDelimiter != delimiter else { return }
        configuration.startDelimiter = delimiter
        saveConfiguration()
    }

    func setEndDelimiter(_ delimiter: String) {
        guard !isConfigurationReadOnly else { return }
        guard configuration.endDelimiter != delimiter else { return }
        configuration.endDelimiter = delimiter
        saveConfiguration()
    }

    func selectSource(_ url: URL) async throws {
        if let configurationLoadError { throw configurationLoadError }

        let requestID = beginSourceOperation()
        let timestamp = now()
        let service = sourceService
        let task = Task {
            try await service.selectSource(
                url,
                sourceID: UUID(),
                bookmarkID: UUID(),
                timestamp: timestamp,
                requestID: requestID
            )
        }
        sourceOperationTask = task

        do {
            let result = try await task.value
            publish(result, requestID: requestID)
        } catch {
            finishSourceOperation(requestID: requestID)
            throw error
        }
    }

    func reloadSource() async {
        guard let operation = prepareReloadSource() else { return }
        await completeReloadSource(operation)
    }

    /// Lets integration callers synchronize with the nonblocking launch reload without starting
    /// a duplicate filesystem request.
    func waitForPendingSourceOperation() async {
        guard let task = sourceOperationTask else { return }
        await completeReloadSource((sourceOperationRequestID, task))
    }

    func removeSource() {
        guard !isConfigurationReadOnly else { return }
        cancelSourceOperation()
        defaults.removeObject(forKey: bookmarkKey)
        configuration.source = nil
        list = CodeReplacementList()
        sourceLoadError = nil
        saveConfiguration()
    }

    private func prepareReloadSource() -> (
        requestID: UUID,
        task: Task<CodeReplacementSourceOperationResult, Error>
    )? {
        guard !isConfigurationReadOnly else {
            cancelSourceOperation()
            list = CodeReplacementList()
            sourceLoadError = nil
            return nil
        }
        guard let source = configuration.source else {
            cancelSourceOperation()
            list = CodeReplacementList()
            sourceLoadError = nil
            return nil
        }
        guard let bookmarkData = defaults.data(forKey: bookmarkKey) else {
            cancelSourceOperation()
            list = CodeReplacementList(source: source)
            sourceLoadError = "The code-replacement source permission is missing. Choose the file again."
            return nil
        }

        let requestID = beginSourceOperation()
        let timestamp = now()
        let service = sourceService
        let task = Task {
            try await service.reloadSource(
                source: source,
                bookmarkData: bookmarkData,
                timestamp: timestamp,
                requestID: requestID
            )
        }
        sourceOperationTask = task
        return (requestID, task)
    }

    private func completeReloadSource(
        _ operation: (
            requestID: UUID,
            task: Task<CodeReplacementSourceOperationResult, Error>
        )
    ) async {
        do {
            let result = try await operation.task.value
            publish(result, requestID: operation.requestID)
        } catch {
            guard sourceOperationRequestID == operation.requestID else { return }
            sourceOperationTask = nil
            list = CodeReplacementList(source: configuration.source)
            sourceLoadError = "The code-replacement source could not be read. Choose the file again."
        }
    }

    private func beginSourceOperation() -> UUID {
        sourceOperationTask?.cancel()
        let requestID = UUID()
        sourceOperationRequestID = requestID
        return requestID
    }

    private func cancelSourceOperation() {
        sourceOperationTask?.cancel()
        sourceOperationTask = nil
        sourceOperationRequestID = UUID()
    }

    private func publish(
        _ result: CodeReplacementSourceOperationResult,
        requestID: UUID
    ) {
        guard sourceOperationRequestID == requestID else { return }
        sourceOperationTask = nil
        guard case let .loaded(snapshot) = result,
              snapshot.requestID == requestID else { return }

        if let bookmarkData = snapshot.bookmarkDataToPersist {
            defaults.set(bookmarkData, forKey: bookmarkKey)
        }
        configuration.source = snapshot.source
        list = snapshot.list
        sourceLoadError = nil
        saveConfiguration()
    }

    private func finishSourceOperation(requestID: UUID) {
        guard sourceOperationRequestID == requestID else { return }
        sourceOperationTask = nil
    }

    private func saveConfiguration() {
        guard !isConfigurationReadOnly else { return }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: configurationKey)
    }

    private static func loadConfiguration(
        _ data: Data?
    ) -> (
        configuration: CodeReplacementConfiguration,
        error: CodeReplacementSettingsStoreError?
    ) {
        guard let data else { return (CodeReplacementConfiguration(), nil) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            return (
                CodeReplacementConfiguration(isEnabled: false),
                .unreadableConfiguration
            )
        }
        guard version <= CodeReplacementConfiguration.currentSchemaVersion else {
            return (
                CodeReplacementConfiguration(isEnabled: false),
                .newerSchema(
                    found: version,
                    supported: CodeReplacementConfiguration.currentSchemaVersion
                )
            )
        }
        guard version == CodeReplacementConfiguration.currentSchemaVersion,
              let decoded = try? JSONDecoder().decode(
                CodeReplacementConfiguration.self,
                from: data
              ) else {
            return (
                CodeReplacementConfiguration(isEnabled: false),
                .unreadableConfiguration
            )
        }
        return (decoded, nil)
    }
}
