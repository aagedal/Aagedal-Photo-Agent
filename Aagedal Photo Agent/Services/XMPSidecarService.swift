import Foundation

struct XMPSidecarService: Sendable {
    private enum Namespace {
        static let x = "adobe:ns:meta/"
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        static let exif = "http://ns.adobe.com/exif/1.0/"
        static let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
    }

    private enum XMPPacket {
        static let id = "W5M0MpCehiHzreSzNTczkc9d"
        static let bom = "\u{FEFF}"
    }

    func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    func loadSidecar(for imageURL: URL) -> IPTCMetadata? {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            guard let document = parseXMLDocument(from: data) else { return nil }
            guard let description = findDescription(in: document) else { return nil }
            return parseMetadata(from: description)
        } catch {
            return nil
        }
    }

    func saveSidecar(metadata: IPTCMetadata, for imageURL: URL) throws {
        let url = sidecarURL(for: imageURL)
        let document = try loadOrCreateDocument(at: url)
        let description = ensureDescription(in: document)
        ensureNamespaces(on: description)
        updateDescription(description, with: metadata)

        let data = serializeXMP(document)
        try data.write(to: url)
    }

    // MARK: - Document Helpers

    private func loadOrCreateDocument(at url: URL) throws -> XMLDocument {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let document = parseXMLDocument(from: data) { return document }
        }
        return createEmptyDocument()
    }

    private func createEmptyDocument() -> XMLDocument {
        let xmpmeta = XMLElement(name: "x:xmpmeta")
        ensureNamespace(xmpmeta, prefix: "x", uri: Namespace.x)
        ensureToolkitAttribute(on: xmpmeta)

        let rdf = XMLElement(name: "rdf:RDF")
        ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)

        xmpmeta.addChild(rdf)

        let description = XMLElement(name: "rdf:Description")
        if let aboutAttr = XMLNode.attribute(withName: "rdf:about", stringValue: "") as? XMLNode {
            description.addAttribute(aboutAttr)
        }
        ensureNamespaces(on: description)
        rdf.addChild(description)

        let document = XMLDocument(rootElement: xmpmeta)
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        return document
    }

    private func ensureDescription(in document: XMLDocument) -> XMLElement {
        if let description = findDescription(in: document) {
            return description
        }

        let rdf = ensureRdfRoot(in: document)
        let description = XMLElement(name: "rdf:Description")
        if let aboutAttr = XMLNode.attribute(withName: "rdf:about", stringValue: "") as? XMLNode {
            description.addAttribute(aboutAttr)
        }
        ensureNamespaces(on: description)
        rdf.addChild(description)
        return description
    }

    private func ensureRdfRoot(in document: XMLDocument) -> XMLElement {
        if let rdf = findFirstElement(in: document, localName: "RDF", namespace: Namespace.rdf) {
            return rdf
        }

        let root = document.rootElement() ?? {
            let xmpmeta = XMLElement(name: "x:xmpmeta")
            ensureNamespace(xmpmeta, prefix: "x", uri: Namespace.x)
            ensureToolkitAttribute(on: xmpmeta)
            document.setRootElement(xmpmeta)
            return xmpmeta
        }()

        let rdf = XMLElement(name: "rdf:RDF")
        ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)
        root.addChild(rdf)
        return rdf
    }

    private func findDescription(in document: XMLDocument) -> XMLElement? {
        findFirstElement(in: document, localName: "Description", namespace: Namespace.rdf)
    }

    private func findFirstElement(in node: XMLNode, localName: String, namespace: String) -> XMLElement? {
        if let element = node as? XMLElement,
           element.localName == localName,
           element.uri == namespace {
            return element
        }

        for child in node.children ?? [] {
            if let match = findFirstElement(in: child, localName: localName, namespace: namespace) {
                return match
            }
        }
        return nil
    }

    private func ensureNamespaces(on description: XMLElement) {
        ensureNamespace(description, prefix: "dc", uri: Namespace.dc)
        ensureNamespace(description, prefix: "xmp", uri: Namespace.xmp)
        ensureNamespace(description, prefix: "photoshop", uri: Namespace.photoshop)
        ensureNamespace(description, prefix: "Iptc4xmpCore", uri: Namespace.iptcCore)
        ensureNamespace(description, prefix: "Iptc4xmpExt", uri: Namespace.iptcExt)
        ensureNamespace(description, prefix: "exif", uri: Namespace.exif)
        ensureNamespace(description, prefix: "crs", uri: Namespace.crs)
        if let rdf = description.parent as? XMLElement {
            ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)
        }
    }

    private func ensureNamespace(_ element: XMLElement, prefix: String, uri: String) {
        if element.namespace(forPrefix: prefix) == nil {
            if let ns = XMLNode.namespace(withName: prefix, stringValue: uri) as? XMLNode {
                element.addNamespace(ns)
            }
        }
    }

    private func ensureToolkitAttribute(on element: XMLElement) {
        guard element.localName == "xmpmeta" else { return }
        ensureNamespace(element, prefix: "x", uri: Namespace.x)
        if element.attribute(forName: "x:xmptk") == nil {
            if let tkAttr = XMLNode.attribute(withName: "x:xmptk", stringValue: "Aagedal Photo Agent") as? XMLNode {
                element.addAttribute(tkAttr)
            }
        }
    }

    private func serializeXMP(_ document: XMLDocument) -> Data {
        if let root = document.rootElement() {
            ensureToolkitAttribute(on: root)
        }

        let body = document.rootElement()?.xmlString(options: [.nodePrettyPrint])
            ?? document.xmlString(options: [.nodePrettyPrint])
        let packet = [
            "<?xpacket begin=\"\(XMPPacket.bom)\" id=\"\(XMPPacket.id)\"?>",
            body,
            "<?xpacket end=\"w\"?>"
        ].joined(separator: "\n")

        return packet.data(using: .utf8) ?? Data()
    }

    private func parseXMLDocument(from data: Data) -> XMLDocument? {
        if let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) {
            return document
        }

        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = stripXPacket(from: xml)
        guard let cleanedData = cleaned.data(using: .utf8) else { return nil }
        return try? XMLDocument(data: cleanedData, options: [.nodePreserveAll])
    }

    private func stripXPacket(from xml: String) -> String {
        var cleaned = xml
        let pattern = "<\\?xpacket[^>]*\\?>"
        while let range = cleaned.range(of: pattern, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Update

    private func updateDescription(_ description: XMLElement, with metadata: IPTCMetadata) {
        setSimple(on: description, prefix: "photoshop", localName: "Headline", value: metadata.title)
        setAltText(on: description, prefix: "dc", localName: "title", value: metadata.title)
        setAltText(on: description, prefix: "dc", localName: "description", value: metadata.description)
        setAltText(on: description, prefix: "Iptc4xmpCore", localName: "ExtDescrAccessibility", value: metadata.extendedDescription)
        setBag(on: description, prefix: "dc", localName: "subject", values: metadata.keywords)
        setBag(on: description, prefix: "Iptc4xmpExt", localName: "PersonInImage", values: metadata.personShown)
        setSimple(on: description, prefix: "xmp", localName: "Rating", value: metadata.rating.map(String.init))
        setSimple(on: description, prefix: "xmp", localName: "Label", value: metadata.label)
        setSimple(on: description, prefix: "Iptc4xmpExt", localName: "DigitalSourceType", value: metadata.digitalSourceType?.rawValue)
        setSeq(on: description, prefix: "dc", localName: "creator", values: metadata.creator.map { [$0] } ?? [])
        setSimple(on: description, prefix: "photoshop", localName: "Credit", value: metadata.credit)
        setSimple(on: description, prefix: "photoshop", localName: "TransmissionReference", value: metadata.jobId)
        setAltText(on: description, prefix: "dc", localName: "rights", value: metadata.copyright)
        setSimple(on: description, prefix: "photoshop", localName: "DateCreated", value: metadata.dateCreated)
        setSimple(on: description, prefix: "photoshop", localName: "City", value: metadata.city)
        setSimple(on: description, prefix: "photoshop", localName: "Country", value: metadata.country)
        setSimple(on: description, prefix: "Iptc4xmpExt", localName: "Event", value: metadata.event)

        if let lat = metadata.latitude, let lon = metadata.longitude {
            setSimple(on: description, prefix: "exif", localName: "GPSLatitude", value: String(format: "%.6f", lat))
            setSimple(on: description, prefix: "exif", localName: "GPSLongitude", value: String(format: "%.6f", lon))
        } else {
            setSimple(on: description, prefix: "exif", localName: "GPSLatitude", value: nil)
            setSimple(on: description, prefix: "exif", localName: "GPSLongitude", value: nil)
        }

        updateCameraRawSettings(on: description, settings: metadata.cameraRaw)
    }

    private func updateCameraRawSettings(on description: XMLElement, settings: CameraRawSettings?) {
        guard let settings else {
            removeCameraRawSettings(from: description)
            return
        }

        // ACR requires Version and ProcessVersion to recognize settings.
        setSimple(on: description, prefix: "crs", localName: "Version", value: settings.version ?? "15.4")
        setSimple(on: description, prefix: "crs", localName: "ProcessVersion", value: settings.processVersion ?? "15.4")
        setSimple(on: description, prefix: "crs", localName: "WhiteBalance", value: settings.whiteBalance)
        setSimple(on: description, prefix: "crs", localName: "Temperature", value: settings.temperature.map(String.init))
        setSimple(on: description, prefix: "crs", localName: "Tint", value: settings.tint.map(formatSignedInt))
        setSimple(
            on: description,
            prefix: "crs",
            localName: "IncrementalTemperature",
            value: settings.incrementalTemperature.map(formatSignedInt)
        )
        setSimple(
            on: description,
            prefix: "crs",
            localName: "IncrementalTint",
            value: settings.incrementalTint.map(formatSignedInt)
        )
        setSimple(
            on: description,
            prefix: "crs",
            localName: "Exposure2012",
            value: settings.exposure2012.map { formatSignedDouble($0, precision: 2) }
        )
        setSimple(on: description, prefix: "crs", localName: "Contrast2012", value: settings.contrast2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Highlights2012", value: settings.highlights2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Shadows2012", value: settings.shadows2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Whites2012", value: settings.whites2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Blacks2012", value: settings.blacks2012.map(formatSignedInt))

        let hasSettings = settings.hasSettings ?? !settings.isEmpty
        setSimple(on: description, prefix: "crs", localName: "HasSettings", value: formatBool(hasSettings))

        let crop = settings.crop
        let hasCrop: Bool? = {
            guard let crop else { return nil }
            return crop.hasCrop ?? !crop.isEmpty
        }()
        setSimple(on: description, prefix: "crs", localName: "CropTop", value: crop?.top.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropLeft", value: crop?.left.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropBottom", value: crop?.bottom.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropRight", value: crop?.right.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropAngle", value: crop?.angle.map { formatUnsignedDouble($0, precision: 2) })
        setSimple(on: description, prefix: "crs", localName: "HasCrop", value: hasCrop.map(formatBool))
        setSimple(on: description, prefix: "crs", localName: "CropConstrainToWarp", value: hasCrop == true ? "0" : nil)
        setSimple(on: description, prefix: "crs", localName: "CropConstrainToUnitSquare", value: hasCrop == true ? "1" : nil)
    }

    private func removeCameraRawSettings(from description: XMLElement) {
        let fields = [
            "Version",
            "ProcessVersion",
            "WhiteBalance",
            "Temperature",
            "Tint",
            "IncrementalTemperature",
            "IncrementalTint",
            "Exposure2012",
            "Contrast2012",
            "Highlights2012",
            "Shadows2012",
            "Whites2012",
            "Blacks2012",
            "HasSettings",
            "CropTop",
            "CropLeft",
            "CropBottom",
            "CropRight",
            "CropAngle",
            "HasCrop",
            "CropConstrainToWarp",
            "CropConstrainToUnitSquare",
        ]
        for field in fields {
            removeProperty(from: description, prefix: "crs", localName: field)
        }
    }

    private func formatSignedInt(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func formatSignedDouble(_ value: Double, precision: Int) -> String {
        let absFormat = "%.\(precision)f"
        let absValue = String(format: absFormat, abs(value))
        if value > 0 { return "+\(absValue)" }
        if value < 0 { return "-\(absValue)" }
        return absValue
    }

    private func formatUnsignedDouble(_ value: Double, precision: Int) -> String {
        String(format: "%.\(precision)f", value)
    }

    private func formatBool(_ value: Bool) -> String {
        value ? "True" : "False"
    }

    private func setSimple(on description: XMLElement, prefix: String, localName: String, value: String?) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        guard let value, !value.isEmpty else { return }
        if let attribute = XMLNode.attribute(withName: "\(prefix):\(localName)", stringValue: value) as? XMLNode {
            description.addAttribute(attribute)
        }
    }

    private func setAltText(on description: XMLElement, prefix: String, localName: String, value: String?) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        guard let value, !value.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let alt = XMLElement(name: "rdf:Alt")
        let li = XMLElement(name: "rdf:li", stringValue: value)
        if let langAttr = XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as? XMLNode {
            li.addAttribute(langAttr)
        }
        alt.addChild(li)
        element.addChild(alt)
        description.addChild(element)
    }

    private func setBag(on description: XMLElement, prefix: String, localName: String, values: [String]) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let bag = XMLElement(name: "rdf:Bag")
        for value in cleaned {
            bag.addChild(XMLElement(name: "rdf:li", stringValue: value))
        }
        element.addChild(bag)
        description.addChild(element)
    }

    private func setSeq(on description: XMLElement, prefix: String, localName: String, values: [String]) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let seq = XMLElement(name: "rdf:Seq")
        for value in cleaned {
            seq.addChild(XMLElement(name: "rdf:li", stringValue: value))
        }
        element.addChild(seq)
        description.addChild(element)
    }

    private func removeProperty(from description: XMLElement, prefix: String, localName: String) {
        let namespace = namespaceURI(for: prefix)
        removeChildren(from: description, localName: localName, namespace: namespace)

        if let exactNameMatch = description.attributes?.first(where: { $0.name == "\(prefix):\(localName)" }) {
            exactNameMatch.detach()
        }

        if let namespaceMatch = description.attributes?.first(where: { $0.localName == localName && $0.uri == namespace }) {
            namespaceMatch.detach()
        }
    }

    private func removeChildren(from description: XMLElement, localName: String, namespace: String) {
        let toRemove = (description.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.localName == localName && $0.uri == namespace }
        for child in toRemove {
            child.detach()
        }
    }

    private func namespaceURI(for prefix: String) -> String {
        switch prefix {
        case "rdf":
            return Namespace.rdf
        case "dc":
            return Namespace.dc
        case "xmp":
            return Namespace.xmp
        case "photoshop":
            return Namespace.photoshop
        case "Iptc4xmpCore":
            return Namespace.iptcCore
        case "Iptc4xmpExt":
            return Namespace.iptcExt
        case "exif":
            return Namespace.exif
        case "crs":
            return Namespace.crs
        default:
            return ""
        }
    }

    // MARK: - Parse

    private func parseMetadata(from description: XMLElement) -> IPTCMetadata {
        let headline = parseSimple(from: description, prefix: "photoshop", localName: "Headline")
        let title = headline ?? parseAltText(from: description, prefix: "dc", localName: "title")
        let descriptionText = parseAltText(from: description, prefix: "dc", localName: "description")
        let extendedDescription = parseAltText(from: description, prefix: "Iptc4xmpCore", localName: "ExtDescrAccessibility")
        let keywords = parseBag(from: description, prefix: "dc", localName: "subject")
        let personShown = parseBag(from: description, prefix: "Iptc4xmpExt", localName: "PersonInImage")
        let ratingValue = parseSimple(from: description, prefix: "xmp", localName: "Rating")
        let label = ColorLabel.canonicalMetadataLabel(
            parseSimple(from: description, prefix: "xmp", localName: "Label")
        )
        let digitalSourceType = parseSimple(from: description, prefix: "Iptc4xmpExt", localName: "DigitalSourceType")
        let creator = parseSeq(from: description, prefix: "dc", localName: "creator").first
        let credit = parseSimple(from: description, prefix: "photoshop", localName: "Credit")
        let jobId = parseSimple(from: description, prefix: "photoshop", localName: "TransmissionReference")
        let rights = parseAltText(from: description, prefix: "dc", localName: "rights")
        let dateCreated = parseSimple(from: description, prefix: "photoshop", localName: "DateCreated")
        let city = parseSimple(from: description, prefix: "photoshop", localName: "City")
        let country = parseSimple(from: description, prefix: "photoshop", localName: "Country")
        let event = parseSimple(from: description, prefix: "Iptc4xmpExt", localName: "Event")
        let latValue = parseSimple(from: description, prefix: "exif", localName: "GPSLatitude")
        let lonValue = parseSimple(from: description, prefix: "exif", localName: "GPSLongitude")
        let cameraRaw = parseCameraRawSettings(from: description)

        return IPTCMetadata(
            title: title,
            description: descriptionText,
            extendedDescription: extendedDescription,
            keywords: keywords,
            personShown: personShown,
            digitalSourceType: digitalSourceType.flatMap { DigitalSourceType(rawValue: $0) },
            latitude: latValue.flatMap { parseCoordinateComponent($0) },
            longitude: lonValue.flatMap { parseCoordinateComponent($0) },
            creator: creator,
            credit: credit,
            copyright: rights,
            jobId: jobId,
            dateCreated: dateCreated,
            city: city,
            country: country,
            event: event,
            rating: ratingValue.flatMap { Int($0) },
            label: label,
            cameraRaw: cameraRaw
        )
    }

    private func parseCameraRawSettings(from description: XMLElement) -> CameraRawSettings? {
        let version = parseSimple(from: description, prefix: "crs", localName: "Version")
        let processVersion = parseSimple(from: description, prefix: "crs", localName: "ProcessVersion")
        let whiteBalance = parseSimple(from: description, prefix: "crs", localName: "WhiteBalance")
        let temperature = parseSimple(from: description, prefix: "crs", localName: "Temperature").flatMap(parseSignedInt)
        let tint = parseSimple(from: description, prefix: "crs", localName: "Tint").flatMap(parseSignedInt)
        let incrementalTemperature = parseSimple(
            from: description,
            prefix: "crs",
            localName: "IncrementalTemperature"
        ).flatMap(parseSignedInt)
        let incrementalTint = parseSimple(
            from: description,
            prefix: "crs",
            localName: "IncrementalTint"
        ).flatMap(parseSignedInt)
        let exposure2012 = parseSimple(from: description, prefix: "crs", localName: "Exposure2012").flatMap(parseSignedDouble)
        let contrast2012 = parseSimple(from: description, prefix: "crs", localName: "Contrast2012").flatMap(parseSignedInt)
        let highlights2012 = parseSimple(from: description, prefix: "crs", localName: "Highlights2012").flatMap(parseSignedInt)
        let shadows2012 = parseSimple(from: description, prefix: "crs", localName: "Shadows2012").flatMap(parseSignedInt)
        let whites2012 = parseSimple(from: description, prefix: "crs", localName: "Whites2012").flatMap(parseSignedInt)
        let blacks2012 = parseSimple(from: description, prefix: "crs", localName: "Blacks2012").flatMap(parseSignedInt)
        let hasSettings = parseSimple(from: description, prefix: "crs", localName: "HasSettings").flatMap(parseBool)

        let crop = CameraRawCrop(
            top: parseSimple(from: description, prefix: "crs", localName: "CropTop").flatMap(Double.init),
            left: parseSimple(from: description, prefix: "crs", localName: "CropLeft").flatMap(Double.init),
            bottom: parseSimple(from: description, prefix: "crs", localName: "CropBottom").flatMap(Double.init),
            right: parseSimple(from: description, prefix: "crs", localName: "CropRight").flatMap(Double.init),
            angle: parseSimple(from: description, prefix: "crs", localName: "CropAngle").flatMap(Double.init),
            hasCrop: parseSimple(from: description, prefix: "crs", localName: "HasCrop").flatMap(parseBool)
        )
        let cropValue = crop.isEmpty ? nil : crop

        let settings = CameraRawSettings(
            version: version,
            processVersion: processVersion,
            whiteBalance: whiteBalance,
            temperature: temperature,
            tint: tint,
            incrementalTemperature: incrementalTemperature,
            incrementalTint: incrementalTint,
            exposure2012: exposure2012,
            contrast2012: contrast2012,
            highlights2012: highlights2012,
            shadows2012: shadows2012,
            whites2012: whites2012,
            blacks2012: blacks2012,
            hasSettings: hasSettings,
            crop: cropValue
        )
        return settings.isEmpty ? nil : settings
    }

    private func parseSimple(from description: XMLElement, prefix: String, localName: String) -> String? {
        if let attr = attributeValue(from: description, prefix: prefix, localName: localName) {
            return attr
        }
        guard let element = childElement(from: description, prefix: prefix, localName: localName) else { return nil }
        return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseAltText(from description: XMLElement, prefix: String, localName: String) -> String? {
        guard let element = childElement(from: description, prefix: prefix, localName: localName),
              let alt = childElement(from: element, prefix: "rdf", localName: "Alt") else {
            return nil
        }
        let items = childElements(from: alt, prefix: "rdf", localName: "li")
        if let preferred = items.first(where: { ($0.attribute(forName: "xml:lang")?.stringValue ?? "") == "x-default" }) {
            return preferred.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return items.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseBag(from description: XMLElement, prefix: String, localName: String) -> [String] {
        guard let element = childElement(from: description, prefix: prefix, localName: localName),
              let bag = childElement(from: element, prefix: "rdf", localName: "Bag") else {
            return []
        }
        return childElements(from: bag, prefix: "rdf", localName: "li")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseSeq(from description: XMLElement, prefix: String, localName: String) -> [String] {
        guard let element = childElement(from: description, prefix: prefix, localName: localName),
              let seq = childElement(from: element, prefix: "rdf", localName: "Seq") else {
            return []
        }
        return childElements(from: seq, prefix: "rdf", localName: "li")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func attributeValue(from element: XMLElement, prefix: String, localName: String) -> String? {
        let namespace = namespaceURI(for: prefix)

        if let namespaceMatch = element.attributes?.first(where: { $0.localName == localName && $0.uri == namespace }),
           let value = namespaceMatch.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        if let nameMatch = element.attributes?.first(where: { $0.name == "\(prefix):\(localName)" }),
           let value = nameMatch.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return nil
    }

    private func childElement(from parent: XMLElement, prefix: String, localName: String) -> XMLElement? {
        childElements(from: parent, prefix: prefix, localName: localName).first
    }

    private func childElements(from parent: XMLElement, prefix: String, localName: String) -> [XMLElement] {
        let namespace = namespaceURI(for: prefix)
        return (parent.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.localName == localName && $0.uri == namespace }
    }

    private func parseCoordinateComponent(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) {
            return direct
        }

        let decimalWithDir = /^\s*(-?\d+\.?\d*)\s*([NSEWnsew])\s*$/
        if let match = trimmed.firstMatch(of: decimalWithDir),
           let base = Double(match.1) {
            let dir = String(match.2).uppercased()
            if dir == "S" || dir == "W" { return -abs(base) }
            return abs(base)
        }

        let dms = /(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: dms),
           let degrees = Int(match.1),
           let minutes = Int(match.2),
           let seconds = Double(match.3) {
            var decimal = Double(abs(degrees)) + Double(minutes) / 60.0 + seconds / 3600.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.4.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        let ddm = /(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: ddm),
           let degrees = Int(match.1),
           let minutes = Double(match.2) {
            var decimal = Double(abs(degrees)) + minutes / 60.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.3.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        return nil
    }

    private func parseSignedInt(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseSignedDouble(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            return nil
        }
    }
}
