import Foundation

nonisolated enum IPTCMediaTopicsLanguage: String, CaseIterable, Codable, Sendable {
    case arabic = "ar", chinese = "zh-Hans", danish = "dk", englishUK = "en-GB", englishUS = "en-US"
    case french = "fr", german = "de", norwegianBokmal = "no-NB", norwegianNynorsk = "no-NN"
    case portuguese = "pt-PT", portugueseBrazil = "pt-BR", spanish = "es", swedish = "se"

    var displayName: String {
        switch self {
        case .arabic: "العربية — Arabic"
        case .chinese: "简体中文 — Chinese (Simplified)"
        case .danish: "Dansk — Danish"
        case .englishUK: "English (UK)"
        case .englishUS: "English (US)"
        case .french: "Français — French"
        case .german: "Deutsch — German"
        case .norwegianBokmal: "Norsk bokmål — Norwegian Bokmål"
        case .norwegianNynorsk: "Norsk nynorsk — Norwegian Nynorsk"
        case .portuguese: "Português — Portuguese"
        case .portugueseBrazil: "Português (Brasil) — Portuguese (Brazil)"
        case .spanish: "Español — Spanish"
        case .swedish: "Svenska — Swedish"
        }
    }

    static func resolve(override: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        if let override, let selected = Self(rawValue: override) { return selected }
        // The primary system language determines the result. An unsupported primary language
        // falls back to US English, rather than an unrelated secondary language.
        guard let preferred = preferredLanguages.first else { return .englishUS }
        let parts = preferred.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        switch parts.first {
        case "ar": return .arabic
        case "zh": return .chinese
        case "da", "dk": return .danish
        case "en": return parts.contains("gb") ? .englishUK : .englishUS
        case "fr": return .french
        case "de": return .german
        case "nb": return .norwegianBokmal
        case "nn": return .norwegianNynorsk
        case "no": return parts.contains("nn") ? .norwegianNynorsk : .norwegianBokmal
        case "pt": return parts.contains("br") ? .portugueseBrazil : .portuguese
        case "es": return .spanish
        // IPTC uses "se" for Swedish; macOS uses the standard "sv" language code.
        case "sv": return .swedish
        default: return .englishUS
        }
    }
}

nonisolated struct IPTCMediaTopics: Codable, Sendable {
    struct Concept: Codable, Sendable {
        let labels: [String: String]
        let children: [String]
    }
    let release: String
    let roots: [String]
    let concepts: [String: Concept]

    @MainActor func tree(language: IPTCMediaTopicsLanguage) -> [StructuredKeyword] {
        func node(_ id: String, ancestors: Set<String>) -> StructuredKeyword? {
            guard !ancestors.contains(id), let concept = concepts[id],
                  let name = concept.labels[language.rawValue] ?? concept.labels["en-US"] ?? concept.labels["en-GB"] else { return nil }
            let children = concept.children.compactMap { node($0, ancestors: ancestors.union([id])) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return StructuredKeyword(
                id: UUID(uuidString: "10000000-0000-0000-0000-0000\(id)") ?? UUID(),
                name: name, kind: .keyword, children: children)
        }
        return roots.compactMap { node($0, ancestors: []) }
    }
}
