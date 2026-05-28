import Foundation

/// Serialises a `[StructuredKeyword]` tree back into the PhotoMechanic-style
/// tab-indented text format consumed by `StructuredKeywordParser`. Round-trip
/// (`parse → serialize → parse`) preserves names, kinds, synonyms, and order.
enum StructuredKeywordSerializer {
    /// Emits the tree as a `\n`-joined text file. A trailing newline is included
    /// when the tree is non-empty so editors that strip-trailing-newline don't
    /// disturb the last line on save.
    static func serialize(_ roots: [StructuredKeyword]) -> String {
        var lines: [String] = []
        for root in roots {
            emit(root, depth: 0, into: &lines)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func emit(_ node: StructuredKeyword, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "\t", count: depth)
        let header: String
        switch node.kind {
        case .keyword:
            header = node.name
        case .container:
            header = "[\(node.name)]"
        }
        lines.append(indent + header)

        let childIndent = String(repeating: "\t", count: depth + 1)
        for synonym in node.synonyms {
            lines.append(childIndent + "{\(synonym)}")
        }
        for child in node.children {
            emit(child, depth: depth + 1, into: &lines)
        }
    }
}
