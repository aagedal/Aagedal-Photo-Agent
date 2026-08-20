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
    case organisationInImageName
    case organisationInImageCode
    case digitalSourceType
    case urgency
    case creator
    case creatorJobTitle
    case descriptionWriter
    case credit
    case rights
    case rightsUsageTerms
    case webStatementOfRights
    case transmissionReference
    case dateCreated
    case city
    case sublocation
    case provinceState
    case country
    case countryCode
    case event
    case instructions
    case source

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
    case crsSharpness
    case crsClarity2012
    case crsDehaze
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
    case aaphotoGlobalDensity
    case aaphotoFilmGrain
    case aaphotoFilmGrainCoarseness
    case aaphotoFilmHalation
    case aaphotoFilmBloom
    case aaphotoFilmVignette
    case aaphotoFilmEdgeBlur

    /// True for develop-settings keys managed with the Camera Raw block.
    nonisolated var isCameraRawField: Bool {
        rawValue.hasPrefix("crs") || rawValue.hasPrefix("aaphoto")
    }
}
