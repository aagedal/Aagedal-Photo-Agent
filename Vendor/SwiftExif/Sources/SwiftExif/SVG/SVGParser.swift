import Foundation

/// Parse SVG files for metadata extraction.
public struct SVGParser: Sendable {

    /// Parse an SVG file from raw data.
    public static func parse(_ data: Data) throws -> SVGFile {
        guard let content = String(data: data, encoding: .utf8) else {
            throw MetadataError.invalidSVG("Cannot decode SVG as UTF-8")
        }

        // Basic validation: must contain <svg
        guard content.range(of: "<svg", options: .caseInsensitive) != nil else {
            throw MetadataError.invalidSVG("Not a valid SVG file (missing <svg element)")
        }

        // Extract width, height, viewBox from <svg> element
        let width = extractAttribute(from: content, element: "svg", attribute: "width")
        let height = extractAttribute(from: content, element: "svg", attribute: "height")
        let viewBox = extractAttribute(from: content, element: "svg", attribute: "viewBox")

        return SVGFile(content: content, width: width, height: height, viewBox: viewBox)
    }

    /// Extract XMP metadata from the SVG's <metadata> element.
    public static func extractXMP(from svg: SVGFile) throws -> XMPData? {
        let content = svg.content

        // Find <metadata>...</metadata> block
        guard let metaStart = content.range(of: "<metadata", options: .caseInsensitive),
              let metaEnd = content.range(of: "</metadata>", options: .caseInsensitive) else {
            return nil
        }

        // Get content between metadata tags
        let afterOpen = content[metaStart.lowerBound...]
        guard let openEnd = afterOpen.range(of: ">") else { return nil }
        let metadataContent = String(content[openEnd.upperBound..<metaEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !metadataContent.isEmpty else { return nil }

        // Try to find RDF/XMP content within the metadata block
        // It may be wrapped in <x:xmpmeta> or be raw <rdf:RDF>
        let xmpContent: String
        if let rdfStart = metadataContent.range(of: "<rdf:RDF", options: .caseInsensitive),
           let rdfEnd = metadataContent.range(of: "</rdf:RDF>", options: .caseInsensitive) {
            xmpContent = String(metadataContent[rdfStart.lowerBound...rdfEnd.upperBound])
        } else if metadataContent.contains("x:xmpmeta") || metadataContent.contains("xmpmeta") {
            xmpContent = metadataContent
        } else {
            return nil
        }

        guard let xmlData = xmpContent.data(using: .utf8) else { return nil }
        return try XMPReader.readFromXML(xmlData)
    }

    // MARK: - Attribute Extraction

    /// Extract an attribute value from the first occurrence of an element.
    /// Uses simple string matching (not full XML parsing) for lightweight extraction.
    private static func extractAttribute(from content: String, element: String, attribute: String) -> String? {
        // Find the opening tag
        guard let tagStart = content.range(of: "<\(element)", options: .caseInsensitive) else { return nil }

        // Find the end of the opening tag
        let searchRange = tagStart.lowerBound..<content.endIndex
        guard let tagEnd = content.range(of: ">", range: searchRange) else { return nil }

        let tagContent = String(content[tagStart.lowerBound..<tagEnd.upperBound])

        // Find attribute="value" or attribute='value'
        let patterns = [
            "\(attribute)=\"",
            "\(attribute)='",
            "\(attribute) =\"",
            "\(attribute) ='",
        ]

        for pattern in patterns {
            if let attrStart = tagContent.range(of: pattern, options: .caseInsensitive) {
                let quote = pattern.last! // " or '
                let valueStart = attrStart.upperBound
                let remaining = tagContent[valueStart...]
                if let valueEnd = remaining.firstIndex(of: quote) {
                    return String(remaining[remaining.startIndex..<valueEnd])
                }
            }
        }

        return nil
    }
}
