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

    @Test("embedded boundary keeps commas inside keywords, people and organisations")
    func embeddedListItemsWithCommasSurvive() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        var record = IPTCMetadata()
        record.keywords = ["Støre, Jonas Gahr", "politikk"]
        record.personShown = ["Støre, Jonas Gahr"]
        record.organisationsShownNames = ["Arbeiderpartiet, Oslo"]

        for semantics in [DescriptiveMetadataWriteSemantics.merge, .replace] {
            _ = try await boundary.write(metadata: record, for: source,
                                         requestedMode: .writeToFile, semantics: semantics)
            let read = try await SwiftExifReadService().readFullMetadata(url: source)
            #expect(read.keywords == record.keywords)
            #expect(read.personShown == record.personShown)
            #expect(read.organisationsShownNames == record.organisationsShownNames)
        }
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

    @Test("Existing-only descriptive writes skip absent sidecars while explicit writes create them")
    func existingOnlySidecarPolicy() async throws {
        let (directory, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        let skipped = try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(title: "Caption"), for: source, onlyIfExisting: true
        )
        #expect(!skipped)
        #expect(!service.sidecarExists(for: source))
        let created = try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(title: "Caption"), for: source
        )
        #expect(created)
        #expect(service.loadSidecar(for: source)?.title == "Caption")
    }

    @Test("Existing-only descriptive writes preserve Develop settings off MainActor")
    @MainActor
    func existingOnlyPreservesDevelop() async throws {
        let (directory, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        var baseline = IPTCMetadata(title: "Before")
        var develop = CameraRawSettings()
        develop.exposure2012 = 1.25
        baseline.cameraRaw = develop
        try service.saveSidecar(metadata: baseline, for: source)
        let installed = try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(title: "After"), for: source, onlyIfExisting: true,
            beforeRevisionCheck: { _ in #expect(!Thread.isMainThread) }
        )
        #expect(installed)
        let result = try #require(service.loadSidecar(for: source))
        #expect(result.title == "After")
        #expect(result.cameraRaw?.exposure2012 == 1.25)
    }

    @Test("Existing-only retries do not recreate an externally deleted sidecar")
    func existingOnlyExternalDeletion() async throws {
        let (directory, source) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(title: "Before"), for: source)
        let installed = try await service.saveSidecarPreservingDevelopSettingsSerialized(
            metadata: IPTCMetadata(title: "After"), for: source, onlyIfExisting: true,
            beforeRevisionCheck: { attempt in
                guard attempt == 0 else { return }
                try? FileManager.default.removeItem(at: service.sidecarURL(for: source))
            }
        )
        #expect(!installed)
        #expect(!service.sidecarExists(for: source))
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

    @Test("Paste IPTC writes RAW to its XMP sidecar, keeps Develop settings and never touches RAW bytes")
    func pasteIntoRawUsesSidecar() async throws {
        let (directory, source) = try makeWorkspace(extension: "arw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBefore = try Data(contentsOf: source)
        var existing = IPTCMetadata(title: "Keep headline")
        existing.cameraRaw = CameraRawSettings(exposure2012: 0.5)
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: existing, for: source)

        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let summary = await boundary.pasteMerging(
            IPTCMetadata(description: "Pasted caption", keywords: ["pasted"]),
            into: [(url: source, mode: .writeToFile)]
        )

        #expect(summary.written == [source])
        #expect(summary.problemMessage == nil)
        #expect(try Data(contentsOf: source) == sourceBefore)
        let written = try #require(service.loadSidecar(for: source))
        #expect(written.title == "Keep headline")
        #expect(written.description == "Pasted caption")
        #expect(written.keywords == ["pasted"])
        #expect(written.cameraRaw?.exposure2012 == 0.5)
    }

    @Test("Paste IPTC embeds into JPEG and refreshes an existing sidecar so it cannot shadow the file")
    func pasteIntoJPEGMirrorsExistingSidecar() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(description: "Stale caption"), for: source)

        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let summary = await boundary.pasteMerging(
            IPTCMetadata(description: "Pasted caption"),
            into: [(url: source, mode: .writeToFile)]
        )

        #expect(summary.written == [source])
        #expect(try await SwiftExifReadService().readFullMetadata(url: source).description == "Pasted caption")
        #expect(try #require(service.loadSidecar(for: source)).description == "Pasted caption")
    }

    @Test("Paste IPTC leaves history-only photos untouched and reports them")
    func pasteSkipsHistoryOnly() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: source)

        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
        let summary = await boundary.pasteMerging(
            IPTCMetadata(description: "Pasted caption"),
            into: [(url: source, mode: .historyOnly)]
        )

        #expect(summary.written.isEmpty)
        #expect(summary.historyOnlySkipped == [source])
        #expect(summary.problemMessage?.contains("Save History Only") == true)
        #expect(try Data(contentsOf: source) == before)
        #expect(!XMPSidecarService().sidecarExists(for: source))
    }

    @Test("Develop paste onto RAW lands in the sidecar, keeps captions and the unpasted crop")
    func developPasteIntoRawSidecar() async throws {
        let (directory, source) = try makeWorkspace(extension: "arw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBefore = try Data(contentsOf: source)
        let targetCrop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 0, hasCrop: true)
        var existing = IPTCMetadata(title: "Keep headline")
        existing.cameraRaw = CameraRawSettings(exposure2012: 0.5)
        existing.cameraRaw?.crop = targetCrop
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: existing, for: source)

        var pasted = CameraRawSettings(exposure2012: 1.25)
        pasted.contrast2012 = 20
        try await service.pasteCameraRawSerialized(pasted, includeCrop: false, for: source)

        #expect(try Data(contentsOf: source) == sourceBefore)
        let written = try #require(service.loadSidecar(for: source))
        #expect(written.title == "Keep headline")
        #expect(written.cameraRaw?.exposure2012 == 1.25)
        #expect(written.cameraRaw?.contrast2012 == 20)
        #expect(written.cameraRaw?.crop?.left == targetCrop.left)
    }

    @Test("Develop paste creates a sidecar for a RAW that has none")
    func developPasteCreatesRawSidecar() async throws {
        let (directory, source) = try makeWorkspace(extension: "arw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()

        try await service.pasteCameraRawSerialized(
            CameraRawSettings(exposure2012: -0.7), includeCrop: true, for: source
        )

        #expect(try #require(service.loadSidecar(for: source)).cameraRaw?.exposure2012 == -0.7)
    }

    @Test("Develop paste keeps target masks and crop the source doesn't carry")
    func developPasteMergeKeepsTargetCollections() {
        var target = CameraRawSettings(exposure2012: 0.3)
        target.crop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 0, hasCrop: true)
        target.toneCurve = ToneCurve()
        let merged = CameraRawSettings.pasted(
            CameraRawSettings(exposure2012: 1.0), onto: target, includeCrop: true
        )
        #expect(merged.exposure2012 == 1.0)
        #expect(merged.crop == target.crop)
        #expect(merged.toneCurve == target.toneCurve)
        #expect(merged.hasSettings == true)
    }

    @Test("Embedded Develop paste appends to the file's own masks and is idempotent")
    func embeddedDevelopPasteAppendsMasks() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SwiftExifWriteEngine()

        var ownBlur = MaskAdjustment(name: "Face B", anonymizer: AnonymizerSettings(amount: 90, blackOut: nil))
        ownBlur.geometry.centerX = 0.7
        _ = try await engine.writeDevelopFields(
            [.crsExposure2012: "+0.30"], to: [source],
            structuredData: StructuredWriteData(masks: [ownBlur]), allowsCredentialedEmbed: false
        )

        var pastedBlur = MaskAdjustment(name: "Face A", anonymizer: AnonymizerSettings(amount: 60, blackOut: nil))
        pastedBlur.geometry.centerX = 0.2
        for _ in 0..<2 {
            let report = try await engine.writeDevelopFields(
                [:], to: [source],
                structuredData: StructuredWriteData(masks: [pastedBlur], mergesLayersForPaste: true),
                allowsCredentialedEmbed: false
            )
            #expect(report.isEmpty)
        }

        let masks = try #require(try await SwiftExifReadService().readFullMetadata(url: source).cameraRaw?.localAdjustments)
        #expect(masks.count == 2)
        #expect(masks.contains { $0.anonymizer?.amount == 90 && abs($0.geometry.centerX - 0.7) < 1e-4 })
        #expect(masks.contains { $0.anonymizer?.amount == 60 && abs($0.geometry.centerX - 0.2) < 1e-4 })
    }

    @Test("Embedded Develop paste replaces ordinary masks, keeps the file's redactions and Anonymizer")
    func embeddedDevelopPasteReplacesOrdinaryMasks() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SwiftExifWriteEngine()

        var ownMask = MaskAdjustment(name: "Own", exposure: 0.5)
        ownMask.geometry.centerX = 0.3
        var ownBlur = MaskAdjustment(name: "Face", anonymizer: AnonymizerSettings(amount: 90, blackOut: nil))
        ownBlur.geometry.centerX = 0.7
        _ = try await engine.writeDevelopFields(
            [.crsExposure2012: "+0.30"], to: [source],
            structuredData: StructuredWriteData(masks: [ownMask, ownBlur],
                                                anonymizer: AnonymizerSettings(amount: 80, blackOut: nil)),
            allowsCredentialedEmbed: false
        )

        var sky = MaskAdjustment(name: "Sky", exposure: -1)
        sky.geometry.centerY = 0.2
        let report = try await engine.writeDevelopFields(
            [:], to: [source],
            structuredData: StructuredWriteData(masks: [sky],
                                                anonymizer: AnonymizerSettings(amount: 20, blackOut: nil),
                                                mergesLayersForPaste: true),
            allowsCredentialedEmbed: false
        )
        #expect(report.isEmpty)

        let settings = try #require(try await SwiftExifReadService().readFullMetadata(url: source).cameraRaw)
        let names = Set(settings.localAdjustments?.map(\.name) ?? [])
        #expect(names == ["Face", "Sky"])
        #expect(settings.anonymizer?.amount == 80)
    }

    @Test("Embedded Develop paste carries the source's ACR-only masks and matches the in-memory paste")
    func embeddedDevelopPasteCarriesACROnlyMasks() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SwiftExifWriteEngine()

        var ownMask = MaskAdjustment(name: "Own", exposure: 0.5)
        ownMask.geometry.centerX = 0.3
        _ = try await engine.writeDevelopFields(
            [.crsExposure2012: "+0.30"], to: [source],
            structuredData: StructuredWriteData(masks: [ownMask]), allowsCredentialedEmbed: false
        )
        let before = try #require(try await SwiftExifReadService().readFullMetadata(url: source).cameraRaw)

        let crs = XMPNamespace.crs
        let lightroomOnly = try #require(parseMaskGroupBasedCorrections([[
            "\(crs)CorrectionActive": "true",
            "\(crs)CorrectionName": "Lightroom erase brush",
            "\(crs)LocalExposure2012": "0.2",
            "\(crs)CorrectionMasks": [[
                "\(crs)What": "Mask/Aggregate",
                "\(crs)MaskName": "Brush 1",
                "\(crs)MaskValue": "1",
                "\(crs)MaskBrushTable": "9F8737DEECAFF5C8FE6BB4B9D438EAF2",
                "\(crs)MaskBrushUncompressedBytes": "13258",
            ]],
        ]])?.preserved.first)
        var copied = CameraRawSettings(exposure2012: 0.6)
        copied.unparsedMaskCorrections = [lightroomOnly]

        let report = try await engine.writeDevelopFields(
            copied.developWriteFields(), to: [source],
            structuredData: .developPaste(copied), allowsCredentialedEmbed: false
        )
        #expect(report.isEmpty)

        let expected = CameraRawSettings.pasted(copied, onto: before, includeCrop: false)
        let written = try #require(try await SwiftExifReadService().readFullMetadata(url: source).cameraRaw)
        #expect(written.unparsedMaskCorrections?.count == 1)
        #expect(written.unparsedMaskCorrections == expected.unparsedMaskCorrections)
        #expect(written.localAdjustments == expected.localAdjustments)
        #expect(written.exposure2012 == expected.exposure2012)
    }

    @Test("Sidecar paste onto a JPEG keeps its embedded redaction instead of hiding it")
    func sidecarPasteCarriesEmbeddedRedaction() async throws {
        let (directory, source) = try makeJPEGWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var faceBlur = MaskAdjustment(name: "Face", anonymizer: AnonymizerSettings(amount: 90, blackOut: nil))
        faceBlur.geometry.centerX = 0.6
        _ = try await SwiftExifWriteEngine().writeDevelopFields(
            [.crsExposure2012: "+0.10"], to: [source],
            structuredData: StructuredWriteData(masks: [faceBlur],
                                                anonymizer: AnonymizerSettings(amount: 75, blackOut: nil)),
            allowsCredentialedEmbed: false
        )
        // A descriptive-only sidecar: the photo displays its embedded develop.
        let service = XMPSidecarService()
        try service.saveSidecar(metadata: IPTCMetadata(title: "Caption only"), for: source)
        #expect(service.loadSidecar(for: source)?.cameraRaw?.isEmpty ?? true)

        var sky = MaskAdjustment(name: "Sky", exposure: -0.7)
        sky.geometry.centerY = 0.2
        var copied = CameraRawSettings(exposure2012: 0.9)
        copied.localAdjustments = [sky]
        try await service.pasteCameraRawSerialized(copied, includeCrop: false, for: source)

        let settings = try #require(service.loadSidecar(for: source)?.cameraRaw)
        #expect(settings.exposure2012 == 0.9)
        #expect(Set(settings.localAdjustments?.map(\.name) ?? []) == ["Face", "Sky"])
        #expect(settings.anonymizer?.amount == 75)
        #expect(service.loadSidecar(for: source)?.title == "Caption only")
    }

    @Test("Sidecar Develop paste appends to the RAW's own masks and is idempotent")
    func sidecarDevelopPasteAppendsMasks() async throws {
        let (directory, source) = try makeWorkspace(extension: "arw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = XMPSidecarService()

        var ownBlur = MaskAdjustment(name: "Face B", anonymizer: AnonymizerSettings(amount: 90, blackOut: nil))
        ownBlur.geometry.centerX = 0.7
        var own = CameraRawSettings(exposure2012: 0.3)
        own.localAdjustments = [ownBlur]
        try await service.pasteCameraRawSerialized(own, includeCrop: false, for: source)

        var pastedBlur = MaskAdjustment(name: "Face A", anonymizer: AnonymizerSettings(amount: 60, blackOut: nil))
        pastedBlur.geometry.centerX = 0.2
        var copied = CameraRawSettings(exposure2012: 1.0)
        copied.localAdjustments = [pastedBlur]
        try await service.pasteCameraRawSerialized(copied, includeCrop: false, for: source)
        try await service.pasteCameraRawSerialized(copied, includeCrop: false, for: source)

        let settings = try #require(service.loadSidecar(for: source)?.cameraRaw)
        #expect(settings.exposure2012 == 1.0)
        let masks = try #require(settings.localAdjustments)
        #expect(masks.count == 2)
        #expect(masks.contains { $0.anonymizer?.amount == 90 })
        #expect(masks.contains { $0.anonymizer?.amount == 60 })
    }

    @Test("Direct SwiftExif writes refuse RAW loudly instead of silently succeeding")
    func swiftExifRefusesRawEmbed() async throws {
        let (directory, source) = try makeWorkspace(extension: "arw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: source)

        await #expect(throws: RawEmbeddedWriteRefusedError(urls: [source])) {
            try await SwiftExifWriteEngine().writeFields([.headline: "x"], to: [source], structuredData: .empty)
        }
        #expect(try Data(contentsOf: source) == before)
    }
}
