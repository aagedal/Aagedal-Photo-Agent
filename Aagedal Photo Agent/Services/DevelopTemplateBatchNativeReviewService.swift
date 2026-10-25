import Foundation

/// App-only capture and retirement. Deliberately owns no writer or execution service.
nonisolated final class DevelopTemplateBatchNativeReviewService: Sendable {
    struct Template: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let revision: String
    }

    nonisolated final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        func begin() { lock.withLock { active = true } }
        func withdraw() { lock.withLock { active = false } }
        func validate() throws {
            guard lock.withLock({ active }) else { throw CancellationError() }
        }
    }

    actor Worker {
        // Capture recurses once per photo; a Dispatch queue's 512 KB stack is too small on CI.
        nonisolated var unownedExecutor: UnownedSerialExecutor {
            LargeStackSerialExecutor.developBatchReview.asUnownedSerialExecutor()
        }
        func templates(_ discovery: MCPTemplateDiscovery) throws -> [Template] {
            try Task.checkCancellation()
            guard case .array(let entries) = try discovery.list(kind: "develop")["templates"] else {
                throw MCPTemplateDiscoveryError.invalidInventory
            }
            let result = try entries.map { entry -> Template in
                guard let object = entry.objectValue,
                      let rawID = object["id"]?.stringValue, let id = UUID(uuidString: rawID),
                      let name = object["name"]?.stringValue, let revision = object["revision"]?.stringValue else {
                    throw MCPTemplateDiscoveryError.invalidInventory
                }
                return Template(id: id, name: name, revision: revision)
            }
            try Task.checkCancellation()
            return result
        }
        func capture(_ service: DevelopTemplateBatchCaptureService, template: Template,
                     photos: [URL], configuration: @Sendable () throws -> String) throws -> (DevelopTemplateBatchCapture, String) {
            let revision = try configuration()
            let capture = try service.capture(templateID: template.id, templateRevision: template.revision,
                photos: photos, mode: .writeToXMPSidecar)
            guard try configuration() == revision else { throw DevelopTemplateBatchAdmissionFailure.changedEvidence }
            return (capture, revision)
        }
    }

    let session = Session()
    let admission: DevelopTemplateBatchAdmissionService
    private let capture: DevelopTemplateBatchCaptureService
    private let worker = Worker()
    private let configuration: DevelopTemplateBatchAdmissionService.ConfigurationRevision

    init(authorizationStore: MCPAuthorizationStore, discovery: MCPTemplateDiscovery,
         store: DevelopTemplateBatchAdmissionStore,
         configurationRevision: @escaping DevelopTemplateBatchAdmissionService.ConfigurationRevision = configurationRevision) {
        let capture = DevelopTemplateBatchCaptureService(facade: MCPAutomationFacade(authorizationStore: authorizationStore),
            discovery: discovery)
        self.capture = capture
        self.configuration = configurationRevision
        let session = self.session
        admission = DevelopTemplateBatchAdmissionService(captureService: capture, store: store,
            configurationRevision: configurationRevision, validateSession: { _ in try session.validate() })
    }

    static func native() throws -> DevelopTemplateBatchNativeReviewService {
        // UI tests must explicitly supply disposable storage, never use the user's library.
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        let authorization = MCPAuthorizationStore()
        return Self(authorizationStore: authorization, discovery: .init(authorizationStore: authorization),
            store: .init(directory: try DevelopTemplateBatchAdmissionStore.defaultStorageDirectory()))
    }

    func templates() async throws -> [Template] { try await worker.templates(capture.discovery) }

    func prepare(template: Template, photos: [URL]) async throws -> DevelopTemplateBatchAdmissionService.Review {
        try session.validate()
        let (captured, revision) = try await worker.capture(capture, template: template, photos: photos, configuration: configuration)
        try session.validate()
        return try await admission.review(captured, expectedConfigurationRevision: revision)
    }

    /// Binds the fixed sidecar review policy and the exact production RAW preferences.
    static func configurationRevision() throws -> String {
        let raw = try MCPDevelopTemplatePreview.configurationRevision()
        return "native-develop-review-v1:sidecar:" + raw
    }
}
