import Foundation

/// Where a keyword (or keyword batch) came from. Threaded through approved-list
/// validation so per-source policies (such as the "always allow keywords from
/// structured list" bypass) can short-circuit on a specific origin.
enum KeywordSource: Hashable {
    /// Typed by the user into a text field, or pasted, or a token-promote action.
    case user
    /// Selected from a Quick List menu / Quick List picker.
    case quickList
    /// Applied as part of a saved metadata template.
    case template
    /// Added via the PhotoMechanic-style structured keyword tree picker.
    case structuredTree
}
