import CoreGraphics
import Foundation

nonisolated struct CaptionConfirmedPerson: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let normalizedFaceRect: CGRect
}

/// Produces a spatial order only from named identity groups with usable, normalized geometry.
/// Unnamed clusters, suggestion-only matches, number-only detections, and malformed rectangles
/// are intentionally absent: the caption UI must never imply certainty that the face system did
/// not persist.
nonisolated enum CaptionConfirmedPersonOrdering {
    static func people(
        for imageURL: URL,
        in faceData: FolderFaceData?
    ) -> [CaptionConfirmedPerson] {
        guard let faceData else { return [] }
        let namesByGroup = Dictionary(uniqueKeysWithValues: faceData.groups.compactMap { group in
            let name = group.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : (group.id, name)
        })
        let target = imageURL.standardizedFileURL

        return faceData.faces.compactMap { face in
            guard face.imageURL.standardizedFileURL == target,
                  let groupID = face.groupID,
                  let name = namesByGroup[groupID],
                  isUsableNormalizedGeometry(face.faceRect) else { return nil }
            return CaptionConfirmedPerson(
                id: face.id,
                name: name,
                normalizedFaceRect: face.faceRect
            )
        }
        .sorted { lhs, rhs in
            if lhs.normalizedFaceRect.midX != rhs.normalizedFaceRect.midX {
                return lhs.normalizedFaceRect.midX < rhs.normalizedFaceRect.midX
            }
            if lhs.normalizedFaceRect.midY != rhs.normalizedFaceRect.midY {
                return lhs.normalizedFaceRect.midY > rhs.normalizedFaceRect.midY
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func isUsableNormalizedGeometry(_ rect: CGRect) -> Bool {
        let values = [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY]
        return values.allSatisfy(\.isFinite)
            && rect.width > 0
            && rect.height > 0
            && rect.minX >= 0
            && rect.minY >= 0
            && rect.maxX <= 1
            && rect.maxY <= 1
    }
}

nonisolated struct CaptionWorkspaceFieldLayout: Equatable, Sendable {
    let priority: [MetadataFieldID]
    let secondary: [MetadataFieldID]

    static func make(
        configuration: DeadlineCaptionFieldConfiguration?,
        groupsSecondaryFields: Bool = true
    ) -> Self {
        let configuredOrder = configuration?.orderedFieldIDs ?? MetadataFieldID.editorFields
        let visible = Set(configuration?.visibleFieldIDs ?? MetadataFieldID.editorFields)
        let orderedVisible = unique(configuredOrder.filter(visible.contains))
        let missingVisible = MetadataFieldID.editorFields.filter {
            visible.contains($0) && !orderedVisible.contains($0)
        }
        let completeOrder = orderedVisible + missingVisible
        guard groupsSecondaryFields else {
            return Self(priority: completeOrder, secondary: [])
        }
        let priorityCandidates: Set<MetadataFieldID> = [
            .headline, .description, .personShown, .keywords, .event,
            .city, .sublocation, .provinceState, .country,
            .creator, .credit, .copyright,
        ]
        return Self(
            priority: completeOrder.filter(priorityCandidates.contains),
            secondary: completeOrder.filter { !priorityCandidates.contains($0) }
        )
    }

    private static func unique(_ fields: [MetadataFieldID]) -> [MetadataFieldID] {
        var seen = Set<MetadataFieldID>()
        return fields.filter { seen.insert($0).inserted }
    }
}

nonisolated enum CaptionWorkspaceValidationSummary {
    static func issues(
        for field: MetadataFieldID,
        in report: MetadataValidationReport
    ) -> [MetadataValidationIssue] {
        report.issues.filter { $0.field == field }
    }

    static func maximumCharacterCount(
        for field: MetadataFieldID,
        profile: MetadataValidationProfile
    ) -> Int? {
        profile.rules.compactMap { rule in
            if case let .maximumLength(ruleField, count) = rule.requirement,
               ruleField == field,
               count >= 0 {
                return count
            }
            return nil
        }.min()
    }

    static func characterCount(
        for field: MetadataFieldID,
        metadata: IPTCMetadata
    ) -> Int {
        field.textValue(in: metadata)?.count ?? 0
    }
}

/// The small, always-visible validation summary shown above Caption's collapsible field list.
/// Selection deliberately reuses the shared report's blocker ordering before falling back to the
/// first remaining issue, matching the workspace's existing Fix Next behavior.
nonisolated struct CaptionWorkspaceChecklistSummary: Equatable, Sendable {
    let readiness: CaptionReadiness
    let blockerCount: Int
    let warningCount: Int
    let informationCount: Int
    let nextIssue: MetadataValidationIssue?

    static func make(
        report: MetadataValidationReport,
        actionableFields: Set<MetadataFieldID>? = nil
    ) -> Self {
        let actionableIssues = actionableFields.map { fields in
            report.issues.filter { fields.contains($0.field) }
        } ?? report.issues
        return Self(
            readiness: CaptionReadinessResolver.readiness(for: report),
            blockerCount: report.blockerCount,
            warningCount: report.warningCount,
            informationCount: report.informationCount,
            nextIssue: actionableIssues.first { $0.severity == .blocker }
                ?? actionableIssues.first
        )
    }
}

nonisolated enum CaptionPreviewGeometry {
    static func fittedImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func displayRect(forVisionRect rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + (1 - rect.maxY) * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }
}

nonisolated enum CaptionWriteAndNextGate {
    static func shouldAdvance(
        pendingURL: URL?,
        currentURL: URL?,
        writeSucceeded: Bool
    ) -> Bool {
        guard writeSucceeded,
              let pendingURL,
              let currentURL else { return false }
        return pendingURL.standardizedFileURL == currentURL.standardizedFileURL
    }
}

nonisolated enum CaptionActionFocus: String, CaseIterable, Sendable {
    case previous
    case saveAndNext
    case writeAndNext
    case applyTemplate
    case copyPrevious
    case fixNext
    case more
    case close
}

nonisolated enum CaptionKeyboardSurface: Hashable, Sendable {
    case priorityField(MetadataFieldID)
    case action(CaptionActionFocus)
}

nonisolated struct CaptionKeyboardOrder: Equatable, Sendable {
    let surfaces: [CaptionKeyboardSurface]

    init(priorityFields: [MetadataFieldID]) {
        surfaces = priorityFields.map(CaptionKeyboardSurface.priorityField)
            + CaptionActionFocus.allCases.map(CaptionKeyboardSurface.action)
    }

    func adjacent(
        to current: CaptionKeyboardSurface?,
        reverse: Bool
    ) -> CaptionKeyboardSurface? {
        guard !surfaces.isEmpty else { return nil }
        guard let current, let index = surfaces.firstIndex(of: current) else {
            return reverse ? surfaces.last : surfaces.first
        }
        let offset = reverse ? -1 : 1
        let target = (index + offset + surfaces.count) % surfaces.count
        return surfaces[target]
    }
}

nonisolated enum CaptionAccessibilityAnnouncement: String, Sendable {
    case savedAndAdvanced = "Saved and moved to the next photo."
    case wroteAndAdvanced = "Wrote metadata and moved to the next photo."
}
