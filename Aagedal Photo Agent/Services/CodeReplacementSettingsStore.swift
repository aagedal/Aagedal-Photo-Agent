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
struct CodeReplacementSourceAccess {
    var createBookmark: (URL) throws -> Data
    var resolveBookmark: (Data) throws -> CodeReplacementBookmarkResolution
    var readData: (URL) throws -> Data

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
        }
    )
}

@MainActor
@Observable
final class CodeReplacementSettingsStore {
    private(set) var configuration: CodeReplacementConfiguration
    private(set) var list: CodeReplacementList
    private(set) var sourceLoadError: String?
    private(set) var configurationLoadError: CodeReplacementSettingsStoreError?
    private(set) var isConfigurationReadOnly: Bool

    private let defaults: UserDefaults
    private let access: CodeReplacementSourceAccess
    private let configurationKey: String
    private let bookmarkKey: String
    private let now: () -> Date
    private let parser = CodeReplacementParser()

    init(
        defaults: UserDefaults = .standard,
        access: CodeReplacementSourceAccess = .live,
        configurationKey: String = UserDefaultsKeys.codeReplacementConfiguration,
        bookmarkKey: String = UserDefaultsKeys.codeReplacementSourceBookmark,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.access = access
        self.configurationKey = configurationKey
        self.bookmarkKey = bookmarkKey
        self.now = now

        let load = Self.loadConfiguration(defaults.data(forKey: configurationKey))
        let restoredConfiguration = load.configuration
        configuration = restoredConfiguration
        configurationLoadError = load.error
        isConfigurationReadOnly = load.error != nil
        list = CodeReplacementList(source: restoredConfiguration.source)
        reloadSource()
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

    func selectSource(_ url: URL) throws {
        if let configurationLoadError { throw configurationLoadError }
        let bookmarkData = try access.createBookmark(url)
        let data = try access.readData(url)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let bookmarkID = UUID()
        let source = CodeReplacementSourceReference(
            displayName: url.lastPathComponent,
            path: url.path,
            bookmark: CodeReplacementBookmarkReference(
                id: bookmarkID,
                createdAt: now(),
                lastResolvedAt: now(),
                wasStaleWhenLastResolved: false
            ),
            fingerprint: CodeReplacementSourceFingerprint(
                byteCount: Int64(data.count),
                modificationDate: values?.contentModificationDate
            )
        )

        defaults.set(bookmarkData, forKey: bookmarkKey)
        configuration.source = source
        list = parser.parse(data, source: source)
        sourceLoadError = nil
        saveConfiguration()
    }

    func reloadSource() {
        guard !isConfigurationReadOnly else {
            list = CodeReplacementList()
            sourceLoadError = nil
            return
        }
        guard configuration.source != nil else {
            list = CodeReplacementList()
            sourceLoadError = nil
            return
        }
        guard let bookmarkData = defaults.data(forKey: bookmarkKey) else {
            list = CodeReplacementList(source: configuration.source)
            sourceLoadError = "The code-replacement source permission is missing. Choose the file again."
            return
        }

        do {
            let resolution = try access.resolveBookmark(bookmarkData)
            let data = try access.readData(resolution.url)
            if resolution.isStale {
                defaults.set(try access.createBookmark(resolution.url), forKey: bookmarkKey)
            }

            var source = configuration.source
            source?.displayName = resolution.url.lastPathComponent
            source?.path = resolution.url.path
            source?.bookmark?.lastResolvedAt = now()
            source?.bookmark?.wasStaleWhenLastResolved = resolution.isStale
            source?.fingerprint?.byteCount = Int64(data.count)
            source?.fingerprint?.modificationDate = try? resolution.url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            configuration.source = source
            list = parser.parse(data, source: source)
            sourceLoadError = nil
            saveConfiguration()
        } catch {
            list = CodeReplacementList(source: configuration.source)
            sourceLoadError = "The code-replacement source could not be read. Choose the file again."
        }
    }

    func removeSource() {
        guard !isConfigurationReadOnly else { return }
        defaults.removeObject(forKey: bookmarkKey)
        configuration.source = nil
        list = CodeReplacementList()
        sourceLoadError = nil
        saveConfiguration()
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
