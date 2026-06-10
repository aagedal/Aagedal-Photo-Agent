import Foundation
import Accelerate

/// Serialization + distance for face-identity embeddings.
///
/// Replaces the previous `NSKeyedArchiver(VNFeaturePrintObservation)` payload that was
/// stored in `DetectedFace.featurePrintData` / `PersonEmbedding.featurePrintData`.
/// The new payload is a small self-describing blob:
///
///     [magic: UInt32 = "FEM2"][count: UInt32][count × Float32]  (native little-endian)
///
/// The magic + count let `decode` cleanly reject legacy archived blobs (they fail the
/// magic check), so a stray pre-rewrite embedding never decodes to garbage.
nonisolated enum EmbeddingCodec {
    /// "FEM2" — face embedding format, embedding version 2.
    static let magic: UInt32 = 0x46_45_4D_32

    static func encode(_ vector: [Float]) -> Data {
        var header: [UInt32] = [magic, UInt32(vector.count)]
        var data = Data(capacity: 8 + vector.count * MemoryLayout<Float>.size)
        header.withUnsafeBytes { data.append(contentsOf: $0) }
        vector.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Decode a blob produced by `encode`. Returns nil for empty/legacy/corrupt data.
    static func decode(_ data: Data) -> [Float]? {
        guard data.count >= 8 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float]? in
            let m = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard m == magic else { return nil }
            let count = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard count > 0, data.count == 8 + count * MemoryLayout<Float>.size else { return nil }
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!, raw.baseAddress!.advanced(by: 8), count * MemoryLayout<Float>.size)
            }
            return out
        }
    }

    /// Cosine distance in `[0, 2]` between two embeddings. 0 = identical direction.
    /// Vectors are L2-normalized at embed time, so this is `1 - dot(a, b)`.
    /// Returns nil if the vectors are empty or have mismatched dimension.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return max(0, min(2, 1 - dot))
    }

    /// Convenience: cosine distance directly between two encoded blobs.
    static func cosineDistance(_ d1: Data, _ d2: Data) -> Float? {
        guard let a = decode(d1), let b = decode(d2) else { return nil }
        return cosineDistance(a, b)
    }
}
