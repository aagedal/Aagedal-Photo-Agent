import Foundation

/// One member of the repeatable PLUS Image Supplier sequence.
///
/// This identity describes the person or organisation that supplied the image. It is deliberately
/// distinct from `IPTCMetadata.imageSupplierImageID`, which identifies the image within a
/// supplier's system. Neither value is inferred from the other.
nonisolated struct EditorialImageSupplier: Codable, Sendable, Equatable, Hashable {
    var identifier: String?
    var name: String?

    init(identifier: String? = nil, name: String? = nil) {
        self.identifier = Self.normalizedText(identifier)
        self.name = Self.normalizedText(name)
    }

    var isEmpty: Bool {
        identifier == nil && name == nil
    }

    /// Preserves sequence order while removing empty and exactly duplicated structures. Supplier
    /// IDs remain opaque: case, URI spelling, and agency-specific syntax are never rewritten.
    static func normalizedValues(_ values: [Self]) -> [Self] {
        var seen = Set<Self>()
        return values.compactMap { value in
            let normalized = Self(identifier: value.identifier, name: value.name)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    /// Lossless transport used by metadata history, templates, and the typed low-level writer
    /// key. A structured supplier must never be flattened into a delimiter-separated string:
    /// identifiers and names are an aligned pair and either member may itself contain commas.
    static func canonicalJSONString(for values: [Self]) -> String? {
        let values = normalizedValues(values)
        guard !values.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes only the typed JSON representation. Invalid or delimiter-flattened input is
    /// rejected rather than guessed, which keeps template/history replay fail-closed.
    static func values(fromCanonicalJSONString value: String) -> [Self]? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Self].self, from: data) else {
            return nil
        }
        return normalizedValues(decoded)
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Explicit operations for a repeatable structured Image Supplier field. `untouched` is kept
/// separate from `clear`, so batch/template/import paths never erase existing suppliers merely
/// because a payload omitted the property.
nonisolated enum EditorialImageSupplierMutation: Sendable, Equatable {
    case untouched
    case clear
    case append([EditorialImageSupplier])
    case replace([EditorialImageSupplier])

    func apply(to existing: [EditorialImageSupplier]) -> [EditorialImageSupplier] {
        switch self {
        case .untouched:
            return existing
        case .clear:
            return []
        case let .append(values):
            return EditorialImageSupplier.normalizedValues(existing + values)
        case let .replace(values):
            return EditorialImageSupplier.normalizedValues(values)
        }
    }
}
