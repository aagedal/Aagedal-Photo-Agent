import Foundation
import Observation

/// Mutable, reference-type counterpart to `StructuredKeyword`, used by the
/// in-app tree editor. Reference semantics let the editor rebind nodes between
/// parents (indent/outdent/move) without copying whole subtrees.
@Observable
final class EditableStructuredKeyword: Identifiable {
    let id: UUID
    var name: String
    var kind: StructuredKeyword.Kind
    var synonyms: [String]
    var relatedKeywords: [String]
    var children: [EditableStructuredKeyword]
    /// Tracked so indent / outdent / move-up / move-down operations can find a
    /// node's siblings without walking the whole tree. Reassigned whenever the
    /// node is moved.
    @ObservationIgnored weak var parent: EditableStructuredKeyword?

    init(
        id: UUID = UUID(),
        name: String,
        kind: StructuredKeyword.Kind,
        synonyms: [String] = [],
        relatedKeywords: [String] = [],
        children: [EditableStructuredKeyword] = [],
        parent: EditableStructuredKeyword? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.synonyms = synonyms
        self.relatedKeywords = relatedKeywords
        self.children = children
        self.parent = parent
        for child in children { child.parent = self }
    }

    /// Builds an editable tree from an immutable parsed tree. The synthetic
    /// "root" returned has `nil` parent and holds the file's top-level nodes
    /// as its children — having a single root simplifies the editor's
    /// add-sibling and indent-into-previous-sibling operations at the top level.
    static func root(from roots: [StructuredKeyword]) -> EditableStructuredKeyword {
        let synthetic = EditableStructuredKeyword(name: "", kind: .container)
        synthetic.children = roots.map { convert($0, parent: synthetic) }
        return synthetic
    }

    private static func convert(_ node: StructuredKeyword, parent: EditableStructuredKeyword) -> EditableStructuredKeyword {
        let copy = EditableStructuredKeyword(
            id: node.id,
            name: node.name,
            kind: node.kind,
            synonyms: node.synonyms,
            relatedKeywords: node.relatedKeywords,
            parent: parent
        )
        copy.children = node.children.map { convert($0, parent: copy) }
        return copy
    }

    /// Returns the immutable snapshot of this subtree's children (used when the
    /// "root" is the synthetic wrapper from `root(from:)`).
    func snapshotChildren() -> [StructuredKeyword] {
        children.map { $0.snapshot() }
    }

    /// Returns an immutable copy of this subtree.
    func snapshot() -> StructuredKeyword {
        StructuredKeyword(
            id: id,
            name: name,
            kind: kind,
            synonyms: synonyms,
            relatedKeywords: relatedKeywords,
            children: children.map { $0.snapshot() }
        )
    }

    /// Depth of this node from the synthetic root (synthetic root = -1, its
    /// children = 0). Useful for indenting the tree view.
    var depthFromRoot: Int {
        var depth = -1
        var current: EditableStructuredKeyword? = self
        while let c = current {
            depth += 1
            current = c.parent
        }
        return depth
    }

    var hasChildren: Bool { !children.isEmpty }
    var isContainer: Bool { kind == .container }
    var isKeyword: Bool { kind == .keyword }
}
