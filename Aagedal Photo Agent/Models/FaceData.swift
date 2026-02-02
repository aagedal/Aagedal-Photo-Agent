import Foundation
import CoreGraphics

/// A detected face from an image scan.
///
/// **Embedding Architecture:**
/// - `featurePrintData`: Always contains the face-only Vision VNFeaturePrintObservation.
///   This is the ONLY embedding used for Known People matching.
/// - `clothingFeaturePrintData`: Optional clothing/torso features, ONLY used for within-folder
///   clustering in Face+Clothing mode. Never stored in the Known People database.
///
/// This separation ensures the Known People database works across different contexts
/// (same person in different clothing) while Face+Clothing mode still helps with
/// same-event clustering where clothing is consistent.
nonisolated struct DetectedFace: Codable, Identifiable {
    let id: UUID
    let imageURL: URL
    let faceRect: CGRect

    /// Face-only Vision VNFeaturePrintObservation. Always present.
    /// This is the only embedding stored in the Known People database.
    let featurePrintData: Data

    var groupID: UUID?
    let detectedAt: Date

    // Quality metrics (optional for backwards compatibility)
    let qualityScore: Float?
    let confidence: Float?
    let faceSize: Int?
    let blurScore: Float?

    /// Clothing/torso features (optional, only in Face+Clothing mode).
    /// Used ONLY for within-folder clustering, never for Known People matching.
    var clothingFeaturePrintData: Data?
    var clothingRect: CGRect?

    // The recognition mode used when this face was detected
    var embeddingMode: FaceRecognitionMode?

    init(
        id: UUID,
        imageURL: URL,
        faceRect: CGRect,
        featurePrintData: Data,
        groupID: UUID? = nil,
        detectedAt: Date,
        qualityScore: Float? = nil,
        confidence: Float? = nil,
        faceSize: Int? = nil,
        blurScore: Float? = nil,
        clothingFeaturePrintData: Data? = nil,
        clothingRect: CGRect? = nil,
        embeddingMode: FaceRecognitionMode? = nil
    ) {
        self.id = id
        self.imageURL = imageURL
        self.faceRect = faceRect
        self.featurePrintData = featurePrintData
        self.groupID = groupID
        self.detectedAt = detectedAt
        self.qualityScore = qualityScore
        self.confidence = confidence
        self.faceSize = faceSize
        self.blurScore = blurScore
        self.clothingFeaturePrintData = clothingFeaturePrintData
        self.clothingRect = clothingRect
        self.embeddingMode = embeddingMode
    }
}

nonisolated struct FaceGroup: Codable, Identifiable {
    let id: UUID
    var name: String?
    var representativeFaceID: UUID
    var faceIDs: [UUID]
}

/// Tracks a file's identity for incremental scanning
nonisolated struct FileSignature: Codable, Equatable {
    let modificationDate: Date
    let fileSize: Int64
}

/// Represents a suggestion to merge two similar face groups
nonisolated struct MergeSuggestion: Identifiable {
    let id = UUID()
    let group1ID: UUID
    let group2ID: UUID
    let similarity: Float  // 0.0-1.0, higher = more similar
}

nonisolated struct FolderFaceData: Codable {
    var folderURL: URL
    var faces: [DetectedFace]
    var groups: [FaceGroup]
    var lastScanDate: Date
    var scanComplete: Bool

    /// File signatures for incremental scanning (URL string -> signature)
    var scannedFiles: [String: FileSignature]

    /// The recognition mode used for this dataset (nil = legacy Vision mode)
    var recognitionMode: FaceRecognitionMode?

    init(
        folderURL: URL,
        faces: [DetectedFace],
        groups: [FaceGroup],
        lastScanDate: Date,
        scanComplete: Bool,
        scannedFiles: [String: FileSignature] = [:],
        recognitionMode: FaceRecognitionMode? = nil
    ) {
        self.folderURL = folderURL
        self.faces = faces
        self.groups = groups
        self.lastScanDate = lastScanDate
        self.scanComplete = scanComplete
        self.scannedFiles = scannedFiles
        self.recognitionMode = recognitionMode
    }
}
