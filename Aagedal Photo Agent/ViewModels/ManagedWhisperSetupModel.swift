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
    }

    static let shared = ManagedWhisperSetupModel()
    static let modelPreferenceKey = "voiceMemo.whisper.downloadableModel"
    private(set) var selectedModelID: String
    var selectedModel: WhisperDownloadableModel {
        WhisperDownloadableModel.catalog.first { $0.id == selectedModelID } ?? WhisperDownloadableModel.catalog[1]
    }
    private(set) var isInstalled = false
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
            admit: { try await admission.admitBundled(modelURL: $0, model: $1) })
        self.admission = admission
        let saved = defaults.string(forKey: Self.modelPreferenceKey)
        selectedModelID = WhisperDownloadableModel.catalog.first { $0.id == saved }?.id
            ?? WhisperDownloadableModel.catalog[1].id
    }

    /// UI tests must never discover or overwrite the user's downloaded weights.
    private static func uiTestModelDirectory() -> URL? {
        guard UITestLaunchConfiguration.current.isEnabled else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-test-whisper-model-root"),
              arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    func selectModel(_ id: String) {
        guard id != selectedModelID, WhisperDownloadableModel.catalog.contains(where: { $0.id == id }) else { return }
        invalidate()
        selectedModelID = id
        defaults.set(id, forKey: Self.modelPreferenceKey)
    }

    func refresh() async {
        // A retained provider may be using this receipt. Its authorizer revalidates
        // exact bytes at execution; reopening Settings must not revoke it.
        guard !isReady, !isDownloading, !isRefreshing else { return }
        let request = generation
        let selected = selectedModel
        isRefreshing = true
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
            errorMessage = error.localizedDescription
        }
    }

    func downloadSelectedModel() {
        guard !isDownloading else { return }
        invalidate()
        let request = generation
        let selected = selectedModel
        isDownloading = true
        downloadTask = Task { [weak self, operations, admission] in
            do {
                let url = try await operations.download(selected) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == request, self.isDownloading else { return }
                        self.progress = min(max(fraction, 0), 1)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.isInstalled = true
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
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func removeSelectedModel() async {
        let selected = selectedModel
        invalidate()
        let request = generation
        isRefreshing = true
        defer { if request == generation { isRefreshing = false } }
        do { try await operations.remove(selected) }
        catch { if request == generation { errorMessage = error.localizedDescription } }
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

    private func invalidate() {
        generation = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        revokeReceipt()
        isRefreshing = false
        isDownloading = false
        isInstalled = false
        progress = 0
        errorMessage = nil
    }
}
