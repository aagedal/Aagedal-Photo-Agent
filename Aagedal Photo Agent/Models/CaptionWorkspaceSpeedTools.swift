import CoreGraphics
import Foundation

nonisolated struct CaptionConfirmedPerson: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    /// Vision-normalized, in the display-oriented (sidecar-first) frame of the full photo.
    let normalizedFaceRect: CGRect
}

/// Produces a spatial order only from named identity groups with usable, normalized geometry.
/// Unnamed clusters, suggestion-only matches, number-only detections, and malformed rectangles
/// are intentionally absent: the caption UI must never imply certainty that the face system did
/// not persist.
///
/// Stored face rects are in the file-tag frame; `orientation` maps them into the displayed
/// (sidecar-first) frame *before* ordering, so "left to right" means left to right as the
/// user sees the photo, and the returned `normalizedFaceRect`s are display-oriented.
nonisolated enum CaptionConfirmedPersonOrdering {
    static func people(
        for imageURL: URL,
        in faceData: FolderFaceData?,
        orientation: FaceDisplayOrientation
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
                normalizedFaceRect: orientation.displayRect(forFileRect: face.faceRect)
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

    /// Maps a face rect (Vision-normalized, bottom-left origin, in the full display-oriented
    /// image) into the frame of a preview rendered with `crop`, replicating the crop + straighten
    /// geometry `CameraRawApproximation.applyCrop` bakes into the pixels (the same math as the
    /// full-screen face overlay). A straightened face becomes the bounding box of its rotated
    /// corners. Returns nil when the face's centre falls outside the crop.
    static func croppedVisionRect(
        _ rect: CGRect,
        crop: CameraRawCrop?,
        displayOrientation: Int,
        renderedSize: CGSize
    ) -> CGRect? {
        guard let crop, crop.isEffectiveCrop,
              renderedSize.width > 0, renderedSize.height > 0 else { return rect }
        let dc = crop.transformedForDisplay(orientation: displayOrientation)
        let left = min(dc.left ?? 0, dc.right ?? 1)
        let right = max(dc.left ?? 0, dc.right ?? 1)
        let top = min(dc.top ?? 0, dc.bottom ?? 1)
        let bottom = max(dc.top ?? 0, dc.bottom ?? 1)
        let fracW = right - left
        let fracH = bottom - top
        guard fracW > 0.0001, fracH > 0.0001 else { return rect }

        // The renderer outputs fracW·Wf × fracH·Hf pixels, so the full-image size follows
        // from the rendered (cropped) size; only the aspect ratio matters.
        let cropW = renderedSize.width
        let cropH = renderedSize.height
        let wf = cropW / fracW
        let hf = cropH / fracH
        let cx = wf / 2, cy = hf / 2
        let theta = (dc.angle ?? 0) * .pi / 180.0
        let cosT = cos(theta), sinT = sin(theta)
        let cropCenterX = (left * wf) + cropW / 2
        let cropCenterY = ((1 - bottom) * hf) + cropH / 2
        let rcx = cropCenterX - cx, rcy = cropCenterY - cy
        let cropOriginX = cx + rcx * cosT - rcy * sinT - cropW / 2
        let cropOriginY = cy + rcx * sinT + rcy * cosT - cropH / 2

        let corners = [
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY),
        ].map { p -> CGPoint in
            let dx = p.x * wf - cx, dy = p.y * hf - cy
            let rx = cx + dx * cosT - dy * sinT
            let ry = cy + dx * sinT + dy * cosT
            return CGPoint(x: (rx - cropOriginX) / cropW, y: (ry - cropOriginY) / cropH)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard unit.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { return nil }
        let clipped = bounds.intersection(unit)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return clipped
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
        writeSucceeded: Bool,
        hasPendingChanges: Bool,
        hasUnpersistedEditorChanges: Bool
    ) -> Bool {
        guard writeSucceeded, !hasPendingChanges, !hasUnpersistedEditorChanges,
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
