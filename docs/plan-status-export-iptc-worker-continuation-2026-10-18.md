# Export IPTC filesystem worker continuation — 2026-10-18

This continuation addresses core export responsiveness while retaining the existing metadata
selection, partial-record and warning policies. No main-window controls are added.

## Changes

After rendering, the overlay previously loaded app JSON and physical XMP synchronously on
MainActor. Its stale-sidecar comparison also performed synchronous file-date probes there.
Only the embedded metadata read held the source photo's metadata lease.

`ExportIPTCSelectionService` now performs this selection on a retained serial Dispatch
executor. The source lease covers JSON, XMP, embedded metadata and reconciliation facts in
one selection, preventing app-managed carrier updates from interleaving with it. The
coordinator explicitly hops back to the filesystem actor for the synchronous snapshot.
The selected metadata is an immutable value; the source lease ends before the destination
writer acquires its own lease.

Pending JSON still wins over physical XMP, including empty/partial pending records that must
stop fallback. Nonpending history may fall through to XMP. Develop-only XMP is ignored;
rating/label-only records no longer trigger an embedded-container read or file-date probes.
Descriptive XMP retains the existing stale-sidecar reconciliation and read-failure behavior.
Post-render selection is not abandoned solely because the caller was cancelled: existing
writer cancellation and overlay failure outcomes remain truthful for already-created pixels.

## Verification

Focused worker tests cover actual executor ownership, task-local propagation and a gated
read while MainActor continues executing. Competing reads serialize, source selection waits
for an admitted source transaction and observes its committed draft, and a real JPEG overlay
onto the same source URL completes without retaining a nested source lease. Precedence,
minimal partial-record reads, stale/nil-embedded behavior and cancellation/empty-draft outcomes
are also covered. Existing real JPEG/PNG/TIFF export tests retain metadata value/clear coverage.

All 41 focused tests in three suites passed. The final full regression passed 4,342 tests
in 418 suites: 4,340 passed, two existing skips and zero failures, in 143.909 seconds.
Repository validation and whitespace checks passed. The initial verification caught and
corrected a test-only async thread-assertion API restriction and a log-privacy validation issue.

Final result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_18-13-50-+0200.xcresult`.
Existing MDB_MAP_FULL runtime diagnostics are not resolved by this work.

## Remaining qualification

No end-to-end export speedup or real network/iCloud/large-RAW timing is claimed from synthetic
blocked-I/O tests. Native interaction, representative volume timing, Instruments/memory evidence,
interoperability and signed release qualification remain open. A selection lease does not make
the entire export atomic relative to changes between the earlier metadata-copy phase and this
snapshot, nor does it coordinate external applications that ignore the app's leases. Existing
read-failure fallback and visible-warning policies are unchanged.
