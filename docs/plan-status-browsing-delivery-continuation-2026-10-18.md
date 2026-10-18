# Browsing cache and metadata delivery continuation — 2026-10-18

This continuation prioritizes browsing correctness and reliable edited-image delivery.
It adds no main-window controls. The keyboard preview and shortcut editor remain in Settings.

## Changes

Edited-thumbnail invalidation now cancels and removes the in-flight old-settings producer,
so a new request cannot join it and its late result cannot repopulate the cache. Existing
request identities keep old consumer cleanup from removing the replacement request.

Folder-return reconciliation includes the already-scanned XMP modification date, including
sidecar removal, alongside source size and modification time. External XMP changes can affect
both edited pixels and original-preview orientation. Only changed URLs lose their cached
variants; unchanged images remain reusable across navigation. This adds no filesystem probes
to the reconciliation loop. It detects timestamp changes, not timestamp-preserving edits.

The shared export pipeline now records copy failures per item as well as in the batch report.
Render & Sign and edited FTP preparation use a delivery boundary that throws after artifact
finalization if metadata copy or pending-IPTC overlay reported a failure. These files never
enter signing/upload queues. The rendered pixels remain locally recoverable and source drafts
remain available. An earlier failed image, including another image with the same basename,
does not disqualify a later successful render. Local Save/Export retains its useful-file plus
warning policy. A stale-XMP warning with newer embedded metadata remains a successful delivery.

## Verification

All 33 focused tests in two suites passed. They exercise a gated stale producer,
real XMP change/removal with unchanged source size/time, unchanged-cache identity,
copy-only/overlay-only/combined faults against real JPEG renders, readable retained pixels,
unchanged source/draft, successful pending-list delivery after same-name batch failures,
and stale-XMP success under the strict delivery policy. Read-only call-site review confirmed
that rendered FTP and both C2PA signing branches consume only guarded return values.

The full regression passed: 4,346 total, 4,344 passed, two existing skips and zero failures,
in 419 suites (146.744 seconds reported by Swift Testing). The Xcode result bundle is
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_18-30-24-+0200.xcresult`.
The final wording correction also compiled and passed the same 33 focused tests in two suites.
Repository validation and whitespace checks passed on the final source changes.
All 11 final FTP filesystem-preparation and transport-acknowledgement tests in two suites
also passed. No real FTP network connection was used.

## Remaining qualification

The guard blocks reported copy/overlay failures; it does not add a complete independent
metadata readback audit, change the existing metadata-selection fallback policy, or make the
whole render atomic with external editors. RAW DNG archival conversion is separate from the
rendered delivery paths. No end-to-end browsing/export speedup, real FTP server delivery,
large-RAW/network/iCloud timing, or final signed release qualification is claimed. Native
shortcut invocation and Develop Save interaction remain open after the earlier native
automation backend outage. Existing MDB_MAP_FULL runtime diagnostics are unresolved.
