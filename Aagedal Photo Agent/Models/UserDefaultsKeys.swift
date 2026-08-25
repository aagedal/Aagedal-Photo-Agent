import Foundation

nonisolated enum UserDefaultsKeys {
    // MARK: - External Editor
    static let defaultExternalEditor = "defaultExternalEditor"
    static let defaultEditDestination = "defaultEditDestination"

    // MARK: - Metadata Write Mode
    /// Top-level preset (simple / professional / custom). Drives mode resolution; the
    /// per-category keys below apply only under `.custom`.
    static let metadataWritePreset = "metadataWritePreset"
    static let metadataWriteMode = "metadataWriteMode"
    static let metadataWriteModeNonC2PA = "metadataWriteModeNonC2PA"
    static let metadataWriteModeC2PA = "metadataWriteModeC2PA"
    /// Custom-preset RAW write mode (RAW files, any C2PA status).
    static let metadataWriteModeRaw = "metadataWriteModeRaw"

    // MARK: - Face Recognition
    static let faceCleanupPolicy = "faceCleanupPolicy"
    static let faceMinConfidence = "faceMinConfidence"
    static let faceMinFaceSize = "faceMinFaceSize"
    /// Minimum face capture-quality (0...1) to keep a detected face — drops too-blurry faces.
    static let faceMinQuality = "faceMinQuality"
    /// When true, face detection also runs Vision over overlapping image tiles and merges the
    /// results, recovering faces the single whole-image pass misses (small/off-angle faces in
    /// group shots). This is the Thorough scan mode; Fast mode is the default.
    static let faceTiledDetection = "faceTiledDetection"

    // Retired in the v2.0 face-recognition rewrite (single CoreML embedder + one clustering
    // algorithm). Constants kept for one release so old stored prefs decode cleanly; no longer
    // read, written, or synced.
    static let faceClothingClusteringThreshold = "faceClothingClusteringThreshold"
    static let faceRecognitionMode = "faceRecognitionMode"
    static let faceFaceWeight = "faceFaceWeight"
    static let faceClusteringAlgorithm = "faceClusteringAlgorithm"
    static let faceQualityGateThreshold = "faceQualityGateThreshold"
    static let faceUseQualityWeightedEdges = "faceUseQualityWeightedEdges"
    static let faceClothingSecondPassAttachToExisting = "faceClothingSecondPassAttachToExisting"

    // MARK: - Known People
    /// Embedding-space version the Known People database was built with. A mismatch with
    /// `FaceRecognitionDefaults.embeddingVersion` triggers a one-time start-fresh migration.
    static let knownPeopleEmbeddingVersion = "knownPeople.embeddingVersion"
    static let knownPeopleMinConfidence = "knownPeopleMinConfidence"
    /// Retired: matching is now always automatic. Kept for one release for clean decoding.
    static let knownPeopleMode = "knownPeopleMode"

    // MARK: - Sports Tagging (jersey-number detection)
    /// True when the scan also detects jersey numbers + team colours.
    static let sportsModeEnabled = "sports.modeEnabled"
    /// Minimum Vision OCR confidence (0...1) to accept a recognised number.
    static let sportsOCRConfidenceThreshold = "sports.ocrConfidenceThreshold"
    /// Minimum number-box height as a fraction of image height, to skip tiny noise.
    static let sportsNumberMinHeightFraction = "sports.numberMinHeightFraction"
    /// Max CIELAB ΔE for a sampled jersey colour to count as matching a kit colour.
    static let sportsColorDistanceThreshold = "sports.colorDistanceThreshold"

    // MARK: - Favorites, Recent & FTP
    static let favoriteFolders = "favoriteFolders"
    static let recentFolders = "recentFolders"
    static let ftpConnections = "ftpConnections"
    static let lastUsedFTPConnectionID = "lastUsedFTPConnectionID"
    static let ftpUploadHistory = "ftpUploadHistory"
    static let activityHistory = "activityHistory"
    /// When set (default true), RAW files are always rendered to JPEG before upload, even
    /// when the "skip automatic rendering of edited files" toggle is on in the upload dialog.
    static let ftpAlwaysRenderRAW = "ftpAlwaysRenderRAW"

    // MARK: - Required Metadata
    /// Legacy: JSON-encoded `[MetadataFieldID]` the user considered mandatory. Superseded by
    /// `metadataRequirementLevels`; still read once to migrate those fields to `.require`.
    static let requiredMetadataFields = "requiredMetadataFields"
    /// JSON-encoded `[FieldKey.rawValue: MetadataRequirementLevel.rawValue]`. The global 3-state
    /// (Optional / Warn / Require) config driving the browser's Required Metadata filter and the FTP
    /// upload checks. Fields absent from the map are `.optional`.
    static let metadataRequirementLevels = "metadataRequirementLevels"
    static let metadataMinimumLengths = "metadataMinimumLengths"
    /// Raw values of IPTC fields hidden from the editable metadata panel.
    static let hiddenIPTCMetadataFields = "hiddenIPTCMetadataFields"
    /// Ordered raw values of fields in the editable metadata panel and Caption navigator.
    static let iptcMetadataFieldOrder = "iptcMetadataFieldOrder"

    // MARK: - Browser
    static let rawRenderAsHDR = "rawRenderAsHDR"
    static let rawDecodeProfile = "rawDecodeProfile"
    static let rawDecoderVersionPreference = "rawDecoderVersionPreference"
    static let showAllFiles = "showAllFiles"
    static let thumbnailSortOrder = "thumbnailSortOrder"
    static let thumbnailSortReversed = "thumbnailSortReversed"
    static let thumbnailScale = "thumbnailScale"
    static let previewMode = "previewMode"
    static let showOriginalThumbnails = "showOriginalThumbnails"
    static let lastScopeMode = "lastScopeMode"
    static let scopesExpanded = "scopesExpanded"
    static let metadataPanelWidth = "metadataPanelWidth"
    /// Split-view layout of the thumbnail area (BrowserPaneLayout raw value).
    static let browserPaneLayout = "browserPaneLayout"
    /// First-pane fraction of the thumbnail split (0.15…0.85).
    static let browserPaneSplitFraction = "browserPaneSplitFraction"
    /// True → full-screen viewer uses nearest-neighbor (pixel) magnification;
    /// false (default) → linear/bilinear smoothing.
    static let imageScalingNearestNeighbor = "imageScalingNearestNeighbor"
    /// Raw values of optional Develop sliders hidden from the adjustment panel.
    static let hiddenDevelopSliders = "hiddenDevelopSliders"
    /// Ordered raw values of the major Global Develop inspector sections.
    static let developSectionOrder = "developSectionOrder"

    // MARK: - Clean Feed (secondary-display output)
    /// CGDirectDisplayID of the screen the clean-feed window should occupy.
    /// Stored as an Int; 0 / absent means "first available external display".
    static let cleanFeedDisplayID = "cleanFeedDisplayID"
    /// ComparisonLayout raw value used by the passive secondary-display output.
    static let cleanFeedComparisonLayout = "cleanFeedComparisonLayout"

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
    static let exportResolutionLimit = "exportResolutionLimit"

    // MARK: - Export Location
    static let exportLocationMode = "exportLocationMode"
    static let exportCustomSubfolderName = "exportCustomSubfolderName"
    static let rawArchiveLocationMode = "rawArchiveLocationMode"
    static let rawArchiveSourceRootBookmark = "rawArchiveSourceRootBookmark"
    static let rawArchiveRootBookmark = "rawArchiveRootBookmark"

    // MARK: - C2PA Signing
    static let c2paCertificatePath = "c2paCertificatePath"
    static let c2paCertificateSubject = "c2paCertificateSubject"
    static let c2paCertificateExpiry = "c2paCertificateExpiry"
    static let c2paDefaultAuthor = "c2paDefaultAuthor"
    static let c2paUseTestCertificate = "c2paUseTestCertificate"
    static let c2paTrustListLastRefreshed = "c2paTrustListLastRefreshed"
    static let c2paTrustListLastError = "c2paTrustListLastError"

    // MARK: - Templates
    static let templatesFolderBookmark = "templatesFolderBookmark"

    // MARK: - Variable Processing
    static let addJobIdToKeywords = "addJobIdToKeywords"
    static let creatorInitials = "creatorInitials"

    // MARK: - Caption Code Replacement
    /// Versioned non-secret `CodeReplacementConfiguration` JSON.
    static let codeReplacementConfiguration = "caption.codeReplacement.configuration"
    /// Opaque security-scoped bookmark bytes, deliberately stored outside the configuration.
    static let codeReplacementSourceBookmark = "caption.codeReplacement.sourceBookmark"

    // MARK: - Reverse Geocoding
    /// Output language for GPS→City/Country lookup. Token decoded by
    /// `ReverseGeocodeLanguage` ("system" or a BCP-47 code). Absent → `.system`.
    static let reverseGeocodeLanguage = "reverseGeocodeLanguage"
    /// When true, names resolve from the offline GeoNames database (no network; city
    /// names stay English). When false (default), Apple's online geocoder is used and
    /// localizes both city and country. Read directly from UserDefaults by `GeocodingService`.
    static let reverseGeocodeOfflineEnabled = "reverseGeocodeOfflineEnabled"

    // MARK: - Import Verification & Backup
    static let importVerificationMode = "importVerificationMode"
    static let importDestinationBookmark = "importDestinationBookmark"
    static let importBackupBookmark = "importBackupBookmark"
    static let importBackupVerifyAfterWrite = "importBackupVerifyAfterWrite"
    static let editedFolderBackupBookmark = "editedFolderBackupBookmark"
    static let importFileTypeFilter = "importFileTypeFilter"
    static let importConflictPolicy = "importConflictPolicy"
    static let importCreateSubFolders = "importCreateSubFolders"
    static let importSortByDate = "importSortByDate"
    static let importGroupByYear = "importGroupByYear"
    static let importDateFolderGrouping = "importDateFolderGrouping"
    static let importSkipPreviouslyImported = "importSkipPreviouslyImported"
    static let importSplitShootsIntoSubfolders = "importSplitShootsIntoSubfolders"

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
    static let structuredPersonShownCategoriesAsKeywords = "structuredPersonShown.categoriesAsKeywords"

    // MARK: - Keyword Lists Sync & Migration
    /// True when the user has opted in to syncing keyword lists via iCloud.
    static let keywordListsICloudEnabled = "keywordLists.iCloudEnabled"
    /// One-shot marker: bumped after the first launch that migrated the legacy
    /// bookmark-based quick/approved/structured files into the managed store.
    static let keywordListsMigratedVersion = "keywordLists.migratedVersion"
    /// Stable per-list migration identifiers. Successful lists remain complete
    /// while failed sources retry on a later launch.
    static let keywordListsMigrationCompletedKeys = "keywordLists.migrationCompletedKeys"

    // MARK: - iCloud Sync (per-category opt-in; local-only, never synced)
    /// True when app preferences are mirrored via NSUbiquitousKeyValueStore.
    static let preferencesICloudEnabled = "preferences.iCloudEnabled"
    /// True when metadata templates live in the iCloud ubiquity container.
    static let templatesICloudEnabled = "templates.iCloudEnabled"
    /// True when the Known People database lives in the iCloud ubiquity container.
    static let knownPeopleICloudEnabled = "knownPeople.iCloudEnabled"
    /// True when the Teams library lives in the iCloud ubiquity container.
    static let teamsICloudEnabled = "teams.iCloudEnabled"
    /// True when the Watermark library lives in the iCloud ubiquity container.
    static let watermarksICloudEnabled = "watermarks.iCloudEnabled"
}
