import AppKit
import Foundation

nonisolated struct DetectedEditor: Identifiable, Hashable, Sendable {
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
    case transcription
    case descriptionAssistant
}

nonisolated struct TemplatesFolderBookmarkResolution: Sendable, Equatable {
    let url: URL
    let isStale: Bool
}

nonisolated struct TemplatesFolderBookmarkAccess: Sendable {
    let resolve: @Sendable (Data) throws -> TemplatesFolderBookmarkResolution
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void
    let create: @Sendable (URL) throws -> Data

    init(
        resolve: @escaping @Sendable (Data) throws -> TemplatesFolderBookmarkResolution = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return TemplatesFolderBookmarkResolution(url: url, isStale: isStale)
        },
        startAccessing: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        },
        create: @escaping @Sendable (URL) throws -> Data = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    ) {
        self.resolve = resolve
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.create = create
    }
}

nonisolated struct TemplatesFolderBookmarkSnapshot: Sendable, Equatable {
    let requestID: UUID
    let url: URL
    let refreshedBookmarkData: Data?
}

nonisolated enum TemplatesFolderBookmarkLoadResult: Sendable, Equatable {
    case loaded(TemplatesFolderBookmarkSnapshot)
    case failed(requestID: UUID)
    case cancelledBeforeAccess(requestID: UUID)
    case cancelledAfterAccess(requestID: UUID)
}

nonisolated struct TemplatesFolderBookmarkCommit: Sendable, Equatable {
    let requestID: UUID
    let bookmarkData: Data?
    let cancellationRequestedAfterAccess: Bool
}

nonisolated enum TemplatesFolderBookmarkCommitResult: Sendable, Equatable {
    case completed(TemplatesFolderBookmarkCommit)
    case cancelledBeforeAccess(requestID: UUID)
}

/// Serializes custom Templates-folder bookmark APIs away from MainActor. Bookmark calls are
/// synchronous and may consult a file provider, so cancellation is sampled around each access
/// and the observable owner publishes only a complete result for its current request.
actor TemplatesFolderBookmarkService {
    static let shared = TemplatesFolderBookmarkService()

    private let access: TemplatesFolderBookmarkAccess
    private let cancellationRequested: @Sendable () -> Bool

    init(
        access: TemplatesFolderBookmarkAccess = TemplatesFolderBookmarkAccess(),
        cancellationRequested: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.access = access
        self.cancellationRequested = cancellationRequested
    }

    func resolve(_ bookmarkData: Data, requestID: UUID) -> TemplatesFolderBookmarkLoadResult {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: requestID)
        }
        guard let resolution = try? access.resolve(bookmarkData) else {
            return .failed(requestID: requestID)
        }
        guard !cancellationRequested() else {
            return .cancelledAfterAccess(requestID: requestID)
        }

        var refreshedBookmarkData: Data?
        if resolution.isStale {
            refreshedBookmarkData = createBookmark(for: resolution.url)
            guard !cancellationRequested() else {
                return .cancelledAfterAccess(requestID: requestID)
            }
        }
        return .loaded(TemplatesFolderBookmarkSnapshot(
            requestID: requestID,
            url: resolution.url,
            refreshedBookmarkData: refreshedBookmarkData
        ))
    }

    func createBookmark(
        for url: URL,
        requestID: UUID
    ) -> TemplatesFolderBookmarkCommitResult {
        guard !cancellationRequested() else {
            return .cancelledBeforeAccess(requestID: requestID)
        }
        let bookmarkData = createBookmark(for: url)
        return .completed(TemplatesFolderBookmarkCommit(
            requestID: requestID,
            bookmarkData: bookmarkData,
            cancellationRequestedAfterAccess: cancellationRequested()
        ))
    }

    private func createBookmark(for url: URL) -> Data? {
        let didStartAccessing = access.startAccessing(url)
        defer {
            if didStartAccessing {
                access.stopAccessing(url)
            }
        }
        return try? access.create(url)
    }
}

@Observable
final class SettingsViewModel {
    private let c2paConfigurationService: C2PASigningConfigurationService
    private let quickListPersistence: KeywordListEditorPersistenceService
    private let quickListStore: KeywordListsStore
    private let templatesFolderDefaults: UserDefaults
    private let templatesFolderBookmarkService: TemplatesFolderBookmarkService
    @ObservationIgnored private var c2paOperationRequestID: UUID?
    @ObservationIgnored private var templatesFolderRequestID: UUID?
    @ObservationIgnored nonisolated(unsafe) private var templatesFolderLoadTask: Task<Void, Never>?
    /// True while `applyStoredValues()` re-reads preferences, so the property observers don't
    /// write the values they were just given back to UserDefaults (and on to iCloud).
    @ObservationIgnored private var isApplyingStoredValues = false
    @ObservationIgnored nonisolated(unsafe) private var preferencesSyncObserver: NSObjectProtocol?
    /// Ephemeral navigation request consumed by the app's Settings scene.
    var requestedDestination: SettingsDestination? = nil
    var rawRenderAsHDR: Bool {
        didSet { persist(rawRenderAsHDR, forKey: UserDefaultsKeys.rawRenderAsHDR) }
    }

    var rawDecodeProfile: RAWDecodeProfile {
        didSet { persist(rawDecodeProfile.rawValue, forKey: UserDefaultsKeys.rawDecodeProfile) }
    }

    var rawDecoderVersionPreference: RAWDecoderVersionPreference {
        didSet { persist(rawDecoderVersionPreference.rawValue, forKey: UserDefaultsKeys.rawDecoderVersionPreference) }
    }

    var fileVisibility: BrowserFileVisibility {
        didSet {
            persist(fileVisibility.rawValue, forKey: UserDefaultsKeys.browserFileVisibility)
            NotificationCenter.default.post(name: .showAllFilesChanged, object: nil)
        }
    }

    var showOriginalThumbnails: Bool {
        didSet { persist(showOriginalThumbnails, forKey: UserDefaultsKeys.showOriginalThumbnails) }
    }

    var hiddenDevelopSliders: Set<DevelopSlider> {
        didSet {
            persist(
                hiddenDevelopSliders.map(\.rawValue).sorted(),
                forKey: UserDefaultsKeys.hiddenDevelopSliders
            )
        }
    }

    var developSectionOrder: [DevelopPanelSection] {
        didSet {
            persist(
                developSectionOrder.map(\.rawValue),
                forKey: UserDefaultsKeys.developSectionOrder
            )
        }
    }

    var hiddenIPTCMetadataFields: Set<MetadataFieldID> {
        didSet {
            let existing = AppDefaults.store.stringArray(
                forKey: UserDefaultsKeys.hiddenIPTCMetadataFields
            )
            persist(
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
            guard !isApplyingStoredValues else { return }
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
        didSet { persist(defaultExternalEditor.isEmpty ? nil : defaultExternalEditor, forKey: UserDefaultsKeys.defaultExternalEditor) }
    }

    var defaultEditDestination: DefaultEditDestination {
        didSet { persist(defaultEditDestination.rawValue, forKey: UserDefaultsKeys.defaultEditDestination) }
    }

    var defaultExternalEditorName: String {
        guard !defaultExternalEditor.isEmpty else { return "Not set" }
        return URL(fileURLWithPath: defaultExternalEditor).deletingPathExtension().lastPathComponent
    }

    var faceCleanupPolicy: FaceCleanupPolicy {
        didSet { persist(faceCleanupPolicy.rawValue, forKey: UserDefaultsKeys.faceCleanupPolicy) }
    }

    var metadataWritePreset: MetadataWritePreset {
        didSet { persist(metadataWritePreset.rawValue, forKey: UserDefaultsKeys.metadataWritePreset) }
    }

    var metadataWriteModeNonC2PA: MetadataWriteMode {
        didSet { persist(metadataWriteModeNonC2PA.rawValue, forKey: UserDefaultsKeys.metadataWriteModeNonC2PA) }
    }

    var metadataWriteModeC2PA: MetadataWriteMode {
        didSet { persist(metadataWriteModeC2PA.rawValue, forKey: UserDefaultsKeys.metadataWriteModeC2PA) }
    }

    var metadataWriteModeRaw: MetadataWriteMode {
        didSet { persist(metadataWriteModeRaw.rawValue, forKey: UserDefaultsKeys.metadataWriteModeRaw) }
    }

    var addJobIdToKeywords: Bool {
        didSet { persist(addJobIdToKeywords, forKey: UserDefaultsKeys.addJobIdToKeywords) }
    }

    var multiSelectKeywordsMode: MultiSelectFieldMode {
        didSet { persist(multiSelectKeywordsMode.rawValue, forKey: UserDefaultsKeys.multiSelectKeywordsMode) }
    }

    var multiSelectPersonShownMode: MultiSelectFieldMode {
        didSet { persist(multiSelectPersonShownMode.rawValue, forKey: UserDefaultsKeys.multiSelectPersonShownMode) }
    }

    var reverseGeocodeLanguage: ReverseGeocodeLanguage {
        didSet { persist(reverseGeocodeLanguage.storageValue, forKey: UserDefaultsKeys.reverseGeocodeLanguage) }
    }

    var reverseGeocodeOffline: Bool {
        didSet { persist(reverseGeocodeOffline, forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled) }
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

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setKeywordsListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .keywords)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setPersonShownListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .personShown)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setCopyrightListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .copyright)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setCreatorListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .creator)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setCreditListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .credit)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setCityListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .city)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setCountryListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .country)
    }

    /// Merges the file into the managed list; returns the number of entries added.
    @discardableResult
    func setEventListURL(_ url: URL) async throws -> Int {
        try await importQuickList(from: url, type: .event)
    }

    private func importQuickList(from url: URL, type: QuickListType) async throws -> Int {
        let requestID = UUID()
        let destinationURL = try await managedQuickListURL(for: type)
        let result = try await quickListPersistence.appendEntries(
            [],
            to: destinationURL,
            importing: url,
            requestID: requestID
        )
        guard case .committed(let commit) = result else {
            try Task.checkCancellation()
            return 0
        }
        publishQuickListCommit(commit, type: type)
        return commit.addedEntries.count
    }

    func setTemplatesFolderURL(_ url: URL) async {
        templatesFolderLoadTask?.cancel()
        templatesFolderLoadTask = nil
        let requestID = UUID()
        templatesFolderRequestID = requestID
        let result = await templatesFolderBookmarkService.createBookmark(
            for: url,
            requestID: requestID
        )
        guard templatesFolderRequestID == requestID,
              case .completed(let commit) = result,
              commit.requestID == requestID else { return }
        templatesFolderRequestID = nil
        if let bookmarkData = commit.bookmarkData {
            templatesFolderDefaults.set(bookmarkData, forKey: UserDefaultsKeys.templatesFolderBookmark)
        }
        templatesFolderPath = url.path
    }

    func clearTemplatesFolder() {
        templatesFolderLoadTask?.cancel()
        templatesFolderLoadTask = nil
        templatesFolderRequestID = nil
        templatesFolderDefaults.removeObject(forKey: UserDefaultsKeys.templatesFolderBookmark)
        templatesFolderPath = ""
    }

    func loadTemplatesFolderBookmark() async {
        if let templatesFolderLoadTask {
            await templatesFolderLoadTask.value
            return
        }
        scheduleTemplatesFolderBookmarkLoad()
        await templatesFolderLoadTask?.value
    }

    private func scheduleTemplatesFolderBookmarkLoad() {
        guard let bookmarkData = templatesFolderDefaults.data(
            forKey: UserDefaultsKeys.templatesFolderBookmark
        ) else { return }
        let requestID = UUID()
        templatesFolderRequestID = requestID
        let service = templatesFolderBookmarkService
        let task = Task { @MainActor [weak self] in
            let result = await service.resolve(bookmarkData, requestID: requestID)
            guard let self, self.templatesFolderRequestID == requestID else { return }
            self.templatesFolderLoadTask = nil
            self.templatesFolderRequestID = nil
            guard case .loaded(let snapshot) = result,
                  snapshot.requestID == requestID else { return }
            self.templatesFolderPath = snapshot.url.path
            if let refreshedBookmarkData = snapshot.refreshedBookmarkData {
                self.templatesFolderDefaults.set(
                    refreshedBookmarkData,
                    forKey: UserDefaultsKeys.templatesFolderBookmark
                )
            }
        }
        templatesFolderLoadTask = task
    }

    /// Minimum detection confidence (0.5 - 0.95). Default: 0.7
    var faceMinConfidence: Double {
        didSet { persist(faceMinConfidence, forKey: UserDefaultsKeys.faceMinConfidence) }
    }

    /// Minimum face size in pixels (30 - 150). Default: 50
    var faceMinFaceSize: Int {
        didSet { persist(faceMinFaceSize, forKey: UserDefaultsKeys.faceMinFaceSize) }
    }

    /// Fast (false, default) scans the full frame once. Thorough (true) adds overlapping
    /// tile passes to recover small and off-angle faces in group photos.
    var faceTiledDetection: Bool {
        didSet { persist(faceTiledDetection, forKey: UserDefaultsKeys.faceTiledDetection) }
    }

    /// Sports tagging (experimental): run jersey-number OCR alongside face detection.
    /// The scan pipeline reads the key from UserDefaults directly, so this takes effect
    /// on the next scan without a restart.
    var sportsModeEnabled: Bool {
        didSet { persist(sportsModeEnabled, forKey: UserDefaultsKeys.sportsModeEnabled) }
    }


    // MARK: - Format & Compression

    /// Default export format for SDR images. Default: JPEG
    var exportFormatSDR: ExportFormatSDR {
        didSet { persist(exportFormatSDR.rawValue, forKey: UserDefaultsKeys.exportFormatSDR) }
    }

    /// Default export format for HDR images. Default: HEIC 10-bit
    var exportFormatHDR: ExportFormatHDR {
        didSet { persist(exportFormatHDR.rawValue, forKey: UserDefaultsKeys.exportFormatHDR) }
    }

    /// SDR export quality (0.10 - 1.0). Default: 0.92
    var exportQualitySDR: Double {
        didSet { persist(exportQualitySDR, forKey: UserDefaultsKeys.exportQualitySDR) }
    }

    /// HDR export quality (0.10 - 1.0). Default: 0.92
    var exportQualityHDR: Double {
        didSet { persist(exportQualityHDR, forKey: UserDefaultsKeys.exportQualityHDR) }
    }

    /// TIFF compression method. Default: LZW
    var exportTIFFCompression: TIFFCompression {
        didSet { persist(exportTIFFCompression.rawValue, forKey: UserDefaultsKeys.exportTIFFCompression) }
    }

    /// SDR export color gamut. Default: sRGB
    var exportColorGamutSDR: TargetColorGamut {
        didSet { persist(exportColorGamutSDR.rawValue, forKey: UserDefaultsKeys.exportColorGamutSDR) }
    }

    /// HDR export color gamut. Default: Display P3
    var exportColorGamutHDR: TargetColorGamut {
        didSet { persist(exportColorGamutHDR.rawValue, forKey: UserDefaultsKeys.exportColorGamutHDR) }
    }

    /// Maximum exported long edge. Default: original resolution.
    var exportResolutionLimit: ExportResolutionLimit {
        didSet {
            persist(
                exportResolutionLimit.rawValue,
                forKey: UserDefaultsKeys.exportResolutionLimit
            )
        }
    }

    /// Where exported files are written. Default: sub-folder named after the export format
    var exportLocationMode: ExportLocationMode {
        didSet { persist(exportLocationMode.rawValue, forKey: UserDefaultsKeys.exportLocationMode) }
    }

    /// Custom sub-folder name used when `exportLocationMode == .customSubfolder`. Default: "Exports"
    var exportCustomSubfolderName: String {
        didSet { persist(exportCustomSubfolderName, forKey: UserDefaultsKeys.exportCustomSubfolderName) }
    }

    /// Where “Archive RAW as…” writes files. Independent of normal export settings.
    var rawArchiveLocationMode: RAWArchiveLocationMode {
        didSet {
            persist(
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
        AppDefaults.store.removeObject(
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
        AppDefaults.store.removeObject(
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
            persist(knownPeopleMinConfidence, forKey: UserDefaultsKeys.knownPeopleMinConfidence)
        }
    }

    // MARK: - C2PA Signing

    var c2paCertificatePath: String {
        didSet { persist(c2paCertificatePath.isEmpty ? nil : c2paCertificatePath, forKey: UserDefaultsKeys.c2paCertificatePath) }
    }

    var c2paCertificateSubject: String {
        didSet { persist(c2paCertificateSubject.isEmpty ? nil : c2paCertificateSubject, forKey: UserDefaultsKeys.c2paCertificateSubject) }
    }

    var c2paCertificateExpiry: String {
        didSet { persist(c2paCertificateExpiry.isEmpty ? nil : c2paCertificateExpiry, forKey: UserDefaultsKeys.c2paCertificateExpiry) }
    }

    private(set) var c2paCertificateExists = false

    var c2paDefaultAuthor: String {
        didSet { persist(c2paDefaultAuthor.isEmpty ? nil : c2paDefaultAuthor, forKey: UserDefaultsKeys.c2paDefaultAuthor) }
    }

    /// Uses c2patool's built-in test credential. It creates valid signatures which are
    /// deliberately untrusted, so users can try the workflow before obtaining a credential.
    var c2paUseTestCertificate: Bool {
        didSet { persist(c2paUseTestCertificate, forKey: UserDefaultsKeys.c2paUseTestCertificate) }
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
    /// False until the off-main application lookup has published `detectedEditors`. Until then
    /// the list is empty and the editor picker still shows the saved editor by name.
    private(set) var hasDetectedEditors = false
    @ObservationIgnored private var editorDetectionTask: Task<Void, Never>?

    /// Awaits the launch-time editor detection (tests and callers needing the final list).
    func waitForEditorDetection() async {
        await editorDetectionTask?.value
    }

    /// Up to nine `NSWorkspace.urlForApplication` Launch Services lookups used to run
    /// synchronously in `init`, i.e. on the main thread before the first window appeared.
    private func scheduleEditorDetection() {
        editorDetectionTask = Task(priority: .utility) { @MainActor [weak self] in
            let editors = await Self.detectEditorsOffMain()
            guard let self else { return }
            self.detectedEditors = editors
            self.hasDetectedEditors = true
        }
    }

    @concurrent
    nonisolated private static func detectEditorsOffMain() async -> [DetectedEditor] {
        detectEditors()
    }

    init(
        c2paPersistence: any C2PASigningConfigurationPersisting = AppC2PASigningConfigurationPersistence(),
        pkcs12Importer: any C2PAIdentityImporting = SecurityPKCS12IdentityImporter(),
        c2paFileIO: C2PACertificateFileIO = .system,
        quickListPersistence: KeywordListEditorPersistenceService = .shared,
        quickListStore: KeywordListsStore = .shared,
        templatesFolderDefaults: UserDefaults = AppDefaults.store,
        templatesFolderBookmarkService: TemplatesFolderBookmarkService = .shared
    ) {
        self.c2paConfigurationService = C2PASigningConfigurationService(
            persistence: c2paPersistence,
            pkcs12Importer: pkcs12Importer,
            fileIO: c2paFileIO
        )
        self.quickListPersistence = quickListPersistence
        self.quickListStore = quickListStore
        self.templatesFolderDefaults = templatesFolderDefaults
        self.templatesFolderBookmarkService = templatesFolderBookmarkService
        let synced = SyncedPreferences()
        self.rawRenderAsHDR = synced.rawRenderAsHDR
        self.rawDecodeProfile = synced.rawDecodeProfile
        self.rawDecoderVersionPreference = synced.rawDecoderVersionPreference
        self.fileVisibility = synced.fileVisibility
        self.showOriginalThumbnails = synced.showOriginalThumbnails
        self.hiddenDevelopSliders = synced.hiddenDevelopSliders
        self.developSectionOrder = synced.developSectionOrder
        self.hiddenIPTCMetadataFields = synced.hiddenIPTCMetadataFields
        self.orderedIPTCMetadataFields = synced.orderedIPTCMetadataFields
        self.defaultEditDestination = synced.defaultEditDestination
        self.faceCleanupPolicy = synced.faceCleanupPolicy
        self.metadataWritePreset = synced.metadataWritePreset
        self.metadataWriteModeRaw = synced.metadataWriteModeRaw
        self.metadataWriteModeNonC2PA = synced.metadataWriteModeNonC2PA
        self.metadataWriteModeC2PA = synced.metadataWriteModeC2PA
        self.addJobIdToKeywords = synced.addJobIdToKeywords
        self.multiSelectKeywordsMode = synced.multiSelectKeywordsMode
        self.multiSelectPersonShownMode = synced.multiSelectPersonShownMode
        self.faceMinConfidence = synced.faceMinConfidence
        self.faceMinFaceSize = synced.faceMinFaceSize
        self.faceTiledDetection = synced.faceTiledDetection
        self.knownPeopleMinConfidence = synced.knownPeopleMinConfidence
        self.c2paDefaultAuthor = synced.c2paDefaultAuthor
        self.exportFormatSDR = synced.exportFormatSDR
        self.exportFormatHDR = synced.exportFormatHDR
        self.exportQualitySDR = synced.exportQualitySDR
        self.exportQualityHDR = synced.exportQualityHDR
        self.exportTIFFCompression = synced.exportTIFFCompression
        self.exportColorGamutSDR = synced.exportColorGamutSDR
        self.exportColorGamutHDR = synced.exportColorGamutHDR
        self.exportResolutionLimit = synced.exportResolutionLimit

        // Machine-local preferences below are not mirrored by PreferencesSyncService.
        self.defaultExternalEditor = AppDefaults.store.string(forKey: UserDefaultsKeys.defaultExternalEditor) ?? ""

        let geocodeLangRaw = AppDefaults.store.string(forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        self.reverseGeocodeLanguage = ReverseGeocodeLanguage(storageValue: geocodeLangRaw ?? ReverseGeocodeLanguage.system.storageValue)
        self.reverseGeocodeOffline = AppDefaults.store.bool(forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)

        self.sportsModeEnabled = AppDefaults.store.bool(forKey: UserDefaultsKeys.sportsModeEnabled)

        // C2PA Signing settings
        self.c2paCertificatePath = AppDefaults.store.string(forKey: UserDefaultsKeys.c2paCertificatePath) ?? ""
        self.c2paCertificateSubject = AppDefaults.store.string(forKey: UserDefaultsKeys.c2paCertificateSubject) ?? ""
        self.c2paCertificateExpiry = AppDefaults.store.string(forKey: UserDefaultsKeys.c2paCertificateExpiry) ?? ""
        self.c2paUseTestCertificate = AppDefaults.store.bool(forKey: UserDefaultsKeys.c2paUseTestCertificate)

        let storedLocationMode = AppDefaults.store.string(forKey: UserDefaultsKeys.exportLocationMode) ?? ExportLocationMode.formatSubfolder.rawValue
        self.exportLocationMode = ExportLocationMode(rawValue: storedLocationMode) ?? .formatSubfolder

        self.exportCustomSubfolderName = AppDefaults.store.string(forKey: UserDefaultsKeys.exportCustomSubfolderName) ?? "Exports"

        let rawArchiveMode = AppDefaults.store.string(
            forKey: UserDefaultsKeys.rawArchiveLocationMode
        ) ?? RAWArchiveLocationMode.workFolderArchive.rawValue
        self.rawArchiveLocationMode =
            RAWArchiveLocationMode(rawValue: rawArchiveMode)
            ?? .workFolderArchive
        self.rawArchiveSourceRootPath = RAWArchiveService.ingestRootURL.path
        self.rawArchiveRootPath = RAWArchiveService.archiveRootURL?.path ?? ""

        scheduleEditorDetection()

        scheduleTemplatesFolderBookmarkLoad()

        // Install exact durable payloads directly. Changes without a payload (remote refresh,
        // routing, or legacy writers) trigger one complete actor-owned reload.
        quickListChangeObserver = NotificationCenter.default.addObserver(
            forName: .keywordListChanged,
            object: quickListStore,
            queue: .main
        ) { [weak self] note in
            guard
                let key = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey,
                case .quick(let type) = key
            else { return }
            let destinationURL = note.userInfo?[KeywordListsStore.changedDestinationURLUserInfo] as? URL
            let committedEntries = note.userInfo?[KeywordListsStore.changedEntriesUserInfo] as? [String]
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let committedEntries, destinationURL == self.quickListStore.currentURL(for: key) {
                    self.quickListURLs[type] = destinationURL
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

        // iCloud preference sync writes pulled values straight into UserDefaults (including at
        // launch, after this model has already read them). Re-read them so Settings shows what
        // export uses, and so a later edit doesn't push this model's stale values back out.
        preferencesSyncObserver = NotificationCenter.default.addObserver(
            forName: PreferencesSyncService.didChangeRemotely,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            PreferencesSyncService.deliverNotification { [weak self] in self?.applyStoredValues() }
        }
    }

    nonisolated deinit {
        templatesFolderLoadTask?.cancel()
        quickListRefreshTask?.cancel()
        if let quickListChangeObserver {
            NotificationCenter.default.removeObserver(quickListChangeObserver)
        }
        if let preferencesSyncObserver {
            NotificationCenter.default.removeObserver(preferencesSyncObserver)
        }
    }

    /// Writes a preference unless it is the value `applyStoredValues()` just read back.
    private func persist(_ value: Any?, forKey key: String) {
        guard !isApplyingStoredValues else { return }
        AppDefaults.store.set(value, forKey: key)
    }

    /// Re-reads every iCloud-synced preference from UserDefaults without writing any of them
    /// back. Observers that react to the values (browser panes, export pickers) still fire.
    func applyStoredValues() {
        let synced = SyncedPreferences()
        isApplyingStoredValues = true
        defer { isApplyingStoredValues = false }
        update(\.rawRenderAsHDR, to: synced.rawRenderAsHDR)
        update(\.rawDecodeProfile, to: synced.rawDecodeProfile)
        update(\.rawDecoderVersionPreference, to: synced.rawDecoderVersionPreference)
        update(\.fileVisibility, to: synced.fileVisibility)
        update(\.showOriginalThumbnails, to: synced.showOriginalThumbnails)
        update(\.hiddenDevelopSliders, to: synced.hiddenDevelopSliders)
        update(\.developSectionOrder, to: synced.developSectionOrder)
        update(\.hiddenIPTCMetadataFields, to: synced.hiddenIPTCMetadataFields)
        update(\.orderedIPTCMetadataFields, to: synced.orderedIPTCMetadataFields)
        update(\.defaultEditDestination, to: synced.defaultEditDestination)
        update(\.faceCleanupPolicy, to: synced.faceCleanupPolicy)
        update(\.metadataWritePreset, to: synced.metadataWritePreset)
        update(\.metadataWriteModeRaw, to: synced.metadataWriteModeRaw)
        update(\.metadataWriteModeNonC2PA, to: synced.metadataWriteModeNonC2PA)
        update(\.metadataWriteModeC2PA, to: synced.metadataWriteModeC2PA)
        update(\.addJobIdToKeywords, to: synced.addJobIdToKeywords)
        update(\.multiSelectKeywordsMode, to: synced.multiSelectKeywordsMode)
        update(\.multiSelectPersonShownMode, to: synced.multiSelectPersonShownMode)
        update(\.faceMinConfidence, to: synced.faceMinConfidence)
        update(\.faceMinFaceSize, to: synced.faceMinFaceSize)
        update(\.faceTiledDetection, to: synced.faceTiledDetection)
        update(\.knownPeopleMinConfidence, to: synced.knownPeopleMinConfidence)
        update(\.c2paDefaultAuthor, to: synced.c2paDefaultAuthor)
        update(\.exportFormatSDR, to: synced.exportFormatSDR)
        update(\.exportFormatHDR, to: synced.exportFormatHDR)
        update(\.exportQualitySDR, to: synced.exportQualitySDR)
        update(\.exportQualityHDR, to: synced.exportQualityHDR)
        update(\.exportTIFFCompression, to: synced.exportTIFFCompression)
        update(\.exportColorGamutSDR, to: synced.exportColorGamutSDR)
        update(\.exportColorGamutHDR, to: synced.exportColorGamutHDR)
        update(\.exportResolutionLimit, to: synced.exportResolutionLimit)
    }

    private func update<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<SettingsViewModel, Value>,
        to value: Value
    ) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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
                to: try await managedQuickListURL(for: type),
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
                to: try await managedQuickListURL(for: type),
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
            let destinationURL = try await managedQuickListURL(for: type)
            let result = try await quickListPersistence.deleteQuickList(
                at: destinationURL,
                requestID: requestID
            )
            switch result {
            case .missing, .removed:
                quickListStore.recordExternalDeletion(to: .quick(type), sourceID: requestID)
                guard quickListStore.currentURL(for: .quick(type)) == destinationURL else {
                    scheduleQuickListRefresh()
                    return
                }
                quickListCache[type] = []
                availableQuickLists.remove(type)
                quickListVersion += 1

            case .cancelledBeforeAccess, .cancelledBeforeCommit:
                break
            }
        } catch {
            return
        }
    }

    private func managedQuickListURL(for type: QuickListType) async throws -> URL {
        try await quickListStore.resolveURL(for: .quick(type))
    }

    private func publishQuickListCommit(_ commit: QuickListMutationCommit, type: QuickListType) {
        quickListStore.recordExternalWrite(
            to: .quick(type),
            destinationURL: commit.destinationURL,
            entries: commit.entries,
            sourceID: commit.requestID
        )
        guard quickListStore.currentURL(for: .quick(type)) == commit.destinationURL else {
            quickListURLs.removeAll()
            scheduleQuickListRefresh()
            return
        }
        quickListURLs[type] = commit.destinationURL
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
        quickListRefreshRequestID = requestID
        let persistence = quickListPersistence
        let store = quickListStore
        quickListRefreshTask = Task { @MainActor [weak self] in
            let root: URL
            do {
                root = try await store.resolveRootURL()
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.quickListRefreshRequestID == requestID else { return }
            let version = self.quickListVersion
            let sources = QuickListType.allCases.map { type in
                QuickListCacheSource(type: type, url: root.appendingPathComponent(KeywordListKey.quick(type).relativePath))
            }
            let result = await persistence.loadQuickListCache(
                from: sources,
                requestID: requestID
            )
            guard self.quickListRefreshRequestID == requestID,
                  !Task.isCancelled,
                  case .complete(let snapshot) = result,
                  snapshot.requestID == requestID,
                  snapshot.requestedSources == sources
            else { return }
            guard store.currentRootURL == root, self.quickListVersion == version else {
                self.scheduleQuickListRefresh()
                return
            }
            self.quickListRefreshTask = nil
            self.quickListRefreshRequestID = nil
            for source in sources {
                if !snapshot.failedTypes.contains(source.type) {
                    self.quickListCache[source.type] = snapshot.entriesByType[source.type] ?? []
                } else if self.quickListURLs[source.type] != source.url {
                    self.quickListCache[source.type] = []
                }
                self.quickListURLs[source.type] = source.url
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

    /// Launch Services lookups; thread-safe, so callers run this off the main actor.
    nonisolated static func detectEditors() -> [DetectedEditor] {
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

/// Decoded values of the preferences `PreferencesSyncService` mirrors through iCloud, read the
/// same way at launch and after a remote change so the two paths can't drift apart.
private struct SyncedPreferences {
    let rawRenderAsHDR: Bool
    let rawDecodeProfile: RAWDecodeProfile
    let rawDecoderVersionPreference: RAWDecoderVersionPreference
    let fileVisibility: BrowserFileVisibility
    let showOriginalThumbnails: Bool
    let hiddenDevelopSliders: Set<DevelopSlider>
    let developSectionOrder: [DevelopPanelSection]
    let hiddenIPTCMetadataFields: Set<MetadataFieldID>
    let orderedIPTCMetadataFields: [MetadataFieldID]
    let defaultEditDestination: DefaultEditDestination
    let faceCleanupPolicy: FaceCleanupPolicy
    let metadataWritePreset: MetadataWritePreset
    let metadataWriteModeRaw: MetadataWriteMode
    let metadataWriteModeNonC2PA: MetadataWriteMode
    let metadataWriteModeC2PA: MetadataWriteMode
    let addJobIdToKeywords: Bool
    let multiSelectKeywordsMode: MultiSelectFieldMode
    let multiSelectPersonShownMode: MultiSelectFieldMode
    let faceMinConfidence: Double
    let faceMinFaceSize: Int
    let faceTiledDetection: Bool
    let knownPeopleMinConfidence: Double
    let c2paDefaultAuthor: String
    let exportFormatSDR: ExportFormatSDR
    let exportFormatHDR: ExportFormatHDR
    let exportQualitySDR: Double
    let exportQualityHDR: Double
    let exportTIFFCompression: TIFFCompression
    let exportColorGamutSDR: TargetColorGamut
    let exportColorGamutHDR: TargetColorGamut
    let exportResolutionLimit: ExportResolutionLimit

    init() {
        let store = AppDefaults.store
        rawRenderAsHDR = store.bool(forKey: UserDefaultsKeys.rawRenderAsHDR)
        rawDecodeProfile = RAWDecodeProfile(
            storedRawValue: store.string(forKey: UserDefaultsKeys.rawDecodeProfile) ?? ""
        ) ?? .camera
        rawDecoderVersionPreference = RAWDecoderVersionPreference(
            rawValue: store.string(forKey: UserDefaultsKeys.rawDecoderVersionPreference) ?? ""
        ) ?? .auto
        fileVisibility = BrowserFileVisibility.saved()
        showOriginalThumbnails = store.bool(forKey: UserDefaultsKeys.showOriginalThumbnails)
        hiddenDevelopSliders = DevelopSlider.decodeHidden(
            store.stringArray(forKey: UserDefaultsKeys.hiddenDevelopSliders) ?? []
        )
        developSectionOrder = DevelopPanelSection.decodeOrder(
            store.stringArray(forKey: UserDefaultsKeys.developSectionOrder) ?? []
        )
        hiddenIPTCMetadataFields = MetadataFieldID.resolvedHiddenEditorFields(in: store)
        orderedIPTCMetadataFields = MetadataFieldID.loadEditorFieldOrder()

        let editDestinationRaw = store.string(forKey: UserDefaultsKeys.defaultEditDestination)
            ?? DefaultEditDestination.internalEditor.rawValue
        defaultEditDestination = DefaultEditDestination(rawValue: editDestinationRaw) ?? .internalEditor
        faceCleanupPolicy = FaceCleanupPolicy(
            rawValue: store.string(forKey: UserDefaultsKeys.faceCleanupPolicy) ?? "never"
        ) ?? .never

        // Top-level preset. Absent (existing users / fresh install) → Professional.
        metadataWritePreset = MetadataWritePreset(
            rawValue: store.string(forKey: UserDefaultsKeys.metadataWritePreset) ?? ""
        ) ?? .professional

        let rawModeStored = store.string(forKey: UserDefaultsKeys.metadataWriteModeRaw)
            ?? MetadataWriteMode.defaultRaw.rawValue
        let storedRawMode = MetadataWriteMode(rawValue: rawModeStored) ?? .defaultRaw
        metadataWriteModeRaw = storedRawMode.writesEmbedded ? .writeToXMPSidecar : storedRawMode

        let legacyWriteModeRaw = store.string(forKey: UserDefaultsKeys.metadataWriteMode)
        let nonC2PARaw = store.string(forKey: UserDefaultsKeys.metadataWriteModeNonC2PA)
            ?? legacyWriteModeRaw
            ?? MetadataWriteMode.defaultNonC2PA.rawValue
        metadataWriteModeNonC2PA = MetadataWriteMode(rawValue: nonC2PARaw) ?? .defaultNonC2PA

        if store.object(forKey: UserDefaultsKeys.metadataWriteModeC2PA) != nil {
            let c2paRaw = store.string(forKey: UserDefaultsKeys.metadataWriteModeC2PA)
                ?? MetadataWriteMode.defaultC2PA.rawValue
            metadataWriteModeC2PA = MetadataWriteMode(rawValue: c2paRaw) ?? .defaultC2PA
        } else {
            let c2paRaw = legacyWriteModeRaw ?? MetadataWriteMode.defaultC2PA.rawValue
            let c2paMode = MetadataWriteMode(rawValue: c2paRaw) ?? .defaultC2PA
            metadataWriteModeC2PA = c2paMode == .writeToFile ? .writeToXMPSidecar : c2paMode
        }

        addJobIdToKeywords = store.bool(forKey: UserDefaultsKeys.addJobIdToKeywords)
        multiSelectKeywordsMode = MultiSelectFieldMode(
            rawValue: store.string(forKey: UserDefaultsKeys.multiSelectKeywordsMode) ?? ""
        ) ?? .add
        multiSelectPersonShownMode = MultiSelectFieldMode(
            rawValue: store.string(forKey: UserDefaultsKeys.multiSelectPersonShownMode) ?? ""
        ) ?? .add

        faceMinConfidence = store.object(forKey: UserDefaultsKeys.faceMinConfidence) as? Double ?? 0.7
        faceMinFaceSize = store.object(forKey: UserDefaultsKeys.faceMinFaceSize) as? Int ?? 50
        faceTiledDetection = store.object(forKey: UserDefaultsKeys.faceTiledDetection) as? Bool ?? false
        knownPeopleMinConfidence = store.object(forKey: UserDefaultsKeys.knownPeopleMinConfidence) as? Double
            ?? Double(FaceRecognitionDefaults.knownPeopleMinConfidence)

        c2paDefaultAuthor = store.string(forKey: UserDefaultsKeys.c2paDefaultAuthor) ?? ""

        exportFormatSDR = ExportFormatSDR(
            rawValue: store.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? ""
        ) ?? .jpeg
        exportFormatHDR = ExportFormatHDR(
            rawValue: store.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? ""
        ) ?? .jxl
        let storedQualitySDR = store.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double
        exportQualitySDR = min(1, max(AdvancedExportConfiguration.minimumQuality, storedQualitySDR ?? 0.92))
        let storedQualityHDR = store.object(forKey: UserDefaultsKeys.exportQualityHDR) as? Double
        exportQualityHDR = min(1, max(AdvancedExportConfiguration.minimumQuality, storedQualityHDR ?? 0.92))
        exportTIFFCompression = TIFFCompression(
            rawValue: store.string(forKey: UserDefaultsKeys.exportTIFFCompression) ?? ""
        ) ?? .lzw
        exportColorGamutSDR = TargetColorGamut(
            rawValue: store.string(forKey: UserDefaultsKeys.exportColorGamutSDR) ?? ""
        ) ?? .sRGB
        exportColorGamutHDR = TargetColorGamut(
            rawValue: store.string(forKey: UserDefaultsKeys.exportColorGamutHDR) ?? ""
        ) ?? .displayP3
        exportResolutionLimit = ExportResolutionLimit(
            rawValue: store.string(forKey: UserDefaultsKeys.exportResolutionLimit) ?? ""
        ) ?? .original
    }
}
