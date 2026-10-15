# Private web downloader runtime

Photo Agent embeds a relocatable **python-build-standalone** installation and pure
Python wheels for gallery-dl, yt-dlp and their dependencies. It does not depend on
the user's Python, Homebrew, a virtual environment, or an absolute Python path.

## Prepare before building

Fetch the exact reviewed standalone Python archive, then prepare the locked
downloader packages. This is CPython 3.13.13, python-build-standalone build
`20260602`; the archive's SHA-256 is pinned in `fetch_python.py`:

```sh
python3 scripts/web_downloads/fetch_python.py
python3 scripts/web_downloads/prepare_runtime.py build/web-download-python
```

The generated `Vendor/web-download-runtime` is deliberately ignored by Git.
Preparation downloads the baseline wheels pinned in `packages.lock.json`, checks every wheel against its
PyPI SHA-256 digest, retains license files, and records exact package versions,
wheel hashes and all runtime file hashes. Wheel versions and hashes must also match
the committed lock. The tested baseline is gallery-dl
1.32.16 and yt-dlp 2026.8.19. Preparation also copies the runtime to a different
path with spaces and checks SSL, SQLite and compression module loading.

Xcode verifies the prepared tree and copies it into the application during its
existing bundled-helper build phase. It signs all Mach-O executables and native
modules inside-out for signed builds. No downloads occur during the Xcode build.
Run a Developer ID archive/notarization qualification before distributing this
new runtime; unsigned Debug builds do not establish notarization compatibility.

Python's bundled LICENSE.txt and each wheel's dist-info license directory remain
in the application. The standalone runtime includes native dependencies; release
packaging must carry the matching python-build-standalone license/source notices
as well as gallery-dl's GPL corresponding source for the exact shipped version.

## Updates

Settings → Web Downloads resolves compatible pure Python wheels in a new private
generation directory, verifies hashes, and imports both tools before publishing
an atomic current-generation pointer. No source builds, native package updates,
user pip configuration, or user gallery-dl configuration are permitted.

The Python interpreter remains bundled. Packages needing a newer Python require
a Photo Agent update. Restoring bundled versions removes only the pointer;
existing generations remain available to imports already using them. Package
versions are pinned from inspection through download and recorded in provenance.
Old generations are currently retained; automatic cleanup is not implemented.

## Import behavior

File → Import from Web URL supports individual Instagram posts/reels and X posts.
It lists images and videos in post order, downloads selected items using
gallery-dl's preferred quality, and uses its yt-dlp integration for DASH video.
Use Select All or Select None to adjust the selection; the import button shows
the selected count. Changing the URL or cookies clears the previous post's
selection, caption and status. Press Return in the URL field to find media.
An optional Netscape cookies file can be selected explicitly. Browser cookies
are not read automatically and credentials are excluded from provenance records.

Each batch creates:

- `Originals`: unchanged downloaded media; partial downloads remain on failure.
- `Working`: verified copies with embedded IPTC/XMP for ordinary JPEGs, or
  adjacent XMP for videos, other formats and C2PA-bearing JPEGs.
- `Provenance`: per-item JSON containing the canonical post URL, account,
  original post text, publication time, carousel position, original SHA-256,
  downloader versions and the actual downloaded media URL.

The posting account is Source, not Creator. Publication time does not become
capture time. The user can edit the working caption while the original post text
stays in provenance. Completed originals survive enrichment failures.
If an import fails or is cancelled, Reveal Retained Files in Finder opens the
retained batch. If no files remain, the dialog reports that instead. Before
creating working copies, the app checks that download results match the complete
selection and have distinct, valid filenames.

This initial UI lists media type and dimensions; it does not yet show thumbnail
previews or enumerate all alternate quality variants. Video metadata is written
to XMP sidecars rather than embedded into video containers. Authentication and
platform changes can still prevent extraction. The supplied carousel
`https://www.instagram.com/p/DeKeT1to6s3/` redirected to login without cookies.

## Verification

```sh
Vendor/web-download-runtime/bin/python3 -I -B scripts/web_downloads/test_bridge.py
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/WebMediaImportTests'
```

Bridge tests cover URL admission, mixed carousel ordering, stable selected-item
identity (including subsets of posts without media numbering), downloaded bytes,
changed selections, and wheel archive validation.
Native tests cover unchanged JPEG/video originals, JPEG metadata readback,
original-versus-edited captions, video XMP and cancellation preservation.
