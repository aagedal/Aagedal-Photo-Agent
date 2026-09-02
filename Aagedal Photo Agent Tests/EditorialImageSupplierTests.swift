import Foundation
import SwiftMediaMetadata
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Structured Image Supplier")
struct EditorialImageSupplierTests {
    @Test("Supplier members normalize only line endings and outer whitespace")
    func memberNormalization() {
        let supplier = EditorialImageSupplier(
            identifier: "  agency:News/Oslo  ",
            name: "  News\r\nAgency  "
        )

        #expect(supplier.identifier == "agency:News/Oslo")
        #expect(supplier.name == "News\nAgency")
    }

    @Test("Sequence normalization preserves order, opaque case, and partial structures")
    func sequenceNormalization() {
        let values = EditorialImageSupplier.normalizedValues([
            EditorialImageSupplier(identifier: "NO-AGENCY", name: "Agency"),
            EditorialImageSupplier(identifier: "no-agency", name: "Agency"),
            EditorialImageSupplier(name: "Name only"),
            EditorialImageSupplier(identifier: "ID-only"),
            EditorialImageSupplier(identifier: "NO-AGENCY", name: "Agency"),
            EditorialImageSupplier(identifier: " ", name: "\n"),
        ])

        #expect(values == [
            EditorialImageSupplier(identifier: "NO-AGENCY", name: "Agency"),
            EditorialImageSupplier(identifier: "no-agency", name: "Agency"),
            EditorialImageSupplier(name: "Name only"),
            EditorialImageSupplier(identifier: "ID-only"),
        ])
    }

    @Test("Mutations distinguish untouched, clear, append, and replace")
    func mutationsAreExplicit() {
        let original = [EditorialImageSupplier(identifier: "A", name: "Alpha")]
        let appended = EditorialImageSupplier(identifier: "B", name: "Beta")

        #expect(EditorialImageSupplierMutation.untouched.apply(to: original) == original)
        #expect(EditorialImageSupplierMutation.clear.apply(to: original).isEmpty)
        #expect(EditorialImageSupplierMutation.append([appended, original[0]]).apply(to: original) == [
            original[0], appended,
        ])
        #expect(EditorialImageSupplierMutation.replace([appended]).apply(to: original) == [appended])
    }

    @Test("JSON uses stable identifier and name members")
    func stableJSONMembers() throws {
        let supplier = EditorialImageSupplier(identifier: "A", name: "Alpha")
        let data = try JSONEncoder().encode(supplier)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(object == ["identifier": "A", "name": "Alpha"])
        #expect(try JSONDecoder().decode(EditorialImageSupplier.self, from: data) == supplier)
    }

    @Test("Canonical sequence transport is lossless and rejects flattened text")
    func canonicalSequenceTransport() throws {
        let suppliers = [
            EditorialImageSupplier(identifier: "agency:one,two", name: "One, Two News"),
            EditorialImageSupplier(name: "Name only"),
        ]
        let encoded = try #require(EditorialImageSupplier.canonicalJSONString(for: suppliers))

        #expect(encoded == #"[{"identifier":"agency:one,two","name":"One, Two News"},{"name":"Name only"}]"#)
        #expect(EditorialImageSupplier.values(fromCanonicalJSONString: encoded) == suppliers)
        #expect(EditorialImageSupplier.values(fromCanonicalJSONString: "One, Two News") == nil)
        #expect(EditorialImageSupplier.canonicalJSONString(for: []) == nil)
    }

    @Test("SwiftMediaMetadata writes PLUS Image Supplier as a sequence")
    func sequenceFormAndPlusPreservation() {
        var xmp = XMPData()
        xmp.setValue(
            .simple("license-42"),
            namespace: XMPNamespace.plus,
            property: "LicenseTransactionID"
        )
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.plus + "ImageSupplierID": .simple("agency-1"),
                XMPNamespace.plus + "ImageSupplierName": .simple("Agency One"),
            ]]),
            namespace: XMPNamespace.plus,
            property: "ImageSupplier"
        )

        let xml = XMPWriter.generateXML(xmp)
        #expect(xml.contains("<plus:ImageSupplier>"))
        #expect(xml.contains("<rdf:Seq>"))
        #expect(!xml.contains("<plus:ImageSupplier>\n   <rdf:Bag>"))
        #expect(xmp.simpleValue(
            namespace: XMPNamespace.plus,
            property: "LicenseTransactionID"
        ) == "license-42")
    }

    @Test("PLUS values win over legacy IPTC Extension fallbacks on read")
    func plusFirstReadMigration() {
        var xmp = XMPData()
        xmp.setValue(
            .simple("legacy-image-id"),
            namespace: XMPNamespace.iptcExt,
            property: "ImageSupplierImageID"
        )
        xmp.setValue(
            .simple("plus-image-id"),
            namespace: XMPNamespace.plus,
            property: "ImageSupplierImageID"
        )
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.iptcExt + "ImageSupplierID": .simple("legacy-agency"),
                XMPNamespace.iptcExt + "ImageSupplierName": .simple("Legacy Agency"),
            ]]),
            namespace: XMPNamespace.iptcExt,
            property: "ImageSupplier"
        )
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.plus + "ImageSupplierID": .simple("plus-agency"),
                XMPNamespace.plus + "ImageSupplierName": .simple("PLUS Agency"),
            ]]),
            namespace: XMPNamespace.plus,
            property: "ImageSupplier"
        )

        let metadata = iptcMetadataFromDict(ImageMetadata(xmp: xmp).asMetadataDict())
        #expect(metadata.imageSupplierImageID == "plus-image-id")
        #expect(metadata.imageSuppliers == [
            EditorialImageSupplier(identifier: "plus-agency", name: "PLUS Agency"),
        ])
    }

    @Test("legacy IPTC Extension supplier structures migrate to canonical PLUS Seq")
    func legacyFallbackCanonicalWrite() throws {
        let foreignNamespace = "https://example.test/newsroom/1.0/"
        var xmp = XMPData()
        xmp.setValue(
            .simple("legacy-image-id"),
            namespace: XMPNamespace.iptcExt,
            property: "ImageSupplierImageID"
        )
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.iptcExt + "ImageSupplierID": .simple("legacy-agency"),
                XMPNamespace.iptcExt + "ImageSupplierName": .simple("Legacy Agency"),
                foreignNamespace + "RoutingCode": .simple("desk-42"),
            ]]),
            namespace: XMPNamespace.iptcExt,
            property: "ImageSupplier"
        )

        let loaded = iptcMetadataFromDict(ImageMetadata(xmp: xmp).asMetadataDict())
        #expect(loaded.imageSupplierImageID == "legacy-image-id")
        #expect(loaded.imageSuppliers == [
            EditorialImageSupplier(identifier: "legacy-agency", name: "Legacy Agency"),
        ])

        XMPDataBuilder.applyDescriptive(loaded, into: &xmp)
        #expect(xmp.simpleValue(
            namespace: XMPNamespace.plus,
            property: "ImageSupplierImageID"
        ) == "legacy-image-id")
        #expect(xmp.value(forKey: XMPNamespace.iptcExt + "ImageSupplierImageID") == nil)
        #expect(xmp.value(forKey: XMPNamespace.iptcExt + "ImageSupplier") == nil)

        let canonical = try #require(xmp.structuredArrayValue(
            namespace: XMPNamespace.plus,
            property: "ImageSupplier"
        )?.first)
        #expect(canonical[XMPNamespace.plus + "ImageSupplierID"] == .simple("legacy-agency"))
        #expect(canonical[XMPNamespace.plus + "ImageSupplierName"] == .simple("Legacy Agency"))
        #expect(canonical[foreignNamespace + "RoutingCode"] == .simple("desk-42"))

        let xml = XMPWriter.generateXML(xmp)
        #expect(xml.contains("<plus:ImageSupplier>"))
        #expect(xml.contains("<rdf:Seq>"))
    }
}
