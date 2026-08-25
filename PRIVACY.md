# Aagedal Photo Agent privacy

**Status:** 3.0 release-candidate draft; external legal/privacy review pending  
**Last reviewed:** 2026-08-25

Aagedal Photo Agent is a native macOS application. Photo browsing, metadata editing, Develop rendering,
analysis, face detection, face matching when its model is packaged, and solar-position calculations run on
the Mac. The app does not include developer analytics, advertising, or cross-app tracking, and its Apple
privacy manifest declares no data collected by the developer. Features that you choose to connect to a
network service are listed below.

## Data stored on the Mac

- Photo Agent sidecars and XMP sidecars store edits and metadata near the photographs where supported.
- Analysis cases, working-folder map state, and named Develop versions prefer hidden app-private JSON in
  the photo folder. Read-only folders use indexed Application Support fallback storage; that fallback
  stays on the current Mac and does not automatically travel with the folder.
- Folder face scans use a hidden `.face_data` folder containing face positions, feature vectors, groups,
  and thumbnails. The separate Known People database stores names, face-only feature vectors, and
  reference thumbnails in the app's managed storage.
- Delivery receipts and exact retained delivery workflows use local Application Support. Activity
  summaries omit credentials and editorial metadata values; receipt details additionally omit filenames,
  source paths, and content hashes. Exact retained workflow state necessarily contains source identities,
  resolved metadata, destination details, and any retained staged derivatives needed to validate, resume,
  or clean up the delivery.
- FTP/FTPS/SFTP passwords and C2PA signing credentials use macOS Keychain. Temporary delivery credential
  files are private mode-0600 files and are removed when the operation ends.
- Exported images, reports, Known People ZIPs, and other user-selected exports are copies at locations you
  choose and are your responsibility to retain or remove. A `.pint` project specifically includes the
  working-folder images, matching XMP sidecars, and folder-local Photo Agent case/metadata/version
  documents; its integrity manifest does not encrypt that content.

## Optional iCloud sync

iCloud Sync is opt-in. Its master switch or individual category switches can sync metadata templates,
keyword/quick lists, Known People, Teams/rosters, watermarks, and portable settings through the app's
iCloud Drive container. Passwords, signing keys, FTP server settings, local paths, certificates, folder
scan data, clothing features, analysis cases, named versions, receipts, and retained delivery workflows
are not included by that setting.

Enabling Known People sync requires a separate confirmation. Turning sync off copies the active Known
People data back to local storage but does not by itself delete the existing iCloud copy; clear the active
database while sync is enabled if you intend to remove that synced database, and review other devices or
exports separately.

## Network features

Photo Agent accesses a network only for a feature that needs it, including:

- Sparkle update checks against the published Photo Agent appcast;
- Apple MapKit place search, reverse geocoding, map imagery, and Look Around links;
- OpenStreetMap tiles when that map style is selected;
- C2PA trust-list refreshes;
- FTP, FTPS, or SFTP connection tests and uploads to a server/profile you configure; and
- links that you explicitly open, including the project website, component sites, Adobe DNG Converter,
  Apple/Google maps, Meta Content Seal, and Google Gemini.

Network providers receive ordinary connection information such as IP address and the request necessary to
serve the feature. Map tile requests reveal the requested tile area, and place/geocoding requests reveal
the query or coordinate. Delivery sends the staged derivative to the configured destination. Their own
terms and privacy policies apply.

The Meta Content Seal and Google SynthID commands only open external webpages. Photo Agent does not send
the current image to those services. If you upload an image after leaving the app, that is a separate
action between you and the provider.

## Logs and reports

Normal app logs are designed not to publish source paths, metadata values, coordinates, case notes,
credentials, or content hashes. macOS and third-party components can still produce diagnostic information;
review logs before sharing them. A report or project that you deliberately export can contain selected
metadata, annotations, coordinates, map evidence, hashes, and notes. Review its options and resulting file
before distribution.

## Retention and deletion

- Delete per-folder face scan data from the Faces view or use its configured auto-delete policy.
- Remove individual Known People entries or use Settings → Known People → Clear Database. This does not
  delete per-folder scan data or ZIP exports.
- Delete delivery receipts and explicitly clean retained workflows/staging from Activity. The receipt
  repository otherwise applies its 250-receipt/365-day retention boundary when retention runs; retained
  workflows require explicit cleanup.
- Delete folder-local hidden analysis/version data with the photo folder only if you no longer need it.
  Application Support fallback data, exported reports/projects, iCloud copies, backups, and files on
  delivery servers are separate copies and may require separate deletion.

## Contact and review status

Security issues should follow [SECURITY.md](SECURITY.md). This draft describes the implemented 3.0 data
flows found in the repository; it is not a completed external legal/privacy review. The final published
privacy text must be reviewed alongside a signed release-candidate build and runtime network/log evidence.
