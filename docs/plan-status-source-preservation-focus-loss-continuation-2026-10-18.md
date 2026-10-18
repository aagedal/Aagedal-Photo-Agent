# Source-preserving export and Develop focus loss — 2026-10-18

This continuation protects original image bytes during edited export and releases temporary
Develop keyboard modes when another window or application takes focus. It adds no main-window
controls or settings.

## Export originals

Render & Sign previously used the shared renderer's replacement default. With a JPEG source,
JPEG output and a destination beside the original, the encoder could replace the source pixels
before metadata copy noticed the alias and rejected delivery. Rejecting metadata failures after
encoding therefore did not protect the original.

Format delivery now defaults to numbered collision handling, producing a distinct output beside
an existing original. The renderer also checks source/destination identity before invoking its
source-aware encoders. The preflight compares standardized symlink-resolved paths and existing
volume/inode identity, covering regular paths, file/directory symlinks and hard links. It applies
to SDR/HDR format rendering, legacy JPEG rendering, Save As and RAW16 JXL/TIFF encoding.
Fresh destinations are checked first, avoiding an additional source-attribute fetch when
there is no existing destination inode to compare. Explicit
replacement of an independent output file remains available. Adobe DNG conversion is unchanged.
This is an existing-alias preflight, not exclusive publication against destination replacements
after the check; concurrent external filesystem changes remain outside that guarantee.

## Develop focus loss

Previously, a held Space/M/D/Command-D mode could receive its key-down in Develop and lose its
key-up to Settings or another application. Rejecting foreign-window input correctly protected
Settings but could leave Develop showing a temporary comparison or hand tool after return.

The owning-window resign-key and application resign-active notifications now release held input.
Rejected foreign key events also release temporary modes and remain unconsumed. Input monitor
registrations, the current image and sticky section-mute choices survive. Before/whole-Develop
release uses the existing preview observers; selected-layer/global release explicitly refreshes
the restored preview. Interrupted zoom/pan commits its visible values as the next gesture anchor,
so returning to Develop does not start from the old completed-gesture viewport.

## Verification

All 62 focused tests in six suites passed. The final full regression passed 4,357 tests
in 422 suites: 4,355 passed, two existing skips and zero failures (141.075 seconds reported
by Swift Testing). Final repository validation and whitespace checks passed.

Final Xcode result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_19-02-15-+0200.xcresult`.
 The new export suite uses real JPEG files and exact
source-byte/metadata checks for same-directory delivery, SDR/HDR in-place refusal, legacy JPEG,
file/directory symlink and hard-link aliases, independent replacement and same-folder Save As.
Coordinator tests cover retained monitor registrations, editable render projection and sticky
section choices after release, image identity and the next pan/pinch anchor.

Live Render & Sign and focus/gesture smoke tests, representative storage and export timing,
interoperability and final signed release qualification remain open. The most recent native
QA reconnect failed with `Sky Computer Use native pipe closed before response`; synthetic
lifecycle and real-file tests do not replace those live checks. Metal map-full diagnostics
remain unresolved as documented in the preceding continuation.
