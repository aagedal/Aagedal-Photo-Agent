import Foundation
import SwiftExif
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Proprietary RAW descriptive write boundary")
struct DescriptiveMetadataWriteBoundaryTests {
    private let resolver = DescriptiveMetadataWriteTargetResolver()

    private func makeWorkspace(extension fileExtension: String = "nef") throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawWriteBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("capture.\(fileExtension)")
        try Data([0x52, 0x41, 0x57, 0x00, 0xCA, 0xFE, 0xBA, 0xBE]).write(to: source)
        return (directory, source)
    }

    @Test("Every supported proprietary RAW extension coerces embedded requests to one XMP target")
    func rawTargetSelection() {
        for fileExtension in SupportedImageFormats.rawExtensions {
            let source = URL(fileURLWithPath: "/tmp/capture.\(fileExtension)")
            #expect(resolver.resolve(sourceURL: source, requestedMode: .writeToFile) == .xmpSidecar)
            #expect(resolver.resolve(sourceURL: source, requestedMode: .writeToFileAndXMPSidecar) == .xmpSidecar)
            #expect(resolver.resolve(sourceURL: source, requestedMode: .writeToXMPSidecar) == .xmpSidecar)
            #expect(resolver.resolve(sourceURL: source, requestedMode: .historyOnly) == .historyOnly)
        }

        let jpeg = URL(fileURLWithPath: "/tmp/capture.jpg")
        #expect(resolver.resolve(sourceURL: jpeg, requestedMode: .writeToFile) == .embedded)
        #expect(resolver.resolve(sourceURL: jpeg, requestedMode: .writeToFileAndXMPSidecar) == .embeddedAndXMPSidecar)
    }

    @Test("RAW replacement clears omitted descriptive fields, preserves unmodeled and Camera Raw XMP, and never changes source bytes")
    func replacePreservesSourceAndUnmodeledXMP() async throws {
        let (directory, source) = try makeWorkspace(extension: "arw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBefore = try Data(contentsOf: source)
        let sidecarService = XMPSidecarService()
        let sidecar = sidecarService.sidecarURL(for: source)
        let existing = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
           photoshop:Headline="Old headline"
           crs:Exposure2012="+0.75" crs:Texture="+22" crs:HasSettings="True">
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Old caption</rdf:li></rdf:Alt></dc:description>
           <dc:subject><rdf:Bag><rdf:li>old-keyword</rdf:li></rdf:Bag></dc:subject>
           <lr:hierarchicalSubject><rdf:Bag><rdf:li>News|Assignment</rdf:li></rdf:Bag></lr:hierarchicalSubject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try #require(existing.data(using: .utf8)).write(to: sidecar)

        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let replacement = IPTCMetadata(title: "Replacement headline", description: nil, keywords: [])
        let result = try await boundary.write(
            metadata: replacement,
            for: source,
            requestedMode: .writeToFile,
            semantics: .replace
        )

        #expect(result.target == .xmpSidecar)
        #expect(result.xmpSidecarURL == sidecar)
        #expect(try Data(contentsOf: source) == sourceBefore)

        let rewritten = try XMPReader.readFromXML(Data(contentsOf: sidecar))
        #expect(rewritten.headline == "Replacement headline")
        #expect(rewritten.description == nil)
        #expect(rewritten.subject.isEmpty)
        #expect(rewritten.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/", property: "Exposure2012") == "+0.75")
        #expect(rewritten.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/", property: "Texture") == "+22")
        #expect(
            rewritten.arrayValue(
                namespace: "http://ns.adobe.com/lightroom/1.0/",
                property: "hierarchicalSubject"
            ) == ["News|Assignment"]
        )
    }

    @Test("RAW merge retains existing descriptive values while applying populated fields")
    func mergeRetainsExistingValues() async throws {
        let (directory, source) = try makeWorkspace(extension: "cr3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        try service.saveSidecar(
            metadata: IPTCMetadata(title: "Keep headline", description: "Old caption", keywords: ["keep"]),
            for: source
        )

        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        _ = try await boundary.write(
            metadata: IPTCMetadata(description: "New caption"),
            for: source,
            requestedMode: .writeToFileAndXMPSidecar,
            semantics: .merge
        )

        let written = try #require(service.loadSidecar(for: source))
        #expect(written.title == "Keep headline")
        #expect(written.description == "New caption")
        #expect(written.keywords == ["keep"])
        #expect(try Data(contentsOf: source) == Data([0x52, 0x41, 0x57, 0x00, 0xCA, 0xFE, 0xBA, 0xBE]))
    }

    @Test("A stale sidecar snapshot rejects a delayed RAW write")
    func staleWriteIsRejected() async throws {
        let (directory, source) = try makeWorkspace(extension: "raf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(title: "Baseline"), for: source)
        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let snapshot = boundary.xmpSnapshot(for: source)

        try service.saveSidecar(metadata: IPTCMetadata(title: "Newer external value"), for: source)
        let sidecar = service.sidecarURL(for: source)
        do {
            _ = try await boundary.write(
                metadata: IPTCMetadata(title: "Stale edit"),
                for: source,
                requestedMode: .writeToFile,
                semantics: .replace,
                expectedXMPSnapshot: snapshot
            )
            Issue.record("Expected the stale XMP precondition to fail")
        } catch let error as DescriptiveMetadataWriteError {
            #expect(error == .staleXMPSidecar(sidecar))
        }

        #expect(service.loadSidecar(for: source)?.title == "Newer external value")
    }

    @Test("Cancellation before the boundary does not create an XMP sidecar")
    func cancellationBeforeWrite() async throws {
        let (directory, source) = try makeWorkspace(extension: "dng")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let task = Task { () throws -> DescriptiveMetadataWriteResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await boundary.write(
                metadata: IPTCMetadata(title: "Must not land"),
                for: source,
                requestedMode: .writeToFile,
                semantics: .replace
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!service.sidecarExists(for: source))
    }
}
