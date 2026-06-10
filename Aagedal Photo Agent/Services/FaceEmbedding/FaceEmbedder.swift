import CoreGraphics

/// Produces an L2-normalized face-identity embedding from an aligned face crop.
///
/// Unlike `VNGenerateImageFeaturePrintRequest` (a general-purpose image-similarity
/// descriptor), a `FaceEmbedder` maps a face to an identity-discriminative vector:
/// images of the same person land close together and different people land far apart,
/// largely independent of pose, lighting and background.
///
/// The returned vector is always L2-normalized, so cosine distance reduces to
/// `1 - dot(a, b)` (see `EmbeddingCodec.cosineDistance`).
nonisolated protocol FaceEmbedder: Sendable {
    /// Dimensionality of the returned embedding (e.g. 512 for ArcFace R100).
    var dimension: Int { get }

    /// Identifies the embedding space. Bump when the model or preprocessing changes;
    /// stored as `FolderFaceData.embeddingVersion` so a mismatch forces a full re-scan.
    var version: Int { get }

    /// Run the model on an aligned face crop and return an L2-normalized embedding.
    /// The crop should already be face-aligned (see the ArcFace alignment in
    /// `FaceDetectionService`); the embedder resizes/normalizes internally, so any
    /// upright face `CGImage` is accepted, but alignment quality affects accuracy.
    func embed(_ alignedFace: CGImage) async throws -> [Float]
}
