import Foundation

/// A stable cross-case reference to one annotation on one photo.
///
/// Annotation UUIDs are only guaranteed to be unique inside their owning analysis case, so both
/// identifiers are persisted. References deliberately survive temporarily missing cases or
/// annotations so moving a photo out of and back into the working folder does not destroy links.
nonisolated struct AnalysisPhotoAnnotationReference: Codable, Hashable, Sendable {
    let caseID: UUID
    let annotationID: UUID
}

/// Geographic markup owned by the working folder instead of by any individual photo.
nonisolated struct AnalysisGlobalMapAnnotation: Identifiable, Codable, Equatable, Sendable {
    var annotation: AnalysisMapAnnotation
    var photoAnnotationReferences: [AnalysisPhotoAnnotationReference]

    var id: UUID { annotation.id }

    init(
        annotation: AnalysisMapAnnotation,
        photoAnnotationReferences: [AnalysisPhotoAnnotationReference] = []
    ) {
        self.annotation = annotation
        self.photoAnnotationReferences = photoAnnotationReferences
    }

    func validate() -> Bool {
        (try? annotation.validate()) != nil
            && Set(photoAnnotationReferences).count == photoAnnotationReferences.count
            && photoAnnotationReferences.count <= 5_000
    }

    @discardableResult
    mutating func setPhotoAnnotationLinked(
        _ reference: AnalysisPhotoAnnotationReference,
        isLinked: Bool
    ) -> Bool {
        let containsReference = photoAnnotationReferences.contains(reference)
        guard containsReference != isLinked else { return false }
        if isLinked {
            photoAnnotationReferences.append(reference)
        } else {
            photoAnnotationReferences.removeAll { $0 == reference }
        }
        return true
    }

    /// Copies the shared annotation into one photo's case, retaining a link to an annotation on
    /// that photo when the shared annotation has one.
    func copiedToPhoto(caseID: UUID, now: Date = Date()) -> AnalysisMapAnnotation {
        let linkedPhotoAnnotationID = photoAnnotationReferences.first {
            $0.caseID == caseID
        }?.annotationID
        return annotation.copied(
            linkedPhotoLabelID: linkedPhotoAnnotationID,
            now: now
        )
    }
}

nonisolated extension AnalysisMapAnnotation {
    /// Copies a photo-local annotation into the folder map and converts its local photo link to
    /// the folder map's stable cross-case reference format.
    func copiedToGlobal(caseID: UUID, now: Date = Date()) -> AnalysisGlobalMapAnnotation {
        let references = linkedPhotoLabelID.map {
            [AnalysisPhotoAnnotationReference(caseID: caseID, annotationID: $0)]
        } ?? []
        return AnalysisGlobalMapAnnotation(
            annotation: copied(now: now),
            photoAnnotationReferences: references
        )
    }
}

enum AnalysisFolderMapDocumentValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidTimestamps
    case invalidAnnotations

    var errorDescription: String? {
        switch self {
        case .invalidTimestamps:
            "The folder map contains invalid update times."
        case .invalidAnnotations:
            "The folder map contains duplicate or invalid annotations."
        }
    }
}

/// Folder-local owner document for map objects shared by several image-analysis cases.
nonisolated struct AnalysisFolderMapDocument: VersionedJSONDocument, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var annotations: [AnalysisGlobalMapAnnotation]

    static func create(now: Date = Date()) -> AnalysisFolderMapDocument {
        AnalysisFolderMapDocument(
            schemaVersion: currentSchemaVersion,
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            annotations: []
        )
    }

    mutating func setAnnotation(
        _ replacement: AnalysisGlobalMapAnnotation,
        now: Date = Date()
    ) {
        var replacement = replacement
        replacement.annotation.markUpdated(now: now)
        if let index = annotations.firstIndex(where: { $0.id == replacement.id }) {
            annotations[index] = replacement
        } else {
            annotations.append(replacement)
        }
        updatedAt = max(max(now, createdAt), replacement.annotation.updatedAt)
    }

    @discardableResult
    mutating func removeAnnotation(id: UUID, now: Date = Date()) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        annotations.remove(at: index)
        updatedAt = max(now, createdAt)
        return true
    }

    mutating func replaceAnnotations(
        _ replacements: [AnalysisGlobalMapAnnotation],
        now: Date = Date()
    ) {
        annotations = replacements
        updatedAt = max(
            max(now, createdAt),
            replacements.map(\.annotation.updatedAt).max() ?? createdAt
        )
    }

    func validateForPersistence() throws {
        guard updatedAt >= createdAt,
              annotations.allSatisfy({ $0.annotation.updatedAt <= updatedAt }) else {
            throw AnalysisFolderMapDocumentValidationError.invalidTimestamps
        }
        guard annotations.count <= 500,
              Set(annotations.map(\.id)).count == annotations.count,
              annotations.allSatisfy({ $0.validate() }) else {
            throw AnalysisFolderMapDocumentValidationError.invalidAnnotations
        }
    }
}

nonisolated struct AnalysisGlobalMapAnnotationUndoHistory: Sendable {
    nonisolated struct Transaction: Equatable, Sendable {
        let before: [AnalysisGlobalMapAnnotation]
        let after: [AnalysisGlobalMapAnnotation]
        let actionName: String
    }

    private let maximumTransactionCount: Int
    private(set) var undoTransactions: [Transaction] = []
    private(set) var redoTransactions: [Transaction] = []

    init(maximumTransactionCount: Int = 100) {
        self.maximumTransactionCount = max(1, maximumTransactionCount)
    }

    var canUndo: Bool { !undoTransactions.isEmpty }
    var canRedo: Bool { !redoTransactions.isEmpty }
    var undoActionName: String? { undoTransactions.last?.actionName }
    var redoActionName: String? { redoTransactions.last?.actionName }

    mutating func record(
        before: [AnalysisGlobalMapAnnotation],
        after: [AnalysisGlobalMapAnnotation],
        actionName: String
    ) {
        guard before != after else { return }
        undoTransactions.append(Transaction(before: before, after: after, actionName: actionName))
        if undoTransactions.count > maximumTransactionCount {
            undoTransactions.removeFirst(undoTransactions.count - maximumTransactionCount)
        }
        redoTransactions.removeAll(keepingCapacity: true)
    }

    mutating func undo() -> [AnalysisGlobalMapAnnotation]? {
        guard let transaction = undoTransactions.popLast() else { return nil }
        redoTransactions.append(transaction)
        return transaction.before
    }

    mutating func redo() -> [AnalysisGlobalMapAnnotation]? {
        guard let transaction = redoTransactions.popLast() else { return nil }
        undoTransactions.append(transaction)
        return transaction.after
    }

    mutating func removeAll() {
        undoTransactions.removeAll(keepingCapacity: false)
        redoTransactions.removeAll(keepingCapacity: false)
    }
}
