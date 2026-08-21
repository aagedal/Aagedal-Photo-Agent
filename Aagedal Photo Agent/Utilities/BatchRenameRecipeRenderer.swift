import Foundation

/// Deterministic, side-effect-free evaluation of a ``BatchRenameRecipe``.
nonisolated struct BatchRenameRecipeRenderer: Sendable {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    /// Evaluation order is intentionally fixed:
    /// components → substitutions (array order) → case → whitespace → sanitization → Unicode.
    func evaluate(
        _ recipe: BatchRenameRecipe,
        context: BatchRenameContext
    ) -> BatchRenameEvaluation {
        var rendered = ""
        var missingValues: [BatchRenameMissingValue] = []

        for (index, component) in recipe.components.enumerated() {
            switch component {
            case let .literal(value):
                rendered += value
            case let .token(token):
                if let value = resolve(token, recipe: recipe, context: context) {
                    rendered += value
                } else {
                    missingValues.append(BatchRenameMissingValue(componentIndex: index, token: token))
                    switch recipe.missingValuePolicy {
                    case .empty, .preserveOriginal, .skip, .block:
                        break
                    case let .fallback(value):
                        rendered += value
                    }
                }
            }
        }

        if !missingValues.isEmpty {
            switch recipe.missingValuePolicy {
            case .preserveOriginal:
                return BatchRenameEvaluation(
                    disposition: .preserveOriginal,
                    // Preserve means no rename at all, including no normalization-only change.
                    proposedFilename: context.originalFilename,
                    missingValues: missingValues,
                    problems: []
                )
            case .skip:
                return BatchRenameEvaluation(
                    disposition: .skip,
                    proposedFilename: nil,
                    missingValues: missingValues,
                    problems: []
                )
            case .block:
                return BatchRenameEvaluation(
                    disposition: .block,
                    proposedFilename: nil,
                    missingValues: missingValues,
                    problems: []
                )
            case .empty, .fallback:
                break
            }
        }

        for (stageIndex, substitution) in recipe.substitutions.enumerated() {
            switch applying(substitution, to: rendered) {
            case let .success(value):
                rendered = value
            case let .failure(pattern):
                return BatchRenameEvaluation(
                    disposition: .block,
                    proposedFilename: nil,
                    missingValues: missingValues,
                    problems: [.invalidRegularExpression(stageIndex: stageIndex, pattern: pattern)]
                )
            }
        }

        rendered = applyCase(recipe.caseConversion, to: rendered)
        rendered = applyWhitespace(recipe.whitespace, to: rendered)
        rendered = sanitize(rendered, using: recipe.sanitization)
        rendered = normalize(rendered, using: recipe.unicodeNormalization)

        return BatchRenameEvaluation(
            disposition: .rename,
            proposedFilename: rendered,
            missingValues: missingValues,
            problems: []
        )
    }

    private func resolve(
        _ token: BatchRenameToken,
        recipe: BatchRenameRecipe,
        context: BatchRenameContext
    ) -> String? {
        switch token {
        case .originalFilename:
            return nonempty(context.originalFilename)
        case .originalStem:
            return nonempty((context.originalFilename as NSString).deletingPathExtension)
        case .originalExtension:
            return nonempty((context.originalFilename as NSString).pathExtension)
        case let .sequence(sequence):
            let value = sequence.start + (context.sequenceIndex * sequence.step)
            return padded(value, width: sequence.padding)
        case let .date(token):
            guard let date = date(for: token.source, context: context) else { return nil }
            return format(date, pattern: token.format, recipe: recipe)
        case let .metadata(field):
            return nonempty(context.metadata[field])
        case .jobTitle:
            return nonempty(context.jobTitle)
        case .importTitle:
            return nonempty(context.importTitle)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func padded(_ value: Int, width: Int) -> String {
        guard width > 0 else { return String(value) }
        if value < 0 {
            return "-" + String(repeating: "0", count: max(0, width - String(-value).count)) + String(-value)
        }
        return String(repeating: "0", count: max(0, width - String(value).count)) + String(value)
    }

    private func date(for source: BatchRenameDateSource, context: BatchRenameContext) -> Date? {
        switch source {
        case .fileCreation:
            return context.fileCreationDate
        case .fileModification:
            return context.fileModificationDate
        case let .capture(fallback):
            if let captureDate = context.captureDate { return captureDate }
            switch fallback {
            case .none: return nil
            case .fileCreation: return context.fileCreationDate
            case .fileModification: return context.fileModificationDate
            }
        }
    }

    private func format(_ date: Date, pattern: String, recipe: BatchRenameRecipe) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.posixLocale
        formatter.calendar = Self.gregorianCalendar
        formatter.timeZone = TimeZone(identifier: recipe.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = canonicalDateFormat(pattern)
        return formatter.string(from: date)
    }

    /// Mirrors the useful aliases supported by metadata interpolation, but is deliberately local
    /// to this engine so filename-recipe evolution cannot alter caption-template behavior.
    private func canonicalDateFormat(_ format: String) -> String {
        switch format.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: Self.posixLocale) {
        case "YYYYMMDD": return "yyyyMMdd"
        case "DDMMYYYY": return "ddMMyyyy"
        case "YYYY-MM-DD": return "yyyy-MM-dd"
        case "DD-MM-YYYY": return "dd-MM-yyyy"
        default: return format
        }
    }

    private enum SubstitutionResult {
        case success(String)
        case failure(pattern: String)
    }

    private func applying(_ substitution: BatchRenameSubstitution, to input: String) -> SubstitutionResult {
        switch substitution {
        case let .literal(find, replacement, caseSensitive):
            guard !find.isEmpty else { return .success(input) }
            if caseSensitive {
                return .success(input.replacingOccurrences(of: find, with: replacement))
            }
            return .success(input.replacingOccurrences(
                of: find,
                with: replacement,
                options: [.caseInsensitive],
                range: nil
            ))
        case let .regularExpression(pattern, replacement, caseInsensitive, anchorsMatchLines):
            var options: NSRegularExpression.Options = []
            if caseInsensitive { options.insert(.caseInsensitive) }
            if anchorsMatchLines { options.insert(.anchorsMatchLines) }
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                return .failure(pattern: pattern)
            }
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            return .success(expression.stringByReplacingMatches(
                in: input,
                options: [],
                range: range,
                withTemplate: replacement
            ))
        }
    }

    private func applyCase(_ conversion: BatchRenameCaseConversion, to input: String) -> String {
        switch conversion {
        case .unchanged: return input
        case .lowercase: return input.lowercased(with: Self.posixLocale)
        case .uppercase: return input.uppercased(with: Self.posixLocale)
        case .titleCase: return input.capitalized(with: Self.posixLocale)
        }
    }

    private func applyWhitespace(_ rule: BatchRenameWhitespaceRule, to input: String) -> String {
        switch rule {
        case .preserve:
            return input
        case let .replace(replacement, collapseRuns):
            let pattern = collapseRuns ? #"\s+"# : #"\s"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
            return expression.stringByReplacingMatches(
                in: input,
                range: NSRange(input.startIndex..<input.endIndex, in: input),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
    }

    private func sanitize(_ input: String, using rule: BatchRenameSanitization) -> String {
        guard rule.enabled else { return input }

        // This superset covers path separators and characters rejected by Windows, ensuring
        // portable sidecars/exports while still allowing the full range of normal Unicode names.
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let safeReplacementScalars = rule.replacement.unicodeScalars.filter { !forbidden.contains($0) }
        let safeReplacement = safeReplacementScalars.isEmpty
            ? "_"
            : String(String.UnicodeScalarView(safeReplacementScalars))
        var result = ""
        var lastWasReplacement = false
        for scalar in input.unicodeScalars {
            if forbidden.contains(scalar) {
                if !rule.collapseReplacementRuns || !lastWasReplacement {
                    result += safeReplacement
                }
                lastWasReplacement = true
            } else {
                result.unicodeScalars.append(scalar)
                lastWasReplacement = false
            }
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.last == "." { result.removeLast() }
        if !rule.allowHiddenFiles {
            while result.hasPrefix(".") { result.removeFirst() }
        }

        let fallbackScalars = rule.emptyFilenameFallback.unicodeScalars.filter {
            !forbidden.contains($0)
        }
        let fallback = String(String.UnicodeScalarView(fallbackScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFallback = fallback.isEmpty ? "untitled" : fallback
        if result.isEmpty || result == "." || result == ".." {
            result = safeFallback
        }
        return result
    }

    private func normalize(_ input: String, using normalization: BatchRenameUnicodeNormalization) -> String {
        switch normalization {
        case .none: return input
        case .canonicalComposed: return input.precomposedStringWithCanonicalMapping
        case .canonicalDecomposed: return input.decomposedStringWithCanonicalMapping
        case .compatibilityComposed: return input.precomposedStringWithCompatibilityMapping
        case .compatibilityDecomposed: return input.decomposedStringWithCompatibilityMapping
        }
    }
}
