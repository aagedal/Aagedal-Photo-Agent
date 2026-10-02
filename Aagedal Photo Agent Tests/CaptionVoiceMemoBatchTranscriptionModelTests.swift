import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Native Caption batch transcription consent") @MainActor
struct CaptionVoiceMemoBatchTranscriptionModelTests {
    private enum Injected: Error { case notReady, save, wait }

    private actor Gate {
        private var opened = false
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending.values { waiter.resume() }
        }
        func wait() async throws {
            if opened { return }
            let id = UUID()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    expire(id)
                }
            }
        }
        private func expire(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: Injected.wait) }
    }

    private actor WhisperRuns {
        var requests: [FFmpegWhisperJobRequest] = []
        func run(_ request: FFmpegWhisperJobRequest) throws -> FFmpegWhisperJobResult {
            requests.append(request)
            return .init(request: request, transcript: try FFmpegWhisperJSONParser.parse(
                Data("{\"start\":0,\"end\":25,\"text\":\"Whisper draft\"}\n".utf8)))
        }
    }

    private actor IO {
        var generated: [URL] = []
        var saved: [URL] = []
        var languages: [String] = []
        var existing = Set<URL>()
        var ready = true
        var drift: URL?
        var failSave: URL?
        var blocked: URL?
        var entered: Gate?
        var teardownEntered: Gate?
        var teardownRelease: Gate?
        var transientWaitFailure = false
        var readinessChecks = 0

        func configure(existing: Set<URL> = [], ready: Bool = true, drift: URL? = nil,
                       failSave: URL? = nil, blocked: URL? = nil, entered: Gate? = nil,
                       teardownEntered: Gate? = nil, teardownRelease: Gate? = nil,
                       transientWaitFailure: Bool = false) {
            self.existing = existing
            self.ready = ready
            self.drift = drift
            self.failSave = failSave
            self.blocked = blocked
            self.entered = entered
            self.teardownEntered = teardownEntered
            self.teardownRelease = teardownRelease
            self.transientWaitFailure = transientWaitFailure
        }
        func validate(_ provider: AutomationVoiceTranscriptionBatchService.Provider) throws {
            readinessChecks += 1
            guard ready else { throw Injected.notReady }
            guard case .apple = provider else { throw Injected.notReady }
        }
        func hasExistingReview(_ url: URL) -> Bool { existing.contains(url) }
        func capture(_ url: URL) -> AutomationVoiceTranscriptionBatchService.Input {
            CaptionVoiceMemoBatchTranscriptionModelTests.input(url, changed: drift == url)
        }
        func generate(_ url: URL, provider: AutomationVoiceTranscriptionBatchService.Provider) async throws -> VoiceMemoTranscriptDraft {
            generated.append(url)
            if case .apple(let locale) = provider { languages.append(locale.identifier) }
            if blocked == url {
                await entered?.open()
                do {
                    while true { try await Task.sleep(for: .milliseconds(10)) }
                } catch {
                    await teardownEntered?.open()
                    try await teardownRelease?.wait()
                    throw error
                }
            }
            return CaptionVoiceMemoBatchTranscriptionModelTests.draft(url)
        }
        func save(_ draft: VoiceMemoTranscriptDraft) throws -> VoiceMemoTranscriptDraft {
            if failSave == draft.imageURL { throw Injected.save }
            saved.append(draft.imageURL)
            return draft
        }
        func failWaitOnceIfConfigured() throws {
            if transientWaitFailure {
                transientWaitFailure = false
                throw Injected.wait
            }
        }
        nonisolated var batchDependencies: AutomationVoiceTranscriptionBatchService.Dependencies {
            .init(capture: { await self.capture($0) },
                  generate: { try await self.generate($0, provider: $1) },
                  save: { draft, _ in try await self.save(draft) })
        }
    }

    private final class Fixture: Sendable {
        let root: URL
        let registry: AutomationOperationRegistry
        let io: IO
        let service: AutomationVoiceTranscriptionBatchService
        init() throws {
            let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(canonical) }
            root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("caption-batch-model-\(UUID())")
            registry = AutomationOperationRegistry(storageDirectory: root)
            io = IO()
            service = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: io.batchDependencies)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var dependencies: CaptionVoiceMemoBatchTranscriptionModel.Dependencies {
            let io = io, registry = registry, service = service
            return .init(prepare: { try await service.prepare(imageURLs: $0) },
                         validateProvider: { try await io.validate($0) },
                         hasExistingReview: { await io.hasExistingReview($0) },
                         submit: { try await service.submit(prepared: $0, provider: $1) },
                         inspect: { try registry.inspect($0) },
                         wait: {
                             try await io.failWaitOnceIfConfigured()
                             return try await service.waitForCompletion($0)
                         },
                         cancel: { try registry.requestCancellation($0) })
        }
    }

    private final class Capacity {
        var held = false
        var starts = 0
        var finishes = 0
        func begin() -> Bool {
            guard !held else { return false }
            held = true
            starts += 1
            return true
        }
        func end() { held = false; finishes += 1 }
    }

    private var photos: [URL] {
        ["first", "second", "third"].map { URL(fileURLWithPath: "/fixture/\($0).JPG") }
    }
    private var provider: AutomationVoiceTranscriptionBatchService.Provider { .apple(Locale(identifier: "en-US")) }
    private func model(_ fixture: Fixture, capacity: Capacity = Capacity()) -> CaptionVoiceMemoBatchTranscriptionModel {
        CaptionVoiceMemoBatchTranscriptionModel(dependencies: fixture.dependencies,
                                               beginExecution: { capacity.begin() }, endExecution: { capacity.end() })
    }
    private func prepare(_ model: CaptionVoiceMemoBatchTranscriptionModel, photos: [URL]? = nil,
                         reviewBusy: Bool = false, providerBusy: Bool = false) async {
        await model.prepare(imageURLs: photos ?? self.photos, provider: provider,
                            providerTitle: "Apple Speech", languageTitle: "English (United States)",
                            reviewOrSaveBusy: reviewBusy, providerBusy: providerBusy)
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
                     association: .init(profileIdentifier: "test", imageURL: url, memoURL: memo), memoRevision: revision(memo),
                     relationshipRevision: .init(url: VoiceMemoCompanionRepository().recordURL(for: url), revision: String(repeating: "c", count: 64)))
    }
    private nonisolated static func draft(_ url: URL) -> VoiceMemoTranscriptDraft {
        let input = input(url)
        return .init(imageURL: url, memoURL: input.association.memoURL,
                     memoByteCount: input.memoRevision.byteCount, memoSHA256: input.memoRevision.sha256,
                     associationProfileIdentifier: "test", localeIdentifier: "en-US", provider: "Test", providerModel: "Test",
                     generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     generatedText: "Review this text", reviewedText: "Review this text")
    }

    @Test("Preparation and declined consent create no retained operation or draft")
    func preConsentIsReadOnly() async throws {
        let f = try Fixture(), capacity = Capacity(), model = model(f, capacity: capacity)
        await prepare(model)
        #expect(model.snapshot?.imageURLs == photos)
        #expect(!FileManager.default.fileExists(atPath: f.root.path))
        await model.confirm(consent: false, reviewOrSaveBusy: false, providerBusy: false)
        #expect(model.snapshot != nil)
        #expect(await f.io.generated.isEmpty)
        #expect(await f.io.saved.isEmpty)
        #expect(try f.registry.records().isEmpty)
        #expect(capacity.starts == 0)
        model.dismissConfirmation()
        #expect(model.snapshot == nil)
    }

    @Test("Starting and closing confirmation preserves background work and records Activity results")
    func backgroundActivity() async throws {
        let f = try Fixture(), capacity = Capacity(), history = ActivityHistoryStore()
        let model = CaptionVoiceMemoBatchTranscriptionModel(dependencies: f.dependencies, activityHistory: history,
            beginExecution: { capacity.begin() }, endExecution: { capacity.end() })
        await prepare(model)
        #expect(model.start(consent: true, reviewOrSaveBusy: false, providerBusy: false))
        #expect(model.isRunning)
        #expect(capacity.held)
        model.dismissConfirmation()
        #expect(model.activeImageURLs == photos)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.isRunning)
        let entry = try #require(history.entries.first { $0.kind == .transcription && $0.files.map(\.fileName) == photos.map(\.lastPathComponent) })
        #expect(entry.successCount == photos.count)
        #expect(entry.isClean)
        #expect(entry.files.allSatisfy { $0.statusDetail == "Transcript saved" })
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.files.map(\.statusDetail) == entry.files.map(\.statusDetail))
        #expect(!capacity.held)
        #expect(capacity.finishes == 1)
    }

    @Test("The confirmed ordered targets and language do not track later selection changes")
    func frozenSnapshot() async throws {
        let f = try Fixture(), model = model(f)
        var selected = Array(photos.prefix(2)).reversed().map { $0 }
        let consented = selected
        await prepare(model, photos: selected)
        selected = [photos[2]]
        await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false)
        #expect(model.activeImageURLs == consented)
        #expect(model.savedDraftImageURLs == consented)
        #expect(await f.io.generated == consented)
        #expect(await f.io.languages == ["en-US", "en-US"])
        #expect(model.record?.outcome == .verified)
        #expect(model.completionToken == 1)
        #expect(model.activeProviderTitle == "Apple Speech")
        #expect(try AutomationOperationRegistry(storageDirectory: f.root).inspect(#require(model.record?.id)) == model.record)
    }

    @Test("Explicit Whisper parameters reach only the consented provider without Apple fallback")
    func frozenWhisperProvider() async throws {
        let f = try Fixture(), runs = WhisperRuns()
        let configuration = FFmpegWhisperTranscriptionProvider.Configuration(
            executable: .init(url: URL(fileURLWithPath: "/fixture/ffmpeg"), byteCount: 10, sha256: String(repeating: "a", count: 64)),
            buildIdentifier: "test-build", model: .init(url: URL(fileURLWithPath: "/fixture/model.bin"),
                byteCount: 20, sha256: String(repeating: "b", count: 64)),
            modelIdentifier: "test-model", language: "no", useGPU: true, timeoutSeconds: 30, translate: true)
        let whisper = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in }, run: { try await runs.run($0) })
        let batch = AutomationVoiceTranscriptionBatchService(registry: f.registry, dependencies: .init(
            capture: { await f.io.capture($0) }, generate: { url, provider in
                guard case .whisper(let admitted) = provider else {
                    Issue.record("An explicit Whisper batch must never invoke Apple Speech")
                    throw Injected.notReady
                }
                let input = Self.input(url)
                let result = try await admitted.transcribe(audio: .init(url: input.association.memoURL,
                    byteCount: input.memoRevision.byteCount, sha256: input.memoRevision.sha256))
                return .init(imageURL: url, memoURL: input.association.memoURL,
                    memoByteCount: input.memoRevision.byteCount, memoSHA256: input.memoRevision.sha256,
                    associationProfileIdentifier: input.association.profileIdentifier, localeIdentifier: "no",
                    provider: "FFmpeg Whisper", providerModel: "test-model", generatedAt: Date(),
                    generatedText: result.text, reviewedText: result.text,
                    whisperProvenance: result.provenance)
            }, save: { value, _ in try await f.io.save(value) }))
        let base = f.dependencies
        let dependencies = CaptionVoiceMemoBatchTranscriptionModel.Dependencies(
            prepare: { try await batch.prepare(imageURLs: $0) }, validateProvider: { provider in
                guard case .whisper(let admitted) = provider else { throw Injected.notReady }
                try await admitted.validateReadiness()
            }, hasExistingReview: base.hasExistingReview,
            submit: { try await batch.submit(prepared: $0, provider: $1) },
            inspect: base.inspect, wait: { try await batch.waitForCompletion($0) }, cancel: base.cancel)
        let model = CaptionVoiceMemoBatchTranscriptionModel(dependencies: dependencies,
            beginExecution: { true }, endExecution: {})
        await model.prepare(imageURLs: Array(photos.prefix(2)), provider: .whisper(whisper),
            providerTitle: "Whisper", languageTitle: "no; translate to English; GPU requested",
            reviewOrSaveBusy: false, providerBusy: false)
        #expect(model.snapshot != nil)
        #expect(await runs.requests.isEmpty)
        await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false)
        let requests = await runs.requests
        #expect(requests.map(\.audio.url) == photos.prefix(2).map { $0.deletingPathExtension().appendingPathExtension("WAV") })
        #expect(requests.allSatisfy { $0.language == "no" && $0.translate && $0.useGPU })
        #expect(model.record?.outcome == .verified)
        #expect(model.savedDraftImageURLs == Array(photos.prefix(2)))
        #expect(await f.io.generated.isEmpty)
    }

    @Test("Existing transcripts keep the captured reset targets and both selected transcripts can be reset")
    func resetSelectionAfterRefusal() async throws {
        let f = try Fixture(), model = model(f)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchReset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["one.JPG", "two.JPG"].map { root.appendingPathComponent($0) }
        let sidecars = MetadataSidecarService()
        for url in urls {
            let transcript = VoiceMemoTranscriptRecord(sourceImageFilename: url.lastPathComponent,
                sourceMemoFilename: url.deletingPathExtension().lastPathComponent + ".WAV",
                memoByteCount: 42, memoSHA256: String(repeating: "a", count: 64),
                associationProfileIdentifier: "test", localeIdentifier: "no", provider: "Test",
                providerModel: "Test", generatedAt: .now, generatedText: "Transcript", reviewedText: "Transcript")
            _ = try await sidecars.saveVoiceMemoTranscriptSerialized(transcript, for: url, in: root)
        }
        await f.io.configure(existing: Set(urls))
        await prepare(model, photos: urls)
        #expect(model.snapshot == nil)
        #expect(model.errorMessage != nil)
        #expect(model.selectedImageURLs == urls)
        #expect(await model.resetTranscripts(imageURLs: model.selectedImageURLs))
        #expect(model.selectedImageURLs == urls)
        for url in urls { #expect(try sidecars.loadVoiceMemoTranscript(for: url, in: root) == nil) }
        await f.io.configure(existing: [])
        await prepare(model, photos: model.selectedImageURLs)
        #expect(model.snapshot?.imageURLs == urls)
    }

    @Test("Existing reviews and missing readiness refuse preparation", arguments: [false, true])
    func readinessAndReviewRefusal(existing: Bool) async throws {
        let f = try Fixture(), model = model(f)
        await f.io.configure(existing: existing ? [photos[0]] : [], ready: existing)
        await prepare(model)
        #expect(model.snapshot == nil)
        #expect(model.errorMessage != nil)
        #expect(await f.io.generated.isEmpty)
        #expect(try f.registry.records().isEmpty)
    }

    @Test("Review/save or provider capacity blocks preparation and later confirmation", arguments: [false, true])
    func callerBusy(providerBusy: Bool) async throws {
        let f = try Fixture(), capacity = Capacity(), model = model(f, capacity: capacity)
        await prepare(model, reviewBusy: !providerBusy, providerBusy: providerBusy)
        #expect(model.snapshot == nil)
        await prepare(model)
        await model.confirm(consent: true, reviewOrSaveBusy: !providerBusy, providerBusy: providerBusy)
        #expect(model.snapshot != nil)
        #expect(capacity.starts == 0)
        #expect(try f.registry.records().isEmpty)
    }

    @Test("An atomic provider reservation refusal keeps the consent snapshot")
    func executionReservationRefusal() async throws {
        let f = try Fixture(), capacity = Capacity(), model = model(f, capacity: capacity)
        await prepare(model)
        capacity.held = true
        await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false)
        #expect(model.snapshot != nil)
        #expect(!model.isRunning)
        #expect(capacity.starts == 0)
        #expect(capacity.finishes == 0)
        #expect(try f.registry.records().isEmpty)
        capacity.held = false
    }

    @Test("Cancellation during final readiness stops before retained admission")
    func cancellationBeforeSubmission() async throws {
        let f = try Fixture(), capacity = Capacity(), entered = Gate(), release = Gate()
        let base = f.dependencies
        let dependencies = CaptionVoiceMemoBatchTranscriptionModel.Dependencies(
            prepare: base.prepare, validateProvider: { provider in
                try await base.validateProvider(provider)
                if await f.io.readinessChecks > 1 {
                    await entered.open()
                    try await release.wait()
                }
            }, hasExistingReview: base.hasExistingReview, submit: base.submit,
            inspect: base.inspect, wait: base.wait, cancel: base.cancel)
        let model = CaptionVoiceMemoBatchTranscriptionModel(dependencies: dependencies,
            beginExecution: { capacity.begin() }, endExecution: { capacity.end() })
        await prepare(model)
        let run = Task { await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false) }
        try await entered.wait()
        await model.requestCancellation()
        #expect(model.isRunning)
        #expect(capacity.held)
        await release.open()
        await run.value
        #expect(!model.isRunning)
        #expect(!capacity.held)
        #expect(model.record == nil)
        #expect(model.statusMessage.contains("before transcription started"))
        #expect(await f.io.generated.isEmpty)
        #expect(try f.registry.records().isEmpty)
    }

    @Test("Invalid and shared sidecar selections cannot reach confirmation", arguments: [0, 9, 2, 3])
    func invalidSelection(count: Int) async throws {
        let f = try Fixture(), model = model(f)
        let urls: [URL]
        if count == 2 { urls = [photos[0], photos[0]] }
        else if count == 3 { urls = [photos[0], photos[0].deletingPathExtension().appendingPathExtension("ARW")] }
        else { urls = (0..<count).map { URL(fileURLWithPath: "/fixture/photo\($0).JPG") } }
        await prepare(model, photos: urls)
        #expect(model.snapshot == nil)
        #expect(await f.io.generated.isEmpty)
        #expect(try f.registry.records().isEmpty)
    }

    @Test("Changed source, revoked readiness, and newly created reviews refuse confirmation", arguments: [0, 1, 2])
    func revalidateBeforeAdmission(change: Int) async throws {
        let f = try Fixture(), capacity = Capacity(), model = model(f, capacity: capacity)
        await prepare(model)
        await f.io.configure(existing: change == 2 ? [photos[1]] : [], ready: change != 1,
                             drift: change == 0 ? photos[1] : nil)
        await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false)
        #expect(!model.isRunning)
        #expect(!capacity.held)
        #expect(capacity.finishes == 1)
        #expect(model.errorMessage != nil)
        #expect(model.statusMessage.contains("Batch was not admitted"))
        #expect(await f.io.generated.isEmpty)
        #expect(try f.registry.records().isEmpty)
    }

    @Test("Cancellation keeps verified drafts and capacity until provider teardown drains")
    func cancellationRetainsPrefixAndCapacity() async throws {
        let f = try Fixture(), capacity = Capacity(), model = model(f, capacity: capacity)
        let entered = Gate(), teardownEntered = Gate(), teardownRelease = Gate()
        await f.io.configure(blocked: photos[1], entered: entered, teardownEntered: teardownEntered,
                             teardownRelease: teardownRelease)
        await prepare(model)
        let run = Task { await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false) }
        try await entered.wait()
        // A cancelled SwiftUI caller cannot release admitted work or provider capacity.
        run.cancel()
        await model.requestCancellation()
        try await teardownEntered.wait()
        #expect(model.isRunning)
        #expect(model.isRequestingCancellation)
        #expect(capacity.held)
        #expect(capacity.finishes == 0)
        #expect(model.statusMessage.contains("Waiting for the current item to stop safely"))
        await teardownRelease.open()
        await run.value
        #expect(!model.isRunning)
        #expect(!capacity.held)
        #expect(capacity.finishes == 1)
        #expect(model.record?.outcome == .cancelled)
        #expect(model.savedDraftImageURLs == [photos[0]])
        #expect(await f.io.generated == Array(photos.prefix(2)))
        #expect(model.record?.batchProgress?.items.map(\.outcome) == [.draftSaved, .cancelled, nil])
        #expect(model.statusMessage.contains("Saved drafts remain available"))
        #expect(model.completionToken == 1)
    }

    @Test("An uncertain save exposes only known saved drafts for Caption refresh")
    func uncertainSave() async throws {
        let f = try Fixture(), model = model(f)
        await f.io.configure(failSave: photos[1])
        await prepare(model)
        await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false)
        #expect(model.record?.outcome == .recoveryRequired)
        #expect(model.savedDraftImageURLs == [photos[0]])
        #expect(await f.io.generated == Array(photos.prefix(2)))
        #expect(model.statusMessage.contains("uncertain save"))
        #expect(!model.statusMessage.contains("Batch cancelled"))
        #expect(model.completionToken == 1)
    }

    @Test("A transient retained wait error does not claim completion or release capacity")
    func transientWaitFailure() async throws {
        let f = try Fixture(), capacity = Capacity(), model = model(f, capacity: capacity)
        let entered = Gate(), teardownEntered = Gate(), teardownRelease = Gate()
        await f.io.configure(blocked: photos[0], entered: entered, teardownEntered: teardownEntered,
                             teardownRelease: teardownRelease, transientWaitFailure: true)
        await prepare(model)
        let run = Task { await model.confirm(consent: true, reviewOrSaveBusy: false, providerBusy: false) }
        try await entered.wait()
        #expect(model.isRunning)
        #expect(capacity.held)
        #expect(model.completionToken == 0)
        await model.requestCancellation()
        try await teardownEntered.wait()
        await teardownRelease.open()
        await run.value
        #expect(model.record?.outcome == .cancelled)
        #expect(capacity.finishes == 1)
        #expect(model.completionToken == 1)
    }
}
