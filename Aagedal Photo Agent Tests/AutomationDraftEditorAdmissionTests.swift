import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Automation draft live-editor admission")
struct AutomationDraftEditorAdmissionTests {
    @Test("All owners must release a target, including batch selections")
    func multipleEditors() throws {
        let registry = AutomationDraftEditorAdmission()
        let first = UUID(), second = UUID()
        let photo = URL(fileURLWithPath: "/photos/frame.jpg")
        let other = URL(fileURLWithPath: "/photos/other.jpg")
        registry.update(owner: first, selectedURLs: [photo, other])
        registry.update(owner: second, selectedURLs: [photo])
        #expect(throws: AutomationDraftEditorAdmission.Failure.selectedInEditor) {
            try registry.requireUnselected(photo)
        }
        registry.update(owner: first, selectedURLs: [])
        try registry.requireUnselected(other)
        #expect(throws: AutomationDraftEditorAdmission.Failure.selectedInEditor) {
            try registry.requireUnselected(photo)
        }
        registry.remove(owner: second)
        try registry.requireUnselected(photo)
    }

    @Test("Selection replacement releases the old target without releasing the new one")
    func replacement() throws {
        let registry = AutomationDraftEditorAdmission()
        let owner = UUID()
        let old = URL(fileURLWithPath: "/photos/old.jpg")
        let new = URL(fileURLWithPath: "/photos/new.jpg")
        registry.update(owner: owner, selectedURLs: [old])
        registry.update(owner: owner, selectedURLs: [new])
        try registry.requireUnselected(old)
        #expect(throws: AutomationDraftEditorAdmission.Failure.selectedInEditor) {
            try registry.requireUnselected(new)
        }
    }

    @Test("Symlink aliases and shared RAW/XMP stems use the metadata lock identity")
    func aliases() throws {
        let registry = AutomationDraftEditorAdmission()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let photo = folder.appendingPathComponent("frame.CR3")
        try Data([1]).write(to: photo)
        registry.update(owner: UUID(), selectedURLs: [alias.appendingPathComponent("frame.CR3")])
        for target in [photo, folder.appendingPathComponent("frame.xmp"), folder.appendingPathComponent("FRAME.jpg")] {
            #expect(throws: AutomationDraftEditorAdmission.Failure.selectedInEditor) {
                try registry.requireUnselected(target)
            }
        }
    }

    @Test("A clean view model registers synchronously and deinitialization releases it") @MainActor
    func viewModelLifecycle() throws {
        let photo = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-admission-\(UUID().uuidString).jpg")
        var model: MetadataViewModel? = MetadataViewModel(readService: SwiftExifReadService(),
                                                         writeEngine: SwiftExifWriteEngine())
        weak var weakModel = model
        model?.selectedURLs = [photo]
        #expect(model?.hasUnpersistedEditorChanges == false)
        #expect(throws: AutomationDraftEditorAdmission.Failure.selectedInEditor) {
            try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
        }
        model = nil
        #expect(weakModel == nil)
        try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
    }
}
