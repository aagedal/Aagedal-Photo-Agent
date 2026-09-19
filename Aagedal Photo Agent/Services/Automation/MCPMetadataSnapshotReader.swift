import Foundation
import ImageIO
import SwiftMediaMetadata

/// Production typed parsing of captured bytes. This app-side adapter never reopens a
/// carrier, and its result describes the captured revisions, not current write authority.
nonisolated enum MCPMetadataSnapshotReader {
    struct Result: Sendable {
        let target: MCPAuthorizedTarget
        let resolution: EffectiveMetadataResolver.Resolution
        let sourceRevision: String
        let xmpSidecarRevision: String
        let appSidecarRevision: String

        /// A bounded historical read, not publication authorization or a mutation plan.
        /// Nulls make absent scalar values explicit; ordered arrays and explicit clears
        /// retain the production model's semantics. Never truncate a metadata record.
        func protocolValue() throws -> MCPJSONValue {
            let encoded = try JSONEncoder().encode(resolution.metadata)
            guard let metadata = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  var fields = MCPEditorialFieldCatalog.read(from: ["metadata": metadata]) else {
                throw ReadError.outputLimitExceeded
            }
            for key in MCPEditorialFieldCatalog.fieldKeys where fields[key] == nil {
                fields[key] = .null
            }
            guard Set(resolution.fieldCarriers.keys) == MCPEditorialFieldCatalog.fieldKeys else {
                throw ReadError.incompleteProvenance
            }
            let value = MCPJSONValue.object([
                "schemaVersion": .integer(1),
                "canonicalPath": .string(target.url.path),
                "rootID": .string(target.rootID.uuidString.lowercased()),
                "sourceRevision": .string(sourceRevision),
                "xmpSidecarRevision": .string(xmpSidecarRevision),
                "appSidecarRevision": .string(appSidecarRevision),
                "fields": .object(fields),
                "fieldScope": .string("effective-editorial-metadata"),
                "effectiveIPTCResolved": .bool(true),
                // Selection provenance includes absent values and explicit clears. It does
                // not claim authorship, authenticity, or that a field was physically present.
                "fieldCarriers": .object(resolution.fieldCarriers.mapValues { .string($0.rawValue) }),
                "descriptiveRecordCarrier": .string(resolution.descriptiveCarrier.rawValue),
                "hasPendingChanges": .bool(resolution.hasPendingChanges),
                "hasXMPConflict": .bool(resolution.hasXMPConflict),
            ])
            guard try JSONEncoder().encode(value).count <= MCPServerConstants.maximumToolResultBytes else {
                throw ReadError.outputLimitExceeded
            }
            return value
        }
    }

    enum ReadError: Error {
        case invalidAppSidecar
        case outputLimitExceeded
        case incompleteProvenance
    }

    /// The production read boundary: serialization completes before the facade revalidates
    /// the retained carriers and authority. The returned revisions are not write permission.
    static func inspectPhoto(path: String, facade: MCPAutomationFacade) throws -> MCPJSONValue {
        try facade.withPhotoSnapshot(path: path) { snapshot in
            try read(snapshot).protocolValue()
        }
    }

    static func read(_ snapshot: MCPPhotoCarrierSnapshot) throws -> Result {
        // Match the production URL reader's TIFF/RAW disambiguation without a URL read.
        let extensionHint = FormatDetector.detectFromExtension(snapshot.target.url.pathExtension)
        var format = FormatDetector.detect(snapshot.sourceBytes) ?? extensionHint
        if format == .tiff,
           ["raw", "cr2", "nef", "nrw", "arw", "dng", "orf", "pef", "srw"].contains(
               snapshot.target.url.pathExtension.lowercased()) {
            format = extensionHint
        }
        guard let format else { throw MetadataError.unsupportedFormat }
        let source = try ImageMetadata.read(from: snapshot.sourceBytes, format: format)
        var dictionary = source.asMetadataDict()
        // Use the same header fallback as interactive reads, from captured bytes only.
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let image = CGImageSourceCreateWithData(snapshot.sourceBytes as CFData, options)
        let properties = image.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, options) as? [CFString: Any]
        }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        let aspect: Double?
        if let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 {
            aspect = width / height
            if dictionary[MetadataDictKey.imageWidth] == nil || dictionary[MetadataDictKey.imageHeight] == nil {
                dictionary[MetadataDictKey.imageWidth] = width
                dictionary[MetadataDictKey.imageHeight] = height
            }
        } else {
            aspect = nil
        }
        let embedded = iptcMetadataFromDict(dictionary)
        let xmp = try snapshot.xmpBytes.map { bytes in
            guard validXMPDocument(bytes) else {
                throw EffectiveMetadataResolver.ReadError.incompleteXMP
            }
            guard let parsed = XMPMetadataReader.read(bytes, imageAspect: { aspect }) else {
                throw EffectiveMetadataResolver.ReadError.incompleteXMP
            }
            return parsed
        }
        let app = try snapshot.appSidecarBytes.map { bytes in
            // Unknown pending state must not silently become a saved record.
            struct Header: Decodable {
                let schemaVersion: Int?
                let version: Int?
                let pendingChanges: Bool
                let metadata: [String: MCPJSONValue]
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(Header.self, from: bytes)
            guard (header.schemaVersion ?? header.version) == MetadataSidecar.currentSchemaVersion else {
                throw ReadError.invalidAppSidecar
            }
            let record = try decoder.decode(MetadataSidecar.self, from: bytes)
            guard record.sourceFile == snapshot.target.url.lastPathComponent else {
                throw ReadError.invalidAppSidecar
            }
            return record
        }
        let verdict = xmp.map {
            SidecarReconciliation.verdict(imageModificationDate: snapshot.sourceModificationDate,
                sidecarModificationDate: snapshot.xmpModificationDate, embedded: embedded, sidecar: $0)
        }
        let facts = MetadataEditorSourceFacts(imageURL: snapshot.target.url, xmpMetadata: xmp,
            appSidecar: app, reconciliationVerdict: verdict)
        return Result(target: snapshot.target, resolution: try EffectiveMetadataResolver.resolve(embedded: embedded, facts: facts,
            isRaw: MCPPhotoFormatCatalog.rawExtensions.contains(snapshot.target.url.pathExtension.lowercased())),
            sourceRevision: snapshot.sourceRevision, xmpSidecarRevision: snapshot.xmpSidecarRevision,
            appSidecarRevision: snapshot.appSidecarRevision)
    }

    /// The production XMP tokenizer tolerates empty/truncated XML. Effective automation
    /// reads require a complete RDF document before treating any values as authoritative.
    private static func validXMPDocument(_ bytes: Data) -> Bool {
        guard var xml = String(data: bytes, encoding: .utf8), !xml.contains("<!DOCTYPE") else { return false }
        // Match the production reader's support for packet padding and trailing NULs.
        if let end = xml.range(of: "<?xpacket end="),
           let close = xml.range(of: "?>", range: end.upperBound..<xml.endIndex) {
            xml = String(xml[..<close.upperBound])
        } else {
            while xml.last == "\0" { xml.removeLast() }
        }
        let parser = XMLParser(data: Data(xml.utf8))
        let validation = XMPDocumentValidation()
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = validation
        return parser.parse() && validation.hasRDF
    }

    private final class XMPDocumentValidation: NSObject, XMLParserDelegate {
        var hasRDF = false
        var depth = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            depth += 1
            if depth > 64 { parser.abortParsing() }
            if elementName == "RDF", namespaceURI == "http://www.w3.org/1999/02/22-rdf-syntax-ns#" {
                hasRDF = true
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    }
}
