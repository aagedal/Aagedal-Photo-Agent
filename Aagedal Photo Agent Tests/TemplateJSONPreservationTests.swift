import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Template extension preservation")
struct TemplateJSONPreservationTests {
    @Test("Metadata extensions follow retained UUIDs while known clears and removals persist")
    func metadataExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let first = TemplateField(fieldKey: "title", templateValue: "Old")
        let second = TemplateField(fieldKey: "description", templateValue: "Description")
        let removed = TemplateField(fieldKey: "creator", templateValue: "Remove")
        var template = MetadataTemplate(name: "Original", fields: [first, second, removed], shortcutSlot: 2)
        try storage.save(template)
        let url = root.appendingPathComponent("\(template.id.uuidString).json")
        var object = try json(Data(contentsOf: url))
        object.removeValue(forKey: "schemaVersion")
        object["presetType"] = object.removeValue(forKey: "templateType")
        object["future"] = ["nested": ["preserve", "values"]]
        var fields = try #require(object["fields"] as? [[String: Any]])
        fields[0]["futureField"] = ["flag": true]
        fields[1]["futureField"] = "second"
        fields[2]["futureField"] = "removed with record"
        object["fields"] = fields
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        template.fields = [second, first]
        template.fields[1].templateValue = ""
        template.shortcutSlot = nil
        template.name = "Edited"
        try storage.save(template)
        let saved = try json(Data(contentsOf: url))
        #expect(saved["shortcutSlot"] == nil)
        #expect(saved["presetType"] == nil)
        #expect(saved["schemaVersion"] as? Int == 1)
        #expect((saved["future"] as? NSDictionary)?.isEqual(object["future"]) == true)
        let savedFields = try #require(saved["fields"] as? [[String: Any]])
        #expect(savedFields.count == 2)
        #expect(savedFields[0]["futureField"] as? String == "second")
        #expect((savedFields[1]["futureField"] as? [String: Bool]) == ["flag": true])
        #expect(savedFields[1]["templateValue"] as? String == "")
        #expect(try storage.loadAll() == [template])
    }

    @Test("Metadata malformed or ambiguous existing documents survive byte for byte",
          arguments: ["corrupt", "missingName", "duplicateIDs", "nullVersion", "futureVersion"])
    func metadataRefusal(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let field = TemplateField(fieldKey: "title", templateValue: "Old")
        let template = MetadataTemplate(name: "Original", fields: [field])
        try storage.save(template)
        let url = root.appendingPathComponent("\(template.id.uuidString).json")
        var object = try json(Data(contentsOf: url))
        switch state {
        case "missingName": object.removeValue(forKey: "name")
        case "duplicateIDs": object["fields"] = [try json(JSONEncoder().encode(field)), try json(JSONEncoder().encode(field))]
        case "nullVersion": object["schemaVersion"] = NSNull()
        case "futureVersion": object["schemaVersion"] = 2
        default: break
        }
        let bytes = state == "corrupt" ? Data("broken".utf8) : try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try storage.save(template) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Develop root extensions survive known optional clears")
    func developRootExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root)
        var settings = CameraRawSettings()
        settings.exposure2012 = 1.5
        var template = DevelopTemplate(name: "Original", settings: settings, shortcutSlot: 1)
        try storage.save(template)
        let url = root.appendingPathComponent("\(template.id.uuidString).json")
        var object = try json(Data(contentsOf: url))
        object.removeValue(forKey: "schemaVersion")
        object["extension"] = ["nested": ["one", "two", "three"]]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        template.shortcutSlot = nil
        template.settings.exposure2012 = nil
        try storage.save(template)
        let saved = try json(Data(contentsOf: url))
        #expect(saved["shortcutSlot"] == nil)
        #expect((saved["settings"] as? [String: Any])?["exposure2012"] == nil)
        #expect((saved["extension"] as? NSDictionary)?.isEqual(object["extension"]) == true)
        #expect(try storage.loadAll() == [template])
    }

    @Test("Unknown Develop settings refuse instead of silently dropping nested members",
          arguments: ["settings", "nested", "array"])
    func developNestedRefusal(location: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root)
        var modelSettings = CameraRawSettings()
        modelSettings.crop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 0, hasCrop: true)
        modelSettings.localAdjustments = [MaskAdjustment()]
        let template = DevelopTemplate(name: "Protected", settings: modelSettings)
        try storage.save(template)
        let url = root.appendingPathComponent("\(template.id.uuidString).json")
        var object = try json(Data(contentsOf: url))
        var settings = try #require(object["settings"] as? [String: Any])
        // Extensions inside known objects/array rows must also be detected.
        switch location {
        case "nested":
            var crop = try #require(settings["crop"] as? [String: Any])
            crop["future"] = ["leaf": true]
            settings["crop"] = crop
        case "array":
            var masks = try #require(settings["localAdjustments"] as? [[String: Any]])
            masks[0]["future"] = ["leaf": true]
            settings["localAdjustments"] = masks
        default: settings["future"] = "retained"
        }
        object["settings"] = settings
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try bytes.write(to: url)
        #expect(try storage.loadAll() == [template])
        #expect(throws: TemplateJSONPreservation.PreservationError.self) { try storage.save(template) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Ambiguous keys and numeric extensions refuse before rewriting", arguments: ["duplicate", "precision", "integer"])
    func rawExtensionsRefuse(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TemplateStorageService(directoryURL: root)
        let template = MetadataTemplate(name: "Protected")
        try storage.save(template)
        let url = root.appendingPathComponent("\(template.id.uuidString).json")
        let original = try String(contentsOf: url, encoding: .utf8)
        let extensionJSON: String
        switch state {
        case "duplicate": extensionJSON = #""extension":{"key":"first","key":"second"},"#
        case "precision": extensionJSON = #""extension":0.1234567890123456789012345678901234567890123456789,"#
        default: extensionJSON = #""extension":{"nested":[123]},"#
        }
        let bytes = Data(("{" + extensionJSON + original.dropFirst()).utf8)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try storage.save(template) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("A mismatched filename identity cannot be overwritten", arguments: [false, true])
    func mismatchedIdentity(develop: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let targetID = UUID()
        let url = root.appendingPathComponent("\(targetID.uuidString).json")
        let bytes: Data
        if develop {
            bytes = try JSONEncoder().encode(DevelopTemplate(name: "Other identity"))
        } else {
            bytes = try JSONEncoder().encode(MetadataTemplate(name: "Other identity"))
        }
        try bytes.write(to: url)
        if develop {
            let storage = DevelopTemplateStorageService(directoryURL: root)
            #expect(throws: TemplateJSONPreservation.PreservationError.self) {
                try storage.save(DevelopTemplate(id: targetID, name: "Must not replace"))
            }
        } else {
            let storage = TemplateStorageService(directoryURL: root)
            #expect(throws: TemplateJSONPreservation.PreservationError.self) {
                try storage.save(MetadataTemplate(id: targetID, name: "Must not replace"))
            }
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
