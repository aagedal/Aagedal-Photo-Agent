import Foundation

@Observable
final class AnalysisWorkspaceModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var analysisCase: AnalysisCase?
    private(set) var currentRevision: SourceImageRevision?
    private(set) var sourceChanged = false
    private(set) var sourceURL: URL?
    private(set) var hasDevelopedRepresentation = false
    private(set) var developSettings: CameraRawSettings?
    private(set) var sourceOrientation = 1

    @ObservationIgnored private var repository: AnalysisCaseRepository?
    @ObservationIgnored private var openedImage: ImageFile?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var workspaceMode: AnalysisWorkspaceMode {
        analysisCase?.workspaceMode ?? .pixelAnalysis
    }

    var displayPreference: AnalysisSourceRepresentation {
        guard hasDevelopedRepresentation else { return .original }
        return analysisCase?.displayPreference ?? .original
    }

    deinit {
        loadTask?.cancel()
        saveTask?.cancel()
    }

    func open(_ image: ImageFile) {
        loadTask?.cancel()
        saveTask?.cancel()

        sourceURL = image.url
        openedImage = image
        developSettings = image.cameraRawSettings
        sourceOrientation = image.exifOrientation
        hasDevelopedRepresentation = image.hasDevelopEdits && image.cameraRawSettings != nil
        loadState = .loading
        analysisCase = nil
        currentRevision = nil
        sourceChanged = false

        let url = image.url
        let orientation = image.exifOrientation
        let repository = AnalysisCaseRepository(
            sourceFolderURL: url.deletingLastPathComponent()
        )
        self.repository = repository

        loadTask = Task { [weak self] in
            do {
                let revision = try await SourceImageRevision.capture(
                    at: url,
                    exifOrientation: orientation
                )
                try Task.checkCancellation()
                let match = await repository.loadMostRelevantCase(for: revision)
                try Task.checkCancellation()

                guard let self, self.sourceURL == url else { return }
                self.currentRevision = revision

                switch match {
                case .exact(let existing):
                    self.analysisCase = existing
                    self.sourceChanged = false
                case .sourceChanged(let existing):
                    self.analysisCase = existing
                    self.sourceChanged = true
                case .none:
                    let newCase = AnalysisCase.create(for: revision)
                    try await repository.save(newCase)
                    try Task.checkCancellation()
                    self.analysisCase = newCase
                    self.sourceChanged = false
                }
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.sourceURL == url else { return }
                self.loadState = .failed(
                    error.localizedDescription.isEmpty
                        ? "The analysis case could not be opened."
                        : error.localizedDescription
                )
            }
        }
    }

    func retry() {
        guard let openedImage else { return }
        open(openedImage)
    }

    func createCaseForCurrentRevision() {
        guard let currentRevision, let repository else { return }
        saveTask?.cancel()

        let newCase = AnalysisCase.create(for: currentRevision)
        analysisCase = newCase
        sourceChanged = false
        loadState = .loading

        saveTask = Task { [weak self] in
            do {
                try await repository.save(newCase)
                try Task.checkCancellation()
                guard let self, self.analysisCase?.id == newCase.id else { return }
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.analysisCase?.id == newCase.id else { return }
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    func selectWorkspaceMode(_ mode: AnalysisWorkspaceMode) {
        guard var updatedCase = analysisCase,
              updatedCase.workspaceMode != mode else { return }
        updatedCase.setWorkspaceMode(mode)
        persist(updatedCase)
    }

    func selectDisplayPreference(_ representation: AnalysisSourceRepresentation) {
        guard representation == .original || hasDevelopedRepresentation,
              var updatedCase = analysisCase,
              updatedCase.displayPreference != representation else { return }
        updatedCase.setDisplayPreference(representation)
        persist(updatedCase)
    }

    private func persist(_ updatedCase: AnalysisCase) {
        analysisCase = updatedCase
        guard let repository else { return }

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await repository.save(updatedCase)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.analysisCase?.id == updatedCase.id else { return }
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }
}

enum AnalysisSelectionResolver {
    static func image(
        images: [ImageFile],
        selectedURLs: Set<URL>,
        lastClickedURL: URL?
    ) -> ImageFile? {
        if let lastClickedURL,
           selectedURLs.contains(lastClickedURL),
           let image = images.first(where: {
               $0.url == lastClickedURL && SupportedImageFormats.isSupported(url: $0.url)
           }) {
            return image
        }

        return images.first {
            selectedURLs.contains($0.url) && SupportedImageFormats.isSupported(url: $0.url)
        }
    }
}
