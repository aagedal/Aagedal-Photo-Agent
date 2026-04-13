import Foundation

/// Type-safe keys for metadata write fields.
/// Each case maps to a specific IPTC, XMP, or EXIF tag that write engines know how to handle.
enum MetadataFieldKey: String, Sendable, CaseIterable {
    // MARK: - IPTC / Photoshop
    case headline
    case description
    case extendedDescription
    case subject
    case personInImage
    case digitalSourceType
    case creator
    case credit
    case rights
    case transmissionReference
    case dateCreated
    case city
    case country
    case event

    // MARK: - GPS
    case gpsLatitude
    case gpsLatitudeRef
    case gpsLongitude
    case gpsLongitudeRef

    // MARK: - XMP Rating & Label
    case rating
    case label
    case xmpTitle

    // MARK: - EXIF
    case orientation

    // MARK: - Camera Raw (simple values)
    case crsVersion
    case crsProcessVersion
    case crsWhiteBalance
    case crsTemperature
    case crsTint
    case crsIncrementalTemperature
    case crsIncrementalTint
    case crsExposure2012
    case crsContrast2012
    case crsHighlights2012
    case crsShadows2012
    case crsWhites2012
    case crsBlacks2012
    case crsSaturation
    case crsVibrance
    case crsHasSettings
    case crsCropTop
    case crsCropLeft
    case crsCropBottom
    case crsCropRight
    case crsCropAngle
    case crsHasCrop
    case crsCropConstrainToWarp
    case crsCropConstrainToUnitSquare
    case crsHDREditMode
    case crsHDRMaxValue
    case crsSDRBrightness
    case crsSDRContrast
    case crsSDRClarity
    case crsSDRHighlights
    case crsSDRShadows
    case crsSDRWhites
    case crsSDRBlend
    case crsToneCurveName2012

    /// The ExifTool tag string for this field key.
    var exifToolTag: String {
        switch self {
        case .headline: return ExifToolWriteTag.headline
        case .description: return ExifToolWriteTag.description
        case .extendedDescription: return ExifToolWriteTag.extendedDescription
        case .subject: return ExifToolWriteTag.subject
        case .personInImage: return ExifToolWriteTag.personInImage
        case .digitalSourceType: return ExifToolWriteTag.digitalSourceType
        case .creator: return ExifToolWriteTag.creator
        case .credit: return ExifToolWriteTag.credit
        case .rights: return ExifToolWriteTag.rights
        case .transmissionReference: return ExifToolWriteTag.transmissionReference
        case .dateCreated: return ExifToolWriteTag.dateCreated
        case .city: return ExifToolWriteTag.city
        case .country: return ExifToolWriteTag.country
        case .event: return ExifToolWriteTag.event
        case .gpsLatitude: return ExifToolWriteTag.gpsLatitude
        case .gpsLatitudeRef: return ExifToolWriteTag.gpsLatitudeRef
        case .gpsLongitude: return ExifToolWriteTag.gpsLongitude
        case .gpsLongitudeRef: return ExifToolWriteTag.gpsLongitudeRef
        case .rating: return ExifToolWriteTag.rating
        case .label: return ExifToolWriteTag.label
        case .xmpTitle: return ExifToolWriteTag.xmpTitle
        case .orientation: return ExifToolWriteTag.orientation
        case .crsVersion: return ExifToolWriteTag.crsVersion
        case .crsProcessVersion: return ExifToolWriteTag.crsProcessVersion
        case .crsWhiteBalance: return ExifToolWriteTag.crsWhiteBalance
        case .crsTemperature: return ExifToolWriteTag.crsTemperature
        case .crsTint: return ExifToolWriteTag.crsTint
        case .crsIncrementalTemperature: return ExifToolWriteTag.crsIncrementalTemperature
        case .crsIncrementalTint: return ExifToolWriteTag.crsIncrementalTint
        case .crsExposure2012: return ExifToolWriteTag.crsExposure2012
        case .crsContrast2012: return ExifToolWriteTag.crsContrast2012
        case .crsHighlights2012: return ExifToolWriteTag.crsHighlights2012
        case .crsShadows2012: return ExifToolWriteTag.crsShadows2012
        case .crsWhites2012: return ExifToolWriteTag.crsWhites2012
        case .crsBlacks2012: return ExifToolWriteTag.crsBlacks2012
        case .crsSaturation: return ExifToolWriteTag.crsSaturation
        case .crsVibrance: return ExifToolWriteTag.crsVibrance
        case .crsHasSettings: return ExifToolWriteTag.crsHasSettings
        case .crsCropTop: return ExifToolWriteTag.crsCropTop
        case .crsCropLeft: return ExifToolWriteTag.crsCropLeft
        case .crsCropBottom: return ExifToolWriteTag.crsCropBottom
        case .crsCropRight: return ExifToolWriteTag.crsCropRight
        case .crsCropAngle: return ExifToolWriteTag.crsCropAngle
        case .crsHasCrop: return ExifToolWriteTag.crsHasCrop
        case .crsCropConstrainToWarp: return ExifToolWriteTag.crsCropConstrainToWarp
        case .crsCropConstrainToUnitSquare: return ExifToolWriteTag.crsCropConstrainToUnitSquare
        case .crsHDREditMode: return ExifToolWriteTag.crsHDREditMode
        case .crsHDRMaxValue: return ExifToolWriteTag.crsHDRMaxValue
        case .crsSDRBrightness: return ExifToolWriteTag.crsSDRBrightness
        case .crsSDRContrast: return ExifToolWriteTag.crsSDRContrast
        case .crsSDRClarity: return ExifToolWriteTag.crsSDRClarity
        case .crsSDRHighlights: return ExifToolWriteTag.crsSDRHighlights
        case .crsSDRShadows: return ExifToolWriteTag.crsSDRShadows
        case .crsSDRWhites: return ExifToolWriteTag.crsSDRWhites
        case .crsSDRBlend: return ExifToolWriteTag.crsSDRBlend
        case .crsToneCurveName2012: return ExifToolWriteTag.crsToneCurveName2012
        }
    }

    /// Reverse lookup from ExifTool tag string to MetadataFieldKey.
    private static let tagToKey: [String: MetadataFieldKey] = {
        var map: [String: MetadataFieldKey] = [:]
        for key in MetadataFieldKey.allCases {
            map[key.exifToolTag] = key
        }
        return map
    }()

    init?(exifToolTag: String) {
        guard let key = Self.tagToKey[exifToolTag] else { return nil }
        self = key
    }
}
