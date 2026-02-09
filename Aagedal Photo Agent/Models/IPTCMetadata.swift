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
    var hasSettings: Bool?
    var crop: CameraRawCrop?

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
            && hasSettings == nil
            && (crop?.isEmpty ?? true)
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
        if let value = override.hasSettings { result.hasSettings = value }
        if let crop = override.crop {
            if let existing = result.crop {
                result.crop = existing.merged(preferring: crop)
            } else {
                result.crop = crop
            }
        }
        return result
    }
}

extension CameraRawCrop {
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
        cameraRaw: CameraRawSettings? = nil
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
