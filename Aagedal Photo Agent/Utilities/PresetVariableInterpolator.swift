import Foundation

struct PresetVariableInterpolator: Sendable {
    private static let gpsCityToken = "{gps:city}"
    private static let gpsCountryToken = "{gps:country}"

    /// Resolves the two place-name variables with one reverse-geocode lookup, then returns a
    /// metadata copy that can continue through the normal synchronous variable interpolator.
    /// On lookup failure the tokens are deliberately preserved so processing can be retried.
    func resolvingGPSPlaceVariables(in metadata: IPTCMetadata) async -> IPTCMetadata {
        let strings = [
            metadata.title, metadata.description, metadata.extendedDescription,
            metadata.creator, metadata.credit, metadata.copyright, metadata.jobId,
            metadata.dateCreated, metadata.city, metadata.country, metadata.event,
        ].compactMap { $0 } + metadata.keywords + metadata.personShown
        guard strings.contains(where: {
            $0.contains(Self.gpsCityToken) || $0.contains(Self.gpsCountryToken)
        }) else { return metadata }
        guard let latitude = metadata.latitude, let longitude = metadata.longitude else {
            return replacingGPSPlaceTokens(in: metadata, city: "", country: "")
        }
        do {
            let location = try await GeocodingService().reverseGeocode(
                latitude: latitude,
                longitude: longitude
            )
            return replacingGPSPlaceTokens(
                in: metadata,
                city: location.city ?? "",
                country: location.country ?? ""
            )
        } catch {
            return metadata
        }
    }

    private func replacingGPSPlaceTokens(
        in metadata: IPTCMetadata,
        city: String,
        country: String
    ) -> IPTCMetadata {
        func replace(_ value: String?) -> String? {
            value?
                .replacingOccurrences(of: Self.gpsCityToken, with: city)
                .replacingOccurrences(of: Self.gpsCountryToken, with: country)
        }
        var result = metadata
        result.title = replace(result.title)
        result.description = replace(result.description)
        result.extendedDescription = replace(result.extendedDescription)
        result.creator = replace(result.creator)
        result.credit = replace(result.credit)
        result.copyright = replace(result.copyright)
        result.jobId = replace(result.jobId)
        result.dateCreated = replace(result.dateCreated)
        result.city = replace(result.city)
        result.country = replace(result.country)
        result.event = replace(result.event)
        result.keywords = result.keywords.compactMap { replace($0) }
        result.personShown = result.personShown.compactMap { replace($0) }
        return result
    }

    /// Resolves template variables in a string.
    /// Supported variables:
    /// - `{date}` — today's date in default format (e.g., "Jan 27, 2026")
    /// - `{date:FORMAT}` — today's date with custom DateFormatter format (e.g., `{date:dd.MM.yyyy}`)
    ///   Friendly aliases are also supported: `YYYYMMDD`, `DDMMYYYY`, `YYYY-MM-DD`, `DD-MM-YYYY`.
    /// - `{dateCreated}` — Date Created from metadata, date only (e.g., "Mar 15, 2024")
    /// - `{dateCreated:FORMAT}` — Date Created with custom format (e.g., `{dateCreated:dd.MM.yyyy}`)
    ///   Friendly aliases are also supported: `YYYYMMDD`, `DDMMYYYY`, `YYYY-MM-DD`, `DD-MM-YYYY`.
    /// - `{dateCaptured}` — EXIF DateTimeOriginal, date only (e.g., "Mar 15, 2024")
    /// - `{dateCaptured:FORMAT}` — DateTimeOriginal with custom format (e.g., `{dateCaptured:yyyy-MM-dd}`)
    ///   Friendly aliases are also supported: `YYYYMMDD`, `DDMMYYYY`, `YYYY-MM-DD`, `DD-MM-YYYY`.
    /// - `{filename}` — filename of the target image (without extension)
    /// - `{initials}` — the user's initials from Settings (empty if unset)
    /// - `{persons}` — comma-separated list of Person Shown names
    /// - `{keywords}` — comma-separated list of keywords
    /// - `{gps}` — latitude and longitude in decimal degrees (six decimal places)
    /// - `{latitude}` / `{longitude}` — individual decimal-degree GPS coordinates
    /// - `{gps:city}` / `{gps:country}` — reverse-geocoded place names
    /// - `{seq}` — 1-based sequence number for batch processing
    /// - `{seq:N}` — zero-padded sequence number (e.g., `{seq:3}` produces "001", "002", …)
    /// - `{field:FIELDNAME}` — value from existing metadata (case-insensitive, matches key or label)
    func resolve(
        _ template: String,
        filename: String = "",
        existingMetadata: IPTCMetadata? = nil,
        sequenceIndex: Int = 1,
        initials: String = ""
    ) -> String {
        resolve(
            template,
            filename: filename,
            existingMetadata: existingMetadata,
            sequenceIndex: sequenceIndex,
            initials: initials,
            visitedFields: []
        )
    }

    /// `visitedFields` tracks the chain of `{field:…}` names currently being
    /// expanded so a field that references another field (which may itself hold
    /// variables) can be resolved recursively without looping on a cycle.
    private func resolve(
        _ template: String,
        filename: String,
        existingMetadata: IPTCMetadata?,
        sequenceIndex: Int,
        initials: String,
        visitedFields: Set<String>
    ) -> String {
        var result = template

        // {initials}
        result = result.replacingOccurrences(of: "{initials}", with: initials)

        // {date} and {date:FORMAT}
        result = resolveDate(in: result)

        // {dateCreated}, {dateCreated:FORMAT}, {dateCaptured}, {dateCaptured:FORMAT}
        result = resolveMetadataDate(in: result, tag: "dateCreated", raw: existingMetadata?.dateCreated)
        result = resolveMetadataDate(in: result, tag: "dateCaptured", raw: existingMetadata?.captureDate)

        // {filename}
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        result = result.replacingOccurrences(of: "{filename}", with: nameWithoutExt)

        // {seq} and {seq:N}
        result = resolveSequence(in: result, index: sequenceIndex)

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
            result = resolveGPS(in: result, metadata: metadata)
        } else {
            result = result.replacingOccurrences(of: "{persons}", with: "")
            result = result.replacingOccurrences(of: "{keywords}", with: "")
            result = result.replacingOccurrences(of: "{gps}", with: "")
            result = result.replacingOccurrences(of: "{latitude}", with: "")
            result = result.replacingOccurrences(of: "{longitude}", with: "")
        }

        // {field:FIELDNAME}
        result = resolveFields(
            in: result,
            metadata: existingMetadata,
            filename: filename,
            sequenceIndex: sequenceIndex,
            initials: initials,
            visitedFields: visitedFields
        )

        return result
    }

    private func resolveGPS(in template: String, metadata: IPTCMetadata) -> String {
        var result = template
        let latitude = metadata.latitude.map { String(format: "%.6f", $0) } ?? ""
        let longitude = metadata.longitude.map { String(format: "%.6f", $0) } ?? ""
        let coordinate = latitude.isEmpty || longitude.isEmpty
            ? ""
            : "\(latitude), \(longitude)"
        result = result.replacingOccurrences(of: "{gps}", with: coordinate)
        result = result.replacingOccurrences(of: "{latitude}", with: latitude)
        result = result.replacingOccurrences(of: "{longitude}", with: longitude)
        return result
    }

    /// Resolves `{tag}` and `{tag:FORMAT}` for a metadata date string.
    /// Parses the raw EXIF/IPTC date and outputs date-only by default,
    /// or applies a custom DateFormatter format when specified.
    private func resolveMetadataDate(in template: String, tag: String, raw: String?) -> String {
        var result = template
        let parsedDate = parseMetadataDate(raw)

        // {tag:FORMAT} — custom format (resolve before plain {tag})
        let prefix = "{\(tag):"
        while let startRange = result.range(of: prefix) {
            guard let endRange = result.range(of: "}", range: startRange.upperBound..<result.endIndex) else { break }
            let format = String(result[startRange.upperBound..<endRange.lowerBound])
            let fullRange = startRange.lowerBound..<endRange.upperBound
            if let date = parsedDate {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = canonicalDateFormat(format)
                result.replaceSubrange(fullRange, with: formatter.string(from: date))
            } else {
                result.replaceSubrange(fullRange, with: "")
            }
        }

        // {tag} — date only, medium style
        let plain = "{\(tag)}"
        if result.contains(plain) {
            if let date = parsedDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                result = result.replacingOccurrences(of: plain, with: formatter.string(from: date))
            } else {
                result = result.replacingOccurrences(of: plain, with: "")
            }
        }

        return result
    }

    /// Parses common EXIF/IPTC date string formats into a Date.
    /// Handles: "2024:03:15 14:30:45", "2024:03:15 14:30:45+02:00",
    /// "2024-03-15T14:30:45", "2024-03-15", "2024:03:15", etc.
    private func parseMetadataDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let formats = [
            "yyyy:MM:dd HH:mm:ssxxx",  // EXIF with timezone offset
            "yyyy:MM:dd HH:mm:ss",     // EXIF standard
            "yyyy-MM-dd'T'HH:mm:ssxxx", // ISO 8601 with timezone
            "yyyy-MM-dd'T'HH:mm:ss",   // ISO 8601
            "yyyy-MM-dd HH:mm:ss",     // Dash-separated with time
            "yyyy:MM:dd",              // Date only, colon
            "yyyy-MM-dd",             // Date only, dash
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }

        // Try trimming trailing timezone like "Z"
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("Z") {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss'Z'"
            if let date = formatter.date(from: trimmed) { return date }
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            if let date = formatter.date(from: trimmed) { return date }
        }

        return nil
    }

    private func resolveSequence(in template: String, index: Int) -> String {
        var result = template

        // {seq:N} — zero-padded to N digits (resolve before plain {seq})
        let padPattern = /\{seq:(\d+)\}/
        for match in result.matches(of: padPattern) {
            let width = Int(String(match.1)) ?? 1
            let padded = String(format: "%0\(width)d", index)
            result = result.replacingOccurrences(of: String(match.0), with: padded)
        }

        // {seq} — plain number
        result = result.replacingOccurrences(of: "{seq}", with: String(index))

        return result
    }

    private func resolveDate(in template: String) -> String {
        var result = template

        // {date:FORMAT}
        let formatPattern = /\{date:([^}]+)\}/
        for match in result.matches(of: formatPattern) {
            let format = String(match.1)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = canonicalDateFormat(format)
            let dateStr = formatter.string(from: Date())
            result = result.replacingOccurrences(of: String(match.0), with: dateStr)
        }

        // {date} (no format)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        result = result.replacingOccurrences(of: "{date}", with: formatter.string(from: Date()))

        return result
    }

    private func canonicalDateFormat(_ format: String) -> String {
        switch format.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "YYYYMMDD": return "yyyyMMdd"
        case "DDMMYYYY": return "ddMMyyyy"
        case "YYYY-MM-DD": return "yyyy-MM-dd"
        case "DD-MM-YYYY": return "dd-MM-yyyy"
        default: return format
        }
    }

    private func resolveFields(
        in template: String,
        metadata: IPTCMetadata?,
        filename: String,
        sequenceIndex: Int,
        initials: String,
        visitedFields: Set<String>
    ) -> String {
        var result = template
        let fieldPattern = /\{field:([^}]+)\}/

        for match in result.matches(of: fieldPattern) {
            let fieldName = String(match.1)
            var value = fieldValue(for: fieldName, from: metadata)
            // A referenced field may itself contain variables (e.g. event =
            // "{date}", or another {field:…}). Resolve them recursively, keyed
            // by normalized name so a reference cycle stops instead of looping.
            let key = normalizeFieldName(fieldName)
            if !value.isEmpty, !visitedFields.contains(key) {
                value = resolve(
                    value,
                    filename: filename,
                    existingMetadata: metadata,
                    sequenceIndex: sequenceIndex,
                    initials: initials,
                    visitedFields: visitedFields.union([key])
                )
            }
            result = result.replacingOccurrences(of: String(match.0), with: value)
        }

        return result
    }

    /// Normalizes a field name so lookups (and cycle keys) accept both keys and
    /// labels, case-insensitively and ignoring spaces/dashes/underscores.
    private func normalizeFieldName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    /// Matches field by key or display label, case-insensitive.
    private func fieldValue(for name: String, from metadata: IPTCMetadata?) -> String {
        guard let metadata else { return "" }

        // Build a lookup that accepts both keys and labels
        let normalized = normalizeFieldName(name)

        switch normalized {
        case "title": return metadata.title ?? ""
        case "description": return metadata.description ?? ""
        case "extendeddescription": return metadata.extendedDescription ?? ""
        case "keywords": return metadata.keywords.joined(separator: ", ")
        case "personshown", "persons": return metadata.personShown.joined(separator: ", ")
        case "creator": return metadata.creator ?? ""
        case "credit": return metadata.credit ?? ""
        case "copyright": return metadata.copyright ?? ""
        case "jobid": return metadata.jobId ?? ""
        case "datecreated": return metadata.dateCreated ?? ""
        case "city": return metadata.city ?? ""
        case "country": return metadata.country ?? ""
        case "gps", "gpscoordinates":
            guard let latitude = metadata.latitude, let longitude = metadata.longitude else { return "" }
            return String(format: "%.6f, %.6f", latitude, longitude)
        case "latitude", "gpslatitude":
            return metadata.latitude.map { String(format: "%.6f", $0) } ?? ""
        case "longitude", "gpslongitude":
            return metadata.longitude.map { String(format: "%.6f", $0) } ?? ""
        case "event": return metadata.event ?? ""
        case "digitalsourcetype": return metadata.digitalSourceType?.displayName ?? ""
        default: return ""
        }
    }
}
