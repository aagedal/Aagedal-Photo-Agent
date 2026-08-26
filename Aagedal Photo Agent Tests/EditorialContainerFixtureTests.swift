import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftExif
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Synthetic editorial container corpus")
struct EditorialContainerFixtureTests {
    private let fixtureNamespace = "https://aagedal.example/ns/fixture/1.0/"

    @Test("Manifest hashes bind every synthetic fixture to reviewed CC0 bytes")
    func manifestHashes() throws {
        let manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("manifest.json")))
                as? [String: Any]
        )
        #expect(manifest["license"] as? String == "CC0-1.0")
        let fixtures = try #require(manifest["fixtures"] as? [[String: Any]])

        let expected: [String: String] = [
            "synthetic-gradient.tiff": "dc6f93ee87d0c1346d0509cc1b3264f9499009642838e54ece8c512ebfe45998",
            "synthetic-gradient.png": "4b8ddde6f4faca6265569f1d0e649cbbc806bf604602a459ff369e912643ba1f",
            "synthetic-gradient.jxl": "44f39e7f5a55d84559966ab1474e6d96af80de2abdd85507a77ed2585c1a8325",
            "synthetic-raw-sidecar.xmp": "57981f5a4b0054935a544200b024d532019bba2ae1ee2f9ad0e64941cf8bf471",
        ]

        for (filename, digest) in expected {
            let entry = try #require(fixtures.first { $0["filename"] as? String == filename })
            #expect(entry["origin"] as? String != nil)
            #expect(entry["license"] as? String == "CC0-1.0")
            #expect(entry["containsPersonalData"] as? Bool == false)
            #expect(entry["sha256"] as? String == digest)
            #expect(sha256(try Data(contentsOf: fixtureURL(filename))) == digest)
        }
    }

    @Test("TIFF, PNG, and JPEG XL preserve pixels while production metadata writes round-trip")
    func supportedContainerRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialContainerFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [(filename: String, format: ImageFormat)] = [
            ("synthetic-gradient.tiff", .tiff),
            ("synthetic-gradient.png", .png),
            ("synthetic-gradient.jxl", .jpegXL),
        ]

        for item in cases {
            let workingURL = directory.appendingPathComponent(item.filename)
            try FileManager.default.copyItem(at: fixtureURL(item.filename), to: workingURL)

            let before = try ImageMetadata.read(from: workingURL)
            #expect(before.format == item.format)
            let rasterIdentity = try pixelPayloadIdentity(for: before)
                ?? decodedPixelIdentity(at: workingURL)
            let beforeSnapshot = MetadataPreservationSnapshotBuilder.makeSnapshot(from: before)

            try await SwiftExifWriteEngine().writeFields(
                [
                    .headline: "Synthetic container headline",
                    .description: "Unicode caption — Oslo",
                    .subject: "fixture, metadata",
                    .rights: "CC0-1.0",
                ],
                to: [workingURL]
            )

            let after = try ImageMetadata.read(from: workingURL)
            #expect(after.format == item.format)
            let readBack = try await SwiftExifReadService().readFullMetadata(url: workingURL)
            #expect(readBack.title == "Synthetic container headline")
            #expect(readBack.description == "Unicode caption — Oslo")
            #expect(Set(readBack.keywords) == Set(["fixture", "metadata"]))
            #expect(readBack.copyright == "CC0-1.0")

            let rewrittenRasterIdentity = try pixelPayloadIdentity(for: after)
                ?? decodedPixelIdentity(at: workingURL)
            #expect(rasterIdentity != nil)
            #expect(rewrittenRasterIdentity == rasterIdentity)

            let report = MetadataPreservationComparator.compare(
                source: beforeSnapshot,
                staged: MetadataPreservationSnapshotBuilder.makeSnapshot(from: after)
            )
            #expect(!report.hasProvenMismatch, "\(item.filename): \(report.domains)")
            #expect(report.isAcceptableForDelivery, "\(item.filename): \(report.domains)")
        }
    }

    @Test("The checked-in RAW sidecar routes embedded requests to XMP and preserves source bytes")
    func rawSidecarBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialRAWFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("synthetic-raw-sidecar.nef")
        let sourceBytes = Data("OPAQUE CAMERA RAW SENTINEL — NOT A DECODE FIXTURE".utf8)
        try sourceBytes.write(to: sourceURL)
        let sidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("xmp")
        try FileManager.default.copyItem(
            at: fixtureURL("synthetic-raw-sidecar.xmp"),
            to: sidecarURL
        )

        let service = XMPSidecarService()
        let original = try #require(service.loadSidecar(for: sourceURL))
        #expect(original.title == "Synthetic RAW sidecar headline")
        #expect(original.description == "Synthetic RAW sidecar caption — no camera original is distributed.")
        #expect(original.keywords == ["synthetic", "sidecar"])
        #expect(original.digitalSourceType == .digitalCapture)
        #expect(original.cameraRaw?.exposure2012 == 0.35)

        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let result = try await boundary.write(
            metadata: IPTCMetadata(description: "Updated sidecar caption"),
            for: sourceURL,
            requestedMode: .writeToFileAndXMPSidecar,
            semantics: .merge
        )
        #expect(result.target == .xmpSidecar)
        #expect(result.xmpSidecarURL == sidecarURL)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let rewritten = try XMPReader.readFromXML(Data(contentsOf: sidecarURL))
        #expect(rewritten.description == "Updated sidecar caption")
        #expect(
            rewritten.simpleValue(namespace: XMPNamespace.crs, property: "Exposure2012") == "+0.35"
        )
        #expect(
            rewritten.simpleValue(namespace: fixtureNamespace, property: "provenance")
                == "original-generated-cc0"
        )
        #expect(MetadataWriteMode.rawOptions.allSatisfy { !$0.writesEmbedded })
    }

    @Test("Unavailable external artifacts and HEIF support boundaries are explicit")
    func unavailableArtifactsAreExplicit() throws {
        let manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("manifest.json")))
                as? [String: Any]
        )
        let unavailable = try #require(manifest["unavailableArtifacts"] as? [[String: Any]])
        let formats = Set(unavailable.compactMap { $0["format"] as? String })
        #expect(formats == ["heic/heif", "camera-raw-original", "iptc-2025.1-reference-image"])
        #expect(unavailable.allSatisfy { ($0["reason"] as? String)?.isEmpty == false })
        #expect(!FileManager.default.fileExists(atPath: fixtureURL("synthetic-gradient.heic").path))

        let heif = MetadataPreservationSnapshotBuilder.formatCapability(for: .heif)
        #expect(heif.formatIdentifier == "heif")
        #expect(heif.support(for: .exif) == .supported)
        #expect(heif.support(for: .iptc) == .unsupported)
        #expect(heif.support(for: .xmp) == .supported)
        #expect(heif.support(for: .cameraRaw) == .supported)
    }

    private func fixtureURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EditorialMetadata", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// JPEG XL metadata is inserted as sibling boxes. Hashing only the codestream boxes proves
    /// that metadata writes did not re-encode or mutate pixels, even on hosts without JXL decode.
    private func pixelPayloadIdentity(for metadata: ImageMetadata) throws -> String? {
        guard case .jpegXL(let file) = metadata.container else { return nil }
        if let codestream = file.rawCodestream { return sha256(codestream) }
        let payload = file.boxes
            .filter { $0.type == "jxlc" || $0.type == "jxlp" }
            .reduce(into: Data()) { result, box in result.append(box.data) }
        return payload.isEmpty ? nil : sha256(payload)
    }

    private func decodedPixelIdentity(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        return rendered ? sha256(Data(pixels)) : nil
    }
}

@Suite("Redistributable analysis fixture corpus")
struct AnalysisFixtureCorpusTests {
    @Test("Manifest inventories and hash-binds every CC0 analysis artifact")
    func manifestInventoryAndHashes() throws {
        let manifest = try manifest()
        #expect(manifest["license"] as? String == "CC0-1.0")
        #expect(manifest["containsPersonalData"] as? Bool == false)
        let files = try #require(manifest["files"] as? [[String: Any]])

        let declared = Set(try files.map { entry in
            let filename = try #require(entry["filename"] as? String)
            let digest = try #require(entry["sha256"] as? String)
            #expect(digest.count == 64)
            #expect((entry["origin"] as? String)?.isEmpty == false)
            #expect((entry["expectedProperties"] as? [String: Any])?.isEmpty == false)
            #expect(sha256(try Data(contentsOf: fixtureURL(filename))) == digest)
            return filename
        })

        let actual = try Set(
            FileManager.default.contentsOfDirectory(
                at: corpusDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .map(\.lastPathComponent)
            .filter { !["README.md", "manifest.json"].contains($0) }
        )
        #expect(declared == actual)

        let unavailable = try #require(
            manifest["unavailableAuthenticArtifacts"] as? [[String: Any]]
        )
        #expect(
            Set(unavailable.compactMap { $0["category"] as? String }) == [
                "camera-jpeg", "heic-heif", "camera-raw-original", "signed-c2pa-media",
                "hdr-gain-map",
            ]
        )
        #expect(unavailable.allSatisfy { ($0["reason"] as? String)?.isEmpty == false })
    }

    @Test("Raster dimensions, frames, alpha, and all eight orientations match the manifest")
    func imageProperties() throws {
        let files = try #require(manifest()["files"] as? [[String: Any]])
        for entry in files {
            guard let expected = entry["expectedProperties"] as? [String: Any],
                  let width = expected["width"] as? Int,
                  let height = expected["height"] as? Int,
                  let filename = entry["filename"] as? String
            else { continue }

            let source = try #require(
                CGImageSourceCreateWithURL(fixtureURL(filename) as CFURL, nil),
                "\(filename) must be ImageIO-decodable"
            )
            #expect(CGImageSourceGetCount(source) == (expected["frameCount"] as? Int ?? 1))
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
            if let orientation = expected["orientation"] as? Int {
                #expect(properties[kCGImagePropertyOrientation] as? Int == orientation)
            }
            if expected["alpha"] as? Bool == true {
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect([
                    CGImageAlphaInfo.premultipliedFirst,
                    .premultipliedLast,
                    .first,
                    .last,
                ].contains(image.alphaInfo))
            }
        }
    }

    @Test("Compression recipes are distinct and malformed media fails ImageIO decode")
    func compressionAndMalformedContracts() throws {
        let single = try Data(contentsOf: fixtureURL("jpeg-single-q82.jpg"))
        let double = try Data(contentsOf: fixtureURL("jpeg-double-q82-q60.jpg"))
        #expect(single != double)
        #expect(CGImageSourceCreateWithData(single as CFData, nil) != nil)
        #expect(CGImageSourceCreateWithData(double as CFData, nil) != nil)

        let malformed = try Data(contentsOf: fixtureURL("malformed-truncated.jpg"))
        if let source = CGImageSourceCreateWithData(malformed as CFData, nil) {
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) == nil)
        }
    }

    @Test("Metadata and C2PA JSON contracts remain synthetic, complete, and typed")
    func semanticCaseContracts() throws {
        let metadata = try jsonObject("metadata-cases.json")
        let metadataCases = try #require(metadata["cases"] as? [[String: Any]])
        #expect(Set(metadataCases.compactMap { $0["id"] as? String }) == [
            "stripped", "conflicting-orientation", "non-ascii-and-multiline", "malformed-values",
        ])
        #expect(metadataCases.allSatisfy { ($0["expected"] as? [String])?.isEmpty == false })

        let c2pa = try jsonObject("c2pa-status-cases.json")
        #expect((c2pa["scope"] as? String)?.contains("not signed media") == true)
        let c2paCases = try #require(c2pa["cases"] as? [[String: Any]])
        #expect(Set(c2paCases.compactMap { $0["id"] as? String }) == [
            "absent", "valid-untrusted", "valid-trusted", "invalid",
        ])
        #expect(c2paCases.allSatisfy {
            ($0["validation"] as? String)?.isEmpty == false
                && ($0["trust"] as? String)?.isEmpty == false
        })
    }

    private var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AnalysisCorpus", isDirectory: true)
    }

    private func fixtureURL(_ filename: String) -> URL {
        corpusDirectory.appendingPathComponent(filename)
    }

    private func manifest() throws -> [String: Any] {
        try jsonObject("manifest.json")
    }

    private func jsonObject(_ filename: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL(filename)))
                as? [String: Any]
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
