import Foundation

/// Stable field identity for normalized metadata verification.
///
/// This is deliberately separate from `MetadataFieldID`: verification also covers persisted
/// fields that are not currently editable (for example Capture Date and GPS). The default field
/// set contains values the app can write without treating read-only technical metadata as a
/// failed descriptive write.
nonisolated enum IPTCMetadataVerificationField: String, CaseIterable, Codable, Equatable, Sendable {
    case headline
    case localizedTitles
    case description
    case extendedDescription
    case keywords
    case personShown
    case organisationsShownNames
    case organisationsShownCodes
    case digitalSourceType
    case urgency
    case sceneCodes
    case subjectCodes
    case mediaTopics
    case genres
    case creator
    case creatorJobTitle
    case descriptionWriter
    case credit
    case copyright
    case rightsUsageTerms
    case webStatementOfRights
    case digitalImageGUID
    case imageSupplierImageID
    case imageSuppliers
    case jobId
    case dateCreated
    case captureDate
    case city
    case sublocation
    case provinceState
    case country
    case countryCode
    case event
    case instructions
    case source
    case creatorContactInfo
    case locationsCreated
    case locationsShown
    case latitude
    case longitude
    case rating
    case label

    /// Fields emitted by the descriptive, structured-editorial, GPS, rating, and label writers.
    /// Capture Date is intentionally omitted because it is source technical metadata, not an
    /// editor-managed write target.
    static let writableFields = Self.allCases.filter { $0 != .captureDate }
}

/// The normalization rule applied before a field is compared.
nonisolated enum IPTCMetadataComparisonRule: String, Sendable, Equatable {
    /// Normalize CRLF/CR to LF, trim leading/trailing whitespace, and treat empty as absent.
    /// Internal whitespace remains significant.
    case scalarWhitespace
    /// Trim items, drop empty items and duplicates, and ignore item order (XMP Bag semantics).
    case unorderedUniqueText
    /// Trim and de-duplicate text while retaining sequence order (XMP Seq / repeatable IIM).
    case orderedUniqueText
    /// Normalize an IPTC NewsCodes URI/QCode/legacy token to its canonical identifier.
    case controlledVocabularyURI
    /// Compare the represented date/time and its precision/timezone-known state, accepting
    /// equivalent timezone projections (for example `Z` and `+00:00`).
    case datePrecision
    case integerExact
    /// Compare decimal degrees after rounding to the six places emitted by the XMP writer.
    case coordinateSixDecimalPlaces
    /// Apply scalar normalization recursively; address-line order remains significant while
    /// alternative contact methods use unordered unique collection semantics.
    case structuredContact
    /// Compare Location structures as an unordered unique collection, recursively normalizing
    /// text, identifiers, country codes, and coordinates.
    case unorderedStructuredLocations
    /// Compare CV-Term structures as an unordered set while retaining vocabulary, term, optional
    /// label, and refined-about identifiers.
    case unorderedControlledVocabularyTerms
    /// Compare the ordered PLUS Image Supplier sequence while keeping each name/identifier pair.
    case orderedStructuredImageSuppliers
    /// Compare every ordered Dublin Core Title value together with its exact language tag.
    case orderedLocalizedText
}

/// A transport-safe representation of a field after canonical normalization.
nonisolated indirect enum IPTCMetadataCanonicalValue: Sendable, Equatable {
    case absent
    case text(String)
    case integer(Int)
    case decimal(String)
    case array([Self])
    case object([String: Self])
}

/// One semantic mismatch from a normalized expected-vs-actual comparison.
nonisolated struct IPTCMetadataDifference: Sendable, Equatable {
    let field: IPTCMetadataVerificationField
    let rule: IPTCMetadataComparisonRule
    let expected: IPTCMetadataCanonicalValue
    let actual: IPTCMetadataCanonicalValue
}

/// Structured result returned both by pure comparisons and file read-back verification.
nonisolated struct IPTCMetadataVerificationReport: Sendable, Equatable {
    let checkedFields: [IPTCMetadataVerificationField]
    let differences: [IPTCMetadataDifference]

    var isMatch: Bool { differences.isEmpty }
}

/// Canonical, non-UI comparison boundary for metadata write verification.
nonisolated enum IPTCMetadataVerifier {
    static func compare(
        expected: IPTCMetadata,
        actual: IPTCMetadata,
        fields: [IPTCMetadataVerificationField] = IPTCMetadataVerificationField.writableFields
    ) -> IPTCMetadataVerificationReport {
        let checkedFields = applicableFields(fields, expected: expected)
        let differences = checkedFields.compactMap { field -> IPTCMetadataDifference? in
            let expectedValue = canonicalValue(for: field, in: expected)
            let actualValue = canonicalValue(for: field, in: actual)
            guard expectedValue != actualValue else { return nil }
            return IPTCMetadataDifference(
                field: field,
                rule: rule(for: field),
                expected: expectedValue,
                actual: actualValue
            )
        }
        return IPTCMetadataVerificationReport(
            checkedFields: checkedFields,
            differences: differences
        )
    }

    /// Returns the subset for which `expected` carries an honest verification assertion.
    /// Localized Title nil is operation intent (leave untouched), not an expected carrier value.
    static func applicableFields(
        _ fields: [IPTCMetadataVerificationField],
        expected: IPTCMetadata
    ) -> [IPTCMetadataVerificationField] {
        fields.uniqued().filter { field in
            field != .localizedTitles || expected.localizedTitles != nil
        }
    }

    static func rule(for field: IPTCMetadataVerificationField) -> IPTCMetadataComparisonRule {
        switch field {
        case .keywords, .personShown, .organisationsShownNames, .organisationsShownCodes:
            .unorderedUniqueText
        case .creator:
            .orderedUniqueText
        case .digitalSourceType, .sceneCodes, .subjectCodes:
            .controlledVocabularyURI
        case .mediaTopics, .genres:
            .unorderedControlledVocabularyTerms
        case .dateCreated, .captureDate:
            .datePrecision
        case .urgency, .rating:
            .integerExact
        case .latitude, .longitude:
            .coordinateSixDecimalPlaces
        case .creatorContactInfo:
            .structuredContact
        case .locationsCreated, .locationsShown:
            .unorderedStructuredLocations
        case .imageSuppliers:
            .orderedStructuredImageSuppliers
        case .localizedTitles:
            .orderedLocalizedText
        default:
            .scalarWhitespace
        }
    }

    static func canonicalValue(
        for field: IPTCMetadataVerificationField,
        in metadata: IPTCMetadata
    ) -> IPTCMetadataCanonicalValue {
        switch field {
        case .headline: scalar(metadata.title)
        case .localizedTitles: localizedText(metadata.localizedTitles)
        case .description: scalar(metadata.description)
        case .extendedDescription: scalar(metadata.extendedDescription)
        case .keywords: unorderedText(metadata.keywords)
        case .personShown: unorderedText(metadata.personShown)
        case .organisationsShownNames: unorderedText(metadata.organisationsShownNames)
        case .organisationsShownCodes: unorderedText(metadata.organisationsShownCodes)
        case .digitalSourceType: scalar(metadata.digitalSourceType?.newsCodeURI)
        case .urgency: integer(metadata.urgency)
        case .sceneCodes:
            unorderedText(metadata.sceneCodes.map(IPTCSceneCode.normalizedValue))
        case .subjectCodes:
            unorderedText(metadata.subjectCodes.map(IPTCSubjectCode.normalizedValue))
        case .mediaTopics:
            controlledVocabularyTerms(metadata.mediaTopics)
        case .genres:
            controlledVocabularyTerms(metadata.genres)
        case .creator: orderedUniqueText(metadata.creators)
        case .creatorJobTitle: scalar(metadata.creatorJobTitle)
        case .descriptionWriter: scalar(metadata.descriptionWriter)
        case .credit: scalar(metadata.credit)
        case .copyright: scalar(metadata.copyright)
        case .rightsUsageTerms: scalar(metadata.rightsUsageTerms)
        case .webStatementOfRights: scalar(metadata.webStatementOfRights)
        case .digitalImageGUID: scalar(metadata.digitalImageGUID)
        case .imageSupplierImageID: scalar(metadata.imageSupplierImageID)
        case .imageSuppliers: imageSuppliers(metadata.imageSuppliers)
        case .jobId: scalar(metadata.jobId)
        case .dateCreated: date(metadata.dateCreated)
        case .captureDate: date(metadata.captureDate)
        case .city: scalar(metadata.city)
        case .sublocation: scalar(metadata.sublocation)
        case .provinceState: scalar(metadata.provinceState)
        case .country: scalar(metadata.country)
        case .countryCode: scalar(metadata.countryCode?.uppercased())
        case .event: scalar(metadata.event)
        case .instructions: scalar(metadata.instructions)
        case .source: scalar(metadata.source)
        case .creatorContactInfo: contact(metadata.creatorContactInfo)
        case .locationsCreated: locations(metadata.locationsCreated)
        case .locationsShown: locations(metadata.locationsShown)
        case .latitude: coordinate(metadata.latitude, decimalPlaces: 6)
        case .longitude: coordinate(metadata.longitude, decimalPlaces: 6)
        case .rating: integer(metadata.rating)
        case .label: scalar(metadata.label)
        }
    }

    // MARK: - Scalar and collection normalization

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let lineNormalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lineNormalized.isEmpty ? nil : lineNormalized
    }

    private static func scalar(_ value: String?) -> IPTCMetadataCanonicalValue {
        normalizedText(value).map(IPTCMetadataCanonicalValue.text) ?? .absent
    }

    private static func integer(_ value: Int?) -> IPTCMetadataCanonicalValue {
        value.map(IPTCMetadataCanonicalValue.integer) ?? .absent
    }

    private static func normalizedUniqueText(_ values: [String], ordered: Bool) -> [String] {
        var seen = Set<String>()
        var normalized = values.compactMap(normalizedText).filter { seen.insert($0).inserted }
        if !ordered { normalized.sort() }
        return normalized
    }

    private static func unorderedText(_ values: [String]) -> IPTCMetadataCanonicalValue {
        let values = normalizedUniqueText(values, ordered: false).map(IPTCMetadataCanonicalValue.text)
        return values.isEmpty ? .absent : .array(values)
    }

    private static func controlledVocabularyTerms(
        _ terms: [IPTCControlledVocabularyTerm]
    ) -> IPTCMetadataCanonicalValue {
        let values = IPTCControlledVocabularyTerm.normalizedValues(terms).map { term in
            IPTCMetadataCanonicalValue.object([
                "cvId": scalar(term.vocabularyIdentifier),
                "termId": scalar(term.termIdentifier),
                "name": scalar(term.name),
                "refinedAbout": scalar(term.refinedAbout),
            ])
        }.sorted { fingerprint($0) < fingerprint($1) }
        return values.isEmpty ? .absent : .array(values)
    }

    private static func orderedUniqueText(_ values: [String]) -> IPTCMetadataCanonicalValue {
        let values = normalizedUniqueText(values, ordered: true).map(IPTCMetadataCanonicalValue.text)
        return values.isEmpty ? .absent : .array(values)
    }

    private static func localizedText(
        _ values: [LocalizedMetadataText]?
    ) -> IPTCMetadataCanonicalValue {
        guard let values, !values.isEmpty else { return .absent }
        return .array(values.map { value in
            .object([
                "languageTag": scalar(value.languageTag),
                "value": scalar(value.value),
            ])
        })
    }

    private static func coordinate(
        _ value: Double?,
        decimalPlaces: Int
    ) -> IPTCMetadataCanonicalValue {
        guard let value, value.isFinite else { return .absent }
        let scale = pow(10.0, Double(decimalPlaces))
        var rounded = (value * scale).rounded() / scale
        if rounded == 0 { rounded = 0 } // Canonicalize negative zero.
        return .decimal(String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            decimalPlaces,
            rounded
        ))
    }

    // MARK: - Structured normalization

    private static func contact(_ value: CreatorContactInfo?) -> IPTCMetadataCanonicalValue {
        guard let value else { return .absent }
        var object: [String: IPTCMetadataCanonicalValue] = [:]
        insert(orderedUniqueText(value.addressLines), as: "addressLines", into: &object)
        insert(scalar(value.city), as: "city", into: &object)
        insert(scalar(value.region), as: "region", into: &object)
        insert(scalar(value.postalCode), as: "postalCode", into: &object)
        insert(scalar(value.country), as: "country", into: &object)
        insert(unorderedText(value.emails), as: "emails", into: &object)
        insert(unorderedText(value.phoneNumbers), as: "phoneNumbers", into: &object)
        insert(unorderedText(value.webURLs), as: "webURLs", into: &object)
        return object.isEmpty ? .absent : .object(object)
    }

    private static func locations(_ values: [EditorialLocation]) -> IPTCMetadataCanonicalValue {
        var seen = Set<String>()
        var normalized = values.compactMap(location).filter { seen.insert(fingerprint($0)).inserted }
        normalized.sort { fingerprint($0) < fingerprint($1) }
        return normalized.isEmpty ? .absent : .array(normalized)
    }

    private static func imageSuppliers(
        _ values: [EditorialImageSupplier]
    ) -> IPTCMetadataCanonicalValue {
        let normalized = EditorialImageSupplier.normalizedValues(values).compactMap { supplier in
            var object: [String: IPTCMetadataCanonicalValue] = [:]
            insert(scalar(supplier.identifier), as: "identifier", into: &object)
            insert(scalar(supplier.name), as: "name", into: &object)
            return object.isEmpty ? nil : IPTCMetadataCanonicalValue.object(object)
        }
        return normalized.isEmpty ? .absent : .array(normalized)
    }

    private static func location(_ value: EditorialLocation) -> IPTCMetadataCanonicalValue? {
        var object: [String: IPTCMetadataCanonicalValue] = [:]
        insert(unorderedText(value.identifiers), as: "identifiers", into: &object)
        insert(scalar(value.name), as: "name", into: &object)
        insert(scalar(value.sublocation), as: "sublocation", into: &object)
        insert(scalar(value.city), as: "city", into: &object)
        insert(scalar(value.provinceState), as: "provinceState", into: &object)
        insert(scalar(value.countryName), as: "countryName", into: &object)
        insert(scalar(value.countryCode?.uppercased()), as: "countryCode", into: &object)
        insert(scalar(value.worldRegion), as: "worldRegion", into: &object)
        insert(coordinate(value.latitude, decimalPlaces: 6), as: "latitude", into: &object)
        insert(coordinate(value.longitude, decimalPlaces: 6), as: "longitude", into: &object)
        insert(coordinate(value.altitudeMeters, decimalPlaces: 3), as: "altitudeMeters", into: &object)
        return object.isEmpty ? nil : .object(object)
    }

    private static func insert(
        _ value: IPTCMetadataCanonicalValue,
        as key: String,
        into object: inout [String: IPTCMetadataCanonicalValue]
    ) {
        guard value != .absent else { return }
        object[key] = value
    }

    private static func fingerprint(_ value: IPTCMetadataCanonicalValue) -> String {
        switch value {
        case .absent: return "n"
        case .text(let value): return "s\(value.utf8.count):\(value)"
        case .integer(let value): return "i:\(value)"
        case .decimal(let value): return "d:\(value)"
        case .array(let values): return "a:[\(values.map(fingerprint).joined(separator: ","))]"
        case .object(let values):
            return "o:{" + values.keys.sorted().map { key in
                "\(key.utf8.count):\(key)=\(fingerprint(values[key]!))"
            }.joined(separator: ",") + "}"
        }
    }

    // MARK: - Date/time normalization

    private static let dateExpression = try! NSRegularExpression(
        pattern: #"^(\d{4})[-:](\d{2})[-:](\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|z|[+-]\d{2}:?\d{2})?)?$"#
    )

    private static func date(_ value: String?) -> IPTCMetadataCanonicalValue {
        guard let value = normalizedText(value) else { return .absent }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = dateExpression.firstMatch(in: value, range: range) else {
            return .text(value)
        }

        func capture(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
                return nil
            }
            return String(value[swiftRange])
        }

        guard let year = capture(1).flatMap(Int.init),
              let month = capture(2).flatMap(Int.init),
              let day = capture(3).flatMap(Int.init) else {
            return .text(value)
        }

        let hour = capture(4).flatMap(Int.init)
        let minute = capture(5).flatMap(Int.init)
        let second = capture(6).flatMap(Int.init)
        let fraction = capture(7).map { digits in
            let trimmed = digits.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            return trimmed.isEmpty ? "0" : trimmed
        }
        let timezone = capture(8)

        let precision: String
        if fraction != nil { precision = "fraction" }
        else if second != nil { precision = "second" }
        else if minute != nil { precision = "minute" }
        else { precision = "day" }

        let local = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            year, month, day, hour ?? 0, minute ?? 0, second ?? 0
        )
        let fractionSuffix = fraction.map { ".\($0)" } ?? ""

        guard let timezone else {
            return .text("local:\(local)\(fractionSuffix);precision:\(precision);timezone:unknown")
        }

        var offsetSeconds = 0
        if timezone.lowercased() != "z" {
            let sign = timezone.hasPrefix("-") ? -1 : 1
            let digits = timezone.dropFirst().replacingOccurrences(of: ":", with: "")
            guard digits.count == 4,
                  let offsetHour = Int(digits.prefix(2)),
                  let offsetMinute = Int(digits.suffix(2)) else {
                return .text(value)
            }
            offsetSeconds = sign * ((offsetHour * 60 + offsetMinute) * 60)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour ?? 0
        components.minute = minute ?? 0
        components.second = second ?? 0
        guard let localDate = calendar.date(from: components) else { return .text(value) }
        let epochSecond = Int64(localDate.timeIntervalSince1970) - Int64(offsetSeconds)
        return .text("instant:\(epochSecond)\(fractionSuffix);precision:\(precision);timezone:known")
    }
}
