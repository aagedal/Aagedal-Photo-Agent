import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery workflow Activity and recovery")
@MainActor
struct DeliveryWorkflowActivityModelTests {
    @Test("multiple recoverable workflows require and preserve the exact selected UUID")
    func exactResumeSelection() async {
        let first = UUID(uuidString: "91000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "91000000-0000-0000-0000-000000000002")!
        let stub = WorkflowActivityStub(workflows: [
            summary(first, stage: .failed, completed: 1, total: 3, retained: true),
            summary(second, stage: .cancelled, completed: 2, total: 3, retained: true),
        ])
        let model = DeliveryWorkflowActivityModel(dependencies: stub.dependencies)

        await model.reload()
        #expect(model.workflows.map(\.id) == [first, second])
        #expect(await model.requestResume(second))
        #expect(stub.validatedResumeIdentifiers == [second])
        #expect(model.error == nil)
    }

    @Test("manual cleanup is exact, confirmed by its API, and survives relaunch")
    func confirmedCleanupAndRelaunch() async {
        let retained = UUID(uuidString: "92000000-0000-0000-0000-000000000001")!
        let removed = UUID(uuidString: "92000000-0000-0000-0000-000000000002")!
        let stub = WorkflowActivityStub(workflows: [
            summary(retained, stage: .sent, completed: 2, total: 2, retained: true),
            summary(removed, stage: .failed, completed: 1, total: 2, retained: true),
        ])
        let firstLaunch = DeliveryWorkflowActivityModel(dependencies: stub.dependencies)
        await firstLaunch.reload()

        #expect(await firstLaunch.removeConfirmedWorkflow(removed))
        #expect(stub.removedIdentifiers == [removed])
        #expect(firstLaunch.workflows.map(\.id) == [retained])

        let relaunched = DeliveryWorkflowActivityModel(dependencies: stub.dependencies)
        await relaunched.reload()
        #expect(relaunched.workflows.map(\.id) == [retained])
        #expect(stub.removedIdentifiers == [removed])
    }

    @Test("active exact workflow blocks resume and cleanup without touching persistence")
    func busyGuards() async {
        let active = UUID(uuidString: "93000000-0000-0000-0000-000000000001")!
        let stub = WorkflowActivityStub(workflows: [
            summary(active, stage: .uploading, completed: 1, total: 2, retained: true),
        ])
        stub.activeIdentifier = active
        let model = DeliveryWorkflowActivityModel(dependencies: stub.dependencies)
        await model.reload()

        #expect(await model.requestResume(active) == false)
        #expect(model.error == .workflowBusy)
        #expect(await model.removeConfirmedWorkflow(active) == false)
        #expect(model.error == .workflowBusy)
        #expect(stub.validatedResumeIdentifiers.isEmpty)
        #expect(stub.removedIdentifiers.isEmpty)
    }

    @Test("resume reservation closes validation-to-navigation cleanup race and can be abandoned")
    func reservationOverlapAndAbandonment() async {
        let identifier = UUID(uuidString: "93500000-0000-0000-0000-000000000001")!
        let stub = WorkflowActivityStub(workflows: [
            summary(identifier, stage: .failed, completed: 1, total: 2, retained: true),
        ])
        let model = DeliveryWorkflowActivityModel(dependencies: stub.dependencies)
        await model.reload()

        #expect(await model.requestResume(identifier))
        #expect(stub.reservedIdentifier == identifier)
        #expect(await model.removeConfirmedWorkflow(identifier) == false)
        #expect(model.error == .workflowBusy)
        #expect(stub.removedIdentifiers.isEmpty)

        await model.abandonResume(identifier)
        #expect(stub.reservedIdentifier == nil)
        #expect(await model.removeConfirmedWorkflow(identifier))
        #expect(stub.removedIdentifiers == [identifier])
    }

    @Test("corrupt or newer-schema catalog fails closed without a stale partial list")
    func catalogFailsClosed() async {
        let identifier = UUID(uuidString: "94000000-0000-0000-0000-000000000001")!
        let stub = WorkflowActivityStub(workflows: [
            summary(identifier, stage: .failed, completed: 0, total: 1, retained: true),
        ])
        let model = DeliveryWorkflowActivityModel(dependencies: stub.dependencies)
        await model.reload()
        #expect(model.workflows.count == 1)

        stub.catalogFailure = DeliveryWorkflowRegistryError.newerSchema
        await model.reload()

        #expect(model.workflows.isEmpty)
        #expect(model.isLoaded)
        #expect(model.error == .catalogUnavailable)
        #expect(await model.requestResume(identifier) == false)
        #expect(stub.validatedResumeIdentifiers.isEmpty)
    }

    @Test("Activity projection serializes no private workflow facts")
    func privacySerialization() throws {
        let identifier = UUID(uuidString: "95000000-0000-0000-0000-000000000001")!
        let projected = DeliveryWorkflowActivitySummary(summary(
            identifier,
            stage: .failed,
            completed: 4,
            total: 5,
            retained: true,
            failure: .uploadFailed
        ))
        let text = String(decoding: try JSONEncoder().encode(projected), as: UTF8.self)
            .lowercased()

        #expect(text.contains(identifier.uuidString.lowercased()))
        #expect(text.contains("uploadfailed"))
        for forbidden in [
            "private-source.jpg", "/incoming/embargoed", "/private/tmp/staging",
            String(repeating: "a", count: 64), "sensitive caption", "connection-secret",
        ] {
            #expect(!text.contains(forbidden))
        }
        #expect(projected.failureTitle == "Upload failed")
    }

    @Test("every persisted workflow stage has an explicit Activity title")
    func stageMapping() {
        let expected: [(DeliveryWorkflowStage, String)] = [
            (.queued, "Queued"),
            (.staging, "Staging"),
            (.writing, "Writing metadata"),
            (.verifying, "Verifying metadata"),
            (.preservationVerifying, "Verifying preservation"),
            (.uploading, "Uploading"),
            (.remoteConfirming, "Confirming remote file"),
            (.recordingReceipt, "Recording receipt"),
            (.sent, "Sent"),
            (.failed, "Failed"),
            (.cancelled, "Cancelled"),
        ]

        for (index, entry) in expected.enumerated() {
            let identifier = UUID(uuidString: String(
                format: "96000000-0000-0000-0000-%012d",
                index + 1
            ))!
            let projected = DeliveryWorkflowActivitySummary(summary(
                identifier,
                stage: entry.0,
                completed: 0,
                total: 1,
                retained: entry.0 != .queued
            ))
            #expect(projected.stageTitle == entry.1)
        }
    }

    private func summary(
        _ identifier: UUID,
        stage: DeliveryWorkflowStage,
        completed: Int,
        total: Int,
        retained: Bool,
        failure: DeliveryWorkflowFailureCode? = nil
    ) -> DeliveryWorkflowRegistrySummary {
        DeliveryWorkflowRegistrySummary(
            workflowIdentifier: identifier,
            stage: stage,
            completedItemCount: completed,
            itemCount: total,
            hasRetainedStaging: retained,
            failureCode: failure
        )
    }
}

@MainActor
private final class WorkflowActivityStub {
    var workflows: [DeliveryWorkflowRegistrySummary]
    var activeIdentifier: UUID?
    var reservedIdentifier: UUID?
    var catalogFailure: Error?
    var validatedResumeIdentifiers: [UUID] = []
    var removedIdentifiers: [UUID] = []

    init(workflows: [DeliveryWorkflowRegistrySummary]) {
        self.workflows = workflows
    }

    var dependencies: DeliveryWorkflowActivityDependencies {
        DeliveryWorkflowActivityDependencies(
            catalog: { [weak self] in
                guard let self else { throw DeliveryWorkflowRegistryError.invalidRoot }
                if let catalogFailure { throw catalogFailure }
                return DeliveryWorkflowRegistryCatalog(workflows: workflows)
            },
            validateResume: { [weak self] identifier in
                guard let self,
                      workflows.contains(where: {
                          $0.workflowIdentifier == identifier
                              && $0.hasRetainedStaging
                              && $0.stage != .sent
                      }) else {
                    throw DeliveryWorkflowRegistryError.retainedStagingUnavailable
                }
                validatedResumeIdentifiers.append(identifier)
                reservedIdentifier = identifier
            },
            releaseResume: { [weak self] identifier in
                if self?.reservedIdentifier == identifier {
                    self?.reservedIdentifier = nil
                }
            },
            removeWorkflow: { [weak self] identifier in
                guard let self,
                      workflows.contains(where: { $0.workflowIdentifier == identifier }) else {
                    throw DeliveryWorkflowRegistryError.workflowNotFound
                }
                removedIdentifiers.append(identifier)
                workflows.removeAll { $0.workflowIdentifier == identifier }
            },
            protectedWorkflowIdentifier: { [weak self] in
                self?.activeIdentifier ?? self?.reservedIdentifier
            }
        )
    }
}
