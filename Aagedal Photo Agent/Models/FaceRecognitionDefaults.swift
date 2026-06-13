import Foundation

/// Centralized tunable defaults for the face-recognition pipeline, all in the ArcFace
/// **cosine-distance** space (`0...2`, lower = more similar).
///
/// These replace the old `VNFeaturePrintObservation` thresholds, which lived on a completely
/// different distance scale and are not portable here. The values below are reasonable starting
/// points for the AuraFace/ArcFace embedding and should be refined empirically on labeled data.
nonisolated enum FaceRecognitionDefaults {
    /// Embedding-space version. Bump when the model or its preprocessing changes; a mismatch with
    /// `FolderFaceData.embeddingVersion` forces a full re-scan, and a mismatch with the stored
    /// Known People schema starts that database fresh.
    static let embeddingVersion = 3

    /// Master switch for the secondary face lenses (Expression / Red Carpet / Sports). Off for the
    /// 2.0 release: only the canonical Face lens ships, with no lens switcher. The lens code and
    /// per-lens storage stay intact — flip this to `true` to bring the switcher, assist strips, and
    /// background prewarm back for 2.1. Gates `availableLenses`, the `activeLens` getter (so a
    /// folder with a persisted secondary lens still opens on Face), and `prewarmSecondaryLensesIfNeeded`.
    static let multiLensEnabled = false

    // MARK: - Clustering (cosine distance)
    //
    // Calibrated against AuraFace on labeled faces: same-person pairs cluster around cosine
    // distance ≈ 0.45 (similarity ≈ 0.55), different-person pairs around ≈ 0.92 (similarity ≈ 0.08),
    // with clean separation at distance ≈ 0.70. The default sits at that boundary so normal
    // pose/lighting variation of one person still groups together without merging different people.

    /// Maximum cosine distance for two faces to be grouped as the same person.
    static let clusteringThreshold: Float = 0.70

    /// Minimum face quality score (0...1) to seed the first (high-quality) clustering pass.
    static let qualityGateThreshold: Float = 0.50

    /// Minimum Apple `VNDetectFaceCaptureQuality` (0...1) to keep a detected face. Faces below this
    /// are too blurry/occluded to be useful and are dropped at detection. Tunable via Settings.
    /// LFW calibration: sharp ≈ 0.3–0.45, slight ≈ 0.22–0.34, moderate ≈ 0.09–0.16, heavy < 0.08.
    /// 0.15 chosen from real-photo testing as a light default; the end user fine-tunes via the
    /// "Sharpness" slider in the expanded face view.
    static let minFaceQuality: Float = 0.15
    /// Slider range for the "minimum sharpness" control (0 = keep everything).
    static let minFaceQualityMax: Float = 0.5

    // MARK: - Known People gallery matching (favors precision over recall)

    /// Maximum cosine distance to auto-assign a group to a known person.
    static let knownPeopleMatchThreshold: Float = 0.68

    /// Minimum confidence (`= 1 - distance`) required to auto-apply a match.
    static let knownPeopleMinConfidence: Float = 0.32

    /// Required confidence gap between the best and second-best candidate (ambiguity guard).
    static let knownPeopleMinConfidenceGap: Float = 0.04

    // MARK: - Expression lens (VNFeaturePrint distance, 0...~2)
    //
    // Appearance vectors come from `VNGenerateImageFeaturePrintRequest` on the stored face
    // crops — a general image-similarity descriptor, deliberately not identity. The scale is
    // Vision's own; the pre-ArcFace face pipeline clustered identities at 0.90 on it, so the
    // appearance default sits a bit stricter to group by look rather than person.

    /// Maximum Vision feature-print distance for two face crops to share an Expression group.
    static let expressionClusteringThreshold: Float = 0.80

    /// Version of the Expression lens's appearance embedding. Bump when the source crop or
    /// request changes; a mismatch re-runs the prewarm for that lens only.
    static let expressionEmbeddingVersion = 1

    // MARK: - Red Carpet lens (combined distance)
    //
    // `faceCosine * redCarpetFaceWeight + clothingFeaturePrint * (1 - redCarpetFaceWeight)`.
    // Both components live on a 0...2 scale (ArcFace cosine; Vision feature print). With the
    // 0.7/0.3 split carried over from the old Face+Clothing mode and the calibrated face
    // threshold of 0.70, consistent attire pulls borderline same-person pairs together:
    // 0.7·0.70 + 0.3·0.8 ≈ 0.73.

    /// Weight of the face (identity) component in the Red Carpet combined distance.
    static let redCarpetFaceWeight: Float = 0.7

    /// Maximum combined distance for two faces to share a Red Carpet group.
    static let redCarpetClusteringThreshold: Float = 0.72

    /// Version of the Red Carpet lens's clothing embedding. Bump when the torso estimation
    /// or request changes; a mismatch re-runs the prewarm for that lens only.
    static let redCarpetEmbeddingVersion = 1
}
