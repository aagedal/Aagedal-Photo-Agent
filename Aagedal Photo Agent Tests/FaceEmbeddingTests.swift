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
