import Foundation

struct IPTCMetadata: Codable, Sendable, Equatable {
    // Priority fields (always visible)
    var title: String?
    var description: String?
    var keywords: [String]
    var personShown: [String]

    // Classification
    var digitalSourceType: DigitalSourceType?

    // Secondary fields (collapsible)
    var creator: String?
    var credit: String?
    var copyright: String?
    var dateCreated: String?
    var city: String?
    var country: String?
    var event: String?

    // XMP managed alongside
    var rating: Int?
    var label: String?

    init(
        title: String? = nil,
        description: String? = nil,
        keywords: [String] = [],
        personShown: [String] = [],
        digitalSourceType: DigitalSourceType? = nil,
        creator: String? = nil,
        credit: String? = nil,
        copyright: String? = nil,
        dateCreated: String? = nil,
        city: String? = nil,
        country: String? = nil,
        event: String? = nil,
        rating: Int? = nil,
        label: String? = nil
    ) {
        self.title = title
        self.description = description
        self.keywords = keywords
        self.personShown = personShown
        self.digitalSourceType = digitalSourceType
        self.creator = creator
        self.credit = credit
        self.copyright = copyright
        self.dateCreated = dateCreated
        self.city = city
        self.country = country
        self.event = event
        self.rating = rating
        self.label = label
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
