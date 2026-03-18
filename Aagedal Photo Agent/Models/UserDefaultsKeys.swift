import Foundation

nonisolated enum UserDefaultsKeys {
    // MARK: - ExifTool
    static let exifToolSource = "exifToolSource"
    static let exifToolCustomPath = "exifToolCustomPath"

    // MARK: - External Editor
    static let defaultExternalEditor = "defaultExternalEditor"
    static let defaultEditDestination = "defaultEditDestination"

    // MARK: - Update Checker
    static let updateCheckFrequency = "updateCheckFrequency"
    static let updateLastChecked = "updateLastChecked"
    static let updateLatestVersion = "updateLatestVersion"
    static let updateAvailable = "updateAvailable"

    // MARK: - Metadata Write Mode
    static let metadataWriteMode = "metadataWriteMode"
    static let metadataWriteModeNonC2PA = "metadataWriteModeNonC2PA"
    static let metadataWriteModeC2PA = "metadataWriteModeC2PA"
    static let metadataPreferXMPSidecar = "metadataPreferXMPSidecar"
    static let metadataAskOnMultipleSources = "metadataAskOnMultipleSources"
    static let pmXmpCompatibilityMode = "pmXmpCompatibilityMode"
    static let pmNonRawXmpBehavior = "pmNonRawXmpBehavior"
    static let pmNonRawXmpRememberedChoice = "pmNonRawXmpRememberedChoice"

    // MARK: - Face Recognition
    static let faceCleanupPolicy = "faceCleanupPolicy"
    static let visionClusteringThreshold = "visionClusteringThreshold"
    static let faceClothingClusteringThreshold = "faceClothingClusteringThreshold"
    static let faceMinConfidence = "faceMinConfidence"
    static let faceMinFaceSize = "faceMinFaceSize"
    static let faceRecognitionMode = "faceRecognitionMode"
    static let faceFaceWeight = "faceFaceWeight"
    static let faceClusteringAlgorithm = "faceClusteringAlgorithm"
    static let faceQualityGateThreshold = "faceQualityGateThreshold"
    static let faceUseQualityWeightedEdges = "faceUseQualityWeightedEdges"
    static let faceClothingSecondPassAttachToExisting = "faceClothingSecondPassAttachToExisting"

    // MARK: - Known People
    static let knownPeopleMode = "knownPeopleMode"
    static let knownPeopleMinConfidence = "knownPeopleMinConfidence"

    // MARK: - Favorites & FTP
    static let favoriteFolders = "favoriteFolders"
    static let ftpConnections = "ftpConnections"
    static let lastUsedFTPConnectionID = "lastUsedFTPConnectionID"

    // MARK: - Browser
    static let showAllFiles = "showAllFiles"
    static let thumbnailSortOrder = "thumbnailSortOrder"
    static let thumbnailSortReversed = "thumbnailSortReversed"
    static let thumbnailScale = "thumbnailScale"
    static let previewMode = "previewMode"

    // MARK: - Multi-Select Behavior
    static let multiSelectKeywordsMode = "multiSelectKeywordsMode"
    static let multiSelectPersonShownMode = "multiSelectPersonShownMode"

    // MARK: - Format & Compression
    static let exportFormatSDR = "exportFormatSDR"
    static let exportFormatHDR = "exportFormatHDR"
    static let exportQualitySDR = "exportQualitySDR"
    static let exportQualityHDR = "exportQualityHDR"
    static let exportTIFFCompression = "exportTIFFCompression"

    // MARK: - Quick List Bookmarks
    static let keywordsListBookmark = "keywordsListBookmark"
    static let personShownListBookmark = "personShownListBookmark"
    static let copyrightListBookmark = "copyrightListBookmark"
    static let creatorListBookmark = "creatorListBookmark"
    static let creditListBookmark = "creditListBookmark"
    static let cityListBookmark = "cityListBookmark"
    static let countryListBookmark = "countryListBookmark"
    static let eventListBookmark = "eventListBookmark"
}
