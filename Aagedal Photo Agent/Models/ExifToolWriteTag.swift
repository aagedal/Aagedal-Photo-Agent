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
