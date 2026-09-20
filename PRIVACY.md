# Aagedal Photo Agent privacy

**Status:** 3.0 release-candidate draft; external legal/privacy review pending  
**Last reviewed:** 2026-09-20 (implementation update; external review remains pending)

Aagedal Photo Agent is a native macOS application. Photo browsing, metadata editing, Develop rendering,
analysis, face detection, face matching when its model is packaged, and solar-position calculations run on
the Mac. The app does not include developer analytics, advertising, or cross-app tracking, and its Apple
privacy manifest declares no data collected by the developer. Features that you choose to connect to a
network service are listed below.

## Data stored on the Mac

- Photo Agent sidecars and XMP sidecars store edits and metadata near the photographs where supported.
- Voice-memo review records store generated and edited text, approval state, audio identity and
  provider information in the photo's app sidecar. The selectable custom FFmpeg Whisper provider additionally
  retains model/build hashes and byte counts, requested language, translation/GPU settings and
  segment text and normalized timing. Provider choice, language/translation/GPU request preferences,
  and security-scoped executable/model bookmarks
  are retained in local preferences. Clear Custom Files removes the saved bookmarks. Execution consent
  and admitted identities last only while the Caption panel remains open; reopening requires fresh
  consent and identity validation. No model downloads occur. Custom executables run only after explicit Transcribe and are
  unverified software with the user's local process permissions. Review approval does not itself
  write transcript text into photo metadata.
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

## Optional local automation

The bundled MCP server is disabled by default and uses only STDIO with the local client process; it does
not open a listening network port. Enabling it does not itself grant photo access. You select each
authorized folder separately in Settings, can remove a grant at any time, and can disable the server
without deleting the folder list. The helper reloads enablement and grants for every tool call and refuses
changed roots, paths outside those roots, links/aliases, special files, and hidden Photo Agent stores.

Team creation has a separate, default-off **Allow team creation** setting. When enabled together
with local automation, `create_team` can add team names, kit colours and numbered player rosters
to the local Teams library without photo-folder grants. With Teams iCloud sync on, the helper stores
proposals and review decisions locally under `Automation/TeamImports` in Photo Agent’s Application
Support folder. They remain there for retry tracking. Only clicking Add Team in the app’s Teams →
Review Imports screen writes the reviewed roster to the selected library, which may sync via iCloud.
Rejecting does not change the Teams library. The tool cannot replace existing teams or link
players to face records. Any online roster research happens
in the connected client's web tools; the helper does not fetch team data or transmit rosters online.

An authorized local AI client can receive filenames, paths, and metadata returned by tools and may apply
its own retention or network policy to that content. Review the client's privacy settings before connecting
it. Current tools provide read-only capability/authorization inspection, bounded effective photo metadata,
and template header discovery from explicitly authorized default local or custom folders. Template names and content
revision hashes can also reach the connected client; template field values are not returned by discovery.
Read-only IPTC patch previews also return existing and proposed descriptive values. The bundled
helper stores up to 64 plans (an 8 MiB serialized-result budget) in a private local archive under
`~/Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans`. The archive includes
photo paths, revision evidence, existing/proposed values and the captured authorization configuration.
Plans survive helper restart but expire after five minutes; every retrieval rechecks current access
and photo/sidecar revisions. Expired records are physically removed on the next successful preparation,
not by a background timer. Interrupted writes can leave private temporary files. Stop connected helpers
and remove this PatchPlans directory to erase the local previews. Previews do not alter photos or appear
in Activity. Photo-metadata mutation tools will remain unavailable until they use Photo
Agent's existing confirmation, preservation, verification, recovery, and privacy-safe activity boundaries.

Operation status and cancellation tools require local automation to be enabled. They return only
opaque operation IDs, fixed kind/state/outcome values and timestamps, not paths, metadata or owner IDs.
The private registry at `~/Library/Application Support/Aagedal Photo Agent/Automation/Operations`
retains up to 256 records within a 1 MiB archive limit. There is no automatic eviction. Cancellation
records a request and does not erase history or prove work stopped. Production executors are not yet
connected. Stop the app and connected helpers before removing this directory to erase local history.

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
- Remove local automation folder grants or turn off the MCP server in Settings → Automation. Also remove
  the server from each connected client if you no longer want that client to launch the helper.

## Contact and review status

Security issues should follow [SECURITY.md](SECURITY.md). This draft describes the implemented 3.0 data
flows found in the repository; it is not a completed external legal/privacy review. The final published
privacy text must be reviewed alongside a signed release-candidate build and runtime network/log evidence.
