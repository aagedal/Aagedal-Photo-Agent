import Testing
import Foundation
import CoreGraphics
@testable import Aagedal_Photo_Agent

/// Tests for the face-embedding serialization + distance layer that replaced the old
/// `VNFeaturePrintObservation` payload, plus a smoke test of the bundled CoreML embedder.
@Suite("FaceEmbedding")
struct FaceEmbeddingTests {

    // MARK: - EmbeddingCodec

    @Test func encodeDecodeRoundTrips() {
        let vector: [Float] = [0.0, 1.5, -2.25, 3.125, 1e-6, -1e6]
        let data = EmbeddingCodec.encode(vector)
        let decoded = EmbeddingCodec.decode(data)
        #expect(decoded != nil)
        #expect(decoded == vector)
    }

    @Test func decodeRejectsLegacyAndCorruptData() {
        // Legacy NSKeyedArchiver blobs start with the "bplist00" magic — wrong codec magic.
        let legacy = Data("bplist00legacyfeatureprintpayload".utf8)
        #expect(EmbeddingCodec.decode(legacy) == nil)

        // Too short to even hold the header.
        #expect(EmbeddingCodec.decode(Data([0x01, 0x02, 0x03])) == nil)
        #expect(EmbeddingCodec.decode(Data()) == nil)

        // Correct magic + count, but the float payload is truncated by one byte.
        var truncated = EmbeddingCodec.encode([1, 2, 3, 4])
        truncated.removeLast()
        #expect(EmbeddingCodec.decode(truncated) == nil)
    }

    @Test func cosineDistanceOnUnitVectors() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        let opposite: [Float] = [-1, 0, 0, 0]

        // Same direction → 0, orthogonal → 1, opposite → 2.
        #expect(approxEqual(EmbeddingCodec.cosineDistance(a, a), 0))
        #expect(approxEqual(EmbeddingCodec.cosineDistance(a, b), 1))
        #expect(approxEqual(EmbeddingCodec.cosineDistance(a, opposite), 2))
    }

    @Test func cosineDistanceIsSymmetricAndGuards() {
        let a: [Float] = [0.6, 0.8, 0, 0]
        let b: [Float] = [0, 0.8, 0.6, 0]
        let dAB = EmbeddingCodec.cosineDistance(a, b)
        let dBA = EmbeddingCodec.cosineDistance(b, a)
        #expect(dAB != nil && dBA != nil)
        #expect(approxEqual(dAB, dBA))

        // Mismatched dimensions / empty → nil rather than a bogus number.
        #expect(EmbeddingCodec.cosineDistance([1, 0], [1, 0, 0]) == nil)
        #expect(EmbeddingCodec.cosineDistance([], []) == nil)
    }

    @Test func faceDetectionDefaultsToFastMode() {
        #expect(FaceDetectionService.DetectionConfig().tiledDetection == false)
    }

    @Test func incrementalClusteringUsesExactAverageGroupDistance() {
        func face(_ vector: [Float], groupID: UUID? = nil) -> DetectedFace {
            DetectedFace(
                id: UUID(),
                imageURL: URL(fileURLWithPath: "/tmp/centroid-test.jpg"),
                faceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                featurePrintData: EmbeddingCodec.encode(vector),
                groupID: groupID,
                detectedAt: Date(),
                qualityScore: 0.9
            )
        }

        let groupID = UUID()
        let memberA = face([1, 0, 0], groupID: groupID)
        let memberB = face([0.8, 0.6, 0], groupID: groupID)
        let firstNewFace = face([1, 0, 0])
        let secondNewFace = face([0.8, 0.6, 0])
        let existingGroup = FaceGroup(
            id: groupID,
            name: nil,
            representativeFaceID: memberA.id,
            faceIDs: [memberA.id, memberB.id]
        )

        var config = FaceDetectionService.DetectionConfig()
        config.clusteringThreshold = 0.15
        let groups = FaceDetectionService().clusterFacesWithAlgorithm(
            [firstNewFace, secondNewFace],
            allFaces: [memberA, memberB, firstNewFace, secondNewFace],
            existingGroups: [existingGroup],
            config: config
        )

        // Both new faces are 0.1 average cosine distance from the original two-member group.
        // The second decision also includes the first newly attached face in the running average.
        #expect(groups.count == 1)
        #expect(Set(groups[0].faceIDs) == Set([memberA.id, memberB.id, firstNewFace.id, secondNewFace.id]))
    }

    // MARK: - CoreMLFaceEmbedder (bundled model smoke test)

    @Test func embedderProducesNormalizedDeterministicVectors() async throws {
        let embedder = CoreMLFaceEmbedder.shared
        let image = Self.makeTestImage(seed: 7)

        let v1: [Float]
        do {
            v1 = try await embedder.embed(image)
        } catch {
            // The compiled model may not be present in the test bundle depending on the
            // test host; in that case this smoke test is a no-op rather than a failure.
            return
        }

        #expect(v1.count == embedder.dimension)

        // L2-normalized: ‖v‖ ≈ 1.
        let norm = sqrt(v1.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 1e-3)

        // Deterministic: same input → same embedding → ~zero distance.
        let v1again = try await embedder.embed(image)
        let selfDistance = EmbeddingCodec.cosineDistance(v1, v1again)
        #expect(selfDistance != nil && selfDistance! < 1e-4)

        // A different input still yields a valid, finite, normalized vector.
        let v2 = try await embedder.embed(Self.makeTestImage(seed: 200))
        #expect(v2.count == embedder.dimension)
        #expect(v2.allSatisfy { $0.isFinite })
    }

    // MARK: - FaceLensService clustering

    /// Identity-distance closure over encoded ArcFace embeddings, as the lens clustering uses.
    private static func identityDistance(_ a: DetectedFace, _ b: DetectedFace) -> Float? {
        EmbeddingCodec.cosineDistance(a.featurePrintData, b.featurePrintData)
    }

    /// Two faces with near-identical vectors group; an orthogonal one stays apart.
    @Test func lensClusteringGroupsByDistance() {
        func face(vector: [Float], quality: Float = 0.9) -> DetectedFace {
            DetectedFace(
                id: UUID(),
                imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                faceRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.2),
                featurePrintData: EmbeddingCodec.encode(vector),
                detectedAt: Date(),
                qualityScore: quality
            )
        }

        let a = face(vector: [1, 0, 0, 0])
        let b = face(vector: [0.999, 0.0447, 0, 0])   // ~0.001 cosine distance from a
        let c = face(vector: [0, 1, 0, 0])            // orthogonal: distance 1 > threshold

        let groups = FaceLensService().clusterFaces([a, b, c], threshold: 0.72, distance: Self.identityDistance)

        #expect(groups.count == 2)
        #expect(Set(groups.flatMap(\.faceIDs)) == Set([a.id, b.id, c.id]))
        let pairGroup = groups.first { $0.faceIDs.count == 2 }
        #expect(pairGroup != nil)
        #expect(Set(pairGroup?.faceIDs ?? []) == Set([a.id, b.id]))
        // Largest group sorts first for the lens view.
        #expect(groups.first?.faceIDs.count == 2)
    }

    /// Faces below the quality gate still land somewhere: near an existing cluster they join
    /// it; otherwise they become singletons. Faces with undecodable embeddings end up as
    /// singletons rather than being dropped.
    @Test func lensClusteringAssignsLowQualityAndKeepsUndecodableFaces() {
        func face(vector: [Float]?, quality: Float) -> DetectedFace {
            DetectedFace(
                id: UUID(),
                imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                faceRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.2),
                featurePrintData: vector.map(EmbeddingCodec.encode) ?? Data([0xDE, 0xAD]),
                detectedAt: Date(),
                qualityScore: quality
            )
        }

        let anchor1 = face(vector: [1, 0, 0, 0], quality: 0.9)
        let anchor2 = face(vector: [0.999, 0.0447, 0, 0], quality: 0.9)
        let lowNear = face(vector: [0.998, 0.0632, 0, 0], quality: 0.1)  // below gate, near the pair
        let lowFar = face(vector: [0, 0, 1, 0], quality: 0.1)            // below gate, far away
        let broken = face(vector: nil, quality: 0.9)                     // undecodable embedding

        let groups = FaceLensService().clusterFaces(
            [anchor1, anchor2, lowNear, lowFar, broken],
            threshold: 0.72,
            distance: Self.identityDistance
        )

        #expect(Set(groups.flatMap(\.faceIDs)) == Set([anchor1.id, anchor2.id, lowNear.id, lowFar.id, broken.id]))
        let mainGroup = groups.first { $0.faceIDs.contains(anchor1.id) }
        #expect(Set(mainGroup?.faceIDs ?? []) == Set([anchor1.id, anchor2.id, lowNear.id]))
        #expect(groups.first { $0.faceIDs.contains(lowFar.id) }?.faceIDs.count == 1)
        #expect(groups.first { $0.faceIDs.contains(broken.id) }?.faceIDs.count == 1)
    }

    // MARK: - Helpers

    private func approxEqual(_ a: Float?, _ b: Float?, tolerance: Float = 1e-4) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) < tolerance
    }

    private static func makeTestImage(seed: Int) -> CGImage {
        let n = 112
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 4
                pixels[i] = UInt8((x + seed) & 0xFF)
                pixels[i + 1] = UInt8((y + seed) & 0xFF)
                pixels[i + 2] = UInt8(((x ^ y) + seed) & 0xFF)
                pixels[i + 3] = 255
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = pixels.withUnsafeMutableBytes { ptr in
            CGContext(
                data: ptr.baseAddress,
                width: n, height: n,
                bitsPerComponent: 8,
                bytesPerRow: n * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }!
        return ctx.makeImage()!
    }
}
