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
    /// Apple `VNDetectFaceCaptureQuality` score (0...1): a learned "is this a good capture of a
    /// face" metric (blur, lighting, occlusion, pose). More reliable than `blurScore` for filtering
    /// out unusable faces and for picking a group's representative thumbnail.
    let captureQuality: Float?

    /// Clothing/torso features (optional, only in Face+Clothing mode).
    /// Used ONLY for within-folder clustering, never for Known People matching.
    var clothingFeaturePrintData: Data?
    var clothingRect: CGRect?

    /// Appearance feature print (archived `VNFeaturePrintObservation` of the face crop),
    /// prewarmed after the Face scan for the Expression lens. Deliberately NOT an identity
    /// embedding — used only for within-folder appearance clustering, never for Known People.
    var appearanceFeaturePrintData: Data?

    // The recognition mode used when this face was detected
    var embeddingMode: FaceRecognitionMode?

    // MARK: - Sports tagging (optional, only populated in sports mode)
    /// Jersey number found within this face's estimated torso region, if any.
    var jerseyNumber: Int?
    /// Vision OCR confidence for the jersey number (0...1).
    var numberConfidence: Float?
    /// Dominant jersey colour sampled near the number, used for team clustering.
    var jerseyColorRGB: ColorRGB?
    /// Team side assigned after colour clustering.
    var teamSide: TeamSide?

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
        captureQuality: Float? = nil,
        clothingFeaturePrintData: Data? = nil,
        clothingRect: CGRect? = nil,
        appearanceFeaturePrintData: Data? = nil,
        embeddingMode: FaceRecognitionMode? = nil,
        jerseyNumber: Int? = nil,
        numberConfidence: Float? = nil,
        jerseyColorRGB: ColorRGB? = nil,
        teamSide: TeamSide? = nil
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
        self.captureQuality = captureQuality
        self.clothingFeaturePrintData = clothingFeaturePrintData
        self.clothingRect = clothingRect
        self.appearanceFeaturePrintData = appearanceFeaturePrintData
        self.embeddingMode = embeddingMode
        self.jerseyNumber = jerseyNumber
        self.numberConfidence = numberConfidence
        self.jerseyColorRGB = jerseyColorRGB
        self.teamSide = teamSide
    }
}

nonisolated struct FaceGroup: Codable, Identifiable {
    let id: UUID
    var name: String?
    var representativeFaceID: UUID
    var faceIDs: [UUID]
    /// Groups explicitly created by the user (split, move-to-new-group) are excluded from the synthetic "Unmatched Faces" group.
    var userCreated: Bool?
}

// MARK: - Lenses

/// A clustering "lens": one alternative grouping over the same detected faces.
///
/// Detection runs once and embeddings are stored per face; each lens is a different
/// clustering/labeling of those crops, so switching lenses never re-detects or re-embeds.
nonisolated enum FaceLens: String, Codable, CaseIterable, Sendable {
    /// ArcFace identity clustering — group people by who they are. The default.
    case face
    /// Appearance clustering (VNFeaturePrint on the face crop) — group by look and
    /// expression, not identity. Never feeds or matches Known People.
    case expression
    /// Identity + clothing combined distance — same event, same outfit.
    case redCarpet

    /// Lenses wired end-to-end and offered in the lens switcher. The switcher hides itself
    /// if this ever drops back to a single lens.
    static let available: [FaceLens] = FaceLens.allCases

    var displayName: String {
        switch self {
        case .face: "Face"
        case .expression: "Expression"
        case .redCarpet: "Red Carpet"
        }
    }

    /// One-line explanation of the lens's grouping, shown in the lens view.
    var caption: String {
        switch self {
        case .face: "Groups people by who they are."
        case .expression: "Groups by look and expression, not identity."
        case .redCarpet: "Groups by face and clothing — same event, same outfit."
        }
    }

    /// Whether this lens's groups represent identity and may feed/match Known People.
    var usesIdentity: Bool { self != .expression }
}

nonisolated enum FaceLensStatus: String, Codable, Sendable {
    case notStarted
    case embedding
    case clustering
    case complete
}

/// Per-lens clustering results and progress for one folder. The Face lens keeps its groups
/// in `FolderFaceData.groups` (the legacy location); secondary lenses store theirs here.
nonisolated struct FaceLensState: Codable, Sendable {
    var groups: [FaceGroup] = []
    var status: FaceLensStatus = .notStarted
    /// Embedding version for this lens's vectors, so bumping one lens's model doesn't
    /// invalidate the others.
    var embeddingVersion: Int?
    var lastUpdated: Date?
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

/// A moderate-confidence match between a face group and a known person,
/// requiring user confirmation (unlike auto-matches which are applied immediately).
nonisolated struct KnownPersonSuggestion: Identifiable {
    let id = UUID()
    let groupID: UUID
    let personID: UUID
    let personName: String
    let confidence: Float         // best confidence across sampled faces
    let sampledFaceCount: Int     // how many faces from the group were checked
    let matchedFaceCount: Int     // how many of those matched this person
}

/// Summary of a Known People check run, for UI feedback.
nonisolated struct KnownPeopleCheckResult {
    let autoMatchCount: Int       // groups auto-named (high confidence)
    let suggestionCount: Int      // groups with suggestions (moderate confidence)
    let noMatchCount: Int         // groups with no match at all
    let totalChecked: Int         // total unnamed groups checked
}

nonisolated struct FolderFaceData: Codable {
    var folderURL: URL
    var faces: [DetectedFace]
    var groups: [FaceGroup]
    var lastScanDate: Date
    var scanComplete: Bool

    /// File signatures for incremental scanning (URL string -> signature)
    var scannedFiles: [String: FileSignature]

    /// Embedding version for compatibility detection (nil/0 = legacy unaligned, 1 = eye-aligned crops)
    var embeddingVersion: Int?

    /// Standalone jersey-number detections (sports mode) with no associated face —
    /// e.g. back-turned players. Optional so legacy face_data.json keeps decoding.
    var numberDetections: [NumberDetection]?

    /// The lens whose grouping the expanded view shows (nil = Face).
    var activeLens: FaceLens?

    /// Secondary-lens results keyed by `FaceLens.rawValue` — the Face lens lives in `groups`.
    /// Optional so legacy face_data.json keeps decoding.
    var lensStates: [String: FaceLensState]?

    init(
        folderURL: URL,
        faces: [DetectedFace],
        groups: [FaceGroup],
        lastScanDate: Date,
        scanComplete: Bool,
        scannedFiles: [String: FileSignature] = [:],
        embeddingVersion: Int? = nil,
        numberDetections: [NumberDetection]? = nil,
        activeLens: FaceLens? = nil,
        lensStates: [String: FaceLensState]? = nil
    ) {
        self.folderURL = folderURL
        self.faces = faces
        self.groups = groups
        self.lastScanDate = lastScanDate
        self.scanComplete = scanComplete
        self.scannedFiles = scannedFiles
        self.embeddingVersion = embeddingVersion
        self.numberDetections = numberDetections
        self.activeLens = activeLens
        self.lensStates = lensStates
    }

    var currentLens: FaceLens { activeLens ?? .face }

    func groups(for lens: FaceLens) -> [FaceGroup] {
        lens == .face ? groups : (lensStates?[lens.rawValue]?.groups ?? [])
    }

    func lensState(for lens: FaceLens) -> FaceLensState {
        if lens == .face {
            return FaceLensState(
                groups: groups,
                status: scanComplete ? .complete : (faces.isEmpty ? .notStarted : .clustering),
                embeddingVersion: embeddingVersion,
                lastUpdated: lastScanDate
            )
        }
        return lensStates?[lens.rawValue] ?? FaceLensState()
    }

    /// Store a secondary lens's results. The Face lens is canonical in `groups`/`scanComplete`
    /// and cannot be set through here.
    mutating func setLensState(_ state: FaceLensState, for lens: FaceLens) {
        guard lens != .face else { return }
        var states = lensStates ?? [:]
        states[lens.rawValue] = state
        lensStates = states
    }
}
