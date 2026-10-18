import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Batch description queue admission", .serialized)
struct DescriptionAssistantBatchApplyTests {
    @MainActor
    private func fixture() async throws -> (BrowserViewModel, CaptionDraftPersistenceQueue, URL, DescriptionAssistantProposal) {
        let photo = URL(fileURLWithPath: "/virtual/description-\(UUID().uuidString)/photo.jpg")
        let baseline = IPTCMetadata(title: "Original headline", description: "Original description")
        let queue = CaptionDraftPersistenceQueue(label: "description.batch.apply")
        queue.enqueue(operation: { throw CaptionWorkspaceFlushError.persistenceFailed("Hold queued work") })
        let model = BrowserViewModel(metadataReviewBaselineLoader: { image, _ in
            .init(metadata: baseline, sidecar: MetadataSidecar(sourceFile: image.lastPathComponent,
                pendingChanges: true, metadata: baseline, imageMetadataSnapshot: nil))
        }, metadataReviewCoordinator: CaptionWorkspaceFlushCoordinator(persistenceQueue: queue))
        model.currentFolderURL = photo.deletingLastPathComponent()
        model.images = [ImageFile(url: photo)]
        await model.prepareMetadataReviewEditor(for: photo)
        let editor = try #require(model.metadataReviewEditor(for: photo))
        let request = DescriptionAssistantRequest(imageURL: photo, editorLoadID: editor.id,
            originalDescription: baseline.description ?? "", action: .wording, language: .english)
        return (model, queue, photo, DescriptionAssistantProposal(request: request,
            text: "Suggested description", model: "Test model"))
    }

    @Test("A failed capture preserves all editor buffers and permits retrying the same proposal")
    @MainActor
    func captureFailureAndRetry() async throws {
        let (model, queue, photo, proposal) = try await fixture()
        let editorID = try #require(model.metadataReviewEditor(for: photo)?.id)
        model.updateMetadataReviewText("Unsaved headline", field: .headline, for: photo, editorID: editorID)
        // Preserve an explicit description buffer as well as unrelated unsaved input.
        model.updateMetadataReviewText("Original description", field: .description, for: photo, editorID: editorID)
        let before = try #require(model.metadataReviewEditor(for: photo))
        model.images = []
        #expect(throws: CaptionWorkspaceFlushError.self) {
            try model.queueReviewedDescription(proposal, text: "Reviewed suggestion")
        }
        let retained = try #require(model.metadataReviewEditor(for: photo))
        #expect(retained.draft == before.draft)
        #expect(retained.previous == before.previous)
        #expect(retained.textBuffers == before.textBuffers)
        #expect(retained.latestRequestID == before.latestRequestID)
        #expect(await queue.pendingCountWhenIdle() == 1)

        model.images = [ImageFile(url: photo)]
        #expect(try model.queueReviewedDescription(proposal, text: "Reviewed suggestion"))
        let admitted = try #require(model.metadataReviewEditor(for: photo))
        #expect(admitted.previous.description == "Reviewed suggestion")
        #expect(admitted.sidecar?.metadata.description == "Reviewed suggestion")
        #expect(admitted.sidecar?.metadata.title == "Unsaved headline")
        #expect(admitted.textBuffers.isEmpty)
        #expect(await queue.pendingCountWhenIdle() == 2)
    }

    @Test("Newer description edits reject a captured proposal without changing the live draft")
    @MainActor
    func newerDescriptionIsRetained() async throws {
        let (model, queue, photo, proposal) = try await fixture()
        let editorID = try #require(model.metadataReviewEditor(for: photo)?.id)
        model.updateMetadataReviewText("Newer user description", field: .description, for: photo, editorID: editorID)
        #expect(try !model.queueReviewedDescription(proposal, text: "Reviewed suggestion"))
        #expect(model.metadataReviewText(for: .description, imageURL: photo) == "Newer user description")
        #expect(await queue.pendingCountWhenIdle() == 1)
    }
}
