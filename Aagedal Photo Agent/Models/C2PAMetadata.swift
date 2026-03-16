import AppKit
import Foundation

struct C2PAThumbnails {
    let claimThumbnail: NSImage?
    let ingredientThumbnail: NSImage?
}

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
    let digitalSourceType: String?
    let ingredientFormat: String?
    let documentID: String?
    let instanceID: String?
    let assertions: [String]
}

struct C2PAMetadata: Identifiable {
    let id = UUID()
    let manifests: [C2PAManifest]
    var thumbnails: C2PAThumbnails?
    var activeManifest: C2PAManifest? { manifests.last }

    private enum C2PAKey {
        static let jumdType = "JUMDType"
        static let jumdLabel = "JUMDLabel"
        static let c2ma = "c2ma"
        static let c2paClaim = "c2pa.claim"
        static let c2paActions = "c2pa.actions"
        static let creativeWork = "stds.schema-org.CreativeWork"
        static let c2paIngredientPrefix = "c2pa.ingredient"
        static let claimGenerator = "Claim_generator"
        static let claimGeneratorInfoName = "Claim_Generator_InfoName"
        static let claimGeneratorInfoVersion = "Claim_Generator_InfoVersion"
        static let alg = "Alg"
        static let title = "Title"
        static let actionsAction = "ActionsAction"
        static let actionsDigitalSourceType = "ActionsDigitalSourceType"
        static let authorName = "AuthorName"
        static let format = "Format"
        static let documentID = "DocumentID"
        static let instanceID = "InstanceID"
        static let assertions = "Assertions"
        static let assertionURL = "AssertionURL"
    }

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
            if fieldName == C2PAKey.jumdType, docPrefix == manifestPrefix {
                if let value = dict[key] as? String, value.contains(C2PAKey.c2ma) {
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
            var documentID: String?
            var instanceID: String?
            var assertions: [String] = []

            // Find actions, author, ingredient from assertion nodes
            var actions: [String] = []
            var digitalSourceType: String?
            var author: String?
            var ingredientTitle: String?
            var ingredientFormat: String?

            for (key, value) in manifestDict {
                guard let colonRange = key.range(of: ":") else { continue }
                let field = String(key[colonRange.upperBound...])

                // Identify which sub-node this key belongs to by checking JUMDLabel
                let nodePrefix = String(key[..<colonRange.lowerBound])

                // Claim fields
                if manifestDict["\(nodePrefix):\(C2PAKey.jumdLabel)"] as? String == C2PAKey.c2paClaim {
                    switch field {
                    case C2PAKey.claimGenerator: claimGenerator = value as? String
                    case C2PAKey.claimGeneratorInfoName: generatorName = value as? String
                    case C2PAKey.claimGeneratorInfoVersion: generatorVersion = value as? String
                    case C2PAKey.alg: algorithm = value as? String
                    case C2PAKey.title: title = value as? String
                    case C2PAKey.documentID: documentID = value as? String
                    case C2PAKey.instanceID: instanceID = value as? String
                    default: break
                    }
                }

                // Claim assertions array
                if manifestDict["\(nodePrefix):\(C2PAKey.jumdLabel)"] as? String == C2PAKey.c2paClaim,
                   field == C2PAKey.assertions || field == C2PAKey.assertionURL {
                    if let urlArray = value as? [String] {
                        assertions = urlArray.compactMap { Self.extractAssertionLabel($0) }
                    } else if let single = value as? String {
                        assertions = [Self.extractAssertionLabel(single)].compactMap { $0 }
                    }
                }

                // Actions
                if let label = manifestDict["\(nodePrefix):\(C2PAKey.jumdLabel)"] as? String,
                   label == C2PAKey.c2paActions {
                    if field == C2PAKey.actionsAction {
                        if let actionArray = value as? [String] {
                            actions = actionArray.map { Self.formatAction($0) }
                        } else if let single = value as? String {
                            actions = [Self.formatAction(single)]
                        }
                    }
                    if field == C2PAKey.actionsDigitalSourceType {
                        digitalSourceType = value as? String
                    }
                }

                // Author (CreativeWork)
                if let label = manifestDict["\(nodePrefix):\(C2PAKey.jumdLabel)"] as? String,
                   label == C2PAKey.creativeWork, field == C2PAKey.authorName {
                    author = value as? String
                }

                // Ingredient
                if let label = manifestDict["\(nodePrefix):\(C2PAKey.jumdLabel)"] as? String,
                   label.hasPrefix(C2PAKey.c2paIngredientPrefix) {
                    if field == C2PAKey.title {
                        ingredientTitle = value as? String
                    }
                    if field == C2PAKey.format {
                        ingredientFormat = value as? String
                    }
                }
            }

            parsed.append(C2PAManifest(
                label: manifestDict["\(prefix):\(C2PAKey.jumdLabel)"] as? String ?? prefix,
                claimGenerator: claimGenerator,
                generatorName: generatorName,
                generatorVersion: generatorVersion,
                author: author,
                actions: actions,
                algorithm: algorithm,
                ingredientTitle: ingredientTitle,
                title: title,
                digitalSourceType: digitalSourceType,
                ingredientFormat: ingredientFormat,
                documentID: documentID,
                instanceID: instanceID,
                assertions: assertions
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

    /// Extract assertion label from a JUMBF URI reference (e.g. "self#jumbf=c2pa.assertions/c2pa.actions" → "c2pa.actions").
    private static func extractAssertionLabel(_ uri: String) -> String? {
        // URIs look like "self#jumbf=/c2pa/...manifest.../c2pa.assertions/c2pa.actions"
        guard let lastSlash = uri.lastIndex(of: "/") else { return uri.isEmpty ? nil : uri }
        let label = String(uri[uri.index(after: lastSlash)...])
        return label.isEmpty ? nil : label
    }

    /// Convert IPTC digital source type URI or short name to display name, reusing DigitalSourceType enum.
    static func formatDigitalSourceType(_ raw: String) -> String {
        // Try short name first (e.g. "digitalCapture")
        if let known = DigitalSourceType(rawValue: raw) {
            return known.displayName
        }
        // Try extracting from IPTC URI (e.g. "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture")
        if let lastSlash = raw.lastIndex(of: "/") {
            let shortName = String(raw[raw.index(after: lastSlash)...])
            if let known = DigitalSourceType(rawValue: shortName) {
                return known.displayName
            }
        }
        return raw
    }

    /// Convert MIME type to friendly format name.
    static func formatMimeType(_ mime: String) -> String {
        let mapping: [String: String] = [
            "image/jpeg": "JPEG",
            "image/png": "PNG",
            "image/tiff": "TIFF",
            "image/heic": "HEIC",
            "image/heif": "HEIF",
            "image/webp": "WebP",
            "image/avif": "AVIF",
            "image/jxl": "JPEG XL",
            "image/gif": "GIF",
            "image/bmp": "BMP",
            "image/x-sony-arw": "Sony ARW",
            "image/x-canon-cr2": "Canon CR2",
            "image/x-canon-cr3": "Canon CR3",
            "image/x-nikon-nef": "Nikon NEF",
            "image/x-fuji-raf": "Fujifilm RAF",
            "image/x-adobe-dng": "Adobe DNG",
            "image/x-panasonic-rw2": "Panasonic RW2",
            "image/x-olympus-orf": "Olympus ORF",
            "image/x-pentax-pef": "Pentax PEF",
            "image/x-samsung-srw": "Samsung SRW",
        ]
        if let friendly = mapping[mime.lowercased()] {
            return friendly
        }
        // Strip "image/" prefix for unknown types
        if mime.lowercased().hasPrefix("image/") {
            return String(mime.dropFirst(6)).uppercased()
        }
        return mime
    }
}
