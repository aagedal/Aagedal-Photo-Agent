import Foundation

/// Unified metadata access for an image file.
public struct ImageMetadata: Sendable {
    public var container: ImageContainer
    public var format: ImageFormat
    public var iptc: IPTCData
    public var exif: ExifData?
    public var xmp: XMPData?
    public var c2pa: C2PAData?
    public var iccProfile: ICCProfile?
    /// JPEG Multi-Picture Format (CIPA DC-007) index. Present when an APP2
    /// segment carries the MPF block — typical for Apple Live Photo aux
    /// images, Sony multi-shot bursts, and stereo / 3D JPEG pairs.
    public var mpf: MPFData?
    /// Adobe DNG private tags (color matrices, default crop, opcode lists,
    /// noise profile). Populated only for files marked with DNGVersion (0xC612).
    public var dng: DNGMetadata?

    /// HDR static metadata for HDR HEIC / AVIF stills (mastering display
    /// colour volume + content light level), shared with `VideoStream.hdr`
    /// so HDR consumers see one shape across video and still containers.
    /// Populated from `mdcv` / `clli` properties under the HEIF / AVIF
    /// `meta → iprp → ipco` hierarchy.
    public var hdr: HDRMetadata?

    /// Non-fatal issues encountered during parsing (e.g. corrupted C2PA data).
    public var warnings: [String]

    public init(container: ImageContainer = .jpeg(JPEGFile()), format: ImageFormat = .jpeg, iptc: IPTCData = IPTCData(), exif: ExifData? = nil, xmp: XMPData? = nil, c2pa: C2PAData? = nil, iccProfile: ICCProfile? = nil, mpf: MPFData? = nil, dng: DNGMetadata? = nil, hdr: HDRMetadata? = nil, warnings: [String] = []) {
        self.container = container
        self.format = format
        self.iptc = iptc
        self.exif = exif
        self.xmp = xmp
        self.c2pa = c2pa
        self.iccProfile = iccProfile
        self.mpf = mpf
        self.dng = dng
        self.hdr = hdr
        self.warnings = warnings
    }

    // MARK: - Reading

    /// Read all metadata from an image file at the given URL.
    public static func read(from url: URL) throws -> ImageMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url.path)
        }
        // Use `.alwaysMapped` rather than `.mappedIfSafe` — the latter declines
        // to map external volumes and silently loads the whole file into RAM,
        // which is wasteful for large raws/HEIFs where metadata lives in the
        // first few KB. (Same rationale as VideoMetadata.readMappedData.)
        let data = try Data(contentsOf: url, options: .alwaysMapped)

        // Try magic-byte detection first, fall back to extension
        var format = FormatDetector.detect(data)
            ?? FormatDetector.detectFromExtension(url.pathExtension)

        // GPR is DNG-structured, so content detection may report generic DNG. The
        // .gpr extension disambiguates it (content detection already upgrades files
        // with a GoPro Make on its own).
        if format == .raw(.dng), url.pathExtension.lowercased() == "gpr" {
            format = .raw(.gpr)
        }

        guard let format else {
            throw MetadataError.unsupportedFormat
        }

        return try read(from: data, format: format)
    }

    /// Read all metadata from image data in memory.
    /// Automatically detects the format from magic bytes.
    public static func read(from data: Data) throws -> ImageMetadata {
        guard let format = FormatDetector.detect(data) else {
            throw MetadataError.unsupportedFormat
        }
        return try read(from: data, format: format)
    }

    /// Read metadata from image data with a known format.
    public static func read(from data: Data, format: ImageFormat) throws -> ImageMetadata {
        switch format {
        case .jpeg:
            return try readJPEG(from: data)
        case .raw(.cr3):
            return try readCR3(from: data)
        case .raw(.raf), .raw(.rw2), .raw(.iiq), .raw(.x3f), .raw(.mrw):
            return try readRAW(from: data, format: format)
        case .tiff, .raw:
            return try readTIFF(from: data, format: format)
        case .jpegXL:
            return try readJPEGXL(from: data)
        case .png:
            return try readPNG(from: data)
        case .avif:
            return try readAVIF(from: data)
        case .heif:
            return try readHEIF(from: data)
        case .webp:
            return try readWebP(from: data)
        case .pdf:
            return try readPDF(from: data)
        case .psd:
            return try readPSD(from: data)
        case .gif:
            return try readGIF(from: data)
        case .bmp:
            return try readBMP(from: data)
        case .svg:
            return try readSVG(from: data)
        }
    }

    // MARK: - Write Options

    /// Options controlling how metadata is written to disk.
    public struct WriteOptions: Sendable {
        /// Write to a temporary file then atomically rename (prevents corruption on crash).
        /// Default: true.
        public var atomic: Bool

        /// Create a backup of the original file before overwriting (e.g. "photo.jpg_original").
        /// Default: false.
        public var createBackup: Bool

        /// Suffix appended to the original filename for the backup (e.g. "_original").
        /// Default: "_original".
        public var backupSuffix: String

        /// Allow embedding metadata into a proprietary TIFF-based RAW container
        /// (Sony ARW, Nikon NEF, Canon CR2, Panasonic RW2, Olympus ORF, …).
        /// Default: false. These formats are rewritten by `TIFFWriter`, which cannot
        /// preserve maker-private structures such as Sony's encrypted SR2Private
        /// white-balance block — so the write corrupts the file (broken decode + bloat).
        /// RAW metadata belongs in an XMP sidecar. DNG/GPR (Adobe's open, writable TIFF
        /// spec) and CR3 (ISOBMFF, dedicated writer) are not affected by this guard.
        /// Only enable if you have verified the specific format round-trips losslessly.
        public var allowUnsafeRawEmbed: Bool

        public init(atomic: Bool = true, createBackup: Bool = false, backupSuffix: String = "_original", allowUnsafeRawEmbed: Bool = false) {
            self.atomic = atomic
            self.createBackup = createBackup
            self.backupSuffix = backupSuffix
            self.allowUnsafeRawEmbed = allowUnsafeRawEmbed
        }

        /// Default options: atomic write, no backup.
        public static let `default` = WriteOptions()

        /// Safe options: atomic write with backup file creation.
        public static let safe = WriteOptions(atomic: true, createBackup: true)
    }

    // MARK: - Writing

    /// Write all metadata back to a new Data blob (preserving image data).
    public func writeToData() throws -> Data {
        var warnings: [String] = []
        return try writeToData(collectingWarnings: &warnings)
    }

    /// Write all metadata back to a new Data blob and return any non-fatal write
    /// warnings. Currently this surfaces a relocated TIFF/DNG MakerNote whose
    /// manufacturer-specific internal offsets may not resolve (see `TIFFWriter`).
    public func writeToDataWithWarnings() throws -> (data: Data, warnings: [String]) {
        var warnings: [String] = []
        let data = try writeToData(collectingWarnings: &warnings)
        return (data, warnings)
    }

    private func writeToData(collectingWarnings warnings: inout [String]) throws -> Data {
        switch container {
        case .jpeg(var file):
            return try writeJPEG(&file, warnings: &warnings)
        case .png(var file):
            return writePNG(&file, warnings: &warnings)
        case .tiff(let file):
            return try writeTIFFFile(file, warnings: &warnings)
        case .jpegXL(var file):
            return try writeJXL(&file, warnings: &warnings)
        case .avif(let file):
            return try writeAVIF(file)
        case .heif(let file):
            return try writeHEIF(file)
        case .webp(let file):
            return try writeWebP(file)
        case .cr3(let file):
            return try writeCR3(file)
        case .pdf(let file):
            return try writePDF(file)
        case .psd(let file):
            return try writePSD(file)
        case .gif(let file):
            return writeGIF(file)
        case .bmp(let file):
            return writeBMP(file)
        case .svg(let file):
            return writeSVG(file)
        }
    }

    /// Write metadata to a file URL with default options (atomic, no backup).
    /// - Returns: non-fatal write warnings (see `writeToDataWithWarnings()`).
    @discardableResult
    public func write(to url: URL) throws -> [String] {
        try write(to: url, options: .default)
    }

    /// Write metadata to a file URL with the given options.
    /// - Returns: non-fatal write warnings (see `writeToDataWithWarnings()`).
    @discardableResult
    public func write(to url: URL, options: WriteOptions) throws -> [String] {
        // Refuse to overwrite a proprietary TIFF-based RAW: TIFFWriter's full IFD
        // rebuild can't preserve maker-private blocks (e.g. Sony's encrypted
        // SR2Private), so the rewrite corrupts the file. RAW metadata belongs in an
        // XMP sidecar. Callers that have verified a format opt in via WriteOptions.
        if !options.allowUnsafeRawEmbed, let rawFormat = unsafeRawWriteFormat(url: url) {
            throw MetadataError.rawWriteUnsupported(rawFormat)
        }
        let (data, warnings) = try writeToDataWithWarnings()
        let fm = FileManager.default

        // Create backup if requested and original file exists
        if options.createBackup && fm.fileExists(atPath: url.path) {
            let backupURL = Self.backupURL(for: url, suffix: options.backupSuffix)
            // Remove existing backup to allow overwrite
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }

        if options.atomic {
            do {
                try AtomicFileWriter.replaceContents(of: url, with: data)
            } catch {
                throw MetadataError.fileWriteError("Atomic write failed: \(error.localizedDescription)")
            }
        } else {
            try data.write(to: url)
        }
        return warnings
    }

    /// Returns the proprietary RAW format when writing back to `url` would rewrite a
    /// TIFF-based RAW that cannot safely round-trip its maker-private data — otherwise nil.
    ///
    /// Only the `.tiff` container path goes through `TIFFWriter`'s full IFD rebuild (the
    /// step that breaks Sony's encrypted SR2Private and bloats the raster). The precise
    /// format is recovered from the parsed bytes — an ARW/NEF/CR2/RW2/ORF/PEF/SRW reports
    /// as a TIFF container — falling back to the extension if content detection is
    /// inconclusive. DNG/GPR are Adobe's open, writable TIFF spec and are allowed; CR3
    /// (ISOBMFF, its own writer) never reaches this path.
    private func unsafeRawWriteFormat(url: URL) -> ImageFormat.RawFormat? {
        guard case .tiff(let file) = container else { return nil }
        // Refuse if EITHER the parsed content OR the target extension says proprietary RAW.
        // A real ARW/NEF detects by content; the extension is a backstop for odd/truncated
        // variants where content detection falls back to plain TIFF. DNG/GPR (open, writable)
        // are never refused.
        for case .raw(let raw)? in [FormatDetector.detect(file.rawData),
                                    FormatDetector.detectFromExtension(url.pathExtension)] {
            switch raw {
            case .dng, .gpr: continue
            default: return raw
            }
        }
        return nil
    }

    /// Get the backup URL for a given file URL.
    public static func backupURL(for url: URL, suffix: String = "_original") -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        if ext.isEmpty {
            return base.appendingPathExtension(suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        // "photo.jpg" → "photo.jpg_original"
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix)
    }

    // MARK: - Stripping

    /// Remove all metadata (Exif, IPTC, XMP, C2PA, ICC profile).
    public mutating func stripAllMetadata() {
        exif = nil
        iptc = IPTCData()
        xmp = nil
        c2pa = nil
        iccProfile = nil
    }

    /// Remove all Exif data.
    public mutating func stripExif() {
        exif = nil
    }

    /// Remove all IPTC data.
    public mutating func stripIPTC() {
        iptc = IPTCData()
    }

    /// Remove all XMP data.
    public mutating func stripXMP() {
        xmp = nil
    }

    /// Remove GPS data from Exif and XMP.
    public mutating func stripGPS() {
        exif?.gpsIFD = nil
        xmp?.removeValue(namespace: XMPNamespace.iptcCore, property: "Location")
    }

    /// Remove C2PA provenance data.
    public mutating func stripC2PA() {
        c2pa = nil
    }

    /// Remove the embedded ICC color profile.
    public mutating func stripICCProfile() {
        iccProfile = nil
    }

    // MARK: - Individual Tag Deletion

    /// Remove a specific EXIF tag from IFD0.
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeExifTag(_ tag: UInt16) -> Bool {
        guard let ifd = exif?.ifd0, ifd.hasEntry(for: tag) else { return false }
        exif?.ifd0 = ifd.removingEntry(for: tag)
        return true
    }

    /// Remove a specific EXIF tag from the Exif sub-IFD.
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeExifSubIFDTag(_ tag: UInt16) -> Bool {
        guard let ifd = exif?.exifIFD, ifd.hasEntry(for: tag) else { return false }
        exif?.exifIFD = ifd.removingEntry(for: tag)
        return true
    }

    /// Remove a specific GPS tag from the GPS IFD.
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeGPSTag(_ tag: UInt16) -> Bool {
        guard let ifd = exif?.gpsIFD, ifd.hasEntry(for: tag) else { return false }
        exif?.gpsIFD = ifd.removingEntry(for: tag)
        return true
    }

    /// Remove a specific IPTC field.
    /// - Returns: true if the field was found and removed.
    @discardableResult
    public mutating func removeIPTCTag(_ tag: IPTCTag) -> Bool {
        let before = iptc.datasets.count
        iptc.removeAll(for: tag)
        return iptc.datasets.count < before
    }

    /// Remove a specific XMP property.
    /// - Returns: true if the property was found and removed.
    @discardableResult
    public mutating func removeXMPProperty(namespace: String, property: String) -> Bool {
        guard xmp?.value(namespace: namespace, property: property) != nil else { return false }
        xmp?.removeValue(namespace: namespace, property: property)
        return true
    }

    /// Remove a tag by its qualified name (e.g. "EXIF:Make", "IPTC:Headline", "XMP-dc:title").
    /// Supports group prefixes: EXIF:, ExifIFD:, GPS:, IPTC:, XMP-prefix:
    /// - Returns: true if the tag was found and removed.
    @discardableResult
    public mutating func removeTag(_ qualifiedName: String) -> Bool {
        if qualifiedName.hasPrefix("EXIF:") {
            let tagName = String(qualifiedName.dropFirst(5))
            if let tagID = ExifTag.tagID(for: tagName, ifd: .ifd0) {
                return removeExifTag(tagID)
            }
            // Also try exif sub-IFD
            if let tagID = ExifTag.tagID(for: tagName, ifd: .exifIFD) {
                return removeExifSubIFDTag(tagID)
            }
            return false
        }

        if qualifiedName.hasPrefix("ExifIFD:") {
            let tagName = String(qualifiedName.dropFirst(8))
            if let tagID = ExifTag.tagID(for: tagName, ifd: .exifIFD) {
                return removeExifSubIFDTag(tagID)
            }
            return false
        }

        if qualifiedName.hasPrefix("GPS:") {
            let tagName = String(qualifiedName.dropFirst(4))
            if let tagID = ExifTag.tagID(for: tagName, ifd: .gpsIFD) {
                return removeGPSTag(tagID)
            }
            return false
        }

        if qualifiedName.hasPrefix("IPTC:") {
            let tagName = String(qualifiedName.dropFirst(5))
            if let tag = IPTCTag.byName(tagName) {
                return removeIPTCTag(tag)
            }
            return false
        }

        if qualifiedName.hasPrefix("XMP-") {
            // Format: "XMP-prefix:property"
            let rest = qualifiedName.dropFirst(4) // drop "XMP-"
            if let colonIdx = rest.firstIndex(of: ":") {
                let prefix = String(rest[rest.startIndex..<colonIdx])
                let property = String(rest[rest.index(after: colonIdx)...])
                if let namespace = XMPNamespace.namespace(for: prefix) {
                    return removeXMPProperty(namespace: namespace, property: property)
                }
            }
            return false
        }

        return false
    }

    // MARK: - Date Shifting

    /// Shift all date/time fields by the given interval.
    /// Positive values move dates forward, negative values move them backward.
    /// Updates EXIF (DateTime, DateTimeOriginal, DateTimeDigitized),
    /// IPTC (DateCreated/TimeCreated, DigitalCreationDate/Time), and XMP (photoshop:DateCreated).
    public mutating func shiftDates(by interval: TimeInterval) {
        // EXIF dates: "YYYY:MM:DD HH:MM:SS"
        if exif != nil {
            shiftExifDate(tag: ExifTag.dateTime, ifdKeyPath: \.ifd0, interval: interval)
            shiftExifDate(tag: ExifTag.dateTimeOriginal, ifdKeyPath: \.exifIFD, interval: interval)
            shiftExifDate(tag: ExifTag.dateTimeDigitized, ifdKeyPath: \.exifIFD, interval: interval)
        }

        // IPTC dates: "YYYYMMDD" + "HHMMSS±HHMM"
        shiftIPTCDate(dateTag: .dateCreated, timeTag: .timeCreated, interval: interval)
        shiftIPTCDate(dateTag: .digitalCreationDate, timeTag: .digitalCreationTime, interval: interval)

        // XMP: photoshop:DateCreated (ISO 8601 or EXIF format)
        if let dateStr = xmp?.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated"),
           let shifted = Self.shiftDateString(dateStr, by: interval) {
            xmp?.setValue(.simple(shifted), namespace: XMPNamespace.photoshop, property: "DateCreated")
        }
    }

    private mutating func shiftExifDate(tag: UInt16, ifdKeyPath: WritableKeyPath<ExifData, IFD?>, interval: TimeInterval) {
        guard let ifd = exif?[keyPath: ifdKeyPath],
              let entry = ifd.entry(for: tag),
              let dateStr = entry.stringValue(endian: exif!.byteOrder),
              let shifted = Self.shiftExifDateString(dateStr, by: interval) else { return }

        // Build new entry with shifted date
        guard let newData = shifted.data(using: .ascii) else { return }
        var padded = newData
        padded.append(0x00) // null terminator
        let newEntry = IFDEntry(tag: tag, type: .ascii, count: UInt32(padded.count), valueData: padded)

        // Replace the entry in the IFD
        var entries = ifd.entries.filter { $0.tag != tag }
        entries.append(newEntry)
        exif?[keyPath: ifdKeyPath] = IFD(entries: entries, nextIFDOffset: ifd.nextIFDOffset)
    }

    private mutating func shiftIPTCDate(dateTag: IPTCTag, timeTag: IPTCTag, interval: TimeInterval) {
        guard let dateStr = iptc.value(for: dateTag) else { return }
        let timeStr = iptc.value(for: timeTag)

        // Combine into a parseable date, shift, then split back
        let combined = Self.combineIPTCDateTime(date: dateStr, time: timeStr)
        guard let shifted = Self.shiftExifDateString(combined, by: interval) else { return }

        // Split back: first 10 chars "YYYY:MM:DD" → "YYYYMMDD", rest → time
        let parts = shifted.split(separator: " ", maxSplits: 1)
        if let datePart = parts.first {
            let iptcDate = datePart.replacingOccurrences(of: ":", with: "")
            try? iptc.setValue(iptcDate, for: dateTag)
        }
        if parts.count > 1 {
            let timePart = String(parts[1]).replacingOccurrences(of: ":", with: "")
            try? iptc.setValue(timePart, for: timeTag)
        }
    }

    // MARK: - Date Parsing Helpers

    // DateFormatter is not thread-safe — it mutates internal state during both
    // `date(from:)` and `string(from:)`. Build a fresh instance per call so this
    // static API stays safe under concurrent use (TaskGroups, batch operations,
    // library clients running their own concurrency).
    private static func makeExifFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    static func shiftExifDateString(_ dateStr: String, by interval: TimeInterval) -> String? {
        let formatter = makeExifFormatter()
        guard let date = formatter.date(from: dateStr) else { return nil }
        let shifted = date.addingTimeInterval(interval)
        return formatter.string(from: shifted)
    }

    /// Shift a date string in various formats (EXIF, ISO 8601).
    static func shiftDateString(_ dateStr: String, by interval: TimeInterval) -> String? {
        // Try EXIF format first
        if let result = shiftExifDateString(dateStr, by: interval) {
            return result
        }
        // Try ISO 8601 (e.g. "2024-01-15T14:30:00")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: dateStr) {
            let shifted = date.addingTimeInterval(interval)
            return iso.string(from: shifted)
        }
        // Try date-only ISO (e.g. "2024-01-15")
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = dateOnly.date(from: dateStr) {
            let shifted = date.addingTimeInterval(interval)
            return dateOnly.string(from: shifted)
        }
        return nil
    }

    /// Combine IPTC date "YYYYMMDD" and time "HHMMSS" into EXIF format "YYYY:MM:DD HH:MM:SS".
    private static func combineIPTCDateTime(date: String, time: String?) -> String {
        // Date: "YYYYMMDD" → "YYYY:MM:DD"
        var result = date
        if date.count == 8 && !date.contains(":") {
            let y = date.prefix(4)
            let m = date.dropFirst(4).prefix(2)
            let d = date.dropFirst(6).prefix(2)
            result = "\(y):\(m):\(d)"
        }

        // Time: "HHMMSS" → " HH:MM:SS"
        if let time = time {
            // Strip timezone suffix if present (±HHMM)
            let core = time.prefix(6)
            if core.count == 6 {
                let h = core.prefix(2)
                let min = core.dropFirst(2).prefix(2)
                let s = core.dropFirst(4).prefix(2)
                result += " \(h):\(min):\(s)"
            }
        } else {
            result += " 00:00:00"
        }

        return result
    }

    // MARK: - Metadata Groups

    /// Groups of metadata that can be selectively copied or compared.
    public enum MetadataGroup: CaseIterable, Sendable {
        case exif
        case iptc
        case xmp
        case c2pa
        case iccProfile
    }

    // MARK: - Copy Metadata

    /// Copy all metadata from another ImageMetadata instance.
    /// Replaces all Exif, IPTC, XMP, and C2PA data with the source's values.
    public mutating func copyMetadata(from source: ImageMetadata) {
        exif = source.exif
        iptc = source.iptc
        xmp = source.xmp
        c2pa = source.c2pa
        iccProfile = source.iccProfile
    }

    /// Copy selected metadata groups from another ImageMetadata instance.
    public mutating func copyMetadata(from source: ImageMetadata, groups: Set<MetadataGroup>) {
        if groups.contains(.exif) { exif = source.exif }
        if groups.contains(.iptc) { iptc = source.iptc }
        if groups.contains(.xmp) { xmp = source.xmp }
        if groups.contains(.c2pa) { c2pa = source.c2pa }
        if groups.contains(.iccProfile) { iccProfile = source.iccProfile }
    }

    /// Copy metadata from source, filtered to only matching tags.
    public mutating func copyMetadata(from source: ImageMetadata, filter: TagFilter) {
        let sourceDict = MetadataExporter.buildDictionary(source)
        for (key, _) in sourceDict where filter.matches(key: key) {
            // Copy IPTC fields
            if key.hasPrefix("IPTC:") {
                let tagName = String(key.dropFirst(5))
                if let tag = IPTCTag.byName(tagName) {
                    let values = source.iptc.values(for: tag)
                    if !values.isEmpty {
                        try? iptc.setValues(values, for: tag)
                    }
                }
            }
            // Copy XMP fields
            else if key.hasPrefix("XMP-") {
                let rest = key.dropFirst(4)
                if let colonIdx = rest.firstIndex(of: ":") {
                    let prefix = String(rest[rest.startIndex..<colonIdx])
                    let property = String(rest[rest.index(after: colonIdx)...])
                    if let namespace = XMPNamespace.namespace(for: prefix),
                       let value = source.xmp?.value(namespace: namespace, property: property) {
                        if xmp == nil { xmp = XMPData() }
                        xmp?.setValue(value, namespace: namespace, property: property)
                    }
                }
            }
        }
    }

    /// Remove all tags whose keys match the filter pattern. Returns the number of tags removed.
    @discardableResult
    public mutating func removeMatchingTags(_ filter: TagFilter) -> Int {
        let dict = MetadataExporter.buildDictionary(self)
        var removed = 0
        for key in dict.keys where filter.matches(key: key) {
            if removeTag(key) { removed += 1 }
        }
        return removed
    }

    // MARK: - Metadata Diff

    /// A single difference between two metadata values.
    public struct MetadataChange: Equatable, Sendable {
        public enum ChangeType: Equatable, Sendable {
            case added
            case removed
            case modified
        }

        public let key: String
        public let type: ChangeType
        public let oldValue: String?
        public let newValue: String?

        public init(key: String, type: ChangeType, oldValue: String? = nil, newValue: String? = nil) {
            self.key = key
            self.type = type
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    /// Result of comparing two metadata instances.
    public struct MetadataDiff: Sendable {
        public let changes: [MetadataChange]

        public var additions: [MetadataChange] { changes.filter { $0.type == .added } }
        public var removals: [MetadataChange] { changes.filter { $0.type == .removed } }
        public var modifications: [MetadataChange] { changes.filter { $0.type == .modified } }
        public var isEmpty: Bool { changes.isEmpty }
    }

    /// Compare this metadata against another instance and return differences.
    public func diff(against other: ImageMetadata) -> MetadataDiff {
        let selfDict = MetadataExporter.buildDictionary(self)
        let otherDict = MetadataExporter.buildDictionary(other)

        var changes: [MetadataChange] = []
        let allKeys = Set(selfDict.keys).union(otherDict.keys)

        for key in allKeys.sorted() {
            let selfVal = selfDict[key].map { Self.stringifyValue($0) }
            let otherVal = otherDict[key].map { Self.stringifyValue($0) }

            switch (selfVal, otherVal) {
            case (nil, .some(let new)):
                changes.append(MetadataChange(key: key, type: .added, newValue: new))
            case (.some(let old), nil):
                changes.append(MetadataChange(key: key, type: .removed, oldValue: old))
            case (.some(let old), .some(let new)) where old != new:
                changes.append(MetadataChange(key: key, type: .modified, oldValue: old, newValue: new))
            default:
                break
            }
        }

        return MetadataDiff(changes: changes)
    }

    private static func stringifyValue(_ value: Any) -> String {
        if let arr = value as? [String] {
            return arr.joined(separator: ", ")
        }
        return String(describing: value)
    }

    // MARK: - Preview Extraction

    /// Extract the embedded JPEG preview image (larger than thumbnail).
    /// For CR3 files, this returns the PRVW image (typically 1620x1080).
    /// Falls back to `extractThumbnail()` if no dedicated preview is found.
    public func extractPreview() -> Data? {
        switch container {
        case .cr3(let file):
            return file.previewData ?? file.thumbnailData
        default:
            // For other formats, fall back to thumbnail (future: SubIFD preview for TIFF-based RAW)
            return extractThumbnail()
        }
    }

    // MARK: - Thumbnail Extraction

    /// Extract every thumbnail asserted in any C2PA manifest (claim or ingredient).
    /// Returns the JUMBF `bidb` payloads as `C2PAThumbnail` values, in manifest/assertion order.
    /// Filter by `label` (e.g. has-prefix `"c2pa.thumbnail.claim."`) to narrow to a specific kind.
    public func extractC2PAThumbnails() -> [C2PAThumbnail] {
        guard let manifests = c2pa?.manifests else { return [] }
        var out: [C2PAThumbnail] = []
        for manifest in manifests {
            for assertion in manifest.assertions {
                guard case .thumbnail(let data, let format) = assertion.content,
                      !data.isEmpty else { continue }
                out.append(C2PAThumbnail(label: assertion.label, data: data, format: format))
            }
        }
        return out
    }

    /// Extract the embedded JPEG thumbnail from Exif IFD1, if present.
    /// Returns the raw JPEG data of the thumbnail image.
    public func extractThumbnail() -> Data? {
        // CR3 stores its thumbnail in the Canon `THMB` box, extracted at parse
        // time — there is no Exif IFD1 to consult.
        if case .cr3(let file) = container {
            return file.thumbnailData
        }

        guard let exif = exif,
              let ifd1 = exif.ifd1 else { return nil }

        let endian = exif.byteOrder

        // Check compression is JPEG (value 6)
        if let compression = ifd1.entry(for: ExifTag.compression)?.uint16Value(endian: endian),
           compression != 6 {
            return nil
        }

        // Get the thumbnail data directly from IFD1 entries
        // The thumbnail JPEG data was already resolved by the IFD parser into valueData
        guard let offsetEntry = ifd1.entry(for: ExifTag.jpegIFOffset),
              let lengthEntry = ifd1.entry(for: ExifTag.jpegIFByteCount),
              let length = lengthEntry.uint32Value(endian: endian) else { return nil }

        // The offset entry points to the thumbnail data within the original Exif blob.
        // Since IFDParser resolves offset-based values, if the data was large enough
        // it would be at the offset. But thumbnail offset/length are metadata about
        // where to find the thumbnail in the original TIFF data — they aren't the
        // thumbnail data itself. We need to extract from the container.
        guard let offset = offsetEntry.uint32Value(endian: endian) else { return nil }

        return extractThumbnailFromContainer(offset: Int(offset), length: Int(length))
    }

    private func extractThumbnailFromContainer(offset: Int, length: Int) -> Data? {
        switch container {
        case .jpeg(let file):
            // Thumbnail offset is relative to TIFF start within the Exif APP1 segment
            guard let exifSegment = file.exifSegment() else { return nil }
            let tiffStart = 6 // Skip "Exif\0\0"
            let absOffset = tiffStart + offset
            let data = exifSegment.data
            guard absOffset >= 0, absOffset + length <= data.count else { return nil }
            return data[data.startIndex + absOffset ..< data.startIndex + absOffset + length]

        case .tiff(let file):
            // Offset is relative to file start (tiffStart = 0)
            guard offset >= 0, offset + length <= file.rawData.count else { return nil }
            return file.rawData[file.rawData.startIndex + offset ..< file.rawData.startIndex + offset + length]

        case .png(let file):
            guard let chunk = file.findChunk("eXIf") else { return nil }
            // eXIf chunk is raw TIFF data, offset is relative to start of chunk data
            guard offset >= 0, offset + length <= chunk.data.count else { return nil }
            return chunk.data[chunk.data.startIndex + offset ..< chunk.data.startIndex + offset + length]

        case .jpegXL(let file):
            guard let box = file.findBox("Exif") else { return nil }
            // Exif box has 4-byte offset prefix before TIFF data
            let prefixSize = 4
            let absOffset = prefixSize + offset
            guard absOffset >= 0, absOffset + length <= box.data.count else { return nil }
            return box.data[box.data.startIndex + absOffset ..< box.data.startIndex + absOffset + length]

        case .avif(let file):
            return extractThumbnailFromISOBMFF(boxes: file.boxes, offset: offset, length: length)

        case .heif(let file):
            return extractThumbnailFromISOBMFF(boxes: file.boxes, offset: offset, length: length)

        case .webp(let file):
            guard let chunk = file.findChunk("EXIF") else { return nil }
            guard offset >= 0, offset + length <= chunk.data.count else { return nil }
            return chunk.data[chunk.data.startIndex + offset ..< chunk.data.startIndex + offset + length]

        case .cr3(let file):
            // CR3 thumbnails are in THMB box (already extracted during parsing)
            return file.thumbnailData

        case .pdf:
            return nil // PDFs don't have EXIF thumbnails

        case .psd:
            return nil // PSD thumbnails are in IRB resource 0x0409, not EXIF

        case .gif:
            return nil // GIF doesn't have standard Exif embedding
        case .bmp:
            return nil // BMP doesn't support embedded thumbnails
        case .svg:
            return nil // SVG doesn't support embedded thumbnails
        }
    }

    private func extractThumbnailFromISOBMFF(boxes: [ISOBMFFBox], offset: Int, length: Int) -> Data? {
        guard let exifBox = ISOBMFFMetadata.findBox(type: "Exif", in: boxes) else { return nil }
        let prefixSize = 4
        let absOffset = prefixSize + offset
        guard absOffset >= 0, absOffset + length <= exifBox.data.count else { return nil }
        return exifBox.data[exifBox.data.startIndex + absOffset ..< exifBox.data.startIndex + absOffset + length]
    }

    // MARK: - IPTC ↔ XMP Sync

    /// Synchronize IPTC values to XMP (one-way: IPTC → XMP).
    public mutating func syncIPTCToXMP() {
        if xmp == nil { xmp = XMPData() }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = iptc.values(for: iptcTag)
                if !values.isEmpty {
                    xmp?.setValue(.array(values), namespace: xmpMapping.namespace, property: xmpMapping.property)
                }
            } else {
                if let value = iptc.value(for: iptcTag) {
                    // dc:title, dc:description, dc:rights use langAlternative
                    if xmpMapping.namespace == XMPNamespace.dc &&
                       (xmpMapping.property == "title" || xmpMapping.property == "description" || xmpMapping.property == "rights") {
                        xmp?.setValue(.langAlternative(value), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    } else {
                        xmp?.setValue(.simple(value), namespace: xmpMapping.namespace, property: xmpMapping.property)
                    }
                }
            }
        }
    }

    /// Synchronize XMP values to IPTC (one-way: XMP → IPTC).
    /// Throws `MetadataError.encodingError` if any XMP value cannot be encoded for IPTC.
    public mutating func syncXMPToIPTC() throws {
        guard let xmp = xmp else { return }

        for (iptcTag, xmpMapping) in XMPNamespace.iimToXMP {
            if iptcTag.isRepeatable {
                let values = xmp.arrayValue(namespace: xmpMapping.namespace, property: xmpMapping.property)
                if !values.isEmpty {
                    try iptc.setValues(values, for: iptcTag)
                }
            } else {
                if let value = xmp.simpleValue(namespace: xmpMapping.namespace, property: xmpMapping.property) {
                    try iptc.setValue(value, for: iptcTag)
                }
            }
        }
    }

    // MARK: - XMP Sidecar

    /// Read XMP metadata from a sidecar file alongside the given image URL.
    public static func readSidecar(for imageURL: URL) throws -> XMPData {
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        return try XMPSidecar.read(from: sidecarURL)
    }

    /// Write current XMP metadata as a sidecar file.
    public func writeSidecar(to url: URL) throws {
        guard let xmp = xmp else {
            throw MetadataError.writeNotSupported("No XMP data to write as sidecar")
        }
        try XMPSidecar.write(xmp, to: url)
    }

    /// Write current XMP metadata as a sidecar file alongside the given image URL.
    public func writeSidecar(for imageURL: URL) throws {
        let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
        try writeSidecar(to: sidecarURL)
    }

    // MARK: - XMP Sidecar Sync

    /// Direction for sidecar synchronization.
    public enum SyncDirection: Sendable {
        case sidecarToImage
        case imageToSidecar
    }

    /// Result of comparing sidecar vs embedded XMP.
    public struct SidecarSyncReport: Sendable {
        public let sidecarOnly: [String]
        public let embeddedOnly: [String]
        public let conflicts: [(key: String, sidecarValue: String, embeddedValue: String)]
        public let matching: Int
        public var hasDifferences: Bool { !sidecarOnly.isEmpty || !embeddedOnly.isEmpty || !conflicts.isEmpty }
    }

    /// Embed XMP from a sidecar file into this image's embedded XMP.
    /// Sidecar values overwrite embedded values on conflict.
    public mutating func embedSidecar(from sidecarURL: URL) throws {
        let sidecarXMP = try XMPSidecar.read(from: sidecarURL)
        if xmp == nil { xmp = XMPData() }

        for key in sidecarXMP.allKeys {
            // Parse namespace and property from the full key
            for (ns, _) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
                if key.hasPrefix(ns) {
                    let property = String(key.dropFirst(ns.count))
                    if let value = sidecarXMP.value(namespace: ns, property: property) {
                        xmp?.setValue(value, namespace: ns, property: property)
                    }
                    break
                }
            }
        }

        // Copy regions if present
        if let regions = sidecarXMP.regions {
            xmp?.regions = regions
        }
    }

    /// Compare sidecar XMP vs embedded XMP and report differences.
    public func compareSidecar(at sidecarURL: URL) throws -> SidecarSyncReport {
        let sidecarXMP = try XMPSidecar.read(from: sidecarURL)
        let embeddedXMP = xmp ?? XMPData()

        let sidecarKeys = Set(sidecarXMP.allKeys)
        let embeddedKeys = Set(embeddedXMP.allKeys)

        let sidecarOnly = sidecarKeys.subtracting(embeddedKeys).sorted()
        let embeddedOnly = embeddedKeys.subtracting(sidecarKeys).sorted()

        var conflicts: [(key: String, sidecarValue: String, embeddedValue: String)] = []
        var matching = 0

        for key in sidecarKeys.intersection(embeddedKeys).sorted() {
            let sVal = xmpValueString(sidecarXMP, key: key)
            let eVal = xmpValueString(embeddedXMP, key: key)
            if sVal == eVal {
                matching += 1
            } else {
                conflicts.append((key: key, sidecarValue: sVal, embeddedValue: eVal))
            }
        }

        return SidecarSyncReport(
            sidecarOnly: sidecarOnly,
            embeddedOnly: embeddedOnly,
            conflicts: conflicts,
            matching: matching
        )
    }

    /// Synchronize sidecar and embedded XMP in the chosen direction.
    public mutating func syncWithSidecar(at sidecarURL: URL, direction: SyncDirection) throws {
        switch direction {
        case .sidecarToImage:
            try embedSidecar(from: sidecarURL)
        case .imageToSidecar:
            try writeSidecar(to: sidecarURL)
        }
    }

    private func xmpValueString(_ xmp: XMPData, key: String) -> String {
        for (ns, _) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
            if key.hasPrefix(ns) {
                let property = String(key.dropFirst(ns.count))
                if let value = xmp.value(namespace: ns, property: property) {
                    switch value {
                    case .simple(let s): return s
                    case .array(let arr): return arr.joined(separator: "; ")
                    case .langAlternative(let s): return s
                    case .languageAlternative(let items):
                        return items.first(where: {
                            $0.language.caseInsensitiveCompare("x-default") == .orderedSame
                        })?.value ?? items.first?.value ?? ""
                    case .structure(let fields):
                        return XMPData.flatten(fields).values.sorted().joined(separator: "; ")
                    case .structuredArray(let items):
                        return items.map { XMPData.flatten($0).values.sorted().joined(separator: ", ") }.joined(separator: "; ")
                    }
                }
                break
            }
        }
        return ""
    }

    // MARK: - Lossless Orientation Operations

    /// Set the EXIF orientation tag directly.
    /// - Parameter value: EXIF orientation value (1-8).
    public mutating func setOrientation(_ value: UInt16) {
        guard value >= 1 && value <= 8 else { return }
        let byteOrder = exif?.byteOrder ?? .bigEndian
        if exif == nil { exif = ExifData(byteOrder: byteOrder) }

        let entry = buildOrientationEntry(value, endian: byteOrder)

        // Update IFD0
        let ifd0Offset = exif?.ifd0?.nextIFDOffset ?? 0
        var entries = (exif?.ifd0?.entries ?? []).filter { $0.tag != ExifTag.orientation }
        entries.append(entry)
        exif?.ifd0 = IFD(entries: entries, nextIFDOffset: ifd0Offset)

        // Update IFD1 (thumbnail) if present
        if let ifd1 = exif?.ifd1 {
            var thumbEntries = ifd1.entries.filter { $0.tag != ExifTag.orientation }
            thumbEntries.append(entry)
            exif?.ifd1 = IFD(entries: thumbEntries, nextIFDOffset: ifd1.nextIFDOffset)
        }
    }

    /// Reset orientation to normal (1 = Horizontal).
    public mutating func resetOrientation() {
        setOrientation(1)
    }

    /// Rotate the image 90° clockwise by updating the orientation tag.
    public mutating func rotateClockwise() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .rotateClockwise))
    }

    /// Rotate the image 90° counter-clockwise by updating the orientation tag.
    public mutating func rotateCounterClockwise() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .rotateCounterClockwise))
    }

    /// Flip the image horizontally by updating the orientation tag.
    public mutating func flipHorizontal() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .flipHorizontal))
    }

    /// Flip the image vertically by updating the orientation tag.
    public mutating func flipVertical() {
        let current = exif?.orientation ?? 1
        setOrientation(OrientationTransform.compose(current: current, operation: .flipVertical))
    }

    private func buildOrientationEntry(_ value: UInt16, endian: ByteOrder) -> IFDEntry {
        var writer = BinaryWriter(capacity: 2)
        writer.writeUInt16(value, endian: endian)
        return IFDEntry(tag: ExifTag.orientation, type: .short, count: 1, valueData: writer.data)
    }

    // MARK: - MakerNote Writing

    /// Set a MakerNote tag value.
    public mutating func setMakerNoteTag(_ key: String, value: MakerNoteValue) {
        exif?.makerNote?.setTag(key, value: value)
    }

    // MARK: - Direct GPS Writing

    /// Set GPS coordinates directly on the image.
    /// - Parameters:
    ///   - latitude: Latitude in decimal degrees (-90...90, positive = North).
    ///   - longitude: Longitude in decimal degrees (-180...180, positive = East).
    ///   - altitude: Altitude in meters above sea level. Negative values are below sea level.
    ///   - timestamp: GPS fix timestamp. Defaults to current time.
    public mutating func setGPS(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        timestamp: Date = Date()
    ) {
        let trackpoint = GPXTrackpoint(
            latitude: latitude,
            longitude: longitude,
            elevation: altitude,
            timestamp: timestamp
        )
        let byteOrder = exif?.byteOrder ?? .bigEndian
        if exif == nil { exif = ExifData(byteOrder: byteOrder) }
        exif?.gpsIFD = GPXGeotagger.buildGPSIFD(from: trackpoint, byteOrder: byteOrder)
    }

    /// Remove all GPS data from the image.
    public mutating func removeGPS() {
        stripGPS()
    }

    /// Reverse-geocode the image's GPS coordinates and fill IPTC/XMP location fields.
    /// - Parameters:
    ///   - geocoder: The reverse geocoder to use. Defaults to the shared instance.
    ///   - overwrite: If true, overwrites existing location fields. Default false.
    /// - Returns: The resolved GeoLocation, or nil if no GPS data or no match found.
    @discardableResult
    public mutating func fillLocationFromGPS(
        geocoder: ReverseGeocoder = .shared,
        overwrite: Bool = false
    ) -> GeoLocation? {
        guard let lat = exif?.gpsLatitude, let lon = exif?.gpsLongitude else { return nil }
        guard let location = geocoder.lookup(latitude: lat, longitude: lon) else { return nil }

        if overwrite || iptc.city == nil {
            iptc.city = location.city
        }
        if overwrite || iptc.provinceState == nil {
            iptc.provinceState = location.region
        }
        if overwrite || iptc.countryName == nil {
            iptc.countryName = location.country
        }
        if overwrite || iptc.countryCode == nil {
            iptc.countryCode = location.countryCode
        }

        // Also sync to XMP
        if xmp == nil { xmp = XMPData() }
        if overwrite || xmp?.city == nil {
            xmp?.city = location.city
        }
        if overwrite || xmp?.state == nil {
            xmp?.state = location.region
        }
        if overwrite || xmp?.country == nil {
            xmp?.country = location.country
        }

        return location
    }

    // MARK: - GPX Geotagging

    /// Apply GPS coordinates from a GPX track by matching DateTimeOriginal.
    /// - Parameters:
    ///   - track: Parsed GPX track with timestamped points.
    ///   - maxOffset: Maximum time difference to accept in seconds. Default 60.
    ///   - timeZoneOffset: Camera timezone offset from UTC in seconds. Default 0.
    ///     If 0, automatically reads OffsetTimeOriginal from EXIF (e.g. "+02:00") when available.
    /// - Returns: true if GPS was applied, false if no match found.
    @discardableResult
    public mutating func applyGPX(
        _ track: GPXTrack,
        maxOffset: TimeInterval = 60,
        timeZoneOffset: TimeInterval = 0
    ) -> Bool {
        guard let dateTimeOriginal = exif?.dateTimeOriginal else { return false }

        // Auto-detect timezone from OffsetTimeOriginal if no explicit offset provided
        var effectiveOffset = timeZoneOffset
        if effectiveOffset == 0, let offsetStr = exif?.offsetTimeOriginal {
            effectiveOffset = Self.parseTimezoneOffset(offsetStr) ?? 0
        }

        guard let matched = GPXGeotagger.match(
            dateTimeOriginal: dateTimeOriginal,
            track: track,
            maxOffset: maxOffset,
            timeZoneOffset: effectiveOffset
        ) else { return false }

        let byteOrder = exif?.byteOrder ?? .bigEndian
        if exif == nil { exif = ExifData(byteOrder: byteOrder) }
        exif?.gpsIFD = GPXGeotagger.buildGPSIFD(from: matched, byteOrder: byteOrder)
        return true
    }

    /// Parse an EXIF OffsetTime string (e.g. "+02:00", "-05:30") to seconds from UTC.
    static func parseTimezoneOffset(_ offset: String) -> TimeInterval? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 5 else { return nil }
        let sign: Double = trimmed.hasPrefix("-") ? -1.0 : 1.0
        let digits = trimmed.dropFirst() // drop +/-
        let parts = digits.split(separator: ":")
        guard parts.count == 2,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]) else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    // MARK: - Format-Specific Writing

    private func writeJPEG(_ file: inout JPEGFile, warnings: inout [String]) throws -> Data {
        // Write IPTC
        let existingAPP13 = file.iptcSegment()?.data
        let app13Data = try IPTCWriter.writeToAPP13(iptc, existingAPP13: existingAPP13, warnings: &warnings)
        file.replaceOrAddIPTCSegment(JPEGSegment(marker: .app13, data: app13Data))

        // Write Exif — size-capped to JPEG's per-segment ceiling. EXIF copied
        // from a RAW can carry oversized proprietary blobs (e.g. a Sony A1's
        // ~1.5 MB C2PA manifest in IFD0 tag 0xCD41) that overflow APP1; the
        // capped writer drops the largest droppable tags rather than letting a
        // single tag abort the whole metadata write. See ExifWriter.write(_:maxPayload:warnings:).
        if let exif = exif {
            let exifData = ExifWriter.write(exif, maxPayload: JPEGWriter.maxSegmentPayload, warnings: &warnings)
            file.replaceOrAddExifSegment(JPEGSegment(marker: .app1, data: exifData))
        }

        // Write XMP
        if let xmp = xmp {
            let xmpData = XMPWriter.write(xmp)
            file.replaceOrAddXMPSegment(JPEGSegment(marker: .app1, data: xmpData))
        } else {
            // Remove existing XMP segment if XMP was stripped
            file.segments.removeAll { $0.isXMP }
        }

        // Write ICC profile
        if let iccProfile = iccProfile {
            file.replaceOrAddICCProfileSegments(iccProfile.data)
        } else {
            // Remove existing ICC segments if profile was stripped
            file.segments.removeAll { $0.isICCProfile }
        }

        // Final safety net: a single oversized metadata segment must never abort
        // the whole write and drop all the *other* good metadata. Exif is already
        // size-capped above and ICC profiles are chunked, so the realistic
        // remaining offenders are an unusually large XMP packet (APP1) or IPTC
        // block (APP13). Drop the offending segment with a warning rather than
        // throwing. (Their proper oversize homes — ExtendedXMP / multi-segment
        // IPTC — are a separate, larger feature.)
        Self.dropOversizedMetadataSegments(&file, warnings: &warnings)

        return try JPEGWriter.write(file)
    }

    /// Drop any metadata APP segment whose payload exceeds JPEG's per-segment
    /// ceiling, recording a non-fatal warning. Only touches the metadata
    /// segments this writer authors (Exif/XMP/IPTC); anything else oversized
    /// still surfaces as `JPEGWriter.write`'s hard error.
    private static func dropOversizedMetadataSegments(_ file: inout JPEGFile, warnings: inout [String]) {
        file.segments.removeAll { segment in
            guard segment.data.count > JPEGWriter.maxSegmentPayload else { return false }
            let kind: String
            if segment.isExif { kind = "Exif" }
            else if segment.isXMP { kind = "XMP" }
            else if segment.isPhotoshop { kind = "IPTC" }
            else { return false } // not ours to drop — let JPEGWriter flag it
            warnings.append(
                "Dropped oversized \(kind) segment: \(segment.data.count) bytes exceeds "
                + "JPEG's \(JPEGWriter.maxSegmentPayload)-byte per-segment limit."
            )
            return true
        }
    }

    private func writePNG(_ file: inout PNGFile, warnings: inout [String]) -> Data {
        // Write Exif as eXIf chunk (raw TIFF, no prefix)
        if let exif = exif {
            let tiffData = ExifWriter.writeTIFF(exif, warnings: &warnings)
            file.replaceOrAddExifChunk(tiffData)
        }

        // Write XMP as iTXt chunk
        if let xmp = xmp {
            let xml = XMPWriter.generateXML(xmp)
            file.replaceOrAddXMPChunk(xml)
        } else {
            // Remove existing XMP chunk if XMP was stripped
            file.removeXMPChunk()
        }

        // Write ICC profile as iCCP chunk
        if let iccProfile = iccProfile {
            Self.writeICCPChunk(&file, profile: iccProfile)
        } else {
            file.removeChunk("iCCP")
        }

        return PNGWriter.write(file)
    }

    /// Build and write a PNG iCCP chunk from an ICC profile.
    private static func writeICCPChunk(_ file: inout PNGFile, profile: ICCProfile) {
        let name = profile.profileDescription ?? "ICC Profile"
        var payload = Data(name.utf8)
        payload.append(0x00) // null terminator
        payload.append(0x00) // compression method: zlib deflate
        if let compressed = ZlibInflate.deflate(profile.data) {
            payload.append(compressed)
        } else {
            payload.append(profile.data)
        }
        file.replaceOrAddChunk("iCCP", data: payload)
    }

    private func writeJXL(_ file: inout JXLFile, warnings: inout [String]) throws -> Data {
        // Write Exif box (4-byte offset prefix + TIFF data)
        if let exif = exif {
            var exifPayload = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix
            exifPayload.append(ExifWriter.writeTIFF(exif, warnings: &warnings))
            file.replaceOrAddBox("Exif", data: exifPayload)
        }

        // Write XMP box (type "xml ")
        if let xmp = xmp {
            let xml = XMPWriter.generateXML(xmp)
            file.replaceOrAddBox("xml ", data: Data(xml.utf8))
        } else {
            // Remove existing XMP box if XMP was stripped
            file.removeBox("xml ")
        }

        return try JXLWriter.write(file)
    }

    private func writeAVIF(_ file: AVIFFile) throws -> Data {
        return try AVIFWriter.write(file, exif: exif, xmp: xmp)
    }

    private func writeHEIF(_ file: HEIFFile) throws -> Data {
        return try HEIFWriter.write(file, exif: exif, xmp: xmp)
    }

    private func writeWebP(_ file: WebPFile) throws -> Data {
        return try WebPWriter.write(file, exif: exif, xmp: xmp, iccProfile: iccProfile)
    }

    private func writeCR3(_ file: CR3File) throws -> Data {
        guard let originalData = file.originalData else {
            throw MetadataError.invalidCR3("Cannot write CR3 without original data")
        }
        return try CR3Writer.write(file, exif: exif, xmp: xmp, originalData: originalData)
    }

    private func writeTIFFFile(_ file: TIFFFile, warnings: inout [String]) throws -> Data {
        return try TIFFWriter.write(file, exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile, warnings: &warnings)
    }

    // MARK: - Format-Specific Reading

    private static func readJPEG(from data: Data) throws -> ImageMetadata {
        let jpegFile = try JPEGParser.parse(data)

        var iptc = IPTCData()
        if let iptcSegment = jpegFile.iptcSegment() {
            iptc = try IPTCReader.readFromAPP13(iptcSegment.data)
        }

        var exif: ExifData?
        if let exifSegment = jpegFile.exifSegment() {
            exif = try ExifReader.read(from: exifSegment.data)
        }

        var xmp: XMPData?
        if let xmpSegment = jpegFile.xmpSegment() {
            xmp = try XMPReader.read(from: xmpSegment.data)
        }

        // ICC profile from APP2 segments
        var iccProfile: ICCProfile?
        let iccSegments = jpegFile.iccProfileSegments()
        if !iccSegments.isEmpty {
            // Sort by sequence number (byte 12 of data, after 12-byte identifier)
            let sorted = iccSegments.sorted { a, b in
                let seqA = a.data.count > 12 ? a.data[a.data.startIndex + 12] : 0
                let seqB = b.data.count > 12 ? b.data[b.data.startIndex + 12] : 0
                return seqA < seqB
            }
            var profileData = Data()
            for seg in sorted {
                guard seg.data.count > 14 else { continue }
                profileData.append(seg.data.suffix(from: seg.data.startIndex + 14))
            }
            iccProfile = ICCProfile(data: profileData)
        }

        // C2PA from APP11 JUMBF segments
        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = try C2PAReader.extractJUMBFFromJPEG(jpegFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        // MPF (CIPA DC-007) from an APP2 segment when the payload starts
        // with "MPF\0". Carries Live Photo aux frames, depth maps, etc.
        var mpf: MPFData?
        if let mpfSegment = jpegFile.mpfSegment() {
            mpf = MPFParser.parse(mpfSegment.data)
        }

        return ImageMetadata(container: .jpeg(jpegFile), format: .jpeg, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, mpf: mpf, warnings: warnings)
    }

    private static func readTIFF(from data: Data, format: ImageFormat) throws -> ImageMetadata {
        let tiffFile = try TIFFFileParser.parse(data)

        var iptc = IPTCData()
        var exif: ExifData?
        var xmp: XMPData?

        // Build ExifData from the parsed IFDs
        exif = try TIFFFileParser.extractExif(from: tiffFile, data: data)

        // Extract IPTC (from tag 0x8649 Photoshop IRB, or tag 0x83BB raw IPTC-NAA)
        iptc = try TIFFFileParser.extractIPTC(from: tiffFile)

        // Extract XMP (from tag 0x02BC)
        xmp = try TIFFFileParser.extractXMP(from: tiffFile)

        // Extract ICC profile (tag 0x8773)
        let iccProfile = TIFFFileParser.extractICCProfile(from: tiffFile)

        // DNG private tags (only populated for DNG-marked files)
        let dng = DNGMetadataReader.read(from: tiffFile)

        // C2PA from IFD0 tag 0xCD41
        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromTIFF(tiffFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .tiff(tiffFile), format: format, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, dng: dng, warnings: warnings)
    }

    private static func readRAW(from data: Data, format: ImageFormat) throws -> ImageMetadata {
        guard case .raw(let rawFormat) = format else {
            throw MetadataError.invalidRAW("Expected RAW format")
        }
        let tiffFile = try RAWFileParser.parse(data, format: rawFormat)

        var iptc = IPTCData()
        var exif: ExifData?
        var xmp: XMPData?

        exif = try TIFFFileParser.extractExif(from: tiffFile, data: tiffFile.rawData)
        iptc = try TIFFFileParser.extractIPTC(from: tiffFile)
        xmp = try TIFFFileParser.extractXMP(from: tiffFile)
        let iccProfile = TIFFFileParser.extractICCProfile(from: tiffFile)
        let dng = DNGMetadataReader.read(from: tiffFile)

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromTIFF(tiffFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .tiff(tiffFile), format: format, iptc: iptc, exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, dng: dng, warnings: warnings)
    }

    private static func readJPEGXL(from data: Data) throws -> ImageMetadata {
        let jxlFile = try JXLParser.parse(data)

        var exif: ExifData?
        var xmp: XMPData?

        // Exif box
        if let exifBox = jxlFile.findBox("Exif") {
            exif = try JXLParser.extractExif(from: exifBox)
        }

        // XMP box (type "xml ")
        if let xmpBox = jxlFile.findBox("xml ") {
            xmp = try XMPReader.readFromXML(xmpBox.data)
        }

        // C2PA from jumb box
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromJPEGXL(jxlFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        return ImageMetadata(container: .jpegXL(jxlFile), format: .jpegXL, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    private static func readPNG(from data: Data) throws -> ImageMetadata {
        let pngFile = try PNGParser.parse(data)

        var exif: ExifData?
        var xmp: XMPData?

        // eXIf chunk
        if let exifChunk = pngFile.findChunk("eXIf") {
            exif = try ExifReader.readFromTIFF(data: exifChunk.data)
        }

        // XMP in iTXt chunk with keyword "XML:com.adobe.xmp"
        xmp = try PNGParser.extractXMP(from: pngFile)

        // ICC profile from iCCP chunk
        var iccProfile: ICCProfile?
        if let iccpChunk = pngFile.findChunk("iCCP") {
            iccProfile = Self.parseICCPChunk(iccpChunk.data)
        }

        // C2PA from caBX chunk
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromPNG(pngFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        return ImageMetadata(container: .png(pngFile), format: .png, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, warnings: warnings)
    }

    /// Parse a PNG iCCP chunk: profile name (null-terminated) + compression method (1 byte) + compressed data.
    private static func parseICCPChunk(_ data: Data) -> ICCProfile? {
        let bytes = [UInt8](data)
        guard let nullIndex = bytes.firstIndex(of: 0), nullIndex + 2 < bytes.count else { return nil }
        // Skip profile name + null + compression method byte
        let compressedData = Data(bytes[(nullIndex + 2)...])
        guard let decompressed = ZlibInflate.inflate(compressedData) else { return nil }
        return ICCProfile(data: decompressed)
    }

    private static func readAVIF(from data: Data) throws -> ImageMetadata {
        let avifFile = try AVIFParser.parse(data)

        let exif = try AVIFParser.extractExif(from: avifFile, fileData: data)
        let xmp = try AVIFParser.extractXMP(from: avifFile, fileData: data)

        // C2PA from jumb or uuid box
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromAVIF(avifFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        let iccProfile = ISOBMFFMetadata.extractICCProfile(from: avifFile.boxes)
        let hdr = ISOBMFFMetadata.extractHDRMetadata(from: avifFile.boxes)

        return ImageMetadata(container: .avif(avifFile), format: .avif, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, hdr: hdr, warnings: warnings)
    }

    private static func readHEIF(from data: Data) throws -> ImageMetadata {
        let heifFile = try HEIFParser.parse(data)

        let exif = try HEIFParser.extractExif(from: heifFile, fileData: data)
        let xmp = try HEIFParser.extractXMP(from: heifFile, fileData: data)

        // C2PA from jumb or uuid box
        var c2pa: C2PAData?
        var warnings: [String] = []
        if let jumbfData = C2PAReader.extractJUMBFFromHEIF(heifFile) {
            do {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            } catch {
                warnings.append("C2PA parsing failed: \(error)")
            }
        }

        let iccProfile = ISOBMFFMetadata.extractICCProfile(from: heifFile.boxes)
        let hdr = ISOBMFFMetadata.extractHDRMetadata(from: heifFile.boxes)

        return ImageMetadata(container: .heif(heifFile), format: .heif, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, hdr: hdr, warnings: warnings)
    }

    private static func readCR3(from data: Data) throws -> ImageMetadata {
        let (file, exif, xmp, iptc) = try CR3Parser.parse(data)
        return ImageMetadata(container: .cr3(file), format: .raw(.cr3), iptc: iptc, exif: exif, xmp: xmp)
    }

    private static func readWebP(from data: Data) throws -> ImageMetadata {
        let webpFile = try WebPParser.parse(data)

        let exif = try WebPParser.extractExif(from: webpFile)
        let xmp = try WebPParser.extractXMP(from: webpFile)
        let iccProfile = WebPParser.extractICCProfile(from: webpFile)

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromWebP(webpFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .webp(webpFile), format: .webp, iptc: IPTCData(), exif: exif, xmp: xmp, c2pa: c2pa, iccProfile: iccProfile, warnings: warnings)
    }

    // MARK: - PDF

    private static func readPDF(from data: Data) throws -> ImageMetadata {
        let pdfFile = try PDFParser.parse(data)

        // Extract XMP from XMP stream if available
        var xmp: XMPData? = nil
        if let xmpStreamData = pdfFile.xmpStreamData {
            xmp = try? XMPReader.readFromXML(xmpStreamData)
        }

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromPDF(pdfFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .pdf(pdfFile), format: .pdf, iptc: IPTCData(), xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    // MARK: - PSD

    private static func readPSD(from data: Data) throws -> ImageMetadata {
        let psdFile = try PSDParser.parse(data)

        let exif = PSDParser.extractExif(from: psdFile)
        let xmp = try? PSDParser.extractXMP(from: psdFile)
        let iccProfile = PSDParser.extractICCProfile(from: psdFile)

        // Extract IPTC from IRB
        var iptc = IPTCData()
        if let iptcBlock = psdFile.irbBlocks.first(where: { $0.resourceID == PSDFile.iptcResourceID }) {
            iptc = (try? IPTCReader.read(from: iptcBlock.data)) ?? IPTCData()
        }

        return ImageMetadata(container: .psd(psdFile), format: .psd, iptc: iptc, exif: exif, xmp: xmp, iccProfile: iccProfile)
    }

    private func writePSD(_ file: PSDFile) throws -> Data {
        try PSDWriter.write(file, iptc: iptc, exif: exif, xmp: xmp, iccProfile: iccProfile)
    }

    private static func readGIF(from data: Data) throws -> ImageMetadata {
        let gifFile = try GIFParser.parse(data)
        let xmp = try? GIFParser.extractXMP(from: gifFile)

        var c2pa: C2PAData?
        var warnings: [String] = []
        do {
            if let jumbfData = C2PAReader.extractJUMBFFromGIF(gifFile) {
                c2pa = try C2PAReader.parseManifestStore(from: jumbfData)
            }
        } catch {
            warnings.append("C2PA parsing failed: \(error)")
        }

        return ImageMetadata(container: .gif(gifFile), format: .gif, xmp: xmp, c2pa: c2pa, warnings: warnings)
    }

    private func writeGIF(_ file: GIFFile) -> Data {
        GIFWriter.write(file, xmp: xmp)
    }

    private static func readBMP(from data: Data) throws -> ImageMetadata {
        let bmpFile = try BMPParser.parse(data)
        return ImageMetadata(container: .bmp(bmpFile), format: .bmp)
    }

    private func writeBMP(_ file: BMPFile) -> Data {
        // BMP is read-only for metadata — return raw data unchanged
        file.rawData
    }

    private static func readSVG(from data: Data) throws -> ImageMetadata {
        let svgFile = try SVGParser.parse(data)
        let xmp = try? SVGParser.extractXMP(from: svgFile)
        return ImageMetadata(container: .svg(svgFile), format: .svg, xmp: xmp)
    }

    private func writeSVG(_ file: SVGFile) -> Data {
        SVGWriter.write(file, xmp: xmp)
    }

    private func writePDF(_ file: PDFFile) throws -> Data {
        // Build updated Info dict from the file's info dict
        var infoDict = file.infoDict

        // Sync XMP title/author to Info dict if available
        if let xmp {
            if let title = xmp.title { infoDict["Title"] = title }
            if let desc = xmp.description { infoDict["Subject"] = desc }
            if !xmp.creator.isEmpty { infoDict["Author"] = xmp.creator.joined(separator: ", ") }
        }

        let xmpData: Data? = xmp.map { Data(XMPWriter.generateXML($0).utf8) }

        return try PDFWriter.write(file, infoDict: infoDict, xmpData: xmpData)
    }
}
