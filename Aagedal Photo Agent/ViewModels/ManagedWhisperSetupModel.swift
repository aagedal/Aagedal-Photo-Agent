import Foundation
import Observation

/// Download and admission state shared by Settings and Caption. No network work starts implicitly.
@MainActor @Observable
final class ManagedWhisperSetupModel {
    nonisolated struct Operations: Sendable {
        var installed: @Sendable (WhisperDownloadableModel) async throws -> URL?
        var download: @Sendable (WhisperDownloadableModel, @escaping WhisperModelDownloadService.Progress) async throws -> URL
        var remove: @Sendable (WhisperDownloadableModel) async throws -> Void
        var admit: @Sendable (URL, WhisperDownloadableModel) async throws -> FFmpegWhisperArtifactAdmissionService.Receipt
        var localModelIDs: @Sendable () async throws -> Set<String> = { [] }
    }

    static let shared = ManagedWhisperSetupModel()
    static let modelPreferenceKey = "voiceMemo.whisper.downloadableModel"
    private(set) var selectedModelID: String
    var selectedModel: WhisperDownloadableModel {
        WhisperDownloadableModel.catalog.first { $0.id == selectedModelID } ?? WhisperDownloadableModel.catalog[1]
    }
    private(set) var isInstalled = false
    // Failed size/hash verification proves regular local weights exist, but grants
    // only recovery controls. It must never enable Retry Setup or a provider.
    var canRemoveModel: Bool { isInstalled || hasCorruptModel }
    var needsModelReplacement: Bool { hasCorruptModel }
    private(set) var localModelIDs = Set<String>()
    private(set) var catalogErrorMessage: String?
    var downloadedModels: [WhisperDownloadableModel] { WhisperDownloadableModel.catalog.filter { localModelIDs.contains($0.id) } }
    var downloadableModels: [WhisperDownloadableModel] { WhisperDownloadableModel.catalog.filter { !localModelIDs.contains($0.id) } }
    private(set) var isReady = false
    private(set) var isRefreshing = false
    private(set) var isDownloading = false
    private(set) var progress = 0.0
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let admission: FFmpegWhisperArtifactAdmissionService
    @ObservationIgnored private var receipt: FFmpegWhisperArtifactAdmissionService.Receipt?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isRemoving = false
    private var hasCorruptModel = false
    @ObservationIgnored private var catalogGeneration = UUID()

    init(defaults: UserDefaults? = nil, downloads: WhisperModelDownloadService? = nil,
         admission: FFmpegWhisperArtifactAdmissionService = FFmpegWhisperArtifactAdmissionService(),
         operations: Operations? = nil) {
        let defaults = defaults ?? FFmpegWhisperSetupModel.sessionDefaults
        self.defaults = defaults
        let downloads = downloads ?? WhisperModelDownloadService(directory: Self.uiTestModelDirectory())
        self.operations = operations ?? Operations(
            installed: { try await downloads.installedURL(for: $0) },
            download: { try await downloads.download($0, progress: $1) },
            remove: { try await downloads.remove($0) },
            admit: { try await admission.admitBundled(modelURL: $0, model: $1) },
            localModelIDs: { try await downloads.localModelIDs() })
        self.admission = admission
        let saved = defaults.string(forKey: Self.modelPreferenceKey)
        selectedModelID = WhisperDownloadableModel.catalog.first { $0.id == saved }?.id
            ?? WhisperDownloadableModel.catalog[1].id
    }

    /// UI tests must never discover or overwrite the user's downloaded weights.
    static func uiTestModelDirectory(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard arguments.contains("--ui-testing") else { return nil }
        if let index = arguments.firstIndex(of: "--ui-test-whisper-model-root"),
           arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        // Missing or malformed test arguments must never fall back to the user's cache.
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperUITests-\(UUID().uuidString)", isDirectory: true)
    }

    func selectModel(_ id: String) {
        guard id != selectedModelID, WhisperDownloadableModel.catalog.contains(where: { $0.id == id }) else { return }
        invalidate()
        selectedModelID = id
        defaults.set(id, forKey: Self.modelPreferenceKey)
    }

    func refresh() async {
        await refreshCatalog()
        // A retained provider may be using this receipt. Its authorizer revalidates
        // exact bytes at execution; reopening Settings must not revoke it.
        guard !isReady, !isDownloading, !isRefreshing, !isRemoving else { return }
        let request = generation
        let selected = selectedModel
        isRefreshing = true
        isInstalled = false
        hasCorruptModel = false
        errorMessage = nil
        defer { if request == generation { isRefreshing = false } }
        do {
            let url = try await operations.installed(selected)
            guard request == generation, !Task.isCancelled else { return }
            isInstalled = url != nil
            guard let url else { revokeReceipt(); return }
            let admitted = try await operations.admit(url, selected)
            guard request == generation, !Task.isCancelled else {
                await admission.revoke(admitted)
                return
            }
            revokeReceipt()
            receipt = admitted
            isReady = true
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            revokeReceipt()
            hasCorruptModel = Self.isCorruptModelError(error)
            errorMessage = error.localizedDescription
        }
    }

    func refreshCatalog() async {
        let request = UUID(); catalogGeneration = request
        do {
            let found = try await operations.localModelIDs()
            guard request == catalogGeneration, !Task.isCancelled else { return }
            localModelIDs = found.intersection(Set(WhisperDownloadableModel.catalog.map(\.id)))
            catalogErrorMessage = nil
        } catch {
            guard request == catalogGeneration, !Task.isCancelled else { return }
            localModelIDs = []
            catalogErrorMessage = error.localizedDescription
        }
    }

    func downloadSelectedModel() {
        guard !isDownloading, !isRemoving else { return }
        let wasInstalled = isInstalled
        let wasCorrupt = hasCorruptModel
        invalidate()
        // Transfer failure/cancellation preserves the old installed file. Keep
        // its recovery controls while revoking all execution authority.
        isInstalled = wasInstalled
        hasCorruptModel = wasCorrupt
        let request = generation
        let selected = selectedModel
        isDownloading = true
        downloadTask = Task { [weak self, operations, admission] in
            do {
                let url = try await operations.download(selected) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == request, self.isDownloading,
                              self.downloadTask?.isCancelled == false else { return }
                        self.progress = min(max(fraction, 0), 1)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.isInstalled = true
                self.hasCorruptModel = false
                self.catalogGeneration = UUID()
                self.localModelIDs.insert(selected.id)
                let admitted = try await operations.admit(url, selected)
                guard self.generation == request, !Task.isCancelled else {
                    await admission.revoke(admitted)
                    if self.generation == request { self.isDownloading = false; self.downloadTask = nil }
                    return
                }
                self.receipt = admitted
                self.isReady = true
                self.progress = 1
                self.isDownloading = false
                self.downloadTask = nil
            } catch {
                guard let self, self.generation == request else { return }
                self.isDownloading = false
                self.downloadTask = nil
                if !Task.isCancelled, !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func removeSelectedModel() async {
        guard !isDownloading, !isRefreshing, !isRemoving else { return }
        let selected = selectedModel
        let wasInstalled = isInstalled
        let wasCorrupt = hasCorruptModel
        invalidate()
        let request = generation
        isRemoving = true
        isRefreshing = true
        defer {
            isRemoving = false
            if request == generation { isRefreshing = false }
        }
        do {
            try await operations.remove(selected)
            catalogGeneration = UUID()
            localModelIDs.remove(selected.id)
        }
        catch {
            guard request == generation else { return }
            errorMessage = error.localizedDescription
            // Failure does not prove absence. Keep removal/retry available, but never
            // restore the revoked receipt. Reconcile a partially completed removal.
            isInstalled = wasInstalled
            hasCorruptModel = wasCorrupt
            do {
                let installed = try await operations.installed(selected)
                guard request == generation else { return }
                isInstalled = installed != nil
                hasCorruptModel = false
            } catch {
                guard request == generation else { return }
                if Self.isCorruptModelError(error) { hasCorruptModel = true; isInstalled = false }
                // Preserve the removal error and last known presence when inspection fails.
            }
        }
    }

    func provider(language: String, useGPU: Bool, translate: Bool,
                  run: @escaping FFmpegWhisperTranscriptionProvider.Run = { try await FFmpegWhisperJobRunner().run($0) }) -> FFmpegWhisperTranscriptionProvider? {
        guard isReady, let receipt else { return nil }
        return FFmpegWhisperTranscriptionProvider(
            configuration: receipt.configuration(language: language, useGPU: useGPU, translate: translate),
            authorizeArtifacts: admission.authorizer(for: receipt), run: run)
    }

    private func revokeReceipt() {
        isReady = false
        if let receipt {
            self.receipt = nil
            Task { [admission] in await admission.revoke(receipt) }
        }
    }

    private static func isCorruptModelError(_ error: Error) -> Bool {
        guard let error = error as? WhisperModelDownloadService.DownloadError else { return false }
        return error == .sizeMismatch || error == .checksumMismatch
    }

    private func invalidate() {
        generation = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        revokeReceipt()
        isRefreshing = false
        isDownloading = false
        isInstalled = false
        hasCorruptModel = false
        progress = 0
        errorMessage = nil
    }
}
