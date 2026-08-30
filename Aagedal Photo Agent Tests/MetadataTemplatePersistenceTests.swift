import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Metadata template persistence")
struct MetadataTemplatePersistenceTests {
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataTemplateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("earliest preset-shaped templates migrate with shipped defaults")
    func legacyPresetShapeMigrates() throws {
        let id = UUID()
        let fieldID = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy",
              "presetType": "Full",
              "fields": [
                {
                  "id": "\(fieldID.uuidString)",
                  "fieldKey": "title",
                  "templateValue": "News"
                }
              ]
            }
            """.utf8
        )

        let template = try JSONDecoder().decode(MetadataTemplate.self, from: data)
        #expect(template.schemaVersion == MetadataTemplate.currentSchemaVersion)
        #expect(template.templateType == .full)
        #expect(template.shortcutSlot == nil)
        #expect(template.processInstantly == false)
        #expect(template.fields.map(\.templateValue) == ["News"])

        let encoded = try JSONEncoder().encode(template)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == MetadataTemplate.currentSchemaVersion)
        #expect(object["presetType"] == nil)
    }

    @Test("template storage writes schema markers")
    func storageWritesSchemaMarker() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = MetadataTemplate(name: "Desk")
        let service = TemplateStorageService(directoryURL: folder)

        try service.save(template)

        let url = folder.appendingPathComponent("\(template.id.uuidString).json")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == MetadataTemplate.currentSchemaVersion)
        #expect(try service.loadAll().map(\.name) == ["Desk"])
    }

    @Test("editorial role fields survive template persistence")
    func editorialRoleFieldsRoundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expectedFields = [
            TemplateField(fieldKey: "creatorJobTitle", templateValue: "Staff Photographer"),
            TemplateField(fieldKey: "descriptionWriter", templateValue: "Night Desk"),
            TemplateField(fieldKey: "countryCode", templateValue: "NOR"),
            TemplateField(fieldKey: "organisationShownName", templateValue: "Example News"),
            TemplateField(fieldKey: "organisationShownCode", templateValue: "EXNEWS"),
            TemplateField(fieldKey: "rightsUsageTerms", templateValue: "Editorial use only"),
            TemplateField(fieldKey: "webStatementOfRights", templateValue: "https://example.test/rights"),
            TemplateField(fieldKey: "digitalImageGUID", templateValue: "urn:uuid:{filename}"),
            TemplateField(fieldKey: "imageSupplierImageID", templateValue: "AGENCY-{filename}"),
            TemplateField(fieldKey: "urgency", templateValue: "2"),
            TemplateField(fieldKey: "sceneCode", templateValue: "011200, 012400"),
        ]
        let template = MetadataTemplate(name: "Editorial roles", fields: expectedFields)
        let service = TemplateStorageService(directoryURL: folder)

        try service.save(template)
        let loaded = try #require(service.loadAll().first)

        #expect(loaded.fields == expectedFields)
        #expect(TemplateField.label(for: "creatorJobTitle") == "Creator Job Title")
        #expect(TemplateField.label(for: "descriptionWriter") == "Description Writer")
        #expect(TemplateField.label(for: "countryCode") == "Country Code")
        #expect(TemplateField.label(for: "organisationShownName") == "Organisation Shown Name")
        #expect(TemplateField.label(for: "organisationShownCode") == "Organisation Shown Code")
        #expect(TemplateField.label(for: "rightsUsageTerms") == "Rights Usage Terms")
        #expect(TemplateField.label(for: "webStatementOfRights") == "Web Statement of Rights")
        #expect(TemplateField.label(for: "digitalImageGUID") == "Digital Image GUID")
        #expect(TemplateField.label(for: "imageSupplierImageID") == "Image Supplier Image ID")
        #expect(TemplateField.label(for: "urgency") == "Urgency")
        #expect(TemplateField.label(for: "sceneCode") == "Scene Code")
    }

    @Test("newer templates are skipped and protected from overwrite")
    func newerTemplateIsReadOnly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = MetadataTemplate(name: "Current build")
        let url = folder.appendingPathComponent("\(template.id.uuidString).json")
        let futureData = Data(
            """
            {
              "schemaVersion": 2,
              "id": "\(template.id.uuidString)",
              "name": "Future build",
              "future": {"keep": true}
            }
            """.utf8
        )
        try futureData.write(to: url)
        let service = TemplateStorageService(directoryURL: folder)

        #expect(try service.loadAll().isEmpty)
        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "metadata template",
            found: 2,
            supported: MetadataTemplate.currentSchemaVersion
        )) {
            try service.save(template)
        }
        #expect(try Data(contentsOf: url) == futureData)
    }

    @Test("legacy bundles migrate and newer bundles are rejected")
    func bundleVersionHandling() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = TemplateStorageService(directoryURL: folder)
        let source = folder.appendingPathComponent("bundle.json")
        let exportedAt = "2026-08-19T12:00:00Z"
        try Data(
            #"{"version":1,"exportedAt":"\#(exportedAt)","templates":[]}"#.utf8
        ).write(to: source)

        let legacy = try service.loadBundle(from: source)
        #expect(legacy.schemaVersion == TemplateBundle.currentSchemaVersion)
        #expect(legacy.templates.isEmpty)

        let futureData = Data(
            #"{"schemaVersion":2,"exportedAt":"\#(exportedAt)","templates":[]}"#.utf8
        )
        try futureData.write(to: source, options: .atomic)
        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "template bundle",
            found: 2,
            supported: TemplateBundle.currentSchemaVersion
        )) {
            _ = try service.loadBundle(from: source)
        }
        #expect(try Data(contentsOf: source) == futureData)
    }

    @Test("a current bundle containing a future template is rejected without changing the file")
    func nestedFutureTemplateInBundleIsReadOnly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = TemplateStorageService(directoryURL: folder)
        let source = folder.appendingPathComponent("bundle.json")
        let templateID = UUID()
        let futureData = Data(
            """
            {
              "schemaVersion": \(TemplateBundle.currentSchemaVersion),
              "exportedAt": "2026-08-19T12:00:00Z",
              "templates": [{
                "schemaVersion": \(MetadataTemplate.currentSchemaVersion + 1),
                "id": "\(templateID.uuidString)",
                "name": "Future build",
                "future": {"keep": true}
              }]
            }
            """.utf8
        )
        try futureData.write(to: source)

        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "metadata template",
            found: MetadataTemplate.currentSchemaVersion + 1,
            supported: MetadataTemplate.currentSchemaVersion
        )) {
            _ = try service.loadBundle(from: source)
        }
        #expect(try Data(contentsOf: source) == futureData)
    }

    @Test("failed editor saves keep the metadata draft open and can be retried")
    @MainActor
    func failedEditorSaveKeepsMetadataDraftAndRetries() throws {
        let root = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storageLocation = root.appendingPathComponent("templates")
        try Data("blocks directory creation".utf8).write(to: storageLocation)

        let original = MetadataTemplate(
            name: "Original",
            fields: [TemplateField(fieldKey: "title", templateValue: "Draft headline")]
        )
        let viewModel = TemplateViewModel(
            storage: TemplateStorageService(directoryURL: storageLocation)
        )
        viewModel.startEditing(original)
        viewModel.editingTemplate.name = "Edited name"

        let failedResult = viewModel.saveEditingTemplate()

        guard case let .failure(failure) = failedResult else {
            Issue.record("Expected the injected storage failure")
            return
        }
        #expect(failure.templateKind == .metadata)
        #expect(viewModel.saveError == failure)
        #expect(viewModel.isEditing)
        #expect(viewModel.isEditingExistingTemplate)
        #expect(viewModel.editingTemplate.id == original.id)
        #expect(viewModel.editingTemplate.name == "Edited name")
        #expect(viewModel.editingTemplate.fields.first?.templateValue == "Draft headline")

        try FileManager.default.removeItem(at: storageLocation)
        try FileManager.default.createDirectory(at: storageLocation, withIntermediateDirectories: false)

        let retryResult = viewModel.saveEditingTemplate()

        guard case let .success(saved) = retryResult else {
            Issue.record("Expected retry to succeed after restoring writable storage")
            return
        }
        #expect(saved.id == original.id)
        #expect(!viewModel.isEditing)
        #expect(viewModel.saveError == nil)
        #expect(try TemplateStorageService(directoryURL: storageLocation).loadAll().first?.name == "Edited name")
    }

    @Test("template import preview returns immutable completion and post-read cancellation evidence")
    func importPreviewEvidence() async throws {
        let source = URL(fileURLWithPath: "/virtual/templates.json")
        let template = MetadataTemplate(name: "Agency")
        let requestID = UUID()
        let completedService = TemplateImportPreviewService(access: TemplateImportPreviewAccess(
            readPreview: { url in
                TemplateImportPreview(
                    source: url,
                    bundle: TemplateBundle(templates: [template]),
                    newCount: 1,
                    overwriteCount: 0
                )
            }
        ))

        let completed = try await completedService.preparePreview(
            from: source,
            requestID: requestID
        )

        guard case .prepared(let evidence) = completed else {
            Issue.record("Expected completed preview evidence")
            return
        }
        #expect(evidence.requestID == requestID)
        #expect(evidence.sourceURL == source)
        #expect(evidence.preview.bundle.templates.map(\.name) == ["Agency"])
        #expect(evidence.inspectedBundleTemplateCount == 1)

        let preCancelledRequestID = UUID()
        let preCancelled = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await completedService.preparePreview(
                from: source,
                requestID: preCancelledRequestID
            )
        }.value
        guard case let .cancelledBeforeRead(returnedRequestID, returnedSource) = preCancelled else {
            Issue.record("Expected pre-read cancellation evidence")
            return
        }
        #expect(returnedRequestID == preCancelledRequestID)
        #expect(returnedSource == source)

        let cancelledRequestID = UUID()
        let cancelledService = TemplateImportPreviewService(access: TemplateImportPreviewAccess(
            readPreview: { url in
                withUnsafeCurrentTask { $0?.cancel() }
                return TemplateImportPreview(
                    source: url,
                    bundle: TemplateBundle(templates: [template]),
                    newCount: 0,
                    overwriteCount: 1
                )
            }
        ))
        let cancelled = try await Task {
            try await cancelledService.preparePreview(
                from: source,
                requestID: cancelledRequestID
            )
        }.value

        guard case let .cancelledAfterRead(
            returnedRequestID,
            returnedSource,
            inspectedCount,
            newCount,
            overwriteCount
        ) = cancelled else {
            Issue.record("Expected post-read cancellation evidence")
            return
        }
        #expect(returnedRequestID == cancelledRequestID)
        #expect(returnedSource == source)
        #expect(inspectedCount == 1)
        #expect(newCount == 0)
        #expect(overwriteCount == 1)
    }

    @MainActor
    @Test("a superseded template import cannot publish a stale preview")
    func supersededImportPreviewCannotPublish() async throws {
        let probe = BlockingTemplateImportPreviewProbe()
        defer { probe.releaseFirstRead() }
        let storage = TemplateStorageService(
            directoryURL: URL(fileURLWithPath: "/virtual/template-storage")
        )
        let viewModel = TemplateViewModel(
            storage: storage,
            importPreviewService: TemplateImportPreviewService(access: probe.access)
        )
        let firstURL = URL(fileURLWithPath: "/virtual/first.json")
        let secondURL = URL(fileURLWithPath: "/virtual/second.json")

        viewModel.preparePreview(from: firstURL)
        try await probe.waitUntilFirstReadStarts()
        viewModel.preparePreview(from: secondURL)
        probe.releaseFirstRead()

        // Match the repository's long-load diagnostic ceiling: under the unfiltered parallel
        // suite the actor reader can be scheduler-starved even though focused execution is fast.
        let deadline = ContinuousClock.now + .seconds(30)
        while viewModel.pendingImportPreview?.source != secondURL {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the latest template preview")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.pendingImportPreview?.source == secondURL)
        #expect(viewModel.pendingImportPreview?.bundle.templates.map(\.name) == ["second"])
        #expect(viewModel.errorMessage == nil)
        #expect(probe.invocationCount == 2)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("template import source keeps blocking reads below a serialized actor boundary")
    func importPreviewSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/TemplateStorageService.swift"
            ),
            encoding: .utf8
        )
        let viewModelSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/TemplateViewModel.swift"
            ),
            encoding: .utf8
        )
        let previewFunctionStart = try #require(
            viewModelSource.range(of: "func preparePreview(from source: URL)")
        )
        let previewFunctionEnd = try #require(
            viewModelSource.range(
                of: "func commitPendingImport()",
                range: previewFunctionStart.upperBound..<viewModelSource.endIndex
            )
        )
        let previewFunction = viewModelSource[
            previewFunctionStart.lowerBound..<previewFunctionEnd.lowerBound
        ]

        #expect(serviceSource.contains("actor TemplateImportPreviewService"))
        #expect(serviceSource.contains("guard !Task.isCancelled"))
        #expect(serviceSource.contains("case cancelledBeforeRead"))
        #expect(serviceSource.contains("case cancelledAfterRead"))
        #expect(previewFunction.contains("storage.previewImport") == false)
        #expect(previewFunction.contains("try await importPreviewService.preparePreview"))
        #expect(previewFunction.contains("importPreviewTask?.cancel()"))
        #expect(previewFunction.contains("importPreviewRequestID == requestID"))
    }
}

private enum TemplateImportPreviewProbeError: Error {
    case timedOut
}

nonisolated private final class BlockingTemplateImportPreviewProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var firstReadReleased = false

    var access: TemplateImportPreviewAccess {
        TemplateImportPreviewAccess(readPreview: { [self] in readPreview(from: $0) })
    }

    private func readPreview(from url: URL) -> TemplateImportPreview {
        condition.lock()
        readCount += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        condition.broadcast()
        if readCount == 1 {
            while !firstReadReleased {
                condition.wait()
            }
        }
        activeReads -= 1
        condition.unlock()

        let name = url.deletingPathExtension().lastPathComponent
        return TemplateImportPreview(
            source: url,
            bundle: TemplateBundle(templates: [MetadataTemplate(name: name)]),
            newCount: 1,
            overwriteCount: 0
        )
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw TemplateImportPreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.lock()
        firstReadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.withLock { readCount }
    }

    var maximumConcurrentReads: Int {
        condition.withLock { maximumActiveReads }
    }
}
