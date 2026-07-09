import Foundation

/// A node in a PhotoMechanic-style structured keywords tree.
///
/// - `keyword` nodes are real IPTC keywords; their `name` is written verbatim.
/// - `container` nodes (`[Bracketed]` in the source file) are organizational
///   headers and are never applied as keywords. They group their children.
/// - `synonyms` are extra strings attached to this node; in PhotoMechanic these
///   appear as `{synonym}` lines under the parent keyword.
/// - `relatedKeywords` are extra IPTC keywords attached to this node; these
///   appear as `#keyword` lines under the parent keyword.
struct StructuredKeyword: Identifiable, Hashable {
    enum Kind: Hashable {
        case keyword
        case container
    }

    let id: UUID
    let name: String
    let kind: Kind
    let synonyms: [String]
    let relatedKeywords: [String]
    let children: [StructuredKeyword]

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        synonyms: [String] = [],
        relatedKeywords: [String] = [],
        children: [StructuredKeyword] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.synonyms = synonyms
        self.relatedKeywords = relatedKeywords
        self.children = children
    }

    var isContainer: Bool { kind == .container }
    var isKeyword: Bool { kind == .keyword }
    var hasChildren: Bool { !children.isEmpty }
}
