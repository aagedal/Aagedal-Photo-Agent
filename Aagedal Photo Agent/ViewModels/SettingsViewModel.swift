import AppKit
import Foundation
import Security

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

enum QuickListType: String, CaseIterable, Identifiable {
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

/// Optional Develop controls that users may hide. Exposure, white balance, and Crop are
/// intentionally absent, making it impossible for persisted preferences or UI code to hide them.
nonisolated enum DevelopSlider: String, CaseIterable, Identifiable, Sendable {
    case saturation
    case vibrance
    case density
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case sharpness
    case clarity
    case dehaze
    case filmGrain
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
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .sharpness: return "Sharpness"
        case .clarity: return "Clarity"
        case .dehaze: return "Dehaze"
        case .filmGrain: return "Film Grain"
        case .halation: return "Halation"
        case .bloom: return "Bloom"
        case .vignette: return "Vignette"
        case .edgeBlur: return "Edge Blur"
        case .anonymizer: return "Anonymizer"
        }
    }

    var group: DevelopSliderGroup {
        switch self {
        case .saturation, .vibrance, .density: return .color
        case .contrast, .highlights, .shadows, .whites, .blacks: return .tone
        case .sharpness, .clarity, .dehaze: return .detail
        case .filmGrain, .halation, .bloom, .vignette, .edgeBlur: return .film
        case .anonymizer: return .privacy
        }
    }

    static func decodeHidden(_ rawValues: [String]) -> Set<DevelopSlider> {
        Set(rawValues.compactMap(DevelopSlider.init(rawValue:)))
    }
}


@Observable
final class SettingsViewModel {
    private let c2paPersistence: any C2PASigningConfigurationPersisting
    private let pkcs12Importer: any C2PAIdentityImporting
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

    var hiddenIPTCMetadataFields: Set<IPTCMetadata.FieldKey> {
        didSet {
            UserDefaults.standard.set(
                hiddenIPTCMetadataFields.map(\.rawValue).sorted(),
                forKey: UserDefaultsKeys.hiddenIPTCMetadataFields
            )
        }
    }

    func isIPTCMetadataFieldVisible(_ field: IPTCMetadata.FieldKey) -> Bool {
        IPTCMetadata.FieldKey.alwaysVisibleEditorFields.contains(field)
            || !hiddenIPTCMetadataFields.contains(field)
    }

    func setIPTCMetadataField(_ field: IPTCMetadata.FieldKey, visible: Bool) {
        guard !IPTCMetadata.FieldKey.alwaysVisibleEditorFields.contains(field) else {
            hiddenIPTCMetadataFields.remove(field)
            return
        }
        if visible {
            hiddenIPTCMetadataFields.remove(field)
        } else {
            hiddenIPTCMetadataFields.insert(field)
        }
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
    @ObservationIgnored private var cachedQuickListVersion: Int = -1
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
        let key = KeywordListKey.quick(type)
        guard KeywordListsStore.shared.exists(key) else { return "" }
        return KeywordListsStore.shared.url(for: key).path
    }

    func setKeywordsListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .keywords)
    }

    func setPersonShownListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .personShown)
    }

    func setCopyrightListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .copyright)
    }

    func setCreatorListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .creator)
    }

    func setCreditListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .credit)
    }

    func setCityListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .city)
    }

    func setCountryListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .country)
    }

    func setEventListURL(_ url: URL) throws {
        try importQuickList(from: url, type: .event)
    }

    private func importQuickList(from url: URL, type: QuickListType) throws {
        try KeywordListsStore.shared.importEntries(from: url, into: .quick(type))
        quickListVersion += 1
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

    var c2paDefaultAuthor: String {
        didSet { UserDefaults.standard.set(c2paDefaultAuthor.isEmpty ? nil : c2paDefaultAuthor, forKey: UserDefaultsKeys.c2paDefaultAuthor) }
    }

    /// Uses c2patool's built-in test credential. It creates valid signatures which are
    /// deliberately untrusted, so users can try the workflow before obtaining a credential.
    var c2paUseTestCertificate: Bool {
        didSet { UserDefaults.standard.set(c2paUseTestCertificate, forKey: UserDefaultsKeys.c2paUseTestCertificate) }
    }

    var c2paHasCertificate: Bool {
        c2paUseTestCertificate || (!c2paCertificatePath.isEmpty && FileManager.default.fileExists(atPath: c2paCertificatePath))
    }

    static var hasC2PASigningCertificate: Bool {
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.c2paUseTestCertificate) { return C2PASigningService.isAvailable }
        guard let path = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificatePath),
              !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path) && C2PASigningService.isAvailable
    }

    func importC2PACertificate(from sourceURL: URL, password: String? = nil) throws {
        do {
            let ext = sourceURL.pathExtension.lowercased()
            if ext == "p12" || ext == "pfx" {
                try importPKCS12(from: sourceURL, password: password ?? "")
            } else {
                try importPEMCertificate(from: sourceURL)
            }
        } catch {
            // An import never owns the optimistic UI state. Re-read persistent settings after
            // every failure so Settings accurately represents the recovered signing pair.
            refreshC2PASettings()
            throw error
        }
    }

    private func importPKCS12(from url: URL, password: String) throws {
        // Security parsing, including private-key export, completes before persistent state changes.
        let identity = try pkcs12Importer.importIdentity(from: url, password: password)
        let previousCertificate = try c2paPersistence.currentCertificateData()
        let previousKey = c2paPersistence.loadPrivateKey()
        let stagedCertificate = try c2paPersistence.stageCertificate(identity.certificatePEM)

        do {
            try c2paPersistence.replacePrivateKey(with: identity.privateKeyPEM)
            do {
                try c2paPersistence.replaceCertificate(with: stagedCertificate)
            } catch {
                // The key may already have changed, so return both stores to their snapshot.
                try? c2paPersistence.replacePrivateKey(with: previousKey)
                try? c2paPersistence.restoreCertificate(previousCertificate)
                throw error
            }
        } catch {
            // A failed Keychain operation must not leave a staged certificate or stale UI state.
            try? FileManager.default.removeItem(at: stagedCertificate)
            throw error
        }

        // Publish settings only after both durable writes have succeeded.
        c2paCertificatePath = c2paPersistence.certificateURL.path(percentEncoded: false)
        c2paCertificateSubject = identity.subject
        c2paCertificateExpiry = identity.expiry
    }

    private func refreshC2PASettings() {
        let path = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificatePath) ?? ""
        c2paCertificatePath = FileManager.default.fileExists(atPath: path) ? path : ""
        c2paCertificateSubject = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificateSubject) ?? ""
        c2paCertificateExpiry = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificateExpiry) ?? ""
    }

    private func importPEMCertificate(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)

        // Check if the file contains a private key
        let hasKey = content.contains("-----BEGIN PRIVATE KEY-----") ||
                     content.contains("-----BEGIN RSA PRIVATE KEY-----") ||
                     content.contains("-----BEGIN EC PRIVATE KEY-----")
        let hasCert = content.contains("-----BEGIN CERTIFICATE-----")

        if hasCert {
            // Extract and save the certificate portion
            let certURL = AppPaths.certificatesDirectory.appendingPathComponent("signing_cert.pem")

            if hasKey {
                // Split: save cert to file, key to Keychain
                let certPEM = extractPEMBlock(from: content, header: "CERTIFICATE")
                let keyPEM = extractPEMBlock(from: content, header: "PRIVATE KEY")
                    ?? extractPEMBlock(from: content, header: "RSA PRIVATE KEY")
                    ?? extractPEMBlock(from: content, header: "EC PRIVATE KEY")

                if let certPEM {
                    try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
                }
                if let keyPEM {
                    try KeychainService.save(password: keyPEM, forKey: "c2pa_private_key")
                }
            } else {
                // Certificate only — copy to app support
                try content.write(to: certURL, atomically: true, encoding: .utf8)
            }

            c2paCertificatePath = certURL.path(percentEncoded: false)
            parseCertificateInfo(from: certURL)
        } else if hasKey {
            // Key only — store in Keychain, prompt for cert separately
            try KeychainService.save(password: content, forKey: "c2pa_private_key")
        }
    }

    private func extractPEMBlock(from content: String, header: String) -> String? {
        let beginMarker = "-----BEGIN \(header)-----"
        let endMarker = "-----END \(header)-----"
        guard let beginRange = content.range(of: beginMarker),
              let endRange = content.range(of: endMarker) else {
            return nil
        }
        return String(content[beginRange.lowerBound...endRange.upperBound])
    }

    private func parseCertificateInfo(from certURL: URL) {
        guard let pemString = try? String(contentsOf: certURL, encoding: .utf8) else { return }

        // Extract DER data from PEM
        let lines = pemString.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let derData = Data(base64Encoded: lines.joined()) else { return }

        guard let cert = SecCertificateCreateWithData(nil, derData as CFData) else { return }
        c2paCertificateSubject = SecCertificateCopySubjectSummary(cert) as String? ?? "Unknown"

        // Try to read expiry
        if let values = SecCertificateCopyValues(cert, nil, nil) as? [String: Any],
           let validityEntry = values["2.5.4.24"] as? [String: Any],
           let notAfter = validityEntry[kSecPropertyKeyValue as String] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            c2paCertificateExpiry = formatter.string(from: notAfter)
        } else {
            c2paCertificateExpiry = ""
        }
    }

    func removeC2PACertificate() {
        if !c2paCertificatePath.isEmpty {
            try? FileManager.default.removeItem(atPath: c2paCertificatePath)
        }
        KeychainService.delete(forKey: "c2pa_private_key")
        c2paCertificatePath = ""
        c2paCertificateSubject = ""
        c2paCertificateExpiry = ""
    }

    var detectedEditors: [DetectedEditor] = []

    init(
        c2paPersistence: any C2PASigningConfigurationPersisting = AppC2PASigningConfigurationPersistence(),
        pkcs12Importer: any C2PAIdentityImporting = SecurityPKCS12IdentityImporter()
    ) {
        self.c2paPersistence = c2paPersistence
        self.pkcs12Importer = pkcs12Importer
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
        self.hiddenIPTCMetadataFields = IPTCMetadata.FieldKey.decodeHidden(
            UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.hiddenIPTCMetadataFields) ?? []
        )

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
        self.metadataWriteModeRaw = MetadataWriteMode(rawValue: rawModeStored) ?? .defaultRaw

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

        // Bump quickListVersion whenever the store reports a per-list change so
        // SwiftUI views observing this ViewModel re-fetch entries.
        quickListChangeObserver = NotificationCenter.default.addObserver(
            forName: .keywordListChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let key = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey,
                case .quick = key
            else { return }
            Task { @MainActor [weak self] in
                self?.quickListVersion += 1
            }
        }
    }

    nonisolated deinit {
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

    /// Returns the entries of a quick list, reading from `KeywordListsStore` and
    /// caching until the next `quickListVersion` bump (file write or import).
    func entries(for type: QuickListType) -> [String] {
        if cachedQuickListVersion == quickListVersion, let cached = quickListCache[type] {
            return cached
        }
        if cachedQuickListVersion != quickListVersion {
            quickListCache.removeAll()
            cachedQuickListVersion = quickListVersion
        }
        let list = KeywordListsStore.shared.readEntries(.quick(type))
        quickListCache[type] = list
        return list
    }

    /// Returns the on-disk URL for a quick list when the file exists, else nil.
    /// Callers used to invoke this to decide whether to prompt the user for a
    /// file; with the managed store the file is always present after first save,
    /// so this returns nil when the list is empty.
    func quickListURL(for type: QuickListType) -> URL? {
        let key = KeywordListKey.quick(type)
        return KeywordListsStore.shared.exists(key)
            ? KeywordListsStore.shared.url(for: key)
            : nil
    }

    func setQuickListURL(_ url: URL, for type: QuickListType) {
        try? importQuickList(from: url, type: type)
    }

    /// Appends `values` to a quick list, deduplicated, and persists through the
    /// store. Returns true on success (false only on a write error). If the list
    /// did not previously exist it is created on-the-fly inside the store.
    @discardableResult
    func appendToQuickList(for type: QuickListType, values: [String]) -> Bool {
        let sanitized = sanitizeQuickListValues(values)
        guard !sanitized.isEmpty else { return false }
        let existing = KeywordListsStore.shared.readEntries(.quick(type))
        var seen = Set(existing)
        var combined = existing
        for value in sanitized where seen.insert(value).inserted {
            combined.append(value)
        }
        guard combined.count != existing.count else {
            // Nothing new — still report success so callers don't show errors.
            return true
        }
        do {
            try KeywordListsStore.shared.writeEntries(combined, to: .quick(type))
            quickListVersion += 1
            return true
        } catch {
            return false
        }
    }

    /// Replaces the quick list with the given entries. Used by the in-app editor.
    @discardableResult
    func replaceQuickList(_ entries: [String], for type: QuickListType) -> Bool {
        do {
            try KeywordListsStore.shared.writeEntries(entries, to: .quick(type))
            quickListVersion += 1
            return true
        } catch {
            return false
        }
    }

    func clearQuickList(_ type: QuickListType) {
        KeywordListsStore.shared.delete(.quick(type))
        quickListVersion += 1
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
