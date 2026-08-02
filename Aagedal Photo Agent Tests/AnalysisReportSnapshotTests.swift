import Foundation
import Testing
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

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
