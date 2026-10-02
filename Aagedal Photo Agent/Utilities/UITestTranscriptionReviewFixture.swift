import Foundation
import CryptoKit

/// Explicit UI-test seam. Real durable intent and source validation, isolated from
/// production authorization, provider state and archives. Execution uses only synthetic recognition.
enum UITestTranscriptionReviewFixture {
    /// Bootstrap disposable retained intent before the real signed listener starts.
    /// This does not select a review, grant consent or inject a channel authenticator.
    static func initializeForNativeInvocation() async throws {
        guard let service = currentServiceForModel() else { throw Failure.invalidFolder }
        _ = try await service.requests()
    }

    static func currentServiceForModel() -> (any AutomationTranscriptionReviewServing)? {
        service(configuration: .current, environment: ProcessInfo.processInfo.environment)
    }

    static func service(configuration: UITestLaunchConfiguration, environment: [String: String]) -> (any AutomationTranscriptionReviewServing)? {
        guard configuration.isEnabled, environment["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW"] == "1" else { return nil }
        return Worker(folder: configuration.folderURL,
            includesRetainedIntent: environment["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW_CAPACITY"] == "1",
            executionMode: environment["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW_EXECUTION"])
    }

    /// Two explicit launch gates isolate synthetic providers from host preferences/assets.
    static func currentProviderForReview() -> FFmpegWhisperTranscriptionProvider? {
        let configuration = UITestLaunchConfiguration.current
        let environment = ProcessInfo.processInfo.environment
        guard configuration.isEnabled, environment["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW"] == "1",
              let mode = environment["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW_EXECUTION"],
              let folder = configuration.folderURL else { return nil }
        return try? provider(root: folder.resolvingSymlinksInPath(), mode: mode)
    }
    nonisolated static func provider(root: URL, mode: String = "complete") throws -> FFmpegWhisperTranscriptionProvider {
        let input: @Sendable (String) throws -> FFmpegWhisperJobInput = { name in
            let url = root.appendingPathComponent(name), data = try Data(contentsOf: url)
            return .init(url: url, byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let config = FFmpegWhisperTranscriptionProvider.Configuration(executable: try input("synthetic-review-runtime"),
            buildIdentifier: "isolated-ui-runtime", model: try input("synthetic-review-model"),
            modelIdentifier: "isolated-ui-model", language: "auto", useGPU: true, timeoutSeconds: 30, translate: true)
        return .init(configuration: config, authorizeArtifacts: { retained in
            guard retained == config, try input("synthetic-review-runtime") == config.executable,
                  try input("synthetic-review-model") == config.model else { throw Failure.invalidPlan }
        }, run: { request in
            if mode == "blockSecond", request.audio.url.lastPathComponent == "transcription-review-1.wav" {
                try Data("synthetic transcription active".utf8).write(to: root.appendingPathComponent("transcription-review-active.txt"))
                while true { try await Task.sleep(for: .milliseconds(50)) }
            }
            return .init(request: request, transcript: .init(segments: [.init(start: 0, end: 10, text: "Synthetic review transcript")],
                editableText: "Synthetic review transcript"))
        })
    }
    private nonisolated static func silentWAV() -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let size: UInt32 = 3200
        data.append(Data("RIFF".utf8)); append(size + 36); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16000))
        append(UInt32(32000)); append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8))
        append(size); data.append(Data(repeating: 0, count: Int(size)))
        return data
    }

    nonisolated final class ConfigurationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? { lock.withLock { data } }
        func write(_ value: Data?) { lock.withLock { data = value } }
    }
    private nonisolated struct Manifest: Codable {
        let requestID: String
        let requestEpoch: String
        let planID: String
        let photoPaths: [String]
        let retainedRequestID: String?
    }
    enum Failure: Error { case invalidFolder, invalidPlan }

    /// Initialization also runs on the filesystem executor, never in SwiftUI init.
    private actor Worker: AutomationTranscriptionReviewServing {
        nonisolated let filesystemQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.ui-test-transcription-review", qos: .utility)
        nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
        let folder: URL?
        let includesRetainedIntent: Bool
        let executionMode: String?
        private var underlying: AutomationTranscriptionReviewService?
        init(folder: URL?, includesRetainedIntent: Bool, executionMode: String?) {
            self.folder = folder; self.includesRetainedIntent = includesRetainedIntent; self.executionMode = executionMode
        }

        private func service() throws -> AutomationTranscriptionReviewService {
            if let underlying { return underlying }
            guard let folder else { throw Failure.invalidFolder }
            let root: URL
#if DEBUG
            if let isolated = UITestNativeInvocationConfiguration.current {
                guard isolated.rootURL.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() else { throw Failure.invalidFolder }
                root = isolated.rootURL
            } else { root = folder.resolvingSymlinksInPath() }
#else
            root = folder.resolvingSymlinksInPath()
#endif
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                throw Failure.invalidFolder
            }
            let box = ConfigurationBox()
            let memoryAuthority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
            let authorityURL = root.appendingPathComponent("transcription-review-authorization.json")
            let manifestURL = root.appendingPathComponent("transcription-review-manifest.json")
            let authority: MCPAuthorizationStore
#if DEBUG
            if let isolated = UITestNativeInvocationConfiguration.current {
                guard isolated.rootURL == root else { throw Failure.invalidFolder }
                if !FileManager.default.fileExists(atPath: manifestURL.path) {
                    try memoryAuthority.addRoot(root); try memoryAuthority.setEnabled(true)
                    guard let data = box.read() else { throw Failure.invalidPlan }
                    try data.write(to: authorityURL, options: .withoutOverwriting)
                }
                authority = isolated.authorizationStore
            } else { authority = memoryAuthority }
#else
            authority = memoryAuthority
#endif
            let facade = MCPAutomationFacade(authorizationStore: authority)
            let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: root.appendingPathComponent("transcription-review-plans"))
            let requests = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root.appendingPathComponent("transcription-review-requests"))
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                box.write(try Data(contentsOf: authorityURL))
                _ = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            } else {
                if !(try authority.load().isEnabled) {
                    try authority.addRoot(root); try authority.setEnabled(true)
                }
                var inputs: [MCPJSONValue] = [], paths: [String] = []
                for index in 1...2 {
                    let photo = root.appendingPathComponent("transcription-review-\(index)-å.jpg")
                    let memo = root.appendingPathComponent("transcription-review-\(index).wav")
                    try Data("isolated photo \(index)".utf8).write(to: photo, options: .withoutOverwriting)
                    try UITestTranscriptionReviewFixture.silentWAV().write(to: memo, options: .withoutOverwriting)
                    let relationship = root.appendingPathComponent(".\(photo.lastPathComponent).voice-memo.json")
                    try JSONSerialization.data(withJSONObject: ["schemaVersion": 2,
                        "profileIdentifier": "custom-reviewed-profile", "imageFilename": photo.lastPathComponent,
                        "memoFilename": memo.lastPathComponent]).write(to: relationship, options: .withoutOverwriting)
                    guard let evidence = try facade.inspectPhotoVoiceMemo(path: photo.path).objectValue else { throw Failure.invalidPlan }
                    var input = evidence.filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
                    input["path"] = .string(photo.path); inputs.append(.object(input)); paths.append(photo.path)
                }
                // Reverse order proves the review follows intent order, not lease sort order.
                let preview = try plans.prepare(arguments: ["photos": .array(Array(inputs.reversed())),
                    "provider": .string("whisper"), "language": .string("auto"), "translate": .bool(true), "useGPU": .bool(true)], facade: facade)
                guard let planID = preview.objectValue?["planID"]?.stringValue else { throw Failure.invalidPlan }
                let epoch = try requests.capacitySnapshot().epoch, requestID = UUID()
                _ = try requests.request(requestID: requestID, requestEpoch: epoch, planID: planID, plans: plans, facade: facade)
                let retainedID = includesRetainedIntent ? UUID() : nil
                if let retainedID {
                    _ = try requests.request(requestID: retainedID, requestEpoch: epoch, planID: planID, plans: plans, facade: facade)
                }
                let data = try JSONEncoder().encode(authority.load())
                // The installed-helper fixture authority writes directly to this file.
                // Other fixtures retain their in-memory authority until initialization ends.
                if !FileManager.default.fileExists(atPath: authorityURL.path) {
                    try data.write(to: authorityURL, options: .withoutOverwriting)
                }
                try JSONEncoder().encode(Manifest(requestID: requestID.uuidString.lowercased(), requestEpoch: epoch.uuidString.lowercased(),
                    planID: planID, photoPaths: Array(paths.reversed()),
                    retainedRequestID: retainedID?.uuidString.lowercased())).write(to: manifestURL, options: .withoutOverwriting)
            }
            var binding: MCPNativeVoiceTranscriptionBindingService?
            var registry: AutomationOperationRegistry?
            if executionMode != nil {
                for name in ["synthetic-review-runtime", "synthetic-review-model"] {
                    let url = root.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try Data("isolated deterministic artifact \(name)".utf8).write(to: url, options: .withoutOverwriting)
                    }
                }
                let operations = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("transcription-review-operations"))
                let batches = AutomationVoiceTranscriptionBatchService(registry: operations)
                registry = operations
                binding = MCPNativeVoiceTranscriptionBindingService(requests: requests, plans: plans,
                    facade: facade, batches: batches, readiness: { _ in })
            }
            let result = AutomationTranscriptionReviewService(plans: plans, facade: facade, requests: requests,
                bindingService: binding, operationRegistry: registry)
            underlying = result; return result
        }
        func requests() async throws -> [MCPVoiceTranscriptionReviewRequestStore.Record] { try await service().requests() }
        func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws -> AutomationTranscriptionReview {
            try await service().inspect(request)
        }
        func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws { try await service().cancel(request) }
        func prepareExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record,
            provider: AutomationVoiceTranscriptionBatchService.Provider,
            whisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind?) async throws -> MCPNativeVoiceTranscriptionBindingService.PreparedBinding {
            guard executionMode != nil else { throw Failure.invalidPlan }
            return try await service().prepareExecution(request, provider: provider, whisperKind: whisperKind)
        }
        func submit(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding, nativeConsent: Bool) async throws -> AutomationOperationRegistry.Record {
            try await service().submit(prepared, nativeConsent: nativeConsent)
        }
        func inspectOperation(_ id: UUID) async throws -> AutomationOperationRegistry.Record { try await service().inspectOperation(id) }
        func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record { try await service().waitForCompletion(id) }
        func cancelExecution(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding) async throws {
            try await service().cancelExecution(prepared)
        }
        func cancelRetainedExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws {
            try await service().cancelRetainedExecution(request)
        }
        func requestCapacity() async throws -> MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot {
            try await service().requestCapacity()
        }
        func recoverCancelledCapacity(expectedEpoch: UUID) async throws -> UUID {
            try await service().recoverCancelledCapacity(expectedEpoch: expectedEpoch)
        }
    }
}
