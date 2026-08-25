# Known People privacy lifecycle validation — 2026-08-25

**Scope:** app-improvement audit plan 2.2 implementation work only. This validation does not perform
or claim the pending legal/privacy review.

## Implemented lifecycle UX

- The first visit to **Settings › Known People** presents a plain-language, versioned disclosure before
  the user continues. It distinguishes on-device processing, the folder-local `.face_data` store, the
  managed Known People database, retention, export/deletion scope, and optional iCloud transfer.
- The disclosure acknowledgement and the iCloud-transfer confirmation are separate, local-only,
  versioned preferences. A disclosure acknowledgement never counts as cloud consent.
- Enabling Known People sync for the first time requires an explicit confirmation. The same checkpoint
  intercepts both the individual category toggle and **Sync everything**. A coordinator-level guard also
  rejects an unconfirmed first enable from any future caller that bypasses Settings.
- Confirmation is persisted only after the Known People database is successfully moved to iCloud Drive.
  Cancelling, unavailable iCloud Drive, or a failed copy does not record confirmation.
- **Settings › Known People › Data Management** is the single summary for people/sample counts, current
  stored size, current Known People destination, folder-scan destination, export scope, and deletion paths.
  It also explains that disabling sync copies data local but does not itself delete the existing iCloud files.

## Data-boundary verification

The copy follows the implemented persistence model and avoids a broader legal conclusion:

- Known People stores names, face-only feature vectors, and reference thumbnails in Application Support,
  or in the app's iCloud Drive container when that category is enabled.
- Each scanned photo folder's hidden `.face_data` directory stores scan records, thumbnails, face feature
  vectors, and optional clothing/torso features used for within-folder grouping.
- Clothing features are not stored in `KnownPerson` / `PersonEmbedding`, are not used for Known People
  matching, and are not transferred by the Known People iCloud category.
- Known People ZIP export and **Clear Database** operate on the Known People database only. Folder scan
  data is removed through **Delete Face Data** in the Faces view or the configured cleanup policy.

## Automated validation

The focused suite covers independent/versioned acknowledgement state, every confirmation decision branch,
nested storage byte totals, counts, and local-versus-iCloud destination projection.

```text
xcodebuild build-for-testing -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/aagedal-knownpeople-privacy-derived \
  -only-testing:'Aagedal Photo Agent Tests/ICloudSyncCoordinatorTests'

** TEST BUILD SUCCEEDED **
```

```text
xcodebuild test-without-building -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/aagedal-knownpeople-privacy-derived \
  -only-testing:'Aagedal Photo Agent Tests/ICloudSyncCoordinatorTests'

Suite "iCloud sync coordinator" passed
4 tests in 1 suite passed
** TEST EXECUTE SUCCEEDED **
```

The first build attempt used the shared DerivedData directory and encountered Xcode's build-database lock
while other audit agents were compiling. The isolated DerivedData run above is the authoritative result.

## Remaining gate

The focused privacy/legal review and any copy changes it requests remain open. These implementation changes
do not claim compliance or approval.
