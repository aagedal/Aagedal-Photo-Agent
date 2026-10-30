# Aagedal Photo Agent

A native macOS desktop application for photo metadata management and face recognition — an open-source alternative to Adobe Bridge and Photo Mechanic. Built with SwiftUI and Metal for Apple Silicon.

**License:** GPL-3.0

[**3.0.0 Beta 4**](https://github.com/aagedal/Aagedal-Photo-Agent/releases/tag/3.0.0-beta.4) is available as a public testing release. See the [3.0 feature guide](docs/feature-help-3.0.md),
[known limitations](docs/limitations-3.0.md), and [privacy draft](PRIVACY.md) for the release-candidate
behavior and boundaries.



## Requirements

- macOS 26.0 or later
- Apple Silicon (arm64)

## Installation

```bash
brew install aagedal/casks/aagedal-photo-agent
```

Or build from source. First provision the reviewed [face model](Aagedal%20Photo%20Agent/Resources/Models/README.md),
[llama runtime](scripts/llama/README.md), and [web downloader runtime](scripts/web_downloads/README.md)
in each checkout or worktree. These build resources are excluded from Git. For the web downloader:

```bash
python3 scripts/web_downloads/fetch_python.py
python3 scripts/web_downloads/prepare_runtime.py build/web-download-python
```

Then build:

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
- Sort by visual similarity to a selected photo using local image analysis. Choose **Similarity** again to use a new selection; without a selection, the first local photo by name is the reference. Analysis uses original pixels and runs in the background, with a completed/total photo counter beside the sort menu's spinner.
- Filter by star rating, color label, person shown, or missing required metadata fields
- Full-text search across filenames and IPTC metadata fields
- Folder favorites, recent folders, and drag-and-drop folder organization in the sidebar
- Split the grid into two panes (side by side, stacked, or tabs) to cull between folders
- Batch Rename with reusable recipes; RAW+JPEG pairs, XMP sidecars and voice memos follow the new names
- Browser visibility modes: Photos, All media files (photos and videos), or All files
- Extract one or several stills from a video from a video’s right-click menu: play, scrub (Option-drag for precision), step frames, press M to add markers without pausing playback, and save full-resolution JPEG, TIFF, or lossless 16-bit JPEG XL files to a chosen folder. This initial version supports videos playable by macOS, converts HDR to SDR for JPEG/TIFF while JPEG XL preserves source precision and HDR, and records the source filename and frame timecode in each still (embedded source timecode when present, otherwise relative timecode starting at `00:00:00:00`). Videos currently use system icons in the grid.

### Ingest & Import

- Import selected images and videos from individual Instagram or X post URLs. Preserve downloaded originals alongside working copies with source attribution and caption metadata, plus JSON provenance records. Settings → Web Downloads updates gallery-dl and yt-dlp independently of the app. This first version uses the extractor's preferred quality; video and non-JPEG metadata use adjacent XMP. See the [runtime setup and current limits](scripts/web_downloads/README.md).
- Import from memory cards or folders with a non-blocking progress bar, a time-left estimate and Eject for the card when it finishes
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
- Customizable Develop panel with per-slider visibility preferences; click a slider's value to type an exact number
- Tone curves (Adobe Camera Raw compatible)
- Crop, straighten, and rotation
- Reorderable develop layer chain — a horizontal strip of cards (Global node plus local masks) that you can drag to reorder
- Local adjustments with elliptical/radial masks — each mask has independent tonal and color controls
- Freeform brush masks and click-to-select AI masks for people and objects
- Anonymizer: the Redact Anonymizer's distortion, blur and mosaic layers (square, triangle or hexagon cells, cell and colour noise, frosted glass) or black out faces and areas; redactions are kept in every export, upload and preview
- Watermark layers from a PNG library or reusable text watermarks, placed relative to the crop
- Develop templates for saving and applying edits, crops, masks and watermarks
- HDR/EDR rendering with extended dynamic range
- Before/after comparison toggle
- Undo/redo support
- Copy/paste develop settings between images (⌥V pastes including crop)
- Edits stored in XMP sidecar files for cross-tool compatibility — develop settings and masks are written in Adobe Camera Raw's `crs` encoding so ACR / Bridge detect and render them

### Metadata Management

- Edit the app's descriptive IPTC/XMP field set, including headline, caption, keywords, people and organisations shown, ordered creators, creator contact, credit and rights, Subject/Scene Codes, Media Topics, structured Genre and PLUS Image Supplier values, precision-aware Date Created, locations, instructions, source, and GPS coordinates
- Description Assistant: fix grammar or improve wording in Bokmål, Nynorsk or English, draft a caption
  from the image, or dictate one, then review the suggestion before applying it. Runs on this Mac with a
  downloaded local model (Gemma 4, Qwen3.5 or Ministral 3; Settings → Description Models shows size and RAM
  guidance) or Apple Foundation Models on macOS 27 with Apple Intelligence.
  [Bundled runtime details](scripts/llama/README.md)
- Description presets: Settings → Description Assistant offers Archival, Neutral editorial, NTB-inspired, Reuters-inspired, AP-inspired, AFP-inspired, and Short caption formats. Create multiple named custom presets, or duplicate a built-in to edit its guidance. Custom names and prompts save automatically and can be renamed or deleted. Existing custom prompt text migrates to “My existing prompt.” The selected preset applies to individual and batch suggestions; language remains a separate choice and factual safeguards apply to every preset. Agency-inspired names describe formatting only. No reference photographs, extracted metadata, or sample captions are bundled.
- Optionally append named people in left-to-right order from an existing face scan. Names and normalized face positions enter the request; the app constructs the name list deterministically. Unnamed, excluded, and out-of-date face records are omitted. Ordering refers to the upright original image, rather than a developed crop. This iteration processes one photo; immutable per-photo requests and shared model admission provide the basis for a later batch queue.
- Non-destructive editing via JSON sidecar files with explicit save
- Copy and paste metadata between images
- Caption Workspace for working through a folder: field navigator, validation, Save & Next, Write & Next,
  Copy Previous and Fix Next Issue
- Metadata Review table for checking and editing fields across many photos
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

### Voice Memos and Transcription

- Sony camera voice memos (WAV) are paired with their photos on import and stay with them through
  rename, move, reject and Trash. Play them in Caption.
- Transcribe one photo in Caption or up to eight from the Browser with **Apple Speech** (default, no
  download) or local **Whisper** (Tiny, Base, Small, Turbo, Large v3 and Norwegian NbAiLab models,
  downloaded in Settings → Transcription and checked against a pinned SHA-256). Inference stays on this Mac.
- Transcripts are editable drafts. Use `{voiceMemoTranscript}` in a template to put one into Description,
  Extended Description, Headline or Instructions.

### Local Automation (experimental)

- A bundled `photo-agent-mcp` helper lets a local MCP client (Codex CLI, Claude Code, OpenCode) read
  and preview photos, metadata, templates and voice memos in folders you allow in Settings → Automation.
  It is off by default and opens no network listener.
- In 3.0 automation is read-only: requests that would change something (a metadata or transcription
  review, adding a team) wait for your approval in the app.
- Tool reference: [docs/developer/local-automation-mcp.md](docs/developer/local-automation-mcp.md).

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

- Waveform scope (Ctrl+Option+1)
- Parade / RGB scope (Ctrl+Option+2)
- Vectorscope (Ctrl+Option+3)
- CIE 1931 chromaticity diagram (Ctrl+Option+4) with target gamut overlay and HDR-aware display gamut indicator
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
- Duplicate, rename, delete or compare named versions, or choose **Make Main Edit…** to make one the main edit
  (the edit saved in the photo's XMP); the previous main edit is kept as a dated version and the result is checked

Other apps see only the main edit; named versions stay in Photo Agent until you make one the main edit.

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

### FTP / FTPS Upload

- Upload selected or all images via FTPS (FTP over TLS, the default for new servers) or plain FTP.
  SFTP isn't supported: macOS's built-in `curl` has no SFTP; older SFTP profiles are flagged and
  refused until switched to FTPS
- Multiple connection profiles with a Test Connection button
- Credentials stored securely in macOS Keychain
- Pre-upload required-field check that is sidecar-aware (falls back to the XMP sidecar for RAW files)
- Edited images rendered into a per-folder `Uploaded/` folder before sending; photos with face blurs
  are always rendered
- Files upload under a temporary name and are renamed when complete, so hot folders never ingest a
  partial file; progress, Retry Failed and human-readable errors in Activity

A successful upload means the server accepted the file; Photo Agent does not re-download it to compare
bytes. Passwords are supplied through a private temporary mode-0600 netrc file.

### External Editor Integration

- Hand off images to external editors (Lightroom, Capture One, etc.)
- Import workflow for externally-edited files

### iCloud Sync

Opt-in sync that keeps your library settings in step across Macs, configured in Settings → iCloud Sync:

- Master "Sync everything" toggle, or per-category control
- Synced categories: metadata templates, keyword lists, the Known People database, the Teams / roster library, watermarks, and portable app settings
- Stored in the app's iCloud Drive container so it follows you to your other Macs
- Passwords, signing keys, and machine-specific values (file paths, certificates, FTP servers) stay on-device and are never synced
- Coordinated through `NSFileCoordinator` so syncing never forks conflicting duplicate folders

### Privacy

- Face recognition, transcription, the Description Assistant and image analysis run on this Mac. No
  analytics or tracking. Photos leave the Mac only through features you use, such as FTP upload; other
  network use (updates, maps and geocoding, model downloads, web imports) is listed in [PRIVACY.md](PRIVACY.md).
- Upload and import history lives in local Application Support, is not synced and contains no
  credentials.

## Keyboard Shortcuts

Open **Settings → Shortcuts** to inspect the keyboard, switch profiles, record a key,
or unassign a command. File, browsing, metadata, Develop, export, scopes and upload
commands share one profile with rating and label shortcuts. The preview shows actual
assignments and free keys across modifier layers; moving an occupied key requires
confirmation. Core menu commands have one shortcut each, while rating and label actions
support alternate bindings. Native menus update immediately. Caption Save & Next and
Write & Next keep separate assignments because they also work during typing.

Standard text editing, window controls and fixed workspace gestures remain reserved.
Settings lists these gestures for reference and identifies contextual Develop behavior.
Dialog and settings editors keep their local controls. The table below uses the default
Photo Agent profile.

| Shortcut | Action |
|---|---|
| Cmd+O | Open folder |
| Shift+Cmd+I | Import photos |
| Cmd+B / Cmd+N | Previous / Next image |
| 0-5 | Set star rating; 0 clears |
| Cmd+0-8 | Set color label; 0 clears |
| Cmd+T | Open template palette |
| Ctrl+1-9 | Apply template 1-9 |
| Cmd+E | Open in external editor |
| Ctrl+Option+H | Toggle HDR mode |
| Ctrl+Option+G | Toggle gamut clipping |
| M (hold, Develop) | Before / after preview |
| Cmd+J | Add new mask |
| Ctrl+Option+Delete (Develop) | Remove selected local layer, or reset Global |
| Cmd+D | Mute selected mask (or the Global layer) |
| Option+V | Paste develop settings (including crop) |
| Cmd+R / Shift+Cmd+R | Rotate right / left |
| Cmd+S | Render selected |
| Shift+Cmd+S | Render all |
| Shift+Cmd+W | Write pending metadata |
| Cmd+U / Shift+Cmd+U | Upload selected / all |
| Ctrl+Option+1-4 | Scope: Waveform / Parade / Vector / Gamut |
| Space | Full-screen toggle |
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

When iCloud Sync is enabled, the Templates, KnownPeople, Teams, Lists, and Watermarks folders move to the app's iCloud Drive container (`iCloud.aagedal.Aagedal-Photo-Agent/Documents/`) instead of Application Support.

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

The app uses [Sparkle](https://sparkle-project.org) for in-app auto-updates. Releases are signed with an EdDSA key and advertised through the canonical `appcast.xml` on GitHub. The website keeps a backup copy at `https://aagedal.me/apps/appcast/photoagent.xml`. Codeberg is no longer used.

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
   For 3.0.0, run `scripts/finalize_changelog.py --version 3.0.0 --date YYYY-MM-DD --draft docs/release/3.0.0-release-notes-draft.md`;
   it adds the dated section and rejects Highlights the appcast would show truncated or as raw markdown.
   Appcast items carry `sparkle:minimumAutoupdateVersion` 740 (the first 3.0 build), so 2.x
   installs see the update alert and its notes instead of a silent background install. Override
   with `AAGEDAL_MINIMUM_AUTOUPDATE_BUILD`, or set it empty to omit the tag.
   AuraFace is bundled for this release. The release assistant verifies the exported app contains
   `Contents/Resources/AuraFaceR100.mlmodelc` with the reviewed model weights before notarization.
3. Commit and push the exact release source, then wait for the **macOS CI / Clean build and unfiltered tests** check to pass for that commit. The workflow performs a clean `build-for-testing`, an unfiltered `test-without-building`, generated-metadata drift checking, JSON/plist validation, conflict-marker scanning, and whitespace checks. Configure this check as required on the protected release branch in GitHub; repository files cannot enforce that remote setting.
4. From a clean checkout of that same commit, run the release assistant with an authenticated GitHub CLI:
   ```bash
   scripts/release.sh
   ```
   Before accessing signing credentials or building, it rejects a dirty worktree and verifies a successful CI run tied to the exact `HEAD` SHA. The accepted run is recorded under `build/release/`. It then archives, exports with Developer ID, notarizes and staples the app and DMG, Sparkle-signs the DMG, and inserts the appcast item. When an archive or valid exported app has matching version/build metadata **and** the source-revision marker written by the script, its terminal menu can resume from that artifact instead of rebuilding; unmarked or stale-revision artifacts are rejected. Set `RELEASE_BUILD_MODE=reuse` or `RELEASE_BUILD_MODE=rebuild` to make that choice non-interactively.
5. Publish the DMG as a GitHub release asset tagged with the version (the appcast's download URL), and copy it to
   the backup host `https://aagedal.me/apps/photoagent/`, using the exact filename printed by the script.
   Also upload the FFmpeg corresponding-source companion built by
   `python3 scripts/ffmpeg/make_source_companion.py --sources <ffmpeg build sources>` (see
   [its provenance](docs/provenance/ffmpeg-photo-agent-9.0.2.md#corresponding-source-companion))
   and link it from the release notes, as GPLv3 §6 requires.
6. Commit and push the generated `appcast.xml` to GitHub (after the release asset exists), then update the website
   fallback feed `https://aagedal.me/apps/appcast/photoagent.xml` with enclosures pointing at the backup host.
7. For stable releases, bump the cask in the `aagedal/homebrew-tap` repo.
   For public betas, publish a GitHub prerelease tagged with the beta version (for example `3.1.0-beta.1`), attach the
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
- **FFmpeg 9.0.2**, built with `--enable-gpl --enable-version3 --enable-whisper`.
  This full build supports image export and local voice memo transcription. Network and
  device support is compiled in; transcription restricts input protocols to local files.
- [Exact source inputs, local patches and build evidence](docs/provenance/ffmpeg-whisper-bundled.md)
  are pinned in the component manifest. Preparation: `docs/provenance/ffmpeg-photo-agent-9.0.2-build/scripts/12b-ffmpeg-photo-agent.sh`.
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
