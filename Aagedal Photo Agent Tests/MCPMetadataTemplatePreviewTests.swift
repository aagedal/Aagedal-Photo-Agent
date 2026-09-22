import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Exact revision literal metadata template previews")
struct MCPMetadataTemplatePreviewTests {
    private func arguments(mode: String = "append") -> [String: MCPJSONValue] {
        ["templateID": .string(UUID().uuidString), "templateRevision": .string("sha256:" + String(repeating: "a", count: 64)),
         "mode": .string(mode), "path": .string("/photos/frame.jpg"), "sourceRevision": .string("source"),
         "xmpSidecarRevision": .string("xmp"), "appSidecarRevision": .string("app")]
    }

    private func template(_ fields: [(String, String)], instantly: Bool = false) throws -> Data {
        try JSONEncoder().encode(MetadataTemplate(name: "Preview", fields: fields.map {
            TemplateField(fieldKey: $0.0, templateValue: $0.1)
        }, processInstantly: instantly))
    }

    @Test("Retained people and keyword shorthands match production interpolation", arguments: ["append", "replace"])
    func contextualListVariables(mode: String) throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        let raw = "People: {persons} / {persons}; tags: {keywords} / {keywords}"
        let values = try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        record["fields"] = .object(["title": .string("Before"),
            "personShown": .array([.string("Ann Å"), .string("Bob")]),
            "keywords": .array([.string("News"), .string("Sport")])])
        var metadata = IPTCMetadata()
        metadata.personShown = ["Ann Å", "Bob"]
        metadata.keywords = ["News", "Sport"]
        let resolved = PresetVariableInterpolator().resolve(raw, existingMetadata: metadata)
        let result = try MCPMetadataTemplatePreview.preview(request: request,
            templateFields: values, metadata: .object(record))
        guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
        let change = try #require(changes.first?.objectValue)
        #expect(change["resolvedTemplateValue"] == .string(resolved))
        #expect(change["resolvedVariables"] == .array([.string("persons"), .string("keywords")]))
        #expect(change["after"] == .string(mode == "append" ? "Before " + resolved : resolved))
        #expect(result.objectValue?["valueSemantics"]?.stringValue?.hasPrefix("retained-list") == true)
        record["fields"] = .object(["title": .null, "personShown": .array([]), "keywords": .array([])])
        let empty = try MCPMetadataTemplatePreview.preview(request: request,
            templateFields: values, metadata: .object(record))
        guard case .array(let emptyChanges) = empty.objectValue?["changes"] else {
            Issue.record("Missing empty-list changes"); return
        }
        #expect(emptyChanges.first?.objectValue?["resolvedTemplateValue"] == .string("People:  / ; tags:  / "))
    }

    @Test("Canonical keyword field references read retained metadata without authoring keywords")
    func retainedKeywordFieldReference() throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: "replace"))
        let raw = "Tags: {field:keywords}"
        let values = try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        record["fields"] = .object(["title": .null, "keywords": .array([.string("News"), .string("Sport")])])
        let result = try MCPMetadataTemplatePreview.preview(request: request,
            templateFields: values, metadata: .object(record))
        guard case .array(let changes) = result.objectValue?["changes"] else {
            Issue.record("Missing changes"); return
        }
        var metadata = IPTCMetadata()
        metadata.keywords = ["News", "Sport"]
        #expect(changes.first?.objectValue?["resolvedTemplateValue"] ==
                .string(PresetVariableInterpolator().resolve(raw, existingMetadata: metadata)))
        #expect(changes.first?.objectValue?["resolvedVariables"] == .array([.string("field:keywords")]))
        record["fields"] = .object(["title": .null, "keywords": .array([.string("{seq}")])])
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
        }
    }

    @Test("Contextual list shorthands refuse changed, malformed, and second-order sources")
    func contextualListRefusals() throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: "replace"))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        record["fields"] = .object(["title": .null, "personShown": .array([.string("Ann")]),
            "keywords": .array([.string("News")])])
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": "{persons}", "personShown": "Changed"], metadata: .object(record))
        }
        for token in ["{seq}", "{field:title}", "{keywords}", "(number)", "brace}", "\0"] {
            record["fields"] = .object(["title": .null, "personShown": .array([.string(token)])])
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.preview(request: request,
                    templateFields: ["title": "{persons}"], metadata: .object(record))
            }
        }
        record["fields"] = .object(["title": .null, "keywords": .array([.integer(1)])])
        #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": "{keywords}"], metadata: .object(record))
        }
        record["fields"] = .object(["title": .null, "keywords": .array([.string(String(repeating: "Å", count: 16_384))])])
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": "{keywords}{keywords}"], metadata: .object(record))
        }
        for raw in ["{persons} {initials}", "{keywords} {gps}", "{Persons}"] {
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
            }
        }
    }

    @Test("Literal field references match the production interpolator", arguments: ["append", "replace"])
    func fieldReferences(mode: String) throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        record["fields"] = .object(["title": .string("Before"), "credit": .string("Agency"), "city": .null])
        let raw = "{field:credit} / {field:city} / {field:credit}"
        let values = try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
        let result = try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
        var metadata = IPTCMetadata()
        metadata.credit = "Agency"
        let resolved = PresetVariableInterpolator().resolve(raw, filename: "frame.jpg", existingMetadata: metadata)
        guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
        let change = try #require(changes.first?.objectValue)
        #expect(change["after"] == .string(mode == "append" ? "Before " + resolved : resolved))
        #expect(change["resolvedTemplateValue"] == .string(resolved))
        #expect(result.objectValue?["valueSemantics"]?.stringValue?.hasPrefix("retained-field") == true)
        #expect(change["resolvedVariables"] == .array([.string("field:city"), .string("field:credit")]))
        for incoming in ["{seq}", "{filename}", "{initials}", "(number)", "brace}"] {
            record["fields"] = .object(["title": .string("Before"), "credit": .string(incoming), "city": .null])
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
            }
        }
        record["fields"] = .object(["title": .string("Before"), "credit": .string("Agency"), "city": .null])
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": raw, "credit": "Changed"], metadata: .object(record))
        }
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": "{field:title}"], metadata: .object(record))
        }
        record["fields"] = .object(["title": .string("Before")])
        #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
        }
    }

    @Test("Recursive retained scalar references match production", arguments: ["append", "replace"])
    func recursiveFieldReferences(mode: String) throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        var metadata = IPTCMetadata()
        metadata.credit = "{field:city} / {field:source}"
        metadata.city = "{field:country}"
        metadata.source = "{field:country}"
        metadata.country = "Norge Å"
        record["fields"] = .object(["title": .string("Before"), "credit": .string(metadata.credit!),
            "city": .string(metadata.city!), "source": .string(metadata.source!), "country": .string(metadata.country!)])
        let raw = "{field:credit} / {field:city} / {field:credit}"
        let result = try MCPMetadataTemplatePreview.preview(request: request,
            templateFields: ["title": raw], metadata: .object(record))
        guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
        let expected = PresetVariableInterpolator().resolve(raw, existingMetadata: metadata)
        #expect(changes.first?.objectValue?["resolvedTemplateValue"] == .string(expected))
        #expect(changes.first?.objectValue?["resolvedVariables"] == .array(
            ["city", "country", "credit", "source"].map { .string("field:\($0)") }))
        #expect(changes.first?.objectValue?["after"] == .string(mode == "append" ? "Before " + expected : expected))
    }

    @Test("Recursive field graphs refuse cycles, changed sources and unsupported nested authority")
    func recursiveFieldRefusals() throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: "replace"))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        for leaf in ["{field:credit}", "{field:city}", "{field:title}",
                     "{field:Country}", "{filename}", "{seq}", "{initials}", "(number)", "brace}", "\0"] {
            record["fields"] = .object(["title": .null, "credit": .string("{field:city}"), "city": .string(leaf)])
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.preview(request: request,
                    templateFields: ["title": "{field:credit}"], metadata: .object(record))
            }
        }
        record["fields"] = .object(["title": .null, "credit": .string("{field:city}"), "city": .string("Before")])
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": "{field:credit}", "city": "After"], metadata: .object(record))
        }
        for leaf in [MCPJSONValue.array([]), .integer(1)] {
            record["fields"] = .object(["title": .null, "credit": .string("{field:city}"), "city": leaf])
            #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
                try MCPMetadataTemplatePreview.preview(request: request,
                    templateFields: ["title": "{field:credit}"], metadata: .object(record))
            }
        }
        record["fields"] = .object(["title": .null, "credit": .string("{field:city}{field:city}"),
            "city": .string(String(repeating: "Å", count: 16_384))])
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": "{field:credit}"], metadata: .object(record))
        }
    }

    @Test("Field expansion is bounded before allocation with UTF-8 byte accounting")
    func fieldExpansionLimit() throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: "replace"))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        record["fields"] = .object(["title": .null, "credit": .string(String(repeating: "Å", count: 16_384))])
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": String(repeating: "{field:credit}", count: 2_000)], metadata: .object(record))
        }
        let atLimit = try MCPMetadataTemplatePreview.replacingBounded("{field:credit}",
            in: "{field:credit}", with: String(repeating: "Å", count: 16_384))
        #expect(atLimit.utf8.count == 32_768)
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            try MCPMetadataTemplatePreview.replacingBounded("{field:credit}",
                in: "x{field:credit}", with: String(repeating: "Å", count: 16_384))
        }
    }

    @Test("Retained list references match production and report recursive dependencies", arguments: ["append", "replace"])
    func listFieldReferences(mode: String) throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        for source in MCPMetadataTemplatePreview.listFieldVariableSources {
            let persisted = MCPMetadataTemplatePreview.editorialKeys[source] ?? source
            for items in [[], ["Å person", "Second, entry", "Å person"], ["{field:city}", "Agency"]] as [[String]] {
                var record = request.revisions
                record["hasXMPConflict"] = .bool(false)
                let fields: [String: MCPJSONValue] = ["title": .string("Before"), "city": .string("Oslo"),
                    persisted: .array(items.map(MCPJSONValue.string))]
                record["fields"] = .object(fields)
                var metadata = IPTCMetadata()
                metadata.city = "Oslo"
                switch source {
                case "keywords": metadata.keywords = items
                case "personShown": metadata.personShown = items
                case "creator": metadata.creators = items
                case "organisationShownName": metadata.organisationsShownNames = items
                case "organisationShownCode": metadata.organisationsShownCodes = items
                case "sceneCode": metadata.sceneCodes = items
                case "subjectCode": metadata.subjectCodes = items
                default: Issue.record("Unexpected list source")
                }
                let raw = "People: {field:\(source)}"
                let values = try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
                let result = try MCPMetadataTemplatePreview.preview(request: request,
                    templateFields: values, metadata: .object(record))
                guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
                let resolved = PresetVariableInterpolator().resolve(raw, existingMetadata: metadata)
                #expect(changes.first?.objectValue?["resolvedTemplateValue"] == .string(resolved))
                #expect(changes.first?.objectValue?["after"] == .string(mode == "append" ? "Before " + resolved : resolved))
                let dependencies = (items.contains("{field:city}") ? [source, "city"] : [source]).sorted()
                #expect(changes.first?.objectValue?["resolvedVariables"] == .array(dependencies.map { .string("field:\($0)") }))
                #expect(result.objectValue?["commitAvailable"] == .bool(false))
            }
        }
    }

    @Test("List references reject changed sources, cycles, malformed carriers and oversized joins")
    func listFieldReferenceRefusals() throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: "replace"))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        for source in MCPMetadataTemplatePreview.listFieldVariableSources {
            let persisted = MCPMetadataTemplatePreview.editorialKeys[source] ?? source
            let raw = "{field:\(source)}"
            for value in [MCPJSONValue.null, .string("Person"), .array([.integer(1)])] {
                record["fields"] = .object(["title": .null, persisted: value])
                #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
                    try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": raw], metadata: .object(record))
                }
            }
            for item in [raw, "{field:credit}", "{seq}", "{filename}", "{initials}", "\0"] {
                record["fields"] = .object(["title": .null, persisted: .array([.string(item)]), "credit": .string(raw)])
                #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                    try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": raw], metadata: .object(record))
                }
            }
            record["fields"] = .object(["title": .null, persisted: .array([.string("Person")])])
            if source != "keywords" {
                #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                    try MCPMetadataTemplatePreview.preview(request: request,
                        templateFields: ["title": raw, source: "Changed"], metadata: .object(record))
                }
            }
            record["fields"] = .object(["title": .null,
                persisted: .array([.string(String(repeating: "Å", count: 16_384)), .string("")])])
            #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
                try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": raw], metadata: .object(record))
            }
        }
    }

    @Test("Every allowed scalar field reference agrees with production resolution")
    func allFieldReferences() throws {
        for source in MCPMetadataTemplatePreview.fieldVariableSources {
            let target = source == "title" ? "description" : "title"
            let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: "replace"))
            let scalar = source == "dateCreated" ? "2026-09-22" : source == "countryCode" ? "NOR" : "Literal Å value"
            let fieldData = try JSONEncoder().encode([source: scalar])
            let metadata = try JSONDecoder().decode(IPTCMetadata.self, from: fieldData)
            var record = request.revisions
            record["hasXMPConflict"] = .bool(false)
            record["fields"] = .object([source: .string(scalar), target: .null])
            let raw = "{field:\(source)}"
            let result = try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: [target: raw], metadata: .object(record))
            guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
            #expect(changes.first?.objectValue?["after"] == .string(
                PresetVariableInterpolator().resolve(raw, existingMetadata: metadata)))
        }
    }

    @Test("Literal append and replace values agree with the production editor", arguments: ["append", "replace"])
    @MainActor func editorSemantics(mode: String) throws {
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.editingMetadata.title = " Existing "
        model.editingMetadata.description = "Body"
        model.editingMetadata.personShown = ["Ann"]
        model.editingMetadata.imageSupplierImageID = "old-id"
        let values = ["title": " New ", "description": "", "credit": "First", "imageSupplierImageID": "new-id",
                      "personShown": " Ann, Bob, Bob, "]
        let fields: [String: MCPJSONValue] = ["title": .string(" Existing "), "description": .string("Body"),
            "credit": .null, "imageSupplierImageID": .string("old-id"), "personShown": .array([.string("Ann")])]
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        var metadata = request.revisions
        metadata["fields"] = .object(fields)
        metadata["hasXMPConflict"] = .bool(false)
        let preview = try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(metadata))
        model.applyTemplateFields(values, append: mode == "append")
        let expected: [String: MCPJSONValue] = ["title": .string(model.editingMetadata.title!),
            "description": .string(model.editingMetadata.description!), "credit": .string(model.editingMetadata.credit!),
            "imageSupplierImageID": .string(model.editingMetadata.imageSupplierImageID!),
            "personShown": .array(model.editingMetadata.personShown.map(MCPJSONValue.string))]
        guard case .array(let changes) = preview.objectValue?["changes"] else { Issue.record("Missing changes"); return }
        for change in changes {
            let object = try #require(change.objectValue)
            let key = try #require(object["field"]?.stringValue)
            #expect(object["after"] == expected[key])
        }
        #expect(preview.objectValue?["commitAvailable"] == .bool(false))
        #expect(preview.objectValue?["planID"] == nil)
    }

    @Test("Expanded literal fields match production editor and use canonical metadata keys", arguments: ["append", "replace"])
    @MainActor func expandedEditorSemantics(mode: String) throws {
        // Include JSON creator transport, malformed values, duplicate incoming organisations,
        // semicolon-separated codes and atomic identifiers to exercise distinct editor rules.
        let variants: [[String: String]] = [
            ["creator": "[\"Ann\",\"Bob\",\"Bob\"]", "organisationShownName": " Ann, Bob, Bob, \n ",
             "organisationShownCode": " OLD, NEW, NEW ", "sceneCode": "010100;010200,010100",
             "subjectCode": "01000000;02000000,01000000", "webStatementOfRights": "https://example.com/rights",
             "digitalImageGUID": "new-guid", "dateCreated": "2026-09-21", "countryCode": "no",
             "digitalSourceType": DigitalSourceType.digitalCapture.newsCodeURI, "urgency": "4"],
            ["creator": "Doe, Jane", "organisationShownName": "", "organisationShownCode": "",
             "sceneCode": "invalid", "subjectCode": "invalid", "webStatementOfRights": "",
             "digitalImageGUID": "", "dateCreated": "invalid-date", "countryCode": "invalid",
             "digitalSourceType": "invalid", "urgency": "invalid"],
            ["dateCreated": "", "urgency": "99"],
        ]
        for values in variants {
            let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            model.editingMetadata.creators = ["Ann"]
            model.editingMetadata.organisationsShownNames = ["Ann"]
            model.editingMetadata.organisationsShownCodes = ["OLD"]
            model.editingMetadata.sceneCodes = ["010100"]
            model.editingMetadata.subjectCodes = ["01000000"]
            model.editingMetadata.webStatementOfRights = "Existing"
            model.editingMetadata.digitalImageGUID = "old-guid"
            model.editingMetadata.dateCreated = "2025-01-01"
            model.editingMetadata.countryCode = "NOR"
            model.editingMetadata.digitalSourceType = .humanEdits
            model.editingMetadata.urgency = 3
            func protocolFields(_ metadata: IPTCMetadata) throws -> [String: MCPJSONValue] {
                let data = try JSONEncoder().encode(metadata)
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var fields = try #require(MCPEditorialFieldCatalog.read(from: ["metadata": object]))
                for key in MCPEditorialFieldCatalog.fieldKeys where fields[key] == nil { fields[key] = .null }
                return fields
            }
            let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
            var record = request.revisions
            record["fields"] = .object(try protocolFields(model.editingMetadata))
            record["hasXMPConflict"] = .bool(false)
            let decoded = try MCPMetadataTemplatePreview.templateFields(template(values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
            let preview = try MCPMetadataTemplatePreview.preview(request: request, templateFields: decoded, metadata: .object(record))
            model.applyTemplateFields(values, append: mode == "append")
            let expected = try protocolFields(model.editingMetadata)
            guard case .array(let changes) = preview.objectValue?["changes"] else { Issue.record("Missing changes"); return }
            #expect(changes.count == values.count)
            for change in changes {
                let item = try #require(change.objectValue)
                let key = try #require(item["field"]?.stringValue)
                #expect(item["after"] == expected[key], "Editor mismatch for \(key), mode \(mode)")
                let templateKey = item["templateField"]?.stringValue ?? key
                #expect(item["templateValue"] == values[templateKey].map(MCPJSONValue.string))
            }
            #expect(preview.objectValue?["previewOnly"] == .bool(true))
            #expect(preview.objectValue?["commitAvailable"] == .bool(false))
        }
    }

    @Test("Structured literals preserve production pairing, term identity and malformed-input behavior", arguments: ["append", "replace"])
    @MainActor func structuredEditorSemantics(mode: String) throws {
        let variants: [[String: String]] = [
            ["mediaTopic": #"[{"cvId":"urn:custom:vocabulary","cvTermId":"urn:topic:existing","cvTermName":"Replacement name"},{"termIdentifier":"urn:topic:new","name":"New; topic","refinedAbout":"urn:detail:new"},{"termIdentifier":"urn:topic:new","name":"Duplicate"}]"#,
             "genre": #"[{"termIdentifier":"urn:genre:new","name":"Feature, long-form"}]"#,
             "imageSupplier": #"[{"identifier":" agency,001 ","name":"Agency, Inc."},{"identifier":"agency,001","name":"Agency, Inc."},{"identifier":"agency,001","name":"Other label"},{"name":" Name only "},{}]"#],
            ["mediaTopic": "01000000; medtop:02000000,invalid,01000000",
             "genre": "genre:Feature;https://cv.iptc.org/newscodes/genre/News,invalid genre",
             "imageSupplier": "Invalid, flattened supplier"],
            ["mediaTopic": "", "genre": "", "imageSupplier": ""],
            ["mediaTopic": "[]", "genre": "[]", "imageSupplier": "[]"],
            ["mediaTopic": #"[{"termIdentifier":false}]"#, "genre": #"[{"termIdentifier":false}]"#,
             "imageSupplier": #"[{"identifier":false}]"#],
        ]
        func protocolFields(_ metadata: IPTCMetadata) throws -> [String: MCPJSONValue] {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
            return try #require(MCPEditorialFieldCatalog.read(from: ["metadata": object]))
        }
        for values in variants {
            let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
            model.editingMetadata.mediaTopics = [IPTCControlledVocabularyTerm(
                vocabularyIdentifier: "urn:custom:vocabulary", termIdentifier: "urn:topic:existing", name: "Original name")]
            model.editingMetadata.genres = [IPTCControlledVocabularyTerm(termIdentifier: "urn:genre:existing")]
            model.editingMetadata.imageSuppliers = [EditorialImageSupplier(identifier: "agency,001", name: "Agency, Inc.")]
            let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
            var record = request.revisions
            record["fields"] = .object(try protocolFields(model.editingMetadata))
            record["hasXMPConflict"] = .bool(false)
            let decoded = try MCPMetadataTemplatePreview.templateFields(template(values.map { ($0.key, $0.value) }))
            let result = try MCPMetadataTemplatePreview.preview(request: request, templateFields: decoded, metadata: .object(record))
            model.applyTemplateFields(values, append: mode == "append")
            let expected = try protocolFields(model.editingMetadata)
            guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
            #expect(changes.count == 3)
            for change in changes {
                let item = try #require(change.objectValue)
                let key = try #require(item["field"]?.stringValue)
                let templateKey = try #require(item["templateField"]?.stringValue)
                #expect(item["after"] == expected[key], "Structured editor mismatch for \(key), mode \(mode)")
                #expect(item["templateValue"] == values[templateKey].map(MCPJSONValue.string))
                #expect(item["changed"] == .bool(item["before"] != item["after"]))
            }
        }
    }

    @Test("Structured JSON escapes cannot smuggle variable or NUL text into either preview entry point")
    func rejectsStructuredVariables() throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments())
        var record = request.revisions
        record["fields"] = .object(["mediaTopics": .array([]), "genres": .array([]), "imageSuppliers": .array([])])
        record["hasXMPConflict"] = .bool(false)
        for key in ["mediaTopic", "genre", "imageSupplier"] {
            for value in [#"[{"name":"\u007bfilename\u007d"}]"#, #"[{"name":"\u0000"}]"#,
                          #"[{"name":"\u0028number\u0029"}]"#, #"[{"unknown":{"nested":"{initials}"}}]"#,
                          #"[{"\u007bfilename\u007d":"literal"}]"#,
                          #"[{"name":"{filename}","name":"Literal","termIdentifier":"urn:topic:test"}]"#,
                          #"[{"name":"Literal","name":"{filename}","termIdentifier":"urn:topic:test"}]"#,
                          #"[{"name":"\u007bfilename\u007d","name":"Literal","termIdentifier":"urn:topic:test"}]"#,
                          #"[{"name":"Literal","name":"\u007bfilename\u007d","termIdentifier":"urn:topic:test"}]"#,
                          #"[{"name":"\u0000","name":"Literal","termIdentifier":"urn:topic:test"}]"#,
                          #"[{"name":"Literal","name":"\u0000","termIdentifier":"urn:topic:test"}]"#,
                          "{voiceMemoTranscript}"] {
                #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                    try MCPMetadataTemplatePreview.templateFields(template([(key, value)]))
                }
                #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
                    try MCPMetadataTemplatePreview.preview(request: request, templateFields: [key: value], metadata: .object(record))
                }
            }
        }
        // Escaped quotes/backslashes cannot terminate the lexical scan early; genuine
        // literal duplicate keys and Unicode still retain production decoder semantics.
        for key in ["mediaTopic", "genre", "imageSupplier"] {
            let value = #"[{"name":"Quoted \"text\", path \\ folder, \u00e9","name":"Literal","termIdentifier":"urn:topic:test"}]"#
            #expect(try MCPMetadataTemplatePreview.templateFields(template([(key, value)]))[key] == value)
        }
    }

    @Test("Filename variables use snapshot authority and production interpolation", arguments: ["append", "replace"])
    func filenameVariable(mode: String) throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        let raw = "Photo {filename} / {filename}"
        let values = try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
        var record = request.revisions
        record["hasXMPConflict"] = .bool(false)
        record["fields"] = .object(["title": .string("Existing")])
        record["canonicalPath"] = .string("/retained/Ålesund.final.jpg")
        let result = try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
        guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
        let change = try #require(changes.first?.objectValue)
        let resolved = PresetVariableInterpolator().resolve(raw, filename: "Ålesund.final.jpg")
        #expect(change["templateValue"] == .string(raw))
        #expect(change["resolvedTemplateValue"] == .string(resolved))
        #expect(change["resolvedVariables"] == .array([.string("filename")]))
        #expect(change["after"] == .string(mode == "append" ? "Existing " + resolved : resolved))
        #expect(result.objectValue?["commitAvailable"] == .bool(false))
        record.removeValue(forKey: "canonicalPath")
        #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
        }
        for filename in ["{seq}.jpg", "{field:credit}.jpg", "(number).jpg", "brace}.jpg"] {
            record["canonicalPath"] = .string("/retained/" + filename)
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
            }
        }
        record["canonicalPath"] = .string("/retained/" + String(repeating: "a", count: 200) + ".jpg")
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            try MCPMetadataTemplatePreview.preview(request: request,
                templateFields: ["title": String(repeating: "{filename}", count: 200)], metadata: .object(record))
        }
        for value in ["{filename} {initials}", "{{filename}}", "{filename} (number)"] {
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.templateFields(template([("title", value)]))
            }
        }
    }

    @Test("Bounded sequence variables match production interpolation without caller context", arguments: ["append", "replace"])
    func sequenceVariables(mode: String) throws {
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        let raw = "{seq} / " + (1...9).map { "{seq:\($0)}" }.joined(separator: " / ")
        for key in ["title", "description", "extendedDescription", "instructions"] {
            let values = try MCPMetadataTemplatePreview.templateFields(template([(key, raw)]))
            var record = request.revisions
            record["hasXMPConflict"] = .bool(false)
            record["fields"] = .object([key: .string("Existing")])
            // Sequence-only previews do not require filename authority.
            let result = try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(record))
            guard case .array(let changes) = result.objectValue?["changes"] else { Issue.record("Missing changes"); return }
            let change = try #require(changes.first?.objectValue)
            let resolved = PresetVariableInterpolator().resolve(raw, sequenceIndex: 1)
            #expect(change["after"] == .string(mode == "append" ? "Existing " + resolved : resolved))
            #expect(change["resolvedTemplateValue"] == .string(resolved))
            #expect(change["resolvedVariables"] == .array([.string("seq")]))
            #expect(change["sequenceIndex"] == .integer(1))
            #expect(result.objectValue?["commitAvailable"] == .bool(false))
        }
        // Filename values must stay literal even when the same supported sequence
        // token already occurs in the template and would otherwise be expanded later.
        for filename in ["frame-{seq}.jpg", "frame-{seq:3}.jpg", "frame.{seq}"] {
            var record = request.revisions
            record["hasXMPConflict"] = .bool(false)
            record["fields"] = .object(["title": .null])
            record["canonicalPath"] = .string("/retained/" + filename)
            let values = try MCPMetadataTemplatePreview.templateFields(
                template([("title", "{filename} / {seq} / {seq:3}")]))
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.preview(request: request, templateFields: values,
                    metadata: .object(record))
            }
        }
        for raw in ["{seq:0}", "{seq:10}", "{seq:9999999999}", "{seq:-1}", "{seq:01}", "{seq:}", "{seq} {initials}"] {
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.templateFields(template([("title", raw)]))
            }
        }
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(template([("credit", "{seq}")]))
        }
        var args = arguments()
        args["sequenceIndex"] = .integer(100)
        #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
            try MCPMetadataTemplatePreview.Request(arguments: args)
        }
    }

    @Test("Unsupported context-dependent templates fail closed")
    func rejectsUnsupported() throws {
        for (key, value) in [("keywords", "news"), ("creatorContactInfo", "Byline"), ("unknown", "value"),
                             ("credit", "{filename}"), ("title", "(number)"), ("title", "{unknown}"), ("title", "{initials}"),
                             ("title", "{voiceMemoTranscript}"),
                             ("creator", "{persons}"), ("creator", #"["\u007bfilename\u007d"]"#), ("dateCreated", "{date}"), ("title", "\0")] {
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.templateFields(template([(key, value)]))
            }
        }
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(template([]))
        }
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(template([("title", "Literal")], instantly: true))
        }
        #expect(try MCPMetadataTemplatePreview.templateFields(template([("title", "First"), ("title", "Last")])) == ["title": "Last"])
        var malformed = try #require(JSONDecoder().decode(MCPJSONValue.self, from: template([("title", "Literal")])).objectValue)
        malformed["shortcutSlot"] = .string("invalid")
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(JSONEncoder().encode(MCPJSONValue.object(malformed)))
        }
        malformed.removeValue(forKey: "shortcutSlot")
        malformed["futureBehavior"] = .bool(true)
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(JSONEncoder().encode(MCPJSONValue.object(malformed)))
        }
    }

    @Test("Exact request fields and every photo revision are mandatory")
    func revisions() throws {
        for key in MCPMetadataTemplatePreview.argumentKeys {
            var args = arguments(); args.removeValue(forKey: key)
            #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) { try MCPMetadataTemplatePreview.Request(arguments: args) }
        }
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments())
        var metadata = request.revisions
        metadata["fields"] = .object(["title": .string("Before")])
        metadata["hasXMPConflict"] = .bool(false)
        for key in request.revisions.keys {
            var stale = metadata; stale[key] = .string("changed")
            #expect(throws: MCPMetadataTemplatePreview.Failure.staleRevision) {
                try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": "After"], metadata: .object(stale))
            }
        }
        metadata["hasXMPConflict"] = .bool(true)
        #expect(throws: MCPMetadataTemplatePreview.Failure.conflict) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": "After"], metadata: .object(metadata))
        }
    }

    @Test("Exposed endpoint binds template and photo and leaves bytes unchanged")
    func productionEndpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apa-template-preview-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let templates = root.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: false)
        let supplierValue = #"[{"identifier":"agency,001","name":"Agency, Inc."}]"#
        let data = try template([("title", "New"), ("imageSupplier", supplierValue)])
        let object = try #require(JSONDecoder().decode(MCPJSONValue.self, from: data).objectValue)
        let id = try #require(object["id"]?.stringValue)
        let templateURL = templates.appendingPathComponent(id + ".json")
        try data.write(to: templateURL)
        let photo = root.appendingPathComponent("frame.jpg")
        let pixels = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(pixels.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCHeadline: "Embedded"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (bytes as Data).write(to: photo)
        let box = MCPServerCoreTests.DataBox()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try store.addRoot(root); try store.setEnabled(true)
        let discovery = MCPTemplateDiscovery(authorizationStore: store,
            resolveScope: { .init(directory: templates, release: {}) })
        let inventory = try discovery.list(kind: "metadata")
        guard case .array(let entries) = inventory["templates"] else { Issue.record("Missing inventory"); return }
        let revision = try #require(entries.first?.objectValue?["revision"])
        let facade = MCPAutomationFacade(authorizationStore: store)
        let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
        var args = arguments()
        args["templateID"] = .string(id); args["templateRevision"] = revision; args["path"] = .string(photo.path)
        for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { args[key] = read[key] }
        let tools = MCPFoundationTools(authorizationStore: store, templateDiscovery: discovery)
        let result = tools.callTool(name: "preview_metadata_template", arguments: args)
        #expect(result.objectValue?["isError"] == .bool(false))
        let preview = try #require(result.objectValue?["structuredContent"]?.objectValue)
        #expect(preview["templateRevision"] == revision)
        #expect(preview["changes"] == .array([.object([
            "field": .string("imageSuppliers"), "templateField": .string("imageSupplier"), "before": .array([]),
            "after": .array([.object(["identifier": .string("agency,001"), "name": .string("Agency, Inc.")])]),
            "templateValue": .string(supplierValue), "changed": .bool(true)]), .object(["field": .string("title"), "before": .string("Embedded"),
            "after": .string("Embedded New"), "templateValue": .string("New"), "changed": .bool(true)])]))
        #expect(try Data(contentsOf: photo) == bytes as Data)
        #expect(try Data(contentsOf: templateURL) == data)
        args["templateRevision"] = .string("sha256:" + String(repeating: "0", count: 64))
        let stale = tools.callTool(name: "preview_metadata_template", arguments: args)
        #expect(stale.objectValue?["structuredContent"]?.objectValue?["code"] == .string("stale_template"))
        args["templateRevision"] = revision
        let changing = MCPTemplateDiscovery(authorizationStore: store,
            resolveScope: { .init(directory: templates, release: {}) }, checkpoint: {
                try? Data("changed".utf8).write(to: photo)
            })
        #expect(throws: (any Error).self) {
            try MCPMetadataTemplatePreview.prepare(arguments: args, facade: facade, discovery: changing)
        }
    }
}
