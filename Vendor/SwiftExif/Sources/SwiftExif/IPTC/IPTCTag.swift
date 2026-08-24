import Foundation

/// An IPTC IIM tag identified by record and dataset number.
public struct IPTCTag: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let record: UInt8
    public let dataSet: UInt8

    public init(record: UInt8, dataSet: UInt8) {
        self.record = record
        self.dataSet = dataSet
    }

    /// Parse from "record:dataset" notation, e.g. "2:25".
    public init?(_ notation: String) {
        let parts = notation.split(separator: ":")
        guard parts.count == 2,
              let record = UInt8(parts[0]),
              let dataSet = UInt8(parts[1])
        else { return nil }
        self.record = record
        self.dataSet = dataSet
    }

    public var description: String {
        let meta = IPTCTag.metadata[self]
        let name = meta?.name ?? "Unknown"
        return "\(record):\(String(format: "%03d", dataSet)) \(name)"
    }

    public static func < (lhs: IPTCTag, rhs: IPTCTag) -> Bool {
        if lhs.record != rhs.record { return lhs.record < rhs.record }
        return lhs.dataSet < rhs.dataSet
    }

    // MARK: - Tag Properties

    /// Human-readable name for this tag.
    public var name: String {
        IPTCTag.metadata[self]?.name ?? "Unknown(\(record):\(dataSet))"
    }

    /// Maximum byte length for this tag's value, or nil for unlimited.
    public var maxLength: Int? {
        IPTCTag.metadata[self]?.maxLength
    }

    /// Whether multiple instances of this tag are allowed.
    public var isRepeatable: Bool {
        IPTCTag.metadata[self]?.isRepeatable ?? false
    }

    /// The data type for this tag.
    public var dataType: IPTCDataType {
        IPTCTag.metadata[self]?.dataType ?? .string
    }

    // MARK: - Record 1 Tags (Envelope)

    public static let envelopeRecordVersion = IPTCTag(record: 1, dataSet: 0)
    public static let codedCharacterSet     = IPTCTag(record: 1, dataSet: 90)

    // MARK: - Record 2 Tags (Application)

    public static let applicationRecordVersion      = IPTCTag(record: 2, dataSet: 0)
    public static let objectTypeReference            = IPTCTag(record: 2, dataSet: 3)
    public static let objectAttributeReference       = IPTCTag(record: 2, dataSet: 4)
    public static let objectName                     = IPTCTag(record: 2, dataSet: 5)
    public static let editStatus                     = IPTCTag(record: 2, dataSet: 7)
    public static let editorialUpdate                = IPTCTag(record: 2, dataSet: 8)
    public static let urgency                        = IPTCTag(record: 2, dataSet: 10)
    public static let subjectReference               = IPTCTag(record: 2, dataSet: 12)
    public static let category                       = IPTCTag(record: 2, dataSet: 15)
    public static let supplementalCategories         = IPTCTag(record: 2, dataSet: 20)
    public static let fixtureIdentifier              = IPTCTag(record: 2, dataSet: 22)
    public static let keywords                       = IPTCTag(record: 2, dataSet: 25)
    public static let contentLocationCode            = IPTCTag(record: 2, dataSet: 26)
    public static let contentLocationName            = IPTCTag(record: 2, dataSet: 27)
    public static let releaseDate                    = IPTCTag(record: 2, dataSet: 30)
    public static let releaseTime                    = IPTCTag(record: 2, dataSet: 35)
    public static let expirationDate                 = IPTCTag(record: 2, dataSet: 37)
    public static let expirationTime                 = IPTCTag(record: 2, dataSet: 38)
    public static let specialInstructions            = IPTCTag(record: 2, dataSet: 40)
    public static let actionAdvised                  = IPTCTag(record: 2, dataSet: 42)
    public static let referenceService               = IPTCTag(record: 2, dataSet: 45)
    public static let referenceDate                  = IPTCTag(record: 2, dataSet: 47)
    public static let referenceNumber                = IPTCTag(record: 2, dataSet: 50)
    public static let dateCreated                    = IPTCTag(record: 2, dataSet: 55)
    public static let timeCreated                    = IPTCTag(record: 2, dataSet: 60)
    public static let digitalCreationDate            = IPTCTag(record: 2, dataSet: 62)
    public static let digitalCreationTime            = IPTCTag(record: 2, dataSet: 63)
    public static let originatingProgram             = IPTCTag(record: 2, dataSet: 65)
    public static let programVersion                 = IPTCTag(record: 2, dataSet: 70)
    public static let objectCycle                    = IPTCTag(record: 2, dataSet: 75)
    public static let byline                         = IPTCTag(record: 2, dataSet: 80)
    public static let bylineTitle                    = IPTCTag(record: 2, dataSet: 85)
    public static let city                           = IPTCTag(record: 2, dataSet: 90)
    public static let sublocation                    = IPTCTag(record: 2, dataSet: 92)
    public static let provinceState                  = IPTCTag(record: 2, dataSet: 95)
    public static let countryPrimaryLocationCode     = IPTCTag(record: 2, dataSet: 100)
    public static let countryPrimaryLocationName     = IPTCTag(record: 2, dataSet: 101)
    public static let originalTransmissionReference  = IPTCTag(record: 2, dataSet: 103)
    public static let headline                       = IPTCTag(record: 2, dataSet: 105)
    public static let credit                         = IPTCTag(record: 2, dataSet: 110)
    public static let source                         = IPTCTag(record: 2, dataSet: 115)
    public static let copyrightNotice                = IPTCTag(record: 2, dataSet: 116)
    public static let contact                        = IPTCTag(record: 2, dataSet: 118)
    public static let captionAbstract                = IPTCTag(record: 2, dataSet: 120)
    public static let writerEditor                   = IPTCTag(record: 2, dataSet: 122)
    public static let languageIdentifier             = IPTCTag(record: 2, dataSet: 135)

    // MARK: - Record 3 Tags (News Photo)
    //
    // IPTC IIM v4.2 §1.5 — pixel-format and color-pipeline metadata that travels
    // with a transmitted news photo. Wire services (AP, Reuters, AFP, EPA) still
    // use these for binary photo distribution. Most fields are uint8 or uint16u
    // because they encode codepoints from CCSDS / ISO color-space tables.

    public static let newsPhotoVersion       = IPTCTag(record: 3, dataSet: 0)
    public static let iptcPictureNumber      = IPTCTag(record: 3, dataSet: 10)
    public static let iptcImageWidth         = IPTCTag(record: 3, dataSet: 20)
    public static let iptcImageHeight        = IPTCTag(record: 3, dataSet: 30)
    public static let iptcPixelWidth         = IPTCTag(record: 3, dataSet: 40)
    public static let iptcPixelHeight        = IPTCTag(record: 3, dataSet: 50)
    public static let supplementalType       = IPTCTag(record: 3, dataSet: 55)
    public static let colorRepresentation    = IPTCTag(record: 3, dataSet: 60)
    public static let interchangeColorSpace  = IPTCTag(record: 3, dataSet: 64)
    public static let colorSequence          = IPTCTag(record: 3, dataSet: 65)
    public static let iccProfile             = IPTCTag(record: 3, dataSet: 66)
    public static let colorCalibrationMatrix = IPTCTag(record: 3, dataSet: 70)
    public static let lookupTable            = IPTCTag(record: 3, dataSet: 80)
    public static let numIndexEntries        = IPTCTag(record: 3, dataSet: 84)
    public static let colorPalette           = IPTCTag(record: 3, dataSet: 85)
    public static let iptcBitsPerSample      = IPTCTag(record: 3, dataSet: 86)
    public static let sampleStructure        = IPTCTag(record: 3, dataSet: 90)
    public static let scanningDirection      = IPTCTag(record: 3, dataSet: 100)
    public static let iptcImageRotation      = IPTCTag(record: 3, dataSet: 102)
    public static let dataCompressionMethod  = IPTCTag(record: 3, dataSet: 110)
    public static let quantizationMethod     = IPTCTag(record: 3, dataSet: 120)
    public static let endPoints              = IPTCTag(record: 3, dataSet: 125)
    public static let excursionTolerance     = IPTCTag(record: 3, dataSet: 130)
    public static let bitsPerComponent       = IPTCTag(record: 3, dataSet: 135)
    public static let maximumDensityRange    = IPTCTag(record: 3, dataSet: 140)
    public static let gammaCompensatedValue  = IPTCTag(record: 3, dataSet: 145)

    // MARK: - Record 6 Tags (Pre-ObjectData Descriptor)
    //
    // Wraps the ObjectData (Record 7) — the carrier record for the actual
    // photo bytes in IIM transmissions. Only one field is defined.

    public static let subfile                = IPTCTag(record: 6, dataSet: 10)

    // MARK: - Record 7 Tags (ObjectData)
    //
    // Carries the actual binary content (preview JPEG, or full image) inside
    // an IIM stream. Used by wire services and NewsML legacy tooling.

    public static let objectDataPreviewFileFormat        = IPTCTag(record: 7, dataSet: 10)
    public static let objectDataPreviewFileFormatVersion = IPTCTag(record: 7, dataSet: 20)
    public static let objectDataPreviewData              = IPTCTag(record: 7, dataSet: 30)

    // MARK: - Record 8 Tags (Post-ObjectData Descriptor)
    //
    // Trailer record after Record 7. ConfirmedDataSize lets receivers
    // sanity-check that no bytes were truncated in transit.

    public static let confirmedDataSize      = IPTCTag(record: 8, dataSet: 10)

    // MARK: - Name Lookup

    /// Find an IPTC tag by its metadata name (e.g. "Headline", "By-line", "Keywords").
    public static func byName(_ name: String) -> IPTCTag? {
        metadata.first { $0.value.name == name }?.key
    }

    // MARK: - Tag Metadata

    struct TagMetadata {
        let name: String
        let maxLength: Int?
        let isRepeatable: Bool
        let dataType: IPTCDataType
    }

    static let metadata: [IPTCTag: TagMetadata] = [
        // Record 1
        .envelopeRecordVersion:     TagMetadata(name: "EnvelopeRecordVersion", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .codedCharacterSet:         TagMetadata(name: "CodedCharacterSet", maxLength: 32, isRepeatable: false, dataType: .binary),

        // Record 2
        .applicationRecordVersion:  TagMetadata(name: "ApplicationRecordVersion", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .objectTypeReference:       TagMetadata(name: "ObjectTypeReference", maxLength: 67, isRepeatable: false, dataType: .string),
        .objectAttributeReference:  TagMetadata(name: "ObjectAttributeReference", maxLength: 68, isRepeatable: true, dataType: .string),
        .objectName:                TagMetadata(name: "ObjectName", maxLength: 64, isRepeatable: false, dataType: .string),
        .editStatus:                TagMetadata(name: "EditStatus", maxLength: 64, isRepeatable: false, dataType: .string),
        .editorialUpdate:           TagMetadata(name: "EditorialUpdate", maxLength: 2, isRepeatable: false, dataType: .digits),
        .urgency:                   TagMetadata(name: "Urgency", maxLength: 1, isRepeatable: false, dataType: .digits),
        .subjectReference:          TagMetadata(name: "SubjectReference", maxLength: 236, isRepeatable: true, dataType: .string),
        .category:                  TagMetadata(name: "Category", maxLength: 3, isRepeatable: false, dataType: .string),
        .supplementalCategories:    TagMetadata(name: "SupplementalCategories", maxLength: 32, isRepeatable: true, dataType: .string),
        .fixtureIdentifier:         TagMetadata(name: "FixtureIdentifier", maxLength: 32, isRepeatable: false, dataType: .string),
        .keywords:                  TagMetadata(name: "Keywords", maxLength: 64, isRepeatable: true, dataType: .string),
        .contentLocationCode:       TagMetadata(name: "ContentLocationCode", maxLength: 3, isRepeatable: true, dataType: .string),
        .contentLocationName:       TagMetadata(name: "ContentLocationName", maxLength: 64, isRepeatable: true, dataType: .string),
        .releaseDate:               TagMetadata(name: "ReleaseDate", maxLength: 8, isRepeatable: false, dataType: .digits),
        .releaseTime:               TagMetadata(name: "ReleaseTime", maxLength: 11, isRepeatable: false, dataType: .string),
        .expirationDate:            TagMetadata(name: "ExpirationDate", maxLength: 8, isRepeatable: false, dataType: .digits),
        .expirationTime:            TagMetadata(name: "ExpirationTime", maxLength: 11, isRepeatable: false, dataType: .string),
        .specialInstructions:       TagMetadata(name: "SpecialInstructions", maxLength: 256, isRepeatable: false, dataType: .string),
        .actionAdvised:             TagMetadata(name: "ActionAdvised", maxLength: 2, isRepeatable: false, dataType: .digits),
        .referenceService:          TagMetadata(name: "ReferenceService", maxLength: 10, isRepeatable: true, dataType: .string),
        .referenceDate:             TagMetadata(name: "ReferenceDate", maxLength: 8, isRepeatable: true, dataType: .digits),
        .referenceNumber:           TagMetadata(name: "ReferenceNumber", maxLength: 8, isRepeatable: true, dataType: .digits),
        .dateCreated:               TagMetadata(name: "DateCreated", maxLength: 8, isRepeatable: false, dataType: .digits),
        .timeCreated:               TagMetadata(name: "TimeCreated", maxLength: 11, isRepeatable: false, dataType: .string),
        .digitalCreationDate:       TagMetadata(name: "DigitalCreationDate", maxLength: 8, isRepeatable: false, dataType: .digits),
        .digitalCreationTime:       TagMetadata(name: "DigitalCreationTime", maxLength: 11, isRepeatable: false, dataType: .string),
        .originatingProgram:        TagMetadata(name: "OriginatingProgram", maxLength: 32, isRepeatable: false, dataType: .string),
        .programVersion:            TagMetadata(name: "ProgramVersion", maxLength: 10, isRepeatable: false, dataType: .string),
        .objectCycle:               TagMetadata(name: "ObjectCycle", maxLength: 1, isRepeatable: false, dataType: .string),
        .byline:                    TagMetadata(name: "By-line", maxLength: 32, isRepeatable: true, dataType: .string),
        .bylineTitle:               TagMetadata(name: "By-lineTitle", maxLength: 32, isRepeatable: true, dataType: .string),
        .city:                      TagMetadata(name: "City", maxLength: 32, isRepeatable: false, dataType: .string),
        .sublocation:               TagMetadata(name: "Sub-location", maxLength: 32, isRepeatable: false, dataType: .string),
        .provinceState:             TagMetadata(name: "Province-State", maxLength: 32, isRepeatable: false, dataType: .string),
        .countryPrimaryLocationCode:TagMetadata(name: "Country-PrimaryLocationCode", maxLength: 3, isRepeatable: false, dataType: .string),
        .countryPrimaryLocationName:TagMetadata(name: "Country-PrimaryLocationName", maxLength: 64, isRepeatable: false, dataType: .string),
        .originalTransmissionReference: TagMetadata(name: "OriginalTransmissionReference", maxLength: 32, isRepeatable: false, dataType: .string),
        .headline:                  TagMetadata(name: "Headline", maxLength: 256, isRepeatable: false, dataType: .string),
        .credit:                    TagMetadata(name: "Credit", maxLength: 32, isRepeatable: false, dataType: .string),
        .source:                    TagMetadata(name: "Source", maxLength: 32, isRepeatable: false, dataType: .string),
        .copyrightNotice:           TagMetadata(name: "CopyrightNotice", maxLength: 128, isRepeatable: false, dataType: .string),
        .contact:                   TagMetadata(name: "Contact", maxLength: 128, isRepeatable: true, dataType: .string),
        .captionAbstract:           TagMetadata(name: "Caption-Abstract", maxLength: 2000, isRepeatable: false, dataType: .string),
        .writerEditor:              TagMetadata(name: "Writer-Editor", maxLength: 32, isRepeatable: true, dataType: .string),
        .languageIdentifier:        TagMetadata(name: "LanguageIdentifier", maxLength: 3, isRepeatable: false, dataType: .string),

        // Record 3 (News Photo)
        .newsPhotoVersion:          TagMetadata(name: "NewsPhotoVersion", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .iptcPictureNumber:         TagMetadata(name: "IPTCPictureNumber", maxLength: 16, isRepeatable: false, dataType: .string),
        .iptcImageWidth:            TagMetadata(name: "IPTCImageWidth", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .iptcImageHeight:           TagMetadata(name: "IPTCImageHeight", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .iptcPixelWidth:            TagMetadata(name: "IPTCPixelWidth", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .iptcPixelHeight:           TagMetadata(name: "IPTCPixelHeight", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .supplementalType:          TagMetadata(name: "SupplementalType", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .colorRepresentation:       TagMetadata(name: "ColorRepresentation", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .interchangeColorSpace:     TagMetadata(name: "InterchangeColorSpace", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .colorSequence:             TagMetadata(name: "ColorSequence", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .iccProfile:                TagMetadata(name: "ICC_Profile", maxLength: nil, isRepeatable: false, dataType: .binary),
        .colorCalibrationMatrix:    TagMetadata(name: "ColorCalibrationMatrix", maxLength: nil, isRepeatable: false, dataType: .binary),
        .lookupTable:               TagMetadata(name: "LookupTable", maxLength: nil, isRepeatable: false, dataType: .binary),
        .numIndexEntries:           TagMetadata(name: "NumIndexEntries", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .colorPalette:              TagMetadata(name: "ColorPalette", maxLength: nil, isRepeatable: false, dataType: .binary),
        .iptcBitsPerSample:         TagMetadata(name: "IPTCBitsPerSample", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .sampleStructure:           TagMetadata(name: "SampleStructure", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .scanningDirection:         TagMetadata(name: "ScanningDirection", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .iptcImageRotation:         TagMetadata(name: "IPTCImageRotation", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .dataCompressionMethod:     TagMetadata(name: "DataCompressionMethod", maxLength: 4, isRepeatable: false, dataType: .int32u),
        .quantizationMethod:        TagMetadata(name: "QuantizationMethod", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .endPoints:                 TagMetadata(name: "EndPoints", maxLength: nil, isRepeatable: false, dataType: .binary),
        .excursionTolerance:        TagMetadata(name: "ExcursionTolerance", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .bitsPerComponent:          TagMetadata(name: "BitsPerComponent", maxLength: 1, isRepeatable: false, dataType: .int8u),
        .maximumDensityRange:       TagMetadata(name: "MaximumDensityRange", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .gammaCompensatedValue:     TagMetadata(name: "GammaCompensatedValue", maxLength: 2, isRepeatable: false, dataType: .int16u),

        // Record 6 (Pre-ObjectData Descriptor)
        .subfile:                   TagMetadata(name: "Subfile", maxLength: nil, isRepeatable: true, dataType: .binary),

        // Record 7 (ObjectData)
        .objectDataPreviewFileFormat:        TagMetadata(name: "ObjectPreviewFileFormat", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .objectDataPreviewFileFormatVersion: TagMetadata(name: "ObjectPreviewFileVersion", maxLength: 2, isRepeatable: false, dataType: .int16u),
        .objectDataPreviewData:              TagMetadata(name: "ObjectPreviewData", maxLength: 256_000, isRepeatable: false, dataType: .binary),

        // Record 8 (Post-ObjectData Descriptor)
        .confirmedDataSize:         TagMetadata(name: "ConfirmedObjectSize", maxLength: 4, isRepeatable: false, dataType: .int32u),
    ]
}

public enum IPTCDataType: Sendable {
    case string    // Text string
    case digits    // Numeric characters only
    case int8u     // 1-byte unsigned integer
    case int16u    // 2-byte unsigned integer (big-endian)
    case int32u    // 4-byte unsigned integer (big-endian)
    case binary    // Raw bytes
}
