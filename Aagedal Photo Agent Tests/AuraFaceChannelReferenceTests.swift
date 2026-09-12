import Testing
import Foundation
import CoreGraphics
import CoreML
import CryptoKit
@testable import Aagedal_Photo_Agent

@Suite("AuraFace app preprocessing reference")
struct AuraFaceChannelReferenceTests {
    private struct Reference: Decodable {
        let bgrMaximumCosineSimilarityToRGB: Double
        let embeddingDimension: Int
        let fixtureDecodedSHA256: String
        let modelFileSHA256: String
        let referenceEncoding: String
        let rgbMinimumCosineSimilarity: Double
        let rgbNormalizedEmbedding: String
        let schemaVersion: Int
    }

    private struct Fixture {
        let width: Int
        let height: Int
        let rgb: Data

        func image(swappingRedAndBlue: Bool = false) throws -> CGImage {
            var bytes = rgb
            if swappingRedAndBlue {
                bytes.withUnsafeMutableBytes { raw in
                    let pixels = raw.bindMemory(to: UInt8.self)
                    for offset in stride(from: 0, to: pixels.count, by: 3) {
                        let red = pixels[offset]
                        pixels[offset] = pixels[offset + 2]
                        pixels[offset + 2] = red
                    }
                }
            }
            let provider = try #require(CGDataProvider(data: bytes as CFData))
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            return try #require(CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: width * 3,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
        }
    }

    nonisolated private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    nonisolated private static let candidateModelPackageURL = repositoryRoot
        .appendingPathComponent("Aagedal Photo Agent/Resources/Models/AuraFaceR100.mlpackage")
    nonisolated private static let hasCandidateModel = FileManager.default.fileExists(
        atPath: candidateModelPackageURL.path
    )

    private func loadReference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AuraFaceChannelReference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private func loadFixture(reference: Reference) throws -> Fixture {
        let url = Self.repositoryRoot
            .appendingPathComponent("scripts/auraface/fixtures/channel-asymmetric-112x112.ppm.base64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        let ppm = try #require(Data(base64Encoded: encoded))
        let hash = SHA256.hash(data: ppm).map { String(format: "%02x", $0) }.joined()
        #expect(hash == reference.fixtureDecodedSHA256)

        let header = Data("P6\n112 112\n255\n".utf8)
        #expect(ppm.starts(with: header))
        let rgb = Data(ppm.dropFirst(header.count))
        #expect(rgb.count == 112 * 112 * 3)
        return Fixture(width: 112, height: 112, rgb: rgb)
    }

    private func referenceEmbedding(_ reference: Reference) throws -> [Float] {
        #expect(reference.schemaVersion == 1)
        #expect(reference.referenceEncoding == "base64(float32 little-endian normalized embedding)")
        let bytes = try #require(Data(base64Encoded: reference.rgbNormalizedEmbedding))
        #expect(bytes.count == reference.embeddingDimension * MemoryLayout<UInt32>.size)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "bcca8c81001bf7c3a59bac638a7ffc031cb8bda1129498c587ab9fd251bbbd6e")
        return bytes.withUnsafeBytes { raw in
            (0..<reference.embeddingDimension).map { index in
                let bits = raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        var dot = 0.0
        var lhsSquared = 0.0
        var rhsSquared = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsSquared += left * left
            rhsSquared += right * right
        }
        return dot / sqrt(lhsSquared * rhsSquared)
    }

    @Test("Production CGImage preprocessing is upright normalized RGB")
    func productionPreprocessingMatchesFixtureBytes() throws {
        let reference = try loadReference()
        let fixture = try loadFixture(reference: reference)
        let input = try #require(CoreMLFaceEmbedder.makeInput(from: fixture.image()))

        #expect(input.shape.map(\.intValue) == [1, 3, 112, 112])
        let planeSize = fixture.width * fixture.height
        var maximumDifference: Float = 0
        for pixel in 0..<planeSize {
            for channel in 0..<3 {
                let expected = (Float(fixture.rgb[pixel * 3 + channel]) - 127.5) / 127.5
                let actual = input[channel * planeSize + pixel].floatValue
                maximumDifference = max(maximumDifference, abs(actual - expected))
            }
        }
        #expect(maximumDifference < 0.000_001)
    }

    @Test(
        "Production embed path matches RGB reference and rejects BGR channel order",
        .enabled(
            if: Self.hasCandidateModel,
            "Requires the optional manifest-declared AuraFaceR100.mlpackage; the preprocessing test still runs in clean offline CI."
        )
    )
    func productionEmbeddingMatchesReference() async throws {
        let reference = try loadReference()
        let fixture = try loadFixture(reference: reference)
        let expected = try referenceEmbedding(reference)
        let modelFile = Self.candidateModelPackageURL
            .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        let modelFileHash = SHA256.hash(data: try Data(contentsOf: modelFile))
            .map { String(format: "%02x", $0) }.joined()
        #expect(modelFileHash == reference.modelFileSHA256)
        let compiledURL = try await MLModel.compileModel(at: Self.candidateModelPackageURL)
        defer { try? FileManager.default.removeItem(at: compiledURL) }

        let embedder = CoreMLFaceEmbedder(modelURL: compiledURL)
        let rgb = try await embedder.embed(fixture.image())
        let bgr = try await embedder.embed(fixture.image(swappingRedAndBlue: true))
        let rgbSimilarity = cosine(rgb, expected)
        let bgrSimilarityToRGB = cosine(bgr, expected)

        #expect(rgb.count == reference.embeddingDimension)
        #expect(rgbSimilarity >= reference.rgbMinimumCosineSimilarity)
        #expect(bgrSimilarityToRGB <= reference.bgrMaximumCosineSimilarityToRGB)
        #expect(rgbSimilarity - bgrSimilarityToRGB >= 0.15)
    }
}
