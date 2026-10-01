import Foundation

/// Explicit UI-test seam. Real durable intent and source validation, isolated from
/// production authorization, provider state and archives. No recognition is invoked.
enum UITestTranscriptionReviewFixture {
    static func currentServiceForModel() -> (any AutomationTranscriptionReviewServing)? {
        service(configuration: .current, environment: ProcessInfo.processInfo.environment)
    }

    static func service(configuration: UITestLaunchConfiguration, environment: [String: String]) -> (any AutomationTranscriptionReviewServing)? {
        guard configuration.isEnabled, environment["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW"] == "1" else { return nil }
        return Worker(folder: configuration.folderURL)
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
    }
    enum Failure: Error { case invalidFolder, invalidPlan }

    /// Initialization also runs on the filesystem executor, never in SwiftUI init.
    private actor Worker: AutomationTranscriptionReviewServing {
        nonisolated let filesystemQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.ui-test-transcription-review", qos: .utility)
        nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
        let folder: URL?
        private var underlying: AutomationTranscriptionReviewService?
        init(folder: URL?) { self.folder = folder }

        private func service() throws -> AutomationTranscriptionReviewService {
            if let underlying { return underlying }
            guard let folder else { throw Failure.invalidFolder }
            let root = folder.resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                throw Failure.invalidFolder
            }
            let box = ConfigurationBox()
            let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
            let authorityURL = root.appendingPathComponent("transcription-review-authorization.json")
            let manifestURL = root.appendingPathComponent("transcription-review-manifest.json")
            let facade = MCPAutomationFacade(authorizationStore: authority)
            let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: root.appendingPathComponent("transcription-review-plans"))
            let requests = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root.appendingPathComponent("transcription-review-requests"))
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                box.write(try Data(contentsOf: authorityURL))
                _ = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            } else {
                try authority.addRoot(root); try authority.setEnabled(true)
                var inputs: [MCPJSONValue] = [], paths: [String] = []
                for index in 1...2 {
                    let photo = root.appendingPathComponent("transcription-review-\(index)-å.jpg")
                    let memo = root.appendingPathComponent("transcription-review-\(index).wav")
                    try Data("isolated photo \(index)".utf8).write(to: photo, options: .withoutOverwriting)
                    try Data("isolated WAV intent \(index)".utf8).write(to: memo, options: .withoutOverwriting)
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
                guard let data = box.read() else { throw Failure.invalidPlan }
                try data.write(to: authorityURL, options: .withoutOverwriting)
                try JSONEncoder().encode(Manifest(requestID: requestID.uuidString.lowercased(), requestEpoch: epoch.uuidString.lowercased(),
                    planID: planID, photoPaths: Array(paths.reversed()))).write(to: manifestURL, options: .withoutOverwriting)
            }
            let result = AutomationTranscriptionReviewService(plans: plans, facade: facade, requests: requests)
            underlying = result; return result
        }
        func requests() async throws -> [MCPVoiceTranscriptionReviewRequestStore.Record] { try await service().requests() }
        func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws -> AutomationTranscriptionReview {
            try await service().inspect(request)
        }
        func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws { try await service().cancel(request) }
    }
}
