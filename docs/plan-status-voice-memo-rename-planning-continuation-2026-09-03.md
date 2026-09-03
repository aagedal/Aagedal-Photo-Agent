# Plan-status voice-memo rename-planning continuation — 2026-09-03

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Browser batch-rename entry no longer enumerates and decodes
hidden voice-memo relationship records on MainActor. The audit remains at 66 of 75 completed substeps, with nine
remaining.

## Serialized relationship planning

`VoiceMemoRenamePlanningService` accepts one immutable request containing request identity, folder identity, and
the in-memory rename inputs. Its actor serializes relationship-record enumeration and JSON decoding, then returns
an immutable snapshot with either complete evidence, an exact cancelled prefix, or an exact failed prefix plus a
sanitized user-facing message.

The underlying repository read is synchronous and individually non-preemptible, so cancellation is checked before
and after every selected item. A cancellation observed after a read does not commit that item's artifacts into the
reported prefix. The service's privacy-safe signpost records only result state and aggregate item counts; it never
records a path or filename.

## Browser publication lifetime

`BrowserViewModel` now builds rename contexts entirely from its in-memory image snapshot and delegates companion
planning to the serialized service. Starting a replacement plan or folder load cancels and invalidates the old
request, and deinitialization cancels outstanding work.

The Browser validates request identity, folder identity, current folder, and the exact current selection before it
opens the rename sheet. Only a complete snapshot with the expected item count is publishable. Cancelled and partial
snapshots remain diagnostic evidence, while a current failed snapshot preserves the existing error presentation.

## Characterization and validation

Four new characterizations prove that relationship planning is serialized away from MainActor, a pre-cancelled
request performs no repository read, cancellation after a non-preemptible read reports the exact uncommitted
prefix, and the Browser rejects completion after selection replacement. Two existing companion-planning tests now
await the intentionally asynchronous sheet or error publication.

The adjacent voice-memo persistence, rename planning, rename sheet state, and rename execution selection passed all
66 tests in four suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,936 logical tests in 226 suites, representing 2,063 expanded
device/configuration executions, with zero failures in 61.025 seconds. Result bundle:
`build/AagedalPhotoAgent-VoiceMemoRenamePlanning-Retry-2026-09-03.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
