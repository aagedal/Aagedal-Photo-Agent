# Edited export IPTC integrity continuation — 2026-10-18

This continuation prioritizes correct embedded metadata in the core edited-image workflow.
It adds no controls to the main UI and makes no unmeasured speed claim.

## Changes

Develop's Save action previously invoked the renderer with only a source-metadata copier.
It bypassed the shared pending JSON/XMP overlay, pending-orientation admission and artifact
finalization. Save now calls `EditExportPipeline.renderItem` with the captured metadata folder
and live Develop settings. Existing export-session ownership, cancellation admission, output
directory handling and thumbnail invalidation remain in place. Copy or overlay failures feed
the existing metadata warning.

Rendered overlays also flattened typed list items into comma-separated strings. A real JPEG
reproduction turned `Washington, D.C.` into two keywords, `Doe, Jane` into two people and
organisation names/codes into separate values. Both pending JSON and physical XMP reproduced
the problem, including incorrect legacy IIM keywords as well as XMP arrays.

An optional typed list payload now carries exact keyword, person and organisation list items
through the native writer. Only fields included in the field map acquire write authority.
An explicit empty array clears a list; absent typed values retain legacy text-field parsing.
The shared overlay mapping supplies the payload for JSON, XMP and FTP's explicit sidecar sync.
Complete-record writes also use their captured typed lists before synchronizing IIM into XMP,
so the two carriers retain the same item boundaries.

## Verification

The baseline real-file regression reproduced twelve failed field assertions across JSON and
XMP populated-list cases; explicit clears passed. All 58 focused tests in four suites passed
after the fix. The final full regression passed 4,332 tests in 417 suites: 4,330 passed,
two existing skips and zero failures, in 136.308 seconds. Repository validation and whitespace
checks passed.

Final result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_17-56-30-+0200.xcresult`.
Existing MDB_MAP_FULL runtime diagnostics are not resolved by this work.

Coverage includes edited JPEG and TIFF format exports, PNG Save As, both sidecar carriers,
populated and explicitly cleared lists, raw IIM and XMP readback, unchanged source bytes and
retained pending drafts. Direct writer coverage checks field scope, explicit typed clears and
unchanged legacy comma parsing. Complete pending writes check IIM/XMP carrier agreement.
Develop Save has a routing regression guarding use of the
shared pipeline and copy/overlay failure accounting.

## Remaining qualification

Native Save interaction after this change, representative large RAW/HDR files, local/network/
iCloud volume timing, external-tool interoperability and signed release qualification remain
open. The prior native automation backend outage prevents claiming a live Save-button smoke
test; a reconnect attempt reproduced `Sky Computer Use native pipe closed before response`.
Synchronous export-side sidecar selection still needs a filesystem-worker boundary for slow
volumes. Export's existing visible-warning policy for metadata failures is preserved; this work
does not redefine such artifacts as fully metadata-qualified output.
