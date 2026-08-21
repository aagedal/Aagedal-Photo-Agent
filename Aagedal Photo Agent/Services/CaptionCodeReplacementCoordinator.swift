import Foundation

nonisolated enum CaptionCodeReplacementField: String, CaseIterable, Equatable, Sendable {
    case headline
    case description
    case extendedDescription

    var displayName: String {
        switch self {
        case .headline: return "Headline"
        case .description: return "Description"
        case .extendedDescription: return "Extended Description"
        }
    }
}

nonisolated struct CaptionCodeReplacementFieldPreview: Equatable, Sendable {
    var field: CaptionCodeReplacementField
    var originalText: String
    var proposedText: String
    var replacements: [CodeReplacementOccurrence]
    var unresolvedOccurrences: [CodeReplacementUnresolvedOccurrence]

    var changed: Bool { originalText != proposedText }
}

nonisolated enum CaptionCodeReplacementStatus: Equatable, Sendable {
    case completed
    case unchanged
    case disabled
    case activeComposition
    case invalidConfiguration
    case invalidSource
    case ambiguousOccurrence
    case unrepresentableCode
}

nonisolated struct CaptionCodeReplacementResult: Equatable, Sendable {
    var status: CaptionCodeReplacementStatus
    var metadata: IPTCMetadata?
    var fields: [CaptionCodeReplacementFieldPreview]

    var changed: Bool { fields.contains(where: \.changed) }
}

/// Binds a proposed replacement to the exact asset and draft used to produce it.
///
/// The preview sheet can remain visible while notification-driven navigation or another draft
/// mutation occurs. Callers must revalidate this snapshot immediately before publishing the
/// proposed metadata; a preview is never portable to a different asset or revised draft.
nonisolated struct CaptionCodeReplacementPendingPreview: Equatable, Sendable {
    var imageURL: URL
    var inputMetadata: IPTCMetadata
    var result: CaptionCodeReplacementResult

    init(imageURL: URL, inputMetadata: IPTCMetadata, result: CaptionCodeReplacementResult) {
        self.imageURL = imageURL.standardizedFileURL
        self.inputMetadata = inputMetadata
        self.result = result
    }

    func validatedMetadata(currentURL: URL?, currentMetadata: IPTCMetadata) -> IPTCMetadata? {
        guard currentURL?.standardizedFileURL == imageURL,
              currentMetadata == inputMetadata,
              result.status == .completed else {
            return nil
        }
        return result.metadata
    }
}

/// Plans one atomic caption-field replacement without touching UI or persistence.
///
/// Only headline, description, and extended description are eligible. If any eligible field
/// contains an ambiguous or unrepresentable occurrence, no updated metadata is returned, even if
/// another field had safe replacements. This keeps the explicit workspace command all-or-nothing.
nonisolated struct CaptionCodeReplacementCoordinator: Sendable {
    private let engine = CodeReplacementEngine()

    func plan(
        metadata: IPTCMetadata,
        list: CodeReplacementList,
        configuration: CodeReplacementConfiguration,
        compositionState: CodeReplacementCompositionState
    ) -> CaptionCodeReplacementResult {
        guard configuration.isEnabled else {
            return result(.disabled)
        }
        guard compositionState == .committed else {
            return result(.activeComposition)
        }
        guard !configuration.startDelimiter.isEmpty,
              !configuration.endDelimiter.isEmpty else {
            return result(.invalidConfiguration)
        }
        guard configuration.source != nil,
              !list.hasInvalidEncoding,
              !list.diagnostics.contains(where: { diagnostic in
                  guard diagnostic.severity == .error else { return false }
                  if case .ambiguousCode = diagnostic.kind { return false }
                  return true
              }) else {
            return result(.invalidSource)
        }

        let previews = CaptionCodeReplacementField.allCases.map { field in
            let original = value(for: field, in: metadata) ?? ""
            let preview = engine.preview(
                text: original,
                list: list,
                configuration: configuration,
                compositionState: compositionState
            )
            return CaptionCodeReplacementFieldPreview(
                field: field,
                originalText: original,
                proposedText: preview.proposedText,
                replacements: preview.replacements,
                unresolvedOccurrences: preview.unresolvedOccurrences
            )
        }

        let unresolved = previews.flatMap(\.unresolvedOccurrences)
        if unresolved.contains(where: { $0.reason == .ambiguousCode }) {
            return result(.ambiguousOccurrence, fields: previews)
        }
        if unresolved.contains(where: { $0.reason == .codeContainsDelimiter }) {
            return result(.unrepresentableCode, fields: previews)
        }
        guard previews.contains(where: \.changed) else {
            return result(.unchanged, metadata: metadata, fields: previews)
        }

        var updated = metadata
        for preview in previews {
            set(preview.proposedText, for: preview.field, in: &updated)
        }
        return result(.completed, metadata: updated, fields: previews)
    }

    private func value(for field: CaptionCodeReplacementField, in metadata: IPTCMetadata) -> String? {
        switch field {
        case .headline: return metadata.title
        case .description: return metadata.description
        case .extendedDescription: return metadata.extendedDescription
        }
    }

    private func set(_ value: String, for field: CaptionCodeReplacementField, in metadata: inout IPTCMetadata) {
        let normalized: String? = value.isEmpty ? nil : value
        switch field {
        case .headline: metadata.title = normalized
        case .description: metadata.description = normalized
        case .extendedDescription: metadata.extendedDescription = normalized
        }
    }

    private func result(
        _ status: CaptionCodeReplacementStatus,
        metadata: IPTCMetadata? = nil,
        fields: [CaptionCodeReplacementFieldPreview] = []
    ) -> CaptionCodeReplacementResult {
        CaptionCodeReplacementResult(status: status, metadata: metadata, fields: fields)
    }
}
