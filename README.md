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
xcodebuild -project "Aagedal Photo Agent/Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent" build
```

## Features

### Image Browsing & Organization

- Browse folders with fast 240x240 thumbnail previews
- Full-screen image view with keyboard navigation and prefetching
- Star ratings (0-5) and color labels with keyboard shortcuts
- Sort by name, date modified, date added, file size, or star rating
- Filter by star rating, color label, or person shown
- Full-text search across filenames and IPTC metadata fields
- Folder favorites for quick access

### Supported Formats

- **Standard:** JPEG, PNG, TIFF, HEIC, HEIF, BMP, GIF, WebP, AVIF, JPEG XL
- **RAW:** CR2, CR3, NEF, NRW, ARW, RAF, DNG, RW2, ORF, PEF, SRW

### Camera RAW Editing

Non-destructive RAW development with real-time Metal GPU preview:

- Exposure, contrast, highlights, shadows, whites, blacks
- White balance (temperature and tint)
- Vibrance and saturation
- Tone curves (Adobe Camera Raw compatible)
- Crop and rotation
- Local adjustments with elliptical/radial masks — each mask has independent tonal and color controls
- HDR/EDR rendering with extended dynamic range
- Before/after comparison toggle
- Undo/redo support
- Edits stored in XMP sidecar files for cross-tool compatibility

### Metadata Management

- Edit IPTC fields: title, caption, keywords, person shown, creator, credit, copyright, city, country, event, job ID, GPS coordinates
- Non-destructive editing via JSON sidecar files with explicit save
- Batch metadata application via templates with variable interpolation
- Template variables: `{date}`, `{date:FORMAT}`, `{dateCreated}`, `{dateCaptured}`, `{filename}`, `{persons}`, `{keywords}`, `{field:FIELDNAME}`
- Template hotkeys (Ctrl+1-9) for rapid workflows
- Metadata mirrored to both IPTC and XMP for cross-tool interoperability
- Pure-Swift in-process metadata engine (SwiftExif) — no external binaries, no subprocess overhead

### Face Recognition

- Automatic face detection using Apple Vision framework
- Similarity-based face clustering with multiple algorithms:
  - Hierarchical clustering (average/median linkage)
  - Chinese Whispers
  - Quality-gated two-pass
- Quality scoring: confidence, face size, and blur detection
- Known People database with per-person embeddings and sample management
  - Auto-matching with configurable confidence thresholds
  - Import/export database (ZIP format)
  - Interactive suggestions UI during metadata editing
- Face + Clothing recognition mode for scenarios like red carpet photography
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
- **HDR formats:** 10-bit HEIC, 10-bit AVIF, JPEG XL, 16-bit TIFF, 16-bit PNG
- **Color gamuts:** sRGB, Display P3, Rec. 2020, Adobe RGB
- TIFF compression options: None, LZW, ZIP
- Quality slider for lossy formats
- Batch render selected or all images

AVIF and JPEG XL encoding powered by bundled FFmpeg (arm64, `libaom-av1` and `libjxl`).

### Content Authenticity (C2PA)

- Detect C2PA manifests on images
- Sign images with C2PA content credentials
- Certificate and private key storage in macOS Keychain
- Warnings before destructive writes to C2PA-protected images
- Powered by bundled c2patool

### FTP / SFTP Upload

- Upload selected or all images via FTP or SFTP
- Multiple connection profiles
- Credentials stored securely in macOS Keychain
- Progress tracking with upload overlay

### External Editor Integration

- Hand off images to external editors (Lightroom, Capture One, etc.)
- Import workflow for externally-edited files

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
| Cmd+R / Shift+Cmd+R | Rotate right / left |
| Cmd+S | Render selected |
| Shift+Cmd+S | Render all |
| Cmd+W | Write pending metadata |
| Cmd+U / Shift+Cmd+U | Upload selected / all |
| Shift+1-4 | Scope: Waveform / Parade / Vector / Chromaticity |
| Space | Full-screen toggle |
| 0-5 (full-screen) | Set rating |

## Architecture

MVVM with a services layer, built primarily on Apple frameworks plus a small set of bundled helper binaries.

- **Swift 6** with strict concurrency (`@MainActor` default isolation, `Sendable` services)
- **Metal GPU pipeline** for real-time image editing, scope rendering, and export
- **SwiftExif** (SPM, pure Swift) for metadata read/write
- **FFmpeg** (bundled, arm64) for AVIF and JPEG XL encoding
- **c2patool** (bundled) for C2PA signing
- **Apple Vision** framework for face detection and feature print similarity

### Storage

| Location | Contents |
|---|---|
| `.photo_metadata/` (per folder) | JSON metadata sidecars |
| `.xmp` sidecars (per folder) | Camera RAW edit settings |
| `.face_data/` (per folder) | Face detection data and thumbnails |
| `~/Library/Application Support/Aagedal Photo Agent/KnownPeople/` | Known People database |
| `~/Library/Application Support/Aagedal Photo Agent/Templates/` | Metadata presets |

## Releasing

The app uses [Sparkle](https://sparkle-project.org) for in-app auto-updates. Releases are signed with an EdDSA key and advertised through an `appcast.xml` hosted on Codeberg.

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
5. Add a new `<item>` entry to `appcast.xml` with the version, build number, pubDate, enclosure URL on Codeberg, signed length, signature, and release notes. Sparkle's docs cover the schema: <https://sparkle-project.org/documentation/publishing/>.
6. Create a new Codeberg release with the DMG; re-upload `appcast.xml` to the persistent `appcast` release tag so `SUFeedURL` stays stable.
7. Bump the cask in the `aagedal/homebrew-casks` repo.

## License

GPL-3.0 - see [LICENSE](Aagedal%20Photo%20Agent/LICENSE) for details.

### Bundled third-party components

License texts ship with the app (Settings → Licenses) and live in `Aagedal Photo Agent/Resources/Licenses/`.

| Component | Purpose | License |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | AVIF / JPEG XL encoding | GPL-3.0 |
| [c2patool](https://github.com/contentauth/c2pa-rs) | C2PA content credentials | MIT |
| [Sparkle](https://sparkle-project.org) | Software updates | MIT |
| [SwiftExif](https://codeberg.org/taagedal/SwiftExif) | EXIF / IPTC metadata | GPL-3.0 |
| [AuraFace-v1](https://huggingface.co/fal/AuraFace-v1) | Face recognition model | Apache-2.0 |
