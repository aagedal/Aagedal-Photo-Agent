import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only native rooted transcription binding")
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
        func capture() -> Int { captures += 1; return captures }
        func ready() -> Int { readiness += 1; return readiness }
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

    private func fixture(provider: String = "appleSpeech") throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/native-transcription-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = MCPVoiceTranscriptionPlanStoreTests.Box()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authority)
        var photos: [URL] = [], memos: [URL] = [], relationships: [URL] = [], inputs: [MCPJSONValue] = []
        for index in 0..<2 {
            let photo = root.appendingPathComponent("frame\(index).jpg"), memo = root.appendingPathComponent("memo\(index).wav")
            let relationship = root.appendingPathComponent(".\(photo.lastPathComponent).voice-memo.json")
            try Data("photo \(index)".utf8).write(to: photo); try Data("wav \(index)".utf8).write(to: memo)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "reviewed",
                "imageFilename": photo.lastPathComponent, "memoFilename": memo.lastPathComponent]).write(to: relationship)
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
}
