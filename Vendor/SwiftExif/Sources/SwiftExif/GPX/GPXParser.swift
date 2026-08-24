import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses GPX XML files into GPXTrack structures.
/// Uses Foundation XMLParser (SAX-style) for zero-dependency XML parsing.
public struct GPXParser: Sendable {

    /// Parse a GPX file from a file URL.
    public static func parse(from url: URL) throws -> GPXTrack {
        let data = try Data(contentsOf: url)
        return try parse(from: data)
    }

    /// Parse GPX from XML data.
    public static func parse(from data: Data) throws -> GPXTrack {
        let delegate = GPXXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw MetadataError.invalidGPX(delegate.parseError ?? "Unknown XML parse error")
        }
        return GPXTrack(name: delegate.trackName, trackpoints: delegate.trackpoints)
    }

    /// Parse GPX from an XML string.
    public static func parse(from xmlString: String) throws -> GPXTrack {
        guard let data = xmlString.data(using: .utf8) else {
            throw MetadataError.invalidGPX("Failed to encode XML string as UTF-8")
        }
        return try parse(from: data)
    }
}

// MARK: - XMLParser Delegate

private class GPXXMLParserDelegate: NSObject, XMLParserDelegate {
    var trackpoints: [GPXTrackpoint] = []
    var trackName: String?
    var parseError: String?

    private var currentText = ""
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var inTrackpoint = false
    private var inTrack = false
    private var currentElement = ""

    nonisolated(unsafe) private static let withFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let noFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ string: String) -> Date? {
        if let d = withFracFormatter.date(from: string) { return d }
        return noFracFormatter.date(from: string)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "trk" {
            inTrack = true
        } else if elementName == "trkpt" || elementName == "wpt" {
            inTrackpoint = true
            currentLat = attributeDict["lat"].flatMap(Double.init)
            currentLon = attributeDict["lon"].flatMap(Double.init)
            currentEle = nil
            currentTime = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "trkpt" || elementName == "wpt" {
            if let lat = currentLat, let lon = currentLon, let time = currentTime {
                trackpoints.append(GPXTrackpoint(
                    latitude: lat, longitude: lon,
                    elevation: currentEle, timestamp: time
                ))
            }
            inTrackpoint = false
        } else if elementName == "ele" && inTrackpoint {
            currentEle = Double(text)
        } else if elementName == "time" && inTrackpoint {
            currentTime = Self.parseISO8601(text)
        } else if elementName == "name" && inTrack && !inTrackpoint {
            trackName = text
        } else if elementName == "trk" {
            inTrack = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError.localizedDescription
    }
}
