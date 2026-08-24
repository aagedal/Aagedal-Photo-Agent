import Foundation

/// Parse JPEG XL files for metadata.
public struct JXLParser: Sendable {

    /// JPEG XL container signature: the first 12 bytes of a JXL container file.
    /// This is actually the JXL file type box: size=12, type="JXL ".
    static let containerSignature: [UInt8] = [
        0x00, 0x00, 0x00, 0x0C,  // box size = 12
        0x4A, 0x58, 0x4C, 0x20,  // "JXL "
        0x0D, 0x0A, 0x87, 0x0A,  // line feed magic
    ]

    /// Bare codestream signature.
    static let codestreamSignature: [UInt8] = [0xFF, 0x0A]

    /// Parse a JPEG XL file from raw data.
    public static func parse(_ data: Data) throws -> JXLFile {
        guard data.count >= 2 else {
            throw MetadataError.invalidJPEGXL("File too small")
        }

        let bytes = [UInt8](data.prefix(12))

        // Check for container format
        if data.count >= 12 && bytes.elementsEqual(containerSignature) {
            return try parseContainer(data)
        }

        // Check for bare codestream
        if bytes[0] == codestreamSignature[0] && bytes[1] == codestreamSignature[1] {
            // Codestream bytes after the 2-byte signature.
            let csTail = data.suffix(from: data.startIndex + 2)
            let dims = decodeSizeHeader(csTail)
            // Retain the full codestream (including the FF 0A signature) so the
            // writer can losslessly wrap it into container format if metadata
            // boxes need to be added. Copy to drop any slice base-offset.
            return JXLFile(isContainer: false, imageDimensions: dims,
                           rawCodestream: Data(data))
        }

        throw MetadataError.invalidJPEGXL("Not a valid JPEG XL file")
    }

    /// Extract Exif data from a JPEG XL Exif box.
    public static func extractExif(from exifBox: ISOBMFFBox) throws -> ExifData? {
        try ExifReader.readFromExifBox(data: exifBox.data)
    }

    // MARK: - Private

    private static func parseContainer(_ data: Data) throws -> JXLFile {
        // Skip the 12-byte file type box
        let boxData = Data(data.suffix(from: data.startIndex + 12))
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: boxData)
        let dims = locateAndDecodeCodestream(in: boxes)
        return JXLFile(isContainer: true, boxes: boxes, imageDimensions: dims)
    }

    /// Find the codestream within a container's boxes and decode its
    /// SizeHeader. Tries `jxlc` (full codestream) first, then the first
    /// `jxlp` (partial codestream, prefixed by a 4-byte index field).
    private static func locateAndDecodeCodestream(in boxes: [ISOBMFFBox]) -> (width: Int, height: Int)? {
        if let jxlc = boxes.first(where: { $0.type == "jxlc" }) {
            return codestreamSizeHeader(from: jxlc.data)
        }
        if let jxlp = boxes.first(where: { $0.type == "jxlp" }) {
            // jxlp payload: 4-byte tcons_index then codestream chunk.
            guard jxlp.data.count > 4 else { return nil }
            let chunk = jxlp.data.suffix(from: jxlp.data.startIndex + 4)
            return codestreamSizeHeader(from: chunk)
        }
        return nil
    }

    /// Decode the SizeHeader from a JXL codestream that still has the
    /// `FF 0A` signature in front. Validates the signature, then hands
    /// the trailing bytes to `decodeSizeHeader`.
    private static func codestreamSizeHeader(from data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        guard bytes[0] == codestreamSignature[0],
              bytes[1] == codestreamSignature[1] else { return nil }
        return decodeSizeHeader(data.suffix(from: data.startIndex + 2))
    }

    /// Decode the JXL SizeHeader from the bytes immediately following the
    /// `FF 0A` codestream signature. Bits are read LSB-first within each
    /// byte; multi-bit integers are accumulated LSB-first (the first bit
    /// read becomes the result's lowest bit).
    ///
    /// Spec layout:
    ///   1 bit:   small_picture
    ///   if small_picture:
    ///     5 bits: div8_y; ysize = (div8_y + 1) * 8
    ///   else:
    ///     2 bits: y_selector ∈ {0,1,2,3} → field width {9,13,18,30}
    ///     N bits: ysize_minus_1; ysize = ysize_minus_1 + 1
    ///   3 bits:  ratio
    ///   if ratio == 0:  xsize encoded the same way as ysize
    ///   else:           xsize = ysize * num/den from the ratio table
    static func decodeSizeHeader(_ data: Data) -> (width: Int, height: Int)? {
        var reader = JXLBitReader(data: data)
        guard let smallPicture = reader.readBit() else { return nil }

        let ysize: Int
        if smallPicture == 1 {
            guard let div8 = reader.read(bits: 5) else { return nil }
            ysize = (div8 + 1) * 8
        } else {
            guard let sel = reader.read(bits: 2) else { return nil }
            let widths = [9, 13, 18, 30]
            guard let v = reader.read(bits: widths[sel]) else { return nil }
            ysize = v + 1
        }

        guard let ratio = reader.read(bits: 3) else { return nil }
        let xsize: Int
        if ratio == 0 {
            if smallPicture == 1 {
                guard let div8 = reader.read(bits: 5) else { return nil }
                xsize = (div8 + 1) * 8
            } else {
                guard let sel = reader.read(bits: 2) else { return nil }
                let widths = [9, 13, 18, 30]
                guard let v = reader.read(bits: widths[sel]) else { return nil }
                xsize = v + 1
            }
        } else {
            // Aspect ratio table per JXL spec §C.2 (xsize = ysize * num / den).
            let nums = [0, 1, 12, 4, 3, 16,  5, 2]
            let dens = [0, 1, 10, 3, 2,  9,  4, 1]
            guard ratio < nums.count else { return nil }
            xsize = (ysize * nums[ratio]) / dens[ratio]
        }
        return (width: xsize, height: ysize)
    }
}

/// LSB-first bit reader over a `Data` buffer. Returns nil when the buffer
/// is exhausted. Used to decode JXL bit-stream headers.
private struct JXLBitReader {
    let data: Data
    var byteIndex: Int = 0
    var bitIndex: Int = 0  // 0..7 within the current byte

    init(data: Data) { self.data = data }

    mutating func readBit() -> Int? {
        guard byteIndex < data.count else { return nil }
        let byte = data[data.startIndex + byteIndex]
        let bit = Int((byte >> bitIndex) & 1)
        bitIndex += 1
        if bitIndex == 8 { bitIndex = 0; byteIndex += 1 }
        return bit
    }

    mutating func read(bits n: Int) -> Int? {
        var value = 0
        for i in 0..<n {
            guard let b = readBit() else { return nil }
            value |= (b << i)
        }
        return value
    }
}
