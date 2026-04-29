import AppKit
import Foundation
import SwiftExif

extension C2PAMetadata {
    /// Build a `C2PAMetadata` from SwiftExif's typed `C2PAData`.
    init(from c2paData: SwiftExif.C2PAData) {
        let parsed: [C2PAManifest] = c2paData.manifests.map { manifest in
            var actions: [String] = []
            var digitalSourceType: String?
            var author: String?
            var ingredientTitle: String?
            var ingredientFormat: String?

            for assertion in manifest.assertions {
                switch assertion.content {
                case .actions(let actionsBox):
                    actions = actionsBox.actions.map { Self.formatAction($0.action) }
                    if let sourceType = actionsBox.actions.compactMap(\.digitalSourceType).first {
                        digitalSourceType = sourceType
                    }
                case .ingredient(let ing):
                    if ingredientTitle == nil, let v = ing.title { ingredientTitle = v }
                    if ingredientFormat == nil, let v = ing.format { ingredientFormat = v }
                case .json(let data):
                    // The CreativeWork assertion is delivered as JSON.
                    if assertion.label == "stds.schema-org.CreativeWork",
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let authors = json["author"] as? [[String: Any]],
                           let firstName = authors.first?["name"] as? String {
                            author = firstName
                        } else if let single = json["author"] as? [String: Any],
                                  let name = single["name"] as? String {
                            author = name
                        }
                    }
                case .thumbnail, .hashData, .cbor, .binary:
                    break
                }
            }

            let assertionLabels = manifest.claim.assertionReferences.compactMap { ref -> String? in
                guard let lastSlash = ref.url.lastIndex(of: "/") else {
                    return ref.url.isEmpty ? nil : ref.url
                }
                let label = String(ref.url[ref.url.index(after: lastSlash)...])
                return label.isEmpty ? nil : label
            }

            return C2PAManifest(
                label: manifest.label,
                claimGenerator: manifest.claim.claimGenerator,
                generatorName: manifest.claim.claimGeneratorInfo?.name,
                generatorVersion: manifest.claim.claimGeneratorInfo?.version,
                author: author,
                actions: actions,
                algorithm: manifest.claim.algorithm,
                ingredientTitle: ingredientTitle,
                title: manifest.claim.title,
                digitalSourceType: digitalSourceType,
                ingredientFormat: ingredientFormat ?? manifest.claim.format,
                documentID: nil,
                instanceID: manifest.claim.instanceID,
                assertions: assertionLabels
            )
        }

        self.init(manifests: parsed)
    }

    private static func formatAction(_ action: String) -> String {
        let stripped = action.hasPrefix("c2pa.") ? String(action.dropFirst(5)) : action
        return stripped.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

extension C2PAThumbnails {
    /// Walk SwiftExif's `C2PAData` for `.thumbnail` assertions, decoding the
    /// claim and ingredient thumbnails to `NSImage` when present.
    init(from c2paData: SwiftExif.C2PAData) {
        var claim: NSImage?
        var ingredient: NSImage?
        for manifest in c2paData.manifests {
            for assertion in manifest.assertions {
                guard case .thumbnail(let data, _) = assertion.content else { continue }
                let label = assertion.label.lowercased()
                if label.contains("ingredient") {
                    if ingredient == nil { ingredient = NSImage(data: data) }
                } else if label.contains("claim") || label.contains("thumbnail") {
                    if claim == nil { claim = NSImage(data: data) }
                }
            }
        }
        self.init(claimThumbnail: claim, ingredientThumbnail: ingredient)
    }
}
