// Interoperability reference: Aagedal FTP Sync 2dc18e9.
import CryptoKit
import Foundation

/// Opaque, lossless editor metadata. Never use sourceDescription as a path or include it in diagnostics.
nonisolated struct KnownPeoplePackageEditorPayload: Codable, Equatable, Sendable {
    static let formatIdentifier = "aagedal-photo-agent-known-people-editor"
    enum ValidationError: Error { case invalidPayload }
    enum RecognitionMode: String, Codable, Sendable { case vision, faceClothing }
    struct PersonMetadata: Codable, Equatable, Sendable {
        let role: String?
        let notes: String?
        let representativeThumbnailID: UUID?
        /// Finite seconds since 2001-01-01, preserving Foundation Date precision.
        let createdAt: Double
        let updatedAt: Double
        init(role: String? = nil, notes: String? = nil, representativeThumbnailID: UUID? = nil,
             createdAt: Double, updatedAt: Double) throws {
            try KnownPeoplePackageEditorCoding.text(role, maximum: 4096); try KnownPeoplePackageEditorCoding.text(notes, maximum: 1_048_576)
            guard createdAt.isFinite, updatedAt.isFinite else { throw ValidationError.invalidPayload }
            self.role = role; self.notes = notes; self.representativeThumbnailID = representativeThumbnailID
            self.createdAt = createdAt; self.updatedAt = updatedAt
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageEditorCoding.object(decoder, required: ["createdAt", "updatedAt"], optional: ["role", "notes", "representativeThumbnailID"])
            let representative: UUID? = c.contains(.init("representativeThumbnailID")) ? try KnownPeoplePackageEditorCoding.id(c.decode(String.self, forKey: .init("representativeThumbnailID"))) : nil
            try self.init(role: KnownPeoplePackageEditorCoding.optional(String.self, c, "role"), notes: KnownPeoplePackageEditorCoding.optional(String.self, c, "notes"),
                          representativeThumbnailID: representative, createdAt: c.decode(Double.self, forKey: .init("createdAt")), updatedAt: c.decode(Double.self, forKey: .init("updatedAt")))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: KnownPeoplePackageEditorCoding.Key.self)
            try c.encodeIfPresent(role, forKey: .init("role")); try c.encodeIfPresent(notes, forKey: .init("notes"))
            try c.encodeIfPresent(representativeThumbnailID?.uuidString.lowercased(), forKey: .init("representativeThumbnailID"))
            try c.encode(createdAt, forKey: .init("createdAt")); try c.encode(updatedAt, forKey: .init("updatedAt"))
        }
    }
    struct ExampleMetadata: Codable, Equatable, Sendable {
        let sourceDescription: String?
        let addedAt: Double
        let recognitionMode: RecognitionMode?
        init(sourceDescription: String? = nil, addedAt: Double, recognitionMode: RecognitionMode? = nil) throws {
            try KnownPeoplePackageEditorCoding.text(sourceDescription, maximum: 65_536)
            guard addedAt.isFinite else { throw ValidationError.invalidPayload }
            self.sourceDescription = sourceDescription; self.addedAt = addedAt; self.recognitionMode = recognitionMode
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageEditorCoding.object(decoder, required: ["addedAt"], optional: ["sourceDescription", "recognitionMode"])
            try self.init(sourceDescription: KnownPeoplePackageEditorCoding.optional(String.self, c, "sourceDescription"),
                          addedAt: c.decode(Double.self, forKey: .init("addedAt")), recognitionMode: KnownPeoplePackageEditorCoding.optional(RecognitionMode.self, c, "recognitionMode"))
        }
    }
    let format: String
    let schemaVersion: Int
    let libraryID: UUID
    let coreRevision: String
    let people: [String: PersonMetadata]
    let examples: [String: ExampleMetadata]

    init(libraryID: UUID, coreRevision: String, people: [String: PersonMetadata], examples: [String: ExampleMetadata]) throws {
        _ = try KnownPeoplePackageEditorCoding.id(libraryID.uuidString.lowercased())
        guard coreRevision.count == 64, coreRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ValidationError.invalidPayload }
        for key in people.keys { _ = try KnownPeoplePackageEditorCoding.id(key) }
        for key in examples.keys { _ = try KnownPeoplePackageEditorCoding.id(key) }
        format = Self.formatIdentifier; schemaVersion = 1; self.libraryID = libraryID; self.coreRevision = coreRevision
        self.people = people; self.examples = examples
    }
    init(from decoder: Decoder) throws {
        let c = try KnownPeoplePackageEditorCoding.object(decoder, required: ["format", "schemaVersion", "libraryID", "coreRevision", "people", "examples"])
        guard try c.decode(String.self, forKey: .init("format")) == Self.formatIdentifier,
              try c.decode(Int.self, forKey: .init("schemaVersion")) == 1 else { throw ValidationError.invalidPayload }
        try self.init(libraryID: KnownPeoplePackageEditorCoding.id(c.decode(String.self, forKey: .init("libraryID"))),
                      coreRevision: c.decode(String.self, forKey: .init("coreRevision")),
                      people: c.decode([String: PersonMetadata].self, forKey: .init("people")),
                      examples: c.decode([String: ExampleMetadata].self, forKey: .init("examples")))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KnownPeoplePackageEditorCoding.Key.self)
        try c.encode(format, forKey: .init("format")); try c.encode(schemaVersion, forKey: .init("schemaVersion"))
        try c.encode(libraryID.uuidString.lowercased(), forKey: .init("libraryID")); try c.encode(coreRevision, forKey: .init("coreRevision"))
        try c.encode(people, forKey: .init("people")); try c.encode(examples, forKey: .init("examples"))
    }
    static func decode(_ data: Data, manifest: KnownPeoplePackageManifest, payload: KnownPeoplePackagePayload,
                       limits: KnownPeoplePackageManifest.Limits = .init()) throws -> Self {
        try manifest.validate(payload: payload, limits: limits)
        guard let descriptor = manifest.editorPayload, data.count <= limits.maximumFileBytes,
              data.count == descriptor.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256 else { throw ValidationError.invalidPayload }
        try KnownPeoplePackageManifest.validateJSONStructure(data)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(manifest: manifest, payload: payload)
        return value
    }
    func validate(manifest: KnownPeoplePackageManifest, payload: KnownPeoplePackagePayload) throws {
        guard libraryID == manifest.libraryID, coreRevision == manifest.coreRevision else { throw ValidationError.invalidPayload }
        let personIDs = Set(payload.people.map { $0.id.uuidString.lowercased() })
        let exampleIDs = Set(payload.people.flatMap { $0.examples.map { $0.id.uuidString.lowercased() } })
        guard Set(people.keys) == personIDs, Set(examples.keys) == exampleIDs else { throw ValidationError.invalidPayload }
        for person in payload.people {
            if let representative = people[person.id.uuidString.lowercased()]?.representativeThumbnailID {
                guard person.examples.contains(where: { $0.id == representative }) else { throw ValidationError.invalidPayload }
            }
        }
    }
}

nonisolated private enum KnownPeoplePackageEditorCoding {
    struct Key: CodingKey { let stringValue: String; var intValue: Int? { nil }; init(_ value: String) { stringValue = value }; init?(stringValue: String) { self.init(stringValue) }; init?(intValue: Int) { return nil } }
    static func object(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws -> KeyedDecodingContainer<Key> {
        let c = try decoder.container(keyedBy: Key.self); let keys = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw KnownPeoplePackageEditorPayload.ValidationError.invalidPayload }
        return c
    }
    static func optional<T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<Key>, _ key: String) throws -> T? {
        c.contains(.init(key)) ? try c.decode(type, forKey: .init(key)) : nil
    }
    static func id(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value,
              value != "00000000-0000-0000-0000-000000000000" else { throw KnownPeoplePackageEditorPayload.ValidationError.invalidPayload }
        return id
    }
    static func text(_ value: String?, maximum: Int) throws {
        guard value.map({ $0.utf8.count <= maximum }) ?? true else { throw KnownPeoplePackageEditorPayload.ValidationError.invalidPayload }
    }
}
