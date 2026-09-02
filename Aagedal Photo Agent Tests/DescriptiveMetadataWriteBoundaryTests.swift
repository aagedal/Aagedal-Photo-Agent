import AppKit
import Foundation
import SwiftMediaMetadata
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

    private func makeJPEGWorkspace() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedWriteBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("capture.jpg")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: source)
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

    @Test("embedded boundary replaces and clears authoritative localized Titles")
    func embeddedLocalizedTitleWrite() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let expected = [
            LocalizedMetadataText(languageTag: "x-default", value: "Default title"),
            LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk tittel"),
        ]

        _ = try await boundary.write(
            metadata: IPTCMetadata(localizedTitles: expected),
            for: source,
            requestedMode: .writeToFile,
            semantics: .merge
        )
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).localizedTitles == expected)

        _ = try await boundary.write(
            metadata: IPTCMetadata(localizedTitles: []),
            for: source,
            requestedMode: .writeToFile,
            semantics: .replace
        )
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).localizedTitles == nil)
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

    @Test("An external replacement before install retries the merge from the new content token")
    func externalReplacementRetriesMerge() async throws {
        let (directory, source) = try makeWorkspace(extension: "raf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(title: "Baseline"), for: source)

        try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(description: "Caption edit"),
            for: source,
            mergeWithExisting: true,
            beforeRevisionCheck: { attempt in
                guard attempt == 0 else { return }
                try? service.saveSidecar(
                    metadata: IPTCMetadata(title: "External replacement"),
                    for: source
                )
            }
        )

        let installed = try #require(service.loadSidecar(for: source))
        #expect(installed.title == "External replacement")
        #expect(installed.description == "Caption edit")
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

    @Test("Overlapping caption, face, and Develop transactions retain unrelated fields")
    func overlappingSidecarTransactionsRetainFields() async throws {
        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let xmp = XMPSidecarService()

        // Repeat with fresh URLs so both possible enqueue orders are exercised by the runtime.
        for iteration in 0..<40 {
            let (directory, source) = try makeWorkspace(extension: "cr3")
            defer { try? FileManager.default.removeItem(at: directory) }

            var settings = CameraRawSettings()
            settings.hasSettings = true
            settings.exposure2012 = Double(iteration) / 10.0
            let expectedExposure = settings.exposure2012

            async let caption: DescriptiveMetadataWriteResult = boundary.write(
                metadata: IPTCMetadata(title: "Caption \(iteration)"),
                for: source,
                requestedMode: .writeToXMPSidecar,
                semantics: .merge
            )
            async let face: DescriptiveMetadataWriteResult = boundary.write(
                metadata: IPTCMetadata(personShown: ["Person \(iteration)"]),
                for: source,
                requestedMode: .writeToXMPSidecar,
                semantics: .merge
            )
            async let develop: Void = xmp.saveCameraRawOnlySerialized(
                settings,
                orientation: 1,
                for: source
            )
            _ = try await (caption, face, develop)

            let installed = try #require(xmp.loadSidecar(for: source))
            #expect(installed.title == "Caption \(iteration)")
            #expect(installed.personShown == ["Person \(iteration)"])
            #expect(installed.cameraRaw?.exposure2012 == expectedExposure)
        }
    }

    @Test("Overlapping JSON field histories merge in deterministic order")
    func overlappingJSONHistoryIsDeterministic() async throws {
        let (directory, source) = try makeWorkspace(extension: "nef")
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = MetadataSidecarService()
        let baseline = IPTCMetadata(title: "Before", personShown: [])
        try json.saveSidecar(
            MetadataSidecar(
                sourceFile: source.lastPathComponent,
                metadata: baseline,
                imageMetadataSnapshot: baseline
            ),
            for: source,
            in: directory
        )

        let captionTime = Date(timeIntervalSinceReferenceDate: 100)
        var captionMetadata = baseline
        captionMetadata.title = "After"
        let caption = MetadataSidecar(
            sourceFile: source.lastPathComponent,
            metadata: captionMetadata,
            imageMetadataSnapshot: baseline,
            history: [MetadataHistoryEntry(
                timestamp: captionTime,
                fieldID: .headline,
                oldValue: "Before",
                newValue: "After"
            )]
        )

        let faceTime = Date(timeIntervalSinceReferenceDate: 101)
        var faceMetadata = baseline
        faceMetadata.personShown = ["Ada"]
        let face = MetadataSidecar(
            sourceFile: source.lastPathComponent,
            metadata: faceMetadata,
            imageMetadataSnapshot: baseline,
            history: [MetadataHistoryEntry(
                timestamp: faceTime,
                fieldID: .personShown,
                oldValue: nil,
                newValue: MetadataFieldID.personShown.historyValue(in: faceMetadata)
            )]
        )

        async let captionWrite = json.saveSidecarMergingHistorySerialized(
            caption,
            for: source,
            in: directory
        )
        async let faceWrite = json.saveSidecarMergingHistorySerialized(
            face,
            for: source,
            in: directory
        )
        _ = try await (captionWrite, faceWrite)

        let installed = try #require(json.loadSidecar(for: source, in: directory))
        #expect(installed.metadata.title == "After")
        #expect(installed.metadata.personShown == ["Ada"])
        #expect(installed.history.map(\.fieldID) == [.headline, .personShown])
    }

    @Test("Variable-processing deltas update an existing JSON sidecar")
    func variableProcessingDeltasUpdateExistingJSONSidecar() async throws {
        let (directory, source) = try makeWorkspace(extension: "nef")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MetadataSidecarService()
        let baseline = IPTCMetadata(title: "{filename}", personShown: ["Ada"])
        try service.saveSidecar(
            MetadataSidecar(sourceFile: source.lastPathComponent, metadata: baseline),
            for: source,
            in: directory
        )

        var resolved = baseline
        resolved.title = "capture"
        let timestamp = Date(timeIntervalSinceReferenceDate: 200)
        var history = MetadataHistoryEntry.changes(
            from: baseline,
            to: resolved,
            timestamp: timestamp
        )
        history.append(MetadataHistoryEntry(
            timestamp: timestamp,
            fieldName: "Variables processed",
            oldValue: nil,
            newValue: "Saved to sidecar (history only)"
        ))

        _ = try await service.saveSidecarMergingHistorySerialized(
            MetadataSidecar(
                sourceFile: source.lastPathComponent,
                metadata: resolved,
                history: history
            ),
            for: source,
            in: directory
        )

        let installed = try #require(service.loadSidecar(for: source, in: directory))
        #expect(installed.metadata.title == "capture")
        #expect(installed.metadata.personShown == ["Ada"])
        #expect(installed.history.contains { $0.fieldName == "Variables processed" })
    }

    @Test("Non-replayable field deltas preserve concurrent unrelated metadata")
    func nonReplayableDeltasPreserveConcurrentUnrelatedMetadata() async throws {
        let (directory, source) = try makeWorkspace(extension: "nef")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MetadataSidecarService()
        let baseline = IPTCMetadata(
            description: "Before",
            creatorContactInfo: CreatorContactInfo(city: "Before")
        )
        try service.saveSidecar(
            MetadataSidecar(sourceFile: source.lastPathComponent, metadata: baseline),
            for: source,
            in: directory
        )

        var incomingMetadata = baseline
        incomingMetadata.description = String(repeating: "resolved-", count: 30)
        incomingMetadata.creatorContactInfo = CreatorContactInfo(city: "After")
        let history = MetadataHistoryEntry.changes(
            from: baseline,
            to: incomingMetadata,
            timestamp: Date(timeIntervalSinceReferenceDate: 300)
        )

        var concurrentMetadata = baseline
        concurrentMetadata.personShown = ["Grace"]
        try service.saveSidecar(
            MetadataSidecar(sourceFile: source.lastPathComponent, metadata: concurrentMetadata),
            for: source,
            in: directory
        )

        _ = try await service.saveSidecarMergingHistorySerialized(
            MetadataSidecar(
                sourceFile: source.lastPathComponent,
                metadata: incomingMetadata,
                history: history
            ),
            for: source,
            in: directory
        )

        let installed = try #require(service.loadSidecar(for: source, in: directory))
        #expect(installed.metadata.description == incomingMetadata.description)
        #expect(installed.metadata.creatorContactInfo == incomingMetadata.creatorContactInfo)
        #expect(installed.metadata.personShown == ["Grace"])
    }

    @Test("Intentional JSON replacement clears history inside the shared transaction")
    func serializedJSONReplacementClearsHistory() async throws {
        let (directory, source) = try makeWorkspace(extension: "nef")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MetadataSidecarService()
        let baseline = IPTCMetadata(title: "Before")
        try service.saveSidecar(
            MetadataSidecar(
                sourceFile: source.lastPathComponent,
                metadata: baseline,
                imageMetadataSnapshot: baseline,
                history: [MetadataHistoryEntry(
                    timestamp: Date(timeIntervalSinceReferenceDate: 100),
                    fieldID: .headline,
                    oldValue: nil,
                    newValue: "Before"
                )]
            ),
            for: source,
            in: directory
        )

        let replacement = MetadataSidecar(
            sourceFile: source.lastPathComponent,
            metadata: IPTCMetadata(title: "Reset"),
            imageMetadataSnapshot: baseline,
            history: []
        )
        let installed = try await service.saveSidecarReplacingHistorySerialized(
            replacement,
            for: source,
            in: directory
        )

        #expect(installed.metadata.title == "Before")
        #expect(installed.history.isEmpty)
        #expect(service.loadSidecar(for: source, in: directory)?.history.isEmpty == true)
    }

    @Test("Serialized IPTC strip preserves Develop settings")
    func serializedIPTCStripPreservesDevelop() async throws {
        let (directory, source) = try makeWorkspace(extension: "cr3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        var settings = CameraRawSettings()
        settings.hasSettings = true
        settings.exposure2012 = 1.25
        try service.saveSidecar(
            metadata: IPTCMetadata(
                title: "Remove me",
                description: "Also remove me",
                keywords: ["remove"],
                cameraRaw: settings
            ),
            for: source
        )

        try await service.stripIPTCFromSidecarSerialized(for: source)

        let installed = try #require(service.loadSidecar(for: source))
        #expect(installed.title == nil)
        #expect(installed.description == nil)
        #expect(installed.keywords.isEmpty)
        #expect(installed.cameraRaw?.exposure2012 == 1.25)
    }
}
