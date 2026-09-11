import Foundation

/// Frozen policies and validation inputs for one accepted variable operation.
struct VariableMetadataOptions: Sendable {
    let ordinaryMode: MetadataWriteMode
    let credentialMode: MetadataWriteMode
    let rawMode: MetadataWriteMode
    let credentialRawMode: MetadataWriteMode
    let initials: String
    let addJobIDToKeywords: Bool
    let approvedKeywords: [String: String]
    let strictKeywords: Bool

    static func capture() -> Self {
        let lists = ApprovedListService.shared
        let active = lists.isActive(for: .keywords)
        var canonical: [String: String] = [:]
        if active {
            for entry in lists.allEntries(for: .keywords) { canonical[normalizedKeyword(entry)] = entry }
        }
        return .init(ordinaryMode: .current(forC2PA: false, isRaw: false),
            credentialMode: .current(forC2PA: true, isRaw: false),
            rawMode: .current(forC2PA: false, isRaw: true),
            credentialRawMode: .current(forC2PA: true, isRaw: true),
            initials: UserDefaults.standard.string(forKey: UserDefaultsKeys.creatorInitials) ?? "",
            addJobIDToKeywords: UserDefaults.standard.bool(forKey: UserDefaultsKeys.addJobIdToKeywords),
            approvedKeywords: canonical, strictKeywords: active && lists.mode(for: .keywords) == .strict)
    }

    func mode(hasC2PA: Bool, imageURL: URL) -> MetadataWriteMode {
        if SupportedImageFormats.isRaw(url: imageURL) { return hasC2PA ? credentialRawMode : rawMode }
        return hasC2PA ? credentialMode : ordinaryMode
    }

    static func normalizedKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

struct VariableMetadataResolutionInput: Sendable {
    let metadata: IPTCMetadata
    let imageURL: URL
    let filename: String
    let sequenceIndex: Int
    let options: VariableMetadataOptions
}

/// Local transformation shared by the displayed editor and folder processing. It never reads
/// selection or changes a live editor while geocoding/roster work is suspended.
enum VariableMetadataResolver {
    static func resolve(_ input: VariableMetadataResolutionInput) async throws -> IPTCMetadata {
        try Task.checkCancellation()
        let interpolator = PresetVariableInterpolator()
        let gps = await interpolator.resolvingGPSPlaceVariables(in: input.metadata)
        try Task.checkCancellation()
        let needsNumber = (try? JSONEncoder().encode(input.metadata))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { $0.contains("{number}") || $0.contains("(number)") } ?? false
        let number = needsNumber ? await sportsNumber(for: input.imageURL) : ""
        try Task.checkCancellation()
        let reference = interpolator.resolvingSportsNumberVariables(in: gps, number: number)
        return resolveText(reference, input: input)
    }

    static func resolveText(_ reference: IPTCMetadata, input: VariableMetadataResolutionInput) -> IPTCMetadata {
        let interpolator = PresetVariableInterpolator()
        func scalar(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return value }
            let resolved = interpolator.resolve(value, filename: input.filename,
                existingMetadata: reference, sequenceIndex: input.sequenceIndex, initials: input.options.initials)
            return resolved.isEmpty ? nil : resolved
        }
        func list(_ values: [String], keywords: Bool = false) -> [String] {
            var result: [String] = []
            var seen = Set<String>()
            for value in values {
                let expanded = scalar(value) ?? ""
                // A literal comma belongs to its original token. Only an actual expansion may
                // introduce multiple values; unrelated list content remains byte-for-byte intact.
                if expanded == value {
                    result.append(value)
                    seen.insert(value)
                    continue
                }
                for part in expanded.components(separatedBy: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let final: String
                    if keywords {
                        if let canonical = input.options.approvedKeywords[VariableMetadataOptions.normalizedKeyword(trimmed)] {
                            final = canonical
                        } else if input.options.strictKeywords { continue }
                        else { final = trimmed }
                    } else { final = trimmed }
                    if seen.insert(final).inserted { result.append(final) }
                }
            }
            return result
        }
        var result = reference
        let fields: [WritableKeyPath<IPTCMetadata, String?>] = [
            \.title, \.description, \.extendedDescription, \.creatorJobTitle, \.descriptionWriter,
            \.credit, \.copyright, \.rightsUsageTerms, \.webStatementOfRights,
            \.digitalImageGUID, \.imageSupplierImageID, \.jobId, \.dateCreated,
            \.city, \.sublocation, \.provinceState, \.country, \.event, \.instructions, \.source
        ]
        for field in fields { result[keyPath: field] = scalar(reference[keyPath: field]) }
        let creators = reference.creators.compactMap(scalar)
        result.creators = creators == reference.creators ? reference.creators : IPTCMetadata.normalizedCreators(creators)
        result.keywords = list(reference.keywords, keywords: true)
        result.personShown = list(reference.personShown)
        result.organisationsShownNames = list(reference.organisationsShownNames)
        result.organisationsShownCodes = list(reference.organisationsShownCodes)
        let scenes = list(reference.sceneCodes)
        let subjects = list(reference.subjectCodes)
        result.sceneCodes = scenes == reference.sceneCodes ? reference.sceneCodes : IPTCSceneCode.normalizedValues(scenes)
        result.subjectCodes = subjects == reference.subjectCodes ? reference.subjectCodes : IPTCSubjectCode.normalizedValues(subjects)
        if input.options.addJobIDToKeywords, let job = result.jobId, !job.isEmpty,
           !result.keywords.contains(job) { result.keywords.append(job) }
        return result
    }

    private static func sportsNumber(for imageURL: URL) async -> String {
        let folder = imageURL.deletingLastPathComponent()
        let roster = await MatchRosterService.shared.load(for: folder, requestID: UUID())
        guard !Task.isCancelled, case .loaded(let rosterSnapshot) = roster else { return "" }
        let faces = await FaceDataFolderLoadService.shared.loadDocument(folderURL: folder)
        guard !Task.isCancelled, case .complete(let faceSnapshot) = faces else { return "" }
        return SportsCaptionNumberResolver.value(for: imageURL, faceData: faceSnapshot.faceData, match: rosterSnapshot.roster)
    }
}

struct VariableMetadataInputSnapshot: Sendable {
    let baselineSidecar: MetadataSidecar?
    let embeddedMetadata: IPTCMetadata
    let xmpMetadata: IPTCMetadata?
    let hasC2PA: Bool
    let evidence: MetadataSidecarReplayCreationEvidence
}

struct VariableMetadataPhotoOutcome: Sendable {
    let imageURL: URL
    var writeResult: VariableMetadataWriteResult? = nil
    var unchanged = false
    var failure: String? = nil
    var wasCancelled = false
    var completed: Bool { unchanged || writeResult?.completed == true }
}

struct VariableMetadataBatchOutcome: Sendable {
    let requestID: UUID
    let folderURL: URL
    let results: [VariableMetadataPhotoOutcome]
    let unattemptedURLs: [URL]
    let wasCancelled: Bool

    var attention: PendingMetadataWriteBatchAttention? {
        guard wasCancelled || results.contains(where: { !$0.completed }) else { return nil }
        var lines = ["Variable processing in \(folderURL.path): completed \(results.filter(\.completed).count) of \(results.count) attempted photos."]
        if wasCancelled { lines.append("Cancelled; \(unattemptedURLs.count) photos were not attempted.") }
        for item in results where !item.completed {
            let result = item.writeResult
            var detail = "\(item.imageURL.path): " + (item.failure ?? result?.failure ?? "The operation was cancelled or did not complete.")
            if result?.preparedSidecar != nil { detail += " The resolved pending draft was saved." }
            if let physical = result?.physicalResult {
                if physical.didWriteEmbedded { detail += " Image metadata was written." }
                if physical.didWriteXMP { detail += " XMP metadata was written." }
                if physical.embeddedWriteMayHaveOccurred { detail += " Image metadata may already have changed; verify it before retrying." }
                if let url = physical.committedButUnverifiedSidecarURL { detail += " Metadata JSON could not be verified after commit: \(url.path)." }
            }
            if let url = result?.committedButUnverifiedSidecarURL {
                detail += " Metadata JSON was committed but not verified: \(url.path)."
            }
            lines.append(detail)
        }
        lines.append("Retry Variable Writes retains the original request only while this app session remains open. After reopening, review the saved pending drafts and deliberately choose Write All to write their full metadata; that is a new destination choice, not a continuation of the original variable policy.")
        return .init(id: requestID, title: "Variable Processing Needs Attention: \(folderURL.lastPathComponent)",
            message: lines.joined(separator: "\n\n"))
    }
}
