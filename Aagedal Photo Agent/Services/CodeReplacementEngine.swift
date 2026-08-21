import Foundation

/// Strict parser for the interoperable subset of Photo Mechanic code-replacement text files.
/// Each nonblank UTF-8 line must contain exactly `code<TAB>replacement`. CRLF, LF, and CR line
/// endings are accepted. Columns are not trimmed because codes and replacement text are exact.
nonisolated struct CodeReplacementParser: Sendable {
    func parse(
        _ data: Data,
        source: CodeReplacementSourceReference? = nil
    ) -> CodeReplacementList {
        guard var text = String(data: data, encoding: .utf8) else {
            return CodeReplacementList(
                source: source,
                diagnostics: [CodeReplacementDiagnostic(
                    severity: .error,
                    kind: .invalidUTF8,
                    line: nil
                )]
            )
        }

        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        struct Definition {
            var value: String
            var line: Int
        }

        var definitions: [String: [Definition]] = [:]
        var codeOrder: [String] = []
        var diagnostics: [CodeReplacementDiagnostic] = []

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            guard !line.isEmpty else { continue }

            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2 else {
                diagnostics.append(CodeReplacementDiagnostic(
                    severity: .error,
                    kind: .malformedRow(columnCount: columns.count),
                    line: lineNumber
                ))
                continue
            }

            let code = String(columns[0])
            let replacement = String(columns[1])
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                diagnostics.append(CodeReplacementDiagnostic(
                    severity: .error,
                    kind: .emptyCode,
                    line: lineNumber
                ))
                continue
            }
            guard !replacement.isEmpty else {
                diagnostics.append(CodeReplacementDiagnostic(
                    severity: .error,
                    kind: .emptyValue(code: code),
                    line: lineNumber
                ))
                continue
            }

            if definitions[code] == nil { codeOrder.append(code) }
            definitions[code, default: []].append(Definition(value: replacement, line: lineNumber))
        }

        var entries: [CodeReplacementEntry] = []
        var ambiguousCodes: [String: [Int]] = [:]
        for code in codeOrder {
            guard let group = definitions[code], let original = group.first else { continue }
            let isAmbiguous = group.dropFirst().contains { $0.value != original.value }
            if isAmbiguous {
                ambiguousCodes[code] = group.map(\.line)
                for definition in group.dropFirst() where definition.value != original.value {
                    diagnostics.append(CodeReplacementDiagnostic(
                        severity: .error,
                        kind: .ambiguousCode(code: code, originalLine: original.line),
                        line: definition.line
                    ))
                }
                continue
            }

            entries.append(CodeReplacementEntry(
                code: code,
                replacement: original.value,
                sourceLine: original.line
            ))
            for duplicate in group.dropFirst() {
                diagnostics.append(CodeReplacementDiagnostic(
                    severity: .warning,
                    kind: .duplicateCode(code: code, originalLine: original.line),
                    line: duplicate.line
                ))
            }
        }

        return CodeReplacementList(
            source: source,
            entries: entries,
            ambiguousCodes: ambiguousCodes,
            diagnostics: diagnostics
        )
    }
}

/// Deterministic, side-effect-free code replacement.
///
/// Matching is case-sensitive. Complete `start + code + end` tokens are considered, longest
/// token first and then lexically, so a shorter code can never consume a longer exact token.
/// Delimiters are made literal by doubling them. Exact tokens take precedence over doubled
/// delimiters, which also permits adjacent tokens when start and end delimiters are identical.
nonisolated struct CodeReplacementEngine: Sendable {
    func preview(
        text: String,
        list: CodeReplacementList,
        configuration: CodeReplacementConfiguration,
        compositionState: CodeReplacementCompositionState = .committed
    ) -> CodeReplacementPreview {
        guard configuration.isEnabled else {
            return result(text, disposition: .disabled, list: list)
        }
        guard compositionState == .committed else {
            return result(text, disposition: .refusedActiveComposition, list: list)
        }
        guard !configuration.startDelimiter.isEmpty, !configuration.endDelimiter.isEmpty else {
            return result(text, disposition: .invalidConfiguration, list: list)
        }
        guard !list.hasInvalidEncoding else {
            return result(text, disposition: .invalidSourceEncoding, list: list)
        }

        let start = configuration.startDelimiter
        let end = configuration.endDelimiter
        var tokens: [Token] = []
        for entry in list.entries {
            let containsDelimiter = entry.code.contains(start) || entry.code.contains(end)
            tokens.append(Token(
                text: start + entry.code + end,
                code: entry.code,
                replacement: containsDelimiter ? nil : entry.replacement,
                unresolvedReason: containsDelimiter ? .codeContainsDelimiter : nil
            ))
        }
        for code in list.ambiguousCodes.keys {
            let containsDelimiter = code.contains(start) || code.contains(end)
            tokens.append(Token(
                text: start + code + end,
                code: code,
                replacement: nil,
                unresolvedReason: containsDelimiter ? .codeContainsDelimiter : .ambiguousCode
            ))
        }
        tokens.sort {
            if $0.text.count != $1.text.count { return $0.text.count > $1.text.count }
            return $0.text < $1.text
        }

        var output = ""
        var replacements: [CodeReplacementOccurrence] = []
        var unresolved: [CodeReplacementUnresolvedOccurrence] = []
        var index = text.startIndex
        var characterOffset = 0

        while index < text.endIndex {
            if let token = tokens.first(where: { text[index...].hasPrefix($0.text) }) {
                let tokenLength = token.text.count
                let range = characterOffset..<(characterOffset + tokenLength)
                if let reason = token.unresolvedReason {
                    output += token.text
                    unresolved.append(CodeReplacementUnresolvedOccurrence(
                        code: token.code,
                        sourceRange: range,
                        reason: reason
                    ))
                } else if let replacement = token.replacement {
                    output += replacement
                    replacements.append(CodeReplacementOccurrence(
                        code: token.code,
                        replacement: replacement,
                        sourceRange: range
                    ))
                }
                index = text.index(index, offsetBy: tokenLength)
                characterOffset += tokenLength
                continue
            }

            if let escaped = escapedDelimiter(at: index, in: text, start: start, end: end) {
                output += escaped.literal
                index = text.index(index, offsetBy: escaped.consumedCharacters)
                characterOffset += escaped.consumedCharacters
                continue
            }

            output.append(text[index])
            index = text.index(after: index)
            characterOffset += 1
        }

        return CodeReplacementPreview(
            originalText: text,
            proposedText: output,
            disposition: output == text ? .unchanged : .applied,
            replacements: replacements,
            unresolvedOccurrences: unresolved,
            sourceDiagnostics: list.diagnostics
        )
    }

    private struct Token {
        var text: String
        var code: String
        var replacement: String?
        var unresolvedReason: CodeReplacementUnresolvedReason?
    }

    private struct EscapedDelimiter {
        var literal: String
        var consumedCharacters: Int
    }

    private func escapedDelimiter(
        at index: String.Index,
        in text: String,
        start: String,
        end: String
    ) -> EscapedDelimiter? {
        let doubledStart = start + start
        if text[index...].hasPrefix(doubledStart) {
            return EscapedDelimiter(literal: start, consumedCharacters: doubledStart.count)
        }
        guard start != end else { return nil }
        let doubledEnd = end + end
        if text[index...].hasPrefix(doubledEnd) {
            return EscapedDelimiter(literal: end, consumedCharacters: doubledEnd.count)
        }
        return nil
    }

    private func result(
        _ text: String,
        disposition: CodeReplacementPreviewDisposition,
        list: CodeReplacementList
    ) -> CodeReplacementPreview {
        CodeReplacementPreview(
            originalText: text,
            proposedText: text,
            disposition: disposition,
            replacements: [],
            unresolvedOccurrences: [],
            sourceDiagnostics: list.diagnostics
        )
    }
}
