import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Native rooted transcription binding and consented execution")
struct MCPNativeVoiceTranscriptionBindingServiceTests {
    private struct Fixture: Sendable {
        let root: URL
        let photos: [URL]
        let memos: [URL]
        let relationships: [URL]
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let plans: MCPVoiceTranscriptionPlanStore
        let requests: MCPVoiceTranscriptionReviewRequestStore
        let request: MCPVoiceTranscriptionReviewRequestStore.Record
        let epoch: UUID
        var archive: URL { root.appendingPathComponent("requests/operations.json") }
    }
    private enum SyntheticFailure: Error { case readiness, inference }
    private actor Probe {
        var captures = 0
        var readiness = 0
        var generated: [URL] = []
        var finished = 0
        func capture() -> Int { captures += 1; return captures }
        func ready() -> Int { readiness += 1; return readiness }
        func generation(_ url: URL) -> Int { generated.append(url); return generated.count }
        func drained() { finished += 1 }
    }
    nonisolated private final class ReservationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        private var count = 0
        func enable() { lock.withLock { enabled = true } }
        func check(photos: [URL]) {
            guard lock.withLock({ enabled }) else { return }
            #expect(!Thread.isMainThread)
            for photo in photos {
                do {
                    let unexpected = try MCPProcessReservation.acquirePhoto(photo)
                    unexpected.release()
                    Issue.record("Whole rooted set was not reserved during native binding")
                } catch { lock.withLock { count += 1 } }
            }
        }
        var collisions: Int { lock.withLock { count } }
    }

    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        func expire() { lock.withLock { offset = 301 } }
        func now() -> Date { lock.withLock { Date().addingTimeInterval(offset) } }
    }

    private func fixture(provider: String = "appleSpeech", editorial: Bool = false, existingTranscript: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/native-transcription-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = MCPVoiceTranscriptionPlanStoreTests.Box()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authority)
        if editorial || existingTranscript {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".photo_metadata"), withIntermediateDirectories: false)
        }
        var photos: [URL] = [], memos: [URL] = [], relationships: [URL] = [], inputs: [MCPJSONValue] = []
        for index in 0..<2 {
            let photo = root.appendingPathComponent("frame\(index).jpg"), memo = root.appendingPathComponent("memo\(index).wav")
            let relationship = root.appendingPathComponent(".\(photo.lastPathComponent).voice-memo.json")
            try Data("photo \(index)".utf8).write(to: photo); try Data("wav \(index)".utf8).write(to: memo)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "reviewed",
                "imageFilename": photo.lastPathComponent, "memoFilename": memo.lastPathComponent]).write(to: relationship)
            if editorial || existingTranscript {
                var object: [String: Any] = ["schemaVersion": 1, "sourceFile": photo.lastPathComponent,
                    "pendingChanges": true, "metadata": ["caption": "Existing caption", "futureNested": ["retain": 42]],
                    "futureExtension": ["enabled": false, "empty": [] as [String]]]
                if existingTranscript { object["voiceMemoTranscript"] = ["preserve": "existing review"] }
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
                    to: root.appendingPathComponent(".photo_metadata/\(photo.lastPathComponent).meta.json"))
            }
            var input = try #require(facade.inspectPhotoVoiceMemo(path: photo.path).objectValue)
                .filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(photo.path)
            inputs.append(.object(input)); photos.append(photo); memos.append(memo); relationships.append(relationship)
        }
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: root.appendingPathComponent("plans"))
        let preview = try plans.prepare(arguments: ["photos": .array(inputs), "provider": .string(provider),
            "language": .string(provider == "appleSpeech" ? "en-US" : "auto"), "translate": .bool(false), "useGPU": .bool(false)], facade: facade)
        let requests = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let epoch = try requests.capacitySnapshot().epoch
        let request = try requests.request(requestID: UUID(), requestEpoch: epoch,
            planID: #require(preview.objectValue?["planID"]?.stringValue), plans: plans, facade: facade)
        return Fixture(root: root, photos: photos, memos: memos, relationships: relationships,
            authority: authority, facade: facade, plans: plans, requests: requests, request: request, epoch: epoch)
    }
    private nonisolated static func capture(_ image: URL) async throws -> AutomationVoiceTranscriptionBatchService.Input {
        guard case .available(let association) = try VoiceMemoTranscriptionService.lookupRegularAssociation(for: image) else {
            throw VoiceMemoTranscriptionError.relationshipUnavailable
        }
        return .init(imageURL: image, sourceRevision: try await SourceImageRevision.capture(at: image),
            association: association, memoRevision: try await SourceImageRevision.capture(at: association.memoURL),
            relationshipRevision: try VoiceMemoRelationshipRevision.capture(for: image))
    }
    private func service(_ f: Fixture, facade: MCPAutomationFacade? = nil,
        capture: @escaping @Sendable (URL) async throws -> AutomationVoiceTranscriptionBatchService.Input = Self.capture,
        readiness: @escaping @Sendable (AutomationVoiceTranscriptionProviderBinding) async throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init) -> MCPNativeVoiceTranscriptionBindingService {
        let dependencies = AutomationVoiceTranscriptionBatchService.Dependencies(capture: capture, generate: { _, _ in
            Issue.record("Read-only native binding attempted inference"); throw SyntheticFailure.inference
        }, save: { draft, _ in
            Issue.record("Read-only native binding attempted draft persistence"); return draft
        })
        let batches = AutomationVoiceTranscriptionBatchService(
            registry: AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations")), dependencies: dependencies)
        return MCPNativeVoiceTranscriptionBindingService(requests: f.requests, plans: f.plans,
            facade: facade ?? f.facade, batches: batches, readiness: readiness, now: now)
    }
    private func prepare(_ service: MCPNativeVoiceTranscriptionBindingService, _ f: Fixture) async throws -> MCPNativeVoiceTranscriptionBindingService.PreparedBinding {
        try await service.prepare(requestID: #require(UUID(uuidString: f.request.requestID)), requestEpoch: f.epoch,
            provider: .apple(Locale(identifier: "en_US")))
    }

    private nonisolated static func syntheticDraft(_ image: URL) async throws -> VoiceMemoTranscriptDraft {
        let input = try await capture(image)
        return .init(imageURL: image, memoURL: input.association.memoURL,
            memoByteCount: input.memoRevision.byteCount, memoSHA256: input.memoRevision.sha256,
            associationProfileIdentifier: input.association.profileIdentifier, localeIdentifier: "en_US",
            provider: "Apple on-device speech", providerModel: "System managed; exact version unavailable",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            generatedText: "Editable generated text", reviewedText: "Editable generated text")
    }

    private func executingService(_ f: Fixture, probe: Probe = Probe(),
        facade: MCPAutomationFacade? = nil,
        generate: @escaping @Sendable (URL) async throws -> VoiceMemoTranscriptDraft = Self.syntheticDraft,
        readiness: @escaping @Sendable (AutomationVoiceTranscriptionProviderBinding) async throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init) -> (MCPNativeVoiceTranscriptionBindingService, AutomationOperationRegistry) {
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let batches = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: .init(
            capture: Self.capture, generate: { image, _ in
                _ = await probe.generation(image)
                do {
                    let draft = try await generate(image)
                    await probe.drained()
                    return draft
                } catch { await probe.drained(); throw error }
            }, save: { draft, _ in
                Issue.record("Rooted execution must install with its retained anchored lease"); return draft
            }))
        return (MCPNativeVoiceTranscriptionBindingService(requests: f.requests, plans: f.plans,
            facade: facade ?? f.facade, batches: batches, readiness: readiness, now: now), registry)
    }

    private func transcriptURL(_ image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".photo_metadata/\(image.lastPathComponent).meta.json")
    }
    private func requireNoEffects(_ f: Fixture, archive: Data) throws {
        #expect(try Data(contentsOf: f.archive) == archive)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }
    private nonisolated static func mutate(_ f: Fixture, kind: String) throws {
        switch kind {
        case "source": try Data("changed photo".utf8).write(to: f.photos[0])
        case "wav": try Data("changed wav".utf8).write(to: f.memos[0])
        case "source-replacement", "wav-replacement":
            let url = kind == "source-replacement" ? f.photos[0] : f.memos[0]
            let bytes = try Data(contentsOf: url)
            try bytes.write(to: url, options: .atomic)
        case "relationship": try (Data(contentsOf: f.relationships[0]) + Data(" \n".utf8)).write(to: f.relationships[0])
        case "xmp": try Data("<changed/>".utf8).write(to: f.root.appendingPathComponent("frame0.xmp"))
        case "app":
            try FileManager.default.createDirectory(at: f.root.appendingPathComponent(".photo_metadata"), withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sourceFile": f.photos[0].lastPathComponent, "pendingChanges": true, "metadata": ["caption": "changed"]]).write(to: f.root.appendingPathComponent(".photo_metadata/frame0.jpg.meta.json"))
        case "private-directory":
            let current = f.root.appendingPathComponent(".photo_metadata"), retained = f.root.appendingPathComponent("old-private-carriers")
            try FileManager.default.moveItem(at: current, to: retained)
            try FileManager.default.copyItem(at: retained, to: current)
        case "new-private-directory":
            try FileManager.default.createDirectory(at: f.root.appendingPathComponent(".photo_metadata"), withIntermediateDirectories: false)
        case "authority": try f.authority.setEnabled(false)
        case "cancel": _ = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch)
        default: throw SyntheticFailure.readiness
        }
    }

    @Test("Exact ordered intent binds and revalidates with whole-set reservations on utility executor")
    func exactBinding() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive), planArchive = try Data(contentsOf: f.root.appendingPathComponent("plans/plans.json"))
        let probe = Probe(), reservations = ReservationProbe()
        let facade = MCPAutomationFacade(authorizationStore: f.authority,
            onVoiceMemoCaptureCheckpoint: { reservations.check(photos: f.photos) })
        let service = service(f, facade: facade, capture: { image in
            _ = await probe.capture(); return try await Self.capture(image)
        }, readiness: { binding in
            _ = await probe.ready(); reservations.enable()
            #expect(binding.identity == .apple(localeIdentifier: "en-us"))
        })
        let prepared = try await prepare(service, f)
        #expect(prepared.request == f.request)
        let expectedPaths = try f.request.intent.photos.map { try #require($0["path"]?.stringValue) }
        #expect(prepared.batch.imageURLs.map(\.path) == expectedPaths)
        try await service.revalidate(prepared)
        #expect(await probe.captures == 4); #expect(await probe.readiness == 2)
        #expect(reservations.collisions >= 8)
        try requireNoEffects(f, archive: archive)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("plans/plans.json")) == planArchive)
    }

    @Test("Any await-time rooted drift refuses native preparation", arguments: ["source", "wav", "source-replacement", "wav-replacement", "relationship", "xmp", "app", "authority", "cancel"])
    func preparationDrift(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = service(f, readiness: { _ in try Self.mutate(f, kind: kind) })
        await #expect(throws: (any Error).self) { try await prepare(service, f) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
        if kind != "cancel" { #expect(try f.requests.inspect(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch) == f.request) }
    }

    @Test("Mutation of an earlier photo during later native capture refuses the whole set")
    func preparationMutation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive), probe = Probe()
        let service = service(f, capture: { image in
            let input = try await Self.capture(image)
            if await probe.capture() == 2 { try Self.mutate(f, kind: "source") }
            return input
        })
        await #expect(throws: (any Error).self) { try await prepare(service, f) }
        try requireNoEffects(f, archive: archive)
    }

    @Test("Fresh readiness refusal never grants a binding or creates history")
    func failedReadiness() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive)
        let service = service(f, readiness: { _ in throw SyntheticFailure.readiness })
        await #expect(throws: SyntheticFailure.readiness) { try await prepare(service, f) }
        try requireNoEffects(f, archive: archive)
    }

    @Test("Revalidation rechecks readiness and refuses mutations after native recapture", arguments: ["source", "wav-replacement", "relationship", "xmp", "authority", "cancel", "refused"])
    func revalidationDrift(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe()
        let service = service(f, readiness: { _ in
            if await probe.ready() == 2 {
                if kind == "refused" { throw SyntheticFailure.readiness }
                try Self.mutate(f, kind: kind)
            }
        })
        let prepared = try await prepare(service, f)
        await #expect(throws: (any Error).self) { try await service.revalidate(prepared) }
        #expect(await probe.readiness == 2)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
    }

    @Test("Expiry after readiness refuses a still-retained original request")
    func expiredPlan() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive), clock = Clock(), probe = Probe()
        let service = service(f, readiness: { _ in _ = await probe.ready(); clock.expire() }, now: { clock.now() })
        await #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.expiredPlan) { try await prepare(service, f) }
        #expect(await probe.readiness == 1)
        try requireNoEffects(f, archive: archive)
    }

    @Test("Native same-path and same-content evidence with a different file identity refuses binding", arguments: ["source", "memo"])
    func wrongNativeIdentity(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive)
        let service = service(f, capture: { image in
            let input = try await Self.capture(image)
            func altered(_ revision: SourceImageRevision) -> SourceImageRevision {
                .init(canonicalURL: revision.canonicalURL, fileResourceIdentifier: .init(foundationValue: "other-file"),
                    filenameAtCreation: revision.filenameAtCreation, byteCount: revision.byteCount,
                    contentModificationDate: revision.contentModificationDate, pixelWidth: revision.pixelWidth,
                    pixelHeight: revision.pixelHeight, exifOrientation: revision.exifOrientation,
                    sha256: revision.sha256, hashCompletedAt: revision.hashCompletedAt)
            }
            return .init(imageURL: image, sourceRevision: kind == "source" ? altered(input.sourceRevision) : input.sourceRevision,
                association: input.association, memoRevision: kind == "memo" ? altered(input.memoRevision) : input.memoRevision,
                relationshipRevision: input.relationshipRevision)
        })
        await #expect(throws: MCPNativeVoiceTranscriptionBindingService.Failure.nativeInputChanged) { try await prepare(service, f) }
        try requireNoEffects(f, archive: archive)
    }

    @Test("Frozen Whisper artifact readiness runs on every native bind and revalidation", arguments: ["ready", "refused", "drift"])
    func whisperReadiness(mode: String) async throws {
        let f = try fixture(provider: "whisper"); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive), artifactProbe = Probe(), appProbe = Probe()
        let configuration = FFmpegWhisperTranscriptionProvider.Configuration(
            executable: .init(url: f.root.appendingPathComponent("selected-ffmpeg"), byteCount: 100, sha256: String(repeating: "a", count: 64)),
            buildIdentifier: "selected-build",
            model: .init(url: f.root.appendingPathComponent("selected-model.bin"), byteCount: 200, sha256: String(repeating: "b", count: 64)),
            modelIdentifier: "selected-model", language: "auto", useGPU: false, timeoutSeconds: 30)
        let native = FFmpegWhisperTranscriptionProvider(configuration: configuration, authorizeArtifacts: { retained in
            #expect(retained == configuration)
            let count = await artifactProbe.ready()
            if mode == "refused", count == 2 { throw SyntheticFailure.readiness }
            if mode == "drift", count == 1 { try Self.mutate(f, kind: "source") }
        }, run: { _ in
            Issue.record("Native preparation attempted Whisper recognition"); throw SyntheticFailure.inference
        })
        let service = service(f, readiness: { _ in _ = await appProbe.ready() })
        if mode == "drift" {
            await #expect(throws: (any Error).self) {
                try await service.prepare(requestID: UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch,
                    provider: .whisper(native), whisperKind: .curated)
            }
            #expect(await artifactProbe.readiness == 1)
        } else {
            let prepared = try await service.prepare(requestID: UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch,
                provider: .whisper(native), whisperKind: .curated)
            if mode == "refused" {
                await #expect(throws: SyntheticFailure.readiness) { try await service.revalidate(prepared) }
            } else { try await service.revalidate(prepared) }
            #expect(await artifactProbe.readiness == 2)
            #expect(await appProbe.readiness == (mode == "refused" ? 1 : 2))
        }
        try requireNoEffects(f, archive: archive)
    }

    @Test("Task cancellation during readiness refuses publication without effects")
    func taskCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let archive = try Data(contentsOf: f.archive)
        let service = service(f, readiness: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        let cancelled = Task { try await prepare(service, f) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try requireNoEffects(f, archive: archive)
    }

    @Test("Already admitted intent refuses preparation before native capture or readiness")
    func admittedRequest() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        _ = try f.requests.admit(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch, expected: f.request,
            operationID: UUID(), ownerID: UUID(), registry: registry)
        let archive = try Data(contentsOf: f.archive), operations = try Data(contentsOf: f.root.appendingPathComponent("operations/operations.json"))
        let probe = Probe()
        let service = service(f, capture: { image in
            _ = await probe.capture(); return try await Self.capture(image)
        }, readiness: { _ in _ = await probe.ready() })
        await #expect(throws: MCPNativeVoiceTranscriptionBindingService.Failure.invalidRequestState) { try await prepare(service, f) }
        #expect(await probe.captures == 0); #expect(await probe.readiness == 0)
        #expect(try Data(contentsOf: f.archive) == archive)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("operations/operations.json")) == operations)
        #expect(try registry.records().isEmpty)
    }

    @Test("Explicit native consent admits and links one exact ordered operation; rooted saves preserve editorial extensions", arguments: [false, true])
    func consentedExecution(editorial: Bool) async throws {
        let f = try fixture(editorial: editorial); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), (service, registry) = executingService(f, probe: probe)
        let source = try f.photos.map { try Data(contentsOf: $0) }, audio = try f.memos.map { try Data(contentsOf: $0) }
        let relationship = try f.relationships.map { try Data(contentsOf: $0) }
        let originals = try f.photos.map { image -> [String: Any]? in
            guard editorial else { return nil }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: transcriptURL(image))) as? [String: Any]
        }
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let linked = try f.requests.inspect(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch)
        #expect(linked.state == .linked && linked.operationID == accepted.id.uuidString.lowercased())
        #expect(linked.admission?.ownerID == accepted.ownerID.uuidString.lowercased())
        #expect(linked.intent == prepared.request.intent)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == .verified)
        #expect(completed.batchProgress?.items.map(\.outcome) == [.draftSaved, .draftSaved])
        #expect(await probe.generated == prepared.batch.imageURLs)
        #expect(try registry.records().count == 1)
        for (index, image) in f.photos.enumerated() {
            let data = try Data(contentsOf: transcriptURL(image))
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let transcript = try #require(object.removeValue(forKey: "voiceMemoTranscript") as? [String: Any])
            #expect(transcript["generatedText"] as? String == "Editable generated text")
            #expect(transcript["reviewedText"] as? String == "Editable generated text")
            #expect(transcript["approvedAt"] == nil)
            if let original = originals[index] { #expect(NSDictionary(dictionary: object) == NSDictionary(dictionary: original)) }
            let lease = try MCPProcessReservation.acquirePhoto(image); lease.release()
        }
        #expect(try f.photos.map { try Data(contentsOf: $0) } == source)
        #expect(try f.memos.map { try Data(contentsOf: $0) } == audio)
        #expect(try f.relationships.map { try Data(contentsOf: $0) } == relationship)
        await #expect(throws: (any Error).self) { try await service.submit(prepared: prepared, nativeConsent: true) }
        #expect(try registry.records().count == 1)
    }

    @Test("Declined native consent cannot consume request authority or create history")
    func declinedConsent() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), (service, _) = executingService(f, probe: probe)
        let archive = try Data(contentsOf: f.archive), prepared = try await prepare(service, f)
        await #expect(throws: MCPNativeVoiceTranscriptionBindingService.Failure.consentRequired) {
            try await service.submit(prepared: prepared, nativeConsent: false)
        }
        #expect(await probe.generated.isEmpty)
        try requireNoEffects(f, archive: archive)
    }

    @Test("Existing review is refused under rooted whole-set authority before durable admission or inference")
    func existingReview() async throws {
        let f = try fixture(existingTranscript: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), (service, registry) = executingService(f, probe: probe)
        let original = try f.photos.map { try Data(contentsOf: transcriptURL($0)) }
        let archive = try Data(contentsOf: f.archive), prepared = try await prepare(service, f)
        await #expect(throws: VoiceMemoTranscriptionError.existingTranscript) {
            try await service.submit(prepared: prepared, nativeConsent: true)
        }
        #expect(await probe.generated.isEmpty)
        #expect(try Data(contentsOf: f.archive) == archive)
        #expect(try registry.records().isEmpty)
        #expect(try f.photos.map { try Data(contentsOf: transcriptURL($0)) } == original)
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

    @Test("Post-consent await drift and failed readiness refuse admission", arguments: ["source", "wav-replacement", "relationship", "xmp", "app", "authority", "cancel", "refused", "expiry"])
    func admissionRefusal(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), clock = Clock()
        let (service, registry) = executingService(f, probe: probe, readiness: { _ in
            if await probe.ready() == 2 {
                if kind == "refused" { throw SyntheticFailure.readiness }
                if kind == "expiry" { clock.expire() }
                else { try Self.mutate(f, kind: kind) }
            }
        }, now: { clock.now() })
        let prepared = try await prepare(service, f)
        await #expect(throws: (any Error).self) { try await service.submit(prepared: prepared, nativeConsent: true) }
        #expect(await probe.generated.isEmpty)
        #expect(try registry.records().isEmpty)
        let current = try f.requests.inspect(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch)
        #expect(current.admission == nil && current.operationID == nil)
    }

    @Test("Carrier and authority drift during pending inference stop the retained complete set", arguments: ["source", "wav", "source-replacement", "wav-replacement", "relationship", "xmp", "app", "private-directory", "new-private-directory", "authority"])
    func executionDrift(kind: String) async throws {
        let f = try fixture(editorial: kind == "private-directory"); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe()
        let (service, _) = executingService(f, probe: probe, generate: { image in
            let draft = try await Self.syntheticDraft(image)
            try Self.mutate(f, kind: kind)
            try await Task.sleep(for: .milliseconds(300))
            return draft
        })
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == .failed)
        #expect(await probe.generated.count == 1)
        #expect(await probe.finished == 1)
        for photo in f.photos {
            if FileManager.default.fileExists(atPath: transcriptURL(photo).path) {
                let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: transcriptURL(photo))) as? [String: Any])
                #expect(object["voiceMemoTranscript"] == nil)
            }
            let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release()
        }
    }

    @Test("Cancellation between admission and durable linkage never schedules recognition and releases the whole set")
    func interruptedLinkage() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe()
        let facade = MCPAutomationFacade(authorizationStore: f.authority, onVoiceMemoCaptureCheckpoint: {
            do {
                let id = UUID(uuidString: f.request.requestID)!
                if try f.requests.inspect(id, requestEpoch: f.epoch).state == .admitted {
                    _ = try f.requests.cancel(id, requestEpoch: f.epoch)
                }
            } catch { Issue.record("Exact durable request cancellation checkpoint failed: \(error)") }
        })
        let (service, registry) = executingService(f, probe: probe, facade: facade)
        let prepared = try await prepare(service, f)
        await #expect(throws: (any Error).self) { try await service.submit(prepared: prepared, nativeConsent: true) }
        let record = try f.requests.inspect(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch)
        #expect(record.state == .admitted && record.admission != nil && record.cancellationRequestedAt != nil)
        #expect(record.linkedAt == nil)
        #expect(await probe.generated.isEmpty)
        let operations = try registry.records()
        #expect(operations.count == 1 && operations.first?.outcome == .failed)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL(f.photos[0]).path))
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

    @Test("Cancellation after enqueue but before entering retained work releases guarded photo leases")
    func cancellationBeforeWork() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let batches = AutomationVoiceTranscriptionBatchService(registry: registry, dependencies: .init(
            capture: Self.capture, generate: { image, _ in
                Issue.record("A durably cancelled queued operation entered recognition"); return try await Self.syntheticDraft(image)
            }, save: { draft, _ in
                Issue.record("A durably cancelled queued operation attempted persistence"); return draft
            }))
        let inputs = try await batches.prepare(imageURLs: f.photos)
        let reservation = try f.plans.retainExecutionPreview(planID: f.request.planID, facade: f.facade)
        let id = UUID()
        let hooks = AutomationVoiceTranscriptionBatchService.LifecycleHooks(operationID: id, admission: { _ in },
            didEnqueue: { record in _ = try registry.requestCancellation(record.id) }, cancellationCheck: { _ in })
        let accepted = try await batches.submit(prepared: inputs, provider: .apple(Locale(identifier: "en_US")), lifecycle: hooks,
            executionGuard: .init(check: {}, save: { draft, _ in
                Issue.record("The rooted save boundary ran for queued cancellation"); return draft
            }, finish: { reservation.release() }))
        let completed = try await batches.waitForCompletion(accepted.id)
        #expect(completed.outcome == .cancelled)
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

    @Test("Whole-set drift after rooted draft installation retains uncertain save evidence and stops the suffix")
    func uncertainRootedSave() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), originalSecondWAV = try Data(contentsOf: f.memos[1])
        let installedURL = transcriptURL(f.photos[0])
        let facade = MCPAutomationFacade(authorizationStore: f.authority, onCaptureCheckpoint: {
            do {
                guard FileManager.default.fileExists(atPath: installedURL.path),
                      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: installedURL)) as? [String: Any],
                      object["voiceMemoTranscript"] != nil,
                      try Data(contentsOf: f.memos[1]) == originalSecondWAV else { return }
                // This checkpoint runs after the first draft's actual rooted rename.
                // Its own bytes remain installed; the retained complete set is stale.
                try Data("changed second WAV after first installed draft".utf8).write(to: f.memos[1])
            } catch { Issue.record("Post-install drift checkpoint failed: \(error)") }
        })
        let (service, registry) = executingService(f, probe: probe, facade: facade)
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == .recoveryRequired)
        #expect(completed.batchProgress?.items.first?.outcome == .recoveryRequired)
        #expect(completed.batchProgress?.items.last?.outcome == nil)
        #expect(await probe.generated.count == 1)
        #expect(await probe.finished == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: installedURL)) as? [String: Any])
        let draft = try #require(object["voiceMemoTranscript"] as? [String: Any])
        #expect(draft["generatedText"] as? String == "Editable generated text")
        #expect(draft["reviewedText"] as? String == "Editable generated text")
        #expect(draft["approvedAt"] == nil)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL(f.photos[1]).path))
        let request = try f.requests.inspect(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch)
        #expect(request.state == .linked && request.operationID == accepted.id.uuidString.lowercased())
        await #expect(throws: (any Error).self) { try await service.submit(prepared: prepared, nativeConsent: true) }
        #expect(try registry.records().count == 1)
        #expect(await probe.generated.count == 1)
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

    @Test("Exact request cancellation drains inference and preserves a verified saved prefix", arguments: [false, true])
    func executionCancellation(savedPrefix: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe()
        let (service, registry) = executingService(f, probe: probe, generate: { image in
            let draft = try await Self.syntheticDraft(image)
            if !savedPrefix || image.lastPathComponent == "frame1.jpg" {
                _ = try f.requests.cancel(UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch)
                try await Task.sleep(for: .milliseconds(300))
            }
            return draft
        })
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == .cancelled)
        #expect(completed.cancellationRequestedAt != nil)
        #expect(await probe.finished == (savedPrefix ? 2 : 1))
        #expect(await probe.generated.count == (savedPrefix ? 2 : 1))
        #expect(FileManager.default.fileExists(atPath: transcriptURL(f.photos[0]).path) == savedPrefix)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL(f.photos[1]).path))
        #expect(try registry.records().count == 1)
        for photo in f.photos { let lease = try MCPProcessReservation.acquirePhoto(photo); lease.release() }
    }

    @Test("Readiness failure refuses further work and preserves any verified prefix", arguments: [false, true])
    func executionReadinessFailure(savedPrefix: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe()
        let (service, _) = executingService(f, probe: probe, readiness: { _ in
            if savedPrefix {
                if FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata/frame0.jpg.meta.json").path) {
                    throw SyntheticFailure.readiness
                }
            } else if await probe.finished > 0 { throw SyntheticFailure.readiness }
        })
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == .failed)
        #expect(await probe.generated.count == 1)
        #expect(FileManager.default.fileExists(atPath: transcriptURL(f.photos[0]).path) == savedPrefix)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL(f.photos[1]).path))
    }

    @Test("Admitted execution retains consent after preview expiry; failures keep the verified prefix", arguments: [false, true])
    func expiryAndFailedPrefix(failSecond: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = Probe(), clock = Clock()
        let (service, _) = executingService(f, probe: probe, generate: { image in
            clock.expire()
            if failSecond, image.lastPathComponent == "frame1.jpg" { throw SyntheticFailure.inference }
            return try await Self.syntheticDraft(image)
        }, now: { clock.now() })
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == (failSecond ? .failed : .verified))
        #expect(FileManager.default.fileExists(atPath: transcriptURL(f.photos[0]).path))
        #expect(FileManager.default.fileExists(atPath: transcriptURL(f.photos[1]).path) == !failSecond)
    }

    @Test("A generated draft cannot substitute the consented Apple locale or provider", arguments: ["locale", "provider", "model"])
    func mismatchedProviderDraft(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (service, _) = executingService(f, generate: { image in
            let original = try await Self.syntheticDraft(image)
            return .init(imageURL: original.imageURL, memoURL: original.memoURL, memoByteCount: original.memoByteCount,
                memoSHA256: original.memoSHA256, associationProfileIdentifier: original.associationProfileIdentifier,
                localeIdentifier: kind == "locale" ? "nb_NO" : original.localeIdentifier,
                provider: kind == "provider" ? "Substituted provider" : original.provider,
                providerModel: kind == "model" ? "Substituted model" : original.providerModel,
                generatedAt: original.generatedAt, generatedText: original.generatedText, reviewedText: original.reviewedText)
        })
        let prepared = try await prepare(service, f)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == .failed)
        #expect(!FileManager.default.fileExists(atPath: transcriptURL(f.photos[0]).path))
        #expect(!FileManager.default.fileExists(atPath: transcriptURL(f.photos[1]).path))
    }

    @Test("Whisper execution saves only exact consented runtime/model/options provenance", arguments: ["exact", "model", "runtime", "options", "missing"])
    func whisperExecution(mode: String) async throws {
        let f = try fixture(provider: "whisper"); defer { try? FileManager.default.removeItem(at: f.root) }
        let configuration = FFmpegWhisperTranscriptionProvider.Configuration(
            executable: .init(url: f.root.appendingPathComponent("selected-ffmpeg"), byteCount: 100, sha256: String(repeating: "a", count: 64)),
            buildIdentifier: "selected-build",
            model: .init(url: f.root.appendingPathComponent("selected-model.bin"), byteCount: 200, sha256: String(repeating: "b", count: 64)),
            modelIdentifier: "selected-model", language: "auto", useGPU: false, timeoutSeconds: 30)
        let artifactProbe = Probe()
        let native = FFmpegWhisperTranscriptionProvider(configuration: configuration, authorizeArtifacts: { current in
            #expect(current == configuration); _ = await artifactProbe.ready()
        }, run: { _ in throw SyntheticFailure.inference })
        let (service, _) = executingService(f, generate: { image in
            let input = try await Self.capture(image)
            let provenance = FFmpegWhisperTranscriptProvenance(buildIdentifier: mode == "runtime" ? "other-build" : configuration.buildIdentifier,
                executableSHA256: configuration.executable.sha256, executableByteCount: configuration.executable.byteCount,
                modelIdentifier: configuration.modelIdentifier,
                modelSHA256: mode == "model" ? String(repeating: "c", count: 64) : configuration.model.sha256,
                modelByteCount: configuration.model.byteCount, requestedLanguage: configuration.language,
                useGPU: mode == "options", segments: [.init(start: 0, end: 100, text: "Editable Whisper text")])
            return .init(imageURL: image, memoURL: input.association.memoURL, memoByteCount: input.memoRevision.byteCount,
                memoSHA256: input.memoRevision.sha256, associationProfileIdentifier: input.association.profileIdentifier,
                localeIdentifier: "auto", provider: "FFmpeg Whisper", providerModel: configuration.modelIdentifier,
                generatedAt: Date(), generatedText: "Editable Whisper text", reviewedText: "Editable Whisper text", whisperProvenance: mode == "missing" ? nil : provenance)
        })
        let prepared = try await service.prepare(requestID: UUID(uuidString: f.request.requestID)!, requestEpoch: f.epoch,
            provider: .whisper(native), whisperKind: .curated)
        let accepted = try await service.submit(prepared: prepared, nativeConsent: true)
        let completed = try await service.waitForCompletion(accepted.id)
        #expect(completed.outcome == (mode == "exact" ? .verified : .failed))
        #expect(await artifactProbe.readiness >= 3)
        for photo in f.photos { #expect(FileManager.default.fileExists(atPath: transcriptURL(photo).path) == (mode == "exact")) }
    }
}
