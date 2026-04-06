import Foundation

nonisolated struct ToneCurvePoint: Codable, Sendable, Equatable {
    var x: Double  // 0-1 input brightness
    var y: Double  // 0-1 output brightness
}

nonisolated struct ToneCurve: Codable, Sendable, Equatable {
    var master: [ToneCurvePoint]?
    var red: [ToneCurvePoint]?
    var green: [ToneCurvePoint]?
    var blue: [ToneCurvePoint]?

    var isEmpty: Bool {
        (master?.count ?? 0) <= 2
            && red == nil
            && green == nil
            && blue == nil
    }
}

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

struct EllipseMaskGeometry: Codable, Sendable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radiusX: Double = 0.15
    var radiusY: Double = 0.10
    var rotation: Double = 0
    var feather: Double = 50
}

struct MaskAdjustment: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Mask 1"
    var enabled: Bool = true
    var inverted: Bool = false
    var amount: Double = 1.0
    var geometry: EllipseMaskGeometry = EllipseMaskGeometry()

    var exposure: Double?
    var contrast: Int?
    var highlights: Int?
    var shadows: Int?
    var whites: Int?
    var blacks: Int?
    var saturation: Int?
    var vibrance: Int?
    var temperature: Double?
    var tint: Double?

    var hasAdjustments: Bool {
        exposure != nil || contrast != nil || highlights != nil
            || shadows != nil || whites != nil || blacks != nil
            || saturation != nil || vibrance != nil
            || temperature != nil || tint != nil
    }
}

struct HSLColorAdjustment: Codable, Sendable, Equatable {
    var saturation: Int?    // -100..+100
    var luminance: Int?     // -100..+100 ("Density" in UI)
    var hueShift: Int?      // -100..+100 (maps to ±30°)

    nonisolated var isEmpty: Bool {
        (saturation ?? 0) == 0 && (luminance ?? 0) == 0 && (hueShift ?? 0) == 0
    }
}

struct HSLAdjustments: Codable, Sendable, Equatable {
    var red: HSLColorAdjustment?
    var yellow: HSLColorAdjustment?
    var green: HSLColorAdjustment?
    var cyan: HSLColorAdjustment?
    var blue: HSLColorAdjustment?
    var magenta: HSLColorAdjustment?
    var skinTone: HSLColorAdjustment?

    nonisolated var isEmpty: Bool {
        (red?.isEmpty ?? true) && (yellow?.isEmpty ?? true)
            && (green?.isEmpty ?? true) && (cyan?.isEmpty ?? true)
            && (blue?.isEmpty ?? true) && (magenta?.isEmpty ?? true)
            && (skinTone?.isEmpty ?? true)
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
    var hdrMaxValue: String?
    var sdrBrightness: Int?
    var sdrContrast: Int?
    var sdrClarity: Int?
    var sdrHighlights: Int?
    var sdrShadows: Int?
    var sdrWhites: Int?
    var sdrBlend: Int?
    var toneCurve: ToneCurve?
    var localAdjustments: [MaskAdjustment]?
    var hslAdjustments: HSLAdjustments?

    /// As-shot neutral white balance from the RAW decoder (CIRAWFilter.neutralTemperature/Tint).
    /// Used as the reference point for white balance correction in renderOffscreen().
    /// Per-image metadata — excluded from isEmpty, merged(), and paste operations.
    var asShotNeutralTemperature: Double?
    var asShotNeutralTint: Double?

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
            && hdrMaxValue == nil
            && sdrBrightness == nil
            && sdrContrast == nil
            && sdrClarity == nil
            && sdrHighlights == nil
            && sdrShadows == nil
            && sdrWhites == nil
            && sdrBlend == nil
            && (toneCurve?.isEmpty ?? true)
            && (localAdjustments?.isEmpty ?? true)
            && (hslAdjustments?.isEmpty ?? true)
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
        if let value = override.hdrMaxValue, !value.isEmpty { result.hdrMaxValue = value }
        if let value = override.sdrBrightness { result.sdrBrightness = value }
        if let value = override.sdrContrast { result.sdrContrast = value }
        if let value = override.sdrClarity { result.sdrClarity = value }
        if let value = override.sdrHighlights { result.sdrHighlights = value }
        if let value = override.sdrShadows { result.sdrShadows = value }
        if let value = override.sdrWhites { result.sdrWhites = value }
        if let value = override.sdrBlend { result.sdrBlend = value }
        if let value = override.toneCurve { result.toneCurve = value }
        if let value = override.localAdjustments { result.localAdjustments = value }
        if let value = override.hslAdjustments { result.hslAdjustments = value }
        return result
    }
}

extension CameraRawCrop {
    /// Transform crop from sensor (XMP) orientation to display orientation.
    nonisolated func transformedForDisplay(orientation: Int) -> CameraRawCrop {
        // Normalize: Adobe XMP can store top > bottom or left > right
        let rawT = top ?? 0, rawL = left ?? 0, rawB = bottom ?? 1, rawR = right ?? 1
        let t = min(rawT, rawB), l = min(rawL, rawR), b = max(rawT, rawB), r = max(rawL, rawR)
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
        // Normalize: ensure proper coordinate ordering
        let rawT = top ?? 0, rawL = left ?? 0, rawB = bottom ?? 1, rawR = right ?? 1
        let t = min(rawT, rawB), l = min(rawL, rawR), b = max(rawT, rawB), r = max(rawL, rawR)
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

struct DescriptionConflict: Sendable {
    let xmpDescription: String
    let iptcCaptionAbstract: String
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

    // XMP managed alongside IPTC (persisted to JSON sidecar)
    var rating: Int?
    var label: String?

    // Camera raw / orientation — in-memory only, sourced from XMP, NOT persisted to JSON sidecar
    var cameraRaw: CameraRawSettings?
    var exifOrientation: Int?

    // Exclude cameraRaw and exifOrientation from JSON sidecar serialization.
    // These are sourced exclusively from XMP (embedded in image or XMP sidecar file).
    enum CodingKeys: String, CodingKey {
        case title, description, extendedDescription, keywords, personShown
        case digitalSourceType
        case creator, credit, copyright, jobId, dateCreated, captureDate
        case city, country, event
        case latitude, longitude
        case rating, label
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        extendedDescription = try container.decodeIfPresent(String.self, forKey: .extendedDescription)
        keywords = (try container.decodeIfPresent([String].self, forKey: .keywords) ?? []).uniqued()
        personShown = (try container.decodeIfPresent([String].self, forKey: .personShown) ?? []).uniqued()
        digitalSourceType = try container.decodeIfPresent(DigitalSourceType.self, forKey: .digitalSourceType)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
        jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
        dateCreated = try container.decodeIfPresent(String.self, forKey: .dateCreated)
        captureDate = try container.decodeIfPresent(String.self, forKey: .captureDate)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // cameraRaw and exifOrientation are not decoded — sourced from XMP only
    }
}

extension IPTCMetadata {
    /// Returns true if any user-facing IPTC fields differ between self and another metadata instance.
    func hasIPTCDifferences(from other: IPTCMetadata) -> Bool {
        title != other.title
            || description != other.description
            || extendedDescription != other.extendedDescription
            || keywords != other.keywords
            || personShown != other.personShown
            || digitalSourceType != other.digitalSourceType
            || creator != other.creator
            || credit != other.credit
            || copyright != other.copyright
            || jobId != other.jobId
            || city != other.city
            || country != other.country
            || event != other.event
    }

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
        // CameraRaw: prefer override (XMP) when it has data
        if let overrideCRS = override.cameraRaw, !overrideCRS.isEmpty {
            if let existingCRS = result.cameraRaw {
                result.cameraRaw = existingCRS.merged(preferring: overrideCRS)
            } else {
                result.cameraRaw = overrideCRS
            }
        }
        if let overrideOrientation = override.exifOrientation {
            result.exifOrientation = overrideOrientation
        }

        return result
    }
}

extension IPTCMetadata {
    /// Convert editable IPTC fields to an ExifTool write-tag dictionary.
    /// Excludes rating, label, cameraRaw, and orientation (managed separately).
    func toExifToolFields() -> [String: String] {
        var fields: [String: String] = [:]
        if let v = title { fields[ExifToolWriteTag.headline] = v }
        if let v = description { fields[ExifToolWriteTag.description] = v }
        if let v = extendedDescription { fields[ExifToolWriteTag.extendedDescription] = v }
        if !keywords.isEmpty { fields[ExifToolWriteTag.subject] = keywords.joined(separator: ", ") }
        if !personShown.isEmpty { fields[ExifToolWriteTag.personInImage] = personShown.joined(separator: ", ") }
        if let v = digitalSourceType { fields[ExifToolWriteTag.digitalSourceType] = v.rawValue }
        if let v = creator { fields[ExifToolWriteTag.creator] = v }
        if let v = credit { fields[ExifToolWriteTag.credit] = v }
        if let v = copyright { fields[ExifToolWriteTag.rights] = v }
        if let v = jobId { fields[ExifToolWriteTag.transmissionReference] = v }
        if let v = dateCreated { fields[ExifToolWriteTag.dateCreated] = v }
        if let v = city { fields[ExifToolWriteTag.city] = v }
        if let v = country { fields[ExifToolWriteTag.country] = v }
        if let v = event { fields[ExifToolWriteTag.event] = v }
        if let lat = latitude, let lon = longitude {
            fields[ExifToolWriteTag.gpsLatitude] = String(abs(lat))
            fields[ExifToolWriteTag.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[ExifToolWriteTag.gpsLongitude] = String(abs(lon))
            fields[ExifToolWriteTag.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        }
        return fields
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

// MARK: - Field Key (for upload metadata check)

extension IPTCMetadata {
    nonisolated enum FieldKey: String, CaseIterable, Codable, Sendable {
        case title, description, extendedDescription, keywords, personShown
        case creator, credit, copyright, jobId, dateCreated, city, country, event

        var displayName: String {
            switch self {
            case .title: return "Headline"
            case .description: return "Description"
            case .extendedDescription: return "Extended Description"
            case .keywords: return "Keywords"
            case .personShown: return "Person Shown"
            case .creator: return "Creator"
            case .credit: return "Credit"
            case .copyright: return "Copyright"
            case .jobId: return "Job ID"
            case .dateCreated: return "Date Created"
            case .city: return "City"
            case .country: return "Country"
            case .event: return "Event"
            }
        }

        func isEmpty(in metadata: IPTCMetadata) -> Bool {
            switch self {
            case .title: return metadata.title?.isEmpty ?? true
            case .description: return metadata.description?.isEmpty ?? true
            case .extendedDescription: return metadata.extendedDescription?.isEmpty ?? true
            case .keywords: return metadata.keywords.isEmpty
            case .personShown: return metadata.personShown.isEmpty
            case .creator: return metadata.creator?.isEmpty ?? true
            case .credit: return metadata.credit?.isEmpty ?? true
            case .copyright: return metadata.copyright?.isEmpty ?? true
            case .jobId: return metadata.jobId?.isEmpty ?? true
            case .dateCreated: return metadata.dateCreated?.isEmpty ?? true
            case .city: return metadata.city?.isEmpty ?? true
            case .country: return metadata.country?.isEmpty ?? true
            case .event: return metadata.event?.isEmpty ?? true
            }
        }

        static let defaultCheckedFields: Set<FieldKey> = [.title, .description, .creator, .copyright]
    }
}

extension Array where Element: Hashable {
    /// Returns the array with duplicates removed, preserving the order of first occurrences.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
