import CoreGraphics
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
    let analysisRunner: AnalysisRunner

    @ObservationIgnored private var repository: AnalysisCaseRepository?
    @ObservationIgnored private var openedImage: ImageFile?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let analyzers: [any AnalysisAnalyzer]

    init(analyzers: [any AnalysisAnalyzer]? = nil) {
        analysisRunner = AnalysisRunner()
        self.analyzers = analyzers ?? [SourceFactsAnalyzer()]
        analysisRunner.onPersistableRunChanged = { [weak self] run in
            self?.persistAnalyzerRun(run)
        }
    }

    var workspaceMode: AnalysisWorkspaceMode {
        analysisCase?.workspaceMode ?? .pixelAnalysis
    }

    var displayPreference: AnalysisSourceRepresentation {
        guard hasDevelopedRepresentation else { return .original }
        return analysisCase?.displayPreference ?? .original
    }

    var sourceFactsRun: AnalysisAnalyzerRun? {
        analysisRunner.runs.first { $0.analyzerID == SourceFactsAnalyzer.analyzerIdentifier }
    }

    var sourceFacts: AnalysisSourceFacts? {
        sourceFactsRun?.output?.sourceFacts
    }

    var findings: [AnalysisFinding] {
        analysisRunner.runs
            .flatMap { $0.output?.findings ?? [] }
            .sorted {
                if $0.severity != $1.severity {
                    return Self.severityRank($0.severity) > Self.severityRank($1.severity)
                }
                return $0.title < $1.title
            }
    }

    var rawMetadata: [AnalysisRawMetadataEntry] {
        analysisRunner.runs.flatMap { $0.output?.rawMetadata ?? [] }
    }

    /// Coordinate transform for the representation currently visible in Analysis.
    ///
    /// Findings stay bound to the source bytes, so developed hover positions are
    /// mapped through crop/straighten back to the original source pixel frame.
    var displayTransform: DisplayImageTransform? {
        guard let facts = sourceFacts,
              let width = facts.pixelWidth,
              let height = facts.pixelHeight else {
            return nil
        }

        let developedCrop: DisplayImageTransform.DevelopedCrop?
        if displayPreference == .developed,
           let crop = developSettings?.crop,
           crop.isEffectiveCrop {
            let left = crop.left ?? 0
            let top = crop.top ?? 0
            let right = crop.right ?? 1
            let bottom = crop.bottom ?? 1
            guard let resolvedCrop = try? DisplayImageTransform.DevelopedCrop(
                sourceNormalizedRect: CGRect(
                    x: left,
                    y: top,
                    width: right - left,
                    height: bottom - top
                ),
                straightenAngleDegrees: crop.angle ?? 0
            ) else {
                return nil
            }
            developedCrop = resolvedCrop
        } else {
            developedCrop = nil
        }

        return try? DisplayImageTransform(
            sourcePixelWidth: width,
            sourcePixelHeight: height,
            exifOrientation: sourceOrientation,
            developedCrop: developedCrop
        )
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
        analysisRunner.configure(existingRuns: [])

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
                    self.configureAnalysis(for: existing, autoStart: true)
                case .sourceChanged(let existing):
                    self.analysisCase = existing
                    self.sourceChanged = true
                    self.configureAnalysis(for: existing, autoStart: false)
                case .none:
                    let newCase = AnalysisCase.create(for: revision)
                    try await repository.save(newCase)
                    try Task.checkCancellation()
                    self.analysisCase = newCase
                    self.sourceChanged = false
                    self.configureAnalysis(for: newCase, autoStart: true)
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
        analysisRunner.configure(existingRuns: [])

        saveTask = Task { [weak self] in
            do {
                try await repository.save(newCase)
                try Task.checkCancellation()
                guard let self, self.analysisCase?.id == newCase.id else { return }
                self.configureAnalysis(for: newCase, autoStart: true)
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

    func cancelAnalyzer(_ analyzerID: String) {
        analysisRunner.cancel(analyzerID: analyzerID)
    }

    func retryAnalyzer(_ analyzerID: String) {
        guard !sourceChanged,
              let analyzer = analyzers.first(where: { $0.identifier == analyzerID }),
              let context = analyzerContext else { return }
        analysisRunner.start(analyzer, context: context)
    }

    func setFindingIncluded(_ findingID: String, included: Bool) {
        analysisRunner.setFindingIncluded(findingID, included: included)
    }

    private var analyzerContext: AnalysisAnalyzerContext? {
        guard let sourceURL, let currentRevision else { return nil }
        return AnalysisAnalyzerContext(
            sourceURL: sourceURL,
            sourceRevision: currentRevision
        )
    }

    private func configureAnalysis(for analysisCase: AnalysisCase, autoStart: Bool) {
        analysisRunner.configure(existingRuns: analysisCase.analyzerRuns)
        guard autoStart, let context = analyzerContext else { return }
        for analyzer in analyzers where analyzer.cost == .fast {
            analysisRunner.start(analyzer, context: context)
        }
    }

    private func persistAnalyzerRun(_ run: AnalysisAnalyzerRun) {
        guard var updatedCase = analysisCase,
              !sourceChanged else { return }
        updatedCase.setAnalyzerRun(run)
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

    private static func severityRank(_ severity: AnalysisFindingSeverity) -> Int {
        switch severity {
        case .informational: 0
        case .notable: 1
        case .caution: 2
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
