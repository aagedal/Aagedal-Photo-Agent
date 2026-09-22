# Cycle 100 — retained keyword references and missing-ledger model floor

Baseline: `45c5ed1`, clean. State remains **IMPLEMENTING**; no whole release gate is closed.

## Implemented behavior

- Read-only metadata template previews now resolve canonical `{field:keywords}` from the
  retained exact photo snapshot. Joining, recursive field handling and bounds match the
  production interpolator. Keyword template-field writes still require separate Approved
  Keywords authority and remain refused.
- First signed Whisper release acceptance or installation now refuses model-scoped content
  and staging artifacts when its authenticated ledger is absent. The check runs before a
  legitimate first install stages bytes, so that install can publish its ledger. This
  prevents a common lost-ledger reset of the accepted release floor. It does not reconstruct
  authority from model bytes.

An attempted recovery-only path for an originally empty app-history file was removed after
integration testing showed that such a file cannot pass the existing source ownership check.
Changing that admission rule would need a separate ownership design. Empty XMP restoration
from Cycle 99 remains intact.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). Fixtures use disposable
metadata, model bytes and signing keys. The final source state is the four application/test
files in this cycle, before the documentation commit.

- Focused template retry: **19 tests / one suite passed**; `build/qa-v3-cycle100-template-retry.log`.
- Final complete regression: **3,428 tests / 353 suites passed**, zero failures, 87.352 seconds;
  `build/qa-v3-cycle100-full-final.log`. An earlier integrated run found the invalid
  empty-app-history fixture and a first-install preflight placement error; both were
  resolved before this final run.
- Repository validation and whitespace checks passed; `build/qa-v3-cycle100-repository-final.log`.
  The actual built MCP helper passed persistent pipes, pipelining, malformed-input recovery,
  provider discovery and honest executor boundaries; `build/qa-v3-cycle100-helper.{log,json}`.
- Independent review found no remaining correctness or security blocker in this bounded
  diff. It confirmed the missing-ledger recovery gap below. No new native UI workflow or
  production-server test is claimed by this cycle.

## Remaining before final release

1. An interrupted *first* Whisper install that leaves model-scoped bytes but no ledger now
   fails closed. Provide an authenticated monotonic external recovery authority and a safe
   cleanup/retry path. Finish production signed descriptors, Settings/download integration,
   offline/GPU acceptance and source distribution/rebuild evidence.
2. Complete the guarded MCP commit boundary, authoritative Approved Keywords writes,
   production template/face-scan/transcription executors and real-client workflows.
   Unreceipted XMP mutation remains refused; broader native restoration and embedded-write
   preservation remain open.
3. Complete authentic Sony, external metadata, cloud/FTP/SFTP, accessibility,
   display/HDR/solar, performance and recovery evidence, qualified privacy/legal review,
   protected release CI and exact signed/notarized candidate acceptance.
