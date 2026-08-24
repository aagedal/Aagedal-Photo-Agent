import Foundation

/// Serialize XMPData to XMP XML.
public struct XMPWriter: Sendable {

    /// Serialize XMPData to APP1 segment payload (including XMP namespace identifier prefix).
    public static func write(_ xmpData: XMPData) -> Data {
        let xml = generateXML(xmpData)

        var result = Data(JPEGSegment.xmpIdentifier)
        result.append(Data(xml.utf8))
        return result
    }

    /// Generate XMP XML string from properties.
    public static func generateXML(_ xmpData: XMPData) -> String {
        // Gather every namespace referenced by any key (top-level and nested struct
        // fields). Namespaces outside the known prefix table get a generated
        // ns1/ns2/… prefix instead of being dropped — the reader accepts any
        // document-declared namespace, so the writer must round-trip them too.
        var usedNamespaces: Set<String> = []
        var unknownNamespaces: Set<String> = []
        for key in xmpData.allKeys {
            classifyKey(key, known: &usedNamespaces, unknown: &unknownNamespaces)
            if let value = xmpData.value(forKey: key) {
                collectNamespacesRecursive(value, known: &usedNamespaces, unknown: &unknownNamespaces)
            }
        }

        var dynamicPrefixes: [String: String] = [:]
        for (index, ns) in unknownNamespaces.sorted().enumerated() {
            dynamicPrefixes[ns] = "ns\(index + 1)"
        }

        let context = EmitContext(dynamic: dynamicPrefixes, observed: xmpData.arrayForms)

        // Resolve every key once into (prefix, localName, namespace) and keep the value alongside —
        // the writer previously split each key three separate times via hasPrefix scans.
        struct ResolvedProp {
            let key: String
            let prefix: String
            let localName: String
            let value: XMPValue
        }

        let resolved: [ResolvedProp] = xmpData.allKeys.sorted().compactMap { key in
            guard let parts = resolveKey(key, dynamic: dynamicPrefixes),
                  let value = xmpData.value(forKey: key) else { return nil }
            return ResolvedProp(key: key, prefix: parts.prefix, localName: parts.localName, value: value)
        }

        // Add region namespaces if needed
        if let regions = xmpData.regions, !regions.regions.isEmpty {
            usedNamespaces.insert(XMPNamespace.mwgRegions)
            usedNamespaces.insert(XMPNamespace.stArea)
            usedNamespaces.insert(XMPNamespace.stDim)
        }

        // Build namespace declarations
        var nsDeclarations = ""
        for ns in usedNamespaces.sorted() {
            if let prefix = XMPNamespace.prefixes[ns] {
                nsDeclarations += "\n   xmlns:\(prefix)=\"\(ns)\""
            }
        }
        for ns in dynamicPrefixes.keys.sorted() {
            nsDeclarations += "\n   xmlns:\(dynamicPrefixes[ns]!)=\"\(ns)\""
        }

        // Build properties
        var simpleProps = ""
        var complexProps = ""

        for prop in resolved {
            let prefix = prop.prefix
            let localName = prop.localName

            switch prop.value {
            case .simple(let s):
                simpleProps += "\n   \(prefix):\(localName)=\"\(escapeXML(s))\""

            case .array(let items):
                let container = containerElement(forKey: prop.key, context: context)
                complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:\(container)>\n"
                for item in items {
                    complexProps += "    <rdf:li>\(escapeXML(item))</rdf:li>\n"
                }
                complexProps += "   </rdf:\(container)>\n  </\(prefix):\(localName)>"

            case .langAlternative(let s):
                complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:Alt>\n"
                complexProps += "    <rdf:li xml:lang=\"x-default\">\(escapeXML(s))</rdf:li>\n"
                complexProps += "   </rdf:Alt>\n  </\(prefix):\(localName)>"

            case .languageAlternative(let items):
                complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:Alt>\n"
                for item in items {
                    complexProps += "    <rdf:li xml:lang=\"\(escapeXML(item.language))\">\(escapeXML(item.value))</rdf:li>\n"
                }
                complexProps += "   </rdf:Alt>\n  </\(prefix):\(localName)>"

            case .structure(let fields):
                complexProps += "\n  <\(prefix):\(localName)>"
                complexProps += emitStructureBody(fields, indent: "   ", context: context)
                complexProps += "\n  </\(prefix):\(localName)>"

            case .structuredArray(let items):
                let container = containerElement(forKey: prop.key, context: context)
                complexProps += "\n  <\(prefix):\(localName)>\n   <rdf:\(container)>"
                for item in items {
                    complexProps += "\n    <rdf:li>"
                    complexProps += emitStructureBody(item, indent: "     ", context: context)
                    complexProps += "\n    </rdf:li>"
                }
                complexProps += "\n   </rdf:\(container)>\n  </\(prefix):\(localName)>"
            }
        }

        // Add region XML if present
        if let regions = xmpData.regions, !regions.regions.isEmpty {
            complexProps += writeRegions(regions)
        }

        let hasComplexProps = !complexProps.isEmpty

        var xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="\(XMPNamespace.rdf)"\(nsDeclarations)>
        """

        if hasComplexProps {
            xml += "\n <rdf:Description rdf:about=\"\"\(simpleProps)>"
            xml += complexProps
            xml += "\n </rdf:Description>"
        } else {
            xml += "\n <rdf:Description rdf:about=\"\"\(simpleProps)/>"
        }

        xml += "\n</rdf:RDF>\n</x:xmpmeta>\n"

        // Add padding (2KB of spaces) for future in-place edits
        let padding = String(repeating: " ", count: 2048) + "\n"
        xml += padding
        xml += "<?xpacket end=\"w\"?>"

        return xml
    }

    /// Serialize MWG regions to XMP XML fragment.
    private static func writeRegions(_ regionList: XMPRegionList) -> String {
        var xml = "\n  <mwg-rs:Regions>"

        // AppliedToDimensions
        if let w = regionList.appliedToDimensionsW, let h = regionList.appliedToDimensionsH {
            let unit = regionList.appliedToDimensionsUnit ?? "pixel"
            xml += "\n   <mwg-rs:AppliedToDimensions stDim:w=\"\(w)\" stDim:h=\"\(h)\" stDim:unit=\"\(escapeXML(unit))\"/>"
        }

        // RegionList
        xml += "\n   <mwg-rs:RegionList>\n    <rdf:Bag>"

        for region in regionList.regions {
            xml += "\n     <rdf:li>"
            xml += "\n      <rdf:Description"
            if let name = region.name {
                xml += " mwg-rs:Name=\"\(escapeXML(name))\""
            }
            if let type = region.type {
                xml += " mwg-rs:Type=\"\(type.rawValue)\""
            }
            if let desc = region.description {
                xml += " mwg-rs:Description=\"\(escapeXML(desc))\""
            }
            xml += ">"
            let a = region.area
            xml += "\n       <mwg-rs:Area stArea:x=\"\(formatDouble(a.x))\" stArea:y=\"\(formatDouble(a.y))\""
            xml += " stArea:w=\"\(formatDouble(a.w))\" stArea:h=\"\(formatDouble(a.h))\""
            xml += " stArea:unit=\"\(escapeXML(a.unit))\"/>"
            xml += "\n      </rdf:Description>"
            xml += "\n     </rdf:li>"
        }

        xml += "\n    </rdf:Bag>\n   </mwg-rs:RegionList>"
        xml += "\n  </mwg-rs:Regions>"
        return xml
    }

    /// Format a double for XMP output, removing trailing zeros.
    private static func formatDouble(_ value: Double) -> String {
        let s = String(format: "%.6f", value)
        // Remove trailing zeros but keep at least one decimal place
        var trimmed = s
        while trimmed.hasSuffix("0") && !trimmed.hasSuffix(".0") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    // MARK: - Private

    /// Carried through the recursive emit helpers: generated prefixes for namespaces
    /// outside the known table, plus the container forms observed when the data was parsed.
    private struct EmitContext {
        let dynamic: [String: String]
        let observed: [String: XMPArrayForm]
    }

    /// Properties the XMP specification defines as ordered rdf:Seq arrays, keyed
    /// "<namespaceURI><localName>" like everything else. The writer emits these as Seq
    /// regardless of the parsed container — matching ExifTool, which normalizes
    /// container types from its tag tables on write. Includes nested struct-field
    /// keys (e.g. crs:CorrectionMasks inside a correction struct).
    static let seqProperties: Set<String> = {
        var keys: Set<String> = []
        func add(_ ns: String, _ names: String...) {
            for name in names { keys.insert("\(ns)\(name)") }
        }
        add(XMPNamespace.dc, "creator", "date")
        add(XMPNamespace.xmpMM, "History", "Versions")
        add(XMPNamespace.tiff, "BitsPerSample", "PrimaryChromaticities", "ReferenceBlackWhite",
            "TransferFunction", "WhitePoint", "YCbCrCoefficients", "YCbCrSubSampling")
        add(XMPNamespace.exif, "ComponentsConfiguration", "ISOSpeedRatings",
            "SubjectArea", "SubjectLocation")
        add(XMPNamespace.crs, "ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue",
            "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
            "GradientBasedCorrections", "PaintBasedCorrections", "CircularGradientBasedCorrections",
            "MaskGroupBasedCorrections", "RetouchAreas", "CorrectionMasks", "Masks", "Dabs")
        add(XMPNamespace.xmpDM, "markers")
        return keys
    }()

    /// The rdf container element ("Bag" or "Seq") for an array at `key`: the spec
    /// table wins, then the form the array was parsed with, then Bag.
    private static func containerElement(forKey key: String, context: EmitContext) -> String {
        if seqProperties.contains(key) { return "Seq" }
        return context.observed[key] == .seq ? "Seq" : "Bag"
    }

    /// Sorted namespace list (longest first) to avoid prefix ambiguity.
    /// e.g. "http://ns.adobe.com/xap/1.0/rights/" must match before "http://ns.adobe.com/xap/1.0/"
    private static let sortedPrefixes: [(ns: String, prefix: String)] = {
        XMPNamespace.prefixes.sorted { $0.key.count > $1.key.count }.map { (ns: $0.key, prefix: $0.value) }
    }()

    private static func resolveKey(_ key: String, dynamic: [String: String]) -> (prefix: String, localName: String, namespace: String)? {
        for entry in sortedPrefixes {
            if key.hasPrefix(entry.ns) {
                let localName = String(key.dropFirst(entry.ns.count))
                // Only match if the local name is a valid XML name (no slashes)
                guard !localName.isEmpty && !localName.contains("/") else { continue }
                return (entry.prefix, localName, entry.ns)
            }
        }
        if let split = splitUnknownKey(key), let prefix = dynamic[split.namespace] {
            return (prefix, split.localName, split.namespace)
        }
        return nil
    }

    /// Split a `"<namespaceURI><localName>"` key from an unknown namespace at its last
    /// '/' or '#'. XMP namespace URIs conventionally end with one of those, and an XML
    /// local name can contain neither, so the rightmost split is stable: re-reading the
    /// rewritten packet concatenates back to the identical key even when the split point
    /// differs from the original document's declaration.
    private static func splitUnknownKey(_ key: String) -> (namespace: String, localName: String)? {
        guard let idx = key.lastIndex(where: { $0 == "/" || $0 == "#" }) else { return nil }
        let namespace = String(key[...idx])
        let localName = String(key[key.index(after: idx)...])
        guard namespace.contains(":"), isValidXMLName(localName) else { return nil }
        return (namespace, localName)
    }

    /// Conservative NCName check for generated element/attribute local names.
    private static func isValidXMLName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Record the key's namespace: a known-table match goes to `known`; otherwise, when
    /// the key splits into a plausible URI + XML name, the URI goes to `unknown` (and
    /// later gets a generated prefix). Mirrors `resolveKey` so every classified key is
    /// actually serializable.
    private static func classifyKey(_ key: String, known: inout Set<String>, unknown: inout Set<String>) {
        for entry in sortedPrefixes where key.hasPrefix(entry.ns) {
            let localName = key.dropFirst(entry.ns.count)
            if !localName.isEmpty && !localName.contains("/") {
                known.insert(entry.ns)
                return
            }
        }
        if let split = splitUnknownKey(key) {
            unknown.insert(split.namespace)
        }
    }

    /// Recursively collect namespaces referenced by an XMPValue's nested fields.
    private static func collectNamespacesRecursive(_ value: XMPValue, known: inout Set<String>, unknown: inout Set<String>) {
        switch value {
        case .structure(let fields):
            for (key, child) in fields {
                classifyKey(key, known: &known, unknown: &unknown)
                collectNamespacesRecursive(child, known: &known, unknown: &unknown)
            }
        case .structuredArray(let items):
            for item in items {
                for (key, child) in item {
                    classifyKey(key, known: &known, unknown: &unknown)
                    collectNamespacesRecursive(child, known: &known, unknown: &unknown)
                }
            }
        case .simple, .array, .langAlternative, .languageAlternative:
            return
        }
    }

    /// Serialize a struct's fields as an `<rdf:Description>` element. `.simple` fields are emitted
    /// as XML attributes (compact form, preserving the existing on-disk shape for flat structures);
    /// any non-simple field becomes a child element so nested arrays/structs round-trip.
    private static func emitStructureBody(_ fields: [String: XMPValue], indent: String, context: EmitContext) -> String {
        var attrs: [(prefix: String, localName: String, value: String)] = []
        var children: [(key: String, prefix: String, localName: String, value: XMPValue)] = []

        for (fieldKey, fieldValue) in fields.sorted(by: { $0.key < $1.key }) {
            guard let parts = resolveKey(fieldKey, dynamic: context.dynamic) else { continue }
            if case .simple(let s) = fieldValue {
                attrs.append((parts.prefix, parts.localName, s))
            } else {
                children.append((fieldKey, parts.prefix, parts.localName, fieldValue))
            }
        }

        var xml = "\n\(indent)<rdf:Description"
        for attr in attrs {
            xml += " \(attr.prefix):\(attr.localName)=\"\(escapeXML(attr.value))\""
        }
        if children.isEmpty {
            xml += "/>"
        } else {
            xml += ">"
            for child in children {
                xml += emitFieldElement(key: child.key, prefix: child.prefix, localName: child.localName, value: child.value, indent: indent + " ", context: context)
            }
            xml += "\n\(indent)</rdf:Description>"
        }
        return xml
    }

    /// Serialize a single field as a child element of an enclosing `<rdf:Description>`.
    private static func emitFieldElement(key: String, prefix: String, localName: String, value: XMPValue, indent: String, context: EmitContext) -> String {
        var xml = "\n\(indent)<\(prefix):\(localName)>"
        switch value {
        case .simple(let s):
            // Element form for what's normally an attribute — used when the writer is given a
            // simple value mixed in among complex children. Round-trips back through the reader.
            xml += escapeXML(s)
        case .array(let items):
            let container = containerElement(forKey: key, context: context)
            xml += "\n\(indent) <rdf:\(container)>"
            for item in items {
                xml += "\n\(indent)  <rdf:li>\(escapeXML(item))</rdf:li>"
            }
            xml += "\n\(indent) </rdf:\(container)>"
        case .langAlternative(let s):
            xml += "\n\(indent) <rdf:Alt>"
            xml += "\n\(indent)  <rdf:li xml:lang=\"x-default\">\(escapeXML(s))</rdf:li>"
            xml += "\n\(indent) </rdf:Alt>"
        case .languageAlternative(let items):
            xml += "\n\(indent) <rdf:Alt>"
            for item in items {
                xml += "\n\(indent)  <rdf:li xml:lang=\"\(escapeXML(item.language))\">\(escapeXML(item.value))</rdf:li>"
            }
            xml += "\n\(indent) </rdf:Alt>"
        case .structure(let fields):
            xml += emitStructureBody(fields, indent: indent + " ", context: context)
        case .structuredArray(let items):
            let container = containerElement(forKey: key, context: context)
            xml += "\n\(indent) <rdf:\(container)>"
            for item in items {
                xml += "\n\(indent)  <rdf:li>"
                xml += emitStructureBody(item, indent: indent + "   ", context: context)
                xml += "\n\(indent)  </rdf:li>"
            }
            xml += "\n\(indent) </rdf:\(container)>"
        }
        xml += "\n\(indent)</\(prefix):\(localName)>"
        return xml
    }

    /// Escape a string for use in XML attribute values or element content.
    /// Tab/LF/CR become character references — required in attribute values, where a
    /// conforming parser normalizes the literal characters to spaces (XML 1.0 §3.3.3),
    /// which would silently flatten multi-line captions on round-trip. Remaining
    /// C0 control characters are illegal in XML 1.0 in any form and are stripped.
    private static func escapeXML(_ string: String) -> String {
        var out = String()
        out.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#xA;"
            case "\r": out += "&#xD;"
            case "\t": out += "&#x9;"
            default:
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
