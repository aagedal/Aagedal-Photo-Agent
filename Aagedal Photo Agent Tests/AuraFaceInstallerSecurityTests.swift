import CryptoKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("AuraFace installer archive and transport security", .serialized)
struct AuraFaceInstallerSecurityTests {
    private let files = [
        "Data/com.apple.CoreML/model.mlmodel": Data("model".utf8),
        "Data/com.apple.CoreML/weights/weight.bin": Data("weights".utf8),
        "Manifest.json": Data("{}".utf8),
    ]

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/AuraFaceSecurity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func u16(_ value: Int, into data: inout Data) {
        data.append(UInt8(value & 255)); data.append(UInt8((value >> 8) & 255))
    }
    private func u32(_ value: UInt32, into data: inout Data) {
        u16(Int(value & 65535), into: &data); u16(Int(value >> 16), into: &data)
    }
    private func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return value ^ 0xffff_ffff
    }

    /// Independent tiny ZIP32 fixture; production extraction never invokes a ZIP writer.
    private func archive(names: [String]? = nil) -> Data {
        var local = Data(), central = Data()
        for (index, relative) in files.keys.sorted().enumerated() {
            let bytes = files[relative]!
            let name = Data((names?[index] ?? "AuraFaceR100.mlpackage/\(relative)").utf8)
            let offset = local.count
            u32(0x04034b50, into: &local)
            for value in [20, 0x800, 0, 0, 23585] { u16(value, into: &local) }
            for value in [crc(bytes), UInt32(bytes.count), UInt32(bytes.count)] { u32(value, into: &local) }
            u16(name.count, into: &local); u16(0, into: &local)
            local.append(name); local.append(bytes)
            u32(0x02014b50, into: &central)
            for value in [788, 20, 0x800, 0, 0, 23585] { u16(value, into: &central) }
            for value in [crc(bytes), UInt32(bytes.count), UInt32(bytes.count)] { u32(value, into: &central) }
            for value in [name.count, 0, 0, 0, 0] { u16(value, into: &central) }
            u32(0o100644 << 16, into: &central); u32(UInt32(offset), into: &central)
            central.append(name)
        }
        let centralOffset = local.count
        local.append(central); u32(0x06054b50, into: &local)
        for value in [0, 0, 3, 3] { u16(value, into: &local) }
        u32(UInt32(central.count), into: &local); u32(UInt32(centralOffset), into: &local); u16(0, into: &local)
        return local
    }

    private func descriptor(_ bytes: Data) -> AuraFaceDistributionDescriptor {
        AuraFaceDistributionDescriptor(schemaVersion: 2, componentID: AuraFaceComponentStore.componentID,
            modelVersion: "AuraFace-v1/glintr100", embeddingVersion: FaceRecognitionDefaults.embeddingVersion,
            packageDirectory: AuraFaceComponentStore.packageDirectory,
            packageFiles: files.mapValues { .init(byteCount: Int64($0.count), sha256: Data(SHA256.hash(data: $0)).lowercaseHexString) },
            archive: .init(fileName: "AuraFaceR100.mlpackage.zip", byteCount: Int64(bytes.count),
                           sha256: Data(SHA256.hash(data: bytes)).lowercaseHexString),
            downloadURL: URL(string: "https://aagedal.me/models/auraface/AuraFaceR100.mlpackage.zip")!)
    }

    @Test("Live extraction and installer accept the exact three-file ZIP32 fixture")
    func install() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = archive(); let value = descriptor(bytes)
        let key = Curve25519.Signing.PrivateKey()
        let manifest = try value.canonicalData()
        var io = AuraFaceComponentIO.live
        io.compileModel = { _, target in try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        let installer = try AuraFaceComponentInstaller(io: io, publicKeyData: key.publicKey.rawRepresentation, root: directory)
        let result = try await installer.install(descriptorData: manifest,
            signatureData: key.signature(for: manifest).base64EncodedData(), archiveData: bytes)
        #expect(result == value)
        for (path, expected) in files {
            #expect(try Data(contentsOf: directory.appendingPathComponent("current/AuraFaceR100.mlpackage/\(path)")) == expected)
        }
    }

    @Test("Malformed ZIP32 headers refuse admission before extraction", arguments: [
        "local-flags", "local-extra", "central-flags", "method", "directory", "symlink", "overlap", "comment", "size"
    ])
    func headers(kind: String) throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        var bytes = archive()
        let central = try #require(bytes.range(of: Data([0x50, 0x4b, 1, 2]))?.lowerBound)
        switch kind {
        case "local-flags": bytes[6] = 8
        case "local-extra": bytes[28] = 20
        case "central-flags": bytes[central + 8] = 8
        case "method": bytes[central + 10] = 8
        case "directory": bytes[central + 38] = 16
        case "symlink": bytes[central + 41] = 0xa1
        case "overlap": bytes[central + 42] = 1
        case "comment": bytes[bytes.count - 2] = 1
        default: bytes[central + 23] = 0xff; bytes[central + 27] = 0xff
        }
        let source = directory.appendingPathComponent("fixture.zip")
        try bytes.write(to: source)
        #expect(throws: (any Error).self) { try AuraFaceZIPArchive(url: source, descriptor: descriptor(bytes)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["fixture.zip"])
    }

    @Test("Exact entry names reject traversal, duplicates and extra paths", arguments: ["traversal", "duplicate", "unexpected"])
    func names(kind: String) throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        var names = files.keys.sorted().map { "AuraFaceR100.mlpackage/\($0)" }
        if kind == "traversal" { names[0] = "AuraFaceR100.mlpackage/../../escape" }
        else if kind == "duplicate" { names[0] = names[1] }
        else { names[0] = "AuraFaceR100.mlpackage/unknown" }
        let bytes = archive(names: names)
        let source = directory.appendingPathComponent("fixture.zip"); try bytes.write(to: source)
        #expect(throws: (any Error).self) { try AuraFaceZIPArchive(url: source) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape").path))
    }

    @Test("CRC failure in a signed archive leaves the installed component untouched")
    func crcFailure() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        try Data("prior".utf8).write(to: current.appendingPathComponent("marker"))
        var bytes = archive()
        let nameSize = Int(bytes[26]) | Int(bytes[27]) << 8
        bytes[30 + nameSize] ^= 1
        let key = Curve25519.Signing.PrivateKey(); let manifest = try descriptor(bytes).canonicalData()
        var io = AuraFaceComponentIO.live
        io.compileModel = { _, _ in Issue.record("Corrupt archive reached compilation") }
        let installer = try AuraFaceComponentInstaller(io: io, publicKeyData: key.publicKey.rawRepresentation, root: directory)
        await #expect(throws: AuraFaceComponentError.invalidArchive) {
            try await installer.install(descriptorData: manifest,
                signatureData: key.signature(for: manifest).base64EncodedData(), archiveData: bytes)
        }
        #expect(try Data(contentsOf: current.appendingPathComponent("marker")) == Data("prior".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["current"])
    }

    @Test("A symlink extraction destination is never followed")
    func containment() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent("extracted")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        let source = directory.appendingPathComponent("fixture.zip"); try archive().write(to: source)
        let admitted = try AuraFaceZIPArchive(url: source)
        #expect(throws: AuraFaceComponentError.unsafeArchive) { try admitted.extract(to: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Transport caps declared and streamed bytes and refuses redirects without a second request", arguments: [
        "valid", "header-overflow", "body-overflow", "redirect", "foreign-response"
    ])
    func transport(scenario: String) async throws {
        AuraFaceSecurityHTTPStub.scenario = scenario
        AuraFaceSecurityHTTPStub.requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuraFaceSecurityHTTPStub.self]
        let url = AuraFaceComponentStore.signatureURL
        if scenario == "valid" {
            let result = try await AuraFaceBoundedHTTP.fetch(url, configuration: configuration)
            #expect(result.statusCode == 200 && result.data == Data([1, 2, 3]))
        } else {
            await #expect(throws: (any Error).self) {
                try await AuraFaceBoundedHTTP.fetch(url, configuration: configuration)
            }
        }
        #expect(AuraFaceSecurityHTTPStub.requests == 1)
    }

    @Test("Pre-cancelled downloads and untrusted origins never start transport")
    func rejectedTransport() async throws {
        AuraFaceSecurityHTTPStub.scenario = "valid"
        AuraFaceSecurityHTTPStub.requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuraFaceSecurityHTTPStub.self]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AuraFaceBoundedHTTP.fetch(AuraFaceComponentStore.signatureURL, configuration: configuration)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(throws: AuraFaceComponentError.invalidServerResponse) {
            try AuraFaceBoundedHTTP.limit(for: URL(string: "https://example.com/AuraFaceR100.mlpackage.zip")!)
        }
        #expect(AuraFaceSecurityHTTPStub.requests == 0)
    }
}

/// Serialized suite owns configuration; callbacks copy it once under a lock.
nonisolated private final class AuraFaceSecurityHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = "valid"
    nonisolated(unsafe) private static var count = 0
    static var scenario: String {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
    static var requests: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.lock.withLock { Self.count += 1; return Self.state }
        let url = request.url!
        if mode == "redirect" {
            let target = URL(string: "https://example.com/redirected")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let responseURL = mode == "foreign-response" ? URL(string: "https://example.com/other")! : url
        let headers = mode == "header-overflow" ? ["Content-Length": "90"] : [:]
        let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mode == "body-overflow" ? Data(repeating: 0, count: 90) : Data([1, 2, 3]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
