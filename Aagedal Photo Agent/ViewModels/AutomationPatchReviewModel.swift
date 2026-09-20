import Foundation
import Observation

/// A presentation of one exact inspected plan. All text remains untrusted plain text.
nonisolated struct AutomationPatchReview: Sendable {
    struct Change: Identifiable, Sendable {
        let id: String
        let operation: String
        let before: String
        let after: String
    }
    let planID: String
    let path: String
    let expiresAt: Date
    let changes: [Change]
    let warnings: [String]

    init(_ preview: MCPJSONValue) throws {
        guard let value = preview.objectValue,
              let planID = value["planID"]?.stringValue,
              UUID(uuidString: planID)?.uuidString.lowercased() == planID,
              value["previewOnly"] == .bool(true), value["commitAvailable"] == .bool(false),
              let path = value["canonicalPath"]?.stringValue,
              let expiry = value["expiresAt"]?.stringValue,
              let date = ISO8601DateFormatter().date(from: expiry),
              case .array(let changes) = value["changes"], !changes.isEmpty,
              case .array(let warnings) = value["preservationWarnings"],
              let validation = value["validation"]?.objectValue,
              case .array(let issues) = validation["issues"] else {
            throw MCPIPTCPatchPlanStore.Failure.invalidStorage
        }
        func text(_ value: MCPJSONValue?) throws -> String {
            switch value {
            case .string(let text): return text
            case .null: return ""
            case .array(let items):
                guard items.allSatisfy({ $0.stringValue != nil }) else {
                    throw MCPIPTCPatchPlanStore.Failure.invalidStorage
                }
                // JSON quoting preserves boundaries, including embedded newlines and commas.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                return String(decoding: try encoder.encode(items), as: UTF8.self)
            default: throw MCPIPTCPatchPlanStore.Failure.invalidStorage
            }
        }
        var seen = Set<String>()
        self.changes = try changes.map { change in
            guard let object = change.objectValue,
                  let field = object["field"]?.stringValue,
                  MCPIPTCPatchPreparation.supportedFields.contains(field), seen.insert(field).inserted,
                  let operation = object["operation"]?.stringValue, ["set", "clear"].contains(operation) else {
                throw MCPIPTCPatchPlanStore.Failure.invalidStorage
            }
            return Change(id: field, operation: operation,
                          before: try text(object["before"]), after: try text(object["after"]))
        }
        self.warnings = try warnings.map { warning in
            guard let text = warning.stringValue else { throw MCPIPTCPatchPlanStore.Failure.invalidStorage }
            return text
        } + issues.map { issue in
            guard let object = issue.objectValue, let message = object["message"]?.stringValue,
                  let field = object["field"]?.stringValue else { throw MCPIPTCPatchPlanStore.Failure.invalidStorage }
            return "\(field): \(message)"
        }
        self.planID = planID
        self.path = path
        self.expiresAt = date
    }
}

actor AutomationPatchReviewService {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.automation-patch-review", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }

    private let plans: MCPIPTCPatchPlanStore
    private let facade: MCPAutomationFacade

    init(plans: MCPIPTCPatchPlanStore? = nil, facade: MCPAutomationFacade = .init()) {
        self.plans = plans ?? MCPIPTCPatchPlanStore(storageDirectory:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans", isDirectory: true))
        self.facade = facade
    }

    func inspect(planID: String) throws -> AutomationPatchReview {
        try Task.checkCancellation()
        let result = try plans.inspect(arguments: ["planID": .string(planID)], facade: facade)
        try Task.checkCancellation()
        return try AutomationPatchReview(result)
    }
}

@MainActor @Observable
final class AutomationPatchReviewModel {
    var planID = ""
    private(set) var review: AutomationPatchReview?
    private(set) var message: String?
    private(set) var isLoading = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let service: AutomationPatchReviewService

    init(service: AutomationPatchReviewService? = nil) {
        if let service { self.service = service; return }
        do {
            self.service = try UITestPatchReviewFixture.currentServiceForModel() ?? .init()
        } catch {
            // A requested test fixture must never fall back to the user's plan archive.
            preconditionFailure("Could not prepare the isolated patch review UI fixture.")
        }
    }

    func clear() {
        generation = UUID()
        task?.cancel()
        task = nil
        review = nil
        message = nil
        isLoading = false
    }

    func inspect() {
        clear()
        let id = planID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
            message = "Enter the exact plan ID returned by prepare_iptc_patch."
            return
        }
        isLoading = true
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let result = try await service.inspect(planID: id)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.review = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }
}
