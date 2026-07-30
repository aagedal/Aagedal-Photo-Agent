import Foundation

enum AnalysisAnalyzerCost: Sendable {
    case fast
    case utility
    case expensive
}

struct AnalysisAnalyzerContext: Sendable {
    let sourceURL: URL
    let sourceRevision: SourceImageRevision
}

protocol AnalysisAnalyzer {
    var identifier: String { get }
    var version: Int { get }
    var displayName: String { get }
    var cost: AnalysisAnalyzerCost { get }
    var sourceRepresentation: AnalysisInputRepresentation { get }

    func analyze(
        context: AnalysisAnalyzerContext,
        parameters: [String: String],
        progress: @MainActor @Sendable (Double) -> Void
    ) async throws -> AnalysisAnalyzerOutput
}

/// Runs independent analyzers, publishes incremental state, and reuses only exact cache matches.
@Observable
final class AnalysisRunner {
    private(set) var runs: [AnalysisAnalyzerRun] = []

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var onPersistableRunChanged: ((AnalysisAnalyzerRun) -> Void)?

    var isRunning: Bool {
        runs.contains { $0.status == .queued || $0.status == .running }
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func configure(existingRuns: [AnalysisAnalyzerRun]) {
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        runs = existingRuns
    }

    func start(
        _ analyzer: any AnalysisAnalyzer,
        context: AnalysisAnalyzerContext,
        parameters: [String: String] = [:]
    ) {
        let cacheKey = AnalysisCacheKey(
            sourceSHA256: context.sourceRevision.sha256,
            analyzerID: analyzer.identifier,
            analyzerVersion: analyzer.version,
            parameters: parameters
        ).value

        if runs.contains(where: {
            $0.analyzerID == analyzer.identifier
                && $0.cacheKey == cacheKey
                && $0.status == .completed
        }) {
            return
        }

        tasks[analyzer.identifier]?.cancel()
        let run = AnalysisAnalyzerRun(
            analyzerID: analyzer.identifier,
            analyzerVersion: analyzer.version,
            cacheKey: cacheKey,
            sourceRepresentation: analyzer.sourceRepresentation,
            status: .queued,
            progress: 0,
            startedAt: nil,
            completedAt: nil,
            errorMessage: nil,
            output: nil
        )
        upsert(run, persist: true)

        let expectedGeneration = generation
        tasks[analyzer.identifier] = Task { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            var current = run
            current.status = .running
            current.startedAt = Date()
            upsert(current, persist: true)

            do {
                let output = try await analyzer.analyze(
                    context: context,
                    parameters: parameters
                ) { [weak self] value in
                    guard let self, generation == expectedGeneration else { return }
                    updateProgress(
                        analyzerID: analyzer.identifier,
                        cacheKey: cacheKey,
                        progress: value
                    )
                }
                try Task.checkCancellation()
                guard generation == expectedGeneration else { return }
                current.status = .completed
                current.progress = 1
                current.completedAt = Date()
                current.output = output
                current.errorMessage = nil
                upsert(current, persist: true)
            } catch is CancellationError {
                guard generation == expectedGeneration else { return }
                current.status = .cancelled
                current.completedAt = Date()
                current.errorMessage = nil
                upsert(current, persist: true)
            } catch {
                guard generation == expectedGeneration else { return }
                current.status = .failed
                current.completedAt = Date()
                current.errorMessage = error.localizedDescription.isEmpty
                    ? "The analyzer could not complete."
                    : error.localizedDescription
                upsert(current, persist: true)
            }
            tasks[analyzer.identifier] = nil
        }
    }

    func cancel(analyzerID: String) {
        tasks[analyzerID]?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    func setFindingIncluded(_ findingID: String, included: Bool) {
        guard let runIndex = runs.firstIndex(where: {
            $0.output?.findings.contains(where: { $0.id == findingID }) == true
        }), var output = runs[runIndex].output,
              let findingIndex = output.findings.firstIndex(where: { $0.id == findingID })
        else { return }

        output.findings[findingIndex].includeInReport = included
        runs[runIndex].output = output
        onPersistableRunChanged?(runs[runIndex])
    }

    private func updateProgress(analyzerID: String, cacheKey: String, progress: Double) {
        guard let index = runs.firstIndex(where: {
            $0.analyzerID == analyzerID && $0.cacheKey == cacheKey
        }), runs[index].status == .running else { return }
        runs[index].progress = min(max(progress, 0), 1)
    }

    private func upsert(_ run: AnalysisAnalyzerRun, persist: Bool) {
        if let index = runs.firstIndex(where: { $0.analyzerID == run.analyzerID }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        if persist {
            onPersistableRunChanged?(run)
        }
    }
}
