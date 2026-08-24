import Foundation

/// Parsed PDF metadata container.
/// Only stores the metadata-relevant parts of the PDF structure.
public struct PDFFile: Sendable, Equatable {
    /// PDF version string (e.g. "1.7").
    public var headerVersion: String
    /// The raw PDF file data (preserved for incremental update writes).
    public var rawData: Data
    /// Parsed Info dictionary fields (Title, Author, Subject, etc.).
    public var infoDict: [String: String]
    /// Raw XMP metadata stream bytes (if present).
    public var xmpStreamData: Data?

    // Internal state for write-back
    var infoObjectNumber: Int?
    var infoGenerationNumber: Int
    var xmpObjectNumber: Int?
    var xmpGenerationNumber: Int
    var lastXRefOffset: Int
    var nextObjectNumber: Int

    public init(
        headerVersion: String = "1.4",
        rawData: Data = Data(),
        infoDict: [String: String] = [:],
        xmpStreamData: Data? = nil,
        infoObjectNumber: Int? = nil,
        infoGenerationNumber: Int = 0,
        xmpObjectNumber: Int? = nil,
        xmpGenerationNumber: Int = 0,
        lastXRefOffset: Int = 0,
        nextObjectNumber: Int = 1
    ) {
        self.headerVersion = headerVersion
        self.rawData = rawData
        self.infoDict = infoDict
        self.xmpStreamData = xmpStreamData
        self.infoObjectNumber = infoObjectNumber
        self.infoGenerationNumber = infoGenerationNumber
        self.xmpObjectNumber = xmpObjectNumber
        self.xmpGenerationNumber = xmpGenerationNumber
        self.lastXRefOffset = lastXRefOffset
        self.nextObjectNumber = nextObjectNumber
    }
}
