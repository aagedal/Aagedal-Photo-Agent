# Concurrent edited-export reservations — 2026-10-18

This continuation prevents overlapping edited exports from encoding or overlaying IPTC onto
one another's destination. It adds no main-window controls.

## Changes

Numbered names previously came from a `fileExists` loop. Separate Develop Save/batch operations
could both select a free name. FTP cancel/restart was more direct: cancellation does not drain
an already-detached renderer, and legacy JPEG delivery always reconstructed the same fixed
output filename before sequencing it after rendering.

`ExportOutputReservationOwner` now admits a destination before encoding. Numbered allocation
uses exclusive, no-follow file creation; occupied or actively claimed names advance the suffix.
Process claims cover stable parent-resolved paths, existing symlink targets, case aliases and
regular-file device/inode identity. Existing hard-linked output aliases therefore cannot enter
concurrent replacement. JPEG and PNG siblings keep distinct names/claims. Explicit replacement
of an independent inactive output remains available; replacing an active artifact reports busy.

Each source-aware renderer retains its owner through encoding and metadata copy. The shared
pipeline retains it through pending IPTC overlay and artifact finalization, then awaits utility
worker cleanup on success or error. Standalone renderer entry points explicitly run concurrently
off MainActor. Filesystem operations and cleanup run outside the short namespace bookkeeping
mutex, and unrelated outputs/cleanup do not wait for a blocked destination's provider access.

Cleanup holds the original placeholder descriptor and removes only the same empty regular-file
inode. Encoded bytes and foreign replacements survive. Ordinary creation permissions follow the
process umask. Legacy JPEG now returns its actual reserved URL and honors the pipeline's collision
policy, so cancelled/restarted delivery cannot reconstruct and reuse a still-owned fixed path.

## Verification

The initial focused build passed 48 tests in three suites. The final full regression, including
the added hardlink and worker-cleanup coverage, passed 4,370 tests in 423 suites: 4,368 passed,
two existing skips and zero failures (144.773 seconds reported by Swift Testing). Final repository
validation and whitespace checks passed.

Final Xcode result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_19-24-22-+0200.xcresult`.

Allocator tests exercise concurrent contenders, case/directory aliases, format siblings, busy
replacement and later release, failure/retry, owned empty cleanup, retained encoded and foreign
files, final-symlink atomic replacement, hardlink output aliases and independent progress during
blocked filesystem admission/cleanup. The cleanup gate verifies MainActor responsiveness.

Real JPEG integration gates the first pending-IPTC overlay while a second format/JPEG/Save As
export completes with its own exact metadata. Active replacement is rejected without mutation,
then becomes available immediately after completion. Another test cancels the parent while its
detached JPEG producer is still in metadata copy and verifies restart chooses a distinct filename.
Source preservation and metadata-failure recovery tests remain part of the regression.

## Remaining qualification

Reservations isolate cooperating in-process writers; exclusive creation also prevents competing
numbered creators from choosing the same occupied path. They do not provide a durable transaction
or a complete-image publication boundary for arbitrary external programs that ignore claims.
Adobe DNG conversion remains unchanged. FTP generation-specific progress/state and real network
behavior require separate qualification. Native shortcut/Save/signing interaction, representative
storage/export timing, interoperability and final signed release gates remain open. The preceding
native automation connection failure and Metal diagnostics remain unresolved.
