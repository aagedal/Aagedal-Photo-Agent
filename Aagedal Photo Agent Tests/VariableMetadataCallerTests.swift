import Foundation
import Testing
import SwiftMediaMetadata
@testable import Aagedal_Photo_Agent

private actor VariableCallerExecutor {
    enum Response: Sendable { case success, failed, cancelledAfterXMP, unverifiedJSON }
    private(set) var requests: [VariableMetadataWriteRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    let pauses: Set<Int>
    let responses: [Response]
    init(pauses: Set<Int> = [], responses: [Response] = []) { self.pauses = pauses; self.responses = responses }
    var isPaused: Bool { gate != nil }
    func resume() { gate?.resume(); gate = nil }
    func execute(_ request: VariableMetadataWriteRequest) async -> VariableMetadataWriteResult {
        let index = requests.count
        requests.append(request)
        if pauses.contains(index) { await withCheckedContinuation { gate = $0 } }
        switch index < responses.count ? responses[index] : .success {
        case .failed:
            return .init(requestID: request.id, imageURL: request.imageURL,
                preparedSidecar: request.sidecar, failure: "Injected physical failure")
        case .cancelledAfterXMP:
            return .init(requestID: request.id, imageURL: request.imageURL,
                preparedSidecar: request.sidecar,
                physicalResult: .init(requestID: request.id, imageURL: request.imageURL, didWriteXMP: true, wasCancelled: true),
                wasCancelled: true)
        case .unverifiedJSON:
            return .init(requestID: request.id, imageURL: request.imageURL,
                failure: "Injected prepare verification failure",
                committedButUnverifiedSidecarURL: request.folderURL.appendingPathComponent(".photo_metadata/uncertain.meta.json"))
        case .success:
            if request.requestedMode == .historyOnly {
                return .init(requestID: request.id, imageURL: request.imageURL, preparedSidecar: request.sidecar, savedToHistory: true)
            }
            var completed = request.sidecar
            completed.pendingChanges = false
            let destinations = await MainActor.run {
                (request.requestedMode.writesEmbedded, request.requestedMode.writesXMPSidecar)
            }
            return .init(requestID: request.id, imageURL: request.imageURL, preparedSidecar: request.sidecar,
                physicalResult: .init(requestID: request.id, imageURL: request.imageURL, installedSidecar: completed,
                    didWriteEmbedded: destinations.0, didWriteXMP: destinations.1))
        }
    }
}

private actor VariableCallerResolutionGate {
    private var gate: CheckedContinuation<Void, Never>?
    var isPaused: Bool { gate != nil }
    func resolve(_ input: VariableMetadataResolutionInput) async -> IPTCMetadata {
        await withCheckedContinuation { gate = $0 }
        return await MainActor.run {
            var resolved = input.metadata
            resolved.title = "Resolved old selection"
            return resolved
        }
    }
    func resume() { gate?.resume(); gate = nil }
}

private actor VariableCallerFirstResolutionFailure {
    private var gate: CheckedContinuation<Void, Never>?
    private var attempts = 0
    var isPaused: Bool { gate != nil }
    func resolve(_ input: VariableMetadataResolutionInput) async throws -> IPTCMetadata {
        attempts += 1
        if attempts == 1 {
            await withCheckedContinuation { gate = $0 }
            throw CocoaError(.fileReadUnknown)
        }
        return await MainActor.run {
            var result = input.metadata
            result.title = "Resolved " + input.filename
            return result
        }
    }
    func resume() { gate?.resume(); gate = nil }
}

@Suite("Variable caller immutable requests and outcomes", .serialized)
struct VariableMetadataCallerTests {
    @MainActor
    private func options(_ mode: MetadataWriteMode = .historyOnly, initials: String = "TA") -> VariableMetadataOptions {
        .init(ordinaryMode: mode, credentialMode: .writeToXMPSidecar,
            rawMode: .writeToXMPSidecar, credentialRawMode: .writeToXMPSidecar,
            initials: initials, addJobIDToKeywords: false, approvedKeywords: [:], strictKeywords: false)
    }

    @MainActor
    private func snapshot(_ url: URL, metadata: IPTCMetadata, record: MetadataSidecar? = nil,
                          xmp: IPTCMetadata? = nil, credentials: Bool = false) -> VariableMetadataInputSnapshot {
        let revision = SourceImageRevision(canonicalURL: url, fileResourceIdentifier: nil,
            filenameAtCreation: url.lastPathComponent, byteCount: 10,
            contentModificationDate: Date(timeIntervalSince1970: 100), pixelWidth: 1, pixelHeight: 1,
            exifOrientation: 1, sha256: String(repeating: "a", count: 64), hashCompletedAt: Date(timeIntervalSince1970: 101))
        return .init(baselineSidecar: record, embeddedMetadata: metadata, xmpMetadata: xmp,
            hasC2PA: credentials, evidence: .init(sourceRevision: revision, xmpData: nil))
    }

    @MainActor
    private func makeModel(_ snapshots: [URL: VariableMetadataInputSnapshot], executor: VariableCallerExecutor,
                           mode: MetadataWriteMode = .historyOnly,
                           loadedSnapshots: [URL: VariableMetadataInputSnapshot]? = nil,
                           lifecycle: VariableDraftLifecycleCoordinator = VariableDraftLifecycleCoordinator(),
                           resolver: (@MainActor @Sendable (VariableMetadataResolutionInput) async throws -> IPTCMetadata)? = nil) -> MetadataViewModel {
        let capturedOptions = options(mode)
        let loadedInputs = loadedSnapshots ?? snapshots
        let loadedFacts = Dictionary(uniqueKeysWithValues: loadedInputs.map { url, input in
            (url, MetadataEditorSourceFacts(imageURL: url,
                xmpMetadata: input.xmpMetadata ?? input.embeddedMetadata,
                appSidecar: input.baselineSidecar, reconciliationVerdict: nil))
        })
        let boundary = MetadataEditorReadService(access: .init(read: { url, _, _, _ in
            loadedFacts[url] ?? .init(imageURL: url, xmpMetadata: nil, appSidecar: nil, reconciliationVerdict: nil)
        }))
        return MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            editorReadService: boundary, variableInputLoader: { url, _ in
                guard let input = snapshots[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return input
            }, variableWriteExecutor: { await executor.execute($0) },
            variableLifecycleCoordinator: lifecycle, variableOptions: { capturedOptions },
            variableResolver: resolver ?? { VariableMetadataResolver.resolveText($0.metadata, input: $0) })
    }

    @MainActor
    private func load(_ model: MetadataViewModel, url: URL) async throws {
        model.loadMetadata(for: [ImageFile(url: url)], folderURL: url.deletingLastPathComponent())
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.isLoading)
    }

    private func waitForPause(_ executor: VariableCallerExecutor) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await executor.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await executor.isPaused)
    }

    @Test("Selected history save is awaited and owns only its original editor")
    @MainActor
    func selectedCompletionIsAwaitedAndScoped() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-selected")
        let url = folder.appendingPathComponent("one.jpg")
        let original = IPTCMetadata(title: "{filename}")
        let record = MetadataSidecar(sourceFile: url.lastPathComponent, pendingChanges: true,
            metadata: original, imageMetadataSnapshot: nil)
        let executor = VariableCallerExecutor(pauses: [0])
        let model = makeModel([url: snapshot(url, metadata: original, record: record)], executor: executor)
        try await load(model, url: url)
        model.processVariablesForImages([ImageFile(url: url)])
        try await waitForPause(executor)
        #expect(model.variableBatchOutcome == nil)
        #expect(model.variableProcessingStatus == nil)
        #expect(model.isProcessingFolder)
        model.selectedURLs = [folder.appendingPathComponent("other.jpg")]
        model.editingMetadata.title = "New selection buffer"
        model.saveError = "New selection message"
        await executor.resume()
        await model.waitForVariableProcessing()
        #expect(model.variableBatchOutcome?.results.first?.writeResult?.savedToHistory == true)
        #expect(model.editingMetadata.title == "New selection buffer")
        #expect(model.saveError == "New selection message")
        #expect(!model.isProcessingFolder)
        #expect(!(await executor.requests).isEmpty)
    }

    @Test("Retry preserves full captured changes, nil original, mode and operation identity")
    @MainActor
    func retryKeepsImmutableIntent() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-retry")
        let url = folder.appendingPathComponent("one.jpg")
        var original = IPTCMetadata(title: "{filename}", description: "Unrelated pending caption")
        original.credit = "Keep pending credit"
        let record = MetadataSidecar(sourceFile: url.lastPathComponent, pendingChanges: true,
            metadata: original, imageMetadataSnapshot: nil)
        let executor = VariableCallerExecutor(responses: [.failed, .success])
        let model = makeModel([url: snapshot(url, metadata: original, record: record)], executor: executor, mode: .writeToFile)
        model.currentFolderURL = folder
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        #expect(model.hasRetainedVariableWrites)
        #expect(model.variableBatchOutcome?.attention?.message.contains("only while this app session remains open") == true)
        let first = try #require(await executor.requests.first)
        model.currentFolderURL = URL(fileURLWithPath: "/virtual/other-folder")
        model.retryVariableWrites()
        await model.waitForVariableProcessing()
        let attempts = await executor.requests
        #expect(attempts.count == 2)
        #expect(attempts[1].id == first.id)
        #expect(attempts[1].replay.changes.map(\.id) == first.replay.changes.map(\.id))
        #expect(attempts[1].requestedMode == .writeToFile)
        #expect(attempts[1].folderURL == folder)
        #expect(attempts[1].sidecar.imageMetadataSnapshot == nil)
        #expect(attempts[1].sidecar.metadata.description == original.description)
        #expect(attempts[1].sidecar.metadata.credit == original.credit)
        #expect(!model.hasRetainedVariableWrites)
    }

    @Test("Cancelled variables retain exact attempted prefix and partial destination evidence")
    @MainActor
    func cancellationAndPrepareRecoveryPaths() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-prefix")
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.map { ($0, snapshot($0, metadata: IPTCMetadata(title: "{seq}"))) })
        let executor = VariableCallerExecutor(responses: [.success, .cancelledAfterXMP])
        let model = makeModel(inputs, executor: executor, mode: .writeToXMPSidecar)
        model.currentFolderURL = folder
        model.processVariablesForImages(urls.map { ImageFile(url: $0) })
        await model.waitForVariableProcessing()
        let outcome = try #require(model.variableBatchOutcome)
        #expect(outcome.results.map(\.imageURL) == Array(urls.prefix(2)))
        #expect(outcome.unattemptedURLs == [urls[2]])
        #expect(outcome.wasCancelled)
        #expect(outcome.attention?.message.contains("XMP metadata was written") == true)
        #expect(!model.isProcessingFolder)
        let uncertain = VariableCallerExecutor(responses: [.unverifiedJSON])
        let otherModel = makeModel(inputs, executor: uncertain)
        otherModel.currentFolderURL = folder
        otherModel.processVariablesForImages([ImageFile(url: urls[0])])
        await otherModel.waitForVariableProcessing()
        #expect(otherModel.variableBatchOutcome?.attention?.message.contains(".photo_metadata/uncertain.meta.json") == true)
    }

    @Test("Literal punctuated lists are unchanged while intentional variable lists expand")
    @MainActor
    func literalListsAndPreprocessing() throws {
        var original = IPTCMetadata(title: "{filename}")
        original.personShown = ["Doe, Jane", "Smith; John"]
        original.keywords = ["literal, comma", "  intentional spaces  "]
        original.creators = ["Writer, First", "Writer, First"]
        let input = VariableMetadataResolutionInput(metadata: original, imageURL: URL(fileURLWithPath: "/one.jpg"),
            filename: "one.jpg", sequenceIndex: 2, options: options())
        let result = VariableMetadataResolver.resolveText(original, input: input)
        #expect(result.personShown == original.personShown)
        #expect(result.keywords == original.keywords)
        #expect(result.creators == original.creators)
        #expect(result.title != original.title)
        var variables = original
        variables.personShown = ["{initials}"]
        let expanded = VariableMetadataResolver.resolveText(variables, input: .init(metadata: variables,
            imageURL: input.imageURL, filename: input.filename, sequenceIndex: 2, options: options(initials: "Jane, John")))
        #expect(expanded.personShown == ["Jane", "John"])
    }

    @Test("Develop-only XMP keeps embedded variables; completed JSON does not resurrect old metadata")
    @MainActor
    func effectivePhysicalBaseline() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-reference")
        let url = folder.appendingPathComponent("one.jpg")
        var embedded = IPTCMetadata(title: "Current {filename}", description: "Current embedded description")
        embedded.credit = "Physical credit"
        var technical = IPTCMetadata()
        var settings = CameraRawSettings(); settings.exposure2012 = 0.5
        technical.cameraRaw = settings
        let stale = MetadataSidecar(sourceFile: url.lastPathComponent, pendingChanges: false,
            metadata: IPTCMetadata(title: "Old {seq}", description: "Obsolete"),
            imageMetadataSnapshot: IPTCMetadata(title: "Original A"))
        let executor = VariableCallerExecutor()
        let model = makeModel([url: snapshot(url, metadata: embedded, record: stale, xmp: technical)], executor: executor)
        model.currentFolderURL = folder
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        let request = try #require(await executor.requests.first)
        #expect(request.sidecar.metadata.title?.hasPrefix("Current ") == true)
        #expect(request.sidecar.metadata.description == embedded.description)
        #expect(request.sidecar.metadata.credit == embedded.credit)
        #expect(request.sidecar.imageMetadataSnapshot?.title == "Original A")
        #expect(request.sidecar.metadata.cameraRaw == settings)
    }

    @Test("Unchanged technical editor values do not block selected pending variable resolution")
    @MainActor
    func selectedTechnicalBaselineAndNoOpCapture() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-technical")
        let url = folder.appendingPathComponent("one.jpg")
        let pending = IPTCMetadata(title: "{filename}")
        var physical = pending
        var settings = CameraRawSettings(); settings.exposure2012 = 0.5
        var mask = MaskAdjustment(name: "Retained mask", geometry: EllipseMaskGeometry())
        mask.exposure = 0.25
        settings.localAdjustments = [mask]
        physical.cameraRaw = settings
        physical.exifOrientation = 6
        let record = MetadataSidecar(sourceFile: url.lastPathComponent, pendingChanges: true,
            metadata: pending, imageMetadataSnapshot: nil)
        let executor = VariableCallerExecutor()
        var freshlyParsed = physical
        var reparsedMask = MaskAdjustment(name: "Retained mask", geometry: EllipseMaskGeometry())
        reparsedMask.exposure = 0.25
        freshlyParsed.cameraRaw?.localAdjustments = [reparsedMask]
        #expect(freshlyParsed.cameraRaw != physical.cameraRaw)
        let model = makeModel([url: snapshot(url, metadata: freshlyParsed, record: record, xmp: freshlyParsed)],
            executor: executor, loadedSnapshots: [url: snapshot(url, metadata: physical, record: record, xmp: physical)])
        try await load(model, url: url)
        #expect(model.editingMetadata.cameraRaw == settings)
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        let request = try #require(await executor.requests.first)
        #expect(request.sidecar.imageMetadataSnapshot == nil)
        #expect(model.hasChanges)
        #expect(!model.hasUnpersistedEditorChanges)
        #expect(try model.captureCaptionDraftPersistence() == nil)
        #expect(model.editingMetadata.cameraRaw == settings)
        model.editingMetadata.cameraRaw?.exposure2012 = 1.0
        model.hasChanges = true
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        #expect(await executor.requests.count == 1)
        #expect(model.variableBatchOutcome?.attention?.message.contains("Develop or rotation") == true)
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 1.0)
    }

    @Test("Buffer-only variables cannot steal a folder operation and cannot replace a later selection")
    @MainActor
    func bufferResolutionOwnership() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-buffer")
        let url = folder.appendingPathComponent("one.jpg")
        let executor = VariableCallerExecutor(pauses: [0])
        let model = makeModel([url: snapshot(url, metadata: IPTCMetadata(title: "{filename}"))], executor: executor)
        model.currentFolderURL = folder
        model.processVariablesForImages([ImageFile(url: url)])
        try await waitForPause(executor)
        model.processVariables(filename: "one.jpg")
        #expect(model.isProcessingFolder)
        await executor.resume()
        await model.waitForVariableProcessing()
        #expect(!model.isProcessingFolder)
        let gate = VariableCallerResolutionGate()
        let buffer = makeModel([url: snapshot(url, metadata: IPTCMetadata(title: "{filename}"))],
            executor: VariableCallerExecutor(), resolver: { await gate.resolve($0) })
        try await load(buffer, url: url)
        buffer.processVariables(filename: "one.jpg")
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isPaused)
        buffer.selectedURLs = [folder.appendingPathComponent("other.jpg")]
        buffer.editingMetadata.title = "New text"
        await gate.resume()
        await buffer.waitForVariableProcessing()
        #expect(buffer.editingMetadata.title == "New text")
    }

    @Test("Wrong-folder admission and missing per-photo input produce scoped errors")
    @MainActor
    func admissionAndReadFailures() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-admission")
        let url = folder.appendingPathComponent("one.jpg")
        let executor = VariableCallerExecutor()
        let model = makeModel([:], executor: executor)
        model.currentFolderURL = URL(fileURLWithPath: "/virtual/elsewhere")
        model.processVariablesForImages([ImageFile(url: url)])
        #expect(model.variableBatchOutcome?.attention?.message.contains("captured folder") == true)
        model.currentFolderURL = folder
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        #expect(model.variableBatchOutcome?.results.first?.completed == false)
        #expect(await executor.requests.isEmpty)
    }
    @Test("Unsaved admission survives selection change and resolution failure until exact retry")
    @MainActor
    func unpreparedEditorInputHasLifecycleOwner() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-unprepared")
        let url = folder.appendingPathComponent("one.jpg")
        let other = folder.appendingPathComponent("other.jpg")
        let lifecycle = VariableDraftLifecycleCoordinator()
        let gate = VariableCallerFirstResolutionFailure()
        let executor = VariableCallerExecutor()
        let original = IPTCMetadata(title: "Original")
        let record = MetadataSidecar(sourceFile: url.lastPathComponent, pendingChanges: true,
            metadata: original, imageMetadataSnapshot: nil)
        let inputs = [url: snapshot(url, metadata: original, record: record),
                      other: snapshot(other, metadata: IPTCMetadata(title: "Other selection"))]
        let model = makeModel(inputs, executor: executor, lifecycle: lifecycle,
            resolver: { try await gate.resolve($0) })
        try await load(model, url: url)
        model.editingMetadata.title = "Unsaved {filename}"
        model.editingMetadata.credit = "Only in editor"
        model.hasChanges = true
        model.processVariablesForImages([ImageFile(url: url)])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.isPaused)
        #expect(lifecycle.hasPendingWork)
        try await load(model, url: other)
        await gate.resume()
        await model.waitForVariableProcessing()
        #expect(model.hasRetainedVariableWrites)
        #expect(lifecycle.hasPendingWork)
        #expect(throws: (any Error).self) { try lifecycle.requirePersisted() }
        model.retryVariableWrites()
        await model.waitForVariableProcessing()
        let request = try #require(await executor.requests.first)
        #expect(request.sidecar.metadata.credit == "Only in editor")
        #expect(request.sidecar.metadata.title == "Resolved one.jpg")
        #expect(model.editingMetadata.title == "Other selection")
        #expect(!lifecycle.hasPendingWork)
        try lifecycle.requirePersisted()
    }

    @Test("Read-only admission failure is retryable without blocking normal Close")
    @MainActor
    func readFailureDoesNotOwnUnsavedEdits() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-readonly")
        let lifecycle = VariableDraftLifecycleCoordinator()
        let model = makeModel([:], executor: VariableCallerExecutor(), lifecycle: lifecycle)
        model.currentFolderURL = folder
        model.processVariablesForImages([ImageFile(url: folder.appendingPathComponent("unreadable.jpg"))])
        await model.waitForVariableProcessing()
        #expect(model.hasRetainedVariableWrites)
        #expect(!lifecycle.hasPendingWork)
        try lifecycle.requirePersisted()
    }

    @Test("Variable completion keeps original provenance on the next Caption edit", arguments: [false, true])
    @MainActor
    func completedOriginalSurvivesNextEdit(unknownOriginal: Bool) async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-next-edit")
        let url = folder.appendingPathComponent("one.jpg")
        let original: IPTCMetadata? = unknownOriginal ? nil : IPTCMetadata(title: "Original A")
        let pending = IPTCMetadata(title: "{filename}")
        let record = MetadataSidecar(sourceFile: url.lastPathComponent, pendingChanges: true,
            metadata: pending, imageMetadataSnapshot: original)
        let executor = VariableCallerExecutor()
        let model = makeModel([url: snapshot(url, metadata: pending, record: record)], executor: executor, mode: .writeToFile)
        try await load(model, url: url)
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        try #require(model.variableBatchOutcome?.results.first?.completed == true)
        #expect(!model.hasChanges)
        model.editingMetadata.credit = "A new editorial edit"
        model.hasChanges = true
        let capture = try #require(try model.captureCaptionDraftPersistence())
        #expect(capture.sidecar.imageMetadataSnapshot == original)
    }

    @Test("Multi-photo instant template folds all fields into immutable full deltas")
    @MainActor
    func fullTemplateBeforeHistoryTrim() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-template")
        let urls = ["one.jpg", "two.jpg"].map { folder.appendingPathComponent($0) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.map {
            ($0, snapshot($0, metadata: IPTCMetadata(title: "Before", description: "Independent caption")))
        })
        let executor = VariableCallerExecutor()
        let model = makeModel(inputs, executor: executor)
        model.currentFolderURL = folder
        model.selectedURLs = urls
        model.selectedCount = 2
        var template: [String: String] = [:]
        let fields = ["title", "description", "extendedDescription", "creatorJobTitle", "descriptionWriter",
            "credit", "copyright", "rightsUsageTerms", "webStatementOfRights", "digitalImageGUID",
            "imageSupplierImageID", "jobId", "city", "sublocation", "provinceState", "country", "event",
            "instructions", "source", "creator", "personShown", "organisationShownName", "organisationShownCode"]
        for field in fields { template[field] = field + " {filename} {seq}" }
        model.applyTemplateFieldsAndProcessVariables(template, to: urls.map { ImageFile(url: $0) })
        await model.waitForVariableProcessing()
        let requests = await executor.requests
        try #require(requests.count == 2)
        #expect(requests.allSatisfy { $0.replay.changes.count > 20 })
        #expect(requests.allSatisfy { $0.sidecar.history.count == 20 })
        #expect(requests[0].sidecar.metadata.title?.contains("one 1") == true)
        #expect(requests[1].sidecar.metadata.title?.contains("two 2") == true)
        #expect(requests[0].sidecar.metadata.instructions?.contains("one 1") == true)
        #expect(requests[1].sidecar.metadata.organisationsShownCodes.first?.contains("two 2") == true)
        #expect(requests[0].sidecar.metadata.organisationsShownNames.first?.contains("one 1") == true)
    }

    @Test("A selected stale physical baseline cannot overwrite an independent newer field")
    @MainActor
    func selectedPhysicalConflictPreservesBuffer() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-stale-physical")
        let url = folder.appendingPathComponent("one.jpg")
        let loaded = IPTCMetadata(title: "Loaded A", description: "Loaded caption")
        let changed = IPTCMetadata(title: "Independent C", description: "New physical caption")
        let lifecycle = VariableDraftLifecycleCoordinator()
        let executor = VariableCallerExecutor()
        let model = makeModel([url: snapshot(url, metadata: changed)], executor: executor,
            loadedSnapshots: [url: snapshot(url, metadata: loaded)], lifecycle: lifecycle)
        try await load(model, url: url)
        model.editingMetadata.title = "Unsaved {filename}"
        model.hasChanges = true
        model.processVariablesForImages([ImageFile(url: url)])
        await model.waitForVariableProcessing()
        #expect(await executor.requests.isEmpty)
        #expect(model.variableBatchOutcome?.attention?.message.contains("physical metadata changed") == true)
        #expect(model.editingMetadata.title == "Unsaved {filename}")
        #expect(model.hasRetainedVariableWrites)
        #expect(lifecycle.hasPendingWork)
    }

    @Test("Retry cannot replace a newer multi-photo editor buffer")
    @MainActor
    func multiRetryPreservesNewerEditor() async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-multi-retry")
        let urls = ["one.jpg", "two.jpg"].map { folder.appendingPathComponent($0) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.map { ($0, snapshot($0, metadata: IPTCMetadata(title: "Before"))) })
        let executor = VariableCallerExecutor(responses: [.failed, .success, .success])
        let model = makeModel(inputs, executor: executor)
        model.currentFolderURL = folder
        model.selectedURLs = urls
        model.selectedCount = 2
        model.applyTemplateFieldsAndProcessVariables(["title": "Captured {filename}"], to: urls.map { ImageFile(url: $0) })
        await model.waitForVariableProcessing()
        try #require(model.hasRetainedVariableWrites)
        model.editingMetadata.title = "Newer unsaved batch title"
        model.hasChanges = true
        model.retryVariableWrites()
        await model.waitForVariableProcessing()
        #expect(!model.hasRetainedVariableWrites)
        #expect(model.editingMetadata.title == "Newer unsaved batch title")
        #expect(model.hasChanges)
        let requests = await executor.requests
        #expect(requests.count == 3)
        #expect(requests[2].id == requests[0].id)
    }

    @Test("Instant template organisation lists retain explicit append and clear intent", arguments: [false, true])
    @MainActor
    func instantTemplateListIntent(append: Bool) async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-list-template")
        let urls = ["one.jpg", "two.jpg"].map { folder.appendingPathComponent($0) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            var original = IPTCMetadata(title: "Keep headline")
            original.organisationsShownCodes = ["Existing \(index + 1)"]
            return (url, snapshot(url, metadata: original))
        })
        let executor = VariableCallerExecutor()
        let model = makeModel(inputs, executor: executor)
        model.currentFolderURL = folder
        model.selectedURLs = urls
        model.selectedCount = 2
        model.applyTemplateFieldsAndProcessVariables(["organisationShownCode": append ? "New {seq}" : ""],
            to: urls.map { ImageFile(url: $0) }, append: append)
        await model.waitForVariableProcessing()
        let requests = await executor.requests
        try #require(requests.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.sidecar.metadata.organisationsShownCodes == (append ? ["Existing \(index + 1)", "New \(index + 1)"] : []))
            #expect(request.sidecar.metadata.title == "Keep headline")
        }
    }

    @Test("Appending an instant template preserves earlier batch clear or replacement", arguments: [false, true])
    @MainActor
    func instantTemplateAppendComposesPriorMutation(replace: Bool) async throws {
        let folder = URL(fileURLWithPath: "/virtual/variables-compose-template")
        let urls = ["one.jpg", "two.jpg"].map { folder.appendingPathComponent($0) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.map { url in
            var original = IPTCMetadata(title: "Keep headline")
            original.personShown = ["Remove original person"]
            return (url, snapshot(url, metadata: original))
        })
        let executor = VariableCallerExecutor()
        let model = makeModel(inputs, executor: executor)
        model.currentFolderURL = folder
        model.selectedURLs = urls
        model.selectedCount = 2
        try model.setBatchMutation(replace ? .overwrite(.repeatable(["Replacement person"])) : .clear, for: .personShown)
        model.applyTemplateFieldsAndProcessVariables(["personShown": "Added {seq}"],
            to: urls.map { ImageFile(url: $0) }, append: true)
        await model.waitForVariableProcessing()
        let requests = await executor.requests
        try #require(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let expected = (replace ? ["Replacement person"] : []) + ["Added \(index + 1)"]
            #expect(request.sidecar.metadata.personShown == expected)
            #expect(!request.sidecar.metadata.personShown.contains("Remove original person"))
        }
    }

}
