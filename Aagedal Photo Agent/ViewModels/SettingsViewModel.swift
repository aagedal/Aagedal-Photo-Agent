import AppKit
import Foundation

struct DetectedEditor: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

enum DefaultEditDestination: String, CaseIterable, Identifiable {
    case internalEditor = "internalEditor"
    case externalEditor = "externalEditor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .internalEditor:
            return "Internal Editor"
        case .externalEditor:
            return "External App"
        }
    }
}

nonisolated enum RAWDecodeProfile: String, CaseIterable, Identifiable, Sendable {
    case linear
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear:
            return "Linear RAW"
        case .camera:
            return "Camera RAW"
        }
    }

    var subtitle: String {
        switch self {
        case .linear:
            return "Neutral decode without Apple's camera tone boost."
        case .camera:
            return "Apple's camera-matched RAW decode, closer to Finder and Preview. Default."
        }
    }

    init?(storedRawValue: String) {
        switch storedRawValue {
        case "flat":
            self = .linear
        case "native":
            self = .camera
        default:
            self.init(rawValue: storedRawValue)
        }
    }
}

nonisolated enum RAWDecoderVersionPreference: String, CaseIterable, Identifiable {
    case auto
    case v9
    case v8
    case v7
    case v6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto (Newest)"
        case .v9:
            return "Version 9"
        case .v8:
            return "Version 8"
        case .v7:
            return "Version 7"
        case .v6:
            return "Version 6"
        }
    }

    /// Substring matched against CIRAWFilter.supportedDecoderVersions (which reports
    /// e.g. "9" or "9DNG" depending on container). nil leaves decoderVersion untouched.
    nonisolated var matchToken: String? {
        switch self {
        case .auto:
            return nil
        case .v9:
            return "9"
        case .v8:
            return "8"
        case .v7:
            return "7"
        case .v6:
            return "6"
        }
    }
}

nonisolated enum QuickListType: String, CaseIterable, Identifiable, Sendable {
    case keywords
    case personShown
    case copyright
    case creator
    case credit
    case city
    case country
    case event

    var id: String { rawValue }

    var bookmarkKey: String {
        switch self {
        case .keywords: return "keywordsListBookmark"
        case .personShown: return "personShownListBookmark"
        case .copyright: return "copyrightListBookmark"
        case .creator: return "creatorListBookmark"
        case .credit: return "creditListBookmark"
        case .city: return "cityListBookmark"
        case .country: return "countryListBookmark"
        case .event: return "eventListBookmark"
        }
    }

    var displayName: String {
        switch self {
        case .keywords: return "Keywords"
        case .personShown: return "Person Shown"
        case .copyright: return "Copyright"
        case .creator: return "Creator"
        case .credit: return "Credit"
        case .city: return "City"
        case .country: return "Country"
        case .event: return "Event"
        }
    }

    var defaultFilename: String {
        "\(displayName) Quick List.txt"
    }
}

nonisolated enum DevelopSliderGroup: String, CaseIterable, Identifiable, Sendable {
    case color
    case tone
    case detail
    case film
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: return "Color"
        case .tone: return "Tone"
        case .detail: return "Detail"
        case .film: return "Film Emulation"
        case .privacy: return "Privacy"
        }
    }

    var sliders: [DevelopSlider] {
        DevelopSlider.allCases.filter { $0.group == self }
    }

    func isVisible(hiddenSliders: Set<DevelopSlider>) -> Bool {
        sliders.contains { !hiddenSliders.contains($0) }
    }

    func setVisible(_ visible: Bool, hiddenSliders: inout Set<DevelopSlider>) {
        if visible {
            hiddenSliders.subtract(sliders)
        } else {
            hiddenSliders.formUnion(sliders)
        }
    }
}

/// Major sections in the Global Develop inspector. This is intentionally separate from
/// `DevelopSliderGroup`: groups control optional-control visibility, while this enum controls
/// the presentation order of complete sections (including always-visible Color and Exposure).
nonisolated enum DevelopPanelSection: String, CaseIterable, Identifiable, Sendable {
    case color
    case exposure
    case detail
    case toneCurve
    case hsl
    case anonymizer
    case filmEmulation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: return "Color"
        case .exposure: return "Exposure"
        case .detail: return "Detail"
        case .toneCurve: return "Tone Curve"
        case .hsl: return "Hue / Saturation / Density"
        case .anonymizer: return "Anonymizer"
        case .filmEmulation: return "Film Emulation"
        }
    }

    static let defaultOrder: [DevelopPanelSection] = [
        .color,
        .exposure,
        .detail,
        .toneCurve,
        .hsl,
        .anonymizer,
        .filmEmulation,
    ]

    /// Optional controls belonging to this section in the Global Develop inspector.
    ///
    /// Keeping this mapping next to the section order lets Settings present ordering and
    /// visibility as one hierarchy instead of grouping the same controls a second way.
    var optionalSliders: [DevelopSlider] {
        switch self {
        case .color:
            return [.saturation, .vibrance, .density]
        case .exposure:
            return [.contrast, .highlights, .shadows, .whites, .blacks]
        case .detail:
            return [.sharpness, .clarity, .dehaze]
        case .toneCurve:
            return [.toneCurve]
        case .hsl:
            return [.hsl]
        case .anonymizer:
            return [.anonymizer]
        case .filmEmulation:
            return [.filmGrain, .filmGrainCoarseness, .halation, .bloom, .vignette, .edgeBlur]
        }
    }

    /// Controls that keep Color and Exposure present even when all of their optional controls
    /// are hidden. Crop is also always available, but lives outside this ordered section list.
    var alwaysVisibleControlNames: [String] {
        switch self {
        case .color:
            return ["White Balance", "Tint"]
        case .exposure:
            return ["Exposure"]
        case .detail, .toneCurve, .hsl, .anonymizer, .filmEmulation:
            return []
        }
    }

    /// Preserves every valid stored section once, then appends newly-added or missing sections
    /// in their default relative order. Unknown values are ignored for forward/backward safety.
    static func decodeOrder(_ rawValues: [String]) -> [DevelopPanelSection] {
        var seen: Set<DevelopPanelSection> = []
        var result: [DevelopPanelSection] = []
        for rawValue in rawValues {
            guard let section = DevelopPanelSection(rawValue: rawValue),
                  seen.insert(section).inserted else { continue }
            result.append(section)
        }
        for section in defaultOrder where seen.insert(section).inserted {
            result.append(section)
        }
        return result
    }
}

/// Optional Develop controls that users may hide. Exposure, white balance, and Crop are
/// intentionally absent, making it impossible for persisted preferences or UI code to hide them.
nonisolated enum DevelopSlider: String, CaseIterable, Identifiable, Sendable {
    case saturation
    case vibrance
    case density
    case hsl
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case toneCurve
    case sharpness
    case clarity
    case dehaze
    case filmGrain
    case filmGrainCoarseness
    case halation
    case bloom
    case vignette
    case edgeBlur
    case anonymizer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .density: return "Density"
        case .hsl: return "Hue / Saturation / Density"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .toneCurve: return "Tone Curve"
        case .sharpness: return "Sharpness"
        case .clarity: return "Clarity"
        case .dehaze: return "Dehaze"
        case .filmGrain: return "Film Grain"
        case .filmGrainCoarseness: return "Grain Size"
        case .halation: return "Halation"
        case .bloom: return "Bloom"
        case .vignette: return "Vignette"
        case .edgeBlur: return "Edge Blur"
        case .anonymizer: return "Anonymizer"
        }
    }

    var group: DevelopSliderGroup {
        switch self {
        case .saturation, .vibrance, .density, .hsl: return .color
        case .contrast, .highlights, .shadows, .whites, .blacks, .toneCurve: return .tone
        case .sharpness, .clarity, .dehaze: return .detail
        case .filmGrain, .filmGrainCoarseness, .halation, .bloom, .vignette, .edgeBlur: return .film
        case .anonymizer: return .privacy
        }
    }

    static func decodeHidden(_ rawValues: [String]) -> Set<DevelopSlider> {
        Set(rawValues.compactMap(DevelopSlider.init(rawValue:)))
    }
}


nonisolated enum SettingsDestination: Equatable, Sendable {
    case metadata
}

@Observable
final class SettingsViewModel {
    private let c2paConfigurationService: C2PASigningConfigurationService
    private let quickListPersistence: KeywordListEditorPersistenceService
    @ObservationIgnored private var c2paOperationRequestID: UUID?
    /// Ephemeral navigation request consumed by the app's Settings scene.
    var requestedDestination: SettingsDestination? = nil
    var rawRenderAsHDR: Bool {
        didSet { UserDefaults.standard.set(rawRenderAsHDR, forKey: UserDefaultsKeys.rawRenderAsHDR) }
    }

    var rawDecodeProfile: RAWDecodeProfile {
        didSet { UserDefaults.standard.set(rawDecodeProfile.rawValue, forKey: UserDefaultsKeys.rawDecodeProfile) }
    }

    var rawDecoderVersionPreference: RAWDecoderVersionPreference {
        didSet { UserDefaults.standard.set(rawDecoderVersionPreference.rawValue, forKey: UserDefaultsKeys.rawDecoderVersionPreference) }
    }

    var showAllFiles: Bool {
        didSet {
            UserDefaults.standard.set(showAllFiles, forKey: UserDefaultsKeys.showAllFiles)
            NotificationCenter.default.post(name: .showAllFilesChanged, object: nil)
        }
    }

    var showOriginalThumbnails: Bool {
        didSet { UserDefaults.standard.set(showOriginalThumbnails, forKey: UserDefaultsKeys.showOriginalThumbnails) }
    }

    var hiddenDevelopSliders: Set<DevelopSlider> {
        didSet {
            UserDefaults.standard.set(
                hiddenDevelopSliders.map(\.rawValue).sorted(),
                forKey: UserDefaultsKeys.hiddenDevelopSliders
            )
        }
    }

    var developSectionOrder: [DevelopPanelSection] {
        didSet {
            UserDefaults.standard.set(
                developSectionOrder.map(\.rawValue),
                forKey: UserDefaultsKeys.developSectionOrder
            )
        }
    }

    var hiddenIPTCMetadataFields: Set<MetadataFieldID> {
        didSet {
            let existing = UserDefaults.standard.stringArray(
                forKey: UserDefaultsKeys.hiddenIPTCMetadataFields
            )
            UserDefaults.standard.set(
                MetadataFieldID.persistedHiddenEditorFields(
                    hiddenIPTCMetadataFields,
                    preserving: existing
                ),
                forKey: UserDefaultsKeys.hiddenIPTCMetadataFields
            )
        }
    }

    var orderedIPTCMetadataFields: [MetadataFieldID] {
        didSet {
            MetadataFieldID.saveEditorFieldOrder(orderedIPTCMetadataFields)
        }
    }

    var visibleIPTCMetadataFieldsInOrder: [MetadataFieldID] {
        orderedIPTCMetadataFields.filter(isIPTCMetadataFieldVisible)
    }

    func isIPTCMetadataFieldVisible(_ field: MetadataFieldID) -> Bool {
        MetadataFieldID.alwaysVisibleEditorFields.contains(field)
            || !hiddenIPTCMetadataFields.contains(field)
    }

    func setIPTCMetadataField(_ field: MetadataFieldID, visible: Bool) {
        guard !MetadataFieldID.alwaysVisibleEditorFields.contains(field) else {
            hiddenIPTCMetadataFields.remove(field)
            return
        }
        if visible {
            hiddenIPTCMetadataFields.remove(field)
        } else {
            hiddenIPTCMetadataFields.insert(field)
        }
    }

    func resetIPTCMetadataFieldVisibility() {
        hiddenIPTCMetadataFields = MetadataFieldID.resolvedHiddenEditorFields(storedRawValues: nil)
    }

    func moveIPTCMetadataField(_ field: MetadataFieldID, by offset: Int) {
        guard let source = orderedIPTCMetadataFields.firstIndex(of: field) else { return }
        let destination = min(max(0, source + offset), orderedIPTCMetadataFields.count - 1)
        guard source != destination else { return }
        orderedIPTCMetadataFields.remove(at: source)
        orderedIPTCMetadataFields.insert(field, at: destination)
    }

    /// Drag/drop uses one stable contract in both directions: place `field` immediately before
    /// `target`. Resolve the target again after removal so a downward move cannot cross it.
    static func iptcMetadataFieldOrder(
        _ order: [MetadataFieldID],
        moving field: MetadataFieldID,
        before target: MetadataFieldID
    ) -> [MetadataFieldID] {
        guard field != target,
              let source = order.firstIndex(of: field),
              order.contains(target) else { return order }
        var result = order
        result.remove(at: source)
        guard let destination = result.firstIndex(of: target) else { return order }
        result.insert(field, at: destination)
        return result
    }

    func moveIPTCMetadataField(_ field: MetadataFieldID, before target: MetadataFieldID) {
        orderedIPTCMetadataFields = Self.iptcMetadataFieldOrder(
            orderedIPTCMetadataFields,
            moving: field,
            before: target
        )
    }

    func resetIPTCMetadataFieldOrder() {
        orderedIPTCMetadataFields = MetadataFieldID.editorFields
    }

    func isDevelopSliderVisible(_ slider: DevelopSlider) -> Bool {
        !hiddenDevelopSliders.contains(slider)
    }

    func setDevelopSlider(_ slider: DevelopSlider, visible: Bool) {
        if visible {
            hiddenDevelopSliders.remove(slider)
        } else {
            hiddenDevelopSliders.insert(slider)
        }
    }

    func isDevelopSliderGroupVisible(_ group: DevelopSliderGroup) -> Bool {
        group.isVisible(hiddenSliders: hiddenDevelopSliders)
    }

    func setDevelopSliderGroup(_ group: DevelopSliderGroup, visible: Bool) {
        group.setVisible(visible, hiddenSliders: &hiddenDevelopSliders)
    }

    func isDevelopPanelSectionVisible(_ section: DevelopPanelSection) -> Bool {
        section.optionalSliders.contains { !hiddenDevelopSliders.contains($0) }
    }

    func setDevelopPanelSection(_ section: DevelopPanelSection, visible: Bool) {
        if visible {
            hiddenDevelopSliders.subtract(section.optionalSliders)
        } else {
            hiddenDevelopSliders.formUnion(section.optionalSliders)
        }
    }

    func moveDevelopSection(_ section: DevelopPanelSection, by offset: Int) {
        guard let sourceIndex = developSectionOrder.firstIndex(of: section) else { return }
        let destinationIndex = min(max(sourceIndex + offset, 0), developSectionOrder.count - 1)
        guard destinationIndex != sourceIndex else { return }
        var reordered = developSectionOrder
        reordered.remove(at: sourceIndex)
        reordered.insert(section, at: destinationIndex)
        developSectionOrder = reordered
    }

    func resetDevelopSectionOrder() {
        developSectionOrder = DevelopPanelSection.defaultOrder
    }

    var defaultExternalEditor: String {
        didSet { UserDefaults.standard.set(defaultExternalEditor.isEmpty ? nil : defaultExternalEditor, forKey: UserDefaultsKeys.defaultExternalEditor) }
    }

    var defaultEditDestination: DefaultEditDestination {
        didSet { UserDefaults.standard.set(defaultEditDestination.rawValue, forKey: UserDefaultsKeys.defaultEditDestination) }
    }

    var defaultExternalEditorName: String {
        guard !defaultExternalEditor.isEmpty else { return "Not set" }
        return URL(fileURLWithPath: defaultExternalEditor).deletingPathExtension().lastPathComponent
    }

    var faceCleanupPolicy: FaceCleanupPolicy {
        didSet { UserDefaults.standard.set(faceCleanupPolicy.rawValue, forKey: UserDefaultsKeys.faceCleanupPolicy) }
    }

    var metadataWritePreset: MetadataWritePreset {
        didSet { UserDefaults.standard.set(metadataWritePreset.rawValue, forKey: UserDefaultsKeys.metadataWritePreset) }
    }

    var metadataWriteModeNonC2PA: MetadataWriteMode {
        didSet { UserDefaults.standard.set(metadataWriteModeNonC2PA.rawValue, forKey: UserDefaultsKeys.metadataWriteModeNonC2PA) }
    }

    var metadataWriteModeC2PA: MetadataWriteMode {
        didSet { UserDefaults.standard.set(metadataWriteModeC2PA.rawValue, forKey: UserDefaultsKeys.metadataWriteModeC2PA) }
    }

    var metadataWriteModeRaw: MetadataWriteMode {
        didSet { UserDefaults.standard.set(metadataWriteModeRaw.rawValue, forKey: UserDefaultsKeys.metadataWriteModeRaw) }
    }

    var addJobIdToKeywords: Bool {
        didSet { UserDefaults.standard.set(addJobIdToKeywords, forKey: UserDefaultsKeys.addJobIdToKeywords) }
    }

    var multiSelectKeywordsMode: MultiSelectFieldMode {
        didSet { UserDefaults.standard.set(multiSelectKeywordsMode.rawValue, forKey: UserDefaultsKeys.multiSelectKeywordsMode) }
    }

    var multiSelectPersonShownMode: MultiSelectFieldMode {
        didSet { UserDefaults.standard.set(multiSelectPersonShownMode.rawValue, forKey: UserDefaultsKeys.multiSelectPersonShownMode) }
    }

    var reverseGeocodeLanguage: ReverseGeocodeLanguage {
        didSet { AppDefaults.store.set(reverseGeocodeLanguage.storageValue, forKey: UserDefaultsKeys.reverseGeocodeLanguage) }
    }

    var reverseGeocodeOffline: Bool {
        didSet { AppDefaults.store.set(reverseGeocodeOffline, forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled) }
    }

    var quickListVersion: Int = 0
    @ObservationIgnored private var quickListCache: [QuickListType: [String]] = [:]
    @ObservationIgnored private var availableQuickLists: Set<QuickListType> = []
    @ObservationIgnored private var quickListURLs: [QuickListType: URL] = [:]
    @ObservationIgnored private var quickListRefreshRequestID: UUID?
    @ObservationIgnored nonisolated(unsafe) private var quickListRefreshTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var quickListChangeObserver: NSObjectProtocol?

    var approvedLists: ApprovedListService { .shared }
    var structuredKeywords: StructuredKeywordService { .shared }
    var structuredPersonShown: StructuredKeywordService { .personShown }
    var keywordLists: KeywordListsStore { .shared }

    /// Path of the store-backed file when the quick list has any entries. Empty
    /// string when the list is empty — matches the existing UI's "No file chosen"
    /// vs "<filename>" rendering for cheap reuse.
    var keywordsListPath: String { quickListPathIfPresent(.keywords) }
    var personShownListPath: String { quickListPathIfPresent(.personShown) }
    var copyrightListPath: String { quickListPathIfPresent(.copyright) }
    var creatorListPath: String { quickListPathIfPresent(.creator) }
    var creditListPath: String { quickListPathIfPresent(.credit) }
    var cityListPath: String { quickListPathIfPresent(.city) }
    var countryListPath: String { quickListPathIfPresent(.country) }
    var eventListPath: String { quickListPathIfPresent(.event) }
    var templatesFolderPath: String = ""

    private func quickListPathIfPresent(_ type: QuickListType) -> String {
        _ = quickListVersion
        guard availableQuickLists.contains(type) else { return "" }
        return quickListURLs[type]?.path ?? ""
    }

    func setKeywordsListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .keywords)
    }

    func setPersonShownListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .personShown)
    }

    func setCopyrightListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .copyright)
    }

    func setCreatorListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .creator)
    }

    func setCreditListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .credit)
    }

    func setCityListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .city)
    }

    func setCountryListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .country)
    }

    func setEventListURL(_ url: URL) async throws {
        try await importQuickList(from: url, type: .event)
    }

    private func importQuickList(from url: URL, type: QuickListType) async throws {
        let requestID = UUID()
        let destinationURL = managedQuickListURL(for: type)
        let result = try await quickListPersistence.appendEntries(
            [],
            to: destinationURL,
            importing: url,
            requestID: requestID
        )
        guard case .committed(let commit) = result else {
            try Task.checkCancellation()
            return
        }
        publishQuickListCommit(commit, type: type)
    }

    func setTemplatesFolderURL(_ url: URL) {
        saveBookmark(for: url, key: UserDefaultsKeys.templatesFolderBookmark)
        templatesFolderPath = url.path
    }

    func clearTemplatesFolder() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.templatesFolderBookmark)
        templatesFolderPath = ""
    }

    private func saveBookmark(for url: URL, key: String) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: key)
        } catch {
            // Bookmark creation failed
        }
    }

    private func resolveBookmark(key: String) -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                // Re-save the bookmark
                saveBookmark(for: url, key: key)
            }
            return url
        } catch {
            return nil
        }
    }

    /// Minimum detection confidence (0.5 - 0.95). Default: 0.7
    var faceMinConfidence: Double {
        didSet { UserDefaults.standard.set(faceMinConfidence, forKey: UserDefaultsKeys.faceMinConfidence) }
    }

    /// Minimum face size in pixels (30 - 150). Default: 50
    var faceMinFaceSize: Int {
        didSet { UserDefaults.standard.set(faceMinFaceSize, forKey: UserDefaultsKeys.faceMinFaceSize) }
    }

    /// Fast (false, default) scans the full frame once. Thorough (true) adds overlapping
    /// tile passes to recover small and off-angle faces in group photos.
    var faceTiledDetection: Bool {
        didSet { UserDefaults.standard.set(faceTiledDetection, forKey: UserDefaultsKeys.faceTiledDetection) }
    }

    /// Sports tagging (experimental): run jersey-number OCR alongside face detection.
    /// The scan pipeline reads the key from UserDefaults directly, so this takes effect
    /// on the next scan without a restart.
    var sportsModeEnabled: Bool {
        didSet { UserDefaults.standard.set(sportsModeEnabled, forKey: UserDefaultsKeys.sportsModeEnabled) }
    }


    // MARK: - Format & Compression

    /// Default export format for SDR images. Default: JPEG
    var exportFormatSDR: ExportFormatSDR {
        didSet { UserDefaults.standard.set(exportFormatSDR.rawValue, forKey: UserDefaultsKeys.exportFormatSDR) }
    }

    /// Default export format for HDR images. Default: HEIC 10-bit
    var exportFormatHDR: ExportFormatHDR {
        didSet { UserDefaults.standard.set(exportFormatHDR.rawValue, forKey: UserDefaultsKeys.exportFormatHDR) }
    }

    /// SDR export quality (0.10 - 1.0). Default: 0.92
    var exportQualitySDR: Double {
        didSet { UserDefaults.standard.set(exportQualitySDR, forKey: UserDefaultsKeys.exportQualitySDR) }
    }

    /// HDR export quality (0.10 - 1.0). Default: 0.92
    var exportQualityHDR: Double {
        didSet { UserDefaults.standard.set(exportQualityHDR, forKey: UserDefaultsKeys.exportQualityHDR) }
    }

    /// TIFF compression method. Default: LZW
    var exportTIFFCompression: TIFFCompression {
        didSet { UserDefaults.standard.set(exportTIFFCompression.rawValue, forKey: UserDefaultsKeys.exportTIFFCompression) }
    }

    /// SDR export color gamut. Default: sRGB
    var exportColorGamutSDR: TargetColorGamut {
        didSet { UserDefaults.standard.set(exportColorGamutSDR.rawValue, forKey: UserDefaultsKeys.exportColorGamutSDR) }
    }

    /// HDR export color gamut. Default: Display P3
    var exportColorGamutHDR: TargetColorGamut {
        didSet { UserDefaults.standard.set(exportColorGamutHDR.rawValue, forKey: UserDefaultsKeys.exportColorGamutHDR) }
    }

    /// Maximum exported long edge. Default: original resolution.
    var exportResolutionLimit: ExportResolutionLimit {
        didSet {
            UserDefaults.standard.set(
                exportResolutionLimit.rawValue,
                forKey: UserDefaultsKeys.exportResolutionLimit
            )
        }
    }

    /// Where exported files are written. Default: sub-folder named after the export format
    var exportLocationMode: ExportLocationMode {
        didSet { UserDefaults.standard.set(exportLocationMode.rawValue, forKey: UserDefaultsKeys.exportLocationMode) }
    }

    /// Custom sub-folder name used when `exportLocationMode == .customSubfolder`. Default: "Exports"
    var exportCustomSubfolderName: String {
        didSet { UserDefaults.standard.set(exportCustomSubfolderName, forKey: UserDefaultsKeys.exportCustomSubfolderName) }
    }

    /// Where “Archive RAW as…” writes files. Independent of normal export settings.
    var rawArchiveLocationMode: RAWArchiveLocationMode {
        didSet {
            UserDefaults.standard.set(
                rawArchiveLocationMode.rawValue,
                forKey: UserDefaultsKeys.rawArchiveLocationMode
            )
        }
    }

    private(set) var rawArchiveSourceRootPath: String = ""
    private(set) var rawArchiveRootPath: String = ""

    var rawArchiveUsesSourceRootOverride: Bool {
        RAWArchiveService.usesSourceRootOverride
    }

    func setRAWArchiveSourceRootURL(_ url: URL) {
        RAWArchiveService.saveBookmark(
            for: url,
            key: UserDefaultsKeys.rawArchiveSourceRootBookmark
        )
        rawArchiveSourceRootPath = url.path
    }

    func resetRAWArchiveSourceRoot() {
        UserDefaults.standard.removeObject(
            forKey: UserDefaultsKeys.rawArchiveSourceRootBookmark
        )
        rawArchiveSourceRootPath = RAWArchiveService.ingestRootURL.path
    }

    func setRAWArchiveRootURL(_ url: URL) {
        RAWArchiveService.saveBookmark(
            for: url,
            key: UserDefaultsKeys.rawArchiveRootBookmark
        )
        rawArchiveRootPath = url.path
    }

    func clearRAWArchiveRoot() {
        UserDefaults.standard.removeObject(
            forKey: UserDefaultsKeys.rawArchiveRootBookmark
        )
        rawArchiveRootPath = ""
    }

    func refreshRAWArchivePaths() {
        rawArchiveSourceRootPath = RAWArchiveService.ingestRootURL.path
        rawArchiveRootPath = RAWArchiveService.archiveRootURL?.path ?? ""
    }

    /// Minimum confidence required for auto-matching known people. Default: 0.60
    var knownPeopleMinConfidence: Double {
        didSet {
            UserDefaults.standard.set(knownPeopleMinConfidence, forKey: UserDefaultsKeys.knownPeopleMinConfidence)
        }
    }

    // MARK: - C2PA Signing

    var c2paCertificatePath: String {
        didSet { UserDefaults.standard.set(c2paCertificatePath.isEmpty ? nil : c2paCertificatePath, forKey: UserDefaultsKeys.c2paCertificatePath) }
    }

    var c2paCertificateSubject: String {
        didSet { UserDefaults.standard.set(c2paCertificateSubject.isEmpty ? nil : c2paCertificateSubject, forKey: UserDefaultsKeys.c2paCertificateSubject) }
    }

    var c2paCertificateExpiry: String {
        didSet { UserDefaults.standard.set(c2paCertificateExpiry.isEmpty ? nil : c2paCertificateExpiry, forKey: UserDefaultsKeys.c2paCertificateExpiry) }
    }

    private(set) var c2paCertificateExists = false

    var c2paDefaultAuthor: String {
        didSet { UserDefaults.standard.set(c2paDefaultAuthor.isEmpty ? nil : c2paDefaultAuthor, forKey: UserDefaultsKeys.c2paDefaultAuthor) }
    }

    /// Uses c2patool's built-in test credential. It creates valid signatures which are
    /// deliberately untrusted, so users can try the workflow before obtaining a credential.
    var c2paUseTestCertificate: Bool {
        didSet { UserDefaults.standard.set(c2paUseTestCertificate, forKey: UserDefaultsKeys.c2paUseTestCertificate) }
    }

    var c2paHasCertificate: Bool {
        c2paUseTestCertificate || c2paCertificateExists
    }

    func importC2PACertificate(
        from sourceURL: URL,
        password: String? = nil,
        requestID: UUID
    ) async throws -> C2PACertificateImportResult {
        c2paOperationRequestID = requestID
        do {
            let result = try await c2paConfigurationService.importCertificate(
                from: sourceURL,
                password: password ?? "",
                requestID: requestID
            )
            guard c2paOperationRequestID == requestID else { return result }
            c2paOperationRequestID = nil
            if case .committed(let commit) = result,
               let certificateURL = commit.certificateURL {
                c2paCertificatePath = certificateURL.path(percentEncoded: false)
                c2paCertificateSubject = commit.subject
                c2paCertificateExpiry = commit.expiry
                c2paCertificateExists = true
            }
            return result
        } catch {
            if c2paOperationRequestID == requestID {
                c2paOperationRequestID = nil
            }
            throw error
        }
    }

    func refreshC2PACertificateStatus(requestID: UUID) async -> C2PACertificateStatusResult {
        c2paOperationRequestID = requestID
        let result = await c2paConfigurationService.status(
            configuredPath: c2paCertificatePath,
            requestID: requestID
        )
        guard c2paOperationRequestID == requestID else { return result }
        c2paOperationRequestID = nil
        if case .loaded(let snapshot) = result {
            c2paCertificateExists = snapshot.certificateExists
            if !snapshot.certificateExists {
                c2paCertificatePath = ""
                c2paCertificateSubject = ""
                c2paCertificateExpiry = ""
            }
        }
        return result
    }

    func removeC2PACertificate(requestID: UUID) async throws -> C2PACertificateRemovalResult {
        c2paOperationRequestID = requestID
        do {
            let result = try await c2paConfigurationService.removeCertificate(requestID: requestID)
            guard c2paOperationRequestID == requestID else { return result }
            c2paOperationRequestID = nil
            if case .committed = result {
                c2paCertificateExists = false
                c2paCertificatePath = ""
                c2paCertificateSubject = ""
                c2paCertificateExpiry = ""
            }
            return result
        } catch {
            if c2paOperationRequestID == requestID {
                c2paOperationRequestID = nil
            }
            throw error
        }
    }

    var detectedEditors: [DetectedEditor] = []

    init(
        c2paPersistence: any C2PASigningConfigurationPersisting = AppC2PASigningConfigurationPersistence(),
        pkcs12Importer: any C2PAIdentityImporting = SecurityPKCS12IdentityImporter(),
        c2paFileIO: C2PACertificateFileIO = .system,
        quickListPersistence: KeywordListEditorPersistenceService = .shared
    ) {
        self.c2paConfigurationService = C2PASigningConfigurationService(
            persistence: c2paPersistence,
            pkcs12Importer: pkcs12Importer,
            fileIO: c2paFileIO
        )
        self.quickListPersistence = quickListPersistence
        self.rawRenderAsHDR = UserDefaults.standard.bool(forKey: UserDefaultsKeys.rawRenderAsHDR)
        let decodeProfileRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.rawDecodeProfile)
        self.rawDecodeProfile = RAWDecodeProfile(storedRawValue: decodeProfileRaw ?? "") ?? .camera
        let decoderVersionRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.rawDecoderVersionPreference)
        self.rawDecoderVersionPreference = RAWDecoderVersionPreference(rawValue: decoderVersionRaw ?? "") ?? .auto
        self.showAllFiles = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showAllFiles)

        self.showOriginalThumbnails = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showOriginalThumbnails)
        self.hiddenDevelopSliders = DevelopSlider.decodeHidden(
            UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.hiddenDevelopSliders) ?? []
        )
        self.developSectionOrder = DevelopPanelSection.decodeOrder(
            UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.developSectionOrder) ?? []
        )
        self.hiddenIPTCMetadataFields = MetadataFieldID.resolvedHiddenEditorFields(
            storedRawValues: UserDefaults.standard.stringArray(
                forKey: UserDefaultsKeys.hiddenIPTCMetadataFields
            )
        )
        self.orderedIPTCMetadataFields = MetadataFieldID.loadEditorFieldOrder()

        self.defaultExternalEditor = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultExternalEditor) ?? ""
        let editDestinationRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultEditDestination)
            ?? DefaultEditDestination.internalEditor.rawValue
        self.defaultEditDestination = DefaultEditDestination(rawValue: editDestinationRaw) ?? .internalEditor
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.faceCleanupPolicy) ?? "never"
        self.faceCleanupPolicy = FaceCleanupPolicy(rawValue: raw) ?? .never

        // Top-level preset. Absent (existing users / fresh install) → Professional.
        let presetRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.metadataWritePreset)
        self.metadataWritePreset = MetadataWritePreset(rawValue: presetRaw ?? "") ?? .professional

        let rawModeStored = UserDefaults.standard.string(forKey: UserDefaultsKeys.metadataWriteModeRaw)
            ?? MetadataWriteMode.defaultRaw.rawValue
        let storedRawMode = MetadataWriteMode(rawValue: rawModeStored) ?? .defaultRaw
        self.metadataWriteModeRaw = storedRawMode.writesEmbedded ? .writeToXMPSidecar : storedRawMode

        let legacyWriteModeRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.metadataWriteMode)
        let nonC2PARaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            ?? legacyWriteModeRaw
            ?? MetadataWriteMode.defaultNonC2PA.rawValue
        self.metadataWriteModeNonC2PA = MetadataWriteMode(rawValue: nonC2PARaw) ?? .defaultNonC2PA

        if UserDefaults.standard.object(forKey: UserDefaultsKeys.metadataWriteModeC2PA) != nil {
            let c2paRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.metadataWriteModeC2PA)
                ?? MetadataWriteMode.defaultC2PA.rawValue
            self.metadataWriteModeC2PA = MetadataWriteMode(rawValue: c2paRaw) ?? .defaultC2PA
        } else {
            let c2paRaw = legacyWriteModeRaw ?? MetadataWriteMode.defaultC2PA.rawValue
            let c2paMode = MetadataWriteMode(rawValue: c2paRaw) ?? .defaultC2PA
            self.metadataWriteModeC2PA = c2paMode == .writeToFile ? .writeToXMPSidecar : c2paMode
        }

        self.addJobIdToKeywords = UserDefaults.standard.bool(forKey: UserDefaultsKeys.addJobIdToKeywords)

        let keywordsModeRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.multiSelectKeywordsMode) ?? MultiSelectFieldMode.add.rawValue
        self.multiSelectKeywordsMode = MultiSelectFieldMode(rawValue: keywordsModeRaw) ?? .add

        let personShownModeRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.multiSelectPersonShownMode) ?? MultiSelectFieldMode.add.rawValue
        self.multiSelectPersonShownMode = MultiSelectFieldMode(rawValue: personShownModeRaw) ?? .add

        let geocodeLangRaw = AppDefaults.store.string(forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        self.reverseGeocodeLanguage = ReverseGeocodeLanguage(storageValue: geocodeLangRaw ?? ReverseGeocodeLanguage.system.storageValue)
        self.reverseGeocodeOffline = AppDefaults.store.bool(forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)

        let storedConfidence = UserDefaults.standard.object(forKey: UserDefaultsKeys.faceMinConfidence) as? Double
        self.faceMinConfidence = storedConfidence ?? 0.7

        let storedMinSize = UserDefaults.standard.object(forKey: UserDefaultsKeys.faceMinFaceSize) as? Int
        self.faceMinFaceSize = storedMinSize ?? 50

        self.faceTiledDetection = UserDefaults.standard.object(forKey: UserDefaultsKeys.faceTiledDetection) as? Bool ?? false

        self.sportsModeEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.sportsModeEnabled)

        let storedKnownPeopleMinConfidence = UserDefaults.standard.object(forKey: UserDefaultsKeys.knownPeopleMinConfidence) as? Double
        self.knownPeopleMinConfidence = storedKnownPeopleMinConfidence ?? Double(FaceRecognitionDefaults.knownPeopleMinConfidence)

        // C2PA Signing settings
        self.c2paCertificatePath = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificatePath) ?? ""
        self.c2paCertificateSubject = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificateSubject) ?? ""
        self.c2paCertificateExpiry = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificateExpiry) ?? ""
        self.c2paDefaultAuthor = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paDefaultAuthor) ?? ""
        self.c2paUseTestCertificate = UserDefaults.standard.bool(forKey: UserDefaultsKeys.c2paUseTestCertificate)

        // Format & Compression settings
        let storedFormatSDR = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? ExportFormatSDR.jpeg.rawValue
        self.exportFormatSDR = ExportFormatSDR(rawValue: storedFormatSDR) ?? .jpeg

        let storedFormatHDR = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? ExportFormatHDR.jxl.rawValue
        self.exportFormatHDR = ExportFormatHDR(rawValue: storedFormatHDR) ?? .jxl

        let storedQualitySDR = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double
        self.exportQualitySDR = min(
            1,
            max(AdvancedExportConfiguration.minimumQuality, storedQualitySDR ?? 0.92)
        )

        let storedQualityHDR = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualityHDR) as? Double
        self.exportQualityHDR = min(
            1,
            max(AdvancedExportConfiguration.minimumQuality, storedQualityHDR ?? 0.92)
        )

        let storedTIFFCompression = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportTIFFCompression) ?? TIFFCompression.lzw.rawValue
        self.exportTIFFCompression = TIFFCompression(rawValue: storedTIFFCompression) ?? .lzw

        let storedColorGamutSDR = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutSDR) ?? TargetColorGamut.sRGB.rawValue
        self.exportColorGamutSDR = TargetColorGamut(rawValue: storedColorGamutSDR) ?? .sRGB

        let storedColorGamutHDR = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutHDR) ?? TargetColorGamut.displayP3.rawValue
        self.exportColorGamutHDR = TargetColorGamut(rawValue: storedColorGamutHDR) ?? .displayP3

        let storedResolutionLimit = UserDefaults.standard.string(
            forKey: UserDefaultsKeys.exportResolutionLimit
        ) ?? ExportResolutionLimit.original.rawValue
        self.exportResolutionLimit = ExportResolutionLimit(rawValue: storedResolutionLimit) ?? .original

        let storedLocationMode = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportLocationMode) ?? ExportLocationMode.formatSubfolder.rawValue
        self.exportLocationMode = ExportLocationMode(rawValue: storedLocationMode) ?? .formatSubfolder

        self.exportCustomSubfolderName = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportCustomSubfolderName) ?? "Exports"

        let rawArchiveMode = UserDefaults.standard.string(
            forKey: UserDefaultsKeys.rawArchiveLocationMode
        ) ?? RAWArchiveLocationMode.workFolderArchive.rawValue
        self.rawArchiveLocationMode =
            RAWArchiveLocationMode(rawValue: rawArchiveMode)
            ?? .workFolderArchive
        self.rawArchiveSourceRootPath = RAWArchiveService.ingestRootURL.path
        self.rawArchiveRootPath = RAWArchiveService.archiveRootURL?.path ?? ""

        self.detectedEditors = Self.detectEditors()

        // Templates folder still uses a bookmark (user-selected location).
        if let url = resolveBookmark(key: UserDefaultsKeys.templatesFolderBookmark) {
            self.templatesFolderPath = url.path
        }

        // Install exact durable payloads directly. Changes without a payload (remote refresh,
        // routing, or legacy writers) trigger one complete actor-owned reload.
        quickListChangeObserver = NotificationCenter.default.addObserver(
            forName: .keywordListChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let key = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey,
                case .quick(let type) = key
            else { return }
            let committedEntries = note.userInfo?[KeywordListsStore.changedEntriesUserInfo] as? [String]
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let committedEntries {
                    self.installQuickListEntries(committedEntries, for: type)
                } else {
                    // A no-payload notification may represent an iCloud route change. Re-resolve
                    // every managed URL before the actor reloads rather than retaining the old root.
                    self.quickListURLs.removeAll()
                    self.scheduleQuickListRefresh()
                }
            }
        }
        scheduleQuickListRefresh()
    }

    nonisolated deinit {
        quickListRefreshTask?.cancel()
        if let quickListChangeObserver {
            NotificationCenter.default.removeObserver(quickListChangeObserver)
        }
    }

    func loadKeywordsList() -> [String] { entries(for: .keywords) }
    func loadPersonShownList() -> [String] { entries(for: .personShown) }
    func loadCopyrightList() -> [String] { entries(for: .copyright) }
    func loadCreatorList() -> [String] { entries(for: .creator) }
    func loadCreditList() -> [String] { entries(for: .credit) }
    func loadCityList() -> [String] { entries(for: .city) }
    func loadCountryList() -> [String] { entries(for: .country) }
    func loadEventList() -> [String] { entries(for: .event) }

    /// Returns the latest actor-loaded snapshot. This is intentionally cache-only because it is
    /// called from SwiftUI body and metadata suggestion projection on MainActor.
    func entries(for type: QuickListType) -> [String] {
        _ = quickListVersion
        return quickListCache[type] ?? []
    }

    /// Returns the on-disk URL for a quick list when the file exists, else nil.
    /// Callers used to invoke this to decide whether to prompt the user for a
    /// file; with the managed store the file is always present after first save,
    /// so this returns nil when the list is empty.
    func quickListURL(for type: QuickListType) -> URL? {
        availableQuickLists.contains(type) ? quickListURLs[type] : nil
    }

    func setQuickListURL(_ url: URL, for type: QuickListType) async {
        try? await importQuickList(from: url, type: type)
    }

    /// Appends `values` to a quick list, deduplicated, and persists through the
    /// store. Returns true on success (false only on a write error). If the list
    /// did not previously exist it is created on-the-fly inside the store.
    @discardableResult
    func appendToQuickList(for type: QuickListType, values: [String]) async -> Bool {
        let sanitized = sanitizeQuickListValues(values)
        guard !sanitized.isEmpty else { return false }
        do {
            let result = try await quickListPersistence.appendEntries(
                sanitized,
                to: managedQuickListURL(for: type),
                createDestinationIfMissing: true,
                requestID: UUID()
            )
            switch result {
            case .committed(let commit):
                publishQuickListCommit(commit, type: type)
                return true
            case .unchanged:
                return true
            default:
                return false
            }
        } catch {
            return false
        }
    }

    /// Replaces the quick list with the given entries. Used by the in-app editor.
    @discardableResult
    func replaceQuickList(_ entries: [String], for type: QuickListType) async -> Bool {
        do {
            let result = try await quickListPersistence.saveEntries(
                entries,
                to: managedQuickListURL(for: type),
                requestID: UUID()
            )
            guard case .committed(let commit) = result else { return false }
            let mutationCommit = QuickListMutationCommit(
                requestID: commit.requestID,
                destinationURL: commit.destinationURL,
                entries: commit.entries,
                addedEntries: [],
                byteCount: commit.byteCount,
                cancellationRequestedAfterCommit: commit.cancellationRequestedAfterCommit
            )
            publishQuickListCommit(mutationCommit, type: type)
            return true
        } catch {
            return false
        }
    }

    func clearQuickList(_ type: QuickListType) async {
        let requestID = UUID()
        do {
            let result = try await quickListPersistence.deleteQuickList(
                at: managedQuickListURL(for: type),
                requestID: requestID
            )
            switch result {
            case .missing, .removed:
                quickListCache[type] = []
                availableQuickLists.remove(type)
                quickListVersion += 1
                KeywordListsStore.shared.recordExternalDeletion(
                    to: .quick(type),
                    sourceID: requestID
                )
            case .cancelledBeforeAccess, .cancelledBeforeCommit:
                break
            }
        } catch {
            return
        }
    }

    private func managedQuickListURL(for type: QuickListType) -> URL {
        if let cached = quickListURLs[type] { return cached }
        let url = KeywordListsStore.shared.url(for: .quick(type))
        quickListURLs[type] = url
        return url
    }

    private func publishQuickListCommit(_ commit: QuickListMutationCommit, type: QuickListType) {
        KeywordListsStore.shared.recordExternalWrite(
            to: .quick(type),
            entries: commit.entries,
            sourceID: commit.requestID
        )
        installQuickListEntries(commit.entries, for: type)
    }

    private func installQuickListEntries(_ entries: [String], for type: QuickListType) {
        guard quickListCache[type] != entries || !availableQuickLists.contains(type) else { return }
        quickListCache[type] = entries
        availableQuickLists.insert(type)
        quickListVersion += 1
    }

    private func scheduleQuickListRefresh() {
        quickListRefreshTask?.cancel()
        let requestID = UUID()
        let sources = QuickListType.allCases.map { type in
            QuickListCacheSource(type: type, url: managedQuickListURL(for: type))
        }
        quickListRefreshRequestID = requestID
        let persistence = quickListPersistence
        quickListRefreshTask = Task { @MainActor [weak self] in
            let result = await persistence.loadQuickListCache(
                from: sources,
                requestID: requestID
            )
            guard let self,
                  self.quickListRefreshRequestID == requestID,
                  !Task.isCancelled,
                  case .complete(let snapshot) = result,
                  snapshot.requestID == requestID,
                  snapshot.requestedSources == sources
            else { return }
            self.quickListRefreshTask = nil
            self.quickListRefreshRequestID = nil
            for source in sources where !snapshot.failedTypes.contains(source.type) {
                self.quickListCache[source.type] = snapshot.entriesByType[source.type] ?? []
            }
            self.availableQuickLists = snapshot.availableTypes
            self.quickListVersion += 1
        }
    }

    private func sanitizeQuickListValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    static func detectEditors() -> [DetectedEditor] {
        let candidates: [(name: String, bundleIDs: [String])] = [
            ("Adobe Photoshop", [
                "com.adobe.Photoshop",
                "com.adobe.Photoshop2024",
                "com.adobe.Photoshop2025",
                "com.adobe.Photoshop2026",
            ]),
            ("Affinity Photo", [
                "com.seriflabs.affinityphoto2",
                "com.seriflabs.affinityphoto",
            ]),
            ("GIMP", [
                "org.gimp.gimp-2.10",
                "org.gimp.GIMP",
                "org.gimp.gimp",
            ]),
        ]

        var editors: [DetectedEditor] = []
        for candidate in candidates {
            for bundleID in candidate.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    editors.append(DetectedEditor(name: candidate.name, path: url.path))
                    break
                }
            }
        }
        return editors
    }
}
