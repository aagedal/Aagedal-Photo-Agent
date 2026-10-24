import Foundation
import Observation

@Observable
@MainActor
final class StructuredKeywordLibrary {
    static let shared = StructuredKeywordLibrary()
    private(set) var document = StructuredKeywordLibraryDocument()
    private(set) var version = 0
    private(set) var error: String?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var hasReadFailure = false
    private var vocabulary: IPTCMediaTopics?
    private(set) var isUpdatingIPTC = false
    private(set) var iptcUpdateMessage: String?
    var iptcRelease: String { String(vocabulary?.release.prefix(10) ?? "") }
    var automaticallyUpdateIPTC = AppDefaults.store.object(forKey: "iptcMediaTopicsAutomaticUpdates") as? Bool ?? true {
        didSet {
            AppDefaults.store.set(automaticallyUpdateIPTC, forKey: "iptcMediaTopicsAutomaticUpdates")
            if automaticallyUpdateIPTC { Task { await checkForIPTCUpdates(force: false) } }
        }
    }
    @ObservationIgnored private let iptcUpdater = IPTCMediaTopicsUpdateService.shared

    var effectiveLanguage: IPTCMediaTopicsLanguage {
        IPTCMediaTopicsLanguage.resolve(override: document.languageOverride)
    }
    private(set) var bundledRoots: [StructuredKeyword] = []
    private(set) var customRoots: [String: [StructuredKeyword]] = [:]
    @ObservationIgnored private let store: KeywordListsStore
    @ObservationIgnored private let persistence: KeywordListEditorPersistenceService
    @ObservationIgnored private let sourceID = UUID()
    @ObservationIgnored private var automaticUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var localeObserver: NSObjectProtocol?
    @ObservationIgnored private var loadID: UUID?
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(store: KeywordListsStore = .shared, persistence: KeywordListEditorPersistenceService = .shared) {
        self.store = store
        self.persistence = persistence
        observer = NotificationCenter.default.addObserver(forName: .keywordListChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey
            let source = note.userInfo?[KeywordListsStore.changedSourceIDUserInfo] as? UUID
            Task { @MainActor [weak self] in
                guard let self, key == .structuredLibrary, source != self.sourceID else { return }
                self.startLoad()
            }
        }
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshLanguageInBackground()
            }
        }
        startLoad()
        if !AppPaths.isTestProcess {
            automaticUpdateTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(24 * 60 * 60)) }
                    catch { return }
                    guard let self else { return }
                    if self.automaticallyUpdateIPTC { await self.checkForIPTCUpdates(force: false) }
                }
            }
        }
    }

    /// Identifies the vocabulary + language `bundledRoots` was built for, so re-installing a
    /// document whose language did not change does not rebuild the IPTC tree.
    private struct BundledTreeKey: Equatable {
        let release: String
        let language: IPTCMediaTopicsLanguage
    }
    @ObservationIgnored private var bundledTreeKey: BundledTreeKey?
    @ObservationIgnored private var bundledTreeTask: Task<Void, Never>?

    /// Synchronous refresh (document installs). Rebuilds the tree only when the vocabulary or
    /// effective language actually changed; the launch load and locale/IPTC-update paths build
    /// it off the main actor instead.
    func refreshLanguage() {
        let language = effectiveLanguage
        if let vocabulary {
            let key = BundledTreeKey(release: vocabulary.release, language: language)
            if key != bundledTreeKey {
                bundledRoots = vocabulary.tree(language: language)
                bundledTreeKey = key
            }
        } else {
            bundledRoots = []
            bundledTreeKey = nil
        }
        version &+= 1
    }

    /// Locale changes: rebuild the localized IPTC tree off the main actor and publish it.
    private func refreshLanguageInBackground() {
        guard let vocabulary else { return refreshLanguage() }
        let language = effectiveLanguage
        let key = BundledTreeKey(release: vocabulary.release, language: language)
        guard key != bundledTreeKey else { return }
        bundledTreeTask?.cancel()
        bundledTreeTask = Task { [weak self] in
            let tree = await Self.makeTree(vocabulary, language: language)
            guard let self, !Task.isCancelled,
                  self.vocabulary?.release == key.release,
                  self.effectiveLanguage == key.language else { return }
            self.installBundledTree(tree, key: key)
        }
    }

    private func installBundledTree(_ tree: [StructuredKeyword], key: BundledTreeKey) {
        bundledRoots = tree
        bundledTreeKey = key
        version &+= 1
    }

    /// The bundled IPTC Media Topics JSON is ~570 KB; decoding it on the main actor (the first
    /// touch of `StructuredKeywordService.shared` from the metadata panel) delayed launch.
    @concurrent
    nonisolated static func decodeVocabulary(_ text: String) async throws -> IPTCMediaTopics {
        try JSONDecoder().decode(IPTCMediaTopics.self, from: Data(text.utf8))
    }

    @concurrent
    nonisolated static func makeTree(
        _ vocabulary: IPTCMediaTopics,
        language: IPTCMediaTopicsLanguage
    ) async -> [StructuredKeyword] {
        vocabulary.tree(language: language)
    }

    nonisolated deinit {
        automaticUpdateTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
    }

    func roots(including legacy: [StructuredKeyword]) -> [StructuredKeyword] {
        let active = Set(document.activeIDs)
        var groups: [StructuredKeyword] = []
        func append(_ id: String, _ name: String, _ roots: [StructuredKeyword]) {
            guard active.contains(id), !roots.isEmpty else { return }
            groups.append(StructuredKeyword(id: Self.groupID(id), name: name, kind: .container, children: roots))
        }
        // The user's own trees come first: name lookups and typeahead resolve in tree order, and
        // the shared IPTC vocabulary must never shadow a user's own path for the same name.
        append(StructuredKeywordLibraryDocument.legacyID, "My Keywords", legacy)
        for list in document.lists { append(list.id, list.name, customRoots[list.id] ?? []) }
        append(StructuredKeywordLibraryDocument.iptcID, "IPTC Media Topics", bundledRoots)
        return groups
    }

    /// Group container ID of the IPTC Media Topics tree in `roots(including:)`.
    nonisolated static let iptcGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static func groupID(_ id: String) -> UUID {
        if id == StructuredKeywordLibraryDocument.iptcID { return iptcGroupID }
        if id == StructuredKeywordLibraryDocument.legacyID { return UUID(uuidString: "00000000-0000-0000-0000-000000000002")! }
        return UUID(uuidString: id) ?? UUID()
    }

    func reload() async {
        startLoad()
        while let task = loadTask {
            let id = loadID
            await task.value
            if Task.isCancelled || loadID == id { return }
        }
    }

    private func startLoad() {
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if vocabulary == nil {
                    guard let url = Bundle.main.url(forResource: "IPTCMediaTopics", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    if case .loaded(_, _, let text) = try await persistence.loadText(from: url, requestID: id) {
                        guard !Task.isCancelled, loadID == id else { return }
                        var decoded = try await Self.decodeVocabulary(text)
                        guard !Task.isCancelled, loadID == id else { return }
                        if !AppPaths.isTestProcess, let cache = await iptcUpdater.cached(),
                           cache.vocabulary.release.prefix(10) >= decoded.release.prefix(10) {
                            decoded = cache.vocabulary
                        }
                        guard !Task.isCancelled, loadID == id else { return }
                        vocabulary = decoded
                    }
                }
                let url = try await store.resolveURL(for: .structuredLibrary)
                let result = try await persistence.loadText(from: url, requestID: id)
                guard !Task.isCancelled, loadID == id else { return }
                guard store.currentURL(for: .structuredLibrary) == url else { startLoad(); return }
                let loadedDocument: StructuredKeywordLibraryDocument
                switch result {
                case .loaded(_, _, let text): loadedDocument = try StructuredKeywordLibraryDocument.decode(text)
                case .missing: loadedDocument = StructuredKeywordLibraryDocument()
                case .cancelled: return
                }
                // Build the localized IPTC tree off the main actor before installing, so the
                // synchronous refresh inside `install` finds it current.
                if let vocabulary {
                    let language = IPTCMediaTopicsLanguage.resolve(override: loadedDocument.languageOverride)
                    let key = BundledTreeKey(release: vocabulary.release, language: language)
                    if key != bundledTreeKey {
                        let tree = await Self.makeTree(vocabulary, language: language)
                        guard !Task.isCancelled, loadID == id else { return }
                        if self.vocabulary?.release == key.release {
                            bundledRoots = tree
                            bundledTreeKey = key
                        }
                    }
                }
                install(loadedDocument)
                hasReadFailure = false
                error = nil
            } catch {
                guard !Task.isCancelled, loadID == id else { return }
                hasReadFailure = true
                self.error = error.localizedDescription
            }
            isLoading = false
            if automaticallyUpdateIPTC, !AppPaths.isTestProcess {
                Task { await checkForIPTCUpdates(force: false) }
            }
        }
    }

    func checkForIPTCUpdates(force: Bool = true) async {
        guard !isUpdatingIPTC, let current = vocabulary else { return }
        isUpdatingIPTC = true
        defer { isUpdatingIPTC = false }
        do {
            if let result = try await iptcUpdater.refresh(current: current, force: force) {
                let language = effectiveLanguage
                let tree = await Self.makeTree(result.vocabulary, language: language)
                vocabulary = result.vocabulary
                if effectiveLanguage == language {
                    installBundledTree(tree, key: BundledTreeKey(
                        release: result.vocabulary.release, language: language))
                } else {
                    refreshLanguage()
                }
                iptcUpdateMessage = current.release == result.vocabulary.release
                    ? "IPTC Media Topics is up to date."
                    : "Updated IPTC Media Topics to \(iptcRelease)."
            }
        } catch {
            iptcUpdateMessage = "Could not update IPTC Media Topics: \(error.localizedDescription) The current list is still available."
        }
    }

    private func install(_ document: StructuredKeywordLibraryDocument) {
        self.document = document
        refreshLanguage()
        customRoots = Dictionary(uniqueKeysWithValues: document.lists.map { ($0.id, StructuredKeywordParser.parseString($0.text)) })
        version &+= 1
    }

    /// All UI mutations await this commit; failed writes leave the previous selection intact.
    @discardableResult
    func update(_ change: (inout StructuredKeywordLibraryDocument) -> Void) async throws -> Bool {
        guard !isLoading, !isSaving, !hasReadFailure else { return false }
        isSaving = true
        defer { isSaving = false }
        var next = document
        change(&next)
        let text = try next.encoded()
        _ = try StructuredKeywordLibraryDocument.decode(text)
        let generation = loadID
        let url = try await store.resolveURL(for: .structuredLibrary)
        guard !Task.isCancelled, loadID == generation else { return false }
        guard store.isSettledRoute(url) else { throw ICloudStorageUnavailableError() }
        let requestID = UUID()
        let result = try await persistence.saveText(text, to: url, requestID: requestID)
        guard case .committed = result else { return false }
        if store.currentURL(for: .structuredLibrary) == url, loadID == generation {
            install(next)
            error = nil
        } else { startLoad() }
        store.recordExternalWrite(to: .structuredLibrary, destinationURL: url, text: text, sourceID: sourceID)
        return true
    }
}
