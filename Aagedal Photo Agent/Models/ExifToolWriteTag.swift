import Foundation

enum ExifToolWriteTag {
    // MARK: - XMP IPTC / Photoshop
    static let headline = "XMP-photoshop:Headline"
    static let description = "XMP:Description"
    static let extendedDescription = "XMP-iptcCore:ExtDescrAccessibility"
    static let subject = "XMP:Subject"
    static let personInImage = "XMP-iptcExt:PersonInImage"
    static let digitalSourceType = "XMP-iptcExt:DigitalSourceType"
    static let creator = "XMP:Creator"
    static let credit = "XMP-photoshop:Credit"
    static let rights = "XMP:Rights"
    static let transmissionReference = "XMP-photoshop:TransmissionReference"
    static let dateCreated = "XMP:DateCreated"
    static let city = "XMP-photoshop:City"
    static let country = "XMP-photoshop:Country"
    static let event = "XMP-iptcExt:Event"

    // MARK: - EXIF GPS
    static let gpsLatitude = "EXIF:GPSLatitude"
    static let gpsLatitudeRef = "EXIF:GPSLatitudeRef"
    static let gpsLongitude = "EXIF:GPSLongitude"
    static let gpsLongitudeRef = "EXIF:GPSLongitudeRef"

    // MARK: - XMP Rating & Label
    static let rating = "XMP:Rating"
    static let label = "XMP:Label"

    // MARK: - Camera Raw (crs)
    static let crsVersion = "XMP-crs:Version"
    static let crsProcessVersion = "XMP-crs:ProcessVersion"
    static let crsWhiteBalance = "XMP-crs:WhiteBalance"
    static let crsTemperature = "XMP-crs:Temperature"
    static let crsTint = "XMP-crs:Tint"
    static let crsIncrementalTemperature = "XMP-crs:IncrementalTemperature"
    static let crsIncrementalTint = "XMP-crs:IncrementalTint"
    static let crsExposure2012 = "XMP-crs:Exposure2012"
    static let crsContrast2012 = "XMP-crs:Contrast2012"
    static let crsHighlights2012 = "XMP-crs:Highlights2012"
    static let crsShadows2012 = "XMP-crs:Shadows2012"
    static let crsWhites2012 = "XMP-crs:Whites2012"
    static let crsBlacks2012 = "XMP-crs:Blacks2012"
    static let crsHasSettings = "XMP-crs:HasSettings"
    static let crsCropTop = "XMP-crs:CropTop"
    static let crsCropLeft = "XMP-crs:CropLeft"
    static let crsCropBottom = "XMP-crs:CropBottom"
    static let crsCropRight = "XMP-crs:CropRight"
    static let crsCropAngle = "XMP-crs:CropAngle"
    static let crsHasCrop = "XMP-crs:HasCrop"
    static let crsCropConstrainToWarp = "XMP-crs:CropConstrainToWarp"
    static let crsCropConstrainToUnitSquare = "XMP-crs:CropConstrainToUnitSquare"
    static let crsHDREditMode = "XMP-crs:HDREditMode"

    // MARK: - IPTC Mirrors (for cross-tool interoperability)
    static let iptcKeywords = "IPTC:Keywords"
    static let iptcCopyrightNotice = "IPTC:CopyrightNotice"
    static let iptcHeadline = "IPTC:Headline"
    static let iptcByLine = "IPTC:By-line"
    static let iptcOriginalTransmissionReference = "IPTC:OriginalTransmissionReference"
    static let iptcJobID = "IPTC:JobID"

    // MARK: - XMP Title (alias)
    static let xmpTitle = "XMP:Title"
}
