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
                self.refreshLanguage()
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

    func refreshLanguage() {
        bundledRoots = vocabulary?.tree(language: effectiveLanguage) ?? []
        version &+= 1
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
        append(StructuredKeywordLibraryDocument.iptcID, "IPTC Media Topics", bundledRoots)
        append(StructuredKeywordLibraryDocument.legacyID, "My Keywords", legacy)
        for list in document.lists { append(list.id, list.name, customRoots[list.id] ?? []) }
        return groups
    }

    private static func groupID(_ id: String) -> UUID {
        if id == StructuredKeywordLibraryDocument.iptcID { return UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
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
                        vocabulary = try JSONDecoder().decode(IPTCMediaTopics.self, from: Data(text.utf8))
                        if !AppPaths.isTestProcess, let cache = await iptcUpdater.cached(),
                           cache.vocabulary.release.prefix(10) >= vocabulary!.release.prefix(10) {
                            vocabulary = cache.vocabulary
                        }
                    }
                }
                let url = try await store.resolveURL(for: .structuredLibrary)
                let result = try await persistence.loadText(from: url, requestID: id)
                guard !Task.isCancelled, loadID == id else { return }
                guard store.currentURL(for: .structuredLibrary) == url else { startLoad(); return }
                switch result {
                case .loaded(_, _, let text): install(try StructuredKeywordLibraryDocument.decode(text))
                case .missing: install(StructuredKeywordLibraryDocument())
                case .cancelled: return
                }
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
                vocabulary = result.vocabulary
                refreshLanguage()
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
