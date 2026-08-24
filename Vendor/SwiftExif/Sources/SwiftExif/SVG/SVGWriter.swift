import Foundation

/// Write XMP metadata into SVG files.
public struct SVGWriter: Sendable {

    /// Write updated XMP metadata into an SVG file.
    /// Replaces existing <metadata> block or inserts one after <svg ...>.
    public static func write(_ svg: SVGFile, xmp: XMPData?) -> Data {
        var content = svg.content

        if let xmp = xmp {
            let xmpXML = XMPWriter.generateXML(xmp)
            let metadataBlock = "<metadata>\n\(xmpXML)\n</metadata>"

            if let metaStart = content.range(of: "<metadata", options: .caseInsensitive),
               let metaEnd = content.range(of: "</metadata>", options: .caseInsensitive) {
                // Replace existing metadata block
                content.replaceSubrange(metaStart.lowerBound..<metaEnd.upperBound, with: metadataBlock)
            } else {
                // Insert after the opening <svg ...> tag
                if let svgStart = content.range(of: "<svg", options: .caseInsensitive) {
                    let searchRange = svgStart.lowerBound..<content.endIndex
                    if let tagEnd = content.range(of: ">", range: searchRange) {
                        let insertPoint = tagEnd.upperBound
                        content.insert(contentsOf: "\n\(metadataBlock)\n", at: insertPoint)
                    }
                }
            }
        } else {
            // Remove existing metadata block if xmp is nil
            if let metaStart = content.range(of: "<metadata", options: .caseInsensitive),
               let metaEnd = content.range(of: "</metadata>", options: .caseInsensitive) {
                content.replaceSubrange(metaStart.lowerBound..<metaEnd.upperBound, with: "")
            }
        }

        return Data(content.utf8)
    }
}
