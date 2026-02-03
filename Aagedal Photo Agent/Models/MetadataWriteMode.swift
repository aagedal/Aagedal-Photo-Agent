import Foundation

enum MetadataWriteMode: String, CaseIterable, Identifiable, Sendable {
    case historyOnly = "historyOnly"
    case writeToFile = "writeToFile"
    case writeToXMPSidecar = "writeToXMPSidecar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .historyOnly:
            return "Save History Only"
        case .writeToFile:
            return "Write To Image File"
        case .writeToXMPSidecar:
            return "Write To XMP Sidecar"
        }
    }

    var description: String {
        switch self {
        case .historyOnly:
            return "Save edits to the app's history sidecar only. Metadata is not written to image files automatically."
        case .writeToFile:
            return "Write metadata to the image file as soon as you leave a field. This may invalidate C2PA signatures."
        case .writeToXMPSidecar:
            return "Write metadata to a .xmp sidecar for Adobe-compatible workflows. The image file itself is not modified automatically."
        }
    }

    static var c2paOptions: [MetadataWriteMode] {
        [.historyOnly, .writeToXMPSidecar, .writeToFile]
    }

    static var defaultNonC2PA: MetadataWriteMode { .writeToFile }
    static var defaultC2PA: MetadataWriteMode { .writeToXMPSidecar }

    static var current: MetadataWriteMode {
        current(forC2PA: false)
    }

    static func current(forC2PA: Bool) -> MetadataWriteMode {
        let defaults = UserDefaults.standard
        let legacyKey = "metadataWriteMode"

        if forC2PA {
            if defaults.object(forKey: "metadataWriteModeC2PA") != nil {
                let raw = defaults.string(forKey: "metadataWriteModeC2PA") ?? MetadataWriteMode.defaultC2PA.rawValue
                return MetadataWriteMode(rawValue: raw) ?? .defaultC2PA
            }

            let raw = defaults.string(forKey: legacyKey) ?? MetadataWriteMode.defaultC2PA.rawValue
            let mode = MetadataWriteMode(rawValue: raw) ?? .defaultC2PA
            return mode == .writeToFile ? .writeToXMPSidecar : mode
        } else {
            let raw = defaults.string(forKey: "metadataWriteModeNonC2PA")
                ?? defaults.string(forKey: legacyKey)
                ?? MetadataWriteMode.defaultNonC2PA.rawValue
            return MetadataWriteMode(rawValue: raw) ?? .defaultNonC2PA
        }
    }
}
