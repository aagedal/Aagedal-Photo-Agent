import AppKit
import Foundation

struct DetectedEditor: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
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

    var faceCleanupPolicy: FaceCleanupPolicy {
        didSet { UserDefaults.standard.set(faceCleanupPolicy.rawValue, forKey: "faceCleanupPolicy") }
    }

    var keywordsListPath: String = ""
    var personShownListPath: String = ""

    func setKeywordsListURL(_ url: URL) {
        saveBookmark(for: url, key: "keywordsListBookmark")
        keywordsListPath = url.path
    }

    func setPersonShownListURL(_ url: URL) {
        saveBookmark(for: url, key: "personShownListBookmark")
        personShownListPath = url.path
    }

    private func saveBookmark(for url: URL, key: String) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
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
        let raw = UserDefaults.standard.string(forKey: "faceCleanupPolicy") ?? "never"
        self.faceCleanupPolicy = FaceCleanupPolicy(rawValue: raw) ?? .never

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

        self.detectedEditors = Self.detectEditors()

        // Restore paths from bookmarks (must be after all properties are initialized)
        if let url = resolveBookmark(key: "keywordsListBookmark") {
            self.keywordsListPath = url.path
        }
        if let url = resolveBookmark(key: "personShownListBookmark") {
            self.personShownListPath = url.path
        }
    }

    func loadKeywordsList() -> [String] {
        loadListFromBookmark(key: "keywordsListBookmark")
    }

    func loadPersonShownList() -> [String] {
        loadListFromBookmark(key: "personShownListBookmark")
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
