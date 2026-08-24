import Foundation

/// A collection of IPTC datasets representing all IPTC metadata in a file.
public struct IPTCData: Equatable, Sendable {
    public private(set) var datasets: [IPTCDataSet]

    /// The detected encoding from Record 1:90 CodedCharacterSet.
    /// Defaults to .utf8 for new data.
    public var encoding: String.Encoding

    public init(datasets: [IPTCDataSet] = [], encoding: String.Encoding = .utf8) {
        self.datasets = datasets
        self.encoding = encoding
    }

    public var isUTF8: Bool { encoding == .utf8 }

    // MARK: - Single-Value Access

    /// Get the first value for a tag as a string.
    public func value(for tag: IPTCTag) -> String? {
        datasets.first { $0.tag == tag }?.stringValue(encoding: encoding)
    }

    /// Get the raw data for a tag.
    public func rawValue(for tag: IPTCTag) -> Data? {
        datasets.first { $0.tag == tag }?.rawValue
    }

    // MARK: - Multi-Value Access

    /// Get all values for a tag (for repeatable fields like keywords).
    public func values(for tag: IPTCTag) -> [String] {
        datasets.filter { $0.tag == tag }.compactMap { $0.stringValue(encoding: encoding) }
    }

    /// Get all datasets for a specific tag.
    public func dataSets(for tag: IPTCTag) -> [IPTCDataSet] {
        datasets.filter { $0.tag == tag }
    }

    // MARK: - Mutation

    /// Set a single value for a tag (replaces all existing instances).
    /// Throws `MetadataError.encodingError` if the value cannot be encoded.
    public mutating func setValue(_ value: String, for tag: IPTCTag) throws {
        let ds = try IPTCDataSet(tag: tag, stringValue: value, encoding: encoding)
        removeAll(for: tag)
        datasets.append(ds)
    }

    /// Set multiple values for a repeatable tag (replaces all existing instances).
    /// Throws `MetadataError.encodingError` if any value cannot be encoded.
    public mutating func setValues(_ values: [String], for tag: IPTCTag) throws {
        var encoded: [IPTCDataSet] = []
        for value in values {
            encoded.append(try IPTCDataSet(tag: tag, stringValue: value, encoding: encoding))
        }
        removeAll(for: tag)
        datasets.append(contentsOf: encoded)
    }

    /// Add a value for a repeatable tag (appends, does not replace).
    /// Throws `MetadataError.encodingError` if the value cannot be encoded.
    public mutating func addValue(_ value: String, for tag: IPTCTag) throws {
        datasets.append(try IPTCDataSet(tag: tag, stringValue: value, encoding: encoding))
    }

    /// Remove all datasets for a specific tag.
    public mutating func removeAll(for tag: IPTCTag) {
        datasets.removeAll { $0.tag == tag }
    }

    // MARK: - Validation

    /// Validate all datasets against IPTC spec constraints (max length).
    /// Throws `MetadataError.dataExceedsMaxLength` for any field that exceeds its limit.
    public func validate() throws {
        for ds in datasets {
            if let max = ds.tag.maxLength, ds.rawValue.count > max {
                throw MetadataError.dataExceedsMaxLength(
                    tag: ds.tag.name, max: max, actual: ds.rawValue.count)
            }
        }
    }

    /// Non-throwing counterpart of `validate()`: returns a human-readable warning
    /// for every field that exceeds its IPTC spec max length, without failing.
    ///
    /// The write path uses this so that re-serializing a file whose IPTC was
    /// authored over-spec by some upstream tool (common in agency/wire JPEGs)
    /// succeeds — preserving the original value — rather than aborting an
    /// unrelated edit. This mirrors ExifTool, which only warns on such fields.
    public func maxLengthWarnings() -> [String] {
        var warnings: [String] = []
        for ds in datasets {
            if let max = ds.tag.maxLength, ds.rawValue.count > max {
                warnings.append(
                    "IPTC \(ds.tag.name) exceeds spec max length (\(ds.rawValue.count) > \(max)); writing value as-is")
            }
        }
        return warnings
    }

    // MARK: - Convenience Properties (Journalism Fields)

    public var headline: String? {
        get { value(for: .headline) }
        set {
            if let v = newValue { try? setValue(v, for: .headline) }
            else { removeAll(for: .headline) }
        }
    }

    public var caption: String? {
        get { value(for: .captionAbstract) }
        set {
            if let v = newValue { try? setValue(v, for: .captionAbstract) }
            else { removeAll(for: .captionAbstract) }
        }
    }

    public var byline: String? {
        get { value(for: .byline) }
        set {
            if let v = newValue { try? setValue(v, for: .byline) }
            else { removeAll(for: .byline) }
        }
    }

    public var bylines: [String] {
        get { values(for: .byline) }
        set { try? setValues(newValue, for: .byline) }
    }

    public var keywords: [String] {
        get { values(for: .keywords) }
        set { try? setValues(newValue, for: .keywords) }
    }

    public var city: String? {
        get { value(for: .city) }
        set {
            if let v = newValue { try? setValue(v, for: .city) }
            else { removeAll(for: .city) }
        }
    }

    public var sublocation: String? {
        get { value(for: .sublocation) }
        set {
            if let v = newValue { try? setValue(v, for: .sublocation) }
            else { removeAll(for: .sublocation) }
        }
    }

    public var provinceState: String? {
        get { value(for: .provinceState) }
        set {
            if let v = newValue { try? setValue(v, for: .provinceState) }
            else { removeAll(for: .provinceState) }
        }
    }

    public var countryCode: String? {
        get { value(for: .countryPrimaryLocationCode) }
        set {
            if let v = newValue { try? setValue(v, for: .countryPrimaryLocationCode) }
            else { removeAll(for: .countryPrimaryLocationCode) }
        }
    }

    public var countryName: String? {
        get { value(for: .countryPrimaryLocationName) }
        set {
            if let v = newValue { try? setValue(v, for: .countryPrimaryLocationName) }
            else { removeAll(for: .countryPrimaryLocationName) }
        }
    }

    public var credit: String? {
        get { value(for: .credit) }
        set {
            if let v = newValue { try? setValue(v, for: .credit) }
            else { removeAll(for: .credit) }
        }
    }

    public var source: String? {
        get { value(for: .source) }
        set {
            if let v = newValue { try? setValue(v, for: .source) }
            else { removeAll(for: .source) }
        }
    }

    public var copyright: String? {
        get { value(for: .copyrightNotice) }
        set {
            if let v = newValue { try? setValue(v, for: .copyrightNotice) }
            else { removeAll(for: .copyrightNotice) }
        }
    }

    public var dateCreated: String? {
        get { value(for: .dateCreated) }
        set {
            if let v = newValue { try? setValue(v, for: .dateCreated) }
            else { removeAll(for: .dateCreated) }
        }
    }

    public var timeCreated: String? {
        get { value(for: .timeCreated) }
        set {
            if let v = newValue { try? setValue(v, for: .timeCreated) }
            else { removeAll(for: .timeCreated) }
        }
    }

    public var specialInstructions: String? {
        get { value(for: .specialInstructions) }
        set {
            if let v = newValue { try? setValue(v, for: .specialInstructions) }
            else { removeAll(for: .specialInstructions) }
        }
    }

    public var objectName: String? {
        get { value(for: .objectName) }
        set {
            if let v = newValue { try? setValue(v, for: .objectName) }
            else { removeAll(for: .objectName) }
        }
    }

    public var writerEditor: String? {
        get { value(for: .writerEditor) }
        set {
            if let v = newValue { try? setValue(v, for: .writerEditor) }
            else { removeAll(for: .writerEditor) }
        }
    }

    public var jobId: String? {
        get { value(for: .originalTransmissionReference) }
        set {
            if let v = newValue { try? setValue(v, for: .originalTransmissionReference) }
            else { removeAll(for: .originalTransmissionReference) }
        }
    }

    public var originatingProgram: String? {
        get { value(for: .originatingProgram) }
        set {
            if let v = newValue { try? setValue(v, for: .originatingProgram) }
            else { removeAll(for: .originatingProgram) }
        }
    }

    public var programVersion: String? {
        get { value(for: .programVersion) }
        set {
            if let v = newValue { try? setValue(v, for: .programVersion) }
            else { removeAll(for: .programVersion) }
        }
    }

    public var bylineTitle: String? {
        get { value(for: .bylineTitle) }
        set {
            if let v = newValue { try? setValue(v, for: .bylineTitle) }
            else { removeAll(for: .bylineTitle) }
        }
    }

    public var bylineTitles: [String] {
        get { values(for: .bylineTitle) }
        set { try? setValues(newValue, for: .bylineTitle) }
    }

    /// Urgency as an integer (1-8, where 1 is most urgent).
    public var urgency: Int? {
        get {
            guard let str = value(for: .urgency) else { return nil }
            return Int(str)
        }
        set {
            if let v = newValue { try? setValue(String(v), for: .urgency) }
            else { removeAll(for: .urgency) }
        }
    }

    public var category: String? {
        get { value(for: .category) }
        set {
            if let v = newValue { try? setValue(v, for: .category) }
            else { removeAll(for: .category) }
        }
    }

    public var supplementalCategories: [String] {
        get { values(for: .supplementalCategories) }
        set { try? setValues(newValue, for: .supplementalCategories) }
    }

    public var contacts: [String] {
        get { values(for: .contact) }
        set { try? setValues(newValue, for: .contact) }
    }

    public var editStatus: String? {
        get { value(for: .editStatus) }
        set {
            if let v = newValue { try? setValue(v, for: .editStatus) }
            else { removeAll(for: .editStatus) }
        }
    }

    public var languageIdentifier: String? {
        get { value(for: .languageIdentifier) }
        set {
            if let v = newValue { try? setValue(v, for: .languageIdentifier) }
            else { removeAll(for: .languageIdentifier) }
        }
    }

    public var releaseDate: String? {
        get { value(for: .releaseDate) }
        set {
            if let v = newValue { try? setValue(v, for: .releaseDate) }
            else { removeAll(for: .releaseDate) }
        }
    }

    public var releaseTime: String? {
        get { value(for: .releaseTime) }
        set {
            if let v = newValue { try? setValue(v, for: .releaseTime) }
            else { removeAll(for: .releaseTime) }
        }
    }

    public var expirationDate: String? {
        get { value(for: .expirationDate) }
        set {
            if let v = newValue { try? setValue(v, for: .expirationDate) }
            else { removeAll(for: .expirationDate) }
        }
    }

    public var expirationTime: String? {
        get { value(for: .expirationTime) }
        set {
            if let v = newValue { try? setValue(v, for: .expirationTime) }
            else { removeAll(for: .expirationTime) }
        }
    }

    // MARK: - Convenience Properties (News Photo Record 3)

    /// Read a Record 3/8 numeric tag, decoding the underlying binary form.
    /// Returns nil if the tag is missing or undersized.
    public func intValue(for tag: IPTCTag) -> Int? {
        guard let ds = datasets.first(where: { $0.tag == tag }) else { return nil }
        switch tag.dataType {
        case .int8u:  return ds.uint8Value().map { Int($0) }
        case .int16u: return ds.uint16Value().map { Int($0) }
        case .int32u: return ds.uint32Value().map { Int($0) }
        case .digits, .string:
            return ds.stringValue(encoding: encoding).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        case .binary:
            return nil
        }
    }

    /// IPTC Record 3:20 — image width in pixels for transmitted news photos.
    public var iptcImageWidth: Int? { intValue(for: .iptcImageWidth) }
    /// IPTC Record 3:30 — image height in pixels.
    public var iptcImageHeight: Int? { intValue(for: .iptcImageHeight) }
    /// IPTC Record 3:40 — pixel width in micrometres × 100.
    public var iptcPixelWidth: Int? { intValue(for: .iptcPixelWidth) }
    /// IPTC Record 3:50 — pixel height in micrometres × 100.
    public var iptcPixelHeight: Int? { intValue(for: .iptcPixelHeight) }
    /// IPTC Record 3:55 — 0=Main, 1=Reduced resolution, 2=Logo, 3=Rasterized caption.
    public var supplementalType: Int? { intValue(for: .supplementalType) }
    /// IPTC Record 3:60 — color representation (0x000=No color, 0x404=Monochrome, 0x3F8=4:4:4, ...).
    public var colorRepresentation: Int? { intValue(for: .colorRepresentation) }
    /// IPTC Record 3:64 — interchange color space (1=X/Y/Z, 2=RGB, 3=CMY, 4=L/A/B, 5=YCbCr, 6=RGB+alpha, ...).
    public var interchangeColorSpace: Int? { intValue(for: .interchangeColorSpace) }
    /// IPTC Record 3:65 — color sequence (1=A then B then C, 2=interleaved).
    public var colorSequence: Int? { intValue(for: .colorSequence) }
    /// IPTC Record 3:66 — embedded ICC profile.
    public var iccProfileData: Data? { rawValue(for: .iccProfile) }
    /// IPTC Record 3:86 — bits per sample (typically 8 or 16).
    public var iptcBitsPerSample: Int? { intValue(for: .iptcBitsPerSample) }
    /// IPTC Record 3:90 — sample structure (1=4:2:2 etc.).
    public var sampleStructure: Int? { intValue(for: .sampleStructure) }
    /// IPTC Record 3:102 — image rotation in degrees (0, 90, 180, 270).
    public var iptcImageRotation: Int? { intValue(for: .iptcImageRotation) }
    /// IPTC Record 3:110 — data compression method (0=uncompressed, 1=PackBits, 2=JPEG, ...).
    public var dataCompressionMethod: Int? { intValue(for: .dataCompressionMethod) }
    /// IPTC Record 3:135 — bits per component.
    public var bitsPerComponent: Int? { intValue(for: .bitsPerComponent) }

    // MARK: - Convenience Properties (ObjectData Records 6, 7, 8)

    /// IPTC Record 7:10 — ObjectData preview file format (1=NewsPhoto, 2=Hires, 4=GIF, 5=JPEG, 6=Photo CD, ...).
    public var objectDataPreviewFileFormat: Int? { intValue(for: .objectDataPreviewFileFormat) }
    /// IPTC Record 7:20 — ObjectData preview file format version.
    public var objectDataPreviewFileFormatVersion: Int? { intValue(for: .objectDataPreviewFileFormatVersion) }
    /// IPTC Record 7:30 — embedded preview bytes (typically a JPEG).
    public var objectDataPreviewData: Data? { rawValue(for: .objectDataPreviewData) }
    /// IPTC Record 8:10 — confirmed object data size (Post-ObjectData trailer).
    public var confirmedDataSize: Int? { intValue(for: .confirmedDataSize) }
}
