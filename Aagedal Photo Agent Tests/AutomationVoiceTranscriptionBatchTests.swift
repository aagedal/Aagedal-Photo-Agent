import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Retained voice transcription batches")
struct AutomationVoiceTranscriptionBatchTests {
    private enum Injected: Error { case inference, save }
    private actor FixtureIO {
        var captures: [URL: Int] = [:]
        var generated: [URL] = []
        var saved: [VoiceMemoTranscriptDraft] = []
        var failGeneration: URL?
        var failSave: URL?
        var drift: URL?
        var invalidApproval = false
        var roundedDates = false
        var gate: Gate?
        var entered: Gate?

        func configure(failGeneration: URL? = nil, failSave: URL? = nil, drift: URL? = nil,
                       invalidApproval: Bool = false, roundedDates: Bool = false,
                       gate: Gate? = nil, entered: Gate? = nil) {
            self.failGeneration = failGeneration; self.failSave = failSave; self.drift = drift
            self.invalidApproval = invalidApproval; self.roundedDates = roundedDates
            self.gate = gate; self.entered = entered
        }
        func capture(_ url: URL) -> AutomationVoiceTranscriptionBatchService.Input {
            captures[url, default: 0] += 1
            return AutomationVoiceTranscriptionBatchTests.input(url, changed: drift == url && captures[url, default: 0] > 1)
        }
        func generate(_ url: URL) async throws -> VoiceMemoTranscriptDraft {
            generated.append(url)
            if let entered { await entered.open() }
            if let gate { try await gate.wait() }
            if failGeneration == url { throw Injected.inference }
            var result = AutomationVoiceTranscriptionBatchTests.draft(url)
            if invalidApproval { result.approvedAt = Date() }
            return result
        }
        func save(_ value: VoiceMemoTranscriptDraft) throws -> VoiceMemoTranscriptDraft {
            if failSave == value.imageURL { throw Injected.save }
            saved.append(value)
            if roundedDates {
                return VoiceMemoTranscriptDraft(imageURL: value.imageURL, memoURL: value.memoURL,
                    memoByteCount: value.memoByteCount, memoSHA256: value.memoSHA256,
                    associationProfileIdentifier: value.associationProfileIdentifier,
                    localeIdentifier: value.localeIdentifier, provider: value.provider, providerModel: value.providerModel,
                    generatedAt: Date(timeIntervalSince1970: value.generatedAt.timeIntervalSince1970.rounded(.down)),
                    generatedText: value.generatedText, reviewedText: value.reviewedText, approvedAt: nil)
            }
            return value
        }
        nonisolated var dependencies: AutomationVoiceTranscriptionBatchService.Dependencies {
            .init(capture: { await self.capture($0) }, generate: { url, _ in try await self.generate(url) },
                  save: { value, _ in try await self.save(value) })
        }
    }

    private actor Gate {
        var opened = false
        func open() { opened = true }
        func wait() async throws {
            while !opened { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private final class Fixture {
        let root: URL
        let registry: AutomationOperationRegistry
        let io = FixtureIO()
        let service: AutomationVoiceTranscriptionBatchService
        init() throws {
            let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(path) }
            root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("batch-transcription-\(UUID())")
            registry = AutomationOperationRegistry(storageDirectory: root)
            service = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: io.dependencies)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private nonisolated static func revision(_ url: URL, changed: Bool = false) -> SourceImageRevision {
        .init(canonicalURL: url, fileResourceIdentifier: nil, filenameAtCreation: url.lastPathComponent,
              byteCount: 3, contentModificationDate: Date(timeIntervalSinceReferenceDate: 1),
              pixelWidth: nil, pixelHeight: nil, exifOrientation: nil,
              sha256: String(repeating: changed ? "b" : "a", count: 64), hashCompletedAt: Date())
    }
    private nonisolated static func input(_ url: URL, changed: Bool = false) -> AutomationVoiceTranscriptionBatchService.Input {
        let memo = url.deletingPathExtension().appendingPathExtension("WAV")
        return .init(imageURL: url, sourceRevision: revision(url, changed: changed),
                     association: .init(profileIdentifier: "test-profile", imageURL: url, memoURL: memo),
                     memoRevision: revision(memo),
                     relationshipRevision: .init(url: VoiceMemoCompanionRepository().recordURL(for: url), revision: String(repeating: "c", count: 64)))
    }
    private nonisolated static func draft(_ url: URL) -> VoiceMemoTranscriptDraft {
        let value = input(url)
        return .init(imageURL: url, memoURL: value.association.memoURL,
                     memoByteCount: value.memoRevision.byteCount, memoSHA256: value.memoRevision.sha256,
                     associationProfileIdentifier: value.association.profileIdentifier,
                     localeIdentifier: "en-US", provider: "Test provider", providerModel: "Test model",
                     generatedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
                     generatedText: "Editable text", reviewedText: "Editable text", approvedAt: nil)
    }
    private var photos: [URL] { ["first", "second", "third"].map { URL(fileURLWithPath: "/fixture/\($0).JPG") } }
    private var provider: AutomationVoiceTranscriptionBatchService.Provider { .apple(Locale(identifier: "en-US")) }

    @Test("Reserved native lifecycle links configured history before recognition")
    func nativeLifecycleOrdering() async throws {
        let f = try Fixture()
        let prepared = try await f.service.prepare(imageURLs: photos)
        let id = UUID(), photoCount = photos.count
        let registry = f.registry
        let hooks = AutomationVoiceTranscriptionBatchService.LifecycleHooks(operationID: id,
            admission: { _ in
                try registry.withAvailableOperationID(id) {}
                let records = try registry.records()
                #expect(records.isEmpty)
            }, didEnqueue: { record in
                #expect(record.id == id && record.state == .queued)
                #expect(record.batchProgress?.itemCount == photoCount)
                #expect(try registry.inspect(id) == record)
                // A durable cancellation after linkage must stop recognition entirely.
                _ = try registry.requestCancellation(id)
            }, cancellationCheck: { operationID in #expect(operationID == id) })
        let accepted = try await f.service.submit(prepared: prepared, provider: provider, lifecycle: hooks)
        #expect(accepted.id == id)
        let completed = try await f.service.waitForCompletion(id)
        #expect(completed.outcome == .cancelled)
        #expect(await f.io.generated.isEmpty)
        #expect(await f.io.saved.isEmpty)
    }

    @Test("Native admission or linkage failure never schedules inference", arguments: [false, true])
    func nativeLifecycleRefusal(atLink: Bool) async throws {
        let f = try Fixture()
        let prepared = try await f.service.prepare(imageURLs: photos)
        let id = UUID()
        let registry = f.registry
        let hooks = AutomationVoiceTranscriptionBatchService.LifecycleHooks(operationID: id,
            admission: { _ in
                try registry.withAvailableOperationID(id) {}
                if !atLink { throw Injected.inference }
            },
            didEnqueue: { _ in throw Injected.save }, cancellationCheck: { _ in })
        await #expect(throws: (any Error).self) {
            try await f.service.submit(prepared: prepared, provider: provider, lifecycle: hooks)
        }
        let history = try f.registry.records()
        #expect(history.count == (atLink ? 1 : 0))
        if atLink { #expect(history.first?.id == id && history.first?.outcome == .failed) }
        #expect(await f.io.generated.isEmpty)
        #expect(await f.io.saved.isEmpty)
    }

    @Test("Native preparation creates no history or drafts and retains exact ordered targets")
    func prepareWithoutEffects() async throws {
        let f = try Fixture()
        let prepared = try await f.service.prepare(imageURLs: photos)
        #expect(prepared.imageURLs == photos)
        #expect(try f.registry.records().isEmpty)
        #expect(await f.io.generated.isEmpty)
        #expect(await f.io.saved.isEmpty)
        let record = try await f.service.submit(prepared: prepared, provider: provider)
        #expect(try await f.service.waitForCompletion(record.id).outcome == .verified)
    }

    @Test("Drift after native preview refuses the complete set before enqueue or inference")
    func changedConsentSnapshot() async throws {
        let f = try Fixture()
        let prepared = try await f.service.prepare(imageURLs: photos)
        await f.io.configure(drift: photos[1])
        await #expect(throws: AutomationVoiceTranscriptionBatchService.Failure.sourceChanged) {
            try await f.service.submit(prepared: prepared, provider: provider)
        }
        #expect(try f.registry.records().isEmpty)
        #expect(await f.io.generated.isEmpty)
        #expect(await f.io.saved.isEmpty)
    }

    @Test("Ordered batch saves only editable drafts and survives registry reload", arguments: [false, true])
    func successfulBatch(roundedDates: Bool) async throws {
        let f = try Fixture()
        await f.io.configure(roundedDates: roundedDates)
        let admitted = try await f.service.submit(imageURLs: photos, provider: provider)
        let result = try await f.service.waitForCompletion(admitted.id)
        #expect(result.kind == .voiceTranscription)
        #expect(result.outcome == .verified)
        #expect(result.batchProgress?.items.map(\.outcome) == [.draftSaved, .draftSaved, .draftSaved])
        #expect(await f.io.generated == photos)
        #expect(await f.io.saved.map(\.imageURL) == photos)
        #expect(await f.io.saved.allSatisfy { !$0.isApproved })
        #expect(try AutomationOperationRegistry(storageDirectory: f.root).inspect(result.id) == result)
        let archive = try String(contentsOf: f.root.appendingPathComponent("operations.json"), encoding: .utf8)
        #expect(!archive.contains("Editable text"))
        try await f.service.shutdown()
    }

    @Test("Invalid sets and shared sidecars reject admission without inference", arguments: [0, 9, 2])
    func invalidSets(count: Int) async throws {
        let f = try Fixture()
        let values = count == 2 ? [photos[0], photos[0].deletingPathExtension().appendingPathExtension("ARW")]
            : (0..<count).map { URL(fileURLWithPath: "/fixture/photo\($0).JPG") }
        await #expect(throws: AutomationVoiceTranscriptionBatchService.Failure.invalidPhotos) {
            try await f.service.submit(imageURLs: values, provider: provider)
        }
        #expect(try f.registry.records().isEmpty)
        #expect(await f.io.generated.isEmpty)
        #expect(await f.io.saved.isEmpty)
    }

    @Test("Stale targets and inference failure retain separate known outcomes", arguments: [false, true])
    func partialFailure(stale: Bool) async throws {
        let f = try Fixture()
        await f.io.configure(failGeneration: stale ? nil : photos[1], drift: stale ? photos[1] : nil)
        let record = try await f.service.submit(imageURLs: photos, provider: provider)
        let result = try await f.service.waitForCompletion(record.id)
        #expect(result.outcome == .failed)
        #expect(result.batchProgress?.items.map(\.outcome) == [.draftSaved, stale ? .stale : .failed, .draftSaved])
        #expect(await f.io.saved.map(\.imageURL) == [photos[0], photos[2]])
    }

    @Test("An uncertain save stops the suffix and retains the verified prefix")
    func uncertainSave() async throws {
        let f = try Fixture()
        await f.io.configure(failSave: photos[1])
        let record = try await f.service.submit(imageURLs: photos, provider: provider)
        let result = try await f.service.waitForCompletion(record.id)
        #expect(result.outcome == .recoveryRequired)
        #expect(!result.canRemove)
        #expect(result.batchProgress?.items.map(\.outcome) == [.draftSaved, .recoveryRequired, nil])
        #expect(await f.io.generated == [photos[0], photos[1]])
        #expect(await f.io.saved.map(\.imageURL) == [photos[0]])
    }

    @Test("Durable cancellation tears down active inference and preserves the queued suffix")
    func cancellationDuringRecognition() async throws {
        let f = try Fixture(), entered = Gate(), gate = Gate()
        await f.io.configure(gate: gate, entered: entered)
        let record = try await f.service.submit(imageURLs: photos, provider: provider)
        try await entered.wait()
        _ = try f.registry.requestCancellation(record.id)
        let result = try await f.service.waitForCompletion(record.id)
        #expect(result.state == .cancelled)
        #expect(result.outcome == .cancelled)
        #expect(result.batchProgress?.items.map(\.outcome) == [.cancelled, nil, nil])
        #expect(await f.io.generated == [photos[0]])
        #expect(await f.io.saved.isEmpty)
        try await f.service.shutdown()
    }

    @Test("Provider output cannot manufacture approval")
    func approvedOutputRefused() async throws {
        let f = try Fixture()
        await f.io.configure(invalidApproval: true)
        let record = try await f.service.submit(imageURLs: [photos[0]], provider: provider)
        #expect(try await f.service.waitForCompletion(record.id).outcome == .failed)
        #expect(await f.io.saved.isEmpty)
    }

    @Test("Cancellation after a verified save preserves that draft and stops the suffix")
    func cancellationAfterSave() async throws {
        let f = try Fixture()
        let base = f.io.dependencies, registry = f.registry
        let dependencies = AutomationVoiceTranscriptionBatchService.Dependencies(
            capture: base.capture, generate: base.generate, save: { draft, revision in
                let saved = try await base.save(draft, revision)
                let active = try #require(try registry.records().first)
                _ = try registry.requestCancellation(active.id)
                return saved
            })
        let service = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: dependencies)
        let record = try await service.submit(imageURLs: photos, provider: provider)
        let result = try await service.waitForCompletion(record.id)
        #expect(result.state == .cancelled)
        #expect(result.outcome == .cancelled)
        #expect(result.batchProgress?.items.map(\.outcome) == [.draftSaved, nil, nil])
        #expect(await f.io.saved.map(\.imageURL) == [photos[0]])
        #expect(await f.io.generated == [photos[0]])
    }

    @Test("A definite existing-review refusal does not hide successful neighboring drafts")
    func existingReviewRefusal() async throws {
        let f = try Fixture()
        let base = f.io.dependencies, existing = photos[1]
        let dependencies = AutomationVoiceTranscriptionBatchService.Dependencies(
            capture: base.capture, generate: base.generate, save: { draft, revision in
                if draft.imageURL == existing { throw VoiceMemoTranscriptionError.existingTranscript }
                return try await base.save(draft, revision)
            })
        let service = AutomationVoiceTranscriptionBatchService(registry: f.registry, dependencies: dependencies)
        let record = try await service.submit(imageURLs: photos, provider: provider)
        let result = try await service.waitForCompletion(record.id)
        #expect(result.outcome == .failed)
        #expect(result.batchProgress?.items.map(\.outcome) == [.draftSaved, .failed, .draftSaved])
        #expect(await f.io.saved.map(\.imageURL) == [photos[0], photos[2]])
    }

    @Test("Incorrect save read-back remains uncertain rather than verified")
    func incorrectSaveReceipt() async throws {
        let f = try Fixture()
        let base = f.io.dependencies
        let dependencies = AutomationVoiceTranscriptionBatchService.Dependencies(
            capture: base.capture, generate: base.generate, save: { draft, revision in
                var saved = try await base.save(draft, revision)
                saved.reviewedText = "Unexpected replacement"
                return saved
            })
        let service = AutomationVoiceTranscriptionBatchService(registry: f.registry, dependencies: dependencies)
        let record = try await service.submit(imageURLs: photos, provider: provider)
        let result = try await service.waitForCompletion(record.id)
        #expect(result.outcome == .recoveryRequired)
        #expect(result.batchProgress?.items.map(\.outcome) == [.recoveryRequired, nil, nil])
        #expect(await f.io.generated == [photos[0]])
    }

    @Test("Active work retains capacity and cannot be silently replaced")
    func capacity() async throws {
        let f = try Fixture(), entered = Gate(), gate = Gate()
        await f.io.configure(gate: gate, entered: entered)
        let record = try await f.service.submit(imageURLs: [photos[0]], provider: provider)
        try await entered.wait()
        await #expect(throws: AutomationOperationExecutionCoordinator.Failure.capacity) {
            try await f.service.submit(imageURLs: [photos[1]], provider: provider)
        }
        await gate.open()
        #expect(try await f.service.waitForCompletion(record.id).outcome == .verified)
        #expect(try f.registry.records().count == 1)
    }
}
