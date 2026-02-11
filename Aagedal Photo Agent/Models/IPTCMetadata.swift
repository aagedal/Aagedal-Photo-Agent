import Foundation

struct CameraRawCrop: Codable, Sendable, Equatable {
    var top: Double?
    var left: Double?
    var bottom: Double?
    var right: Double?
    var angle: Double?
    var hasCrop: Bool?

    var isEmpty: Bool {
        top == nil
            && left == nil
            && bottom == nil
            && right == nil
            && angle == nil
            && hasCrop == nil
    }
}

struct CameraRawSettings: Codable, Sendable, Equatable {
    var version: String?
    var processVersion: String?
    var whiteBalance: String?
    var temperature: Int?
    var tint: Int?
    var incrementalTemperature: Int?
    var incrementalTint: Int?
    var exposure2012: Double?
    var contrast2012: Int?
    var highlights2012: Int?
    var shadows2012: Int?
    var whites2012: Int?
    var blacks2012: Int?
    var saturation: Int?
    var vibrance: Int?
    var hasSettings: Bool?
    var crop: CameraRawCrop?
    var hdrEditMode: Int?

    var isEmpty: Bool {
        version == nil
            && processVersion == nil
            && whiteBalance == nil
            && temperature == nil
            && tint == nil
            && incrementalTemperature == nil
            && incrementalTint == nil
            && exposure2012 == nil
            && contrast2012 == nil
            && highlights2012 == nil
            && shadows2012 == nil
            && whites2012 == nil
            && blacks2012 == nil
            && saturation == nil
            && vibrance == nil
            && hasSettings == nil
            && (crop?.isEmpty ?? true)
            && hdrEditMode == nil
    }

    func merged(preferring override: CameraRawSettings) -> CameraRawSettings {
        var result = self
        if let value = override.version, !value.isEmpty { result.version = value }
        if let value = override.processVersion, !value.isEmpty { result.processVersion = value }
        if let value = override.whiteBalance, !value.isEmpty { result.whiteBalance = value }
        if let value = override.temperature { result.temperature = value }
        if let value = override.tint { result.tint = value }
        if let value = override.incrementalTemperature { result.incrementalTemperature = value }
        if let value = override.incrementalTint { result.incrementalTint = value }
        if let value = override.exposure2012 { result.exposure2012 = value }
        if let value = override.contrast2012 { result.contrast2012 = value }
        if let value = override.highlights2012 { result.highlights2012 = value }
        if let value = override.shadows2012 { result.shadows2012 = value }
        if let value = override.whites2012 { result.whites2012 = value }
        if let value = override.blacks2012 { result.blacks2012 = value }
        if let value = override.saturation { result.saturation = value }
        if let value = override.vibrance { result.vibrance = value }
        if let value = override.hasSettings { result.hasSettings = value }
        if let crop = override.crop {
            if let existing = result.crop {
                result.crop = existing.merged(preferring: crop)
            } else {
                result.crop = crop
            }
        }
        if let value = override.hdrEditMode { result.hdrEditMode = value }
        return result
    }
}

extension CameraRawCrop {
    /// Transform crop from sensor (XMP) orientation to display orientation.
    nonisolated func transformedForDisplay(orientation: Int) -> CameraRawCrop {
        let t = top ?? 0, l = left ?? 0, b = bottom ?? 1, r = right ?? 1
        let (dt, dl, db, dr): (Double, Double, Double, Double)
        switch orientation {
        case 2: (dt, dl, db, dr) = (t, 1-r, b, 1-l)       // flip horizontal
        case 3: (dt, dl, db, dr) = (1-b, 1-r, 1-t, 1-l)   // rotate 180°
        case 4: (dt, dl, db, dr) = (1-b, l, 1-t, r)        // flip vertical
        case 5: (dt, dl, db, dr) = (l, t, r, b)             // transpose
        case 6: (dt, dl, db, dr) = (l, 1-b, r, 1-t)        // rotate 90° CW
        case 7: (dt, dl, db, dr) = (1-r, 1-b, 1-l, 1-t)    // transverse
        case 8: (dt, dl, db, dr) = (1-r, t, 1-l, b)         // rotate 90° CCW
        default: return self                                  // O=1 or unknown
        }
        return CameraRawCrop(top: dt, left: dl, bottom: db, right: dr, angle: angle, hasCrop: hasCrop)
    }

    /// Inverse: transform crop from display orientation back to sensor (XMP) orientation.
    nonisolated func transformedForSensor(orientation: Int) -> CameraRawCrop {
        let t = top ?? 0, l = left ?? 0, b = bottom ?? 1, r = right ?? 1
        let (st, sl, sb, sr): (Double, Double, Double, Double)
        switch orientation {
        case 2: (st, sl, sb, sr) = (t, 1-r, b, 1-l)       // flip H is self-inverse
        case 3: (st, sl, sb, sr) = (1-b, 1-r, 1-t, 1-l)   // 180° is self-inverse
        case 4: (st, sl, sb, sr) = (1-b, l, 1-t, r)        // flip V is self-inverse
        case 5: (st, sl, sb, sr) = (l, t, r, b)             // transpose is self-inverse
        case 6: (st, sl, sb, sr) = (1-l, t, 1-r, b)        // inverse of 90° CW = 90° CCW
        case 7: (st, sl, sb, sr) = (1-r, 1-b, 1-l, 1-t)    // transverse is self-inverse
        case 8: (st, sl, sb, sr) = (l, 1-b, r, 1-t)        // inverse of 90° CCW = 90° CW
        default: return self
        }
        return CameraRawCrop(top: st, left: sl, bottom: sb, right: sr, angle: angle, hasCrop: hasCrop)
    }

    func merged(preferring override: CameraRawCrop) -> CameraRawCrop {
        var result = self
        if let value = override.top { result.top = value }
        if let value = override.left { result.left = value }
        if let value = override.bottom { result.bottom = value }
        if let value = override.right { result.right = value }
        if let value = override.angle { result.angle = value }
        if let value = override.hasCrop { result.hasCrop = value }
        return result
    }
}

struct IPTCMetadata: Codable, Sendable, Equatable {
    // Priority fields (always visible)
    var title: String?
    var description: String?
    var extendedDescription: String?
    var keywords: [String]
    var personShown: [String]

    // Classification
    var digitalSourceType: DigitalSourceType?

    // Secondary fields (collapsible)
    var creator: String?
    var credit: String?
    var copyright: String?
    var jobId: String?
    var dateCreated: String?
    var captureDate: String?
    var city: String?
    var country: String?
    var event: String?

    // GPS
    var latitude: Double?
    var longitude: Double?

    // XMP managed alongside
    var rating: Int?
    var label: String?
    var cameraRaw: CameraRawSettings?
    var exifOrientation: Int?

    init(
        title: String? = nil,
        description: String? = nil,
        extendedDescription: String? = nil,
        keywords: [String] = [],
        personShown: [String] = [],
        digitalSourceType: DigitalSourceType? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        creator: String? = nil,
        credit: String? = nil,
        copyright: String? = nil,
        jobId: String? = nil,
        dateCreated: String? = nil,
        captureDate: String? = nil,
        city: String? = nil,
        country: String? = nil,
        event: String? = nil,
        rating: Int? = nil,
        label: String? = nil,
        cameraRaw: CameraRawSettings? = nil,
        exifOrientation: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.extendedDescription = extendedDescription
        self.keywords = keywords
        self.personShown = personShown
        self.digitalSourceType = digitalSourceType
        self.latitude = latitude
        self.longitude = longitude
        self.creator = creator
        self.credit = credit
        self.copyright = copyright
        self.jobId = jobId
        self.dateCreated = dateCreated
        self.captureDate = captureDate
        self.city = city
        self.country = country
        self.event = event
        self.rating = rating
        self.label = label
        self.cameraRaw = cameraRaw
        self.exifOrientation = exifOrientation
    }
}

extension IPTCMetadata {
    func merged(preferring override: IPTCMetadata) -> IPTCMetadata {
        var result = self

        if let value = override.title, !value.isEmpty { result.title = value }
        if let value = override.description, !value.isEmpty { result.description = value }
        if let value = override.extendedDescription, !value.isEmpty { result.extendedDescription = value }
        if !override.keywords.isEmpty { result.keywords = override.keywords }
        if !override.personShown.isEmpty { result.personShown = override.personShown }
        if let value = override.digitalSourceType { result.digitalSourceType = value }
        if let value = override.creator, !value.isEmpty { result.creator = value }
        if let value = override.credit, !value.isEmpty { result.credit = value }
        if let value = override.copyright, !value.isEmpty { result.copyright = value }
        if let value = override.jobId, !value.isEmpty { result.jobId = value }
        if let value = override.dateCreated, !value.isEmpty { result.dateCreated = value }
        if let value = override.captureDate, !value.isEmpty { result.captureDate = value }
        if let value = override.city, !value.isEmpty { result.city = value }
        if let value = override.country, !value.isEmpty { result.country = value }
        if let value = override.event, !value.isEmpty { result.event = value }
        if let value = override.latitude { result.latitude = value }
        if let value = override.longitude { result.longitude = value }
        if let value = override.rating { result.rating = value }
        if let value = override.label, !value.isEmpty { result.label = value }
        if let value = override.cameraRaw {
            if let existing = result.cameraRaw {
                result.cameraRaw = existing.merged(preferring: value)
            } else {
                result.cameraRaw = value
            }
        }
        if let value = override.exifOrientation { result.exifOrientation = value }

        return result
    }
}

enum DigitalSourceType: String, Codable, CaseIterable, Sendable {
    case trainedAlgorithmicMedia = "trainedAlgorithmicMedia"
    case digitalCapture = "digitalCapture"
    case negativeFilm = "negativeFilm"
    case positiveFilm = "positiveFilm"
    case print = "print"
    case compositeCapture = "compositeCapture"
    case compositeSynthetic = "compositeSynthetic"
    case compositeWithTrainedAlgorithmicMedia = "compositeWithTrainedAlgorithmicMedia"

    var displayName: String {
        switch self {
        case .trainedAlgorithmicMedia: return "AI-Generated"
        case .digitalCapture: return "Digital Capture"
        case .negativeFilm: return "Scanned Negative"
        case .positiveFilm: return "Scanned Positive"
        case .print: return "Scanned Print"
        case .compositeCapture: return "Composite (Capture)"
        case .compositeSynthetic: return "Composite (Synthetic)"
        case .compositeWithTrainedAlgorithmicMedia: return "Composite (AI)"
        }
    }
}
