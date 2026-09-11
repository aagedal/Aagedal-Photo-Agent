import Foundation
import Testing
import SwiftMediaMetadata
@testable import Aagedal_Photo_Agent

@MainActor
private final class VariableRecoveryCallerGate {
    var continuation: CheckedContinuation<Void, Never>?
    var paused: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class VariableRecoveryCallerExecutionState { var succeed = false }

@Suite("Variable photo-scoped recovery callers", .serialized)
@MainActor
struct VariableConflictRecoveryCallerTests {
    private func folder() throws -> URL {
        // Use a lexical physical root: Foundation can rewrite canonicalized temporaryDirectory
        // back to /var, which is an explicitly linked destination rejected by recovery export.
        let url = URL(fileURLWithPath: "/private/tmp/variable-recovery-caller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func input(_ url: URL, metadata: IPTCMetadata) -> VariableMetadataInputSnapshot {
        let revision = SourceImageRevision(canonicalURL: url, fileResourceIdentifier: nil,
            filenameAtCreation: url.lastPathComponent, byteCount: 5,
            contentModificationDate: Date(timeIntervalSince1970: 100), pixelWidth: 1, pixelHeight: 1,
            exifOrientation: 1, sha256: String(repeating: "a", count: 64), hashCompletedAt: Date(timeIntervalSince1970: 101))
        return .init(baselineSidecar: nil, embeddedMetadata: metadata, xmpMetadata: nil, hasC2PA: false,
            evidence: .init(sourceRevision: revision, xmpData: nil))
    }
    private func model(_ inputs: [URL: VariableMetadataInputSnapshot],
                       loader: (@MainActor @Sendable (URL, URL) async throws -> VariableMetadataInputSnapshot)? = nil,
                       resolver: (@MainActor @Sendable (VariableMetadataResolutionInput) async throws -> IPTCMetadata)? = nil,
                       executor: (@Sendable (VariableMetadataWriteRequest) async -> VariableMetadataWriteResult)? = nil,
                       beforeDiscard: @escaping @Sendable () async -> Void = {}) -> MetadataViewModel {
        let facts = Dictionary(uniqueKeysWithValues: inputs.map { url, value in
            (url, MetadataEditorSourceFacts(imageURL: url, xmpMetadata: value.embeddedMetadata,
                appSidecar: value.baselineSidecar, reconciliationVerdict: nil))
        })
        let boundary = MetadataEditorReadService(access: .init(read: { url, _, _, _ in
            facts[url] ?? .init(imageURL: url, xmpMetadata: nil, appSidecar: nil, reconciliationVerdict: nil)
        }))
        let options = VariableMetadataOptions(ordinaryMode: .historyOnly, credentialMode: .writeToXMPSidecar,
            rawMode: .writeToXMPSidecar, credentialRawMode: .writeToXMPSidecar,
            initials: "CAPTURED", addJobIDToKeywords: false, approvedKeywords: [:], strictKeywords: false)
        let result = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(),
            editorReadService: boundary, variableInputLoader: loader ?? { url, _ in try #require(inputs[url]) },
            variableWriteExecutor: executor ?? { .init(requestID: $0.id, imageURL: $0.imageURL, failure: "Retained conflict") },
            variableLifecycleCoordinator: VariableDraftLifecycleCoordinator(),
            variableRecoveryBeforeDiscard: beforeDiscard, variableOptions: { options },
            variableResolver: resolver ?? { VariableMetadataResolver.resolveText($0.metadata, input: $0) })
        // These tests edit model values directly; the registered barrier certifies there is
        // no separate AppKit buffer, matching the production panel's synchronous contract.
        result.registerVariableRecoveryEditorBarrier(owner: UUID(), handler: {})
        return result
    }
    private func load(_ model: MetadataViewModel, _ urls: [URL]) async throws {
        model.loadMetadata(for: urls.map { ImageFile(url: $0) }, folderURL: try #require(urls.first).deletingLastPathComponent())
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.isLoading)
    }
    private func entries(_ export: URL) throws -> [[String: Any]] {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any])
        return try #require(doc["entries"] as? [[String: Any]])
    }
    private func wait(_ gate: VariableRecoveryCallerGate) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.paused, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.paused)
    }

    @Test("Pre-read failure exports the only captured editor copy and options after selection changes")
    func preprepareOnlyCopy() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        try Data("photo".utf8).write(to: a)
        let snapshots = [a: input(a, metadata: IPTCMetadata(title: "Original")), b: input(b, metadata: IPTCMetadata(title: "Other"))]
        let m = model(snapshots, loader: { _, _ in throw CocoaError(.fileReadUnknown) })
        try await load(m, [a]); m.editingMetadata.title = "Only copy {filename}"; m.hasChanges = true
        m.processVariablesForImages([ImageFile(url: a)]); await m.waitForVariableProcessing()
        try await load(m, [b])
        let review = try await m.beginVariableRecovery(for: a)
        #expect(throws: (any Error).self) { try m.requireVariableDraftsPersisted() }
        let export = root.appendingPathComponent("recovery.json")
        let receipt = try await m.exportVariableRecovery(review, to: export)
        let entry = try #require(try entries(export).first)
        let payload = try #require(entry["admissionPayload"] as? [String: Any])
        let edited = try #require(payload["editedMetadata"] as? [String: Any])
        let editorial = try #require(edited["editorial"] as? [String: Any])
        #expect(editorial["title"] as? String == "Only copy {filename}")
        #expect(payload["cachedFirstInput"] is NSNull)
        #expect((payload["options"] as? [String: Any])?["initials"] as? String == "CAPTURED")
        try await m.discardVariableRecovery(review, receipt: receipt)
        #expect(m.variableRecoveryPhotos.isEmpty)
        #expect(m.editingMetadata.title == "Other")
        #expect(try Data(contentsOf: a) == Data("photo".utf8))
        try m.requireVariableDraftsPersisted()
    }

    @Test("Full template export retains pretrim deltas and cached first facts")
    func fullTemplateExport() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["a.png", "b.png"].map { root.appendingPathComponent($0) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.map { ($0, input($0, metadata: IPTCMetadata(title: "Before"))) })
        let m = model(inputs)
        m.currentFolderURL = root; m.selectedURLs = urls; m.selectedCount = 2
        let fields = ["title", "description", "extendedDescription", "creatorJobTitle", "descriptionWriter",
            "credit", "copyright", "rightsUsageTerms", "webStatementOfRights", "digitalImageGUID",
            "imageSupplierImageID", "jobId", "city", "sublocation", "provinceState", "country", "event",
            "instructions", "source", "creator", "personShown", "organisationShownName", "organisationShownCode"]
        m.applyTemplateFieldsAndProcessVariables(Dictionary(uniqueKeysWithValues: fields.map { ($0, $0 + " {filename} {seq}") }),
            to: urls.map { ImageFile(url: $0) })
        await m.waitForVariableProcessing()
        let review = try await m.beginVariableRecovery(for: urls[0])
        let export = root.appendingPathComponent("template.json")
        _ = try await m.exportVariableRecovery(review, to: export)
        let entry = try #require(try entries(export).first)
        let request = try #require(entry["request"] as? [String: Any])
        #expect(try #require(request["fullChanges"] as? [Any]).count > 20)
        let payload = try #require(entry["admissionPayload"] as? [String: Any])
        #expect(payload["batchInput"] is [String: Any])
        #expect(payload["cachedFirstInput"] is [String: Any])
        await m.endVariableRecovery(review)
    }

    @Test("Discard preserves same-stem siblings and other folders; unselected export omits unrelated editor")
    func exactPhotoScopeAndPayload() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("same.png"), sibling = root.appendingPathComponent("same.jpg"), b = other.appendingPathComponent("same.png")
        let inputs = Dictionary(uniqueKeysWithValues: [a, sibling, b].map { ($0, input($0, metadata: IPTCMetadata(title: "{filename}"))) })
        let m = model(inputs, loader: { _, _ in throw CocoaError(.fileReadUnknown) })
        try await load(m, [a]); m.editingMetadata.description = "Private selected A"; m.hasChanges = true
        m.processVariablesInFolder(images: [a, sibling].map { ImageFile(url: $0) }); await m.waitForVariableProcessing()
        m.currentFolderURL = other
        m.processVariablesForImages([ImageFile(url: b)]); await m.waitForVariableProcessing()
        let review = try await m.beginVariableRecovery(for: sibling)
        let export = root.appendingPathComponent("sibling.json")
        let receipt = try await m.exportVariableRecovery(review, to: export)
        let payload = try #require(try entries(export).first?["admissionPayload"] as? [String: Any])
        #expect(payload["editedMetadata"] is NSNull)
        #expect(payload["batchInput"] is NSNull)
        try await m.discardVariableRecovery(review, receipt: receipt)
        #expect(Set(m.variableRecoveryPhotos.map(\.path)) == Set([a.path, b.path]))
    }

    @Test("Tampered or obsolete exports cannot discard; cancellation keeps retained work")
    func tamperAndCancel() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png")
        let m = model([a: input(a, metadata: IPTCMetadata(title: "{filename}"))])
        m.currentFolderURL = root
        m.processVariablesForImages([ImageFile(url: a)]); await m.waitForVariableProcessing()
        let first = try await m.beginVariableRecovery(for: a)
        let export = root.appendingPathComponent("export.json")
        let receipt = try await m.exportVariableRecovery(first, to: export)
        try Data("tampered".utf8).write(to: export)
        await #expect(throws: (any Error).self) { try await m.discardVariableRecovery(first, receipt: receipt) }
        #expect(m.variableRecoveryPhotos == [a])
        await m.endVariableRecovery(first)
        let second = try await m.beginVariableRecovery(for: a)
        await #expect(throws: (any Error).self) { try await m.discardVariableRecovery(second, receipt: receipt) }
        await m.endVariableRecovery(second)
        #expect(m.hasRetainedVariableWrites)
    }

    @Test("Review waits for accepted work and refuses new admission; disappeared discard stays frozen")
    func settledReviewAndDiscardLifetime() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png")
        let resolverGate = VariableRecoveryCallerGate(), discardGate = VariableRecoveryCallerGate()
        let m = model([a: input(a, metadata: IPTCMetadata(title: "{filename}"))], resolver: { input in
            await resolverGate.wait(); return VariableMetadataResolver.resolveText(input.metadata, input: input)
        }, beforeDiscard: { await discardGate.wait() })
        m.currentFolderURL = root
        m.processVariablesForImages([ImageFile(url: a)])
        try await wait(resolverGate)
        let task = Task { try await m.beginVariableRecovery(for: a) }
        while m.variableRecoveryPhotoURL == nil { await Task.yield() }
        m.processVariablesForImages([ImageFile(url: a)])
        #expect(m.saveError?.contains("review") == true)
        resolverGate.release()
        let review = try await task.value
        #expect(review.requestCount == 1)
        let receipt = try await m.exportVariableRecovery(review, to: root.appendingPathComponent("settled.json"))
        let discard = Task { try await m.discardVariableRecovery(review, receipt: receipt) }
        try await wait(discardGate)
        await m.endVariableRecovery(review)
        #expect(m.variableRecoveryPhotoURL == a)
        #expect(throws: (any Error).self) { try m.requireVariableDraftsPersisted() }
        discardGate.release(); try await discard.value
        #expect(m.variableRecoveryPhotoURL == nil)
        #expect(m.variableRecoveryPhotos.isEmpty)
    }

    @Test("A fresh native buffer captured after export survives discard")
    func newerNativeBufferPreserved() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png")
        let m = model([a: input(a, metadata: IPTCMetadata(title: "Original"))], loader: { _, _ in throw CocoaError(.fileReadUnknown) })
        try await load(m, [a]); m.editingMetadata.title = "Exported {filename}"; m.hasChanges = true
        m.processVariablesForImages([ImageFile(url: a)]); await m.waitForVariableProcessing()
        let review = try await m.beginVariableRecovery(for: a)
        let receipt = try await m.exportVariableRecovery(review, to: root.appendingPathComponent("buffer.json"))
        m.registerVariableRecoveryEditorBarrier(owner: UUID()) { m.editingMetadata.title = "New native text" }
        try await m.discardVariableRecovery(review, receipt: receipt)
        #expect(m.editingMetadata.title == "New native text")
        #expect(m.hasChanges)
    }
    @Test("Discarded shared template cannot resurrect after the other photo retries successfully", arguments: [false, true])
    func sharedTemplateDeferredCleanup(compositionBlocksCleanup: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["a.png", "b.png"].map { root.appendingPathComponent($0) }
        for url in urls { try Data("untouched source".utf8).write(to: url) }
        let inputs = Dictionary(uniqueKeysWithValues: urls.map { ($0, input($0, metadata: IPTCMetadata(title: "Original"))) })
        let execution = VariableRecoveryCallerExecutionState()
        let m = model(inputs, executor: { request in
            await MainActor.run {
                execution.succeed
                    ? .init(requestID: request.id, imageURL: request.imageURL, preparedSidecar: request.sidecar, savedToHistory: true)
                    : .init(requestID: request.id, imageURL: request.imageURL, failure: "Retained conflict")
            }
        })
        try await load(m, urls)
        m.applyTemplateFieldsAndProcessVariables(["title": "Shared {filename}"], to: urls.map { ImageFile(url: $0) })
        await m.waitForVariableProcessing()
        try #require(m.variableRecoveryPhotos.count == 2)
        let review = try await m.beginVariableRecovery(for: urls[0])
        let receipt = try await m.exportVariableRecovery(review, to: root.appendingPathComponent("shared.json"))
        try await m.discardVariableRecovery(review, receipt: receipt)
        #expect(m.editingMetadata.title == "Shared {filename}")
        m.saveToSidecar()
        #expect(m.saveError?.contains("shared editor") == true)
        #expect(!m.isSaving)
        m.processVariablesForImages(urls.map { ImageFile(url: $0) })
        #expect(m.saveError?.contains("shared editor") == true)
        m.processVariables(filename: "new", sequenceIndex: 5)
        #expect(m.saveError?.contains("shared editor") == true)
        m.applyTemplateFieldsAndProcessVariables(["title": "Replacement"], to: urls.map { ImageFile(url: $0) })
        #expect(m.saveError?.contains("shared editor") == true)
        #expect(m.editingMetadata.title == "Shared {filename}")
        #expect(m.variableRecoveryPhotos == [urls[1]])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".photo_metadata").path))
        if compositionBlocksCleanup {
            m.registerVariableRecoveryEditorBarrier(owner: UUID()) { throw CocoaError(.userCancelled) }
        }
        execution.succeed = true
        m.retryVariableWrites(); await m.waitForVariableProcessing()
        if compositionBlocksCleanup {
            #expect(m.hasRetainedVariableWrites)
            #expect(throws: (any Error).self) { try m.requireVariableDraftsPersisted() }
            m.saveToSidecar()
            #expect(m.saveError?.contains("shared editor") == true)
            m.registerVariableRecoveryEditorBarrier(owner: UUID(), handler: {})
            m.retryVariableWrites(); await m.waitForVariableProcessing()
        }
        #expect(m.variableRecoveryPhotos.isEmpty)
        #expect(m.editingMetadata.title == "Original")
        #expect(!m.hasUnpersistedEditorChanges)
        #expect(try m.captureCaptionDraftPersistence() == nil)
        for url in urls { #expect(try Data(contentsOf: url) == Data("untouched source".utf8)) }
    }

    @Test("Cancelled waiting review releases its freeze after accepted work settles")
    func cancelledBeginSettles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png")
        let gate = VariableRecoveryCallerGate()
        let m = model([a: input(a, metadata: IPTCMetadata(title: "{filename}"))], resolver: { input in
            await gate.wait(); return VariableMetadataResolver.resolveText(input.metadata, input: input)
        })
        m.currentFolderURL = root
        m.processVariablesForImages([ImageFile(url: a)])
        try await wait(gate)
        let begin = Task { try await m.beginVariableRecovery(for: a) }
        while m.variableRecoveryPhotoURL == nil { await Task.yield() }
        begin.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await begin.value }
        #expect(m.variableRecoveryPhotoURL == nil)
        #expect(m.variableRecoveryPhotos == [a])
        let again = try await m.beginVariableRecovery(for: a)
        await m.endVariableRecovery(again)
    }

    @Test("An active composition barrier refuses discard before removing captured work")
    func bufferBarrierRefusesDiscard() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png")
        let m = model([a: input(a, metadata: IPTCMetadata(title: "{filename}"))])
        m.currentFolderURL = root
        m.processVariablesForImages([ImageFile(url: a)]); await m.waitForVariableProcessing()
        let review = try await m.beginVariableRecovery(for: a)
        let receipt = try await m.exportVariableRecovery(review, to: root.appendingPathComponent("composition.json"))
        let owner = UUID()
        m.registerVariableRecoveryEditorBarrier(owner: owner) { throw CocoaError(.userCancelled) }
        m.unregisterVariableRecoveryEditorBarrier(owner: UUID())
        await #expect(throws: (any Error).self) { try await m.discardVariableRecovery(review, receipt: receipt) }
        #expect(m.variableRecoveryPhotos == [a])
        m.unregisterVariableRecoveryEditorBarrier(owner: owner)
        await m.endVariableRecovery(review)
    }

    @Test("Absent live-editor barrier refuses owned-buffer discard while keeping export valid")
    func absentBarrierRefusesOwnedReset() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.png")
        let m = model([a: input(a, metadata: IPTCMetadata(title: "Original"))], loader: { _, _ in throw CocoaError(.fileReadUnknown) })
        try await load(m, [a]); m.editingMetadata.title = "Only {filename}"; m.hasChanges = true
        m.processVariablesForImages([ImageFile(url: a)]); await m.waitForVariableProcessing()
        let review = try await m.beginVariableRecovery(for: a)
        let receipt = try await m.exportVariableRecovery(review, to: root.appendingPathComponent("no-panel.json"))
        let owner = UUID()
        m.registerVariableRecoveryEditorBarrier(owner: owner, handler: {})
        m.unregisterVariableRecoveryEditorBarrier(owner: owner)
        await #expect(throws: (any Error).self) { try await m.discardVariableRecovery(review, receipt: receipt) }
        #expect(m.variableRecoveryPhotos == [a])
        #expect(m.editingMetadata.title == "Only {filename}")
        await m.endVariableRecovery(review)
    }

}
