import Foundation

/// Canonical lookup key for filename-derived associations. Resolve the parent independently so the
/// old leaf may already have been moved while a symlinked folder still resolves deterministically.
nonisolated func renameReassociationLookupURL(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    let resolvedParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
    return resolvedParent
        .appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
        .standardizedFileURL
}

nonisolated struct RenameReassociationIssue: Equatable, Sendable {
    enum Subsystem: String, Equatable, Sendable {
        case faceData
        case imageAnalysis
        case voiceMemoCompanion
    }

    let subsystem: Subsystem
    let detail: String
}

nonisolated struct RenameReassociationResult: Equatable, Sendable {
    let faceReferenceCount: Int
    let analysisCaseCount: Int
    let voiceMemoCompanionCount: Int
    let issues: [RenameReassociationIssue]

    var succeeded: Bool { issues.isEmpty }

    static let noChanges = RenameReassociationResult(
        faceReferenceCount: 0,
        analysisCaseCount: 0,
        voiceMemoCompanionCount: 0,
        issues: []
    )
}

/// Updates persistent records that genuinely use image paths as lookup keys after the filesystem
/// transaction succeeds. Hash-keyed Develop catalogs and source-identity evidence are intentionally
/// excluded: their association already survives a rename and rewriting them would weaken identity.
nonisolated struct RenameReassociationService: Sendable {
    private let faceStorage = FaceDataStorageService()

    func reassociate(
        folderURL: URL,
        mappings: [BatchRenameExecutionPresentation.Mapping]
    ) async -> RenameReassociationResult {
        guard !mappings.isEmpty else { return .noChanges }

        var faceReferenceCount = 0
        var analysisCaseCount = 0
        var voiceMemoCompanionCount = 0
        var issues: [RenameReassociationIssue] = []

        let hadPersistedFaceData = faceStorage.faceDataExists(for: folderURL)
        if var faceData = faceStorage.loadFaceData(for: folderURL) {
            faceReferenceCount = faceData.reassociateImageURLs(using: mappings)
            if faceReferenceCount > 0 {
                do {
                    try faceStorage.saveFaceData(faceData)
                } catch {
                    issues.append(RenameReassociationIssue(
                        subsystem: .faceData,
                        detail: error.localizedDescription
                    ))
                }
            }
        } else if hadPersistedFaceData {
            issues.append(RenameReassociationIssue(
                subsystem: .faceData,
                detail: "The existing face-data document could not be decoded; it was not reassociated."
            ))
        }

        do {
            analysisCaseCount = try await AnalysisCaseRepository(
                sourceFolderURL: folderURL
            ).relocateSourceHints(using: mappings)
        } catch {
            issues.append(RenameReassociationIssue(
                subsystem: .imageAnalysis,
                detail: error.localizedDescription
            ))
        }

        do {
            voiceMemoCompanionCount = try VoiceMemoCompanionRepository()
                .reassociateRenamedRecords(using: mappings)
        } catch {
            issues.append(RenameReassociationIssue(
                subsystem: .voiceMemoCompanion,
                detail: error.localizedDescription
            ))
        }

        return RenameReassociationResult(
            faceReferenceCount: faceReferenceCount,
            analysisCaseCount: analysisCaseCount,
            voiceMemoCompanionCount: voiceMemoCompanionCount,
            issues: issues
        )
    }
}
