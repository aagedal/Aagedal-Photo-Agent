# Plan-status existing-XMP transaction continuation — 2026-09-05

## Scope and result

This continuation advances Phase 3.1 without closing its broad filesystem or real-volume gates.
The audit remains at 66 of 75 completed substeps, with nine remaining.

Metadata's single-image embedded write and variable-processing embedded write no longer probe XMP
existence on MainActor before deciding whether to mirror descriptive metadata. The existing serialized
XMP transaction accepts an `onlyIfExisting` policy and returns whether a record was installed. Its
per-photo lock owns the source read, merge, revision comparison, atomic installation, and read-back.
An absent sidecar returns false; an explicit dual write retains its normal creation behavior. Every
revision retry rechecks existence, so an external deletion observed before installation does not cause
an existing-only operation to recreate the sidecar. The single-image owner uses the returned result
for its existing Camera Raw fallback and UI bookkeeping. Writes retain the established coordinator's
run-to-completion behavior after entry.

Compare's replacement-image lookup now uses direct URL equality against the availability snapshot
that supplied the replacement URL, removing redundant symlink resolution for each candidate. Broader
Compare/Analysis identity preparation remains open: it requires coordinated rename-event ordering,
revision/case relocation, and stale-publication guards rather than an isolated async lookup.

## Validation

Three added regression tests cover absent-sidecar skipping versus explicit creation, preservation of
Develop settings with transaction work off MainActor, and external deletion during a revision retry.
The focused descriptive-write and Compare selection passed all 45 tests in two suites. Independent
sub-agent review found no actionable correctness issues. `scripts/ci/validate_repository.sh` passed.

The serial unfiltered suite passed all 2,038 tests in 234 suites with zero failures in 68.301 seconds.
Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_18-13-41-+0200.xcresult` in Xcode DerivedData.
Two unused-result compiler warnings were then removed by explicitly discarding the new transaction
result in existing full-record and Camera Raw wrappers; the focused selection was rerun after that cleanup.

## Remaining work

Metadata's batch mirror preflight, full-record batch read-modify-write paths, JSON baseline reads,
and sidecar deletion still need complete transaction-owned async boundaries. Known People database
cache-miss/reload migration and shared Compare/Analysis rename identity preparation remain open.
Local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library, signpost and Thread
Performance Checker evidence is still required. Phase 3.2 retains its representative RAW/HDR
Instruments benchmark.

Other release gates remain protected-release-branch enforcement, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and production
AuraFace publishing plus model-omitted release packaging and supported-macOS install/offline/update/
rollback/removal/interrupted-or-corrupt-download drills.
