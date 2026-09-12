// Interoperability reference: Aagedal FTP Sync 2dc18e9.
import CryptoKit
import Foundation

/// Shared schema-2 contract mirrored from FTP Sync source 2dc18e9.
/// Keep canonical revision inputs aligned with the cross-app golden fixture.
/// These types perform no extraction, filesystem access, or snapshot publication.
nonisolated struct KnownPeoplePackageManifest: Codable, Equatable, Sendable {
    static let fileName = "manifest.json"
    static let payloadFileName = "people.json"
    static let formatIdentifier = "aagedal-known-people"

    enum ValidationError: Error, Equatable {
        case invalidSchema, invalidContract, invalidIdentity, invalidDate, invalidPath
        case invalidHash, invalidCounts, exceededLimit, duplicateIdentity, duplicatePath
        case invalidReference, revisionMismatch, invalidPayload, invalidLimits
    }

    /// Conservative admission ceilings, not calibrated throughput guarantees.
    /// Callers may tighten these; increasing a ceiling requires a contract review.
    struct Limits: Equatable, Sendable {
        var maximumPeople = 10_000
        var maximumEmbeddings = 100_000
        var maximumFiles = 200_001
        var maximumFileBytes = 16_777_216
        var maximumTotalBytes = 500_000_000
        var maximumManifestBytes = 16_777_216
        var maximumPayloadBytes = 16_777_216
        var maximumNameUTF8Bytes = 1_024

        func validate() throws {
            let baseline = Self()
            let pairs = [(maximumPeople, baseline.maximumPeople), (maximumEmbeddings, baseline.maximumEmbeddings),
                (maximumFiles, baseline.maximumFiles), (maximumFileBytes, baseline.maximumFileBytes),
                (maximumTotalBytes, baseline.maximumTotalBytes), (maximumManifestBytes, baseline.maximumManifestBytes),
                (maximumPayloadBytes, baseline.maximumPayloadBytes), (maximumNameUTF8Bytes, baseline.maximumNameUTF8Bytes)]
            guard pairs.allSatisfy({ $0.0 > 0 && $0.0 <= $0.1 }) else { throw ValidationError.invalidLimits }
        }
    }

    struct EmbeddingContract: Codable, Equatable, Sendable {
        static let auraFaceV1 = Self()
        var embeddingSpaceVersion: Int { 3 }
        var componentID: String { "auraface-r100-coreml" }
        var modelID: String { "AuraFace-v1/glintr100" }
        var preprocessingRevision: String { "photo-agent-eyes112-rgb-v3" }
        var vectorEncoding: String { "fem2-float32-le" }
        var dimension: Int { 512 }
        var l2Normalized: Bool { true }
        private init() {}
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageCoding.object(decoder, required: ["embeddingSpaceVersion", "componentID", "modelID", "preprocessingRevision", "vectorEncoding", "dimension", "l2Normalized"])
            self.init()
            guard try c.decode(Int.self, forKey: .init("embeddingSpaceVersion")) == embeddingSpaceVersion,
                  try c.decode(String.self, forKey: .init("componentID")) == componentID,
                  try c.decode(String.self, forKey: .init("modelID")) == modelID,
                  try c.decode(String.self, forKey: .init("preprocessingRevision")) == preprocessingRevision,
                  try c.decode(String.self, forKey: .init("vectorEncoding")) == vectorEncoding,
                  try c.decode(Int.self, forKey: .init("dimension")) == dimension,
                  try c.decode(Bool.self, forKey: .init("l2Normalized")) == true else { throw ValidationError.invalidContract }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: KnownPeoplePackageCoding.Key.self)
            try c.encode(embeddingSpaceVersion, forKey: .init("embeddingSpaceVersion"))
            try c.encode(componentID, forKey: .init("componentID")); try c.encode(modelID, forKey: .init("modelID"))
            try c.encode(preprocessingRevision, forKey: .init("preprocessingRevision")); try c.encode(vectorEncoding, forKey: .init("vectorEncoding"))
            try c.encode(dimension, forKey: .init("dimension")); try c.encode(l2Normalized, forKey: .init("l2Normalized"))
        }
    }

    struct Exporter: Codable, Equatable, Sendable {
        let app: String
        let version: String
        let sourceRevision: String
        init(app: String, version: String, sourceRevision: String) throws {
            guard KnownPeoplePackageCoding.text(app, maximumBytes: 128), KnownPeoplePackageCoding.text(version, maximumBytes: 128),
                  sourceRevision.utf8.count == 40, KnownPeoplePackageCoding.lowerHex(sourceRevision) else { throw ValidationError.invalidIdentity }
            self.app = app; self.version = version; self.sourceRevision = sourceRevision
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageCoding.object(decoder, required: ["app", "version", "sourceRevision"])
            try self.init(app: c.decode(String.self, forKey: .init("app")), version: c.decode(String.self, forKey: .init("version")),
                sourceRevision: c.decode(String.self, forKey: .init("sourceRevision")))
        }
    }

    struct FileDeclaration: Codable, Equatable, Sendable {
        let path: String
        let byteCount: Int
        let sha256: String
        init(path: String, byteCount: Int, sha256: String) throws {
            try KnownPeoplePackageCoding.validatePath(path)
            guard byteCount > 0, byteCount <= Limits().maximumFileBytes else { throw ValidationError.exceededLimit }
            guard sha256.utf8.count == 64, KnownPeoplePackageCoding.lowerHex(sha256) else { throw ValidationError.invalidHash }
            if path.hasPrefix("embeddings/") {
                guard byteCount == FaceEmbeddingInterchangeCodec.byteCount else { throw ValidationError.invalidPayload }
            }
            self.path = path; self.byteCount = byteCount; self.sha256 = sha256
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageCoding.object(decoder, required: ["path", "byteCount", "sha256"])
            try self.init(path: c.decode(String.self, forKey: .init("path")), byteCount: c.decode(Int.self, forKey: .init("byteCount")),
                sha256: c.decode(String.self, forKey: .init("sha256")))
        }
    }

    struct EditorPayloadDescriptor: Codable, Equatable, Sendable {
        static let filePath = "editor/photo-agent.json"
        static let contentType = "application/vnd.aagedal.photo-agent-known-people+json;version=1"
        let path: String
        let mediaType: String
        let byteCount: Int
        let sha256: String
        init(byteCount: Int, sha256: String) throws {
            path = Self.filePath; mediaType = Self.contentType
            let file = try FileDeclaration(path: path, byteCount: byteCount, sha256: sha256)
            self.byteCount = file.byteCount; self.sha256 = file.sha256
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageCoding.object(decoder, required: ["path", "mediaType", "byteCount", "sha256"])
            guard try c.decode(String.self, forKey: .init("path")) == Self.filePath,
                  try c.decode(String.self, forKey: .init("mediaType")) == Self.contentType else { throw ValidationError.invalidSchema }
            try self.init(byteCount: c.decode(Int.self, forKey: .init("byteCount")), sha256: c.decode(String.self, forKey: .init("sha256")))
        }
    }

    let format: String
    let schemaVersion: Int
    let libraryID: UUID
    let revision: String
    let coreRevision: String
    let editorPayload: EditorPayloadDescriptor?
    /// Exactly yyyy-MM-dd'T'HH:mm:ss.SSS'Z', in UTC; independent of JSON date strategies.
    let exportedAt: String
    let exporter: Exporter
    let contract: EmbeddingContract
    let peopleCount: Int
    let embeddingCount: Int
    let files: [FileDeclaration]

    init(libraryID: UUID, exportedAt: String, exporter: Exporter, peopleCount: Int, embeddingCount: Int,
         files: [FileDeclaration], contract: EmbeddingContract = .auraFaceV1, editorPayload: EditorPayloadDescriptor? = nil) throws {
        format = Self.formatIdentifier; schemaVersion = 2
        self.libraryID = libraryID; self.exportedAt = exportedAt; self.exporter = exporter
        self.peopleCount = peopleCount; self.embeddingCount = embeddingCount; self.files = files; self.contract = contract
        self.editorPayload = editorPayload
        coreRevision = try Self.revision(libraryID: libraryID, contract: contract, peopleCount: peopleCount, embeddingCount: embeddingCount,
            files: files.filter { $0.path != EditorPayloadDescriptor.filePath })
        revision = try Self.overallRevision(coreRevision: coreRevision, editorPayload: editorPayload)
        try validate()
    }

    static func decode(_ data: Data, limits: Limits = .init()) throws -> Self {
        try limits.validate()
        guard data.count <= limits.maximumManifestBytes else { throw ValidationError.exceededLimit }
        try KnownPeoplePackageCoding.validateJSON(data)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(limits: limits)
        return value
    }

    /// Shared by small local pointer records that need the same duplicate-key,
    /// nesting and trailing-content rejection before Codable chooses any value.
    static func validateJSONStructure(_ data: Data) throws {
        try KnownPeoplePackageCoding.validateJSON(data)
    }

    func validate(limits: Limits = .init()) throws {
        try limits.validate()
        guard format == Self.formatIdentifier, schemaVersion == 2 else { throw ValidationError.invalidSchema }
        try KnownPeoplePackageCoding.validateID(libraryID)
        guard revision.utf8.count == 64, KnownPeoplePackageCoding.lowerHex(revision) else { throw ValidationError.invalidHash }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard exportedAt.utf8.count == 24, let date = formatter.date(from: exportedAt), formatter.string(from: date) == exportedAt else {
            throw ValidationError.invalidDate
        }
        guard (0...limits.maximumPeople).contains(peopleCount), (0...limits.maximumEmbeddings).contains(embeddingCount),
              embeddingCount >= peopleCount, (peopleCount == 0) == (embeddingCount == 0),
              files.count <= limits.maximumFiles else { throw ValidationError.invalidCounts }
        var paths: Set<String> = [], total = 0
        for file in files {
            try KnownPeoplePackageCoding.validatePath(file.path)
            guard paths.insert(file.path.lowercased()).inserted else { throw ValidationError.duplicatePath }
            guard file.byteCount <= limits.maximumFileBytes, file.byteCount <= limits.maximumTotalBytes - total else { throw ValidationError.exceededLimit }
            if file.path == Self.payloadFileName, file.byteCount > limits.maximumPayloadBytes { throw ValidationError.exceededLimit }
            total += file.byteCount
        }
        guard paths.contains(Self.payloadFileName), files.filter({ $0.path.hasPrefix("embeddings/") }).count == embeddingCount else {
            throw ValidationError.invalidCounts
        }
        let editorFiles = files.filter { $0.path == EditorPayloadDescriptor.filePath }
        if let editorPayload {
            guard editorFiles.count == 1, editorFiles[0].byteCount == editorPayload.byteCount,
                  editorFiles[0].sha256 == editorPayload.sha256 else { throw ValidationError.invalidReference }
        } else if !editorFiles.isEmpty { throw ValidationError.invalidReference }
        guard try Self.revision(libraryID: libraryID, contract: contract, peopleCount: peopleCount, embeddingCount: embeddingCount,
                  files: files.filter { $0.path != EditorPayloadDescriptor.filePath }) == coreRevision,
              try Self.overallRevision(coreRevision: coreRevision, editorPayload: editorPayload) == revision else {
            throw ValidationError.revisionMismatch
        }
    }

    func validate(payload: KnownPeoplePackagePayload, limits: Limits = .init()) throws {
        try validate(limits: limits); try payload.validate(limits: limits)
        var referenced: Set<String> = [Self.payloadFileName]
        if editorPayload != nil { referenced.insert(EditorPayloadDescriptor.filePath) }
        var examples = 0
        for person in payload.people {
            if let path = person.thumbnailPath { guard referenced.insert(path).inserted else { throw ValidationError.duplicatePath } }
            for example in person.examples {
                examples += 1
                guard referenced.insert(example.embeddingPath).inserted else { throw ValidationError.duplicatePath }
                if let path = example.thumbnailPath { guard referenced.insert(path).inserted else { throw ValidationError.duplicatePath } }
            }
        }
        guard payload.people.count == peopleCount, examples == embeddingCount else { throw ValidationError.invalidCounts }
        guard referenced == Set(files.map(\.path)) else { throw ValidationError.invalidReference }
    }

    /// Canonical UTF-8 JSON with sorted keys/unescaped slashes and lowercase UUID;
    /// file declarations are sorted by ASCII path. Export time/exporter are excluded.
    private static func revision(libraryID: UUID, contract: EmbeddingContract, peopleCount: Int, embeddingCount: Int, files: [FileDeclaration]) throws -> String {
        struct RevisionInput: Encodable {
            let format: String; let schemaVersion: Int; let libraryID: String; let contract: EmbeddingContract
            let peopleCount: Int; let embeddingCount: Int; let files: [FileDeclaration]
        }
        let value = RevisionInput(format: formatIdentifier, schemaVersion: 2, libraryID: libraryID.uuidString.lowercased(), contract: contract,
            peopleCount: peopleCount, embeddingCount: embeddingCount, files: files.sorted { $0.path < $1.path })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// Separate domain prevents an editor-only change from changing recognition identity.
    private static func overallRevision(coreRevision: String, editorPayload: EditorPayloadDescriptor?) throws -> String {
        struct Input: Encodable { let format: String; let schemaVersion: Int; let coreRevision: String; let editorPayload: EditorPayloadDescriptor? }
        let value = Input(format: "aagedal-known-people-snapshot", schemaVersion: 2, coreRevision: coreRevision, editorPayload: editorPayload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: Decoder) throws {
        let c = try KnownPeoplePackageCoding.object(decoder, required: ["format", "schemaVersion", "libraryID", "revision", "coreRevision", "exportedAt", "exporter", "contract", "peopleCount", "embeddingCount", "files"], optional: ["editorPayload"])
        format = try c.decode(String.self, forKey: .init("format")); schemaVersion = try c.decode(Int.self, forKey: .init("schemaVersion"))
        guard format == Self.formatIdentifier, schemaVersion == 2 else { throw ValidationError.invalidSchema }
        contract = try c.decode(EmbeddingContract.self, forKey: .init("contract"))
        libraryID = try KnownPeoplePackageCoding.id(from: c, key: "libraryID"); revision = try c.decode(String.self, forKey: .init("revision"))
        coreRevision = try c.decode(String.self, forKey: .init("coreRevision"))
        editorPayload = c.contains(.init("editorPayload")) ? try c.decode(EditorPayloadDescriptor.self, forKey: .init("editorPayload")) : nil
        exportedAt = try c.decode(String.self, forKey: .init("exportedAt")); exporter = try c.decode(Exporter.self, forKey: .init("exporter"))
        peopleCount = try c.decode(Int.self, forKey: .init("peopleCount")); embeddingCount = try c.decode(Int.self, forKey: .init("embeddingCount"))
        files = try KnownPeoplePackageCoding.array(FileDeclaration.self, from: c, key: "files", maximum: Limits().maximumFiles)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: KnownPeoplePackageCoding.Key.self)
        try c.encode(format, forKey: .init("format")); try c.encode(schemaVersion, forKey: .init("schemaVersion"))
        try c.encode(libraryID.uuidString.lowercased(), forKey: .init("libraryID")); try c.encode(revision, forKey: .init("revision"))
        try c.encode(coreRevision, forKey: .init("coreRevision"))
        try c.encodeIfPresent(editorPayload, forKey: .init("editorPayload"))
        try c.encode(exportedAt, forKey: .init("exportedAt")); try c.encode(exporter, forKey: .init("exporter"))
        try c.encode(contract, forKey: .init("contract")); try c.encode(peopleCount, forKey: .init("peopleCount"))
        try c.encode(embeddingCount, forKey: .init("embeddingCount")); try c.encode(files, forKey: .init("files"))
    }
}

nonisolated struct KnownPeoplePackagePayload: Codable, Equatable, Sendable {
    struct Example: Codable, Equatable, Sendable {
        let id: UUID
        let embeddingPath: String
        let thumbnailPath: String?
        init(id: UUID, embeddingPath: String, thumbnailPath: String? = nil) throws {
            try KnownPeoplePackageCoding.validateID(id)
            guard embeddingPath == "embeddings/\(id.uuidString.lowercased()).fem2",
                  thumbnailPath == nil || thumbnailPath == "embedding_thumbnails/\(id.uuidString.lowercased()).jpg" else {
                throw KnownPeoplePackageManifest.ValidationError.invalidReference
            }
            self.id = id; self.embeddingPath = embeddingPath; self.thumbnailPath = thumbnailPath
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageCoding.object(decoder, required: ["id", "embeddingPath"], optional: ["thumbnailPath"])
            try self.init(id: KnownPeoplePackageCoding.id(from: c, key: "id"), embeddingPath: c.decode(String.self, forKey: .init("embeddingPath")),
                thumbnailPath: c.contains(.init("thumbnailPath")) ? c.decode(String.self, forKey: .init("thumbnailPath")) : nil)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: KnownPeoplePackageCoding.Key.self)
            try c.encode(id.uuidString.lowercased(), forKey: .init("id")); try c.encode(embeddingPath, forKey: .init("embeddingPath"))
            try c.encodeIfPresent(thumbnailPath, forKey: .init("thumbnailPath"))
        }
    }
    struct Person: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        let examples: [Example]
        let thumbnailPath: String?
        init(id: UUID, name: String, examples: [Example], thumbnailPath: String? = nil) throws {
            try KnownPeoplePackageCoding.validateID(id)
            guard KnownPeoplePackageCoding.text(name, maximumBytes: KnownPeoplePackageManifest.Limits().maximumNameUTF8Bytes), !examples.isEmpty,
                  examples.count <= KnownPeoplePackageManifest.Limits().maximumEmbeddings,
                  thumbnailPath == nil || thumbnailPath == "thumbnails/\(id.uuidString.lowercased()).jpg" else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
            self.id = id; self.name = name; self.examples = examples; self.thumbnailPath = thumbnailPath
        }
        init(from decoder: Decoder) throws {
            let c = try KnownPeoplePackageCoding.object(decoder, required: ["id", "name", "examples"], optional: ["thumbnailPath"])
            try self.init(id: KnownPeoplePackageCoding.id(from: c, key: "id"), name: c.decode(String.self, forKey: .init("name")),
                examples: KnownPeoplePackageCoding.array(Example.self, from: c, key: "examples", maximum: KnownPeoplePackageManifest.Limits().maximumEmbeddings),
                thumbnailPath: c.contains(.init("thumbnailPath")) ? c.decode(String.self, forKey: .init("thumbnailPath")) : nil)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: KnownPeoplePackageCoding.Key.self)
            try c.encode(id.uuidString.lowercased(), forKey: .init("id")); try c.encode(name, forKey: .init("name"))
            try c.encode(examples, forKey: .init("examples")); try c.encodeIfPresent(thumbnailPath, forKey: .init("thumbnailPath"))
        }
    }
    let people: [Person]
    init(people: [Person]) throws { self.people = people; try validate() }
    static func decode(_ data: Data, limits: KnownPeoplePackageManifest.Limits = .init()) throws -> Self {
        try limits.validate()
        guard data.count <= limits.maximumPayloadBytes else { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
        try KnownPeoplePackageCoding.validateJSON(data)
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(limits: limits); return value
    }
    func validate(limits: KnownPeoplePackageManifest.Limits = .init()) throws {
        try limits.validate()
        guard people.count <= limits.maximumPeople else { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
        var ids: Set<UUID> = [], examples: Set<UUID> = []
        for person in people {
            guard ids.insert(person.id).inserted else { throw KnownPeoplePackageManifest.ValidationError.duplicateIdentity }
            guard person.name.utf8.count <= limits.maximumNameUTF8Bytes else { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
            for example in person.examples {
                guard examples.count < limits.maximumEmbeddings else { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
                guard examples.insert(example.id).inserted else { throw KnownPeoplePackageManifest.ValidationError.duplicateIdentity }
            }
        }
    }
    init(from decoder: Decoder) throws {
        let c = try KnownPeoplePackageCoding.object(decoder, required: ["people"])
        people = try KnownPeoplePackageCoding.array(Person.self, from: c, key: "people", maximum: KnownPeoplePackageManifest.Limits().maximumPeople)
        try validate()
    }
}

nonisolated private enum KnownPeoplePackageCoding {
    /// Foundation's keyed containers cannot report duplicate JSON keys. The
    /// bounded admission entry points inspect raw keys before Codable decoding.
    static func validateJSON(_ data: Data) throws {
        var scanner = JSONKeys(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
    }
    private struct JSONKeys {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
            index += 1
        }
        mutating func string() throws -> Range<Int> {
            whitespace(); let start = index
            try consume(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return start..<index }
                guard byte >= 32 else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
                if byte == 92 {
                    guard index < bytes.count else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
                    index += 1
                }
            }
            throw KnownPeoplePackageManifest.ValidationError.invalidPayload
        }
        mutating func value(depth: Int) throws {
            guard depth < 64 else { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
            whitespace()
            guard index < bytes.count else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
            switch bytes[index] {
            case 123:
                index += 1; whitespace(); var keys: Set<String> = []
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let range = try string()
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
                    guard keys.insert(key).inserted else { throw KnownPeoplePackageManifest.ValidationError.invalidSchema }
                    try consume(58); try value(depth: depth + 1); whitespace()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try consume(44)
                }
            case 91:
                index += 1; whitespace()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw KnownPeoplePackageManifest.ValidationError.invalidPayload }
            }
        }
    }
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    static func object(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws -> KeyedDecodingContainer<Key> {
        let c = try decoder.container(keyedBy: Key.self)
        let keys = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw KnownPeoplePackageManifest.ValidationError.invalidSchema }
        return c
    }
    static func array<T: Decodable>(_ type: T.Type, from c: KeyedDecodingContainer<Key>, key: String, maximum: Int) throws -> [T] {
        var values = try c.nestedUnkeyedContainer(forKey: Key(key)), result: [T] = []
        if let count = values.count, count > maximum { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
        while !values.isAtEnd {
            guard result.count < maximum else { throw KnownPeoplePackageManifest.ValidationError.exceededLimit }
            result.append(try values.decode(T.self))
        }
        return result
    }
    static func lowerHex(_ text: String) -> Bool { text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func id(from c: KeyedDecodingContainer<Key>, key: String) throws -> UUID {
        let raw = try c.decode(String.self, forKey: Key(key))
        guard let id = UUID(uuidString: raw), raw == id.uuidString.lowercased() else { throw KnownPeoplePackageManifest.ValidationError.invalidIdentity }
        try validateID(id)
        return id
    }
    static func text(_ text: String, maximumBytes: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumBytes && !text.contains("\0")
    }
    static func validateID(_ id: UUID) throws {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000" else { throw KnownPeoplePackageManifest.ValidationError.invalidIdentity }
    }
    static func validatePath(_ path: String) throws {
        if path == KnownPeoplePackageManifest.payloadFileName || path == KnownPeoplePackageManifest.EditorPayloadDescriptor.filePath { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { throw KnownPeoplePackageManifest.ValidationError.invalidPath }
        let folder = String(components[0]), name = String(components[1])
        let suffix: String
        switch folder {
        case "embeddings": suffix = ".fem2"
        case "thumbnails", "embedding_thumbnails": suffix = ".jpg"
        default: throw KnownPeoplePackageManifest.ValidationError.invalidPath
        }
        guard name.hasSuffix(suffix), let id = UUID(uuidString: String(name.dropLast(suffix.count))),
              name == id.uuidString.lowercased() + suffix else { throw KnownPeoplePackageManifest.ValidationError.invalidPath }
        try validateID(id)
    }
}
