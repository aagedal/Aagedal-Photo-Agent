import Foundation

/// Top-level metadata-write preset shown as a single picker in Settings. Resolves down to a
/// concrete `MetadataWriteMode` per file (via `MetadataWriteMode.current(forC2PA:isRaw:)`).
enum MetadataWritePreset: String, CaseIterable, Identifiable, Sendable {
    /// Write metadata directly into the image file. Simple deliberately ignores C2PA:
    /// the file is written without warnings even though that invalidates content
    /// credentials. RAW is the exception — embedding into a proprietary RAW container
    /// corrupts maker-private data, so RAW always gets an XMP sidecar.
    case simple
    /// Mirrors Photo Mechanic: sidecar for RAW files (and C2PA, which we treat like RAW
    /// because writing into the file would invalidate the credential); embed directly
    /// into the image file for everything else, including JPEG.
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
            return "Write metadata into the image file, including C2PA-protected files. RAW still uses an XMP sidecar."
        case .professional:
            return "Sidecar for RAW and C2PA files. Write into the image file for everything else, like Photo Mechanic."
        case .custom:
            return "Choose where each kind of file is written, below."
        }
    }

    static var current: MetadataWritePreset {
        MetadataWritePreset(rawValue: AppDefaults.store.string(forKey: UserDefaultsKeys.metadataWritePreset) ?? "")
            ?? .professional
    }
}

extension MetadataWriteMode {
    static var current: MetadataWriteMode {
        current(forC2PA: false, isRaw: false)
    }

    /// Back-compat overload (callers that don't yet distinguish RAW). Prefer
    /// `current(forC2PA:isRaw:)`.
    static func current(forC2PA: Bool) -> MetadataWriteMode {
        current(forC2PA: forC2PA, isRaw: false)
    }

    /// One write mode for a whole selection. Embedding writes already route each RAW file to
    /// its XMP sidecar, so a RAW+JPEG selection whose RAW files resolve to a sidecar uses the
    /// other files' embedding mode (Photo Mechanic: the JPEGs are embedded, the RAWs get
    /// sidecars). Any other mix keeps the most protective mode for the whole selection.
    static func current(forSelection images: [ImageFile]) -> MetadataWriteMode {
        let resolved = images.map {
            (isRaw: SupportedImageFormats.isRaw(url: $0.url),
             mode: current(forC2PA: $0.hasC2PA, isRaw: SupportedImageFormats.isRaw(url: $0.url)))
        }
        let modes = Set(resolved.map(\.mode))
        if modes.count == 1, let mode = modes.first { return mode }
        let rawModes = Set(resolved.filter(\.isRaw).map(\.mode))
        let otherModes = Set(resolved.filter { !$0.isRaw }.map(\.mode))
        if rawModes == [.writeToXMPSidecar], otherModes.count == 1,
           let mode = otherModes.first, mode.writesEmbedded {
            return mode
        }
        return current(
            forC2PA: images.contains(where: \.hasC2PA),
            isRaw: resolved.contains(where: \.isRaw)
        )
    }

    /// Resolves the effective write mode for a file, honoring the top-level preset.
    static func current(forC2PA: Bool, isRaw: Bool) -> MetadataWriteMode {
        switch MetadataWritePreset.current {
        case .simple:
            // Literal: always embed, for every file. C2PA is ignored — the write
            // proceeds without warnings (invalidating the credential is accepted).
            // RAW is the exception: embedding into a proprietary RAW container
            // corrupts maker-private data (e.g. Sony's SR2Private WB block), so RAW
            // always routes to an XMP sidecar regardless of preset.
            if isRaw { return .writeToXMPSidecar }
            return .writeToFile
        case .professional:
            // Photo Mechanic semantics: RAW gets a sidecar; everything else (incl. JPEG)
            // is embedded directly. C2PA is the exception — treated like RAW so the
            // credential survives.
            if isRaw || forC2PA { return .writeToXMPSidecar }
            return .writeToFile
        case .custom:
            if isRaw {
                let configured = customMode(key: UserDefaultsKeys.metadataWriteModeRaw, default: .defaultRaw)
                return configured.writesEmbedded ? .writeToXMPSidecar : configured
            }
            if forC2PA { return customC2PAMode() }
            return customNonC2PAMode()
        }
    }

    // MARK: - Custom-preset per-category resolution

    private static func customMode(key: String, default fallback: MetadataWriteMode) -> MetadataWriteMode {
        let raw = AppDefaults.store.string(forKey: key) ?? fallback.rawValue
        return MetadataWriteMode(rawValue: raw) ?? fallback
    }

    private static func customC2PAMode() -> MetadataWriteMode {
        let defaults = AppDefaults.store
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
        let defaults = AppDefaults.store
        let raw = defaults.string(forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            ?? defaults.string(forKey: UserDefaultsKeys.metadataWriteMode)
            ?? MetadataWriteMode.defaultNonC2PA.rawValue
        return MetadataWriteMode(rawValue: raw) ?? .defaultNonC2PA
    }
}
