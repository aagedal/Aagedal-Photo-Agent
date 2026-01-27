import Foundation

struct PresetVariableInterpolator: Sendable {
    /// Resolves template variables in a string.
    /// Supported variables:
    /// - `{date}` — current date in default format (e.g., "Jan 27, 2026")
    /// - `{date:FORMAT}` — current date with custom DateFormatter format (e.g., `{date:dd.MM.yyyy}`)
    /// - `{filename}` — filename of the target image (without extension)
    /// - `{persons}` — comma-separated list of Person Shown names
    /// - `{keywords}` — comma-separated list of keywords
    /// - `{field:FIELDNAME}` — value from existing metadata (case-insensitive, matches key or label)
    func resolve(
        _ template: String,
        filename: String = "",
        existingMetadata: IPTCMetadata? = nil
    ) -> String {
        var result = template

        // {date} and {date:FORMAT}
        result = resolveDate(in: result)

        // {filename}
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        result = result.replacingOccurrences(of: "{filename}", with: nameWithoutExt)

        // {persons} shorthand
        if let metadata = existingMetadata {
            result = result.replacingOccurrences(
                of: "{persons}",
                with: metadata.personShown.joined(separator: ", ")
            )
            // {keywords} shorthand
            result = result.replacingOccurrences(
                of: "{keywords}",
                with: metadata.keywords.joined(separator: ", ")
            )
        } else {
            result = result.replacingOccurrences(of: "{persons}", with: "")
            result = result.replacingOccurrences(of: "{keywords}", with: "")
        }

        // {field:FIELDNAME}
        result = resolveFields(in: result, metadata: existingMetadata)

        return result
    }

    private func resolveDate(in template: String) -> String {
        var result = template

        // {date:FORMAT}
        let formatPattern = /\{date:([^}]+)\}/
        for match in result.matches(of: formatPattern) {
            let format = String(match.1)
            let formatter = DateFormatter()
            formatter.dateFormat = format
            let dateStr = formatter.string(from: Date())
            result = result.replacingOccurrences(of: String(match.0), with: dateStr)
        }

        // {date} (no format)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        result = result.replacingOccurrences(of: "{date}", with: formatter.string(from: Date()))

        return result
    }

    private func resolveFields(in template: String, metadata: IPTCMetadata?) -> String {
        var result = template
        let fieldPattern = /\{field:([^}]+)\}/

        for match in result.matches(of: fieldPattern) {
            let fieldName = String(match.1)
            let value = fieldValue(for: fieldName, from: metadata)
            result = result.replacingOccurrences(of: String(match.0), with: value)
        }

        return result
    }

    /// Matches field by key or display label, case-insensitive.
    private func fieldValue(for name: String, from metadata: IPTCMetadata?) -> String {
        guard let metadata else { return "" }

        // Build a lookup that accepts both keys and labels
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "title": return metadata.title ?? ""
        case "description": return metadata.description ?? ""
        case "keywords": return metadata.keywords.joined(separator: ", ")
        case "personshown", "persons": return metadata.personShown.joined(separator: ", ")
        case "creator": return metadata.creator ?? ""
        case "credit": return metadata.credit ?? ""
        case "copyright": return metadata.copyright ?? ""
        case "datecreated": return metadata.dateCreated ?? ""
        case "city": return metadata.city ?? ""
        case "country": return metadata.country ?? ""
        case "event": return metadata.event ?? ""
        case "digitalsourcetype": return metadata.digitalSourceType?.displayName ?? ""
        default: return ""
        }
    }
}
