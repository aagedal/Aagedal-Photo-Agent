# Aagedal Photo Agent

A native macOS desktop application for photo metadata management and face recognition — an open-source alternative to Adobe Bridge and Photo Mechanic. Built with SwiftUI and Metal for Apple Silicon.

**License:** GPL-3.0

[**3.0.0 Beta 2**](https://github.com/aagedal/Aagedal-Photo-Agent/releases/tag/3.0.0-beta.2) is available as a public testing release. See the [3.0 feature guide](docs/feature-help-3.0.md),
[known limitations](docs/limitations-3.0.md), and [privacy draft](PRIVACY.md) for the release-candidate
behavior and boundaries.



## Requirements

- macOS 26.0 or later
- Apple Silicon (arm64)

## Installation

```bash
brew install aagedal/casks/aagedal-photo-agent
```

Or build from source:

```bash
xcodebuild -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent" build
```

## Features

### Image Browsing & Organization

- Browse folders with fast 240x240 thumbnail previews
- Full-screen loupe view with keyboard navigation, prefetching, and edited-preview rendering
- Star ratings (0-5) and color labels with keyboard shortcuts
- Photo Mechanic-style cull shortcuts in full-screen (bare digits for rating/label, X to trash)
- Sort by name, date modified, date added, file size, or star rating
- Filter by star rating, color label, person shown, or missing required metadata fields
- Full-text search across filenames and IPTC metadata fields
- Folder favorites, recent folders, and drag-and-drop folder organization in the sidebar
- Browser visibility modes: Photos, All media files (photos and videos), or All files
- Extract one or several stills from a video from a video’s right-click menu: play, scrub (Option-drag for precision), step frames, press M to add markers without pausing playback, and save full-resolution JPEG, TIFF, or lossless 16-bit JPEG XL files to a chosen folder. This initial version supports videos playable by macOS, converts HDR to SDR for JPEG/TIFF while JPEG XL preserves source precision and HDR, and records the source filename and frame timecode in each still (embedded source timecode when present, otherwise relative timecode starting at `00:00:00:00`). Videos currently use system icons in the grid.

### Ingest & Import

- Import from memory cards or folders with a non-blocking progress bar
- Copy verification (SHA-256) so files are checksummed before the source is released
- Dual-destination backup — primary and backup copies written and verified in one pass
- Capture-date sorting into year-grouped date folders, with an Import Title applied automatically
- Unified import/upload activity history with sticky completion banners

### Supported Formats

- **Standard:** JPEG, PNG, TIFF, HEIC, HEIF, BMP, GIF, WebP, AVIF, JPEG XL
- **RAW:** CR2, CR3, NEF, NRW, ARW, RAF, DNG, RW2, ORF, PEF, SRW
- **RAW archiving:** Create unedited 16-bit JPEG XL or TIFF decodes with Linear RAW or Camera RAW processing, or lossless/lossy DNG files when the free [Adobe DNG Converter](https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html) is installed. Develop edits are never baked into archive pixels; the matching XMP sidecar is copied unchanged. Archives can go into each work folder’s `Archive` sub-folder, a separate root that mirrors the main ingest structure, or a folder chosen for each batch. C2PA-protected RAW archives are signed with the source credential as a parent ingredient when a signing identity is configured; otherwise the app warns before creating unsigned files.

### Camera RAW Editing

Non-destructive RAW development with real-time Metal GPU preview:

- Exposure, contrast, highlights, shadows, whites, blacks
- White balance (temperature and tint), with a click/drag-to-neutral eyedropper that samples the pre-WB source like Adobe Camera Raw
- Vibrance and saturation
- Per-color HSL — Hue / Saturation / Density adjustments matched to the vectorscope channels
- Film emulation controls for grain, halation, bloom, vignette, and edge blur
- Customizable Develop panel with per-slider visibility preferences
- Tone curves (Adobe Camera Raw compatible)
- Crop, straighten, and rotation
- Reorderable develop layer chain — a horizontal strip of cards (Global node plus local masks) that you can drag to reorder
- Local adjustments with elliptical/radial masks — each mask has independent tonal and color controls
- HDR/EDR rendering with extended dynamic range
- Before/after comparison toggle
- Undo/redo support
- Copy/paste develop settings between images (⌥V pastes including crop)
- Edits stored in XMP sidecar files for cross-tool compatibility — develop settings and masks are written in Adobe Camera Raw's `crs` encoding so ACR / Bridge detect and render them

### Metadata Management

- Edit the app's descriptive IPTC/XMP field set, including headline, caption, keywords, people and organisations shown, ordered creators, creator contact, credit and rights, Subject/Scene Codes, Media Topics, structured Genre and PLUS Image Supplier values, precision-aware Date Created, locations, instructions, source, and GPS coordinates
- Local description assistance: correct grammar or improve wording in Bokmål, Nynorsk, or English, then review/edit the suggestion before applying it. The wand beside Description opens the assistant. Settings → Description Assistant recommends Gemma 4 12B for multilingual writing (7.12 GB download). Alternatives are Gemma 4 E4B (4.98 GB), Qwen3.5 9B (5.68 GB), Ministral 3 14B Instruct (8.24 GB), and Gemma 4 26B A4B as a high-quality option (17.04 GB). All downloads use pinned, SHA-256-verified Q4_K_M GGUF weights and can be selected again without another transfer. Recommended total Mac RAM is 16 GB for E4B/Qwen, 24 GB for 12B/Ministral, and 32 GB for 26B A4B; Settings warns when this Mac has less. These are recommendations rather than measured minimums. The backend uses each model’s embedded chat template with thinking disabled. llama.cpp and Metal libraries ship inside the app, so only the model needs downloading. Existing GGUF files and converted MLX folders can also be selected. [Bundled runtime details](scripts/llama/README.md). On macOS 27 or later, **Apple Foundation Models** is the default when no provider choice is saved and is available as an on-device alternative without a Photo Agent model download. It requires an eligible Mac, Apple Intelligence enabled, and Apple’s model ready. Supported caption languages are checked on this Mac; unsupported languages remain available through local models. Individual and batch suggestions still require explicit review and application. **Write from image** uses Apple Foundation Models on macOS 27 or later or a vision-capable converted MLX folder and drafts captions from an upright image capped at two megapixels, editorial metadata and optional reporting notes. The bundled GGUF runner supports text editing only. The assistant also supports **microphone dictation** through the configured Apple Speech or Whisper transcription provider: record, stop, review, then use the text as a description or reporting notes. Temporary recordings are removed after transcription or cancellation.
- Optionally append named people in left-to-right order from an existing face scan. Names and normalized face positions enter the request; the app constructs the name list deterministically. Unnamed, excluded, and out-of-date face records are omitted. Ordering refers to the upright original image, rather than a developed crop. This iteration processes one photo; immutable per-photo requests and shared model admission provide the basis for a later batch queue.
- Non-destructive editing via JSON sidecar files with explicit save
- Copy and paste metadata between images
- Structured keywords — manage multiple named Photo Mechanic-style hierarchical lists, with one or several active at a time. Includes offline IPTC Media Topics in all 13 published languages and variants; follows the system language with a US English fallback and an independent language override. Existing keywords remain available as My Keywords. Custom lists, selection, and language settings are included in keyword archives, backups, and iCloud sync. IPTC Media Topics checks for updates weekly while the app runs, with an automatic-update toggle and a Check for Updates button; validated downloads are cached for offline use.
- Batch metadata application via templates with variable interpolation
- Template variables: `{date}`, `{date:FORMAT}`, `{dateCreated}`, `{dateCreated:YYYYMMDD}`, `{dateCreated:DDMMYYYY}`, `{dateCreated:YYYY-MM-DD}`, `{dateCaptured}`, `{dateCaptured:YYYYMMDD}`, `{dateCaptured:DDMMYYYY}`, `{dateCaptured:YYYY-MM-DD}`, `{filename}`, `{seq}`, `{persons}`, `{keywords}`, `{initials}`, `{field:FIELDNAME}` — variables also resolve inside keywords and Person Shown
- Template hotkeys (Ctrl+1-9) for rapid workflows
- Required-metadata definitions that drive the browser's missing-field filter and the pre-upload check
- Metadata mirrored to both IPTC and XMP for cross-tool interoperability
- Correct IPTC `CodedCharacterSet` tagging so Nordic / non-ASCII characters round-trip through other apps
- Pure-Swift in-process metadata engine (SwiftMediaMetadata 3) — no external binaries, no subprocess overhead

The generated [metadata field and delivery support table](docs/metadata-field-support.md) lists every
current descriptive field ID, writer mapping, normalized read-back rule, and carrier boundary. It is
an implementation-support statement, not a claim of completed manual round trips through Adobe
Bridge, Photo Mechanic, or every supported browsing/export format.
Headline and localized Dublin Core Title are independent. SwiftMediaMetadata 3 preserves
ordered `rdf:Alt` language alternatives and exact language tags through the supported read/write paths;
Headline writes do not create, clear, or replace `dc:title` or IIM Object Name. External Adobe Bridge,
Photo Mechanic, and remaining licensed-container round trips are still limited to the evidence named in
the support table and validation records.

### Local Automation (3.0 foundation)

- A separately built, hardened-runtime `photo-agent-mcp` helper is bundled for local STDIO MCP clients;
  it does not listen on the network.
- Automation is disabled by default. Settings → Automation manages explicit folder grants and provides a
  copyable setup for Codex CLI, Claude Code, OpenCode 1.x, and OpenCode v2.
  Authorization refreshes shared preferences on every read, so persistent clients see revocation and
  fresh grant generations; failed refreshes or saves refuse authority.
- The current foundation exposes read-only server, photo-input-format, root, path-admission and photo-revision tools with strict canonical-path,
  identity, link, special-file, and private-store refusal. The helper shares photo/folder reservations
  with retained field, variable/template, Write All, Primary Develop and Batch Rename GUI execution. The helper
  discovers stable metadata/Develop template UUIDs, names and revision hashes with `list_templates`
  from explicitly authorized default local or custom template folders (template iCloud sync must be off). Photo-revision inspection
  captures opaque source, XMP and owned app-sidecar tokens. `preview_metadata_template` previews a
  template for one photo using exact template and photo revisions, with Append/Replace
  behavior matching the editor for descriptive fields, creators, organisations, scene/subject codes,
  date, country, source type, urgency, Media Topic, Genre and Image Supplier. `preview_metadata_template_batch` extends the same preview
  to 1–8 explicit photos, retaining and revalidating every photo and returning no partial result. Both previews resolve `{filename}` from each retained photo in Headline, Description, Extended Description and Instructions. Other variables, Keywords, instant processing and unsupported
  fields are refused; it creates no draft or approval. `get_photo_metadata` returns bounded, typed
  effective editorial values with field provenance, pending/conflict state and those revision tokens.
  `prepare_iptc_patch` returns read-only, revision-bound normalized before/after values, exact inputs and compatibility warnings
  for supported descriptive fields, exact carrier hashes and preservation baselines. Keyword edits
  bind the exact local Approved Keywords list and settings, using
  the editor's Strict policy, canonical spelling and duplicate handling. iCloud keyword lists
  are not yet supported by patch previews. `get_iptc_patch_plan` revalidates the retained preview
  and keyword authority. These expiring read-only plans survive helper restart in a bounded
  private local archive but cannot be committed by MCP. `get_native_review_request_capacity` explicitly
  initializes or migrates request coordination storage and returns its durable `requestEpoch`.
  `request_iptc_patch_review` queues a durable request with that epoch, a new lowercase UUID
  `requestID`, the `planID`, and purpose `pendingDraft`
  or `xmpPublication`. In Settings → Automation → Show Client Review Requests, refresh and inspect the
  request, then explicitly approve and apply it. `get_native_review_request` reports the retained
  intent, linked operation ID and matching retained outcome; unavailable history stays explicitly
  unconfirmed. Settings shows these outcomes and lets you request cancellation during execution.
  `cancel_native_review_request` cancels before admission or requests
  cooperative cancellation of linked work. Status, cancellation and exact retries retain the original
  epoch and request ID across helper restart;
  requests grant no consent and interrupted admission is never replayed. This private archive retains
  at most 256 requests without automatic eviction. Settings can explicitly remove requests cancelled
  before admission, or separately remove linked requests whose exact retained operation confirms a
  finished outcome, and rotate the epoch. Cleanup preserves operation and recovery history. Active,
  admitted, uncertain and missing-history requests remain retained. An uncertain XMP operation is
  eligible only with an exact matching retained receipt for completed restoration or unchanged staging;
  missing, replaced or incomplete recovery evidence keeps the request retained. Removed intents
  cannot be retried; clients must never silently resubmit them under a
  new epoch. Retained requests keep their original epochs. Settings can explicitly apply an approved
  plan to a pending local draft after the photo is deselected in all editors, preserving the photo
  and XMP. Template application, face scans and physical photo mutation tools remain
  under implementation for 3.0; transcription start uses the separate native grant below.
  `get_operation_status` and `cancel_operation` expose durable coordination records and cooperative
  cancellation requests. The native pending-draft executor is connected with distinct `iptc_draft`
  outcomes. Available transcription batch status includes ordered per-photo outcomes without paths
  or transcript text. Saved transcripts are ready for metadata variables; failed or cancelled batches can
  retain a saved prefix. Caption launches the shared batch backend after explicit native consent;
  helper transcription invocation remains unfinished. A request is not completion.
  `get_photo_voice_memo` inspects one photo's saved adjacent WAV relationship under the authorized
  root and returns exact relationship/audio revision evidence. It does not expose audio or transcript
  content, decode WAVs, inspect provider readiness, or start transcription.
  `prepare_voice_transcription` retains an immutable five-minute preview for one to eight explicit
  photos and requested provider options. `get_voice_transcription_plan` rechecks every photo,
  metadata, relationship, WAV and root grant before returning it. Preparation writes private
  coordination storage; neither tool grants consent, starts inference or saves drafts.
  Separate epoch-bound transcription review requests can be queued, inspected and cancelled through
  MCP, then revalidated in Settings → Automation → Transcription Intent Review. Photo order and
  requested provider options remain exact. Settings can separately review the exact selected native
  provider, locale/model/runtime and options, then start one durably linked operation after explicit
  consent. Whole-set rooted reservations and identity checks span recognition and verified create-only
  transcript saves. Existing transcripts refuse admission; cancellation preserves saved drafts. Closing
  Settings does not stop admitted work, and linked requests never replay. Helper tools can request
  cooperative cancellation and inspect the linked operation.
  `open_voice_transcription_review` asks the running app to open one exact original request/epoch.
  A private local socket authenticates both processes against the matching signed app/helper pair.
  The app repeats whole-set validation and the native UI clears previous execution consent.
  `reviewRequired` acknowledges a presentation request only; an already linked request returns its
  exactly matched operation handle without claiming completion. No provider consent or execution
  authority is supplied by the helper. Copied, unsigned, mismatched, stale and unavailable peers refuse.
  After exact native provider review and checked consent, **Allow Helper to Start Once** enables
  `start_voice_transcription` for that request for 60 seconds while the review stays open.
  The app consumes this session-only grant once and schedules guarded admission; `executionRequested`
  confirms scheduling, never durable admission, inference or completion. Provider changes, consent
  withdrawal, dismissal and repeat review revoke the grant. Exact linked retries return the original
  operation handle without starting again. Saved drafts still require separate caption approval.
- `create_team` adds a team with a complete numbered roster to the Teams library. Enable
  **Allow team creation** in Settings → Automation as well as local automation. With Teams iCloud
  sync on, the request stays local until you open **Teams → Review Imports**, review the roster and
  choose **Add Team** or **Reject**. Approved imports use the app’s coordinated iCloud storage;
  unavailable iCloud leaves the request pending. Retry the same MCP call to check its
  `awaiting_confirmation`, `accepted`, or `rejected` status. A connected AI client can research this week's team sheets using its own web tools,
  then submit the team name, sport, kit colours and players. The helper itself does not browse.
  Supply a client-generated `teamID` UUID and reuse it with the same content on retries. Creation
  never replaces existing teams, assigns teams to a match, or links players to Known People.
  Player numbers must be unique integers from 0 through 9999. Unknown names, numbers and colours
  should be verified from a reliable source before submission.
- **Settings → Transcription** selects **Apple Speech**, **Whisper** with embedded FFmpeg,
  or advanced **Custom FFmpeg Whisper**. Download Tiny, Base, Small, multilingual Turbo or Large v3 explicitly in the app;
  installed models are checked against pinned size/SHA-256 before use. Inference stays local,
  and Caption retains compact playback, Transcribe and review controls. Language, English translation
  and GPU request settings persist and are recorded in each editable draft. Custom files still require
  explicit session execution consent. Provider discovery does not expose transcription execution to MCP.

### Face Recognition

Rebuilt for 2.0 around a bundled on-device AuraFace (ArcFace) model, with eye-aligned crops and **improved, fully editable face grouping** — review groups, merge or split people, and drag faces between groups.

- Automatic face detection using the Apple Vision framework
- Face embeddings from a bundled AuraFace (ArcFace) CoreML model — 512-dimension vectors compared by cosine distance
- Quality-gated hierarchical clustering with eye-aligned face crops
- Quality scoring: confidence, face size, and blur detection
- Known People database with per-person embeddings and sample management
  - Auto-matching with configurable confidence thresholds
  - Import/export database (ZIP format)
  - Interactive multi-face suggestions UI during metadata editing
  - Dedicated Unmatched faces group with drag-to-group / ungroup actions
- Face data written to image metadata on save

### Image Scopes & Visualization

- Waveform scope (Shift+1)
- Parade / RGB scope (Shift+2)
- Vectorscope (Shift+3)
- CIE 1931 chromaticity diagram (Shift+4) with target gamut overlay and HDR-aware display gamut indicator
- Gamut clipping soft proof for both edit and browse views
- All scopes rendered via Metal GPU compute shaders

### Image Analysis, OSINT, and Reports

- Source-revision-bound analysis cases that keep evidence separate from source metadata
- Pixel Analysis views for channels, luminance, alpha, fixed-parameter edges, and a labeled
  compression/residual visualization, with linked hover sampling and source-pixel inspection
- Source facts, namespace-preserving metadata/provenance inspection, C2PA states, and narrow
  consistency findings with alternatives and limitations instead of an authenticity verdict
- Photo annotations, source-pixel measurement, and optional user calibration
- OSINT timeline and map evidence with photo/map annotations, linked objects, field-of-view geometry,
  and an offline solar-position direction overlay
- Immutable PDF reports with selected findings, evidence figures, methodology, limitations, source
  identity, and map attribution or a schematic fallback
- Portable `.pint` Image Analysis Project export/import containing the working-folder images, matching
  XMP sidecars, and folder-local Photo Agent case/metadata/version documents, with a manifest that checks
  every archived file before import

The app does not include an AI-origin detector, clone detector, automatic AI-artifact highlighting, or
sun/shadow consistency verdict in 3.0. The Meta Content Seal and Google SynthID entries are
privacy-labeled links to external services; Photo Agent does not upload the image to them.

### Comparison and Named Develop Versions

- Compare exactly two images in side-by-side, stacked, or adjustable wipe layouts
- Synchronize normalized pan/zoom, temporarily unlock alignment, save an offset, and reset safely
- Enter comparison from Browser, Develop, or full-screen and present it on Clean Feed
- Save named Develop versions in an app-private JSON catalog without multiplying XMP states
- Duplicate, rename, delete, compare, or promote a named version to Primary; promotion first creates a
  recovery snapshot and verifies the resulting XMP read-back

Named versions are not interoperable XMP edits until explicitly promoted to Primary.

### Export & Rendering

Render edited images with the same pixel-perfect Metal pipeline used for preview:

- **SDR formats:** JPEG, PNG, TIFF, HEIC, AVIF, JPEG XL
- **HDR formats:** Adaptive HDR JPEG (ISO gain map), 10-bit HEIC, 10-bit AVIF, JPEG XL, 16-bit TIFF, 16-bit PNG
- **Color gamuts:** sRGB, Display P3, Rec. 2020, Adobe RGB
- TIFF compression options: None, LZW, ZIP
- Quality slider for lossy formats
- Batch render selected or all images

AVIF can be encoded with native macOS Image I/O or bundled FFmpeg
(arm64, `libaom-av1`). JPEG XL encoding uses bundled FFmpeg (`libjxl`).

### Content Authenticity (C2PA)

> **Experimental preview.** C2PA signing has not yet been verified end-to-end and may change, or be turned off by default, in a future release.

- Detect and display C2PA content credentials on images
- Warnings before destructive writes to C2PA-protected images
- Experimental signing of images with C2PA content credentials — certificate and private key stored in the macOS Keychain
- Powered by bundled c2patool

### FTP / SFTP Upload and Deadline Delivery

- Upload selected or all images via FTP or SFTP
- Multiple connection profiles with a Test Connection button
- Credentials stored securely in macOS Keychain
- Pre-upload required-field check that is sidecar-aware (falls back to the XMP sidecar for RAW files)
- Edited images rendered into a per-folder `Uploaded/` folder before sending, with batch abort
- Progress tracking with upload overlay, automatic retry, and human-readable errors
- Deadline Send freezes the preflight, filenames, metadata, Develop state, export settings, and
  destination before producing isolated staged copies; warnings require explicit per-batch acceptance
- Deadline delivery supports staged copies only: SDR JPEG/TIFF and HDR Adaptive JPEG gain-map/16-bit
  TIFF. RAW sources are rendered into those derivatives; Deadline Send refuses original-file and
  XMP-sidecar-only delivery strategies
- Staged bytes receive the authoritative resolved metadata, are parsed back for semantic verification,
  and retain preservation evidence before upload. Failed and cancelled workflows keep verified staging
  evidence for exact resume or confirmed cleanup in Activity

FTP/SFTP delivery acknowledgement has deliberate limits. FTP/FTPS/SFTP protocol success and an optional
remote existence/size observation are not a cryptographic remote-byte verification. The production
adapter rechecks the local file's identity, size, and SHA-256 before requesting credentials, but there is
still a narrow path-based time-of-check/time-of-use interval before `curl` opens that path. SFTP currently
supports passwords supplied through a private temporary mode-0600 netrc file; SSH private-key identities
are not supported.

### External Editor Integration

- Hand off images to external editors (Lightroom, Capture One, etc.)
- Import workflow for externally-edited files

### iCloud Sync

Opt-in sync that keeps your library settings in step across Macs, configured in Settings → iCloud Sync:

- Master "Sync everything" toggle, or per-category control
- Synced categories: metadata templates, keyword lists, the Known People database, the Teams / roster library, and portable app settings
- Stored in the app's iCloud Drive container so it follows you to your other Macs
- Passwords, signing keys, and machine-specific values (file paths, certificates, FTP servers) stay on-device and are never synced
- Coordinated through `NSFileCoordinator` so syncing never forks conflicting duplicate folders

### Privacy and Delivery Retention

- Delivery receipts and retained delivery workflows live in local Application Support and are not part
  of iCloud Sync. Retained workflow directories are also excluded from device backup
- Workflow catalog and Activity summaries are deliberately limited and contain no credentials or
  editorial metadata values. Receipt Activity details additionally omit filenames, source paths, and
  content hashes
- Exact private workflow state necessarily contains the frozen plan, local source identities, resolved
  editorial metadata, destination details, and retained staged copies. It is used only for validation,
  resume, and delivery execution; it is not placed in Activity summaries, logs, analytics, or sync
- Retained workflows and staging are removed only after an explicit confirmation in Activity. Receipts
  can also be deleted there; the local receipt repository otherwise keeps at most 250 receipts and drops
  entries older than 365 days when its retention boundary runs

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+O | Open folder |
| Shift+Cmd+I | Import photos |
| Cmd+B / Cmd+N | Previous / Next image |
| Cmd+0-5 | Set star rating |
| Option+0-8 | Set color label |
| Cmd+T | Open template palette |
| Ctrl+1-9 | Apply template 1-9 |
| Cmd+E | Open in external editor |
| H | Toggle HDR mode |
| G | Toggle gamut clipping |
| M | Toggle masks panel |
| Cmd+J | Add new mask |
| Cmd+W (Develop) | Remove selected local layer, or reset Global |
| Cmd+D | Mute selected mask (or the Global layer) |
| Option+V | Paste develop settings (including crop) |
| Cmd+R / Shift+Cmd+R | Rotate right / left |
| Cmd+S | Render selected |
| Shift+Cmd+S | Render all |
| Shift+Cmd+W | Write pending metadata |
| Cmd+U / Shift+Cmd+U | Upload selected / all |
| Shift+1-4 | Scope: Waveform / Parade / Vector / Chromaticity |
| Space | Full-screen toggle |
| 0-5 (full-screen or Develop) | Set rating; 0 clears |
| Middle-click (Develop filmstrip) | Copy clicked image's settings to current selection |

## Architecture

MVVM with a services layer, built primarily on Apple frameworks plus a small set of bundled helper binaries.

- **Swift 6** with strict concurrency (`@MainActor` default isolation, `Sendable` services)
- **Metal GPU pipeline** for real-time image editing, scope rendering, and export
- **SwiftMediaMetadata 3** (SPM, pure Swift) for metadata read/write
- **Image I/O** for native 8-bit and 10-bit AVIF encoding
- **FFmpeg** (bundled, arm64) for alternative AVIF and JPEG XL encoding
- **c2patool** (bundled) for C2PA signing
- **Apple Vision** for face detection; bundled **AuraFace (ArcFace) CoreML** model for face embeddings and recognition

### Storage

| Location | Contents |
|---|---|
| `.photo_metadata/` (per folder) | JSON metadata sidecars |
| `.xmp` sidecars (per folder) | Camera RAW edit settings |
| `.face_data/` (per folder) | Face detection data and thumbnails |
| `~/Library/Application Support/Aagedal Photo Agent/KnownPeople/` | Known People database |
| `~/Library/Application Support/Aagedal Photo Agent/Templates/` | Metadata presets |
| `~/Library/Application Support/Aagedal Photo Agent/Lists/` | Keyword lists |

When iCloud Sync is enabled, the Templates, KnownPeople, Teams, and Lists folders move to the app's iCloud Drive container (`iCloud.aagedal.Aagedal-Photo-Agent/Documents/`) instead of Application Support.

## Local testing and CI

Before pushing a PR, run the relevant local tests and repository validation:

```bash
xcodebuild -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS" test
scripts/ci/validate_repository.sh
```

Use Xcode’s test selection or `-only-testing` for focused checks appropriate to the change.
PR CI runs the fast **Repository validation** job, including generated-document drift,
release metadata, bundled-component provenance, privacy checks, JSON/plist validation,
conflict markers and whitespace. It relies on local builds and tests before pushing.
Pushes to `main` and manual **macOS CI** runs also reproduce the reviewed model, perform
a clean build and run the entire test suite. Releases still require a passing full push
run tied to the exact source revision; a successful lightweight PR run does not qualify.

## Releasing

The app uses [Sparkle](https://sparkle-project.org) for in-app auto-updates. Releases are signed with an EdDSA key and advertised through the canonical `appcast.xml` on GitHub. Codeberg keeps a synchronized legacy copy for older installed builds whose feed URL still points there.

### One-time setup

1. Resolve Swift packages so Sparkle's command-line tools are downloaded:
   ```bash
   xcodebuild -resolvePackageDependencies -project "Aagedal Photo Agent.xcodeproj"
   ```
2. Generate an EdDSA key pair. The private key is stored in your login keychain; the public key is printed to stdout:
   ```bash
   "$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*/Sparkle*' | head -n 1)"
   ```
3. Paste the public key into `Aagedal Photo Agent/Info.plist` under `SUPublicEDKey`, replacing `REPLACE_WITH_PUBLIC_KEY_FROM_GENERATE_KEYS`. Commit the plist; never commit the private key.

### Per release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
   Keep the bundle version numeric (for example `3.0.0`). Set `AAGEDAL_RELEASE_VERSION`
   to `3.0.0-beta.2` for a beta, or to the numeric version for a stable release.
   Every beta and subsequent stable release must have a strictly increasing build.
   Beta DMGs and archives use the full beta identity; generated appcast items carry
   `sparkle:channel=beta`. Only beta installations opt into that channel; the eventual
   stable release remains available to them through the default channel.
2. Add the release notes to `CHANGELOG.md`, including a concise `### Highlights` list for the Sparkle appcast.
   AuraFace is bundled for this release. The release assistant verifies the exported app contains
   `Contents/Resources/AuraFaceR100.mlmodelc` with the reviewed model weights before notarization.
3. Commit and push the exact release source, then wait for the **macOS CI / Clean build and unfiltered tests** check to pass for that commit. The workflow performs a clean `build-for-testing`, an unfiltered `test-without-building`, generated-metadata drift checking, JSON/plist validation, conflict-marker scanning, and whitespace checks. Configure this check as required on the protected release branch in GitHub; repository files cannot enforce that remote setting.
4. From a clean checkout of that same commit, run the release assistant with an authenticated GitHub CLI:
   ```bash
   scripts/release.sh
   ```
   Before accessing signing credentials or building, it rejects a dirty worktree and verifies a successful CI run tied to the exact `HEAD` SHA. The accepted run is recorded under `build/release/`. It then archives, exports with Developer ID, notarizes and staples the app and DMG, Sparkle-signs the DMG, and inserts the appcast item. When an archive or valid exported app has matching version/build metadata **and** the source-revision marker written by the script, its terminal menu can resume from that artifact instead of rebuilding; unmarked or stale-revision artifacts are rejected. Set `RELEASE_BUILD_MODE=reuse` or `RELEASE_BUILD_MODE=rebuild` to make that choice non-interactively.
5. Upload the DMG to `https://aagedal.me/apps/photoagent/`, using the exact filename printed by the script.
6. Commit and push the generated `appcast.xml` to GitHub, tag the release, then synchronize the website fallback appcast and legacy Codeberg copy.
7. For stable releases, bump the cask in the `aagedal/homebrew-tap` repo.
   For public betas, publish a GitHub prerelease with tag `3.0.0-beta.2`, attach the
   notarized DMG and its SHA-256, and leave the stable cask/latest release unchanged.
   Include the beta limitations and backup guidance from the changelog.

An emergency can bypass the CI lookup only with `RELEASE_TEST_GATE_OVERRIDE=EMERGENCY`, a written `RELEASE_TEST_GATE_OVERRIDE_REASON` of at least 20 characters, and confirmation by typing (or setting `RELEASE_TEST_GATE_OVERRIDE_CONFIRM` to) the full current SHA. The script prints a prominent warning and records the revision, operator, timestamp, and reason in `build/release/release-test-gate.json` and the append-only-per-worktree `release-test-gate-audit.jsonl`. Preserve those files with the release records. An override does not permit releasing uncommitted source.

## License

GPL-3.0 - see [LICENSE](LICENSE) for details.

### Bundled third-party components

License texts ship with the app (Settings → Licenses) and live under `Aagedal Photo Agent/Resources/`.

| Component | Purpose | License |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | Image encoding and local Whisper transcription | GPL-3.0 |
| [c2patool](https://github.com/contentauth/c2pa-rs) | C2PA content credentials | MIT |
| [Sparkle](https://sparkle-project.org) | Software updates | MIT |
| [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata) | Image, audio, and video metadata | GPL-3.0 |
| [AuraFace-v1](https://huggingface.co/fal/AuraFace-v1) | Face recognition model | Apache-2.0 |

### Source for bundled GPL components (GPLv3 §6)

The app bundles a GPL-licensed **FFmpeg** binary. In accordance with the GPL, the corresponding source is available:

<!-- BEGIN GENERATED BUNDLED GPL SOURCE -->
- **FFmpeg 9.0.1**, built with `--enable-gpl --enable-version3 --enable-whisper`.
  This full build supports image export and local voice memo transcription. Network and
  device support is compiled in; transcription restricts input protocols to local files.
- [Exact source inputs, local patches and build evidence](docs/provenance/ffmpeg-whisper-bundled.md)
  are pinned in the component manifest. Preparation: `scripts/ffmpeg/prepare_full_candidate.py`.
  The complete corresponding source companion must accompany a release; an upstream
  FFmpeg tarball alone does not reproduce this modified build and its dependencies.
<!-- END GENERATED BUNDLED GPL SOURCE -->

Versions, immutable upstream and build-recipe revisions, artifact SHA-256 values, licenses, target
architectures, and expected runtime capabilities for bundled binaries and the optional AuraFace model are
recorded in `Aagedal Photo Agent/Resources/bundled-components.json`. The repository validator checks that
manifest against every present artifact; the required FFmpeg and c2patool binaries must always be present.

The application's own source is published under GPL-3.0. SwiftMediaMetadata is resolved from its
GPL-3.0 upstream repository at the version pinned in `Package.resolved` (currently
[3.0.1](https://github.com/aagedal/SwiftMediaMetadata/tree/3.0.1)); the shipped license text, public
table, and in-app label consistently identify GPL-3.0. See the
[documentation-readiness validation](docs/documentation-readiness-validation-2026-08-25.md).
