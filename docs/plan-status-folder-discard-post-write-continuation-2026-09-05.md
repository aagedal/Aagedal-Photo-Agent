# Plan-status folder discard and post-write cleanup continuation — 2026-09-05

## Scope and result

This continuation advances Phase 3.1 and the release plan's filesystem/recovery work.
The audit remains at 66 of 75 completed substeps; broad inventory and measured release gates
remain open.

Folder-wide app-sidecar discard now removes the directory through an asynchronous folder
barrier in `MetadataIOCoordinator`. The barrier waits for admitted photo operations in the
same direct parent folder; later photo operations wait for the barrier. Sibling folders remain
independent. Cancellation prevents entry, while admitted work runs to completion. The editor
waits for its preceding save and only resets current state when folder, selection, load request,
draft, and batch mutation intent still match. Failures preserve the editor and report an error;
successful batch discard clears common-value caches and captured mutation intent.

Single-image Write and Clear and folder pending writes now capture both current and legacy
sidecar bytes before writing, then conditionally delete under the photo lock. A changed byte
snapshot survives cleanup; batch writes also reject a stale pending record before writing.
Single-image cleanup compares the actual loaded or installed sidecar metadata/history, rather
than the display metadata with its orientation/Camera Raw overlays and trimmed history. Unknown
baselines and newer edits are retained. Unreadable or newer-schema preflight documents are left
in place. Cleanup conflicts and failures surface instead of silently claiming successful removal.
The unused synchronous deletion helper was removed.

Image/XMP writes and JSON deletion remain separate commits. A cleanup failure can therefore
leave a completed image write and a retained JSON sidecar. Directory removal and multi-file
cleanup are not rollback transactions; an operating-system error may leave partial durable
removal. External processes do not share app locks, so the final revision-check-to-delete interval
is not an OS-level compare-and-swap guarantee.

## Validation

New regressions cover folder barrier ordering, independent sibling folders, off-main deletion,
pre-admission and admitted cancellation, stale folder/draft/batch-intent completion, failure and
batch-cache reset, unchanged post-write cleanup, current/legacy/newly created revisions, stale
preflight records, unreadable JSON preservation, and cleanup cancellation/storage failures.

Two sub-agents implemented folder discard and reviewed the cleanup slice. Review led to capturing
the Camera Raw baseline before suspension, guarding stale and cancelled publication, and retaining
the exact persisted sidecar baseline. An initial build caught a nested Swift Testing macro expansion;
that test now records its asynchronous result before asserting it. An intermediate full run passed
2,068 tests in 236 suites. A later 2,069-test run exposed an incorrect fixture assumption that
EXIF orientation persists in JSON. The executable regression now checks the actual Camera Raw
overlay difference and successful sidecar deletion; the implementation did not change for that
assertion correction. Final validation is recorded below.

Final validation:

- Serial unfiltered run: **2,069 tests in 236 suites passed**, zero failures, 63.176 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_21-37-45-+0200.xcresult`
in Xcode DerivedData. Final log: `/private/tmp/aagedal-discard-final-verified.log`.
Repository validation log: `/private/tmp/aagedal-discard-repository.log`.
Automated results do not substitute for manual and real-volume gates.

## Remaining work

Known People database cache-miss/reload migration and shared Compare/Analysis rename identity
preparation remain open. Phase 3.1 also requires local SSD, network-volume, iCloud-placeholder,
read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
retains the representative RAW/HDR Instruments benchmark.

Other release gates remain protected-release-branch enforcement, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace
model-omitted release candidate plus supported-macOS production-server install/offline/update/
rollback/removal/interrupted-or-corrupt-download drills. Production model publication was already
completed; this continuation does not claim those external validation passes.
