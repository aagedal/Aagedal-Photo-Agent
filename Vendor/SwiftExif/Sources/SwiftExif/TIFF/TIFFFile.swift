import Foundation

/// Parsed representation of a TIFF file (also used for TIFF-based RAW formats).
public struct TIFFFile: Sendable {
    /// Full raw file data (needed for offset-based value lookup).
    public let rawData: Data
    /// TIFF header (byte order, magic 42, first IFD offset).
    public let header: TIFFHeader
    /// All IFDs in the chain (IFD0, IFD1, ...).
    public var ifds: [IFD]

    public init(rawData: Data, header: TIFFHeader, ifds: [IFD] = []) {
        self.rawData = rawData
        self.header = header
        self.ifds = ifds
    }

    /// The first IFD (IFD0), containing main image metadata.
    public var ifd0: IFD? { ifds.first }
}
