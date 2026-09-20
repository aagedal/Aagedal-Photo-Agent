import Foundation

// Shared value-only write modes and RAW-safe target resolution. User preferences and
// physical write execution remain in their separate application services.
enum MetadataWriteMode: String, CaseIterable, Identifiable, Sendable {
    case historyOnly = "historyOnly"
    case writeToFile = "writeToFile"
    case writeToXMPSidecar = "writeToXMPSidecar"
    /// Write embedded metadata into the image file *and* an `.xmp` sidecar
    /// (available via the Custom preset's per-category pickers).
    case writeToFileAndXMPSidecar = "writeToFileAndXMPSidecar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .historyOnly:
            return "Save History Only"
        case .writeToFile:
            return "Write To Image File"
        case .writeToXMPSidecar:
            return "Write To XMP Sidecar"
        case .writeToFileAndXMPSidecar:
            return "Write To Image File + XMP Sidecar"
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
        case .writeToFileAndXMPSidecar:
            return "Write metadata to the image file and also keep a matching .xmp sidecar."
        }
    }

    /// Whether this mode writes embedded metadata into the image file.
    var writesEmbedded: Bool {
        self == .writeToFile || self == .writeToFileAndXMPSidecar
    }

    /// Whether this mode writes an `.xmp` sidecar.
    var writesXMPSidecar: Bool {
        self == .writeToXMPSidecar || self == .writeToFileAndXMPSidecar
    }

    /// Modes offered for C2PA images in the Custom preset (never the file-writing ones —
    /// those invalidate the credential).
    static var c2paOptions: [MetadataWriteMode] {
        [.historyOnly, .writeToXMPSidecar]
    }

    /// Modes offered in the Custom non-C2PA and RAW pickers.
    static var standardOptions: [MetadataWriteMode] {
        [.historyOnly, .writeToFile, .writeToXMPSidecar, .writeToFileAndXMPSidecar]
    }

    /// Proprietary RAW containers are never offered an embedded destination.
    static var rawOptions: [MetadataWriteMode] {
        [.historyOnly, .writeToXMPSidecar]
    }

    static var defaultNonC2PA: MetadataWriteMode { .writeToFile }
    static var defaultC2PA: MetadataWriteMode { .writeToXMPSidecar }
    static var defaultRaw: MetadataWriteMode { .writeToXMPSidecar }

}

/// The physical destination selected for a descriptive-metadata write.
nonisolated enum DescriptiveMetadataWriteTarget: Sendable, Equatable {
    case historyOnly
    case embedded
    case xmpSidecar
    case embeddedAndXMPSidecar

    nonisolated var writesEmbedded: Bool {
        switch self {
        case .embedded, .embeddedAndXMPSidecar: return true
        case .historyOnly, .xmpSidecar: return false
        }
    }

    nonisolated var writesXMPSidecar: Bool {
        switch self {
        case .xmpSidecar, .embeddedAndXMPSidecar: return true
        case .historyOnly, .embedded: return false
        }
    }
}

/// Central target policy for descriptive metadata. Proprietary RAW containers are a hard safety
/// boundary: a request to embed (including a dual write) is reduced to one adjacent XMP write.
nonisolated struct DescriptiveMetadataWriteTargetResolver: Sendable {
    nonisolated init() {}

    nonisolated func resolve(
        sourceURL: URL,
        requestedMode: MetadataWriteMode
    ) -> DescriptiveMetadataWriteTarget {
        if MCPPhotoFormatCatalog.rawExtensions.contains(sourceURL.pathExtension.lowercased()) {
            switch requestedMode {
            case .historyOnly:
                return .historyOnly
            case .writeToFile, .writeToXMPSidecar, .writeToFileAndXMPSidecar:
                return .xmpSidecar
            }
        }

        switch requestedMode {
        case .historyOnly: return .historyOnly
        case .writeToFile: return .embedded
        case .writeToXMPSidecar: return .xmpSidecar
        case .writeToFileAndXMPSidecar: return .embeddedAndXMPSidecar
        }
    }
}
