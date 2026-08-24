import Foundation

// MARK: - IPTC Creator Contact Info

/// IPTC Creator Contact Information structure (Iptc4xmpCore:CreatorContactInfo).
/// Contains contact details for the creator of the image.
public struct IPTCCreatorContactInfo: Equatable, Sendable {
    /// City of the creator's address.
    public var city: String?
    /// Country of the creator's address.
    public var country: String?
    /// Street address (may include multiple lines).
    public var address: String?
    /// Postal code.
    public var postalCode: String?
    /// State or province.
    public var region: String?
    /// Work email address.
    public var emailWork: String?
    /// Work phone number.
    public var phoneWork: String?
    /// Work URL.
    public var webUrl: String?

    public init(
        city: String? = nil, country: String? = nil, address: String? = nil,
        postalCode: String? = nil, region: String? = nil,
        emailWork: String? = nil, phoneWork: String? = nil, webUrl: String? = nil
    ) {
        self.city = city
        self.country = country
        self.address = address
        self.postalCode = postalCode
        self.region = region
        self.emailWork = emailWork
        self.phoneWork = phoneWork
        self.webUrl = webUrl
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcCore
        self.city = fields[ns + "CiAdrCity"]
        self.country = fields[ns + "CiAdrCtry"]
        self.address = fields[ns + "CiAdrExtadr"]
        self.postalCode = fields[ns + "CiAdrPcode"]
        self.region = fields[ns + "CiAdrRegion"]
        self.emailWork = fields[ns + "CiEmailWork"]
        self.phoneWork = fields[ns + "CiTelWork"]
        self.webUrl = fields[ns + "CiUrlWork"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcCore
        var fields: [String: String] = [:]
        if let v = city { fields[ns + "CiAdrCity"] = v }
        if let v = country { fields[ns + "CiAdrCtry"] = v }
        if let v = address { fields[ns + "CiAdrExtadr"] = v }
        if let v = postalCode { fields[ns + "CiAdrPcode"] = v }
        if let v = region { fields[ns + "CiAdrRegion"] = v }
        if let v = emailWork { fields[ns + "CiEmailWork"] = v }
        if let v = phoneWork { fields[ns + "CiTelWork"] = v }
        if let v = webUrl { fields[ns + "CiUrlWork"] = v }
        return fields
    }
}

// MARK: - IPTC Location

/// IPTC Location structure used for LocationCreated and LocationShown (Iptc4xmpExt).
public struct IPTCLocation: Equatable, Sendable {
    public var city: String?
    public var countryCode: String?
    public var countryName: String?
    public var provinceState: String?
    public var sublocation: String?
    public var worldRegion: String?

    public init(
        city: String? = nil, countryCode: String? = nil, countryName: String? = nil,
        provinceState: String? = nil, sublocation: String? = nil, worldRegion: String? = nil
    ) {
        self.city = city
        self.countryCode = countryCode
        self.countryName = countryName
        self.provinceState = provinceState
        self.sublocation = sublocation
        self.worldRegion = worldRegion
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.city = fields[ns + "City"]
        self.countryCode = fields[ns + "CountryCode"]
        self.countryName = fields[ns + "CountryName"]
        self.provinceState = fields[ns + "ProvinceState"]
        self.sublocation = fields[ns + "Sublocation"]
        self.worldRegion = fields[ns + "WorldRegion"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = city { fields[ns + "City"] = v }
        if let v = countryCode { fields[ns + "CountryCode"] = v }
        if let v = countryName { fields[ns + "CountryName"] = v }
        if let v = provinceState { fields[ns + "ProvinceState"] = v }
        if let v = sublocation { fields[ns + "Sublocation"] = v }
        if let v = worldRegion { fields[ns + "WorldRegion"] = v }
        return fields
    }
}

// MARK: - IPTC Registry Entry

/// IPTC Registry Entry structure (Iptc4xmpExt:RegistryId).
public struct IPTCRegistryEntry: Equatable, Sendable {
    /// The identifier assigned by the registry.
    public var regItemId: String?
    /// The identifier of the registry (organization).
    public var regOrgId: String?

    public init(regItemId: String? = nil, regOrgId: String? = nil) {
        self.regItemId = regItemId
        self.regOrgId = regOrgId
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.regItemId = fields[ns + "RegItemId"]
        self.regOrgId = fields[ns + "RegOrgId"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = regItemId { fields[ns + "RegItemId"] = v }
        if let v = regOrgId { fields[ns + "RegOrgId"] = v }
        return fields
    }
}

// MARK: - IPTC Artwork or Object

/// IPTC Artwork or Object structure (Iptc4xmpExt:ArtworkOrObject).
public struct IPTCArtworkOrObject: Equatable, Sendable {
    /// Title of the artwork or object.
    public var title: String?
    /// Creator of the artwork or object.
    public var creator: String?
    /// Date the artwork or object was created.
    public var dateCreated: String?
    /// Source of the artwork or object.
    public var source: String?
    /// Source inventory number.
    public var sourceInventoryNo: String?
    /// Copyright notice for the artwork or object.
    public var copyrightNotice: String?

    public init(
        title: String? = nil, creator: String? = nil, dateCreated: String? = nil,
        source: String? = nil, sourceInventoryNo: String? = nil, copyrightNotice: String? = nil
    ) {
        self.title = title
        self.creator = creator
        self.dateCreated = dateCreated
        self.source = source
        self.sourceInventoryNo = sourceInventoryNo
        self.copyrightNotice = copyrightNotice
    }

    /// Initialize from raw XMP structure fields (namespace-qualified keys).
    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.title = fields[ns + "AOTitle"]
        self.creator = fields[ns + "AOCreator"]
        self.dateCreated = fields[ns + "AODateCreated"]
        self.source = fields[ns + "AOSource"]
        self.sourceInventoryNo = fields[ns + "AOSourceInvNo"]
        self.copyrightNotice = fields[ns + "AOCopyrightNotice"]
    }

    /// Convert to raw XMP structure fields with namespace-qualified keys.
    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = title { fields[ns + "AOTitle"] = v }
        if let v = creator { fields[ns + "AOCreator"] = v }
        if let v = dateCreated { fields[ns + "AODateCreated"] = v }
        if let v = source { fields[ns + "AOSource"] = v }
        if let v = sourceInventoryNo { fields[ns + "AOSourceInvNo"] = v }
        if let v = copyrightNotice { fields[ns + "AOCopyrightNotice"] = v }
        return fields
    }
}

// MARK: - IPTC Image Creator (Extension 1.4+)

/// Image Creator structure (Iptc4xmpExt:ImageCreator).
/// Identifies the image creator with an optional registry ID and a human-readable name.
public struct IPTCImageCreator: Equatable, Sendable {
    /// Identifier assigned by a registry, if any.
    public var creatorID: String?
    /// Human-readable name of the creator.
    public var creatorName: String?

    public init(creatorID: String? = nil, creatorName: String? = nil) {
        self.creatorID = creatorID
        self.creatorName = creatorName
    }

    public init(fields: [String: String]) {
        let ns = XMPNamespace.iptcExt
        self.creatorID = fields[ns + "ImageCreatorID"]
        self.creatorName = fields[ns + "ImageCreatorName"]
    }

    public func toFields() -> [String: String] {
        let ns = XMPNamespace.iptcExt
        var fields: [String: String] = [:]
        if let v = creatorID { fields[ns + "ImageCreatorID"] = v }
        if let v = creatorName { fields[ns + "ImageCreatorName"] = v }
        return fields
    }
}

// MARK: - IPTC Copyright Owner (PLUS)

/// Copyright Owner structure (plus:CopyrightOwner).
public struct IPTCCopyrightOwner: Equatable, Sendable {
    public var copyrightOwnerID: String?
    public var copyrightOwnerName: String?

    public init(copyrightOwnerID: String? = nil, copyrightOwnerName: String? = nil) {
        self.copyrightOwnerID = copyrightOwnerID
        self.copyrightOwnerName = copyrightOwnerName
    }

    public init(fields: [String: String]) {
        let ns = XMPNamespace.plus
        self.copyrightOwnerID = fields[ns + "CopyrightOwnerID"]
        self.copyrightOwnerName = fields[ns + "CopyrightOwnerName"]
    }

    public func toFields() -> [String: String] {
        let ns = XMPNamespace.plus
        var fields: [String: String] = [:]
        if let v = copyrightOwnerID { fields[ns + "CopyrightOwnerID"] = v }
        if let v = copyrightOwnerName { fields[ns + "CopyrightOwnerName"] = v }
        return fields
    }
}

// MARK: - IPTC Licensor (PLUS)

/// Licensor structure (plus:Licensor). Full PLUS licensor contact details.
public struct IPTCLicensor: Equatable, Sendable {
    public var licensorID: String?
    public var licensorName: String?
    public var licensorStreetAddress: String?
    public var licensorExtendedAddress: String?
    public var licensorCity: String?
    public var licensorRegion: String?
    public var licensorPostalCode: String?
    public var licensorCountry: String?
    public var licensorTelephone1: String?
    public var licensorTelephone2: String?
    public var licensorEmail: String?
    public var licensorURL: String?

    public init(
        licensorID: String? = nil, licensorName: String? = nil,
        licensorStreetAddress: String? = nil, licensorExtendedAddress: String? = nil,
        licensorCity: String? = nil, licensorRegion: String? = nil,
        licensorPostalCode: String? = nil, licensorCountry: String? = nil,
        licensorTelephone1: String? = nil, licensorTelephone2: String? = nil,
        licensorEmail: String? = nil, licensorURL: String? = nil
    ) {
        self.licensorID = licensorID
        self.licensorName = licensorName
        self.licensorStreetAddress = licensorStreetAddress
        self.licensorExtendedAddress = licensorExtendedAddress
        self.licensorCity = licensorCity
        self.licensorRegion = licensorRegion
        self.licensorPostalCode = licensorPostalCode
        self.licensorCountry = licensorCountry
        self.licensorTelephone1 = licensorTelephone1
        self.licensorTelephone2 = licensorTelephone2
        self.licensorEmail = licensorEmail
        self.licensorURL = licensorURL
    }

    public init(fields: [String: String]) {
        let ns = XMPNamespace.plus
        self.licensorID = fields[ns + "LicensorID"]
        self.licensorName = fields[ns + "LicensorName"]
        self.licensorStreetAddress = fields[ns + "LicensorStreetAddress"]
        self.licensorExtendedAddress = fields[ns + "LicensorExtendedAddress"]
        self.licensorCity = fields[ns + "LicensorCity"]
        self.licensorRegion = fields[ns + "LicensorRegion"]
        self.licensorPostalCode = fields[ns + "LicensorPostalCode"]
        self.licensorCountry = fields[ns + "LicensorCountry"]
        self.licensorTelephone1 = fields[ns + "LicensorTelephone1"]
        self.licensorTelephone2 = fields[ns + "LicensorTelephone2"]
        self.licensorEmail = fields[ns + "LicensorEmail"]
        self.licensorURL = fields[ns + "LicensorURL"]
    }

    public func toFields() -> [String: String] {
        let ns = XMPNamespace.plus
        var fields: [String: String] = [:]
        if let v = licensorID { fields[ns + "LicensorID"] = v }
        if let v = licensorName { fields[ns + "LicensorName"] = v }
        if let v = licensorStreetAddress { fields[ns + "LicensorStreetAddress"] = v }
        if let v = licensorExtendedAddress { fields[ns + "LicensorExtendedAddress"] = v }
        if let v = licensorCity { fields[ns + "LicensorCity"] = v }
        if let v = licensorRegion { fields[ns + "LicensorRegion"] = v }
        if let v = licensorPostalCode { fields[ns + "LicensorPostalCode"] = v }
        if let v = licensorCountry { fields[ns + "LicensorCountry"] = v }
        if let v = licensorTelephone1 { fields[ns + "LicensorTelephone1"] = v }
        if let v = licensorTelephone2 { fields[ns + "LicensorTelephone2"] = v }
        if let v = licensorEmail { fields[ns + "LicensorEmail"] = v }
        if let v = licensorURL { fields[ns + "LicensorURL"] = v }
        return fields
    }
}

// MARK: - IPTC Image Supplier (PLUS)

/// Image Supplier structure (plus:ImageSupplier).
/// PLUS distinguishes the image *supplier* (the agency or creator who provided
/// the image) from the *licensor* (who licenses the rights). Required by
/// AAP/PACA distribution agreements.
public struct IPTCImageSupplier: Equatable, Sendable {
    public var imageSupplierID: String?
    public var imageSupplierName: String?

    public init(imageSupplierID: String? = nil, imageSupplierName: String? = nil) {
        self.imageSupplierID = imageSupplierID
        self.imageSupplierName = imageSupplierName
    }

    public init(fields: [String: String]) {
        let ns = XMPNamespace.plus
        self.imageSupplierID = fields[ns + "ImageSupplierID"]
        self.imageSupplierName = fields[ns + "ImageSupplierName"]
    }

    public func toFields() -> [String: String] {
        let ns = XMPNamespace.plus
        var fields: [String: String] = [:]
        if let v = imageSupplierID { fields[ns + "ImageSupplierID"] = v }
        if let v = imageSupplierName { fields[ns + "ImageSupplierName"] = v }
        return fields
    }
}
