import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop template schema preservation")
struct DevelopTemplateSchemaTests {
    @Test("Unversioned templates migrate without losing settings or identity")
    func legacyMigration() throws {
        var settings = CameraRawSettings()
        settings.exposure2012 = 1.5
        let original = DevelopTemplate(name: "Legacy", settings: settings, shortcutSlot: 2, includesCrop: false)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        let legacyBytes = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DevelopTemplate.self, from: legacyBytes)
        #expect(decoded == original)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(encoded["schemaVersion"] as? Int == DevelopTemplate.currentSchemaVersion)
    }

    @Test("Unsupported or malformed templates are preserved by compatibility saves",
          arguments: ["future", "zero", "negative", "null", "boolean", "fractional", "string", "corrupt", "invalidSettings"])
    func refusesUnsafeOverwrite(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root)
        let original = DevelopTemplate(name: "Protected")
        try storage.save(original)
        let url = root.appendingPathComponent("\(original.id.uuidString).json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        switch state {
        case "future": object["schemaVersion"] = DevelopTemplate.currentSchemaVersion + 1
        case "zero": object["schemaVersion"] = 0
        case "negative": object["schemaVersion"] = -1
        case "null": object["schemaVersion"] = NSNull()
        case "boolean": object["schemaVersion"] = true
        case "fractional": object["schemaVersion"] = 1.5
        case "string": object["schemaVersion"] = "1"
        case "invalidSettings": object["settings"] = "not settings"
        default: break
        }
        object["futurePrivateField"] = ["preserve": "exact bytes"]
        let protectedBytes = state == "corrupt" ? Data("broken JSON".utf8)
            : try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try protectedBytes.write(to: url)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DevelopTemplate.self, from: protectedBytes)
        }
        var replacement = original
        replacement.name = "Must not overwrite"
        #expect(throws: (any Error).self) { try storage.save(replacement) }
        #expect(try Data(contentsOf: url) == protectedBytes)
        #expect(try storage.loadAll().isEmpty)
        #expect(try Data(contentsOf: url) == protectedBytes)
    }

    @Test("Valid current and legacy documents can still be updated")
    func supportedOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root)
        var template = DevelopTemplate(name: "Original")
        try storage.save(template)
        let url = root.appendingPathComponent("\(template.id.uuidString).json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "schemaVersion")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        template.name = "Migrated"
        try storage.save(template)
        #expect(try storage.loadAll() == [template])
        template.name = "Updated"
        try storage.save(template)
        #expect(try storage.loadAll() == [template])
    }
}
