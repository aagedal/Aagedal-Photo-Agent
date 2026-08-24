import Foundation

/// XMP value types.
///
/// `.structure` and `.structuredArray` carry `XMPValue` payloads recursively,
/// so a struct can contain another struct, an array, or a nested rdf:Bag of structs.
/// Adobe Camera Raw's MaskGroupBasedCorrections (rdf:Bag of corrections, each holding
/// its own rdf:Bag of CorrectionMasks) is the canonical case that requires recursion.
///
/// Struct fields are keyed `"<namespaceURI><name>"` — the same convention as
/// `XMPData`'s top-level properties — never the bare local name, because a
/// struct's fields may come from a different namespace than the property that
/// holds it (e.g. Iptc4xmpExt structs carrying plus: fields). Use the
/// `subscript(namespace:property:)` / `simpleField(namespace:property:)`
/// accessors below instead of concatenating keys by hand.
public indirect enum XMPValue: Equatable, Sendable {
    case simple(String)
    case array([String])                       // rdf:Bag or rdf:Seq
    case langAlternative(String)               // rdf:Alt with xml:lang="x-default"
    case languageAlternative([XMPLanguageAlternative]) // ordered rdf:Alt, retaining xml:lang
    case structure([String: XMPValue])         // Single rdf:Description with fields
    case structuredArray([[String: XMPValue]]) // rdf:Bag of rdf:Description items
}

/// One ordered item in an XMP language alternative. `language` is the exact `xml:lang` value
/// observed on read (normally a BCP 47 tag or XMP's `x-default` pseudo-tag).
public struct XMPLanguageAlternative: Equatable, Sendable {
    public var language: String
    public var value: String

    public init(language: String, value: String) {
        self.language = language
        self.value = value
    }
}

public extension Dictionary where Key == String, Value == XMPValue {
    /// Access a struct field by namespace + local name. Fields are keyed
    /// `"<namespaceURI><name>"`; this mirrors `XMPData.value(namespace:property:)`
    /// / `setValue` so callers never hand-concatenate field keys (a bare-name
    /// lookup compiles fine but silently never matches).
    subscript(namespace namespace: String, property property: String) -> XMPValue? {
        get { self["\(namespace)\(property)"] }
        set { self["\(namespace)\(property)"] = newValue }
    }

    /// The field's string payload when it is `.simple` or `.langAlternative`, else nil.
    func simpleField(namespace: String, property: String) -> String? {
        switch self[namespace: namespace, property: property] {
        case .simple(let s), .langAlternative(let s): return s
        case .languageAlternative(let items):
            return items.first(where: { $0.language.caseInsensitiveCompare("x-default") == .orderedSame })?.value
                ?? items.first?.value
        default: return nil
        }
    }
}

/// The rdf container element an XMP array was carried in. `XMPValue.array` /
/// `.structuredArray` deliberately don't distinguish Bag from Seq (consumers
/// rarely care), so the parsed form is tracked alongside the properties and
/// consulted on write to round-trip the original container.
public enum XMPArrayForm: Equatable, Sendable {
    case bag
    case seq
}

/// Parsed XMP metadata.
public struct XMPData: Equatable, Sendable {
    /// The raw XMP XML string (preserved for round-trip fidelity when possible).
    public var xmlString: String

    /// Parsed property values keyed by "namespace:property".
    private var properties: [String: XMPValue]

    /// Face/object regions (MWG Regions specification).
    public var regions: XMPRegionList?

    /// Container form (Bag vs Seq) observed per array key when this data was parsed
    /// from a packet, keyed like `properties` — including nested struct-field keys.
    /// The writer uses this so vendor arrays it has no spec knowledge of keep their
    /// original container; spec-defined Seq properties are normalized regardless
    /// (mirroring ExifTool, which writes container types from its tag tables).
    var arrayForms: [String: XMPArrayForm]

    public init(xmlString: String = "", properties: [String: XMPValue] = [:], regions: XMPRegionList? = nil) {
        self.xmlString = xmlString
        self.properties = properties
        self.regions = regions
        self.arrayForms = [:]
    }

    // MARK: - Property Access

    public func value(namespace: String, property: String) -> XMPValue? {
        properties["\(namespace)\(property)"]
    }

    public mutating func setValue(_ value: XMPValue, namespace: String, property: String) {
        properties["\(namespace)\(property)"] = value
    }

    public mutating func removeValue(namespace: String, property: String) {
        properties.removeValue(forKey: "\(namespace)\(property)")
    }

    // MARK: - Namespace Blocks

    /// All properties in a namespace, keyed by local property name.
    ///
    /// Matching is namespace-exact, not raw prefix: Adobe URIs nest (`xmpRights`,
    /// `xmpMM`, `stEvt` all start with the `xmp` URI), so a key only belongs to
    /// `namespace` when the remainder after it is a plain local name.
    public func properties(in namespace: String) -> [String: XMPValue] {
        var result: [String: XMPValue] = [:]
        for (key, value) in properties {
            if let local = Self.localName(of: key, in: namespace) {
                result[local] = value
            }
        }
        return result
    }

    /// Remove every property in a namespace — e.g. drop a file's whole `crs:`
    /// Camera Raw settings block before applying another file's. Also clears the
    /// parsed rdf container-form records for the removed keys. Namespace-exact,
    /// see `properties(in:)`.
    public mutating func removeAll(namespace: String) {
        properties = properties.filter { Self.localName(of: $0.key, in: namespace) == nil }
        arrayForms = arrayForms.filter { Self.localName(of: $0.key, in: namespace) == nil }
    }

    /// Replace this data's entire `namespace` block with `other`'s: every existing
    /// property in the namespace is removed, then every property `other` carries in
    /// it is copied over — including the container forms observed when `other` was
    /// parsed, so arrays keep their rdf:Bag/Seq shape on the next write.
    public mutating func replaceAll(namespace: String, from other: XMPData) {
        removeAll(namespace: namespace)
        for (key, value) in other.properties where Self.localName(of: key, in: namespace) != nil {
            properties[key] = value
        }
        for (key, form) in other.arrayForms where Self.localName(of: key, in: namespace) != nil {
            arrayForms[key] = form
        }
    }

    /// The local property name when `key` belongs to exactly `namespace`, else nil.
    /// Rejects remainders containing `/` or `#` — those keys belong to a longer
    /// URI that merely shares this namespace as a prefix.
    private static func localName(of key: String, in namespace: String) -> String? {
        guard key.hasPrefix(namespace) else { return nil }
        let local = key.dropFirst(namespace.count)
        guard !local.isEmpty, !local.contains("/"), !local.contains("#") else { return nil }
        return String(local)
    }

    /// Get a simple string value.
    public func simpleValue(namespace: String, property: String) -> String? {
        if case .simple(let s) = value(namespace: namespace, property: property) { return s }
        if case .langAlternative(let s) = value(namespace: namespace, property: property) { return s }
        if case .languageAlternative(let items) = value(namespace: namespace, property: property) {
            return items.first(where: { $0.language.caseInsensitiveCompare("x-default") == .orderedSame })?.value
                ?? items.first?.value
        }
        return nil
    }

    /// Get every ordered language alternative without collapsing non-default languages.
    public func languageAlternativeValue(
        namespace: String,
        property: String
    ) -> [XMPLanguageAlternative]? {
        switch value(namespace: namespace, property: property) {
        case .languageAlternative(let items): return items
        case .langAlternative(let value):
            return [XMPLanguageAlternative(language: "x-default", value: value)]
        default: return nil
        }
    }

    /// Get an array value.
    public func arrayValue(namespace: String, property: String) -> [String] {
        if case .array(let arr) = value(namespace: namespace, property: property) { return arr }
        return []
    }

    /// Get a structure value (single rdf:Description with fields). Field values may themselves
    /// be nested arrays / structs — for the common flat-string case use `flatStructureValue`.
    public func structureValue(namespace: String, property: String) -> [String: XMPValue]? {
        if case .structure(let fields) = value(namespace: namespace, property: property) { return fields }
        return nil
    }

    /// Get a structured array value (rdf:Bag of rdf:Description items). For the flat-string
    /// case use `flatStructuredArrayValue`.
    public func structuredArrayValue(namespace: String, property: String) -> [[String: XMPValue]]? {
        if case .structuredArray(let items) = value(namespace: namespace, property: property) { return items }
        return nil
    }

    /// Convenience view that down-casts a structure's `XMPValue` fields to `String`, dropping
    /// any non-`.simple` entries. Use this for legacy schemas (IPTC, xmpDM timecode, stRef) that
    /// only carry flat-string fields.
    public func flatStructureValue(namespace: String, property: String) -> [String: String]? {
        guard let fields = structureValue(namespace: namespace, property: property) else { return nil }
        return Self.flatten(fields)
    }

    /// Down-cast view of a structured array — see `flatStructureValue`.
    public func flatStructuredArrayValue(namespace: String, property: String) -> [[String: String]]? {
        guard let items = structuredArrayValue(namespace: namespace, property: property) else { return nil }
        return items.map { Self.flatten($0) }
    }

    /// Down-cast a struct's `XMPValue` fields to `String`, dropping anything that isn't `.simple`.
    /// Use this when consuming a flat-string schema (IPTC, stRef, xmpDM timecode) where non-simple
    /// fields aren't expected.
    public static func flatten(_ fields: [String: XMPValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in fields {
            if case .simple(let s) = value { out[key] = s }
        }
        return out
    }

    /// Wrap each entry in a flat `[String: String]` as `.simple`, producing the recursive form.
    public static func wrapSimple(_ fields: [String: String]) -> [String: XMPValue] {
        fields.mapValues { .simple($0) }
    }

    /// All property keys.
    public var allKeys: [String] { Array(properties.keys) }

    /// Lookup by the internal "namespace+property" key (as returned by `allKeys`).
    public func value(forKey key: String) -> XMPValue? {
        properties[key]
    }

    // MARK: - Convenience Properties (IPTC-mapped fields)

    public var title: String? {
        get { simpleValue(namespace: XMPNamespace.dc, property: "title") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.dc, property: "title") }
            else { removeValue(namespace: XMPNamespace.dc, property: "title") }
        }
    }

    public var description: String? {
        get { simpleValue(namespace: XMPNamespace.dc, property: "description") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.dc, property: "description") }
            else { removeValue(namespace: XMPNamespace.dc, property: "description") }
        }
    }

    public var creator: [String] {
        get { arrayValue(namespace: XMPNamespace.dc, property: "creator") }
        set { setValue(.array(newValue), namespace: XMPNamespace.dc, property: "creator") }
    }

    public var subject: [String] {
        get { arrayValue(namespace: XMPNamespace.dc, property: "subject") }
        set { setValue(.array(newValue), namespace: XMPNamespace.dc, property: "subject") }
    }

    public var rights: String? {
        get { simpleValue(namespace: XMPNamespace.dc, property: "rights") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.dc, property: "rights") }
            else { removeValue(namespace: XMPNamespace.dc, property: "rights") }
        }
    }

    public var headline: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Headline") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Headline") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Headline") }
        }
    }

    public var city: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "City") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "City") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "City") }
        }
    }

    public var state: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "State") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "State") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "State") }
        }
    }

    public var country: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Country") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Country") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Country") }
        }
    }

    public var credit: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Credit") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Credit") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Credit") }
        }
    }

    public var source: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "Source") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "Source") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "Source") }
        }
    }

    public var jobId: String? {
        get { simpleValue(namespace: XMPNamespace.photoshop, property: "TransmissionReference") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.photoshop, property: "TransmissionReference") }
            else { removeValue(namespace: XMPNamespace.photoshop, property: "TransmissionReference") }
        }
    }

    // MARK: - XMP Basic Properties (xmp:)

    /// User rating (xmp:Rating). Typically 0.0–5.0; Bridge may write halves. Returns nil when absent
    /// or when the stored value isn't numeric.
    public var rating: Double? {
        get {
            guard let s = simpleValue(namespace: XMPNamespace.xmp, property: "Rating") else { return nil }
            return Double(s)
        }
        set {
            if let v = newValue { setValue(.simple(Self.formatRating(v)), namespace: XMPNamespace.xmp, property: "Rating") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "Rating") }
        }
    }

    /// Color label (xmp:Label). Lightroom/Bridge use "Red", "Yellow", "Green", "Blue", "Purple".
    public var label: String? {
        get { simpleValue(namespace: XMPNamespace.xmp, property: "Label") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmp, property: "Label") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "Label") }
        }
    }

    /// Resource creation date (xmp:CreateDate). W3C-DTF / ISO 8601.
    public var createDate: String? {
        get { simpleValue(namespace: XMPNamespace.xmp, property: "CreateDate") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmp, property: "CreateDate") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "CreateDate") }
        }
    }

    /// Resource last-modified date (xmp:ModifyDate). W3C-DTF / ISO 8601.
    public var modifyDate: String? {
        get { simpleValue(namespace: XMPNamespace.xmp, property: "ModifyDate") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmp, property: "ModifyDate") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "ModifyDate") }
        }
    }

    /// Metadata last-modified date (xmp:MetadataDate). W3C-DTF / ISO 8601.
    public var metadataDate: String? {
        get { simpleValue(namespace: XMPNamespace.xmp, property: "MetadataDate") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmp, property: "MetadataDate") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "MetadataDate") }
        }
    }

    /// Tool that created or last modified the resource (xmp:CreatorTool).
    public var creatorTool: String? {
        get { simpleValue(namespace: XMPNamespace.xmp, property: "CreatorTool") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmp, property: "CreatorTool") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "CreatorTool") }
        }
    }

    /// Unordered identifier array (xmp:Identifier) — rdf:Bag of strings.
    public var identifier: [String] {
        get { arrayValue(namespace: XMPNamespace.xmp, property: "Identifier") }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.xmp, property: "Identifier") }
            else { setValue(.array(newValue), namespace: XMPNamespace.xmp, property: "Identifier") }
        }
    }

    /// Short human-readable name for the resource (xmp:Nickname).
    public var nickname: String? {
        get { simpleValue(namespace: XMPNamespace.xmp, property: "Nickname") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmp, property: "Nickname") }
            else { removeValue(namespace: XMPNamespace.xmp, property: "Nickname") }
        }
    }

    private static func formatRating(_ value: Double) -> String {
        let clamped = max(0.0, min(5.0, value))
        if clamped.rounded() == clamped { return String(Int(clamped)) }
        return String(format: "%.1f", clamped)
    }

    // MARK: - IPTC Core Properties (Iptc4xmpCore)

    /// Extended description for accessibility (Iptc4xmpCore:ExtDescrAccessibility).
    public var extendedDescription: String? {
        get { simpleValue(namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility") }
        }
    }

    /// Alt text for accessibility (Iptc4xmpCore:AltTextAccessibility).
    public var altText: String? {
        get { simpleValue(namespace: XMPNamespace.iptcCore, property: "AltTextAccessibility") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.iptcCore, property: "AltTextAccessibility") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "AltTextAccessibility") }
        }
    }

    /// Intellectual genre of the content (Iptc4xmpCore:IntellectualGenre).
    public var intellectualGenre: String? {
        get { simpleValue(namespace: XMPNamespace.iptcCore, property: "IntellectualGenre") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcCore, property: "IntellectualGenre") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "IntellectualGenre") }
        }
    }

    /// IPTC Scene codes — 6-digit codes from IPTC Scene NewsCodes (Iptc4xmpCore:Scene).
    public var scene: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcCore, property: "Scene") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcCore, property: "Scene") }
    }

    /// IPTC Subject codes (Iptc4xmpCore:SubjectCode).
    public var subjectCode: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcCore, property: "SubjectCode") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcCore, property: "SubjectCode") }
    }

    /// Creator contact information (Iptc4xmpCore:CreatorContactInfo) — structured type.
    public var creatorContactInfo: IPTCCreatorContactInfo? {
        get {
            guard let fields = flatStructureValue(namespace: XMPNamespace.iptcCore, property: "CreatorContactInfo") else { return nil }
            return IPTCCreatorContactInfo(fields: fields)
        }
        set {
            if let v = newValue { setValue(.structure(Self.wrapSimple(v.toFields())), namespace: XMPNamespace.iptcCore, property: "CreatorContactInfo") }
            else { removeValue(namespace: XMPNamespace.iptcCore, property: "CreatorContactInfo") }
        }
    }

    // MARK: - IPTC Extension Properties (Iptc4xmpExt)

    /// Persons shown in the image (Iptc4xmpExt:PersonInImage).
    public var personInImage: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "PersonInImage") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "PersonInImage") }
    }

    /// IPTC Digital Source Type URI (Iptc4xmpExt:DigitalSourceType).
    /// Uses IPTC controlled vocabulary URIs, e.g. "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture".
    public var digitalSourceType: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "DigitalSourceType") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "DigitalSourceType") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "DigitalSourceType") }
        }
    }

    /// Event name (Iptc4xmpExt:Event).
    public var event: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "Event") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.iptcExt, property: "Event") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "Event") }
        }
    }

    /// Organizations shown in image by code (Iptc4xmpExt:OrganisationInImageCode).
    public var organisationInImageCode: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageCode") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "OrganisationInImageCode") }
    }

    /// Organizations shown in image by name (Iptc4xmpExt:OrganisationInImageName).
    public var organisationInImageName: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageName") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "OrganisationInImageName") }
    }

    /// Maximum available image height in pixels (Iptc4xmpExt:MaxAvailHeight).
    public var maxAvailHeight: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailHeight") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "MaxAvailHeight") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailHeight") }
        }
    }

    /// Maximum available image width in pixels (Iptc4xmpExt:MaxAvailWidth).
    public var maxAvailWidth: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailWidth") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "MaxAvailWidth") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "MaxAvailWidth") }
        }
    }

    /// Additional information about models in the image (Iptc4xmpExt:AddlModelInfo).
    public var additionalModelInformation: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "AddlModelInfo") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "AddlModelInfo") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "AddlModelInfo") }
        }
    }

    /// Model release status URI (Iptc4xmpExt:ModelReleaseStatus).
    public var modelReleaseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "ModelReleaseStatus") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "ModelReleaseStatus") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "ModelReleaseStatus") }
        }
    }

    /// Property release status URI (Iptc4xmpExt:PropertyReleaseStatus).
    public var propertyReleaseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "PropertyReleaseStatus") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "PropertyReleaseStatus") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "PropertyReleaseStatus") }
        }
    }

    /// Model release document identifiers (Iptc4xmpExt:ModelReleaseDocument).
    public var modelReleaseDocument: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "ModelReleaseDocument") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "ModelReleaseDocument") }
    }

    /// Property release document identifiers (Iptc4xmpExt:PropertyReleaseDocument).
    public var propertyReleaseDocument: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "PropertyReleaseDocument") }
        set { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "PropertyReleaseDocument") }
    }

    /// Globally unique identifier for the image (Iptc4xmpExt:DigitalImageGUID).
    public var digitalImageGUID: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "DigitalImageGUID") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "DigitalImageGUID") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "DigitalImageGUID") }
        }
    }

    /// Image supplier's image ID (Iptc4xmpExt:ImageSupplierImageID).
    public var imageSupplierImageID: String? {
        get { simpleValue(namespace: XMPNamespace.iptcExt, property: "ImageSupplierImageID") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.iptcExt, property: "ImageSupplierImageID") }
            else { removeValue(namespace: XMPNamespace.iptcExt, property: "ImageSupplierImageID") }
        }
    }

    /// Locations where the image was created (Iptc4xmpExt:LocationCreated) — structured array.
    public var locationCreated: [IPTCLocation] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.iptcExt, property: "LocationCreated") else { return [] }
            return items.map { IPTCLocation(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "LocationCreated") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.iptcExt, property: "LocationCreated") }
        }
    }

    /// Locations shown in the image (Iptc4xmpExt:LocationShown) — structured array.
    public var locationShown: [IPTCLocation] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.iptcExt, property: "LocationShown") else { return [] }
            return items.map { IPTCLocation(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "LocationShown") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.iptcExt, property: "LocationShown") }
        }
    }

    /// Registry entries for the image (Iptc4xmpExt:RegistryId) — structured array.
    public var registryId: [IPTCRegistryEntry] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.iptcExt, property: "RegistryId") else { return [] }
            return items.map { IPTCRegistryEntry(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "RegistryId") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.iptcExt, property: "RegistryId") }
        }
    }

    /// Artwork or objects in the image (Iptc4xmpExt:ArtworkOrObject) — structured array.
    public var artworkOrObject: [IPTCArtworkOrObject] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.iptcExt, property: "ArtworkOrObject") else { return [] }
            return items.map { IPTCArtworkOrObject(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "ArtworkOrObject") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.iptcExt, property: "ArtworkOrObject") }
        }
    }

    /// Image creators (Iptc4xmpExt:ImageCreator) — structured array, IPTC Extension 1.4+.
    public var imageCreator: [IPTCImageCreator] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.iptcExt, property: "ImageCreator") else { return [] }
            return items.map { IPTCImageCreator(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "ImageCreator") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.iptcExt, property: "ImageCreator") }
        }
    }

    /// Genre of the content (Iptc4xmpExt:Genre) — rdf:Bag of controlled vocabulary terms.
    /// Note: richer than Iptc4xmpCore:IntellectualGenre (which is a single string).
    public var genres: [String] {
        get { arrayValue(namespace: XMPNamespace.iptcExt, property: "Genre") }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.iptcExt, property: "Genre") }
            else { setValue(.array(newValue), namespace: XMPNamespace.iptcExt, property: "Genre") }
        }
    }

    /// Copyright owners (plus:CopyrightOwner) — structured array from PLUS namespace.
    public var copyrightOwner: [IPTCCopyrightOwner] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.plus, property: "CopyrightOwner") else { return [] }
            return items.map { IPTCCopyrightOwner(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.plus, property: "CopyrightOwner") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.plus, property: "CopyrightOwner") }
        }
    }

    /// Licensors (plus:Licensor) — structured array from PLUS namespace.
    public var licensor: [IPTCLicensor] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.plus, property: "Licensor") else { return [] }
            return items.map { IPTCLicensor(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.plus, property: "Licensor") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.plus, property: "Licensor") }
        }
    }

    // MARK: - PLUS Properties (Picture Licensing Universal System)

    /// Minor model age disclosure URI (plus:MinorModelAgeDisclosure).
    public var minorModelAgeDisclosure: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "MinorModelAgeDisclosure") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.plus, property: "MinorModelAgeDisclosure") }
            else { removeValue(namespace: XMPNamespace.plus, property: "MinorModelAgeDisclosure") }
        }
    }

    /// PLUS model release identifiers (plus:ModelReleaseID).
    public var plusModelReleaseID: [String] {
        get { arrayValue(namespace: XMPNamespace.plus, property: "ModelReleaseID") }
        set { setValue(.array(newValue), namespace: XMPNamespace.plus, property: "ModelReleaseID") }
    }

    /// PLUS property release identifiers (plus:PropertyReleaseID).
    public var plusPropertyReleaseID: [String] {
        get { arrayValue(namespace: XMPNamespace.plus, property: "PropertyReleaseID") }
        set { setValue(.array(newValue), namespace: XMPNamespace.plus, property: "PropertyReleaseID") }
    }

    // MARK: - PLUS Wire-Service / License Transaction Fields
    //
    // PLUS Coalition v1.2.1 license-tracking fields. Wire services (AP, Reuters,
    // AFP) and DAMs use these to identify a specific licensing transaction and
    // its time window. Fields use code-point URIs from
    // ns.useplus.org/LDF/ldf-XMPSpecification.html.

    /// Image suppliers (plus:ImageSupplier) — agencies/creators that provided the image.
    public var imageSupplier: [IPTCImageSupplier] {
        get {
            guard let items = flatStructuredArrayValue(namespace: XMPNamespace.plus, property: "ImageSupplier") else { return [] }
            return items.map { IPTCImageSupplier(fields: $0) }
        }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.plus, property: "ImageSupplier") }
            else { setValue(.structuredArray(newValue.map { Self.wrapSimple($0.toFields()) }), namespace: XMPNamespace.plus, property: "ImageSupplier") }
        }
    }

    /// Supplier's image identifier in the PLUS namespace (plus:ImageSupplierImageID).
    /// Distinct from the IPTC Extension `imageSupplierImageID` — most files use
    /// the iptcExt form, but PLUS-aware DAMs sometimes write both.
    public var plusImageSupplierImageID: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "ImageSupplierImageID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "ImageSupplierImageID") }
    }

    /// License transaction identifier (plus:LicenseTransactionID).
    public var licenseTransactionID: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "LicenseTransactionID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "LicenseTransactionID") }
    }

    /// License transaction date (plus:LicenseTransactionDate, ISO 8601).
    public var licenseTransactionDate: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "LicenseTransactionDate") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "LicenseTransactionDate") }
    }

    /// License start date (plus:LicenseStartDate, ISO 8601).
    public var licenseStartDate: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "LicenseStartDate") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "LicenseStartDate") }
    }

    /// License end date (plus:LicenseEndDate, ISO 8601).
    public var licenseEndDate: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "LicenseEndDate") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "LicenseEndDate") }
    }

    /// License status code-point URI (plus:LicenseStatus).
    /// Standard values: "...US-EXP" (expired), "...US-LIC" (licensed),
    /// "...US-PND" (pending), "...US-CAN" (cancelled).
    public var licenseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "LicenseStatus") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "LicenseStatus") }
    }

    /// License document identifier (plus:LicenseDocumentID).
    public var licenseDocumentID: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "LicenseDocumentID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "LicenseDocumentID") }
    }

    /// Copyright status code-point URI (plus:CopyrightStatus).
    /// Standard values: "...CS-PRO" (protected), "...CS-PUB" (public domain),
    /// "...CS-UNK" (unknown).
    public var copyrightStatus: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "CopyrightStatus") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "CopyrightStatus") }
    }

    /// Copyright registration number (plus:CopyrightRegistrationNumber).
    public var copyrightRegistrationNumber: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "CopyrightRegistrationNumber") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "CopyrightRegistrationNumber") }
    }

    /// Model release status in the PLUS namespace (plus:ModelReleaseStatus).
    /// "...MR-NON" (none), "...MR-NAP" (not applicable), "...MR-LMR" (limited or
    /// incomplete), "...MR-UMR" (unlimited). Most files use the iptcExt form.
    public var plusModelReleaseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "ModelReleaseStatus") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "ModelReleaseStatus") }
    }

    /// Property release status in the PLUS namespace (plus:PropertyReleaseStatus).
    public var plusPropertyReleaseStatus: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "PropertyReleaseStatus") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "PropertyReleaseStatus") }
    }

    /// Data-mining permission code-point URI (plus:DataMining).
    /// Standard values: "...DM-PRO" (protected), "...DM-NMP" (not for mining
    /// permitted), "...DM-AIN" (all incl. AI training).
    public var dataMining: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "DataMining") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "DataMining") }
    }

    /// Other constraints (plus:OtherConstraints).
    public var plusOtherConstraints: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "OtherConstraints") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "OtherConstraints") }
    }

    /// Other license requirements (plus:OtherLicenseRequirements).
    public var plusOtherLicenseRequirements: String? {
        get { simpleValue(namespace: XMPNamespace.plus, property: "OtherLicenseRequirements") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.plus, property: "OtherLicenseRequirements") }
    }

    // MARK: - EXIF / TIFF Camera Metadata

    // Values in XMP arrive pre-serialized (rationals as "1/125", lists as rdf:Seq). Numeric parsing
    // belongs on ExifData (the binary form), not here — this layer is a pass-through for XMP strings.

    // --- exif: ---

    /// Date and time the original image was taken (exif:DateTimeOriginal).
    public var exifDateTimeOriginal: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "DateTimeOriginal") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.exif, property: "DateTimeOriginal") }
            else { removeValue(namespace: XMPNamespace.exif, property: "DateTimeOriginal") }
        }
    }

    /// Date and time the image was digitized (exif:DateTimeDigitized).
    public var exifDateTimeDigitized: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "DateTimeDigitized") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "DateTimeDigitized") }
    }

    /// Exposure time in seconds (exif:ExposureTime). Rational form "1/125" or decimal.
    public var exifExposureTime: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "ExposureTime") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "ExposureTime") }
    }

    /// F-number (exif:FNumber). Rational form "56/10" or decimal "5.6".
    public var exifFNumber: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "FNumber") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "FNumber") }
    }

    /// ISO speed ratings (exif:ISOSpeedRatings) — rdf:Seq of integer strings.
    public var exifISOSpeedRatings: [String] {
        get { arrayValue(namespace: XMPNamespace.exif, property: "ISOSpeedRatings") }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.exif, property: "ISOSpeedRatings") }
            else { setValue(.array(newValue), namespace: XMPNamespace.exif, property: "ISOSpeedRatings") }
        }
    }

    /// Focal length in millimeters (exif:FocalLength).
    public var exifFocalLength: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "FocalLength") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "FocalLength") }
    }

    /// Focal length equivalent in 35mm film (exif:FocalLengthIn35mmFilm).
    public var exifFocalLengthIn35mmFilm: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "FocalLengthIn35mmFilm") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "FocalLengthIn35mmFilm") }
    }

    /// GPS latitude (exif:GPSLatitude). Formatted as "deg,min.decimalN" per XMP spec.
    public var exifGPSLatitude: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "GPSLatitude") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "GPSLatitude") }
    }

    /// GPS longitude (exif:GPSLongitude).
    public var exifGPSLongitude: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "GPSLongitude") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "GPSLongitude") }
    }

    /// GPS altitude in meters (exif:GPSAltitude). Rational.
    public var exifGPSAltitude: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "GPSAltitude") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "GPSAltitude") }
    }

    /// GPS timestamp (exif:GPSTimeStamp). W3C-DTF.
    public var exifGPSTimeStamp: String? {
        get { simpleValue(namespace: XMPNamespace.exif, property: "GPSTimeStamp") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exif, property: "GPSTimeStamp") }
    }

    // --- tiff: ---

    /// Camera manufacturer (tiff:Make).
    public var tiffMake: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "Make") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "Make") }
    }

    /// Camera model (tiff:Model).
    public var tiffModel: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "Model") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "Model") }
    }

    /// Orientation code "1"–"8" per TIFF 6.0 (tiff:Orientation).
    public var tiffOrientation: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "Orientation") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "Orientation") }
    }

    /// Software used to create/edit the image (tiff:Software).
    public var tiffSoftware: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "Software") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "Software") }
    }

    /// Pixel width (tiff:ImageWidth).
    public var tiffImageWidth: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "ImageWidth") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "ImageWidth") }
    }

    /// Pixel height (tiff:ImageLength).
    public var tiffImageLength: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "ImageLength") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "ImageLength") }
    }

    /// Image modification date (tiff:DateTime).
    public var tiffDateTime: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "DateTime") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "DateTime") }
    }

    /// Horizontal resolution (tiff:XResolution). Rational.
    public var tiffXResolution: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "XResolution") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "XResolution") }
    }

    /// Vertical resolution (tiff:YResolution). Rational.
    public var tiffYResolution: String? {
        get { simpleValue(namespace: XMPNamespace.tiff, property: "YResolution") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.tiff, property: "YResolution") }
    }

    /// Bits per sample (tiff:BitsPerSample) — rdf:Seq of ints, one per channel.
    public var tiffBitsPerSample: [String] {
        get { arrayValue(namespace: XMPNamespace.tiff, property: "BitsPerSample") }
        set {
            if newValue.isEmpty { removeValue(namespace: XMPNamespace.tiff, property: "BitsPerSample") }
            else { setValue(.array(newValue), namespace: XMPNamespace.tiff, property: "BitsPerSample") }
        }
    }

    // --- aux: (Lightroom/Adobe lens & body identity) ---

    /// Human-readable lens description (aux:Lens).
    public var auxLens: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "Lens") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "Lens") }
    }

    /// Lens info: four rationals (min/max focal length, min/max f-number) (aux:LensInfo).
    public var auxLensInfo: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "LensInfo") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "LensInfo") }
    }

    /// Lens ID (aux:LensID).
    public var auxLensID: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "LensID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "LensID") }
    }

    /// Lens serial number (aux:LensSerialNumber).
    public var auxLensSerialNumber: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "LensSerialNumber") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "LensSerialNumber") }
    }

    /// Camera body serial number (aux:SerialNumber).
    public var auxSerialNumber: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "SerialNumber") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "SerialNumber") }
    }

    /// Camera owner name (aux:OwnerName).
    public var auxOwnerName: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "OwnerName") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "OwnerName") }
    }

    /// Camera firmware (aux:Firmware).
    public var auxFirmware: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "Firmware") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "Firmware") }
    }

    /// Flash compensation (aux:FlashCompensation). Rational.
    public var auxFlashCompensation: String? {
        get { simpleValue(namespace: XMPNamespace.aux, property: "FlashCompensation") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.aux, property: "FlashCompensation") }
    }

    // --- exifEX: (Exif 2.3+ additions, minimal surface) ---

    /// Lens model string (exifEX:LensModel). Preferred over aux:Lens on newer cameras.
    public var exifExLensModel: String? {
        get { simpleValue(namespace: XMPNamespace.exifEX, property: "LensModel") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exifEX, property: "LensModel") }
    }

    /// Lens serial number per Exif 2.3 (exifEX:LensSerialNumber).
    public var exifExLensSerialNumber: String? {
        get { simpleValue(namespace: XMPNamespace.exifEX, property: "LensSerialNumber") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exifEX, property: "LensSerialNumber") }
    }

    /// Body serial number per Exif 2.3 (exifEX:BodySerialNumber).
    public var exifExBodySerialNumber: String? {
        get { simpleValue(namespace: XMPNamespace.exifEX, property: "BodySerialNumber") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exifEX, property: "BodySerialNumber") }
    }

    /// Camera owner name per Exif 2.3 (exifEX:CameraOwnerName).
    public var exifExCameraOwnerName: String? {
        get { simpleValue(namespace: XMPNamespace.exifEX, property: "CameraOwnerName") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.exifEX, property: "CameraOwnerName") }
    }

    private mutating func setSimpleOrRemove(_ value: String?, namespace: String, property: String) {
        if let v = value { setValue(.simple(v), namespace: namespace, property: property) }
        else { removeValue(namespace: namespace, property: property) }
    }

    // MARK: - XMP Media Management (xmpMM:)

    // Scalars only. xmpMM:DerivedFrom (stRef structure) and xmpMM:History (rdf:Seq of stEvt
    // structures) ride the existing generic `.structure` / `.structuredArray` API. Callers
    // that want typed access read them via `structureValue(namespace:property:)`.

    /// Globally unique document identifier (xmpMM:DocumentID).
    public var documentID: String? {
        get { simpleValue(namespace: XMPNamespace.xmpMM, property: "DocumentID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.xmpMM, property: "DocumentID") }
    }

    /// Globally unique instance identifier (xmpMM:InstanceID).
    public var instanceID: String? {
        get { simpleValue(namespace: XMPNamespace.xmpMM, property: "InstanceID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.xmpMM, property: "InstanceID") }
    }

    /// Original source document identifier, preserved across copies (xmpMM:OriginalDocumentID).
    public var originalDocumentID: String? {
        get { simpleValue(namespace: XMPNamespace.xmpMM, property: "OriginalDocumentID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.xmpMM, property: "OriginalDocumentID") }
    }

    /// Rendition class (xmpMM:RenditionClass). Typically "default", "thumbnail", "screen", "proof".
    public var renditionClass: String? {
        get { simpleValue(namespace: XMPNamespace.xmpMM, property: "RenditionClass") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.xmpMM, property: "RenditionClass") }
    }

    /// Version identifier (xmpMM:VersionID).
    public var versionID: String? {
        get { simpleValue(namespace: XMPNamespace.xmpMM, property: "VersionID") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.xmpMM, property: "VersionID") }
    }

    // MARK: - PDF (pdf:)

    /// PDF producer application (pdf:Producer).
    public var pdfProducer: String? {
        get { simpleValue(namespace: XMPNamespace.pdf, property: "Producer") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.pdf, property: "Producer") }
    }

    /// PDF document keywords as a single semicolon-separated string (pdf:Keywords).
    public var pdfKeywords: String? {
        get { simpleValue(namespace: XMPNamespace.pdf, property: "Keywords") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.pdf, property: "Keywords") }
    }

    /// PDF specification version (pdf:PDFVersion), e.g. "1.7".
    public var pdfVersion: String? {
        get { simpleValue(namespace: XMPNamespace.pdf, property: "PDFVersion") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.pdf, property: "PDFVersion") }
    }

    /// Trapped status (pdf:Trapped) — "True", "False", or "Unknown".
    public var pdfTrapped: String? {
        get { simpleValue(namespace: XMPNamespace.pdf, property: "Trapped") }
        set { setSimpleOrRemove(newValue, namespace: XMPNamespace.pdf, property: "Trapped") }
    }

    // MARK: - Rights & Usage Terms

    /// Usage terms for the image (xmpRights:UsageTerms).
    public var usageTerms: String? {
        get { simpleValue(namespace: XMPNamespace.xmpRights, property: "UsageTerms") }
        set {
            if let v = newValue { setValue(.langAlternative(v), namespace: XMPNamespace.xmpRights, property: "UsageTerms") }
            else { removeValue(namespace: XMPNamespace.xmpRights, property: "UsageTerms") }
        }
    }

    /// URL of a web page describing the license or usage terms (xmpRights:WebStatement).
    public var webStatement: String? {
        get { simpleValue(namespace: XMPNamespace.xmpRights, property: "WebStatement") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.xmpRights, property: "WebStatement") }
            else { removeValue(namespace: XMPNamespace.xmpRights, property: "WebStatement") }
        }
    }

    // MARK: - xmpDM (Dynamic Media — video / audio)

    /// Decoded `xmpDM:startTimeCode` and `xmpDM:altTimeCode` structures,
    /// exposing the `timeValue` (HH:MM:SS:FF or HH:MM:SS;FF drop-frame) and
    /// the optional `timeFormat` companion (Adobe enumerated string such as
    /// "24Timecode" / "2997DropTimecode" / "25Timecode" / "30Timecode").
    ///
    /// These are the canonical XMP video timecode fields, written by Adobe
    /// Premiere / Media Encoder, Avid Media Composer, DaVinci Resolve, and
    /// anything else that embeds an RDD-09 / RDD-47 compliant sidecar.
    public struct XMPTimecode: Sendable, Equatable {
        public var timeValue: String
        public var timeFormat: String?
        public init(timeValue: String, timeFormat: String? = nil) {
            self.timeValue = timeValue
            self.timeFormat = timeFormat
        }
        /// Numeric frame rate parsed from `timeFormat` (e.g. "2997DropTimecode"
        /// → 29.97, "24Timecode" → 24, "25Timecode" → 25). Returns nil for
        /// unknown / missing values.
        public var frameRate: Double? {
            guard let fmt = timeFormat else { return nil }
            // Adobe's enumerated strings start with a numeric prefix that
            // encodes the nominal fps × 100 for drop-frame and the nominal
            // fps for non-drop. We reverse-map the ones RDD-47 lists.
            switch fmt {
            case "24Timecode": return 24
            case "25Timecode": return 25
            case "2997DropTimecode", "2997NonDropTimecode": return 29.97
            case "30Timecode": return 30
            case "50Timecode": return 50
            case "5994DropTimecode", "5994NonDropTimecode": return 59.94
            case "60Timecode": return 60
            case "23976Timecode": return 23.976
            default: return nil
            }
        }
    }

    /// `xmpDM:startTimeCode`: the clip-start timecode. Returns nil when the
    /// structure or its `timeValue` field is missing.
    public var startTimecode: XMPTimecode? {
        get { timecodeStructure(property: "startTimeCode") }
    }

    /// `xmpDM:altTimeCode`: an alternate (secondary) timecode reel. Many
    /// editors set this to a user-facing timecode that runs separately from
    /// the source stamp.
    public var altTimecode: XMPTimecode? {
        get { timecodeStructure(property: "altTimeCode") }
    }

    private func timecodeStructure(property: String) -> XMPTimecode? {
        guard let fields = flatStructureValue(namespace: XMPNamespace.xmpDM, property: property) else {
            return nil
        }
        let ns = XMPNamespace.xmpDM
        guard let value = fields["\(ns)timeValue"], !value.isEmpty else { return nil }
        return XMPTimecode(timeValue: value, timeFormat: fields["\(ns)timeFormat"])
    }

    // MARK: - Lightroom (lr:)

    /// `lr:hierarchicalSubject` — a Bag of pipe-delimited keyword paths
    /// (e.g. `["Family|Vacation|Beach", "Locations|Norway|Oslo"]`). Lightroom
    /// Classic and Photo Mechanic both store hierarchical keywords here; the
    /// flat tag list lives in `dc:subject`.
    public var hierarchicalSubject: [String] {
        get { arrayValue(namespace: XMPNamespace.lr, property: "hierarchicalSubject") }
        set {
            if newValue.isEmpty {
                removeValue(namespace: XMPNamespace.lr, property: "hierarchicalSubject")
            } else {
                setValue(.array(newValue), namespace: XMPNamespace.lr, property: "hierarchicalSubject")
            }
        }
    }

    // MARK: - Creative Commons (cc:)

    /// `cc:license` — Creative Commons license URI (e.g.
    /// `https://creativecommons.org/licenses/by-sa/4.0/`).
    public var creativeCommonsLicense: String? {
        get { simpleValue(namespace: XMPNamespace.cc, property: "license") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.cc, property: "license") }
            else { removeValue(namespace: XMPNamespace.cc, property: "license") }
        }
    }

    /// `cc:attributionURL` — canonical URL the user should link to when
    /// crediting the work.
    public var creativeCommonsAttributionURL: String? {
        get { simpleValue(namespace: XMPNamespace.cc, property: "attributionURL") }
        set {
            if let v = newValue { setValue(.simple(v), namespace: XMPNamespace.cc, property: "attributionURL") }
            else { removeValue(namespace: XMPNamespace.cc, property: "attributionURL") }
        }
    }

    // MARK: - Google Spatial / MotionPhoto (GCamera:, GPano:)

    /// `GCamera:MotionPhoto` — set to "1" by Google's MotionPhoto encoders
    /// (Pixel, recent Samsung phones) when the carrier file embeds a MOV
    /// micro-video alongside the still image.
    public var isGoogleMotionPhoto: Bool {
        guard let s = simpleValue(namespace: XMPNamespace.gCamera, property: "MotionPhoto") else {
            return false
        }
        return s == "1" || s.lowercased() == "true"
    }

    /// `GCamera:MicroVideoOffset` — byte offset from the end of file to the
    /// start of the embedded MOV. Use this to extract the motion-photo MOV
    /// without re-parsing the whole carrier.
    public var googleMicroVideoOffset: Int? {
        simpleValue(namespace: XMPNamespace.gCamera, property: "MicroVideoOffset").flatMap(Int.init)
    }

    /// `GPano:ProjectionType` — usually `"equirectangular"` for 360 photos.
    public var panoramaProjectionType: String? {
        simpleValue(namespace: XMPNamespace.gPano, property: "ProjectionType")
    }

    /// `GPano:FullPanoWidthPixels` — width of the *full* spherical canvas
    /// the cropped image is sampled from. May exceed the JPEG's pixel width
    /// for partial / cropped panoramas.
    public var panoramaFullWidth: Int? {
        simpleValue(namespace: XMPNamespace.gPano, property: "FullPanoWidthPixels").flatMap(Int.init)
    }

    /// `GPano:FullPanoHeightPixels` — height of the full spherical canvas.
    public var panoramaFullHeight: Int? {
        simpleValue(namespace: XMPNamespace.gPano, property: "FullPanoHeightPixels").flatMap(Int.init)
    }
}
