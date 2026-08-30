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
    func failedEditorSaveKeepsMetadataDraftAndRetries() async throws {
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

        let failedResult = await viewModel.saveEditingTemplate()

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

        let retryResult = await viewModel.saveEditingTemplate()

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

    @Test("template import commit distinguishes cancellation from durable mutation")
    func importCommitCancellationAndDurabilityEvidence() async throws {
        let source = URL(fileURLWithPath: "/virtual/templates.json")
        let template = MetadataTemplate(name: "Agency")
        let bundle = TemplateBundle(templates: [template])
        let preCancelledProbe = TemplateImportCommitProbe()
        let preCancelledService = TemplateImportCommitService(access: preCancelledProbe.access)
        let preCancelledRequestID = UUID()

        let preCancelled = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preCancelledService.commit(
                bundle,
                sourceURL: source,
                requestID: preCancelledRequestID
            )
        }.value

        guard case let .cancelledBeforeCommit(returnedRequestID, returnedSource) = preCancelled else {
            Issue.record("Expected cancellation before any durable mutation")
            return
        }
        #expect(returnedRequestID == preCancelledRequestID)
        #expect(returnedSource == source)
        #expect(preCancelledProbe.saveCount == 0)
        #expect(preCancelledProbe.loadCount == 0)

        let committedProbe = TemplateImportCommitProbe(cancelDuringCommit: true)
        let committedService = TemplateImportCommitService(access: committedProbe.access)
        let committedRequestID = UUID()
        let committed = try await Task {
            try await committedService.commit(
                bundle,
                sourceURL: source,
                requestID: committedRequestID
            )
        }.value

        guard case .committed(let evidence) = committed else {
            Issue.record("Expected durable import evidence")
            return
        }
        #expect(evidence.requestID == committedRequestID)
        #expect(evidence.sourceURL == source)
        #expect(evidence.addedCount == 1)
        #expect(evidence.overwrittenCount == 0)
        #expect(evidence.committedTemplateIDs == [template.id])
        #expect(evidence.refreshedTemplates.map(\.name) == ["Agency"])
        #expect(evidence.inventoryRefreshFailureReason == nil)
        #expect(evidence.cancellationObservedAfterCommit)
        #expect(committedProbe.saveCount == 1)
        #expect(committedProbe.loadCount == 1)
    }

    @Test("template import commit returns a refreshed immutable inventory")
    func importCommitReturnsRefreshedInventory() async throws {
        let source = URL(fileURLWithPath: "/virtual/templates.json")
        let template = MetadataTemplate(name: "Agency")
        let probe = TemplateImportCommitProbe(refreshedTemplates: [template])
        let service = TemplateImportCommitService(access: probe.access)
        let requestID = UUID()

        let result = try await service.commit(
            TemplateBundle(templates: [template]),
            sourceURL: source,
            requestID: requestID
        )

        guard case .committed(let evidence) = result else {
            Issue.record("Expected a committed import")
            return
        }
        #expect(evidence.requestID == requestID)
        #expect(evidence.refreshedTemplates.map(\.name) == ["Agency"])
        #expect(evidence.inventoryRefreshFailureReason == nil)
        #expect(!evidence.cancellationObservedAfterCommit)
        #expect(probe.saveCount == 1)
        #expect(probe.loadCount == 2)
    }

    @Test("template import failure reports already durable templates")
    func importCommitFailureReportsPartialDurability() async throws {
        let source = URL(fileURLWithPath: "/virtual/templates.json")
        let templates = [MetadataTemplate(name: "First"), MetadataTemplate(name: "Second")]
        let probe = TemplateImportCommitProbe(failOnSaveNumber: 2)
        let service = TemplateImportCommitService(access: probe.access)
        let requestID = UUID()

        do {
            _ = try await service.commit(
                TemplateBundle(templates: templates),
                sourceURL: source,
                requestID: requestID
            )
            Issue.record("Expected the second save to fail")
        } catch let error as TemplateImportCommitError {
            #expect(error.requestID == requestID)
            #expect(error.sourceURL == source)
            #expect(error.addedCount == 1)
            #expect(error.overwrittenCount == 0)
            #expect(error.committedTemplateIDs == [templates[0].id])
            #expect(error.refreshedTemplates.map(\.name) == ["First"])
            #expect(error.reason == "Injected save failure")
            #expect(error.localizedDescription.contains("1 template was already imported"))
        }
        #expect(probe.saveCount == 2)
        #expect(probe.loadCount == 1)
    }

    @MainActor
    @Test("template view model publishes durable partial import state")
    func viewModelPublishesPartialImportState() async throws {
        let source = URL(fileURLWithPath: "/virtual/templates.json")
        let templates = [MetadataTemplate(name: "First"), MetadataTemplate(name: "Second")]
        let probe = TemplateImportCommitProbe(failOnSaveNumber: 2)
        let viewModel = TemplateViewModel(
            storage: TemplateStorageService(
                directoryURL: URL(fileURLWithPath: "/virtual/template-storage")
            ),
            importCommitService: TemplateImportCommitService(access: probe.access)
        )
        viewModel.pendingImportPreview = TemplateImportPreview(
            source: source,
            bundle: TemplateBundle(templates: templates),
            newCount: 2,
            overwriteCount: 0
        )

        viewModel.commitPendingImport()

        // Match the repository's long-load diagnostic ceiling: the actor can be
        // scheduler-starved while the complete suite occupies every test executor.
        let deadline = ContinuousClock.now + .seconds(30)
        while viewModel.errorMessage == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the partial import result")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.pendingImportPreview == nil)
        #expect(viewModel.templates.map(\.name) == ["First"])
        #expect(viewModel.errorMessage?.contains("1 template was already imported") == true)
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

        let commitFunctionStart = try #require(
            viewModelSource.range(of: "func commitPendingImport()")
        )
        let commitFunctionEnd = try #require(
            viewModelSource.range(
                of: "func cancelPendingImport()",
                range: commitFunctionStart.upperBound..<viewModelSource.endIndex
            )
        )
        let commitFunction = viewModelSource[
            commitFunctionStart.lowerBound..<commitFunctionEnd.lowerBound
        ]
        #expect(serviceSource.contains("actor TemplateImportCommitService"))
        #expect(serviceSource.contains("case cancelledBeforeCommit"))
        #expect(serviceSource.contains("cancellationObservedAfterCommit"))
        #expect(commitFunction.contains("storage.importBundle") == false)
        #expect(commitFunction.contains("loadTemplates()") == false)
        #expect(commitFunction.contains("importCommitTask?.cancel()"))
        #expect(commitFunction.contains("try await importCommitService.commit"))
    }

    @Test("template CRUD save clears shortcut conflicts and returns immutable durable evidence")
    func templateCRUDSaveReturnsDurableInventory() async throws {
        var conflict = MetadataTemplate(name: "Existing")
        conflict.shortcutSlot = 3
        var replacement = MetadataTemplate(name: "Replacement")
        replacement.shortcutSlot = 3
        let probe = MetadataTemplateCRUDProbe(initial: [conflict])
        let service = TemplateCRUDService(access: probe.access)
        let requestID = UUID()

        let result = try await service.save(replacement, requestID: requestID)

        guard case .committed(let commit) = result else {
            Issue.record("Expected a durable template save")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.requestedTemplateCommitted)
        #expect(commit.durableTemplateIDs == [conflict.id, replacement.id])
        #expect(commit.refreshedTemplates.map(\.name) == ["Existing", "Replacement"])
        #expect(commit.refreshedTemplates.first?.shortcutSlot == nil)
        #expect(commit.refreshedTemplates.last?.shortcutSlot == 3)
        #expect(commit.inventoryRefreshFailureReason == nil)
        #expect(!commit.cancellationObservedAfterCommit)
        #expect(probe.maximumConcurrentOperations == 1)
    }

    @Test("template CRUD cancellation distinguishes zero IO from a durable save")
    func templateCRUDCancellationEvidence() async throws {
        let template = MetadataTemplate(name: "Agency")
        let preCancelledProbe = MetadataTemplateCRUDProbe()
        let preCancelledService = TemplateCRUDService(access: preCancelledProbe.access)
        let preCancelledID = UUID()
        let preCancelled = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preCancelledService.save(template, requestID: preCancelledID)
        }.value

        guard case .cancelledBeforeCommit(let returnedID) = preCancelled else {
            Issue.record("Expected cancellation before template IO")
            return
        }
        #expect(returnedID == preCancelledID)
        #expect(preCancelledProbe.loadCount == 0)
        #expect(preCancelledProbe.saveCount == 0)

        let durableProbe = MetadataTemplateCRUDProbe(cancelOnSave: true)
        let durableService = TemplateCRUDService(access: durableProbe.access)
        let durableID = UUID()
        let durable = try await Task {
            try await durableService.save(template, requestID: durableID)
        }.value

        guard case .committed(let commit) = durable else {
            Issue.record("Expected post-save cancellation evidence")
            return
        }
        #expect(commit.requestID == durableID)
        #expect(commit.requestedTemplateCommitted)
        #expect(commit.durableTemplateIDs == [template.id])
        #expect(commit.refreshedTemplates.map(\.name) == ["Agency"])
        #expect(commit.cancellationObservedAfterCommit)
    }

    @Test("template CRUD delete and export return durable immutable evidence")
    func templateCRUDDeleteAndExportEvidence() async throws {
        let template = MetadataTemplate(name: "Agency")
        let deleteProbe = MetadataTemplateCRUDProbe(initial: [template])
        let deleteService = TemplateCRUDService(access: deleteProbe.access)
        let deleteID = UUID()

        let deleteResult = try await deleteService.delete(template, requestID: deleteID)
        guard case .committed(let deleteCommit) = deleteResult else {
            Issue.record("Expected a durable deletion")
            return
        }
        #expect(deleteCommit.requestID == deleteID)
        #expect(deleteCommit.requestedTemplate == nil)
        #expect(deleteCommit.durableTemplateIDs == [template.id])
        #expect(deleteCommit.refreshedTemplates.isEmpty)
        #expect(deleteProbe.deleteCount == 1)

        let exportProbe = MetadataTemplateCRUDProbe(initial: [template], cancelOnExport: true)
        let exportService = TemplateCRUDService(access: exportProbe.access)
        let exportID = UUID()
        let destination = URL(fileURLWithPath: "/virtual/export.json")
        let exportResult = try await Task {
            try await exportService.exportAll(to: destination, requestID: exportID)
        }.value
        guard case .exported(let exportCommit) = exportResult else {
            Issue.record("Expected durable export evidence")
            return
        }
        #expect(exportCommit.requestID == exportID)
        #expect(exportCommit.destinationURL == destination)
        #expect(exportCommit.exportedTemplateCount == 1)
        #expect(exportCommit.cancellationObservedAfterCommit)
        #expect(exportProbe.exportCount == 1)
    }

    @MainActor
    @Test("superseded template inventory cannot publish stale results")
    func supersededTemplateInventoryCannotPublish() async throws {
        let probe = BlockingMetadataTemplateCRUDProbe()
        defer { probe.releaseFirstLoad() }
        let service = TemplateCRUDService(access: probe.access)
        let viewModel = TemplateViewModel(
            storage: TemplateStorageService(directoryURL: URL(fileURLWithPath: "/virtual/templates")),
            crudService: service
        )

        viewModel.loadTemplates()
        try await probe.waitUntilFirstLoadStarts()
        viewModel.loadTemplates()
        probe.releaseFirstLoad()

        let deadline = ContinuousClock.now + .seconds(30)
        while viewModel.templates.map(\.name) != ["second"] {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the latest template inventory")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.templates.map(\.name) == ["second"])
        #expect(probe.loadCount == 2)
        #expect(probe.maximumConcurrentOperations == 1)
    }

    @Test("template view models keep synchronous CRUD below the actor boundary")
    func templateCRUDSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/TemplateCRUDService.swift"
            ),
            encoding: .utf8
        )
        let metadataViewModelSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/TemplateViewModel.swift"
            ),
            encoding: .utf8
        )
        let developViewModelSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/DevelopTemplateViewModel.swift"
            ),
            encoding: .utf8
        )

        #expect(serviceSource.contains("actor TemplateCRUDService"))
        #expect(serviceSource.contains("case cancelledBeforeRead"))
        #expect(serviceSource.contains("case cancelledAfterRead"))
        #expect(serviceSource.contains("case cancelledBeforeCommit"))
        #expect(serviceSource.contains("cancellationObservedAfterCommit"))
        #expect(metadataViewModelSource.contains("try storage.loadAll()") == false)
        #expect(metadataViewModelSource.contains("try storage.save(") == false)
        #expect(metadataViewModelSource.contains("try storage.delete(") == false)
        #expect(metadataViewModelSource.contains("try storage.exportAll(") == false)
        #expect(developViewModelSource.contains("try storage.loadAll()") == false)
        #expect(developViewModelSource.contains("try storage.save(") == false)
        #expect(developViewModelSource.contains("try storage.delete(") == false)
        #expect(metadataViewModelSource.contains("loadRequestID == requestID"))
        #expect(developViewModelSource.contains("loadRequestID == requestID"))
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

nonisolated private final class TemplateImportCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelDuringCommit: Bool
    private let failOnSaveNumber: Int?
    private let refreshedTemplates: [MetadataTemplate]
    private var saves = 0
    private var loads = 0

    init(
        cancelDuringCommit: Bool = false,
        failOnSaveNumber: Int? = nil,
        refreshedTemplates: [MetadataTemplate] = []
    ) {
        self.cancelDuringCommit = cancelDuringCommit
        self.failOnSaveNumber = failOnSaveNumber
        self.refreshedTemplates = refreshedTemplates
    }

    var access: TemplateImportCommitAccess {
        TemplateImportCommitAccess(
            loadAll: { [self] in
                lock.withLock { loads += 1 }
                return refreshedTemplates
            },
            save: { [self] _ in
                let saveNumber = lock.withLock {
                    saves += 1
                    return saves
                }
                if saveNumber == failOnSaveNumber {
                    throw TemplateImportCommitProbeError.injectedSaveFailure
                }
                if cancelDuringCommit {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
    }

    var saveCount: Int { lock.withLock { saves } }
    var loadCount: Int { lock.withLock { loads } }
}

nonisolated private enum TemplateImportCommitProbeError: LocalizedError {
    case injectedSaveFailure

    var errorDescription: String? { "Injected save failure" }
}

nonisolated private final class MetadataTemplateCRUDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnSave: Bool
    private let cancelOnExport: Bool
    private var inventory: [MetadataTemplate]
    private var loads = 0
    private var saves = 0
    private var deletes = 0
    private var exports = 0
    private var activeOperations = 0
    private var maximumActiveOperations = 0

    init(
        initial: [MetadataTemplate] = [],
        cancelOnSave: Bool = false,
        cancelOnExport: Bool = false
    ) {
        inventory = initial
        self.cancelOnSave = cancelOnSave
        self.cancelOnExport = cancelOnExport
    }

    var access: TemplateCRUDAccess<MetadataTemplate> {
        TemplateCRUDAccess(
            loadAll: { [self] in
                operation {
                    loads += 1
                    return inventory
                }
            },
            save: { [self] template in
                operation {
                    saves += 1
                    if let index = inventory.firstIndex(where: { $0.id == template.id }) {
                        inventory[index] = template
                    } else {
                        inventory.append(template)
                    }
                }
                if cancelOnSave {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            delete: { [self] template in
                operation {
                    deletes += 1
                    inventory.removeAll { $0.id == template.id }
                }
            },
            exportAll: { [self] _ in
                let count = operation {
                    exports += 1
                    return inventory.count
                }
                if cancelOnExport {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return count
            },
            shortcutSlot: { $0.shortcutSlot },
            clearingShortcutSlot: {
                var copy = $0
                copy.shortcutSlot = nil
                return copy
            },
            sorted: { $0.sorted { $0.name < $1.name } }
        )
    }

    private func operation<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        defer {
            activeOperations -= 1
            lock.unlock()
        }
        return try body()
    }

    var loadCount: Int { lock.withLock { loads } }
    var saveCount: Int { lock.withLock { saves } }
    var deleteCount: Int { lock.withLock { deletes } }
    var exportCount: Int { lock.withLock { exports } }
    var maximumConcurrentOperations: Int { lock.withLock { maximumActiveOperations } }
}

nonisolated private final class BlockingMetadataTemplateCRUDProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var loads = 0
    private var activeOperations = 0
    private var maximumActiveOperations = 0
    private var firstLoadReleased = false

    var access: TemplateCRUDAccess<MetadataTemplate> {
        TemplateCRUDAccess(
            loadAll: { [self] in loadAll() },
            save: { _ in },
            delete: { _ in },
            exportAll: { _ in 0 },
            shortcutSlot: { $0.shortcutSlot },
            clearingShortcutSlot: {
                var copy = $0
                copy.shortcutSlot = nil
                return copy
            },
            sorted: { $0.sorted { $0.name < $1.name } }
        )
    }

    private func loadAll() -> [MetadataTemplate] {
        condition.lock()
        loads += 1
        let invocation = loads
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        condition.broadcast()
        if invocation == 1 {
            while !firstLoadReleased { condition.wait() }
        }
        activeOperations -= 1
        condition.unlock()
        return [MetadataTemplate(name: invocation == 1 ? "first" : "second")]
    }

    func waitUntilFirstLoadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while loadCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw TemplateImportPreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstLoad() {
        condition.lock()
        firstLoadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var loadCount: Int { condition.withLock { loads } }
    var maximumConcurrentOperations: Int { condition.withLock { maximumActiveOperations } }
}
