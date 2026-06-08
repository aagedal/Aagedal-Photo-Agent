import Foundation

/// Top-level metadata-write preset shown as a single picker in Settings. Resolves down to a
/// concrete `MetadataWriteMode` per file (via `MetadataWriteMode.current(forC2PA:isRaw:)`).
enum MetadataWritePreset: String, CaseIterable, Identifiable, Sendable {
    /// Always write metadata directly into the image file, for every file — including
    /// C2PA (subject to the usual overwrite warning) and RAW (best-effort embed).
    case simple
    /// Sidecar for RAW and C2PA files; write to the image file *and* a sidecar for
    /// non-RAW non-C2PA files. Matches a Photo Mechanic-style professional workflow.
    case professional
    /// Use the per-category pickers below (RAW / C2PA / non-C2PA).
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .professional: return "Professional"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .simple:
            return "Always write metadata directly into the image file."
        case .professional:
            return "Sidecar for RAW and C2PA files. Image file + sidecar for everything else."
        case .custom:
            return "Choose where each kind of file is written, below."
        }
    }

    static var current: MetadataWritePreset {
        MetadataWritePreset(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.metadataWritePreset) ?? "")
            ?? .professional
    }
}

enum MetadataWriteMode: String, CaseIterable, Identifiable, Sendable {
    case historyOnly = "historyOnly"
    case writeToFile = "writeToFile"
    case writeToXMPSidecar = "writeToXMPSidecar"
    /// Write embedded metadata into the image file *and* an `.xmp` sidecar (the
    /// "Professional" preset's choice for non-RAW non-C2PA files).
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

    static var defaultNonC2PA: MetadataWriteMode { .writeToFile }
    static var defaultC2PA: MetadataWriteMode { .writeToXMPSidecar }
    static var defaultRaw: MetadataWriteMode { .writeToXMPSidecar }

    static var current: MetadataWriteMode {
        current(forC2PA: false, isRaw: false)
    }

    /// Back-compat overload (callers that don't yet distinguish RAW). Prefer
    /// `current(forC2PA:isRaw:)`.
    static func current(forC2PA: Bool) -> MetadataWriteMode {
        current(forC2PA: forC2PA, isRaw: false)
    }

    /// Resolves the effective write mode for a file, honoring the top-level preset.
    static func current(forC2PA: Bool, isRaw: Bool) -> MetadataWriteMode {
        switch MetadataWritePreset.current {
        case .simple:
            // Literal: always embed, for every file (C2PA goes through the usual overwrite
            // warning at write time; RAW is a best-effort embed).
            return .writeToFile
        case .professional:
            if isRaw || forC2PA { return .writeToXMPSidecar }
            return .writeToFileAndXMPSidecar
        case .custom:
            if isRaw { return customMode(key: UserDefaultsKeys.metadataWriteModeRaw, default: .defaultRaw) }
            if forC2PA { return customC2PAMode() }
            return customNonC2PAMode()
        }
    }

    // MARK: - Custom-preset per-category resolution

    private static func customMode(key: String, default fallback: MetadataWriteMode) -> MetadataWriteMode {
        let raw = UserDefaults.standard.string(forKey: key) ?? fallback.rawValue
        return MetadataWriteMode(rawValue: raw) ?? fallback
    }

    private static func customC2PAMode() -> MetadataWriteMode {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UserDefaultsKeys.metadataWriteModeC2PA) != nil {
            let raw = defaults.string(forKey: UserDefaultsKeys.metadataWriteModeC2PA) ?? MetadataWriteMode.defaultC2PA.rawValue
            return MetadataWriteMode(rawValue: raw) ?? .defaultC2PA
        }
        // Legacy fallback: never let a C2PA file resolve to a file-writing mode.
        let raw = defaults.string(forKey: UserDefaultsKeys.metadataWriteMode) ?? MetadataWriteMode.defaultC2PA.rawValue
        let mode = MetadataWriteMode(rawValue: raw) ?? .defaultC2PA
        return mode.writesEmbedded ? .writeToXMPSidecar : mode
    }

    private static func customNonC2PAMode() -> MetadataWriteMode {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            ?? defaults.string(forKey: UserDefaultsKeys.metadataWriteMode)
            ?? MetadataWriteMode.defaultNonC2PA.rawValue
        return MetadataWriteMode(rawValue: raw) ?? .defaultNonC2PA
    }
}
