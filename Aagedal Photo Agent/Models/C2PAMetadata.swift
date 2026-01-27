import Foundation

struct C2PAManifest {
    let label: String
    let claimGenerator: String?
    let generatorName: String?
    let generatorVersion: String?
    let author: String?
    let actions: [String]
    let algorithm: String?
    let ingredientTitle: String?
    let title: String?
}

struct C2PAMetadata {
    let manifests: [C2PAManifest]
    var activeManifest: C2PAManifest? { manifests.last }

    /// Parse `-json -G3 -JUMBF:All` output into per-manifest data.
    ///
    /// Keys are prefixed like `Doc1-1:...`, `Doc1-2:...` where each `Doc1-N`
    /// with JUMDType containing `c2ma` is a manifest. Within each manifest,
    /// child nodes contain the claim (`c2pa.claim`), actions, author, etc.
    init(from dict: [String: Any]) {
        // Group keys by their top-level Doc prefix (e.g. "Doc1-1", "Doc1-2")
        var manifestPrefixes: [String] = []
        var groupedKeys: [String: [(key: String, suffix: String)]] = [:]

        for key in dict.keys {
            // Match keys like "Doc1-1:Field" or "Doc1-1-2:Field"
            guard let colonRange = key.range(of: ":") else { continue }
            let docPrefix = String(key[..<colonRange.lowerBound])
            let fieldName = String(key[colonRange.upperBound...])

            // Find the manifest-level prefix (Doc1-N)
            let parts = docPrefix.split(separator: "-")
            guard parts.count >= 2 else { continue }
            let manifestPrefix = "\(parts[0])-\(parts[1])"

            if groupedKeys[manifestPrefix] == nil {
                groupedKeys[manifestPrefix] = []
            }
            groupedKeys[manifestPrefix]?.append((key: key, suffix: fieldName))

            // Detect manifest boxes by JUMDType containing "c2ma"
            if fieldName == "JUMDType", docPrefix == manifestPrefix {
                if let value = dict[key] as? String, value.contains("c2ma") {
                    manifestPrefixes.append(manifestPrefix)
                }
            }
        }

        // Sort manifests by their numeric suffix so ordering is deterministic
        manifestPrefixes.sort { a, b in
            let aNum = Int(a.split(separator: "-").last ?? "0") ?? 0
            let bNum = Int(b.split(separator: "-").last ?? "0") ?? 0
            return aNum < bNum
        }

        var parsed: [C2PAManifest] = []

        for prefix in manifestPrefixes {
            guard groupedKeys[prefix] != nil else { continue }

            // Collect all keys that belong to this manifest (prefix match)
            var manifestDict: [String: Any] = [:]
            for key in dict.keys {
                if key.hasPrefix(prefix) {
                    manifestDict[key] = dict[key]
                }
            }

            // Find the claim node (JUMDLabel == "c2pa.claim")
            var claimGenerator: String?
            var generatorName: String?
            var generatorVersion: String?
            var algorithm: String?
            var title: String?

            // Find actions, author, ingredient from assertion nodes
            var actions: [String] = []
            var author: String?
            var ingredientTitle: String?

            for (key, value) in manifestDict {
                guard let colonRange = key.range(of: ":") else { continue }
                let field = String(key[colonRange.upperBound...])

                // Identify which sub-node this key belongs to by checking JUMDLabel
                let nodePrefix = String(key[..<colonRange.lowerBound])

                // Claim fields
                if manifestDict["\(nodePrefix):JUMDLabel"] as? String == "c2pa.claim" {
                    switch field {
                    case "Claim_generator": claimGenerator = value as? String
                    case "Claim_Generator_InfoName": generatorName = value as? String
                    case "Claim_Generator_InfoVersion": generatorVersion = value as? String
                    case "Alg": algorithm = value as? String
                    case "Title": title = value as? String
                    default: break
                    }
                }

                // Actions
                if let label = manifestDict["\(nodePrefix):JUMDLabel"] as? String,
                   label == "c2pa.actions", field == "ActionsAction" {
                    if let actionArray = value as? [String] {
                        actions = actionArray.map { Self.formatAction($0) }
                    } else if let single = value as? String {
                        actions = [Self.formatAction(single)]
                    }
                }

                // Author (CreativeWork)
                if let label = manifestDict["\(nodePrefix):JUMDLabel"] as? String,
                   label == "stds.schema-org.CreativeWork", field == "AuthorName" {
                    author = value as? String
                }

                // Ingredient
                if let label = manifestDict["\(nodePrefix):JUMDLabel"] as? String,
                   label.hasPrefix("c2pa.ingredient"), field == "Title" {
                    ingredientTitle = value as? String
                }
            }

            parsed.append(C2PAManifest(
                label: manifestDict["\(prefix):JUMDLabel"] as? String ?? prefix,
                claimGenerator: claimGenerator,
                generatorName: generatorName,
                generatorVersion: generatorVersion,
                author: author,
                actions: actions,
                algorithm: algorithm,
                ingredientTitle: ingredientTitle,
                title: title
            ))
        }

        self.manifests = parsed
    }

    /// Convert C2PA action URIs to human-readable names.
    private static func formatAction(_ action: String) -> String {
        // Strip "c2pa." prefix and convert underscores to spaces, then capitalize
        let stripped = action.hasPrefix("c2pa.") ? String(action.dropFirst(5)) : action
        return stripped
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
