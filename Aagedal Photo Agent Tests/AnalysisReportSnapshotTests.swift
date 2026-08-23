import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Aagedal_Photo_Agent

@Suite("Analysis report snapshot")
struct AnalysisReportSnapshotTests {
    @Test("freezes an exact viewport as schematic evidence without map imagery")
    func freezesSchematicMapEvidence() async throws {
        let fixture = try AnalysisReportFixture(contents: "report source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "case-build")
        let viewport = AnalysisMapViewport(
            center: AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522),
            latitudeDelta: 0.05,
            longitudeDelta: 0.06
        )
        analysisCase.setMapStyle(.satellite)
        analysisCase.setMapViewport(viewport)
        analysisCase.setInvestigationLocation(AnalysisLocationEvidence(
            coordinate: AnalysisGeoCoordinate(latitude: 59.911, longitude: 10.75),
            source: .manualCoordinates,
            sourceDetail: "Investigator entry"
        ))
        let visible = AnalysisMapAnnotation(
            kind: .label,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.914, longitude: 10.753)),
            text: "Camera position"
        )
        let hidden = AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.915, longitude: 10.754)),
            isVisible: false
        )
        analysisCase.setMapAnnotation(visible)
        analysisCase.setMapAnnotation(hidden)
        let frozenAt = Date(timeIntervalSince1970: 1234)

        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            now: frozenAt
        )
        let map = try #require(snapshot.mapEvidence)

        #expect(map.rendering == .schematicWGS84)
        #expect(map.viewport == viewport)
        #expect(map.liveMapStyle == .satellite)
        #expect(map.visibleAnnotations.map(\.id) == [visible.id])
        #expect(map.coordinateSystem == "WGS 84 (EPSG:4326)")
        #expect(map.disclosure.contains("No Apple Maps tiles or imagery are embedded"))
        #expect(map.capturedAt == frozenAt)

        let components = try #require(URLComponents(
            url: map.liveMapReference,
            resolvingAgainstBaseURL: false
        ))
        #expect(components.scheme == "https")
        #expect(components.host == "maps.apple.com")
        #expect(components.queryItems?.first(where: { $0.name == "ll" })?.value
            == "59.91390000,10.75220000")
        #expect(components.queryItems?.first(where: { $0.name == "spn" })?.value
            == "0.05000000,0.06000000")
        #expect(components.queryItems?.first(where: { $0.name == "t" })?.value == "k")

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AnalysisReportSnapshot.self, from: encoded) == snapshot)
    }

    @Test("freezes and independently reproduces saved solar evidence")
    func freezesReproducibleSolarEvidence() async throws {
        let fixture = try AnalysisReportFixture(contents: "solar report source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let coordinate = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        let location = AnalysisLocationEvidence(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            coordinate: coordinate,
            source: .manualCoordinates,
            sourceDetail: "Surveyed photo location",
            placeName: "Oslo",
            placeNameSource: .placeSearch,
            now: Date(timeIntervalSince1970: 10)
        )
        let timestamp = AnalysisTimestampValue(
            year: 2026,
            month: 6,
            day: 21,
            hour: 12,
            minute: 30,
            precision: .minute,
            utcOffsetMinutes: 120
        )
        let timelineEvidence = AnalysisTimestampEvidence(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            kind: .capture,
            title: "Qualified capture time",
            value: timestamp,
            source: .userEntered,
            sourceDetail: "Confirmed timeline entry",
            now: Date(timeIntervalSince1970: 11)
        )
        let overlay = AnalysisSolarOverlayState(
            timestamp: timestamp,
            linkedTimestampEvidenceID: timelineEvidence.id,
            showsSunsetDirection: false
        )
        analysisCase.setMapViewport(AnalysisMapViewport(
            center: coordinate,
            latitudeDelta: 0.05,
            longitudeDelta: 0.06
        ))
        analysisCase.setInvestigationLocation(location, now: Date(timeIntervalSince1970: 12))
        analysisCase.setTimestampEvidence(timelineEvidence, now: Date(timeIntervalSince1970: 13))
        analysisCase.setSolarOverlay(overlay, now: Date(timeIntervalSince1970: 14))

        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "3.0",
            appBuild: "test",
            now: Date(timeIntervalSince1970: 20)
        )
        let solar = try #require(snapshot.mapEvidence?.solarEvidence)
        let fresh = try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(
                instant: try #require(timestamp.resolvedInstant),
                coordinate: coordinate
            ),
            civilDayOffsetMinutes: 120
        )

        #expect(snapshot.schemaVersion == 4)
        #expect(solar.coordinate == coordinate)
        #expect(solar.locationEvidenceID == location.id)
        #expect(solar.locationSourceDetail == "Surveyed photo location")
        #expect(solar.overlay == overlay)
        #expect(solar.linkedTimestampEvidence == analysisCase.timestampEvidence.first)
        #expect(solar.linkedTimestampEvidenceIsAvailable)
        #expect(solar.day == fresh)

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AnalysisReportSnapshot.self, from: encoded) == snapshot)

        let removedTimelineEvidence = analysisCase.removeTimestampEvidence(
            id: timelineEvidence.id,
            now: Date(timeIntervalSince1970: 21)
        )
        #expect(removedTimelineEvidence)
        let withoutLinkedRow = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "3.0",
            appBuild: "test",
            now: Date(timeIntervalSince1970: 22)
        )
        let unlinkedSolar = try #require(withoutLinkedRow.mapEvidence?.solarEvidence)
        #expect(unlinkedSolar.overlay.timestamp == timestamp)
        #expect(unlinkedSolar.overlay.linkedTimestampEvidenceID == timelineEvidence.id)
        #expect(unlinkedSolar.linkedTimestampEvidence == nil)
        #expect(!unlinkedSolar.linkedTimestampEvidenceIsAvailable)
        #expect(unlinkedSolar.day == fresh)
    }

    @Test("rejects a solar report input outside the supported method range")
    func rejectsUnreproducibleSolarEvidence() async throws {
        let fixture = try AnalysisReportFixture(contents: "unsupported solar report source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let coordinate = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        analysisCase.setMapViewport(AnalysisMapViewport(
            center: coordinate,
            latitudeDelta: 0.05,
            longitudeDelta: 0.06
        ))
        analysisCase.setInvestigationLocation(AnalysisLocationEvidence(
            coordinate: coordinate,
            source: .manualCoordinates,
            sourceDetail: "Investigator entry"
        ))
        analysisCase.setSolarOverlay(AnalysisSolarOverlayState(
            timestamp: AnalysisTimestampValue(
                year: 2201,
                month: 6,
                day: 21,
                hour: 12,
                minute: 0,
                precision: .minute,
                utcOffsetMinutes: 0
            )
        ))

        do {
            _ = try await AnalysisReportSnapshot.capture(
                from: analysisCase,
                sourceURL: fixture.fileURL,
                appVersion: "3.0",
                appBuild: "test"
            )
            Issue.record("Expected an unreproducible solar calculation to block report capture")
        } catch let error as AnalysisReportSnapshotError {
            guard case .solarCalculationFailed(let detail) = error else {
                Issue.record("Unexpected snapshot error: \(error)")
                return
            }
            #expect(detail.contains("outside the supported 1800–2100"))
        }
    }

    @Test("renders solar rays, calculation values, method, and limitations")
    func rendersSolarReportEvidence() async throws {
        let fixture = try AnalysisReportFixture(contents: "solar PDF source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let coordinate = AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522)
        let timestamp = AnalysisTimestampValue(
            year: 2026,
            month: 6,
            day: 21,
            hour: 12,
            minute: 30,
            precision: .minute,
            utcOffsetMinutes: 120
        )
        analysisCase.setMapViewport(AnalysisMapViewport(
            center: coordinate,
            latitudeDelta: 0.05,
            longitudeDelta: 0.06
        ))
        analysisCase.setInvestigationLocation(AnalysisLocationEvidence(
            coordinate: coordinate,
            source: .manualCoordinates,
            sourceDetail: "Investigator entry",
            placeName: "Oslo",
            placeNameSource: .placeSearch
        ))
        analysisCase.setSolarOverlay(AnalysisSolarOverlayState(timestamp: timestamp))
        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "3.0",
            appBuild: "test"
        )

        let data = try await AnalysisPDFReportRenderer.makePDF(snapshot: snapshot)
        let document = try #require(PDFDocument(data: data))
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        #expect(text.contains("Solar position calculation"))
        #expect(text.contains("2026-06-21 12:30 UTC+02:00"))
        #expect(text.contains("Meeus/NOAA v1"))
        #expect(text.contains("Sun direction"))
        #expect(text.contains("Expected shadow direction"))
        #expect(text.contains("Shadow reference height"))
        #expect(text.contains("Expected shadow length"))
        #expect(text.contains("Sunrise direction"))
        #expect(text.contains("Sunset direction"))
        #expect(text.contains("Direction-ray length is derived"))
        #expect(text.contains("flat, unobstructed horizon"))
        #expect(text.contains("terrain, buildings, vegetation"))
        #expect(text.contains("source clock"))
        #expect(text.contains("camera orientation"))

        try writeQAReportIfRequested(data, filename: "analysis-report-solar.pdf")
    }

    @Test("rejects a source whose bytes changed after the case was created")
    func rejectsChangedSource() async throws {
        let fixture = try AnalysisReportFixture(contents: "original")
        defer { fixture.remove() }
        let original = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: original, appBuild: "test")

        try Data("changed bytes".utf8).write(to: fixture.fileURL)
        await #expect(throws: AnalysisReportSnapshotError.sourceRevisionChanged) {
            try await AnalysisReportSnapshot.capture(
                from: analysisCase,
                sourceURL: fixture.fileURL,
                appVersion: "2.3",
                appBuild: "test"
            )
        }
    }

    @Test("filters excluded findings and remains unchanged after later case edits")
    func freezesDeterministicReportInputs() async throws {
        let fixture = try AnalysisReportFixture(contents: "immutable")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let includedB = finding(id: "b", category: .source, includeInReport: true)
        let excluded = finding(id: "excluded", category: .metadata, includeInReport: false)
        let includedA = finding(id: "a", category: .metadata, includeInReport: true)
        analysisCase.setAnalyzerRun(AnalysisAnalyzerRun(
            analyzerID: "z-analyzer",
            analyzerVersion: 1,
            cacheKey: "z-cache",
            sourceRepresentation: .originalBytes,
            status: .completed,
            progress: 1,
            startedAt: nil,
            completedAt: Date(timeIntervalSince1970: 20),
            errorMessage: nil,
            output: AnalysisAnalyzerOutput(findings: [includedB, excluded, includedA])
        ))
        let observation = AnalysisObservation(
            title: "Weather",
            note: "Overcast, with no reliable timestamp."
        )
        analysisCase.setObservation(observation)

        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test",
            now: Date(timeIntervalSince1970: 30)
        )
        analysisCase.title = "Edited after export began"
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .label,
            geometry: .anchor(AnalysisNormalizedPoint(x: 0.5, y: 0.5)),
            text: "Later annotation"
        ))
        analysisCase.removeObservation(id: observation.id)

        #expect(snapshot.caseTitle != analysisCase.title)
        #expect(snapshot.photoAnnotations.isEmpty)
        #expect(snapshot.observations.map(\.id) == [observation.id])
        #expect(snapshot.observations.first?.note == observation.note)
        #expect(snapshot.includedFindings.map(\.id) == ["a", "b"])
        #expect(snapshot.analyzerRuns.count == 1)
        #expect(snapshot.analyzerRuns[0].analyzerID == "z-analyzer")
    }

    @Test("omits a map figure when no exact viewport has been captured")
    func omitsMapWithoutViewport() async throws {
        let fixture = try AnalysisReportFixture(contents: "no viewport")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")

        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test"
        )

        #expect(snapshot.mapEvidence == nil)
    }

    @Test("freezes outward-rounded true-pixel bounds through EXIF orientation")
    func freezesTruePixelCropBounds() async throws {
        let fixture = try AnalysisReportFixture(contents: "crop coordinate source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 120,
            pixelHeight: 80,
            exifOrientation: 6
        )
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")

        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test",
            originalDisplayEvidenceCrop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        let crop = try #require(snapshot.evidenceCrop)

        #expect(crop.displayedSourceWidth == 80)
        #expect(crop.displayedSourceHeight == 120)
        #expect(crop.displayPixelRect == AnalysisReportPixelRect(x: 20, y: 30, width: 40, height: 60))
        #expect(crop.sourcePixelRect == AnalysisReportPixelRect(x: 30, y: 20, width: 60, height: 40))
        #expect(crop.scaleLabel == "1:1 source-pixel extraction")
        #expect(crop.interpolationLabel == "No interpolation")

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AnalysisReportSnapshot.self, from: encoded) == snapshot)
    }

    @Test("embeds and captions a selected true-pixel crop")
    func rendersTruePixelCrop() async throws {
        let fixture = try AnalysisReportFixture(pixelWidth: 80, pixelHeight: 60)
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(
            at: fixture.fileURL,
            pixelWidth: 80,
            pixelHeight: 60,
            exifOrientation: 1
        )
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test",
            originalDisplayEvidenceCrop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )

        let data = try await AnalysisPDFReportRenderer.makePDF(snapshot: snapshot)
        let document = try #require(PDFDocument(data: data))
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        #expect(text.contains("Pixel evidence"))
        #expect(text.contains("Full-image analytical scopes"))
        #expect(text.contains("Waveform"))
        #expect(text.contains("RGBY Parade"))
        #expect(text.contains("Vectorscope"))
        #expect(text.contains("Chromaticity"))
        #expect(text.contains("direct Image"))
        #expect(text.contains("selected-region scopes are intentionally excluded"))
        #expect(text.contains("true-pixel crop"))
        #expect(text.contains("1:1 source-pixel extraction"))
        #expect(text.contains("No interpolation"))
        #expect(text.contains("40 × 30 px"))
        #expect(!text.contains("Evidence crop unavailable"))

        try writeQAReportIfRequested(data, filename: "analysis-report-evidence-crop.pdf")
    }

    @Test("renders a structured A4 PDF from only the immutable snapshot")
    func rendersStructuredA4PDF() async throws {
        let fixture = try AnalysisReportFixture(contents: "rendered report source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.title = "Example Evidence Case"
        analysisCase.setAnalyzerRun(AnalysisAnalyzerRun(
            analyzerID: "report-test",
            analyzerVersion: 3,
            cacheKey: "sha256:test|report-test|v3",
            sourceRepresentation: .originalBytes,
            status: .completed,
            progress: 1,
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            errorMessage: nil,
            output: AnalysisAnalyzerOutput(findings: [AnalysisFinding(
                id: "metadata-discrepancy",
                analyzerID: "report-test",
                analyzerVersion: 3,
                category: .metadata,
                severity: .notable,
                evidenceClass: .derivedObservation,
                title: "Metadata discrepancy",
                explanation: "Two metadata namespaces contain different software values.",
                technicalDetail: "XMP and EXIF values differ.",
                alternatives: ["A normal export application may preserve an older value."],
                confidence: nil,
                sourceRepresentation: .originalBytes,
                computedAt: Date(timeIntervalSince1970: 11),
                includeInReport: true
            )])
        ))
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .distance,
            geometry: .segment(
                start: AnalysisNormalizedPoint(x: 0.1, y: 0.2),
                end: AnalysisNormalizedPoint(x: 0.7, y: 0.8)
            ),
            text: "Known doorway",
            note: "Measured from visible frame edges.",
            measurementCalibration: AnalysisMeasurementCalibration(
                knownLength: 2,
                unit: .meters
            )
        ))
        analysisCase.setAnnotation(AnalysisAnnotation(
            kind: .polygon,
            geometry: .polygon([
                AnalysisNormalizedPoint(x: 0.15, y: 0.15),
                AnalysisNormalizedPoint(x: 0.45, y: 0.20),
                AnalysisNormalizedPoint(x: 0.30, y: 0.50),
            ]),
            text: "Polygon detail"
        ))
        analysisCase.setTimestampEvidence(AnalysisTimestampEvidence(
            kind: .observation,
            title: "Witness time",
            value: AnalysisTimestampValue(
                year: 2026,
                month: 8,
                day: 2,
                hour: 12,
                minute: 30,
                precision: .minute,
                utcOffsetMinutes: 120
            ),
            source: .userEntered,
            sourceDetail: "Investigator entry"
        ))
        analysisCase.setObservation(AnalysisObservation(
            title: "Weather",
            note: "Overcast, with no reliable timestamp."
        ))
        analysisCase.setMapViewport(AnalysisMapViewport(
            center: AnalysisGeoCoordinate(latitude: 59.9139, longitude: 10.7522),
            latitudeDelta: 0.05,
            longitudeDelta: 0.06
        ))
        analysisCase.setMapAnnotation(AnalysisMapAnnotation(
            kind: .label,
            geometry: .point(AnalysisGeoCoordinate(latitude: 59.914, longitude: 10.753)),
            text: "Camera position"
        ))

        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test",
            now: Date(timeIntervalSince1970: 30)
        )
        var progressValues: [Double] = []
        let data = try await AnalysisPDFReportRenderer.makePDF(snapshot: snapshot) {
            progressValues.append($0)
        }
        try writeQAReportIfRequested(data, filename: "analysis-report-a4.pdf")
        let document = try #require(PDFDocument(data: data))
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        #expect(document.pageCount >= 9)
        let bounds = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(bounds.width - 595.28) < 1)
        #expect(abs(bounds.height - 841.89) < 1)
        #expect(text.contains("IMAGE ANALYSIS REPORT"))
        #expect(text.contains("Example Evidence Case"))
        #expect(text.contains(revision.sha256))
        #expect(text.contains("Metadata discrepancy"))
        #expect(text.contains("Known doorway"))
        #expect(text.contains("Polygon detail"))
        #expect(text.contains("polygon with 3 vertices"))
        #expect(text.contains("Converted measurements depend"))
        #expect(text.contains("Witness time"))
        #expect(text.contains("Weather"))
        #expect(text.contains("No Apple Maps tiles or imagery are embedded"))
        #expect(text.contains("Methodology"))
        #expect(text.contains("Limitations"))
        #expect(text.contains("sha256:test|report-test|v3"))
        #expect(text.contains("Image figure unavailable"))
        #expect(text.contains("Full-image analytical scopes"))
        #expect(text.contains("Scope figures unavailable"))
        #expect(progressValues.last == 1)
        #expect(progressValues == progressValues.sorted())
    }

    @Test("supports US Letter and privacy-oriented export settings")
    func supportsLetterAndPrivacyOptions() async throws {
        let fixture = try AnalysisReportFixture(contents: "letter report source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        let analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test"
        )
        let data = try await AnalysisPDFReportRenderer.makePDF(
            snapshot: snapshot,
            options: AnalysisReportExportOptions(
                pageFormat: .usLetter,
                includeAnalyticalScopes: false,
                includeCanonicalPath: false,
                includeCameraSerialNumber: false,
                includeLocationCoordinates: false,
                includeRawMetadata: false
            )
        )
        try writeQAReportIfRequested(data, filename: "analysis-report-letter.pdf")
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        #expect(abs(bounds.width - 612) < 0.1)
        #expect(abs(bounds.height - 792) < 0.1)
        #expect(text.contains("US Letter"))
        #expect(text.contains("Canonical path"))
        #expect(text.contains("Omitted by export settings"))
        #expect(!text.contains(fixture.directoryURL.path))
        #expect(text.contains("Raw metadata was omitted by export settings"))
        #expect(!text.contains("Full-image analytical scopes"))
    }

    @Test("paginates long Unicode findings and many annotations")
    func paginatesLongUnicodeAndManyAnnotations() async throws {
        let fixture = try AnalysisReportFixture(contents: "pagination source")
        defer { fixture.remove() }
        let revision = try await SourceImageRevision.capture(at: fixture.fileURL)
        var analysisCase = AnalysisCase.create(for: revision, appBuild: "test")
        analysisCase.title = "Åsted – blåbær og café"
        let longExplanation = String(
            repeating: "A normal workflow may preserve this observation; context remains necessary. ",
            count: 70
        ) + "Sluttmerknad: blåbær, café, Straße."
        analysisCase.setAnalyzerRun(AnalysisAnalyzerRun(
            analyzerID: "pagination-test",
            analyzerVersion: 1,
            cacheKey: "pagination-key",
            sourceRepresentation: .originalBytes,
            status: .completed,
            progress: 1,
            startedAt: nil,
            completedAt: nil,
            errorMessage: nil,
            output: AnalysisAnalyzerOutput(findings: [AnalysisFinding(
                id: "long-unicode",
                analyzerID: "pagination-test",
                analyzerVersion: 1,
                category: .metadata,
                severity: .notable,
                evidenceClass: .derivedObservation,
                title: "Lang merknad – café",
                explanation: longExplanation,
                technicalDetail: "Unicode: ÆØÅ, é, ß.",
                alternatives: ["Benign eksport", "Normal redigering"],
                confidence: nil,
                sourceRepresentation: .originalBytes,
                computedAt: Date(timeIntervalSince1970: 1),
                includeInReport: true
            )])
        ))
        for index in 0..<70 {
            analysisCase.setAnnotation(AnalysisAnnotation(
                kind: .label,
                geometry: .anchor(AnalysisNormalizedPoint(
                    x: Double((index % 10) + 1) / 11,
                    y: Double((index / 10) + 1) / 8
                )),
                text: index == 69 ? "Siste merknad – blåbær" : "Merknad \(index + 1)"
            ))
        }
        let snapshot = try await AnalysisReportSnapshot.capture(
            from: analysisCase,
            sourceURL: fixture.fileURL,
            appVersion: "2.3",
            appBuild: "test"
        )

        let data = try await AnalysisPDFReportRenderer.makePDF(snapshot: snapshot)
        let document = try #require(PDFDocument(data: data))
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        #expect(document.pageCount >= 15)
        #expect(text.contains("Åsted – blåbær og café"))
        #expect(text.contains("Sluttmerknad: blåbær, café, Straße."))
        #expect(text.contains("Siste merknad – blåbær"))

        try writeQAReportIfRequested(data, filename: "analysis-report-long-unicode.pdf")
    }

    private func finding(
        id: String,
        category: AnalysisFindingCategory,
        includeInReport: Bool
    ) -> AnalysisFinding {
        AnalysisFinding(
            id: id,
            analyzerID: "z-analyzer",
            analyzerVersion: 1,
            category: category,
            severity: .informational,
            evidenceClass: .fact,
            title: id,
            explanation: "Explanation",
            technicalDetail: "Detail",
            alternatives: [],
            confidence: nil,
            sourceRepresentation: .originalBytes,
            computedAt: Date(timeIntervalSince1970: 10),
            includeInReport: includeInReport
        )
    }

    private func writeQAReportIfRequested(_ data: Data, filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ANALYSIS_REPORT_QA_OUTPUT"] else {
            return
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
    }
}

private struct AnalysisReportFixture {
    let directoryURL: URL
    let fileURL: URL

    init(contents: String) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "analysis-report-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileURL = directoryURL.appendingPathComponent("fixture.jpg")
        try Data(contents.utf8).write(to: fileURL)
    }

    init(pixelWidth: Int, pixelHeight: Int) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "analysis-report-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileURL = directoryURL.appendingPathComponent("fixture.png")
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw AnalysisReportFixtureError.imageCreationFailed
        }
        context.setFillColor(red: 0.12, green: 0.36, blue: 0.68, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  fileURL as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw AnalysisReportFixtureError.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AnalysisReportFixtureError.imageCreationFailed
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum AnalysisReportFixtureError: Error {
    case imageCreationFailed
}
