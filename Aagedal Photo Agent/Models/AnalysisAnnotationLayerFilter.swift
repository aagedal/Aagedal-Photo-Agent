import Foundation

/// Filters the layer list without altering source-bound evidence or marker visibility.
nonisolated struct AnalysisAnnotationLayerFilter: Equatable, Sendable {
    var kind: AnalysisAnnotationKind?
    var colorID: String?

    func includes(_ annotation: AnalysisAnnotation) -> Bool {
        (kind == nil || kind == annotation.kind)
            && (colorID == nil || colorID == annotation.style.color.stableIdentifier)
    }

    func matchingIDs(in annotations: [AnalysisAnnotation]) -> Set<UUID> {
        Set(annotations.lazy.filter(includes).map(\.id))
    }
}

nonisolated struct AnalysisAnnotationLayerGroup: Identifiable, Sendable {
    let kind: AnalysisAnnotationKind
    let color: AnalysisAnnotationColor
    let annotationIDs: Set<UUID>
    let visibleCount: Int

    var id: String { kind.rawValue + ":" + color.stableIdentifier }

    static func groups(in annotations: [AnalysisAnnotation]) -> [Self] {
        var indexes: [String: Int] = [:]
        var grouped: [[AnalysisAnnotation]] = []
        for annotation in annotations {
            let key = annotation.kind.rawValue + ":" + annotation.style.color.stableIdentifier
            if let index = indexes[key] {
                grouped[index].append(annotation)
            } else {
                indexes[key] = grouped.count
                grouped.append([annotation])
            }
        }
        return grouped.compactMap { items in
            guard let first = items.first else { return nil }
            return Self(kind: first.kind, color: first.style.color,
                        annotationIDs: Set(items.map(\.id)),
                        visibleCount: items.count(where: \.isVisible))
        }
    }
}
