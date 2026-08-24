import Foundation

/// Parsed representation of an SVG file for metadata extraction/writing.
public struct SVGFile: Sendable {
    /// The full SVG content as a string.
    public var content: String
    /// Image width from the SVG root element (if specified).
    public var width: String?
    /// Image height from the SVG root element (if specified).
    public var height: String?
    /// The viewBox attribute (if specified).
    public var viewBox: String?

    public init(content: String = "", width: String? = nil, height: String? = nil, viewBox: String? = nil) {
        self.content = content
        self.width = width
        self.height = height
        self.viewBox = viewBox
    }
}
