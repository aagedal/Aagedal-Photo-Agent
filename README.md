# Aagedal Photo Agent

A native macOS desktop application for photo metadata management and face recognition — an open-source alternative to Adobe Bridge and Photo Mechanic. Built with SwiftUI and Metal for Apple Silicon.

**License:** GPL-3.0



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

- Edit IPTC fields: title, caption, keywords, person shown, creator, credit, copyright, city, country, event, job ID, GPS coordinates
- Non-destructive editing via JSON sidecar files with explicit save
- Copy and paste metadata between images
- Structured keywords — Photo Mechanic-style hierarchical keyword lists with categories and synonyms, with a tree picker in the metadata panel
- Batch metadata application via templates with variable interpolation
- Template variables: `{date}`, `{date:FORMAT}`, `{dateCreated}`, `{dateCreated:YYYYMMDD}`, `{dateCreated:DDMMYYYY}`, `{dateCreated:YYYY-MM-DD}`, `{dateCaptured}`, `{dateCaptured:YYYYMMDD}`, `{dateCaptured:DDMMYYYY}`, `{dateCaptured:YYYY-MM-DD}`, `{filename}`, `{seq}`, `{persons}`, `{keywords}`, `{initials}`, `{field:FIELDNAME}` — variables also resolve inside keywords and Person Shown
- Template hotkeys (Ctrl+1-9) for rapid workflows
- Required-metadata definitions that drive the browser's missing-field filter and the pre-upload check
- Metadata mirrored to both IPTC and XMP for cross-tool interoperability
- Correct IPTC `CodedCharacterSet` tagging so Nordic / non-ASCII characters round-trip through other apps
- Pure-Swift in-process metadata engine (SwiftExif) — no external binaries, no subprocess overhead

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

### FTP / SFTP Upload

- Upload selected or all images via FTP or SFTP
- Multiple connection profiles with a Test Connection button
- Credentials stored securely in macOS Keychain
- Pre-upload required-field check that is sidecar-aware (falls back to the XMP sidecar for RAW files)
- Edited images rendered into a per-folder `Uploaded/` folder before sending, with batch abort
- Progress tracking with upload overlay, automatic retry, and human-readable errors

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
- **SwiftExif** (SPM, pure Swift) for metadata read/write
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
2. In Xcode: Product → Archive → Distribute App → Developer ID → upload for notarization → Export Notarized App.
3. Build the DMG with the existing process.
4. Sign the DMG (produces `sparkle:edSignature` and `length`):
   ```bash
   "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -path '*/Sparkle*' | head -n 1)" \
     "Aagedal-Photo-Agent-X.Y.Z.dmg"
   ```
5. Add a new `<item>` entry to `appcast.xml` with the version, build number, pubDate, enclosure URL on `aagedal.me`, signed length, signature, and release notes. Sparkle's docs cover the schema: <https://sparkle-project.org/documentation/publishing/>.
6. Commit and push `appcast.xml` to GitHub, then synchronize the legacy Codeberg copy for older installed builds.
7. Bump the cask in the `aagedal/homebrew-tap` repo.

## License

GPL-3.0 - see [LICENSE](LICENSE) for details.

### Bundled third-party components

License texts ship with the app (Settings → Licenses) and live under `Aagedal Photo Agent/Resources/`.

| Component | Purpose | License |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | AVIF / JPEG XL encoding | GPL-3.0 |
| [c2patool](https://github.com/contentauth/c2pa-rs) | C2PA content credentials | MIT |
| [Sparkle](https://sparkle-project.org) | Software updates | MIT |
| [SwiftExif](https://github.com/aagedal/SwiftExif) | EXIF / IPTC metadata | GPL-3.0 |
| [AuraFace-v1](https://huggingface.co/fal/AuraFace-v1) | Face recognition model | Apache-2.0 |

### Source for bundled GPL components (GPLv3 §6)

The app bundles a GPL-licensed **FFmpeg** binary. In accordance with the GPL, the corresponding source is available:

- **FFmpeg 8.1.1**, built with `--enable-gpl --enable-version3` (image-only, network and device features disabled). Upstream source: <https://ffmpeg.org/releases/> (`ffmpeg-8.1.1.tar.xz`). The exact `configure` flags are embedded in the binary (`ffmpeg -version`).
- The build script used to produce it is published at <https://github.com/aagedal/ffmpeg-apple-silicon>.

The application's own source (GPL-3.0) and the **SwiftExif** source (GPL-3.0) are published on GitHub.
