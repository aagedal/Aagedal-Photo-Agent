# Aagedal Photo Agent
![Aagedal Photo Agent screenshot](https://github.com/user-attachments/assets/31cc3e86-ce9d-4deb-add9-3ca62fd426b9)

Open-source macOS photo metadata and face-tagging tool, built as a fast workflow alternative to Photo Mechanic and Adobe Bridge.

## Features

- IPTC/XMP editing for common newsroom/photo-library fields (title, caption, keywords, person shown, creator, credit, copyright, city, country, event, job ID, GPS).
- Star ratings and color labels with keyboard shortcuts.
- Metadata templates and variables for repeatable batch workflows.
- Folder-local non-destructive metadata history via sidecars.
- Face detection and clustering, plus a reusable Known People database.
- C2PA detection with warnings before destructive writes.
- FTP/SFTP upload support with credentials stored in macOS Keychain.
- External editor handoff and import workflow for incoming files.

## Installation

Install from Homebrew:

```bash
brew install aagedal/casks/aagedal-photo-agent
```

Or download a release from:

- <https://github.com/aagedal/aagedal-photo-agent/releases>

## Quick Start

1. Launch the app and open a folder with photos (`Cmd+O`).
2. Select one or more images and edit metadata in the right panel.
3. Optionally apply a template (`Cmd+T`) and resolve variables (`Cmd+P`).
4. Run face detection/grouping from the face bar, then name groups.
5. Configure write mode in Settings (direct file writes or sidecar-first behavior, including C2PA-safe defaults).

## Template Variables

Supported placeholders in template text:

- `{date}` or `{date:FORMAT}`
- `{dateCreated}`
- `{dateCaptured}`
- `{filename}`
- `{persons}`
- `{keywords}`
- `{field:FIELDNAME}`

## Keyboard Shortcuts

- `Cmd+O`: Open folder
- `Shift+Cmd+I`: Import photos
- `Cmd+0...5`: Set rating (0 = no rating)
- `Option+0...8`: Set color label
- `Cmd+B` / `Cmd+N`: Previous / next image
- `Cmd+P`: Process variables for selected images
- `Shift+Cmd+P`: Process variables for all images in folder
- `Cmd+T`: Open template palette
- `Cmd+U`: Upload selected
- `Shift+Cmd+U`: Upload all
- `Cmd+E`: Open in external editor
- `Cmd+Delete`: Move selected images to Trash

## Supported File Types

- JPEG, PNG, TIFF, HEIC, HEIF, BMP, GIF, WebP, AVIF, JXL
- RAW: CR2, CR3, NEF, NRW, ARW, RAF, DNG, RW2, ORF, PEF, SRW

## Data Storage

Per-folder:

- `.photo_metadata/` for metadata sidecars
- `.face_data/` for face clusters and thumbnails

App-wide:

- `~/Library/Application Support/Aagedal Photo Agent/Templates/`
- `~/Library/Application Support/Aagedal Photo Agent/KnownPeople/`

## Build From Source

Requirements:

- Apple Silicon Mac
- Xcode with Swift 6 support
- Project deployment target is currently set to `macOS 26.0` in the Xcode project

Build:

```bash
xcodebuild -project "Aagedal Photo Agent.xcodeproj" -scheme "Aagedal Photo Agent" -configuration Debug build
```

Notes:

- ExifTool is bundled with the app target.
- In Settings, ExifTool source can be switched to bundled, Homebrew, or a custom path.
- No automated test suite is currently configured.

## License

This project is licensed under **GNU GPL v3**. See [LICENSE](LICENSE).

## Acknowledgments

This application bundles [ExifTool](https://exiftool.org/) by Phil Harvey for reading and writing image metadata. ExifTool is distributed under the same terms as Perl itself (Perl Artistic License or GPL).
