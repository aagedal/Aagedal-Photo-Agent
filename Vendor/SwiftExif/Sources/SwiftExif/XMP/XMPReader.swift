import Foundation

/// Parse XMP XML from an APP1 segment or raw XML data.
public struct XMPReader: Sendable {

    /// Maximum frameStack depth for the SAX parser. Real-world XMP nests at most a
    /// few levels; the cap stops a crafted packet from growing the stack
    /// unboundedly via deeply nested `rdf:Bag`/`Seq`/`Alt`/`Description`
    /// containers.
    static let maxFrameDepth = 64

    /// Parse XMP data from APP1 segment payload (after XMP namespace identifier).
    public static func read(from data: Data) throws -> XMPData {
        // Skip the XMP identifier prefix
        let identifierData = JPEGSegment.xmpIdentifier
        guard data.count > identifierData.count,
              data.prefix(identifierData.count) == identifierData else {
            throw MetadataError.invalidXMP("Missing XMP identifier")
        }

        let xmlData = data.suffix(from: data.startIndex + identifierData.count)
        return try readFromXML(Data(xmlData))
    }

    /// Parse XMP from raw XML data (no JPEG identifier prefix).
    /// Used for TIFF XMP tag (0x02BC), PNG iTXt, JPEG XL xml box, AVIF XMP.
    public static func readFromXML(_ data: Data) throws -> XMPData {
        let trimmed = trimXMPPacketPadding(data)
        guard let xmlString = String(data: trimmed, encoding: .utf8) else {
            throw MetadataError.invalidXMP("Failed to decode XMP as UTF-8")
        }

        let parser = XMPXMLParser(xmlString: xmlString)
        return try parser.parse()
    }

    /// Strip the trailing padding that XMP writers append after the closing
    /// `<?xpacket end="..."?>` processing instruction. Adobe's XMP spec lets
    /// writers pad packets so they can be edited in place; some writers leave
    /// NUL bytes or non-XML whitespace bytes past the PI, which NSXMLParser
    /// rejects as "extra content at end of document". When no xpacket PI is
    /// present, fall back to trimming trailing NULs.
    static func trimXMPPacketPadding(_ data: Data) -> Data {
        let endMarker = Data("<?xpacket end=".utf8)
        if let endRange = data.range(of: endMarker) {
            let piClose = Data("?>".utf8)
            if let closeRange = data.range(of: piClose, in: endRange.upperBound..<data.endIndex) {
                return data.subdata(in: data.startIndex..<closeRange.upperBound)
            }
        }
        // No xpacket end PI — strip trailing NUL bytes (whitespace is legal in the epilog).
        var end = data.endIndex
        while end > data.startIndex, data[end - 1] == 0x00 {
            end -= 1
        }
        return data.subdata(in: data.startIndex..<end)
    }
}

// MARK: - SAX Parser

private final class XMPXMLParser: PureXMLEvents {
    let xmlString: String
    /// Set when the frame-depth cap is hit; polled by the tokenizer via `shouldStop` to halt.
    private var aborted = false
    var shouldStop: Bool { aborted }
    private var properties: [String: XMPValue] = [:]
    /// Container form (Bag vs Seq) per array key, so the writer can round-trip it.
    private var arrayForms: [String: XMPArrayForm] = [:]
    private var currentElement = ""
    private var currentNamespace = ""
    private var currentText = ""
    private var inDescription = false
    private var inBag = false
    private var inSeq = false
    private var inAlt = false
    private var currentArrayItems: [String] = []
    private var currentLanguageAlternatives: [XMPLanguageAlternative] = []
    private var currentAlternativeLanguage = "x-default"
    private var currentArrayProperty = ""
    private var currentArrayNamespace = ""
    private var parseError: Error?

    // MWG Region parsing state
    private var inRegions = false
    private var inRegionList = false
    private var inRegionItem = false
    private var regionListRegions: [XMPRegion] = []
    private var currentRegionName: String?
    private var currentRegionType: String?
    private var currentRegionArea: XMPRegionArea?
    private var currentRegionDescription: String?
    private var appliedDimW: Int?
    private var appliedDimH: Int?
    private var appliedDimUnit: String?
    private var regionList: XMPRegionList?

    // Structure parsing state
    private var inStructuredItem = false
    private var currentStructureFields: [String: XMPValue] = [:]
    private var currentStructuredArrayItems: [[String: XMPValue]] = []
    private var isStructuredBag = false
    private var inPropertyStructure = false
    private var propertyStructureFields: [String: XMPValue] = [:]
    private var propertyStructureProperty = ""
    private var propertyStructureNamespace = ""
    private var structureChildElement = ""
    private var structureChildNamespace = ""
    /// Tracks when we're inside a property element awaiting a value (child Bag/Alt/simple text or nested Description).
    private var inPendingProperty = false

    /// Stack of paused parsing frames. Pushed when a nested container (rdf:Bag / rdf:Seq /
    /// rdf:Alt / rdf:Description) appears as a child of a struct field — we save the outer
    /// frame's state, reset, parse the inner container fresh, then on the matching close-tag
    /// restore the outer state and assign the inner value as a field of its parent struct.
    /// Without this, anything nested deeper than a single rdf:Description is silently dropped.
    private var frameStack: [NestedFrame] = []
    private struct NestedFrame {
        let triggeringElement: String   // "Bag" | "Seq" | "Alt" | "Description"
        let parentFieldKey: String      // namespaced key to store the result under
        /// Whether the parent frame was a structured-array item (vs property-structure or top-level).
        let parentWasStructuredItem: Bool
        let parentWasPropertyStructure: Bool

        let savedCurrentStructureFields: [String: XMPValue]
        let savedCurrentStructuredArrayItems: [[String: XMPValue]]
        let savedCurrentArrayItems: [String]
        let savedCurrentLanguageAlternatives: [XMPLanguageAlternative]
        let savedCurrentAlternativeLanguage: String
        let savedCurrentArrayProperty: String
        let savedCurrentArrayNamespace: String
        let savedInBag: Bool
        let savedInSeq: Bool
        let savedInAlt: Bool
        let savedIsStructuredBag: Bool
        let savedInStructuredItem: Bool
        let savedInPropertyStructure: Bool
        let savedPropertyStructureFields: [String: XMPValue]
        let savedPropertyStructureProperty: String
        let savedPropertyStructureNamespace: String
        let savedStructureChildElement: String
        let savedStructureChildNamespace: String
        let savedInPendingProperty: Bool
    }

    /// Stack of active xmlns prefix → URI mappings. XMLParser doesn't resolve attribute namespaces,
    /// so we honor the document's live declarations to avoid silently dropping unknown-prefix attribute-form
    /// properties (which is how Lightroom/Capture One/Photo Mechanic write most fields).
    private var prefixStack: [(prefix: String, uri: String)] = []

    init(xmlString: String) {
        self.xmlString = xmlString
    }

    func parse() throws -> XMPData {
        // Pure-Swift tokenizer (no libxml2) drives the same SAX building logic — see
        // PureXMLTokenizer for why Foundation's XMLParser is avoided here.
        PureXMLTokenizer().parse(xmlString, events: self)

        if let error = parseError {
            throw error
        }

        var result = XMPData(xmlString: xmlString, properties: properties, regions: regionList)
        result.arrayForms = arrayForms
        return result
    }

    // MARK: - PureXMLEvents

    func startElement(_ elementName: String, namespaceURI: String?, attributes attributeDict: [String: String]) {
        currentText = ""

        // MWG Region handling
        if namespaceURI == XMPNamespace.mwgRegions && elementName == "Regions" {
            inRegions = true
            return
        }
        if inRegions && namespaceURI == XMPNamespace.mwgRegions && elementName == "RegionList" {
            inRegionList = true
            regionListRegions = []
            return
        }
        if inRegions && namespaceURI == XMPNamespace.mwgRegions && elementName == "AppliedToDimensions" {
            // Dimensions stored as attributes: stDim:w, stDim:h, stDim:unit
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prop = String(parts[1])
                    switch prop {
                    case "w": appliedDimW = Int(value)
                    case "h": appliedDimH = Int(value)
                    case "unit": appliedDimUnit = value
                    default: break
                    }
                }
            }
            return
        }
        if inRegionList && elementName == "li" {
            inRegionItem = true
            currentRegionName = nil
            currentRegionType = nil
            currentRegionArea = nil
            currentRegionDescription = nil
            return
        }
        if inRegionItem && elementName == "Description" {
            // Region properties may be attributes on rdf:Description
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if prefix == "mwg-rs" {
                        switch prop {
                        case "Name": currentRegionName = value
                        case "Type": currentRegionType = value
                        case "Description": currentRegionDescription = value
                        default: break
                        }
                    }
                }
            }
            return
        }
        if inRegionItem && namespaceURI == XMPNamespace.mwgRegions && elementName == "Area" {
            // Area properties as stArea: attributes
            var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
            var unit = "normalized"
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prop = String(parts[1])
                    switch prop {
                    case "x": x = Double(value) ?? 0
                    case "y": y = Double(value) ?? 0
                    case "w": w = Double(value) ?? 0
                    case "h": h = Double(value) ?? 0
                    case "unit": unit = value
                    default: break
                    }
                }
            }
            currentRegionArea = XMPRegionArea(x: x, y: y, w: w, h: h, unit: unit)
            return
        }

        // Standard XMP handling (skip when inside regions)
        if inRegions { return }

        // Detect nested-container start FIRST — before the inPropertyStructure / inStructuredItem
        // handlers below would clobber `structureChildElement` for a value-bearing child element
        // (Bag / Seq / Alt / Description). When we're already collecting fields for a struct AND
        // the field-element has been seen (`structureChildElement` is set), the next container
        // element supplies that field's value: push the outer frame, parse the inner container
        // fresh, and let the matching close-tag pop and assign.
        if shouldDescend(elementName: elementName) {
            if descend(triggeringElement: elementName, attributes: attributeDict) {
                return  // Description trigger fully handled in descend(), or depth cap hit.
            }
            // Bag/Seq/Alt: fall through so the existing element-start branches fire at the
            // inner frame's reset state.
        }

        // Handle structure child elements (rdf:parseType="Resource" style)
        if inPropertyStructure {
            structureChildElement = elementName
            structureChildNamespace = namespaceURI ?? ""
            currentText = ""
            return
        }

        // Handle structured items inside Bag/Seq (Description inside li)
        if inStructuredItem && elementName == "Description" {
            // Parse attributes as structure fields
            for (key, value) in attributeDict {
                if Self.isMetaAttribute(key) { continue }
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if let ns = resolvePrefix(prefix) {
                        currentStructureFields["\(ns)\(prop)"] = .simple(value)
                    }
                }
            }
            return
        }
        if inStructuredItem {
            // Child element inside a structured item (element form)
            structureChildElement = elementName
            structureChildNamespace = namespaceURI ?? ""
            currentText = ""
            return
        }

        if elementName == "Description" && inPendingProperty {
            // Nested rdf:Description inside a property element → structure
            inPropertyStructure = true
            propertyStructureProperty = currentArrayProperty
            propertyStructureNamespace = currentArrayNamespace
            inPendingProperty = false
            // Parse attributes as structure fields
            for (key, value) in attributeDict {
                if Self.isMetaAttribute(key) { continue }
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if let ns = resolvePrefix(prefix) {
                        propertyStructureFields["\(ns)\(prop)"] = .simple(value)
                    }
                }
            }
        } else if elementName == "Description" {
            inDescription = true
            // Some simple properties are stored as attributes on rdf:Description
            for (key, value) in attributeDict {
                if !Self.isMetaAttribute(key) {
                    // Try to resolve the qualified name to namespace + property
                    let parts = key.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let prefix = String(parts[0])
                        let prop = String(parts[1])
                        if let ns = resolvePrefix(prefix) {
                            properties["\(ns)\(prop)"] = .simple(value)
                        }
                    }
                }
            }
        } else if elementName == "Bag" {
            inBag = true
            inPendingProperty = false
            currentArrayItems = []
            isStructuredBag = false
            currentStructuredArrayItems = []
        } else if elementName == "Seq" {
            inSeq = true
            inPendingProperty = false
            currentArrayItems = []
            isStructuredBag = false
            currentStructuredArrayItems = []
        } else if elementName == "Alt" {
            inAlt = true
            inPendingProperty = false
            currentArrayItems = []
            currentLanguageAlternatives = []
            currentAlternativeLanguage = "x-default"
        } else if elementName == "li" {
            currentText = ""
            if inAlt {
                currentAlternativeLanguage = attributeDict["xml:lang"]
                    ?? attributeDict["lang"]
                    ?? "x-default"
            }
            // Inside a Bag or Seq, prepare for a potential structured item. ACR writes
            // structured arrays as rdf:Seq, and an item's fields may be attribute-form
            // directly on the li (<rdf:li crs:Top="..."/>) with no Description child.
            if inBag || inSeq {
                inStructuredItem = true
                currentStructureFields = [:]
                for (key, value) in attributeDict {
                    if Self.isMetaAttribute(key) { continue }
                    let parts = key.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let prefix = String(parts[0])
                        let prop = String(parts[1])
                        if let ns = resolvePrefix(prefix) {
                            currentStructureFields["\(ns)\(prop)"] = .simple(value)
                        }
                    }
                }
            }
        } else if inDescription && !inBag && !inSeq && !inAlt {
            // This is a property element — remember it for potential child arrays
            currentElement = elementName
            currentNamespace = namespaceURI ?? ""
            currentArrayProperty = elementName
            currentArrayNamespace = namespaceURI ?? ""
            inPendingProperty = true

            // Check for rdf:parseType="Resource" indicating a single structure
            if attributeDict["rdf:parseType"] == "Resource" || attributeDict["parseType"] == "Resource" {
                inPropertyStructure = true
                inPendingProperty = false
                propertyStructureFields = [:]
                propertyStructureProperty = elementName
                propertyStructureNamespace = namespaceURI ?? ""
            } else {
                // Check for structure attributes directly on the property element (compact form)
                var structAttrs: [String: XMPValue] = [:]
                for (key, value) in attributeDict {
                    if Self.isMetaAttribute(key) { continue }
                    let parts = key.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let prefix = String(parts[0])
                        let prop = String(parts[1])
                        if let ns = resolvePrefix(prefix) {
                            structAttrs["\(ns)\(prop)"] = .simple(value)
                        }
                    }
                }
                if !structAttrs.isEmpty {
                    // This property element has namespaced attributes — treat as single structure
                    inPropertyStructure = true
                    inPendingProperty = false
                    propertyStructureFields = structAttrs
                    propertyStructureProperty = elementName
                    propertyStructureNamespace = namespaceURI ?? ""
                }
            }
        }
    }

    func characters(_ string: String) {
        currentText += string
    }

    func endElement(_ elementName: String, namespaceURI: String?) {
        // MWG Region end handling
        if namespaceURI == XMPNamespace.mwgRegions && elementName == "Regions" {
            inRegions = false
            if !regionListRegions.isEmpty || appliedDimW != nil {
                regionList = XMPRegionList(
                    regions: regionListRegions,
                    appliedToDimensionsW: appliedDimW,
                    appliedToDimensionsH: appliedDimH,
                    appliedToDimensionsUnit: appliedDimUnit
                )
            }
            return
        }
        if inRegionList && namespaceURI == XMPNamespace.mwgRegions && elementName == "RegionList" {
            inRegionList = false
            return
        }
        if inRegionItem && elementName == "li" {
            if let area = currentRegionArea {
                regionListRegions.append(XMPRegion(
                    name: currentRegionName,
                    type: currentRegionType.flatMap { XMPRegionType(rawValue: $0) },
                    area: area,
                    description: currentRegionDescription
                ))
            }
            inRegionItem = false
            return
        }
        if inRegionItem {
            // Handle region properties as child elements (not just attributes)
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && namespaceURI == XMPNamespace.mwgRegions {
                switch elementName {
                case "Name": currentRegionName = trimmed
                case "Type": currentRegionType = trimmed
                case "Description": currentRegionDescription = trimmed
                default: break
                }
            }
            return
        }
        if inRegions { return }

        // Description-triggered nested frame: when the close-tag matches the rdf:Description we
        // descended into, build the struct value and ascend instead of storing top-level.
        if elementName == "Description",
           let frame = frameStack.last, frame.triggeringElement == "Description" {
            let value: XMPValue = .structure(propertyStructureFields)
            ascend(value: value)
            return
        }

        // Handle end of structure child elements
        if inPropertyStructure && elementName != propertyStructureProperty {
            if elementName == "Description" {
                // End of rdf:Description inside the property — fields already captured
                return
            }
            // Child element text value
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let ns = namespaceURI, !ns.isEmpty {
                propertyStructureFields["\(ns)\(elementName)"] = .simple(trimmed)
            }
            structureChildElement = ""
            structureChildNamespace = ""
            return
        }

        // End of property structure element
        if inPropertyStructure && elementName == propertyStructureProperty {
            if !propertyStructureFields.isEmpty {
                let key = "\(propertyStructureNamespace)\(propertyStructureProperty)"
                properties[key] = .structure(propertyStructureFields)
            }
            inPropertyStructure = false
            propertyStructureFields = [:]
            propertyStructureProperty = ""
            propertyStructureNamespace = ""
            return
        }

        // Handle structured items inside bag
        if inStructuredItem && elementName != "li" && elementName != "Description" {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let ns = namespaceURI, !ns.isEmpty {
                currentStructureFields["\(ns)\(elementName)"] = .simple(trimmed)
            }
            structureChildElement = ""
            structureChildNamespace = ""
            return
        }
        if inStructuredItem && elementName == "Description" {
            // End of rdf:Description inside li — fields already captured from attributes
            return
        }

        // Standard XMP handling
        if elementName == "Description" {
            inDescription = false
        } else if elementName == "li" {
            if inStructuredItem && !currentStructureFields.isEmpty {
                // This was a structured item in a Bag
                isStructuredBag = true
                currentStructuredArrayItems.append(currentStructureFields)
                inStructuredItem = false
                currentStructureFields = [:]
            } else {
                inStructuredItem = false
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if inAlt {
                    currentLanguageAlternatives.append(XMPLanguageAlternative(
                        language: currentAlternativeLanguage,
                        value: trimmed
                    ))
                    currentAlternativeLanguage = "x-default"
                } else if !trimmed.isEmpty {
                    currentArrayItems.append(trimmed)
                }
            }
        } else if elementName == "Bag" || elementName == "Seq" {
            // Build the result value first so we can either store as a top-level property
            // or hand it back to a paused parent frame.
            let builtValue: XMPValue
            if isStructuredBag && !currentStructuredArrayItems.isEmpty {
                builtValue = .structuredArray(currentStructuredArrayItems)
            } else {
                builtValue = .array(currentArrayItems)
            }

            let form: XMPArrayForm = elementName == "Seq" ? .seq : .bag
            if let frame = frameStack.last, frame.triggeringElement == elementName {
                arrayForms[frame.parentFieldKey] = form
                ascend(value: builtValue)
            } else if !currentArrayNamespace.isEmpty && !currentArrayProperty.isEmpty {
                let key = "\(currentArrayNamespace)\(currentArrayProperty)"
                properties[key] = builtValue
                arrayForms[key] = form
                inBag = false
                inSeq = false
                isStructuredBag = false
                currentArrayItems = []
                currentStructuredArrayItems = []
            } else {
                inBag = false
                inSeq = false
                isStructuredBag = false
                currentArrayItems = []
                currentStructuredArrayItems = []
            }
        } else if elementName == "Alt" {
            // Keep 1.9.10's scalar case for the overwhelmingly common single x-default form so
            // existing clients retain source/shape compatibility. Any genuinely localized or
            // empty alternative uses the lossless ordered carrier.
            let builtValue: XMPValue
            if currentLanguageAlternatives.count == 1,
               let only = currentLanguageAlternatives.first,
               only.language.caseInsensitiveCompare("x-default") == .orderedSame {
                builtValue = .langAlternative(only.value)
            } else {
                builtValue = .languageAlternative(currentLanguageAlternatives)
            }
            if let frame = frameStack.last, frame.triggeringElement == "Alt" {
                ascend(value: builtValue)
            } else if !currentArrayNamespace.isEmpty, !currentArrayProperty.isEmpty {
                properties["\(currentArrayNamespace)\(currentArrayProperty)"] = builtValue
                inAlt = false
                currentArrayItems = []
                currentLanguageAlternatives = []
            } else {
                inAlt = false
                currentArrayItems = []
                currentLanguageAlternatives = []
            }
        } else if inDescription && !inBag && !inSeq && !inAlt {
            inPendingProperty = false
            // Only store as simple if this key wasn't already set (by a child Bag/Seq/Alt/structure)
            let key = "\(namespaceURI ?? "")\(elementName)"
            if properties[key] == nil {
                let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, namespaceURI != nil {
                    properties[key] = .simple(trimmed)
                }
            }
        }
    }

    func tokenizerError(_ message: String) {
        // Keep the first error: the frame-depth cap also routes through here and must not clobber
        // a more specific earlier message.
        if parseError == nil {
            parseError = MetadataError.invalidXMP(message)
        }
    }

    func startPrefix(_ prefix: String, uri namespaceURI: String) {
        prefixStack.append((prefix, namespaceURI))
    }

    func endPrefix(_ prefix: String) {
        if let idx = prefixStack.lastIndex(where: { $0.prefix == prefix }) {
            prefixStack.remove(at: idx)
        }
    }

    private func resolvePrefix(_ prefix: String) -> String? {
        // Innermost xmlns declaration wins — mirrors XML scoping rules.
        if let uri = prefixStack.reversed().first(where: { $0.prefix == prefix })?.uri {
            return uri
        }
        // Fallback for documents that reference a prefix without declaring xmlns (malformed but tolerated).
        return XMPNamespace.namespace(for: prefix)
    }

    /// RDF/XML meta-attributes that exist for parser control, not as user metadata. These must
    /// never be stored as properties (rdf:about, xml:lang, etc. are infrastructure).
    private static func isMetaAttribute(_ key: String) -> Bool {
        if key.hasPrefix("xmlns") { return true }
        if key == "about" || key == "parseType" || key == "ID" || key == "nodeID" || key == "resource" { return true }
        if key.hasPrefix("rdf:") || key.hasPrefix("xml:") { return true }
        return false
    }

    // MARK: - Nested-container stack

    /// True when an element-start indicates a nested container value inside a struct field.
    /// The trigger: we're inside a struct (structured-array item or property-structure), the most
    /// recent child element opened is the field name (structureChildElement), and now we see a
    /// container element that supplies that field's value.
    private func shouldDescend(elementName: String) -> Bool {
        guard inStructuredItem || inPropertyStructure else { return false }
        guard !structureChildElement.isEmpty else { return false }
        return elementName == "Bag" || elementName == "Seq"
            || elementName == "Alt" || elementName == "Description"
    }

    /// Push the current frame and reset state to begin parsing a nested container fresh.
    /// Returns true if the trigger element was fully handled (Description trigger, or the
    /// depth cap was hit and parsing was aborted), in which case the caller should return
    /// from didStartElement immediately. False otherwise (Bag/Seq/Alt) — the existing
    /// handlers run at the inner level after descend.
    private func descend(triggeringElement: String, attributes: [String: String]) -> Bool {
        guard frameStack.count < XMPReader.maxFrameDepth else {
            parseError = MetadataError.invalidXMP(
                "Frame stack depth exceeds limit (\(XMPReader.maxFrameDepth))"
            )
            aborted = true
            return true
        }
        let parentKey = "\(structureChildNamespace)\(structureChildElement)"
        frameStack.append(NestedFrame(
            triggeringElement: triggeringElement,
            parentFieldKey: parentKey,
            parentWasStructuredItem: inStructuredItem,
            parentWasPropertyStructure: inPropertyStructure,
            savedCurrentStructureFields: currentStructureFields,
            savedCurrentStructuredArrayItems: currentStructuredArrayItems,
            savedCurrentArrayItems: currentArrayItems,
            savedCurrentLanguageAlternatives: currentLanguageAlternatives,
            savedCurrentAlternativeLanguage: currentAlternativeLanguage,
            savedCurrentArrayProperty: currentArrayProperty,
            savedCurrentArrayNamespace: currentArrayNamespace,
            savedInBag: inBag,
            savedInSeq: inSeq,
            savedInAlt: inAlt,
            savedIsStructuredBag: isStructuredBag,
            savedInStructuredItem: inStructuredItem,
            savedInPropertyStructure: inPropertyStructure,
            savedPropertyStructureFields: propertyStructureFields,
            savedPropertyStructureProperty: propertyStructureProperty,
            savedPropertyStructureNamespace: propertyStructureNamespace,
            savedStructureChildElement: structureChildElement,
            savedStructureChildNamespace: structureChildNamespace,
            savedInPendingProperty: inPendingProperty
        ))

        // Reset to a pristine state so the triggering element parses as if at top level.
        inBag = false
        inSeq = false
        inAlt = false
        inStructuredItem = false
        inPropertyStructure = false
        inPendingProperty = false
        isStructuredBag = false
        currentStructureFields = [:]
        currentStructuredArrayItems = []
        currentArrayItems = []
        currentLanguageAlternatives = []
        currentAlternativeLanguage = "x-default"
        currentArrayProperty = ""
        currentArrayNamespace = ""
        propertyStructureFields = [:]
        propertyStructureProperty = ""
        propertyStructureNamespace = ""
        structureChildElement = ""
        structureChildNamespace = ""

        // Description trigger: collect the rdf:Description's attributes ourselves (the existing
        // attribute-parsing branches all require flags we just cleared). The matching close-tag
        // is detected in didEndElement and ascends with `.structure(propertyStructureFields)`.
        if triggeringElement == "Description" {
            inPropertyStructure = true
            propertyStructureProperty = "Description"
            propertyStructureNamespace = ""
            for (key, value) in attributes {
                if Self.isMetaAttribute(key) { continue }
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let prefix = String(parts[0])
                    let prop = String(parts[1])
                    if let ns = resolvePrefix(prefix) {
                        propertyStructureFields["\(ns)\(prop)"] = .simple(value)
                    }
                }
            }
            return true
        }
        return false
    }

    /// Pop a frame: restore outer state and assign the inner value to the parent struct field.
    private func ascend(value: XMPValue) {
        guard let frame = frameStack.popLast() else { return }

        currentStructureFields = frame.savedCurrentStructureFields
        currentStructuredArrayItems = frame.savedCurrentStructuredArrayItems
        currentArrayItems = frame.savedCurrentArrayItems
        currentLanguageAlternatives = frame.savedCurrentLanguageAlternatives
        currentAlternativeLanguage = frame.savedCurrentAlternativeLanguage
        currentArrayProperty = frame.savedCurrentArrayProperty
        currentArrayNamespace = frame.savedCurrentArrayNamespace
        inBag = frame.savedInBag
        inSeq = frame.savedInSeq
        inAlt = frame.savedInAlt
        isStructuredBag = frame.savedIsStructuredBag
        inStructuredItem = frame.savedInStructuredItem
        inPropertyStructure = frame.savedInPropertyStructure
        propertyStructureFields = frame.savedPropertyStructureFields
        propertyStructureProperty = frame.savedPropertyStructureProperty
        propertyStructureNamespace = frame.savedPropertyStructureNamespace
        // The field-element that triggered this nested value is now consumed.
        structureChildElement = ""
        structureChildNamespace = ""
        inPendingProperty = frame.savedInPendingProperty
        // Clear leftover text from the inner container so the parent's field-end-tag handler
        // (line ~367, which converts trailing text to .simple) doesn't overwrite the value
        // we just stored on the parent struct.
        currentText = ""

        // Assign the popped value to the appropriate parent container.
        if frame.parentWasStructuredItem {
            currentStructureFields[frame.parentFieldKey] = value
        } else if frame.parentWasPropertyStructure {
            propertyStructureFields[frame.parentFieldKey] = value
        }
    }
}
