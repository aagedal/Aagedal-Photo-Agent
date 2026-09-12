import Foundation

nonisolated enum FaceEmbeddingInterchangeError: LocalizedError, Equatable {
    case invalidByteCount(actual: Int)
    case invalidMagic
    case invalidDimension(actual: Int)
    case nonFiniteValue(index: Int)
    case zeroVector
    case notL2Normalized(norm: Double)

    var errorDescription: String? {
        switch self {
        case .invalidByteCount(let actual):
            return "The face embedding has \(actual) bytes; FEM2-512 requires exactly 2,056."
        case .invalidMagic:
            return "The face embedding does not have the FEM2 header."
        case .invalidDimension(let actual):
            return "The face embedding has dimension \(actual); this library requires 512."
        case .nonFiniteValue(let index):
            return "The face embedding contains a non-finite value at index \(index)."
        case .zeroVector:
            return "The face embedding is a zero vector."
        case .notL2Normalized(let norm):
            return "The face embedding has L2 norm \(norm); this library requires a normalized vector."
        }
    }
}

/// Strict, platform-independent admission for the shared Known People FEM2 payload.
///
/// `EmbeddingCodec` remains the internal compatibility codec. Interchange has a tighter
/// contract: 512 finite little-endian Float32 values and an L2 norm within 0.0001 of 1.
/// Shape alone does not establish model/preprocessing provenance; callers must verify the
/// library's embedding-space identity separately before exporting or importing a snapshot.
nonisolated enum FaceEmbeddingInterchangeCodec {
    static let dimension = 512
    static let byteCount = 8 + dimension * MemoryLayout<UInt32>.size
    static let normalizationTolerance = 0.0001

    static func validate(_ data: Data) throws -> [Float] {
        guard data.count == byteCount else {
            throw FaceEmbeddingInterchangeError.invalidByteCount(actual: data.count)
        }

        return try data.withUnsafeBytes { raw in
            let encodedMagic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard UInt32(littleEndian: encodedMagic) == EmbeddingCodec.magic else {
                throw FaceEmbeddingInterchangeError.invalidMagic
            }
            let encodedDimension = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let actualDimension = Int(UInt32(littleEndian: encodedDimension))
            guard actualDimension == dimension else {
                throw FaceEmbeddingInterchangeError.invalidDimension(actual: actualDimension)
            }

            var vector = [Float]()
            vector.reserveCapacity(dimension)
            var squaredNorm = 0.0
            for index in 0..<dimension {
                let encodedBits = raw.loadUnaligned(
                    fromByteOffset: 8 + index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
                let value = Float(bitPattern: UInt32(littleEndian: encodedBits))
                guard value.isFinite else {
                    throw FaceEmbeddingInterchangeError.nonFiniteValue(index: index)
                }
                vector.append(value)
                squaredNorm += Double(value) * Double(value)
            }

            guard squaredNorm > 0 else { throw FaceEmbeddingInterchangeError.zeroVector }
            let norm = squaredNorm.squareRoot()
            guard abs(norm - 1) <= normalizationTolerance else {
                throw FaceEmbeddingInterchangeError.notL2Normalized(norm: norm)
            }
            return vector.map { Float(Double($0) / norm) }
        }
    }

    static func encode(_ vector: [Float]) throws -> Data {
        guard vector.count == dimension else {
            throw FaceEmbeddingInterchangeError.invalidDimension(actual: vector.count)
        }
        for (index, value) in vector.enumerated() where !value.isFinite {
            throw FaceEmbeddingInterchangeError.nonFiniteValue(index: index)
        }
        let squaredNorm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squaredNorm > 0 else { throw FaceEmbeddingInterchangeError.zeroVector }
        let norm = squaredNorm.squareRoot()
        guard abs(norm - 1) <= normalizationTolerance else {
            throw FaceEmbeddingInterchangeError.notL2Normalized(norm: norm)
        }

        var data = Data(capacity: byteCount)
        appendLittleEndian(EmbeddingCodec.magic, to: &data)
        appendLittleEndian(UInt32(dimension), to: &data)
        for value in vector {
            appendLittleEndian(value.bitPattern, to: &data)
        }
        return data
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
