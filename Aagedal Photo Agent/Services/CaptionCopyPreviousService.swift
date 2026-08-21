import Foundation

/// A field that can be requested by the Caption Workspace's Copy Previous action.
///
/// The complete inventory is intentional: callers cannot bypass the capture-specific protections
/// by constructing a broader allowlist than the UI normally presents.
nonisolated enum CaptionCopyPreviousField: String, CaseIterable, Codable, Hashable, Sendable {
    case headline
    case caption
    case extendedDescription
    case keywords
    case persons
    case organisationNames
    case organisationCodes
    case digitalSourceType
    case urgency
    case sceneCodes
    case creator
    case creatorJobTitle
    case descriptionWriter
    case credit
    case copyright
    case rightsUsageTerms
    case webStatementOfRights
    case digitalImageGUID
    case imageSupplierImageID
    case jobID
    case dateCreated
    case captureDate
    case city
    case sublocation
    case provinceState
    case country
    case countryCode
    case event
    case instructions
    case source
    case creatorContactInfo
    case locationsCreated
    case locationsShown
    case latitude
    case longitude
    case rating
    case label
    case cameraRaw
    case exifOrientation

    static let defaultSelection: Set<Self> = [.caption, .headline, .persons, .keywords]

    /// Fields that may be copied when a caller opts in. The default UI still selects only the
    /// four fast-caption fields above.
    static let transferableFields: Set<Self> = Set(allCases).subtracting(protectedFields)

    static let protectedFields: Set<Self> = [
        .digitalImageGUID,
        .imageSupplierImageID,
        .dateCreated,
        .captureDate,
        .city,
        .sublocation,
        .provinceState,
        .country,
        .countryCode,
        .locationsCreated,
        .latitude,
        .longitude,
        .rating,
        .label,
        .cameraRaw,
        .exifOrientation,
    ]

    var isProtected: Bool { Self.protectedFields.contains(self) }
}

nonisolated enum CaptionCopyPreviousMergeMode: String, Codable, Equatable, Sendable {
    case replace
    case append
}

nonisolated struct CaptionCopyPreviousConfiguration: Sendable {
    var selectedFields: Set<CaptionCopyPreviousField>
    var allowedFields: Set<CaptionCopyPreviousField>
    var defaultMode: CaptionCopyPreviousMergeMode
    var modeByField: [CaptionCopyPreviousField: CaptionCopyPreviousMergeMode]
    var scalarAppendSeparator: String

    init(
        selectedFields: Set<CaptionCopyPreviousField> = CaptionCopyPreviousField.defaultSelection,
        allowedFields: Set<CaptionCopyPreviousField> = CaptionCopyPreviousField.transferableFields,
        defaultMode: CaptionCopyPreviousMergeMode = .replace,
        modeByField: [CaptionCopyPreviousField: CaptionCopyPreviousMergeMode] = [:],
        scalarAppendSeparator: String = "\n"
    ) {
        self.selectedFields = selectedFields
        self.allowedFields = allowedFields
        self.defaultMode = defaultMode
        self.modeByField = modeByField
        self.scalarAppendSeparator = scalarAppendSeparator
    }

    func mode(for field: CaptionCopyPreviousField) -> CaptionCopyPreviousMergeMode {
        modeByField[field] ?? defaultMode
    }
}

nonisolated enum CaptionCopyPreviousStatus: String, Equatable, Sendable {
    case completed
    case missingPrevious
    case missingCurrent
}

nonisolated enum CaptionCopyPreviousDisposition: String, Equatable, Sendable {
    case applied
    case unchanged
    case skippedNotAllowed
    case skippedNoSourceValue
    case protected
    case missingPrevious
    case missingCurrent
}

/// One non-sensitive preview line. Values are deliberately omitted so the result is safe to log.
nonisolated struct CaptionCopyPreviousFieldResult: Sendable, Equatable {
    let field: CaptionCopyPreviousField
    let mode: CaptionCopyPreviousMergeMode
    let disposition: CaptionCopyPreviousDisposition

    var changed: Bool { disposition == .applied }
}

/// The proposed output and an audit-friendly explanation for every requested field.
nonisolated struct CaptionCopyPreviousResult: Sendable, Equatable {
    let status: CaptionCopyPreviousStatus
    let metadata: IPTCMetadata?
    let fields: [CaptionCopyPreviousFieldResult]

    var changed: Bool { fields.contains(where: \.changed) }
    var appliedFields: [CaptionCopyPreviousField] {
        fields.filter(\.changed).map(\.field)
    }
    var protectedFields: [CaptionCopyPreviousField] {
        fields.filter { $0.disposition == .protected }.map(\.field)
    }
}

/// Pure Copy Previous planner. Neither input is ever mutated.
nonisolated struct CaptionCopyPreviousService: Sendable {
    func copy(
        previous: IPTCMetadata?,
        current: IPTCMetadata?,
        configuration: CaptionCopyPreviousConfiguration = CaptionCopyPreviousConfiguration()
    ) -> CaptionCopyPreviousResult {
        let fields = CaptionCopyPreviousField.allCases.filter(configuration.selectedFields.contains)

        guard let previous else {
            return missingResult(
                status: .missingPrevious,
                disposition: .missingPrevious,
                fields: fields,
                current: current,
                configuration: configuration
            )
        }
        guard var output = current else {
            return missingResult(
                status: .missingCurrent,
                disposition: .missingCurrent,
                fields: fields,
                current: nil,
                configuration: configuration
            )
        }

        var previews: [CaptionCopyPreviousFieldResult] = []
        previews.reserveCapacity(fields.count)
        for field in fields {
            let requestedMode = configuration.mode(for: field)
            let disposition: CaptionCopyPreviousDisposition
            if field.isProtected {
                disposition = .protected
            } else if !configuration.allowedFields.contains(field) {
                disposition = .skippedNotAllowed
            } else {
                disposition = apply(
                    field,
                    mode: requestedMode,
                    separator: configuration.scalarAppendSeparator,
                    from: previous,
                    to: &output
                )
            }
            previews.append(.init(field: field, mode: requestedMode, disposition: disposition))
        }

        return CaptionCopyPreviousResult(status: .completed, metadata: output, fields: previews)
    }

    private func missingResult(
        status: CaptionCopyPreviousStatus,
        disposition: CaptionCopyPreviousDisposition,
        fields: [CaptionCopyPreviousField],
        current: IPTCMetadata?,
        configuration: CaptionCopyPreviousConfiguration
    ) -> CaptionCopyPreviousResult {
        CaptionCopyPreviousResult(
            status: status,
            metadata: current,
            fields: fields.map {
                CaptionCopyPreviousFieldResult(
                    field: $0,
                    mode: configuration.mode(for: $0),
                    disposition: disposition
                )
            }
        )
    }

    private func apply(
        _ field: CaptionCopyPreviousField,
        mode: CaptionCopyPreviousMergeMode,
        separator: String,
        from previous: IPTCMetadata,
        to output: inout IPTCMetadata
    ) -> CaptionCopyPreviousDisposition {
        switch field {
        case .headline:
            return copyScalar(previous.title, into: &output.title, mode: mode, separator: separator)
        case .caption:
            return copyScalar(previous.description, into: &output.description, mode: mode, separator: separator)
        case .extendedDescription:
            return copyScalar(previous.extendedDescription, into: &output.extendedDescription, mode: mode, separator: separator)
        case .keywords:
            return copyList(previous.keywords, into: &output.keywords, mode: mode)
        case .persons:
            return copyList(previous.personShown, into: &output.personShown, mode: mode)
        case .organisationNames:
            return copyList(previous.organisationsShownNames, into: &output.organisationsShownNames, mode: mode)
        case .organisationCodes:
            return copyList(previous.organisationsShownCodes, into: &output.organisationsShownCodes, mode: mode)
        case .digitalSourceType:
            return copyValue(previous.digitalSourceType, into: &output.digitalSourceType)
        case .urgency:
            return copyValue(previous.urgency, into: &output.urgency)
        case .sceneCodes:
            return copyList(previous.sceneCodes, into: &output.sceneCodes, mode: mode)
        case .creator:
            return copyList(previous.creators, into: &output.creators, mode: mode)
        case .creatorJobTitle:
            return copyScalar(previous.creatorJobTitle, into: &output.creatorJobTitle, mode: mode, separator: separator)
        case .descriptionWriter:
            return copyScalar(previous.descriptionWriter, into: &output.descriptionWriter, mode: mode, separator: separator)
        case .credit:
            return copyScalar(previous.credit, into: &output.credit, mode: mode, separator: separator)
        case .copyright:
            return copyScalar(previous.copyright, into: &output.copyright, mode: mode, separator: separator)
        case .rightsUsageTerms:
            return copyScalar(previous.rightsUsageTerms, into: &output.rightsUsageTerms, mode: mode, separator: separator)
        case .webStatementOfRights:
            return copyScalar(previous.webStatementOfRights, into: &output.webStatementOfRights, mode: mode, separator: separator)
        case .jobID:
            return copyScalar(previous.jobId, into: &output.jobId, mode: mode, separator: separator)
        case .event:
            return copyScalar(previous.event, into: &output.event, mode: mode, separator: separator)
        case .instructions:
            return copyScalar(previous.instructions, into: &output.instructions, mode: mode, separator: separator)
        case .source:
            return copyScalar(previous.source, into: &output.source, mode: mode, separator: separator)
        case .creatorContactInfo:
            return copyValue(previous.creatorContactInfo, into: &output.creatorContactInfo)
        case .locationsShown:
            return copyList(previous.locationsShown, into: &output.locationsShown, mode: mode)
        case .digitalImageGUID, .imageSupplierImageID, .dateCreated, .captureDate,
             .city, .sublocation, .provinceState, .country, .countryCode, .locationsCreated,
             .latitude, .longitude, .rating, .label, .cameraRaw, .exifOrientation:
            // Defense in depth. The public path rejects these before reaching `apply`.
            return .protected
        }
    }

    private func copyScalar(
        _ source: String?,
        into destination: inout String?,
        mode: CaptionCopyPreviousMergeMode,
        separator: String
    ) -> CaptionCopyPreviousDisposition {
        guard let source = normalizedScalar(source) else { return .skippedNoSourceValue }
        let proposed: String
        switch mode {
        case .replace:
            proposed = source
        case .append:
            if let existing = normalizedScalar(destination) {
                proposed = existing == source ? existing : existing + separator + source
            } else {
                proposed = source
            }
        }
        guard destination != proposed else { return .unchanged }
        destination = proposed
        return .applied
    }

    /// Non-string scalar and structured fields have no meaningful append representation, so an
    /// append request safely uses replacement semantics rather than fabricating a merge.
    private func copyValue<Value: Equatable>(
        _ source: Value?,
        into destination: inout Value?
    ) -> CaptionCopyPreviousDisposition {
        guard let source else { return .skippedNoSourceValue }
        guard destination != source else { return .unchanged }
        destination = source
        return .applied
    }

    private func copyList<Value: Hashable>(
        _ source: [Value],
        into destination: inout [Value],
        mode: CaptionCopyPreviousMergeMode
    ) -> CaptionCopyPreviousDisposition {
        let source = orderedUnique(source)
        guard !source.isEmpty else { return .skippedNoSourceValue }
        let proposed: [Value]
        switch mode {
        case .replace:
            proposed = source
        case .append:
            proposed = orderedUnique(destination + source)
        }
        guard destination != proposed else { return .unchanged }
        destination = proposed
        return .applied
    }

    private func orderedUnique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func normalizedScalar(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
