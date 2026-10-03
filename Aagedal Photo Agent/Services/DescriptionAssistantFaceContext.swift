import Foundation

/// Shared input preparation for the interactive editor and future batch requests.
/// Reads existing face data only; never scans, identifies people or mutates the face library.
nonisolated struct DescriptionAssistantFaceContext: Sendable {
    let people: [CaptionConfirmedPerson]
    let notice: String?

    static func load(for imageURL: URL) async -> Self {
        let result = await FaceDataFolderLoadService.shared.loadDocument(folderURL: imageURL.deletingLastPathComponent())
        guard !Task.isCancelled, case .complete(let evidence) = result else {
            return Self(people: [], notice: "Face context could not be loaded.")
        }
        let signature = await FaceScanFileSignatureService.shared.signature(for: imageURL)
        guard !Task.isCancelled, case .captured(_, let current) = signature else {
            return Self(people: [], notice: "Face context could not be loaded.")
        }
        return make(for: imageURL, data: evidence.faceData, currentSignature: current)
    }

    static func make(for imageURL: URL, data: FolderFaceData?, currentSignature: FileSignature?) -> Self {
        guard var data else { return Self(people: [], notice: "No face scan is available for this photo.") }
        // Geometry from a replaced or physically rotated file must not enter the prompt.
        guard let currentSignature, data.scannedFiles[imageURL.path] == currentSignature else {
            return Self(people: [], notice: "Face data is missing or out of date. Scan this photo again to include names.")
        }
        data.groups.removeAll { $0.isExcludedFromPersonShown }
        let people = CaptionConfirmedPersonOrdering.people(for: imageURL, in: data)
        return Self(people: people, notice: people.isEmpty ? "No named faces are available for this photo." : nil)
    }
}
