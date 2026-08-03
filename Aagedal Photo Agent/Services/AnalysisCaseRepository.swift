import Foundation

enum AnalysisCaseMatch: Equatable, Sendable {
    case exact(AnalysisCase)
    case sourceChanged(AnalysisCase)
    case none
}

/// Folder-local persistence for source-bound analysis cases.
///
/// The repository deliberately owns only app-private `.photo_analysis` JSON. It never writes
/// the source image, its metadata, or its XMP sidecar.
actor AnalysisCaseRepository {
    private let casesDirectoryURL: URL
    private let folderMapDocumentURL: URL

    init(sourceFolderURL: URL) {
        let analysisDirectoryURL = sourceFolderURL
            .appendingPathComponent(".photo_analysis", isDirectory: true)
        casesDirectoryURL = analysisDirectoryURL
            .appendingPathComponent("cases", isDirectory: true)
        folderMapDocumentURL = analysisDirectoryURL
            .appendingPathComponent("folder-map.analysis.json")
    }

    func loadMostRelevantCase(for revision: SourceImageRevision) async -> AnalysisCaseMatch {
        let cases = await loadAllCases()

        var exactMatches: [AnalysisCase] = []
        var changedMatches: [AnalysisCase] = []

        for analysisCase in cases {
            switch analysisCase.source.relationship(to: revision) {
            case .exactRevision:
                exactMatches.append(analysisCase)
            case .sameFileChanged, .samePathChanged:
                changedMatches.append(analysisCase)
            case .unrelated:
                break
            }
        }

        if let exact = exactMatches.max(by: { $0.updatedAt < $1.updatedAt }) {
            return .exact(exact)
        }
        if let changed = changedMatches.max(by: { $0.updatedAt < $1.updatedAt }) {
            return .sourceChanged(changed)
        }
        return .none
    }

    func loadAllCases() async -> [AnalysisCase] {
        let caseURLs: [URL]
        do {
            caseURLs = try FileManager.default.contentsOfDirectory(
                at: casesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            .filter { $0.lastPathComponent.hasSuffix(".analysis.json") }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            return []
        }

        var cases: [AnalysisCase] = []

        for url in caseURLs {
            let store = AtomicJSONDocumentStore<AnalysisCase>(documentURL: url)
            guard let loaded = try? await store.load(),
                  case .document(let analysisCase, _) = loaded else {
                continue
            }

            cases.append(analysisCase)
        }
        return cases
    }

    func save(_ analysisCase: AnalysisCase) async throws {
        let store = AtomicJSONDocumentStore<AnalysisCase>(
            documentURL: caseURL(for: analysisCase.id)
        )
        try await store.save(analysisCase)
    }

    func loadFolderMapDocument() async -> AnalysisFolderMapDocument {
        let store = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
            documentURL: folderMapDocumentURL
        )
        guard let loaded = try? await store.load(),
              case .document(let document, _) = loaded else {
            return AnalysisFolderMapDocument.create()
        }
        return document
    }

    func saveFolderMapDocument(_ document: AnalysisFolderMapDocument) async throws {
        let store = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
            documentURL: folderMapDocumentURL
        )
        try await store.save(document)
    }

    private func caseURL(for id: UUID) -> URL {
        casesDirectoryURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).analysis.json"
        )
    }
}
