import Foundation

/// A reusable set of metadata field values that can be applied to images.
/// Templates define default IPTC and XMP values for common photojournalism workflows.
public struct MetadataTemplate: Sendable {
    public let name: String
    public let iptcFields: [IPTCTag: String]
    public let iptcArrayFields: [IPTCTag: [String]]
    public let xmpFields: [(namespace: String, property: String, value: XMPValue)]

    public init(
        name: String,
        iptcFields: [IPTCTag: String] = [:],
        iptcArrayFields: [IPTCTag: [String]] = [:],
        xmpFields: [(namespace: String, property: String, value: XMPValue)] = []
    ) {
        self.name = name
        self.iptcFields = iptcFields
        self.iptcArrayFields = iptcArrayFields
        self.xmpFields = xmpFields
    }

    /// Apply this template to an ImageMetadata instance.
    /// - Parameter overwrite: If `true`, overwrites existing values. If `false`, only sets fields that are empty.
    public func apply(to metadata: inout ImageMetadata, overwrite: Bool = false) throws {
        for (tag, value) in iptcFields {
            if overwrite || metadata.iptc.value(for: tag) == nil {
                try metadata.iptc.setValue(value, for: tag)
            }
        }

        for (tag, values) in iptcArrayFields {
            if overwrite || metadata.iptc.values(for: tag).isEmpty {
                try metadata.iptc.setValues(values, for: tag)
            }
        }

        if !xmpFields.isEmpty {
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            for field in xmpFields {
                let existing = metadata.xmp?.value(namespace: field.namespace, property: field.property)
                if overwrite || existing == nil {
                    metadata.xmp?.setValue(field.value, namespace: field.namespace, property: field.property)
                }
            }
        }

        metadata.syncIPTCToXMP()
    }

    // MARK: - Built-in Templates

    /// News wire photo template with standard editorial defaults.
    public static let news = MetadataTemplate(
        name: "News",
        iptcFields: [
            .bylineTitle: "Staff Photographer",
            .urgency: "5",
            .objectCycle: "a",
            .editStatus: "New",
        ],
        xmpFields: [
            (XMPNamespace.xmpRights, "UsageTerms", .langAlternative("For editorial use only")),
            (XMPNamespace.xmp, "CreatorTool", .simple("SwiftExif")),
        ]
    )

    /// Stock photography template with commercial licensing defaults.
    public static let stock = MetadataTemplate(
        name: "Stock",
        iptcFields: [
            .category: "STK",
            .editStatus: "Final",
        ],
        iptcArrayFields: [
            .supplementalCategories: ["Stock", "Commercial"],
        ],
        xmpFields: [
            (XMPNamespace.xmpRights, "UsageTerms", .langAlternative("Licensed for commercial use")),
        ]
    )

    /// Editorial/feature photo template.
    public static let editorial = MetadataTemplate(
        name: "Editorial",
        iptcFields: [
            .urgency: "5",
            .objectCycle: "b",
            .editStatus: "New",
        ],
        xmpFields: [
            (XMPNamespace.xmpRights, "UsageTerms", .langAlternative("For editorial use only")),
        ]
    )

    /// AI-generated content template with appropriate Digital Source Type.
    public static let aiGenerated = MetadataTemplate(
        name: "AI Generated",
        xmpFields: [
            (XMPNamespace.iptcExt, "DigitalSourceType",
             .simple("http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")),
            (XMPNamespace.xmpRights, "UsageTerms", .langAlternative("AI-generated content")),
        ]
    )

    /// Composite/edited image template with Digital Source Type.
    public static let compositeEdited = MetadataTemplate(
        name: "Composite Edited",
        xmpFields: [
            (XMPNamespace.iptcExt, "DigitalSourceType",
             .simple("http://cv.iptc.org/newscodes/digitalsourcetype/compositeSynthetic")),
        ]
    )
}
