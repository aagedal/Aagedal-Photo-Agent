import Foundation

// MARK: - Top-Level

/// Parsed C2PA (Coalition for Content Provenance and Authenticity) data from an image.
public struct C2PAData: Sendable {
    /// All manifests in the manifest store, in order.
    public let manifests: [C2PAManifest]

    /// The active manifest (last in the store, whose bindings apply to the current asset).
    public var activeManifest: C2PAManifest? {
        manifests.last
    }

    public init(manifests: [C2PAManifest]) {
        self.manifests = manifests
    }

    /// Read a sidecar `.c2pa` file: a raw JUMBF byte stream paired with an
    /// asset. Returns nil if the data does not begin with a `jumb` box.
    public static func readSidecar(from data: Data) throws -> C2PAData? {
        guard let jumbf = C2PAReader.extractJUMBFFromSidecar(data) else { return nil }
        return try C2PAReader.parseManifestStore(from: jumbf)
    }

    /// Read a sidecar `.c2pa` file from a URL.
    public static func readSidecar(from url: URL) throws -> C2PAData? {
        // Map rather than copy — provenance-heavy C2PA manifests can reach
        // multi-MB (cloud-rendered chains with embedded thumbnails).
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try readSidecar(from: data)
    }
}

// MARK: - Manifest

/// A single C2PA manifest containing a claim, signature, and assertions.
public struct C2PAManifest: Sendable {
    /// The manifest label (URN identifier, e.g. "urn:c2pa:{uuid}").
    public let label: String
    /// The parsed claim.
    public let claim: C2PAClaim
    /// The parsed claim signature.
    public let signature: C2PASignature
    /// Parsed assertions from the assertion store.
    public let assertions: [C2PAAssertion]

    public init(label: String, claim: C2PAClaim, signature: C2PASignature, assertions: [C2PAAssertion]) {
        self.label = label
        self.claim = claim
        self.signature = signature
        self.assertions = assertions
    }
}

// MARK: - Claim

/// A parsed C2PA claim (CBOR-encoded).
public struct C2PAClaim: Sendable {
    /// The claim generator string (v1) or name from generator info (v2).
    public let claimGenerator: String
    /// Structured generator info (v2 only).
    public let claimGeneratorInfo: C2PAGeneratorInfo?
    /// Unique instance identifier for this version of the asset.
    public let instanceID: String?
    /// Media type (v1: dc:format).
    public let format: String?
    /// Asset title (dc:title).
    public let title: String?
    /// Hash algorithm used for assertions (e.g. "sha256").
    public let algorithm: String?
    /// Referenced assertions with their hashes.
    public let assertionReferences: [C2PAHashedURI]
    /// The full decoded CBOR claim for custom field access.
    public let raw: CBORValue
    /// Raw CBOR bytes of the claim's `cbor` content box. These are the
    /// detached payload that the manifest's COSE_Sign1 was computed over —
    /// `verifySignature()` needs them to reconstruct `Sig_structure`.
    public let rawCBORBytes: Data

    public init(
        claimGenerator: String,
        claimGeneratorInfo: C2PAGeneratorInfo? = nil,
        instanceID: String? = nil,
        format: String? = nil,
        title: String? = nil,
        algorithm: String? = nil,
        assertionReferences: [C2PAHashedURI] = [],
        raw: CBORValue = .null,
        rawCBORBytes: Data = Data()
    ) {
        self.claimGenerator = claimGenerator
        self.claimGeneratorInfo = claimGeneratorInfo
        self.instanceID = instanceID
        self.format = format
        self.title = title
        self.algorithm = algorithm
        self.assertionReferences = assertionReferences
        self.raw = raw
        self.rawCBORBytes = rawCBORBytes
    }
}

/// Structured claim generator information (C2PA v2).
public struct C2PAGeneratorInfo: Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// A hashed URI reference to an assertion or resource.
public struct C2PAHashedURI: Sendable {
    /// JUMBF URI (e.g. "self#jumbf=/c2pa/{manifest}/c2pa.assertions/{label}").
    public let url: String
    /// Hash algorithm identifier (e.g. "sha256").
    public let algorithm: String?
    /// Hash value.
    public let hash: Data

    public init(url: String, algorithm: String? = nil, hash: Data = Data()) {
        self.url = url
        self.algorithm = algorithm
        self.hash = hash
    }
}

// MARK: - Signature

/// A parsed C2PA claim signature (COSE Sign1).
public struct C2PASignature: Sendable {
    /// The signing algorithm.
    public let algorithm: C2PASignatureAlgorithm?
    /// DER-encoded X.509 certificate chain (if present in protected header).
    public let certificateChain: [Data]
    /// RFC 3161 timestamp token (DER-encoded, if present).
    public let timestamp: Data?
    /// Raw signature bytes.
    public let signatureBytes: Data
    /// The full decoded COSE Sign1 structure for custom access.
    public let raw: CBORValue

    public init(
        algorithm: C2PASignatureAlgorithm? = nil,
        certificateChain: [Data] = [],
        timestamp: Data? = nil,
        signatureBytes: Data = Data(),
        raw: CBORValue = .null
    ) {
        self.algorithm = algorithm
        self.certificateChain = certificateChain
        self.timestamp = timestamp
        self.signatureBytes = signatureBytes
        self.raw = raw
    }
}

/// COSE signature algorithm identifiers used by C2PA.
public enum C2PASignatureAlgorithm: Sendable, CustomStringConvertible {
    case es256    // ECDSA P-256 + SHA-256 (COSE -7)
    case es384    // ECDSA P-384 + SHA-384 (COSE -35)
    case es512    // ECDSA P-521 + SHA-512 (COSE -36)
    case ps256    // RSASSA-PSS + SHA-256 (COSE -37)
    case ps384    // RSASSA-PSS + SHA-384 (COSE -38)
    case ps512    // RSASSA-PSS + SHA-512 (COSE -39)
    case edDSA    // Edwards-curve DSA (COSE -8)
    case unknown(Int64)

    /// Create from a COSE algorithm integer value.
    public init(coseValue: Int64) {
        switch coseValue {
        case -7:  self = .es256
        case -35: self = .es384
        case -36: self = .es512
        case -37: self = .ps256
        case -38: self = .ps384
        case -39: self = .ps512
        case -8:  self = .edDSA
        default:  self = .unknown(coseValue)
        }
    }

    public var description: String {
        switch self {
        case .es256: return "ES256"
        case .es384: return "ES384"
        case .es512: return "ES512"
        case .ps256: return "PS256"
        case .ps384: return "PS384"
        case .ps512: return "PS512"
        case .edDSA: return "EdDSA"
        case .unknown(let v): return "Unknown(\(v))"
        }
    }
}

// MARK: - Assertions

/// A parsed C2PA assertion.
public struct C2PAAssertion: Sendable {
    /// The assertion label (e.g. "c2pa.actions", "c2pa.hash.data", "c2pa.ingredient").
    public let label: String
    /// Parsed assertion content.
    public let content: C2PAAssertionContent

    public init(label: String, content: C2PAAssertionContent) {
        self.label = label
        self.content = content
    }
}

/// Typed assertion content.
public enum C2PAAssertionContent: Sendable {
    /// Action assertion (c2pa.actions / c2pa.actions.v2).
    case actions(C2PAActions)
    /// Data hash assertion (c2pa.hash.data).
    case hashData(C2PAHashData)
    /// Ingredient assertion (c2pa.ingredient / c2pa.ingredient.v3).
    case ingredient(C2PAIngredient)
    /// Thumbnail binary data with format string (e.g. "jpeg", "png").
    case thumbnail(Data, format: String)
    /// BMFF box-level hash assertion (c2pa.hash.boxes).
    case hashBoxes(C2PAHashBoxes)
    /// BMFF v2 hash assertion (c2pa.hash.bmff.v2).
    case hashBMFFv2(C2PAHashBMFFv2)
    /// Collection-of-URIs hash assertion (c2pa.hash.collection.data).
    case hashCollection(C2PAHashCollection)
    /// IPTC standard assertion (stds.iptc / stds.iptc.photo-metadata).
    case iptc(C2PAIPTCAssertion)
    /// Exif standard assertion (stds.exif).
    case exif(C2PAExifAssertion)
    /// schema.org CreativeWork standard assertion (stds.schema-org.CreativeWork).
    case schemaOrgCreativeWork(C2PASchemaOrgCreativeWork)
    /// Training-mining usage declaration (c2pa.training-mining, c2pa.training-mining.v2).
    case trainingMining(C2PATrainingMining)
    /// Assertion redactions (c2pa.redactions).
    case redactions(C2PARedactions)
    /// CAWG identity assertion envelope (c2pa.identity.assertion).
    case identityAssertion(C2PAIdentityAssertion)
    /// Raw CBOR content for unrecognized or custom assertions.
    case cbor(CBORValue)
    /// Raw JSON content.
    case json(Data)
    /// Raw binary content.
    case binary(Data)
}

/// Parsed c2pa.actions assertion.
public struct C2PAActions: Sendable {
    public let actions: [C2PAAction]

    public init(actions: [C2PAAction]) {
        self.actions = actions
    }
}

/// A single action within an actions assertion.
public struct C2PAAction: Sendable {
    /// Action type (e.g. "c2pa.created", "c2pa.edited", "c2pa.opened").
    public let action: String
    /// Software agent that performed the action.
    public let softwareAgent: String?
    /// Human-readable description.
    public let description: String?
    /// IPTC digital source type URI.
    public let digitalSourceType: String?
    /// Additional parameters as raw CBOR.
    public let parameters: CBORValue?

    public init(
        action: String,
        softwareAgent: String? = nil,
        description: String? = nil,
        digitalSourceType: String? = nil,
        parameters: CBORValue? = nil
    ) {
        self.action = action
        self.softwareAgent = softwareAgent
        self.description = description
        self.digitalSourceType = digitalSourceType
        self.parameters = parameters
    }
}

/// Parsed c2pa.hash.data assertion (hard binding).
public struct C2PAHashData: Sendable {
    /// Hash algorithm identifier (e.g. "sha256").
    public let algorithm: String
    /// Computed hash value.
    public let hash: Data
    /// Byte ranges excluded from hashing (where the manifest store is embedded).
    public let exclusions: [C2PAExclusion]

    public init(algorithm: String, hash: Data, exclusions: [C2PAExclusion] = []) {
        self.algorithm = algorithm
        self.hash = hash
        self.exclusions = exclusions
    }
}

/// A byte range exclusion for data hash computation.
public struct C2PAExclusion: Sendable {
    /// Start byte offset in the asset.
    public let start: UInt64
    /// Number of bytes to exclude.
    public let length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }
}

/// Parsed `c2pa.hash.boxes` assertion. Each entry hashes one or more named
/// ISOBMFF/JUMBF top-level boxes (`ftyp`, `moov`, `mdat`, …).
public struct C2PAHashBoxes: Sendable {
    /// Default hash algorithm for entries that don't override it.
    public let algorithm: String?
    /// Per-box hash entries, in the order specified by the assertion.
    public let boxes: [C2PAHashBoxEntry]

    public init(algorithm: String? = nil, boxes: [C2PAHashBoxEntry]) {
        self.algorithm = algorithm
        self.boxes = boxes
    }
}

/// One entry in a `c2pa.hash.boxes` assertion: hash for a contiguous group of
/// box types.
public struct C2PAHashBoxEntry: Sendable {
    /// Box type names ("ftyp", "moov", …) covered by this hash.
    public let names: [String]
    /// Hash algorithm (defaults to the parent assertion's `alg`).
    public let algorithm: String?
    /// Computed hash value.
    public let hash: Data
    /// Optional padding bytes preserved for round-tripping.
    public let pad: Data?

    public init(names: [String], algorithm: String? = nil, hash: Data, pad: Data? = nil) {
        self.names = names
        self.algorithm = algorithm
        self.hash = hash
        self.pad = pad
    }
}

/// Parsed `c2pa.hash.bmff.v2` assertion. The Merkle-tree variant is surfaced
/// verbatim — full V2 verification (Merkle reconstruction across MP4 fragments)
/// is out of scope here.
public struct C2PAHashBMFFv2: Sendable {
    public let algorithm: String?
    public let hash: Data?
    public let exclusions: [C2PABMFFv2Exclusion]
    /// Merkle-tree definitions when the assertion uses fragmented BMFF hashing.
    public let merkle: [C2PABMFFv2Merkle]

    public init(algorithm: String? = nil, hash: Data? = nil, exclusions: [C2PABMFFv2Exclusion], merkle: [C2PABMFFv2Merkle]) {
        self.algorithm = algorithm
        self.hash = hash
        self.exclusions = exclusions
        self.merkle = merkle
    }
}

/// One exclusion entry inside a `c2pa.hash.bmff.v2` assertion. Excludes either
/// a whole box (by `xpath` like `/uuid[c2pa]`), a contiguous byte range, or a
/// per-byte data overlay.
public struct C2PABMFFv2Exclusion: Sendable {
    public let xpath: String?
    public let length: UInt64?
    public let version: UInt64?
    public let flags: UInt64?
    /// Subset ranges to exclude inside the matched box.
    public let subset: [C2PAExclusion]
    /// Embedded constant data overlays preserved for fragment hashing.
    public let dataOverlays: [C2PABMFFv2DataOverlay]

    public init(xpath: String? = nil, length: UInt64? = nil, version: UInt64? = nil, flags: UInt64? = nil, subset: [C2PAExclusion] = [], dataOverlays: [C2PABMFFv2DataOverlay] = []) {
        self.xpath = xpath
        self.length = length
        self.version = version
        self.flags = flags
        self.subset = subset
        self.dataOverlays = dataOverlays
    }
}

/// A single byte overlay applied during BMFF v2 hashing.
public struct C2PABMFFv2DataOverlay: Sendable {
    public let offset: UInt64
    public let value: Data

    public init(offset: UInt64, value: Data) {
        self.offset = offset
        self.value = value
    }
}

/// Merkle-tree descriptor inside a `c2pa.hash.bmff.v2` assertion.
public struct C2PABMFFv2Merkle: Sendable {
    public let uniqueId: UInt64
    public let localId: UInt64
    public let count: UInt64
    public let algorithm: String?
    public let initHash: Data?
    public let hashes: [Data]

    public init(uniqueId: UInt64, localId: UInt64, count: UInt64, algorithm: String? = nil, initHash: Data? = nil, hashes: [Data]) {
        self.uniqueId = uniqueId
        self.localId = localId
        self.count = count
        self.algorithm = algorithm
        self.initHash = initHash
        self.hashes = hashes
    }
}

/// Parsed `c2pa.hash.collection.data` assertion. Used when a manifest binds
/// to multiple asset files identified by relative URIs.
public struct C2PAHashCollection: Sendable {
    public let algorithm: String?
    public let uris: [C2PACollectionEntry]

    public init(algorithm: String? = nil, uris: [C2PACollectionEntry]) {
        self.algorithm = algorithm
        self.uris = uris
    }
}

/// One URI/hash pair inside a `c2pa.hash.collection.data` assertion.
public struct C2PACollectionEntry: Sendable {
    public let uri: String
    public let hash: Data
    public let size: UInt64?
    public let format: String?

    public init(uri: String, hash: Data, size: UInt64? = nil, format: String? = nil) {
        self.uri = uri
        self.hash = hash
        self.size = size
        self.format = format
    }
}

/// Parsed c2pa.ingredient assertion.
public struct C2PAIngredient: Sendable {
    /// Asset title.
    public let title: String?
    /// Media type (MIME).
    public let format: String?
    /// Unique instance identifier.
    public let instanceID: String?
    /// Relationship to the parent asset: "parentOf", "componentOf", or "inputTo".
    public let relationship: String?

    public init(title: String? = nil, format: String? = nil, instanceID: String? = nil, relationship: String? = nil) {
        self.title = title
        self.format = format
        self.instanceID = instanceID
        self.relationship = relationship
    }
}

// MARK: - Thumbnail Convenience

/// An extracted C2PA thumbnail with its source label and image format.
public struct C2PAThumbnail: Sendable {
    /// Full assertion label, e.g. "c2pa.thumbnail.claim.jpeg" or "c2pa.thumbnail.ingredient.png".
    public let label: String
    /// Raw image bytes from the JUMBF `bidb` box.
    public let data: Data
    /// Image format suffix from the assertion label, e.g. "jpeg", "png".
    public let format: String

    public init(label: String, data: Data, format: String) {
        self.label = label
        self.data = data
        self.format = format
    }
}

// MARK: - Standard Assertions (Phase B)

/// Parsed `stds.iptc` / `stds.iptc.photo-metadata` assertion. The CBOR is a
/// JSON-LD-shaped map keyed by namespaced strings (e.g. `dc:creator`,
/// `Iptc4xmpExt:DigitalSourceType`). Raw fields are exposed via `fields` for
/// callers that need keys this struct doesn't surface directly.
public struct C2PAIPTCAssertion: Sendable {
    /// All assertion fields, indexed by the namespaced CBOR key.
    public let fields: [String: CBORValue]

    public init(fields: [String: CBORValue]) {
        self.fields = fields
    }

    /// `dc:creator` — usually a CBOR text string array. Returns the joined names.
    public var creators: [String] {
        if let arr = fields["dc:creator"]?.arrayValue {
            return arr.compactMap { $0.textStringValue }
        }
        if let str = fields["dc:creator"]?.textStringValue { return [str] }
        return []
    }

    public var rights: String? {
        fields["dc:rights"]?.textStringValue
            ?? fields["dc:rights"]?["x-default"]?.textStringValue
    }

    public var title: String? {
        fields["dc:title"]?.textStringValue
            ?? fields["dc:title"]?["x-default"]?.textStringValue
    }

    public var description: String? {
        fields["dc:description"]?.textStringValue
            ?? fields["dc:description"]?["x-default"]?.textStringValue
    }

    /// IPTC Digital Source Type URI (e.g. `trainedAlgorithmicMedia`).
    public var digitalSourceType: String? {
        fields["Iptc4xmpExt:DigitalSourceType"]?.textStringValue
    }

    public var dateCreated: String? {
        fields["photoshop:DateCreated"]?.textStringValue
    }
}

/// Parsed `stds.exif` assertion. Stores the namespaced map verbatim.
public struct C2PAExifAssertion: Sendable {
    public let fields: [String: CBORValue]

    public init(fields: [String: CBORValue]) {
        self.fields = fields
    }

    public var make: String? { fields["tiff:Make"]?.textStringValue }
    public var model: String? { fields["tiff:Model"]?.textStringValue }
    public var dateTimeOriginal: String? { fields["exif:DateTimeOriginal"]?.textStringValue }
    public var gpsLatitude: String? { fields["exif:GPSLatitude"]?.textStringValue }
    public var gpsLongitude: String? { fields["exif:GPSLongitude"]?.textStringValue }
}

/// Parsed `stds.schema-org.CreativeWork` assertion. Keeps the raw schema.org
/// payload while exposing common provenance fields.
public struct C2PASchemaOrgCreativeWork: Sendable {
    public let fields: [String: CBORValue]

    public init(fields: [String: CBORValue]) {
        self.fields = fields
    }

    /// `author` is typically `[{"@type": "Person", "name": "..."}]`.
    public var authors: [String] {
        guard let value = fields["author"] else { return [] }
        if let arr = value.arrayValue {
            return arr.compactMap { $0["name"]?.textStringValue ?? $0.textStringValue }
        }
        if let name = value["name"]?.textStringValue { return [name] }
        if let str = value.textStringValue { return [str] }
        return []
    }

    public var copyrightHolder: String? {
        fields["copyrightHolder"]?["name"]?.textStringValue
            ?? fields["copyrightHolder"]?.textStringValue
    }

    public var copyrightNotice: String? {
        fields["copyrightNotice"]?.textStringValue
    }

    public var creditText: String? {
        fields["creditText"]?.textStringValue
    }

    public var license: String? { fields["license"]?.textStringValue }
    public var url: String? { fields["url"]?.textStringValue }
}

/// Parsed `c2pa.training-mining` (or `.v2`) assertion. Each entry expresses
/// whether a category of automated use is allowed/notAllowed/constrained.
public struct C2PATrainingMining: Sendable {
    public let entries: [C2PATrainingMiningEntry]

    public init(entries: [C2PATrainingMiningEntry]) {
        self.entries = entries
    }
}

/// A single category entry inside a training-mining assertion.
public struct C2PATrainingMiningEntry: Sendable {
    /// Category identifier (e.g. `c2pa.ai_generative_training`,
    /// `c2pa.ai_inference`, `c2pa.ai_training`, `c2pa.data_mining`).
    public let category: String
    /// Use declaration: `allowed`, `notAllowed`, or `constrained`.
    public let use: String
    /// Optional human-readable explanation when `use == "constrained"`.
    public let constraintInfo: String?

    public init(category: String, use: String, constraintInfo: String? = nil) {
        self.category = category
        self.use = use
        self.constraintInfo = constraintInfo
    }
}

/// Parsed `c2pa.redactions` assertion: the JUMBF URIs of redacted assertions.
public struct C2PARedactions: Sendable {
    public let redactions: [String]

    public init(redactions: [String]) {
        self.redactions = redactions
    }
}

/// Envelope of a CAWG `c2pa.identity.assertion`. Cryptographic verification
/// is intentionally out of scope here — Phase C will validate the embedded
/// signature against the signer's certificate. We only surface the bytes.
public struct C2PAIdentityAssertion: Sendable {
    /// The `signer_payload` map (CBOR-encoded inside the assertion). Surfaced
    /// raw so callers can pull `referenced_assertions`, `sig_type`, etc.
    public let signerPayload: CBORValue
    /// Signer signature bytes (COSE_Sign1 or other sig_type, depending on the
    /// `signer_payload.sig_type` field).
    public let signature: Data
    /// Optional padding bytes preserved for round-tripping.
    public let pad1: Data?
    public let pad2: Data?

    public init(signerPayload: CBORValue, signature: Data, pad1: Data? = nil, pad2: Data? = nil) {
        self.signerPayload = signerPayload
        self.signature = signature
        self.pad1 = pad1
        self.pad2 = pad2
    }
}
