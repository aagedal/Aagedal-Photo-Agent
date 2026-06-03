import Foundation

nonisolated enum UserDefaultsKeys {
    // MARK: - External Editor
    static let defaultExternalEditor = "defaultExternalEditor"
    static let defaultEditDestination = "defaultEditDestination"

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

    // MARK: - Favorites, Recent & FTP
    static let favoriteFolders = "favoriteFolders"
    static let recentFolders = "recentFolders"
    static let ftpConnections = "ftpConnections"
    static let lastUsedFTPConnectionID = "lastUsedFTPConnectionID"
    static let ftpUploadHistory = "ftpUploadHistory"
    static let ftpCheckIPTCBeforeUpload = "ftpCheckIPTCBeforeUpload"
    static let ftpCheckedIPTCFields = "ftpCheckedIPTCFields"

    // MARK: - Browser
    static let rawRenderAsHDR = "rawRenderAsHDR"
    static let showAllFiles = "showAllFiles"
    static let thumbnailSortOrder = "thumbnailSortOrder"
    static let thumbnailSortReversed = "thumbnailSortReversed"
    static let thumbnailScale = "thumbnailScale"
    static let previewMode = "previewMode"
    static let showOriginalThumbnails = "showOriginalThumbnails"
    static let lastScopeMode = "lastScopeMode"
    static let metadataPanelWidth = "metadataPanelWidth"
    /// True → full-screen viewer uses nearest-neighbor (pixel) magnification;
    /// false (default) → linear/bilinear smoothing.
    static let imageScalingNearestNeighbor = "imageScalingNearestNeighbor"

    // MARK: - Clean Feed (secondary-display output)
    /// CGDirectDisplayID of the screen the clean-feed window should occupy.
    /// Stored as an Int; 0 / absent means "first available external display".
    static let cleanFeedDisplayID = "cleanFeedDisplayID"

    // MARK: - Multi-Select Behavior
    static let multiSelectKeywordsMode = "multiSelectKeywordsMode"
    static let multiSelectPersonShownMode = "multiSelectPersonShownMode"

    // MARK: - Format & Compression
    static let exportFormatSDR = "exportFormatSDR"
    static let exportFormatHDR = "exportFormatHDR"
    static let exportQualitySDR = "exportQualitySDR"
    static let exportQualityHDR = "exportQualityHDR"
    static let exportTIFFCompression = "exportTIFFCompression"
    static let exportColorGamutSDR = "exportColorGamutSDR"
    static let exportColorGamutHDR = "exportColorGamutHDR"

    // MARK: - Export Location
    static let exportLocationMode = "exportLocationMode"
    static let exportCustomSubfolderName = "exportCustomSubfolderName"

    // MARK: - C2PA Signing
    static let c2paCertificatePath = "c2paCertificatePath"
    static let c2paCertificateSubject = "c2paCertificateSubject"
    static let c2paCertificateExpiry = "c2paCertificateExpiry"
    static let c2paDefaultAuthor = "c2paDefaultAuthor"

    // MARK: - Templates
    static let templatesFolderBookmark = "templatesFolderBookmark"

    // MARK: - Variable Processing
    static let addJobIdToKeywords = "addJobIdToKeywords"
    static let creatorInitials = "creatorInitials"

    // MARK: - Import Verification & Backup
    static let importVerificationMode = "importVerificationMode"
    static let importBackupBookmark = "importBackupBookmark"
    static let importBackupVerifyAfterWrite = "importBackupVerifyAfterWrite"
    static let editedFolderBackupBookmark = "editedFolderBackupBookmark"
    static let importGroupByYear = "importGroupByYear"

    // MARK: - Quick List Bookmarks
    static let keywordsListBookmark = "keywordsListBookmark"
    static let personShownListBookmark = "personShownListBookmark"
    static let copyrightListBookmark = "copyrightListBookmark"
    static let creatorListBookmark = "creatorListBookmark"
    static let creditListBookmark = "creditListBookmark"
    static let cityListBookmark = "cityListBookmark"
    static let countryListBookmark = "countryListBookmark"
    static let eventListBookmark = "eventListBookmark"

    // MARK: - Approved Lists
    // Per-field keys are also derived by ApprovedListField. The constants below
    // exist for grep-ability against the codebase. v2 keys (remoteURL,
    // refreshInterval, lastRefreshed) are declared via ApprovedListField only.
    static let approvedKeywordsEnabled  = "approvedList.keywords.enabled"
    static let approvedKeywordsBookmark = "approvedList.keywords.bookmark"
    static let approvedKeywordsMode     = "approvedList.keywords.mode"
    static let approvedKeywordsAllowStructuredBypass = "approvedList.keywords.allowStructuredBypass"

    // MARK: - Structured Keywords (PhotoMechanic-style tree)
    static let structuredKeywordsBookmark = "structuredKeywords.bookmark"

    // MARK: - Keyword Lists Sync & Migration
    /// True when the user has opted in to syncing keyword lists via iCloud.
    static let keywordListsICloudEnabled = "keywordLists.iCloudEnabled"
    /// One-shot marker: bumped after the first launch that migrated the legacy
    /// bookmark-based quick/approved/structured files into the managed store.
    static let keywordListsMigratedVersion = "keywordLists.migratedVersion"

    // MARK: - iCloud Sync (per-category opt-in; local-only, never synced)
    /// True when app preferences are mirrored via NSUbiquitousKeyValueStore.
    static let preferencesICloudEnabled = "preferences.iCloudEnabled"
    /// True when metadata templates live in the iCloud ubiquity container.
    static let templatesICloudEnabled = "templates.iCloudEnabled"
    /// True when the Known People database lives in the iCloud ubiquity container.
    static let knownPeopleICloudEnabled = "knownPeople.iCloudEnabled"
}
