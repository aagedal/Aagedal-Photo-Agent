import Foundation

/// SAX-style events emitted by `PureXMLTokenizer`, mirroring the subset of
/// `XMLParserDelegate` that the XMP reader relies on. Element names are reported as **local**
/// names with the resolved `namespaceURI` (namespace processing on); attribute keys are reported
/// **qualified** (prefix kept) and `xmlns` declarations are surfaced via `startPrefix`/`endPrefix`
/// rather than in the attribute dictionary — exactly how `XMLParser` behaves with
/// `shouldProcessNamespaces` + `shouldReportNamespacePrefixes` both true.
protocol PureXMLEvents: AnyObject {
    func startPrefix(_ prefix: String, uri: String)
    func endPrefix(_ prefix: String)
    func startElement(_ localName: String, namespaceURI: String?, attributes: [String: String])
    func endElement(_ localName: String, namespaceURI: String?)
    func characters(_ text: String)
    func tokenizerError(_ message: String)
    /// Polled between tokens so the consumer can halt parsing (e.g. a frame-depth cap).
    var shouldStop: Bool { get }
}

/// A small, dependency-free XML pull tokenizer scoped to the well-formed XMP packets this library
/// reads and writes (and the third-party XMP it must tolerate). It exists so XMP parsing has NO
/// libxml2 dependency: Foundation's `XMLParser` wraps libxml2, whose process-global state is not
/// thread-safe and can race other in-process libxml2 users (notably ImageIO) — surfacing as
/// `EXC_BAD_ACCESS` in unrelated code. This tokenizer is pure Swift and fully reentrant.
///
/// Handles: elements (open / close / self-closing), single- and double-quoted attributes, `xmlns`
/// and `xmlns:prefix` declarations (with XML scoping), entity references in text and attribute
/// values (`&lt; &gt; &amp; &quot; &apos;`, decimal `&#NN;`, hex `&#xHH;`), CDATA sections,
/// comments, processing instructions (`<?xml?>`, `<?xpacket?>`), and `<!DOCTYPE …>`. It does NOT
/// implement DTDs/entity definitions or validation — none of which appear in XMP.
final class PureXMLTokenizer {

    private weak var events: PureXMLEvents?
    private var chars: [Character] = []
    private var pos = 0

    /// One entry per currently-open element: its resolved local name + namespace, and the prefixes
    /// it declared (so the matching close tag pops the right namespace scope, innermost-first).
    private struct OpenElement {
        let localName: String
        let namespaceURI: String?
        let declaredPrefixes: [String]
    }
    private var openElements: [OpenElement] = []
    /// Namespace scopes parallel to `openElements`: prefix → URI declared at that element.
    private var scopes: [[String: String]] = []

    func parse(_ xml: String, events: PureXMLEvents) {
        self.events = events
        chars = Array(xml)
        pos = 0
        openElements = []
        scopes = []

        while pos < chars.count {
            if events.shouldStop { return }
            if chars[pos] == "<" {
                consumeMarkup()
            } else {
                consumeText()
            }
        }
    }

    // MARK: - Text

    private func consumeText() {
        let start = pos
        while pos < chars.count, chars[pos] != "<" {
            pos += 1
        }
        let raw = String(chars[start..<pos])
        // Mirror XMLParser, which reports character data between tags. Leading prolog whitespace is
        // harmless (the consumer resets its text buffer on each start element).
        if !raw.isEmpty {
            events?.characters(Self.unescape(raw))
        }
    }

    // MARK: - Markup dispatch

    private func consumeMarkup() {
        // pos is at '<'.
        if match("<!--") {
            skipUntil("-->")
            return
        }
        if match("<![CDATA[") {
            let start = pos
            let end = indexOf("]]>", from: pos)
            let text = String(chars[start..<(end ?? chars.count)])
            pos = end.map { $0 + 3 } ?? chars.count
            // CDATA content is literal — no entity processing.
            if !text.isEmpty { events?.characters(text) }
            return
        }
        if match("<!") {       // DOCTYPE or other declaration — skip to the closing '>'.
            skipUntil(">")
            return
        }
        if match("<?") {       // Processing instruction (<?xml?>, <?xpacket?>) — skip to '?>'.
            skipUntil("?>")
            return
        }
        if peek(1) == "/" {    // End tag.
            consumeEndTag()
            return
        }
        consumeStartTag()
    }

    // MARK: - Start tag

    private func consumeStartTag() {
        pos += 1  // past '<'
        let qName = readName()
        var declsOrdered: [(prefix: String, uri: String)] = []
        var attributes: [String: String] = [:]
        var selfClosing = false

        while pos < chars.count {
            skipWhitespace()
            guard pos < chars.count else { break }
            let c = chars[pos]
            if c == ">" {
                pos += 1
                break
            }
            if c == "/" {
                selfClosing = true
                pos += 1
                skipWhitespace()
                if pos < chars.count, chars[pos] == ">" { pos += 1 }
                break
            }
            // Attribute: name (= value)?
            let attrName = readName()
            if attrName.isEmpty {
                // Malformed — avoid an infinite loop by advancing.
                pos += 1
                continue
            }
            skipWhitespace()
            var value = ""
            if pos < chars.count, chars[pos] == "=" {
                pos += 1
                skipWhitespace()
                value = readAttributeValue()
            }
            if attrName == "xmlns" {
                declsOrdered.append((prefix: "", uri: value))
            } else if attrName.hasPrefix("xmlns:") {
                declsOrdered.append((prefix: String(attrName.dropFirst("xmlns:".count)), uri: value))
            } else {
                attributes[attrName] = value
            }
        }

        // Push this element's namespace scope BEFORE resolving its own prefix, so a namespace
        // declared on the same element resolves (mirrors XML scoping + XMLParser ordering).
        var scope: [String: String] = [:]
        for decl in declsOrdered { scope[decl.prefix] = decl.uri }
        scopes.append(scope)

        let (local, prefix) = Self.splitQName(qName)
        let namespaceURI = resolvePrefix(prefix)
        openElements.append(OpenElement(
            localName: local,
            namespaceURI: namespaceURI,
            declaredPrefixes: declsOrdered.map(\.prefix)
        ))

        // XMLParser fires didStartMappingPrefix before didStartElement, in declaration order.
        for decl in declsOrdered { events?.startPrefix(decl.prefix, uri: decl.uri) }
        events?.startElement(local, namespaceURI: namespaceURI, attributes: attributes)

        if selfClosing {
            closeTop()
        }
    }

    // MARK: - End tag

    private func consumeEndTag() {
        pos += 2  // past '</'
        _ = readName()
        skipUntil(">")
        closeTop()
    }

    /// Emit endElement (then endPrefix for the element's declarations, innermost-first) and pop the
    /// element + its namespace scope. Uses the resolved name/namespace captured at the start tag so
    /// open/close report identical values, exactly as XMLParser does.
    private func closeTop() {
        guard let element = openElements.popLast() else { return }
        events?.endElement(element.localName, namespaceURI: element.namespaceURI)
        // XMLParser fires didEndElement before didEndMappingPrefix.
        for prefix in element.declaredPrefixes.reversed() { events?.endPrefix(prefix) }
        if !scopes.isEmpty { scopes.removeLast() }
    }

    // MARK: - Namespace resolution

    /// Resolve a prefix to its URI using the live scope stack (innermost declaration wins). Returns
    /// nil for an unprefixed element with no default namespace in scope.
    private func resolvePrefix(_ prefix: String) -> String? {
        for scope in scopes.reversed() {
            if let uri = scope[prefix] { return uri.isEmpty ? nil : uri }
        }
        return nil
    }

    private static func splitQName(_ qName: String) -> (local: String, prefix: String) {
        guard let colon = qName.firstIndex(of: ":") else { return (qName, "") }
        return (String(qName[qName.index(after: colon)...]), String(qName[..<colon]))
    }

    // MARK: - Low-level scanning

    private func peek(_ offset: Int) -> Character? {
        let i = pos + offset
        return i < chars.count ? chars[i] : nil
    }

    /// If the upcoming characters equal `literal`, consume them and return true.
    private func match(_ literal: String) -> Bool {
        let lit = Array(literal)
        guard pos + lit.count <= chars.count else { return false }
        for (i, c) in lit.enumerated() where chars[pos + i] != c { return false }
        pos += lit.count
        return true
    }

    private func indexOf(_ literal: String, from start: Int) -> Int? {
        let lit = Array(literal)
        guard !lit.isEmpty else { return start }
        var i = start
        while i + lit.count <= chars.count {
            var matched = true
            for (j, c) in lit.enumerated() where chars[i + j] != c { matched = false; break }
            if matched { return i }
            i += 1
        }
        return nil
    }

    /// Advance past the next occurrence of `literal` (to just after it). Jumps to end if absent.
    private func skipUntil(_ literal: String) {
        if let i = indexOf(literal, from: pos) {
            pos = i + literal.count
        } else {
            pos = chars.count
        }
    }

    private func skipWhitespace() {
        while pos < chars.count, chars[pos].isXMLWhitespace {
            pos += 1
        }
    }

    /// Read an element/attribute name: up to whitespace, '=', '/', '>', or '<'.
    private func readName() -> String {
        let start = pos
        while pos < chars.count {
            let c = chars[pos]
            if c.isXMLWhitespace || c == "=" || c == "/" || c == ">" || c == "<" { break }
            pos += 1
        }
        return String(chars[start..<pos])
    }

    /// Read a quoted attribute value (single or double quotes) and unescape entities. Tolerates an
    /// unquoted value by reading to the next whitespace or '>'.
    private func readAttributeValue() -> String {
        guard pos < chars.count else { return "" }
        let quote = chars[pos]
        if quote == "\"" || quote == "'" {
            pos += 1
            let start = pos
            while pos < chars.count, chars[pos] != quote { pos += 1 }
            let raw = String(chars[start..<pos])
            if pos < chars.count { pos += 1 } // closing quote
            return Self.unescape(raw)
        }
        // Unquoted (malformed but tolerated).
        let start = pos
        while pos < chars.count, !chars[pos].isXMLWhitespace, chars[pos] != ">", chars[pos] != "/" {
            pos += 1
        }
        return Self.unescape(String(chars[start..<pos]))
    }

    // MARK: - Entities

    /// Resolve XML entity references: the five predefined entities plus decimal (`&#NN;`) and hex
    /// (`&#xHH;`) numeric character references. Unknown entities are left verbatim.
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        let scalars = Array(s)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "&", let semicolon = scalars[(i + 1)...].firstIndex(of: ";") else {
                out.append(scalars[i])
                i += 1
                continue
            }
            let entity = String(scalars[(i + 1)..<semicolon])
            if let replacement = Self.resolveEntity(entity) {
                out.append(replacement)
                i = semicolon + 1
            } else {
                out.append("&")
                i += 1
            }
        }
        return out
    }

    private static func resolveEntity(_ entity: String) -> Character? {
        switch entity {
        case "lt": return "<"
        case "gt": return ">"
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let body = entity.dropFirst()
            let scalarValue: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalarValue = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(body, radix: 10)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
    }
}

private extension Character {
    var isXMLWhitespace: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\r"
    }
}
