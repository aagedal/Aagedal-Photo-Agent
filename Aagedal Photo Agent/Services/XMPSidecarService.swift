import Foundation

struct XMPSidecarService: Sendable {
    private enum Namespace {
        static let x = "adobe:ns:meta/"
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        static let exif = "http://ns.adobe.com/exif/1.0/"
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
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
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
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
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
        ensureNamespace(description, prefix: "Iptc4xmpExt", uri: Namespace.iptcExt)
        ensureNamespace(description, prefix: "exif", uri: Namespace.exif)
        if let rdf = description.parent as? XMLElement {
            ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)
        }
    }

    private func ensureNamespace(_ element: XMLElement, prefix: String, uri: String) {
        if element.namespace(forPrefix: prefix) == nil {
            element.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        }
    }

    private func ensureToolkitAttribute(on element: XMLElement) {
        guard element.localName == "xmpmeta" else { return }
        ensureNamespace(element, prefix: "x", uri: Namespace.x)
        if element.attribute(forName: "x:xmptk") == nil {
            element.addAttribute(XMLNode.attribute(withName: "x:xmptk", stringValue: "Aagedal Photo Agent") as! XMLNode)
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
        setBag(on: description, prefix: "dc", localName: "subject", values: metadata.keywords)
        setBag(on: description, prefix: "Iptc4xmpExt", localName: "PersonInImage", values: metadata.personShown)
        setSimple(on: description, prefix: "xmp", localName: "Rating", value: metadata.rating.map(String.init))
        setSimple(on: description, prefix: "xmp", localName: "Label", value: metadata.label)
        setSimple(on: description, prefix: "Iptc4xmpExt", localName: "DigitalSourceType", value: metadata.digitalSourceType?.rawValue)
        setSeq(on: description, prefix: "dc", localName: "creator", values: metadata.creator.map { [$0] } ?? [])
        setSimple(on: description, prefix: "photoshop", localName: "Credit", value: metadata.credit)
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
    }

    private func setSimple(on description: XMLElement, prefix: String, localName: String, value: String?) {
        removeChildren(from: description, localName: localName, namespace: namespaceURI(for: prefix))
        guard let value, !value.isEmpty else { return }
        let element = XMLElement(name: "\(prefix):\(localName)", stringValue: value)
        description.addChild(element)
    }

    private func setAltText(on description: XMLElement, prefix: String, localName: String, value: String?) {
        removeChildren(from: description, localName: localName, namespace: namespaceURI(for: prefix))
        guard let value, !value.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let alt = XMLElement(name: "rdf:Alt")
        let li = XMLElement(name: "rdf:li", stringValue: value)
        li.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
        alt.addChild(li)
        element.addChild(alt)
        description.addChild(element)
    }

    private func setBag(on description: XMLElement, prefix: String, localName: String, values: [String]) {
        removeChildren(from: description, localName: localName, namespace: namespaceURI(for: prefix))
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
        removeChildren(from: description, localName: localName, namespace: namespaceURI(for: prefix))
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
        case "Iptc4xmpExt":
            return Namespace.iptcExt
        case "exif":
            return Namespace.exif
        default:
            return ""
        }
    }

    // MARK: - Parse

    private func parseMetadata(from description: XMLElement) -> IPTCMetadata {
        let headline = parseSimple(from: description, prefix: "photoshop", localName: "Headline")
        let title = headline ?? parseAltText(from: description, prefix: "dc", localName: "title")
        let descriptionText = parseAltText(from: description, prefix: "dc", localName: "description")
        let keywords = parseBag(from: description, prefix: "dc", localName: "subject")
        let personShown = parseBag(from: description, prefix: "Iptc4xmpExt", localName: "PersonInImage")
        let ratingValue = parseSimple(from: description, prefix: "xmp", localName: "Rating")
        let label = parseSimple(from: description, prefix: "xmp", localName: "Label")
        let digitalSourceType = parseSimple(from: description, prefix: "Iptc4xmpExt", localName: "DigitalSourceType")
        let creator = parseSeq(from: description, prefix: "dc", localName: "creator").first
        let credit = parseSimple(from: description, prefix: "photoshop", localName: "Credit")
        let rights = parseAltText(from: description, prefix: "dc", localName: "rights")
        let dateCreated = parseSimple(from: description, prefix: "photoshop", localName: "DateCreated")
        let city = parseSimple(from: description, prefix: "photoshop", localName: "City")
        let country = parseSimple(from: description, prefix: "photoshop", localName: "Country")
        let event = parseSimple(from: description, prefix: "Iptc4xmpExt", localName: "Event")
        let latValue = parseSimple(from: description, prefix: "exif", localName: "GPSLatitude")
        let lonValue = parseSimple(from: description, prefix: "exif", localName: "GPSLongitude")

        return IPTCMetadata(
            title: title,
            description: descriptionText,
            keywords: keywords,
            personShown: personShown,
            digitalSourceType: digitalSourceType.flatMap { DigitalSourceType(rawValue: $0) },
            latitude: latValue.flatMap { parseCoordinateComponent($0) },
            longitude: lonValue.flatMap { parseCoordinateComponent($0) },
            creator: creator,
            credit: credit,
            copyright: rights,
            dateCreated: dateCreated,
            city: city,
            country: country,
            event: event,
            rating: ratingValue.flatMap { Int($0) },
            label: label
        )
    }

    private func parseSimple(from description: XMLElement, prefix: String, localName: String) -> String? {
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
}
