import Foundation
import CoreGraphics

nonisolated struct DetectedFace: Codable, Identifiable {
    let id: UUID
    let imageURL: URL
    let faceRect: CGRect
    let featurePrintData: Data
    var groupID: UUID?
    let detectedAt: Date

    // Quality metrics (optional for backwards compatibility)
    let qualityScore: Float?
    let confidence: Float?
    let faceSize: Int?
    let blurScore: Float?

    // Clothing/torso features (optional, only populated in Face+Clothing mode)
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
