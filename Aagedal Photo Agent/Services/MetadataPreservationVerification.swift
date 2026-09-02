import CryptoKit
import Foundation
import SwiftMediaMetadata

/// Metadata families whose semantic identity can be checked independently of the descriptive
/// values resolved by a deadline profile. C2PA is deliberately not a member: carrying a manifest
/// into a newly rendered asset has provenance consequences that are not a metadata-preservation
/// mismatch and must be reported separately.
nonisolated enum MetadataPreservationDomain: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case exif
    case iptc
    case xmp
    case cameraRaw
}

nonisolated enum MetadataPreservationSupport: String, Codable, Equatable, Sendable {
    /// The reader and destination carrier can represent this domain and an identity was captured.
    case supported
    /// The format or rendition contract explicitly does not promise identity for this domain.
    case unsupported
    /// The implementation cannot make a reliable claim for this domain.
    case unknown
}

/// Explicit capabilities for the parsed carrier. Keeping this on every snapshot prevents a
/// missing parser feature from being mistaken for a removed metadata block.
nonisolated struct MetadataPreservationFormatCapability: Codable, Equatable, Sendable {
    let formatIdentifier: String
    let domains: [MetadataPreservationDomainSupport]
    let c2pa: MetadataPreservationSupport

    func support(for domain: MetadataPreservationDomain) -> MetadataPreservationSupport {
        domains.first(where: { $0.domain == domain })?.support ?? .unknown
    }
}

nonisolated struct MetadataPreservationDomainSupport: Codable, Equatable, Sendable {
    let domain: MetadataPreservationDomain
    let support: MetadataPreservationSupport
}

/// A transport-safe semantic fingerprint. No descriptive values or raw metadata payloads are
/// exposed in this value, so it is suitable for a staging result or future resume manifest.
nonisolated struct MetadataPreservationSnapshot: Codable, Equatable, Sendable {
    let capability: MetadataPreservationFormatCapability
    let identities: [MetadataPreservationDomainIdentity]
    let c2paIdentity: String?

    func identity(for domain: MetadataPreservationDomain) -> String? {
        identities.first(where: { $0.domain == domain })?.sha256
    }
}

nonisolated struct MetadataPreservationDomainIdentity: Codable, Equatable, Sendable {
    let domain: MetadataPreservationDomain
    let sha256: String
}

nonisolated enum MetadataPreservationComparisonStatus: String, Codable, Equatable, Sendable {
    case match
    case mismatch
    case unsupported
    case unknown
}

nonisolated struct MetadataPreservationDomainResult: Codable, Equatable, Sendable {
    let domain: MetadataPreservationDomain
    let status: MetadataPreservationComparisonStatus
    let sourceIdentity: String?
    let stagedIdentity: String?
}

/// C2PA bytes bind to an asset. A byte-for-byte carried manifest on a new rendition is not proof
/// that the binding is valid, so the names below describe carriage only and never trust validity.
nonisolated enum C2PACarriageConsequence: String, Codable, Equatable, Sendable {
    case absentFromBoth
    case carriedUnchanged
    case removed
    case added
    case changed
    case unsupported
    case unknown
}

nonisolated struct MetadataPreservationVerificationReport: Codable, Equatable, Sendable {
    let sourceFormatIdentifier: String
    let stagedFormatIdentifier: String
    let domains: [MetadataPreservationDomainResult]
    let c2paConsequence: C2PACarriageConsequence

    /// A supported domain with different identities is concrete proof of loss.
    var hasProvenMismatch: Bool {
        domains.contains { $0.status == .mismatch }
    }

    /// Delivery accepts a semantic match or an explicitly unsupported format boundary. Unknown
    /// means preservation could not be confirmed and is therefore fail-closed for staging.
    /// C2PA carriage remains evidence-only here; provenance validity has its own validator.
    var isAcceptableForDelivery: Bool {
        domains.allSatisfy { $0.status == .match || $0.status == .unsupported }
    }

    var mismatchedDomains: [MetadataPreservationDomain] {
        domains.compactMap { $0.status == .mismatch ? $0.domain : nil }
    }

    static func unknown(
        sourceFormatIdentifier: String = "unknown",
        stagedFormatIdentifier: String = "unknown"
    ) -> Self {
        Self(
            sourceFormatIdentifier: sourceFormatIdentifier,
            stagedFormatIdentifier: stagedFormatIdentifier,
            domains: MetadataPreservationDomain.allCases.map {
                MetadataPreservationDomainResult(
                    domain: $0,
                    status: .unknown,
                    sourceIdentity: nil,
                    stagedIdentity: nil
                )
            },
            c2paConsequence: .unknown
        )
    }
}

/// Pure comparison boundary. It consumes only immutable snapshots and does no parsing or I/O.
nonisolated enum MetadataPreservationComparator {
    static func compare(
        source: MetadataPreservationSnapshot,
        staged: MetadataPreservationSnapshot
    ) -> MetadataPreservationVerificationReport {
        let domainResults = MetadataPreservationDomain.allCases.map { domain in
            let sourceSupport = source.capability.support(for: domain)
            let stagedSupport = staged.capability.support(for: domain)
            let sourceIdentity = source.identity(for: domain)
            let stagedIdentity = staged.identity(for: domain)
            let status: MetadataPreservationComparisonStatus

            if sourceSupport == .unknown || stagedSupport == .unknown {
                status = .unknown
            } else if sourceSupport == .unsupported || stagedSupport == .unsupported {
                status = .unsupported
            } else if let sourceIdentity, let stagedIdentity {
                status = sourceIdentity == stagedIdentity ? .match : .mismatch
            } else {
                status = .unknown
            }

            return MetadataPreservationDomainResult(
                domain: domain,
                status: status,
                sourceIdentity: sourceIdentity,
                stagedIdentity: stagedIdentity
            )
        }

        return MetadataPreservationVerificationReport(
            sourceFormatIdentifier: source.capability.formatIdentifier,
            stagedFormatIdentifier: staged.capability.formatIdentifier,
            domains: domainResults,
            c2paConsequence: compareC2PA(source: source, staged: staged)
        )
    }

    private static func compareC2PA(
        source: MetadataPreservationSnapshot,
        staged: MetadataPreservationSnapshot
    ) -> C2PACarriageConsequence {
        let sourceSupport = source.capability.c2pa
        let stagedSupport = staged.capability.c2pa
        if sourceSupport == .unknown || stagedSupport == .unknown { return .unknown }
        if sourceSupport == .unsupported || stagedSupport == .unsupported { return .unsupported }

        switch (source.c2paIdentity, staged.c2paIdentity) {
        case (nil, nil): return .absentFromBoth
        case (.some, nil): return .removed
        case (nil, .some): return .added
        case let (.some(lhs), .some(rhs)) where lhs == rhs: return .carriedUnchanged
        case (.some, .some): return .changed
        }
    }
}

/// Describes which expected rendition mutations must be removed from the unrelated-metadata
/// identity. Profile-controlled descriptive fields are excluded under every policy.
nonisolated struct MetadataPreservationSnapshotPolicy: Sendable {
    let treatsCameraRawAsPreservable: Bool
    let excludesRenderedEXIF: Bool
    let excludesRendererAuthoredXMP: Bool

    /// Exact semantic copy, useful for no-op writers and sidecar/file round-trip verification.
    static let exactCopy = Self(
        treatsCameraRawAsPreservable: true,
        excludesRenderedEXIF: false,
        excludesRendererAuthoredXMP: false
    )

    /// Deadline renders bake develop state, normalize orientation/dimensions, and stamp the tool.
    /// Those are output facts, not unrelated-metadata loss.
    static let renderedDelivery = Self(
        treatsCameraRawAsPreservable: false,
        excludesRenderedEXIF: true,
        excludesRendererAuthoredXMP: true
    )
}

/// Converts SwiftExif's typed representation into stable, privacy-safe semantic identities.
nonisolated enum MetadataPreservationSnapshotBuilder {
    private static let cameraRawNamespace = XMPNamespace.crs
    private static let appDevelopNamespace = "http://aagedal.me/ns/photo/1.0/"

    static func makeSnapshot(
        from metadata: ImageMetadata,
        policy: MetadataPreservationSnapshotPolicy = .exactCopy
    ) -> MetadataPreservationSnapshot {
        var capability = formatCapability(for: metadata.format)
        if !policy.treatsCameraRawAsPreservable {
            capability = replacingSupport(
                in: capability,
                domain: .cameraRaw,
                with: .unsupported
            )
        }

        let identities = MetadataPreservationDomain.allCases.compactMap { domain
            -> MetadataPreservationDomainIdentity? in
            guard capability.support(for: domain) == .supported else { return nil }
            let canonical: Data
            switch domain {
            case .exif:
                canonical = canonicalEXIF(metadata.exif, policy: policy)
            case .iptc:
                canonical = canonicalIPTC(metadata.iptc)
            case .xmp:
                canonical = canonicalXMP(metadata.xmp, kind: .unrelated, policy: policy)
            case .cameraRaw:
                canonical = canonicalXMP(metadata.xmp, kind: .cameraRaw, policy: policy)
            }
            return MetadataPreservationDomainIdentity(domain: domain, sha256: sha256(canonical))
        }

        return MetadataPreservationSnapshot(
            capability: capability,
            identities: identities,
            c2paIdentity: c2paIdentity(in: metadata)
        )
    }

    // MARK: Explicit carrier capabilities

    static func formatCapability(for format: ImageFormat) -> MetadataPreservationFormatCapability {
        let identifier: String
        let domainSupport: [MetadataPreservationDomain: MetadataPreservationSupport]
        let c2pa: MetadataPreservationSupport

        let allSupported = Dictionary(
            uniqueKeysWithValues: MetadataPreservationDomain.allCases.map {
                ($0, MetadataPreservationSupport.supported)
            }
        )
        let xmpCarrierSupported: [MetadataPreservationDomain: MetadataPreservationSupport] = [
            .exif: .supported,
            .iptc: .unsupported,
            .xmp: .supported,
            .cameraRaw: .supported,
        ]
        let allUnsupported = Dictionary(
            uniqueKeysWithValues: MetadataPreservationDomain.allCases.map {
                ($0, MetadataPreservationSupport.unsupported)
            }
        )
        let allUnknown = Dictionary(
            uniqueKeysWithValues: MetadataPreservationDomain.allCases.map {
                ($0, MetadataPreservationSupport.unknown)
            }
        )

        switch format {
        case .jpeg:
            identifier = "jpeg"; domainSupport = allSupported; c2pa = .supported
        case .tiff:
            identifier = "tiff"; domainSupport = allSupported; c2pa = .supported
        case .raw(let raw):
            identifier = "raw.\(raw.rawValue)"; domainSupport = allSupported; c2pa = .supported
        case .jpegXL:
            identifier = "jpegXL"; domainSupport = xmpCarrierSupported; c2pa = .supported
        case .png:
            identifier = "png"; domainSupport = xmpCarrierSupported; c2pa = .supported
        case .avif:
            identifier = "avif"; domainSupport = xmpCarrierSupported; c2pa = .supported
        case .heif:
            identifier = "heif"; domainSupport = xmpCarrierSupported; c2pa = .supported
        case .webp:
            identifier = "webp"; domainSupport = xmpCarrierSupported; c2pa = .supported
        case .gif:
            // SwiftExif can inspect XMP/C2PA in GIF application extensions, but this app's
            // delivery renderer does not promise unrelated EXIF/IPTC/CRS carriage for GIF.
            identifier = "gif"; domainSupport = allUnsupported; c2pa = .supported
        case .bmp:
            identifier = "bmp"; domainSupport = allUnsupported; c2pa = .unsupported
        case .svg:
            identifier = "svg"; domainSupport = allUnsupported; c2pa = .unsupported
        case .pdf:
            identifier = "pdf"; domainSupport = allUnknown; c2pa = .supported
        case .psd:
            identifier = "psd"; domainSupport = allUnknown; c2pa = .unknown
        }

        return MetadataPreservationFormatCapability(
            formatIdentifier: identifier,
            domains: MetadataPreservationDomain.allCases.map {
                MetadataPreservationDomainSupport(domain: $0, support: domainSupport[$0] ?? .unknown)
            },
            c2pa: c2pa
        )
    }

    private static func replacingSupport(
        in capability: MetadataPreservationFormatCapability,
        domain: MetadataPreservationDomain,
        with support: MetadataPreservationSupport
    ) -> MetadataPreservationFormatCapability {
        MetadataPreservationFormatCapability(
            formatIdentifier: capability.formatIdentifier,
            domains: MetadataPreservationDomain.allCases.map {
                MetadataPreservationDomainSupport(
                    domain: $0,
                    support: $0 == domain ? support : capability.support(for: $0)
                )
            },
            c2pa: capability.c2pa
        )
    }

    // MARK: EXIF

    private static func canonicalEXIF(
        _ exif: ExifData?,
        policy: MetadataPreservationSnapshotPolicy
    ) -> Data {
        // A rendered file may need an EXIF shell solely to carry output-owned fields such as
        // normalized orientation. Once those fields are excluded by the policy, that shell is
        // semantically identical to a source with no EXIF block at all.
        let byteOrder = exif?.byteOrder ?? .littleEndian
        var parts = canonicalEntries(
            exif?.ifd0,
            label: "ifd0",
            byteOrder: byteOrder,
            policy: policy
        )
        parts += canonicalEntries(
            exif?.exifIFD,
            label: "exif",
            byteOrder: byteOrder,
            policy: policy
        )
        // GPS is controlled by the deadline profile and resolved metadata, so it is never part of
        // the unrelated identity. IFD1 is a rendered thumbnail and is likewise output-owned.
        parts += canonicalEntries(
            exif?.makerNoteIFD,
            label: "maker",
            byteOrder: byteOrder,
            policy: policy
        )
        return framed(parts.sorted())
    }

    private static func canonicalEntries(
        _ ifd: IFD?,
        label: String,
        byteOrder: ByteOrder,
        policy: MetadataPreservationSnapshotPolicy
    ) -> [String] {
        guard let ifd else { return ["\(label):absent"] }
        let entries: [String] = ifd.entries.compactMap { entry -> String? in
            guard !excludedEXIFTags(policy: policy).contains(entry.tag) else { return nil }
            return "\(label):\(entry.tag):\(entry.type.rawValue):\(entry.count):\(canonicalEXIFValue(entry, byteOrder: byteOrder))"
        }
        return entries.isEmpty ? ["\(label):absent"] : entries
    }

    private static func canonicalEXIFValue(_ entry: IFDEntry, byteOrder: ByteOrder) -> String {
        var reader = BinaryReader(data: entry.valueData)
        let count = Int(entry.count)
        do {
            switch entry.type {
            case .byte:
                return try (0..<count).map { _ in String(try reader.readUInt8()) }.joined(separator: ",")
            case .sbyte:
                return try (0..<count).map { _ in
                    String(Int8(bitPattern: try reader.readUInt8()))
                }.joined(separator: ",")
            case .short:
                return try (0..<count).map { _ in
                    String(try reader.readUInt16(endian: byteOrder))
                }.joined(separator: ",")
            case .sshort:
                return try (0..<count).map { _ in
                    String(try reader.readInt16(endian: byteOrder))
                }.joined(separator: ",")
            case .long:
                return try (0..<count).map { _ in
                    String(try reader.readUInt32(endian: byteOrder))
                }.joined(separator: ",")
            case .slong:
                return try (0..<count).map { _ in
                    String(try reader.readInt32(endian: byteOrder))
                }.joined(separator: ",")
            case .rational:
                return try (0..<count).map { _ in
                    let numerator = try reader.readUInt32(endian: byteOrder)
                    let denominator = try reader.readUInt32(endian: byteOrder)
                    return "\(numerator)/\(denominator)"
                }.joined(separator: ",")
            case .srational:
                return try (0..<count).map { _ in
                    let numerator = try reader.readInt32(endian: byteOrder)
                    let denominator = try reader.readInt32(endian: byteOrder)
                    return "\(numerator)/\(denominator)"
                }.joined(separator: ",")
            case .float:
                return try (0..<count).map { _ in
                    String(try reader.readUInt32(endian: byteOrder), radix: 16)
                }.joined(separator: ",")
            case .double:
                return try (0..<count).map { _ in
                    String(try reader.readUInt64(endian: byteOrder), radix: 16)
                }.joined(separator: ",")
            case .ascii, .undefined:
                return entry.valueData.base64EncodedString()
            }
        } catch {
            // A malformed/truncated value remains fingerprintable without asserting semantics.
            return "raw:\(entry.valueData.base64EncodedString())"
        }
    }

    private static func excludedEXIFTags(
        policy: MetadataPreservationSnapshotPolicy
    ) -> Set<UInt16> {
        // Offset pointers are serialization provenance, not semantic metadata identities.
        // TIFF stores XMP and IIM inside IFD0 carrier tags and relocates raster offsets whenever
        // those blocks change size. Those values are respectively fingerprinted by the XMP/IPTC
        // domains or describe byte layout, so counting them again as EXIF creates a false mismatch
        // after an otherwise preserving descriptive write.
        var tags: Set<UInt16> = [
            0x8769, 0x8825, 0xA005, 0x014A, // nested IFD pointers
            0x0111, 0x0144, 0x0201,         // strip/tile/old-JPEG raster offsets
            0x02BC,                         // TIFF XMP carrier
            0x83BB, 0x8649,                 // TIFF IIM / Photoshop IRB carriers
        ]
        guard policy.excludesRenderedEXIF else { return tags }
        tags.formUnion([
            0x0100, // ImageWidth
            0x0101, // ImageLength
            0x0112, // Orientation (rendered pixels are normalized upright)
            0xA002, // PixelXDimension
            0xA003, // PixelYDimension
        ])
        return tags
    }

    // MARK: IPTC

    private static func canonicalIPTC(_ iptc: IPTCData) -> Data {
        let parts = iptc.datasets.compactMap { dataset -> String? in
            guard !controlledIPTCTags.contains(dataset.tag) else { return nil }
            return "\(dataset.tag.record):\(dataset.tag.dataSet):\(dataset.rawValue.base64EncodedString())"
        }
        return framed(parts.sorted())
    }

    /// Every IIM dataset that the profile-resolved descriptive writer may replace or clear.
    private static let controlledIPTCTags: Set<IPTCTag> = [
        // The IIM writer authors/removes 1:90 as a serialization declaration whenever controlled
        // text needs UTF-8. The actual unrelated dataset bytes remain independently fingerprinted.
        .codedCharacterSet,
        .objectName, .urgency, .keywords, .specialInstructions, .dateCreated, .timeCreated,
        .byline, .bylineTitle, .city, .sublocation, .provinceState,
        .countryPrimaryLocationCode, .countryPrimaryLocationName,
        .originalTransmissionReference, .headline, .credit, .source, .copyrightNotice,
        .contact, .captionAbstract, .writerEditor,
    ]

    // MARK: XMP / Camera Raw

    private enum XMPIdentityKind { case unrelated, cameraRaw, c2pa }

    private static func canonicalXMP(
        _ xmp: XMPData?,
        kind: XMPIdentityKind,
        policy: MetadataPreservationSnapshotPolicy
    ) -> Data {
        // Domain identities describe semantic values, not whether an otherwise empty XMP packet
        // exists. A packet containing only profile-controlled or renderer-authored values is the
        // same unrelated-domain state as no packet.
        guard let xmp else { return framed([]) }
        var parts: [String] = []
        for key in xmp.allKeys.sorted() {
            let belongsToCameraRaw = key.hasPrefix(cameraRawNamespace)
                || key.hasPrefix(appDevelopNamespace)
            let belongsToC2PA = key.hasPrefix(XMPNamespace.c2pa)
            let include: Bool
            switch kind {
            case .cameraRaw: include = belongsToCameraRaw
            case .c2pa: include = belongsToC2PA
            case .unrelated:
                include = !belongsToCameraRaw
                    && !belongsToC2PA
                    && !controlledXMPKeys.contains(key)
                    && !(policy.excludesRendererAuthoredXMP
                        && key == XMPNamespace.xmp + "CreatorTool")
            }
            guard include, let value = xmp.value(forKey: key) else { continue }
            parts.append("key:\(key)")
            parts.append(canonicalXMPValue(value))
        }

        if kind == .unrelated, let regions = xmp.regions {
            parts.append(canonicalRegions(regions))
        }
        return framed(parts)
    }

    private static func canonicalXMPValue(_ value: XMPValue) -> String {
        switch value {
        case .simple(let value): return "simple:\(framedString(value))"
        case .langAlternative(let value): return "lang:\(framedString(value))"
        case .languageAlternative(let values):
            let framedValues = values.map {
                framedString($0.language) + framedString($0.value)
            }.joined()
            return "langs:\(framedValues)"
        case .array(let values):
            return "array:\(values.map(framedString).joined())"
        case .structure(let fields):
            let encodedFields = fields.keys.sorted().map { key in
                framedString(key) + canonicalXMPValue(fields[key]!)
            }.joined()
            return "struct:\(encodedFields)"
        case .structuredArray(let values):
            let encodedValues = values.map { fields in
                fields.keys.sorted().map { key in
                    framedString(key) + canonicalXMPValue(fields[key]!)
                }.joined()
            }.map(framedString).joined()
            return "structArray:\(encodedValues)"
        }
    }

    private static func canonicalRegions(_ value: XMPRegionList) -> String {
        let dimensions = [
            value.appliedToDimensionsW.map(String.init) ?? "nil",
            value.appliedToDimensionsH.map(String.init) ?? "nil",
            value.appliedToDimensionsUnit ?? "nil",
        ].map(framedString).joined()
        let regions = value.regions.map { region in
            [
                region.name ?? "nil",
                region.type?.rawValue ?? "nil",
                String(region.area.x), String(region.area.y),
                String(region.area.w), String(region.area.h), region.area.unit,
                region.description ?? "nil",
            ].map(framedString).joined()
        }.map(framedString).joined()
        return "regions:\(dimensions)\(regions)"
    }

    /// XMP counterparts of every profile-controlled descriptive, GPS, rating, and label field.
    private static let controlledXMPKeys: Set<String> = [
        XMPNamespace.dc + "title",
        XMPNamespace.dc + "description",
        XMPNamespace.dc + "subject",
        XMPNamespace.dc + "creator",
        XMPNamespace.dc + "rights",
        XMPNamespace.photoshop + "Headline",
        XMPNamespace.photoshop + "AuthorsPosition",
        XMPNamespace.photoshop + "CaptionWriter",
        XMPNamespace.photoshop + "Credit",
        XMPNamespace.photoshop + "TransmissionReference",
        XMPNamespace.photoshop + "DateCreated",
        XMPNamespace.photoshop + "City",
        XMPNamespace.photoshop + "State",
        XMPNamespace.photoshop + "Country",
        XMPNamespace.photoshop + "Urgency",
        XMPNamespace.photoshop + "Instructions",
        XMPNamespace.photoshop + "Source",
        XMPNamespace.iptcCore + "Location",
        XMPNamespace.iptcCore + "CountryCode",
        XMPNamespace.iptcCore + "Scene",
        XMPNamespace.iptcCore + "ExtDescrAccessibility",
        XMPNamespace.iptcCore + "CreatorContactInfo",
        XMPNamespace.iptcExt + "PersonInImage",
        XMPNamespace.iptcExt + "OrganisationInImageName",
        XMPNamespace.iptcExt + "OrganisationInImageCode",
        XMPNamespace.iptcExt + "DigitalSourceType",
        XMPNamespace.iptcExt + "DigImageGUID",
        // Legacy scalar namespace is controlled because canonical writes remove it during
        // migration to PLUS.
        XMPNamespace.iptcExt + "ImageSupplierImageID",
        XMPNamespace.iptcExt + "Event",
        XMPNamespace.iptcExt + "LocationCreated",
        XMPNamespace.iptcExt + "LocationShown",
        XMPNamespace.plus + "ImageSupplierImageID",
        XMPNamespace.plus + "ImageSupplier",
        XMPNamespace.xmpRights + "UsageTerms",
        XMPNamespace.xmpRights + "WebStatement",
        XMPNamespace.xmp + "Rating",
        XMPNamespace.xmp + "Label",
        XMPNamespace.exif + "GPSLatitude",
        XMPNamespace.exif + "GPSLongitude",
        XMPNamespace.exif + "GPSLatitudeRef",
        XMPNamespace.exif + "GPSLongitudeRef",
        XMPNamespace.tiff + "Orientation",
    ]

    // MARK: C2PA carriage

    private static func c2paIdentity(in metadata: ImageMetadata) -> String? {
        var parts: [String] = []
        if let c2pa = metadata.c2pa {
            for manifest in c2pa.manifests {
                parts.append("label:\(manifest.label)")
                parts.append("claim:\(manifest.claim.rawCBORBytes.base64EncodedString())")
                parts.append("signature:\(manifest.signature.signatureBytes.base64EncodedString())")
            }
        }
        let xmpCarriage = canonicalXMP(metadata.xmp, kind: .c2pa, policy: .exactCopy)
        if xmpCarriage != framed(["absent"]), xmpCarriage != framed([]) {
            parts.append("xmp:\(xmpCarriage.base64EncodedString())")
        }
        return parts.isEmpty ? nil : sha256(framed(parts))
    }

    // MARK: Canonical framing

    private static func framed(_ values: [String]) -> Data {
        var result = Data()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    private static func framedString(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Source-vs-staged injection seam for the delivery coordinator. Implementations always return a
/// report: inability to parse is `.unknown`, allowing the coordinator to fail closed with typed
/// evidence instead of collapsing inspection failure into an unrelated operational exception.
nonisolated struct DeliveryStageMetadataPreservationVerifier: Sendable {
    let verify: @Sendable (
        _ sourceURL: URL,
        _ stagedBytes: Data,
        _ stagedURL: URL
    ) async -> MetadataPreservationVerificationReport

    static let liveRenderedDelivery = Self { sourceURL, stagedBytes, _ in
        await Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let source = try ImageMetadata.read(from: sourceURL)
                try Task.checkCancellation()
                let staged = try ImageMetadata.read(from: stagedBytes)
                let sourceSnapshot = MetadataPreservationSnapshotBuilder.makeSnapshot(
                    from: source,
                    policy: .renderedDelivery
                )
                let stagedSnapshot = MetadataPreservationSnapshotBuilder.makeSnapshot(
                    from: staged,
                    policy: .renderedDelivery
                )
                return MetadataPreservationComparator.compare(
                    source: sourceSnapshot,
                    staged: stagedSnapshot
                )
            } catch {
                return .unknown()
            }
        }.value
    }
}
