import AppKit
import Foundation

struct DetectedEditor: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let caskURL = URL(string: "https://raw.githubusercontent.com/aagedal/homebrew-casks/main/Casks/aagedal-photo-agent.rb")!
    private var isChecking = false

    private enum Keys {
        static let updateCheckFrequency = "updateCheckFrequency"
        static let updateLastChecked = "updateLastChecked"
        static let updateLatestVersion = "updateLatestVersion"
        static let updateAvailable = "updateAvailable"
    }

    func checkIfNeeded() async {
        guard let interval = currentFrequency.interval else { return }
        if let lastChecked = lastCheckedDate,
           Date().timeIntervalSince(lastChecked) < interval {
            return
        }
        await checkNow()
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let now = Date()
        defer { setLastChecked(now) }

        do {
            let (data, response) = try await URLSession.shared.data(from: caskURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            guard let latestVersion = parseVersion(from: text) else { return }
            setLatestVersion(latestVersion)
            setUpdateAvailable(Self.isNewerVersion(latestVersion, than: currentVersion))
        } catch {
            return
        }
    }

    private var currentFrequency: UpdateCheckFrequency {
        let raw = UserDefaults.standard.string(forKey: Keys.updateCheckFrequency) ?? UpdateCheckFrequency.weekly.rawValue
        return UpdateCheckFrequency(rawValue: raw) ?? .weekly
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var lastCheckedDate: Date? {
        let timestamp = UserDefaults.standard.double(forKey: Keys.updateLastChecked)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func setLastChecked(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.updateLastChecked)
    }

    private func setLatestVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: Keys.updateLatestVersion)
    }

    private func setUpdateAvailable(_ available: Bool) {
        UserDefaults.standard.set(available, forKey: Keys.updateAvailable)
    }

    private func parseVersion(from text: String) -> String? {
        let pattern = #"(?m)^\s*version\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let versionRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let version = String(text[versionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if version == ":latest" || version == "latest" {
            return nil
        }
        return version
    }

    private static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        let remoteParts = parseVersionParts(remote)
        let currentParts = parseVersionParts(current)
        let maxCount = max(remoteParts.count, currentParts.count)
        for index in 0..<maxCount {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let c = index < currentParts.count ? currentParts[index] : 0
            if r != c { return r > c }
        }
        return false
    }

    private static func parseVersionParts(_ version: String) -> [Int] {
        version
            .split { $0 == "." || $0 == "-" || $0 == "_" }
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

enum ExifToolSource: String, CaseIterable {
    case bundled = "bundled"
    case homebrew = "homebrew"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .bundled: return "Bundled"
        case .homebrew: return "Homebrew"
        case .custom: return "Custom"
        }
    }
}

enum UpdateCheckFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never:
            return nil
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        case .monthly:
            return 30 * 24 * 60 * 60
        }
    }
}

enum QuickListType: String, CaseIterable {
    case keywords
    case personShown
    case copyright
    case creator
    case credit
    case city
    case country
    case event

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

@Observable
final class SettingsViewModel {
    var exifToolSource: ExifToolSource {
        didSet { UserDefaults.standard.set(exifToolSource.rawValue, forKey: "exifToolSource") }
    }

    var exifToolCustomPath: String {
        didSet { UserDefaults.standard.set(exifToolCustomPath.isEmpty ? nil : exifToolCustomPath, forKey: "exifToolCustomPath") }
    }

    var defaultExternalEditor: String {
        didSet { UserDefaults.standard.set(defaultExternalEditor.isEmpty ? nil : defaultExternalEditor, forKey: "defaultExternalEditor") }
    }

    var defaultExternalEditorName: String {
        guard !defaultExternalEditor.isEmpty else { return "Not set" }
        return URL(fileURLWithPath: defaultExternalEditor).deletingPathExtension().lastPathComponent
    }

    var updateCheckFrequency: UpdateCheckFrequency {
        didSet { UserDefaults.standard.set(updateCheckFrequency.rawValue, forKey: "updateCheckFrequency") }
    }

    var faceCleanupPolicy: FaceCleanupPolicy {
        didSet { UserDefaults.standard.set(faceCleanupPolicy.rawValue, forKey: "faceCleanupPolicy") }
    }

    var metadataWriteModeNonC2PA: MetadataWriteMode {
        didSet { UserDefaults.standard.set(metadataWriteModeNonC2PA.rawValue, forKey: "metadataWriteModeNonC2PA") }
    }

    var metadataWriteModeC2PA: MetadataWriteMode {
        didSet { UserDefaults.standard.set(metadataWriteModeC2PA.rawValue, forKey: "metadataWriteModeC2PA") }
    }

    var preferXMPSidecar: Bool {
        didSet { UserDefaults.standard.set(preferXMPSidecar, forKey: "metadataPreferXMPSidecar") }
    }

    var quickListVersion: Int = 0
    var keywordsListPath: String = ""
    var personShownListPath: String = ""
    var copyrightListPath: String = ""
    var creatorListPath: String = ""
    var creditListPath: String = ""
    var cityListPath: String = ""
    var countryListPath: String = ""
    var eventListPath: String = ""

    func setKeywordsListURL(_ url: URL) {
        saveBookmark(for: url, key: "keywordsListBookmark")
        keywordsListPath = url.path
        quickListVersion += 1
    }

    func setPersonShownListURL(_ url: URL) {
        saveBookmark(for: url, key: "personShownListBookmark")
        personShownListPath = url.path
        quickListVersion += 1
    }

    func setCopyrightListURL(_ url: URL) {
        saveBookmark(for: url, key: "copyrightListBookmark")
        copyrightListPath = url.path
        quickListVersion += 1
    }

    func setCreatorListURL(_ url: URL) {
        saveBookmark(for: url, key: "creatorListBookmark")
        creatorListPath = url.path
        quickListVersion += 1
    }

    func setCreditListURL(_ url: URL) {
        saveBookmark(for: url, key: "creditListBookmark")
        creditListPath = url.path
        quickListVersion += 1
    }

    func setCityListURL(_ url: URL) {
        saveBookmark(for: url, key: "cityListBookmark")
        cityListPath = url.path
        quickListVersion += 1
    }

    func setCountryListURL(_ url: URL) {
        saveBookmark(for: url, key: "countryListBookmark")
        countryListPath = url.path
        quickListVersion += 1
    }

    func setEventListURL(_ url: URL) {
        saveBookmark(for: url, key: "eventListBookmark")
        eventListPath = url.path
        quickListVersion += 1
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

    /// Clustering sensitivity threshold for Vision mode. Default: 0.40
    var visionClusteringThreshold: Double {
        didSet { UserDefaults.standard.set(visionClusteringThreshold, forKey: "visionClusteringThreshold") }
    }

    /// Clustering sensitivity threshold for Face+Clothing mode. Default: 0.48
    var faceClothingClusteringThreshold: Double {
        didSet { UserDefaults.standard.set(faceClothingClusteringThreshold, forKey: "faceClothingClusteringThreshold") }
    }

    /// Returns the effective clustering threshold for the current recognition mode
    var effectiveClusteringThreshold: Double {
        switch faceRecognitionMode {
        case .visionFeaturePrint:
            return visionClusteringThreshold
        case .faceAndClothing:
            return faceClothingClusteringThreshold
        }
    }

    /// Minimum detection confidence (0.5 - 0.95). Default: 0.7
    var faceMinConfidence: Double {
        didSet { UserDefaults.standard.set(faceMinConfidence, forKey: "faceMinConfidence") }
    }

    /// Minimum face size in pixels (30 - 150). Default: 50
    var faceMinFaceSize: Int {
        didSet { UserDefaults.standard.set(faceMinFaceSize, forKey: "faceMinFaceSize") }
    }

    /// Face recognition mode (vision, arcface, faceClothing). Default: vision
    var faceRecognitionMode: FaceRecognitionMode {
        didSet { UserDefaults.standard.set(faceRecognitionMode.rawValue, forKey: "faceRecognitionMode") }
    }

    /// Face weight for Face+Clothing mode (0.3 - 0.9). Default: 0.7
    var faceFaceWeight: Double {
        didSet {
            UserDefaults.standard.set(faceFaceWeight, forKey: "faceFaceWeight")
        }
    }

    /// Clothing weight for Face+Clothing mode (auto-calculated as 1 - faceWeight)
    var faceClothingWeight: Double {
        return 1.0 - faceFaceWeight
    }

    /// Clustering algorithm. Default: chineseWhispers (most accurate)
    var faceClusteringAlgorithm: FaceClusteringAlgorithm {
        didSet {
            UserDefaults.standard.set(faceClusteringAlgorithm.rawValue, forKey: "faceClusteringAlgorithm")
        }
    }

    /// Quality gate threshold for quality-gated clustering (0.3 - 0.9). Default: 0.6
    var faceQualityGateThreshold: Double {
        didSet {
            UserDefaults.standard.set(faceQualityGateThreshold, forKey: "faceQualityGateThreshold")
        }
    }

    /// Whether to use quality-weighted edges in Chinese Whispers. Default: true
    var faceUseQualityWeightedEdges: Bool {
        didSet {
            UserDefaults.standard.set(faceUseQualityWeightedEdges, forKey: "faceUseQualityWeightedEdges")
        }
    }

    /// For Face+Clothing mode: allow the second pass to match leftovers to existing groups. Default: false
    var faceClothingSecondPassAttachToExisting: Bool {
        didSet {
            UserDefaults.standard.set(faceClothingSecondPassAttachToExisting, forKey: "faceClothingSecondPassAttachToExisting")
        }
    }

    /// Known People database mode. Default: off
    var knownPeopleMode: KnownPeopleMode {
        didSet {
            UserDefaults.standard.set(knownPeopleMode.rawValue, forKey: "knownPeopleMode")
        }
    }

    /// Minimum confidence required for auto-matching known people. Default: 0.60
    var knownPeopleMinConfidence: Double {
        didSet {
            UserDefaults.standard.set(knownPeopleMinConfidence, forKey: "knownPeopleMinConfidence")
        }
    }

    var detectedEditors: [DetectedEditor] = []

    var bundledExifToolPath: String? {
        // Try ExifTool folder first, then direct resource
        if let bundledDir = Bundle.main.path(forResource: "ExifTool", ofType: nil) {
            return (bundledDir as NSString).appendingPathComponent("exiftool")
        }
        return Bundle.main.path(forResource: "exiftool", ofType: nil)
    }

    var homebrewExifToolPath: String? {
        let paths = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var selectedExifToolPath: String? {
        switch exifToolSource {
        case .bundled:
            return bundledExifToolPath
        case .homebrew:
            return homebrewExifToolPath
        case .custom:
            let path = exifToolCustomPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
    }

    init() {
        let sourceRaw = UserDefaults.standard.string(forKey: "exifToolSource") ?? "bundled"
        self.exifToolSource = ExifToolSource(rawValue: sourceRaw) ?? .bundled
        self.exifToolCustomPath = UserDefaults.standard.string(forKey: "exifToolCustomPath") ?? ""
        self.defaultExternalEditor = UserDefaults.standard.string(forKey: "defaultExternalEditor") ?? ""
        let updateRaw = UserDefaults.standard.string(forKey: "updateCheckFrequency") ?? UpdateCheckFrequency.weekly.rawValue
        self.updateCheckFrequency = UpdateCheckFrequency(rawValue: updateRaw) ?? .weekly
        let raw = UserDefaults.standard.string(forKey: "faceCleanupPolicy") ?? "never"
        self.faceCleanupPolicy = FaceCleanupPolicy(rawValue: raw) ?? .never
        let legacyWriteModeRaw = UserDefaults.standard.string(forKey: "metadataWriteMode")
        let nonC2PARaw = UserDefaults.standard.string(forKey: "metadataWriteModeNonC2PA")
            ?? legacyWriteModeRaw
            ?? MetadataWriteMode.defaultNonC2PA.rawValue
        self.metadataWriteModeNonC2PA = MetadataWriteMode(rawValue: nonC2PARaw) ?? .defaultNonC2PA

        if UserDefaults.standard.object(forKey: "metadataWriteModeC2PA") != nil {
            let c2paRaw = UserDefaults.standard.string(forKey: "metadataWriteModeC2PA")
                ?? MetadataWriteMode.defaultC2PA.rawValue
            self.metadataWriteModeC2PA = MetadataWriteMode(rawValue: c2paRaw) ?? .defaultC2PA
        } else {
            let c2paRaw = legacyWriteModeRaw ?? MetadataWriteMode.defaultC2PA.rawValue
            let c2paMode = MetadataWriteMode(rawValue: c2paRaw) ?? .defaultC2PA
            self.metadataWriteModeC2PA = c2paMode == .writeToFile ? .writeToXMPSidecar : c2paMode
        }

        let preferXmpStored = UserDefaults.standard.object(forKey: "metadataPreferXMPSidecar") as? Bool
        self.preferXMPSidecar = preferXmpStored ?? false

        // Face recognition settings with defaults
        // Mode-specific thresholds with optimized defaults
        let storedVisionThreshold = UserDefaults.standard.object(forKey: "visionClusteringThreshold") as? Double
        self.visionClusteringThreshold = storedVisionThreshold ?? 0.40

        let storedFaceClothingThreshold = UserDefaults.standard.object(forKey: "faceClothingClusteringThreshold") as? Double
        self.faceClothingClusteringThreshold = storedFaceClothingThreshold ?? 0.48

        let storedConfidence = UserDefaults.standard.object(forKey: "faceMinConfidence") as? Double
        self.faceMinConfidence = storedConfidence ?? 0.7

        let storedMinSize = UserDefaults.standard.object(forKey: "faceMinFaceSize") as? Int
        self.faceMinFaceSize = storedMinSize ?? 50

        let storedMode = UserDefaults.standard.string(forKey: "faceRecognitionMode") ?? "faceClothing"
        self.faceRecognitionMode = FaceRecognitionMode(rawValue: storedMode) ?? .faceAndClothing

        let storedFaceWeight = UserDefaults.standard.object(forKey: "faceFaceWeight") as? Double
        self.faceFaceWeight = storedFaceWeight ?? 0.7

        let storedAlgorithm = UserDefaults.standard.string(forKey: "faceClusteringAlgorithm") ?? "chineseWhispers"
        self.faceClusteringAlgorithm = FaceClusteringAlgorithm(rawValue: storedAlgorithm) ?? .chineseWhispers

        let storedQualityGate = UserDefaults.standard.object(forKey: "faceQualityGateThreshold") as? Double
        self.faceQualityGateThreshold = storedQualityGate ?? 0.6

        let storedQualityWeighted = UserDefaults.standard.object(forKey: "faceUseQualityWeightedEdges") as? Bool
        self.faceUseQualityWeightedEdges = storedQualityWeighted ?? true

        let storedSecondPassAttach = UserDefaults.standard.object(forKey: "faceClothingSecondPassAttachToExisting") as? Bool
        self.faceClothingSecondPassAttachToExisting = storedSecondPassAttach ?? false

        let storedKnownPeopleMode = UserDefaults.standard.string(forKey: "knownPeopleMode") ?? "off"
        self.knownPeopleMode = KnownPeopleMode(rawValue: storedKnownPeopleMode) ?? .off
        let storedKnownPeopleMinConfidence = UserDefaults.standard.object(forKey: "knownPeopleMinConfidence") as? Double
        self.knownPeopleMinConfidence = storedKnownPeopleMinConfidence ?? 0.60

        self.detectedEditors = Self.detectEditors()

        // Restore paths from bookmarks (must be after all properties are initialized)
        if let url = resolveBookmark(key: "keywordsListBookmark") {
            self.keywordsListPath = url.path
        }
        if let url = resolveBookmark(key: "personShownListBookmark") {
            self.personShownListPath = url.path
        }
        if let url = resolveBookmark(key: "copyrightListBookmark") {
            self.copyrightListPath = url.path
        }
        if let url = resolveBookmark(key: "creatorListBookmark") {
            self.creatorListPath = url.path
        }
        if let url = resolveBookmark(key: "creditListBookmark") {
            self.creditListPath = url.path
        }
        if let url = resolveBookmark(key: "cityListBookmark") {
            self.cityListPath = url.path
        }
        if let url = resolveBookmark(key: "countryListBookmark") {
            self.countryListPath = url.path
        }
        if let url = resolveBookmark(key: "eventListBookmark") {
            self.eventListPath = url.path
        }
    }

    func loadKeywordsList() -> [String] {
        loadListFromBookmark(key: "keywordsListBookmark")
    }

    func loadPersonShownList() -> [String] {
        loadListFromBookmark(key: "personShownListBookmark")
    }

    func quickListURL(for type: QuickListType) -> URL? {
        resolveBookmark(key: type.bookmarkKey)
    }

    func setQuickListURL(_ url: URL, for type: QuickListType) {
        switch type {
        case .keywords:
            setKeywordsListURL(url)
        case .personShown:
            setPersonShownListURL(url)
        case .copyright:
            setCopyrightListURL(url)
        case .creator:
            setCreatorListURL(url)
        case .credit:
            setCreditListURL(url)
        case .city:
            setCityListURL(url)
        case .country:
            setCountryListURL(url)
        case .event:
            setEventListURL(url)
        }
    }

    func appendToQuickList(for type: QuickListType, values: [String]) -> Bool {
        let sanitized = sanitizeQuickListValues(values)
        guard !sanitized.isEmpty else { return false }
        guard let url = resolveBookmark(key: type.bookmarkKey) else { return false }
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let existingLines = existing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set(existingLines)
        var newLines: [String] = []
        for value in sanitized {
            if !seen.contains(value) {
                seen.insert(value)
                newLines.append(value)
            }
        }

        guard !newLines.isEmpty else { return true }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += newLines.joined(separator: "\n")

        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            quickListVersion += 1
            return true
        } catch {
            return false
        }
    }

    func loadCopyrightList() -> [String] {
        loadListFromBookmark(key: "copyrightListBookmark")
    }

    func loadCreatorList() -> [String] {
        loadListFromBookmark(key: "creatorListBookmark")
    }

    func loadCreditList() -> [String] {
        loadListFromBookmark(key: "creditListBookmark")
    }

    func loadCityList() -> [String] {
        loadListFromBookmark(key: "cityListBookmark")
    }

    func loadCountryList() -> [String] {
        loadListFromBookmark(key: "countryListBookmark")
    }

    func loadEventList() -> [String] {
        loadListFromBookmark(key: "eventListBookmark")
    }

    private func loadListFromBookmark(key: String) -> [String] {
        guard let url = resolveBookmark(key: key) else { return [] }
        guard url.startAccessingSecurityScopedResource() else { return [] }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            return []
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
