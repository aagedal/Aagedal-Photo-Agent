# Cycle 103 — interrupted XMP recovery, keyword policy, and Whisper setup retry

Baseline: `bb15db2`, clean. Implementation commits: `8b63ca9`, `e807942`, and `46db355`.
State remains **IMPLEMENTING**; no whole 3.0 release gate is newly closed.

## Implemented

- Before an XMP rename, publication now retains the staged file's device, inode, size, and
  modification time in the recovery journal. Native recovery of an interrupted rename requires
  that identity on the rooted live carrier, exact candidate bytes, unchanged source and app-history
  revisions, and current authorization. It then records the live post-rename revision before an
  explicitly reviewed restoration. An unrenamed candidate can still resolve as unchanged.
- Approved Keywords validation now captures an immutable policy and canonical map for an operation.
  Single-value and bulk validation share it, and variable metadata capture uses the same first
  normalized spelling as the managed list cache.
- Settings' **Retry Setup** for an installed Whisper model rechecks the local artifact instead of
  starting another download. **Download Model** still starts an explicit download when absent.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). Tests used disposable metadata
fixtures and local model bytes; no user photos or model downloads were used.

- Managed Whisper setup: 12 tests / one suite passed, `build/qa-v3-cycle103-whisper-approved.{log,xcresult}`.
- XMP recovery and Approved Keywords: 30 tests / two suites passed,
  `build/qa-v3-cycle103-focused.{log,xcresult}`. This includes interrupted XMP restoration with
  originally present and absent sidecars, same-byte external replacement refusal, and unchanged
  pre-rename resolution.
- Repository validation and whitespace checks passed after the documentation update,
  `build/qa-v3-cycle103-repository-final.log`.
- Serial integrated suite: **3,445 tests / 353 suites**, zero failures, 150.579 seconds,
  `build/qa-v3-cycle103-full-serial.{log,xcresult}`.

An exploratory full run used Xcode's default parallel execution and exposed timing failures in
unrelated asynchronous suites. It was interrupted and is not release evidence. The serial run
above used the project's established validation configuration.

## Remaining before final release

1. Pre-receipt app-history mutation and restoration interruptions remain fail-closed. Complete the
   guarded helper commit boundary and broader native interruption cases.
2. MCP keyword writes still need exact managed-list bytes and settings revision at plan and commit;
   complete production metadata, Develop, face-scan, template and transcription executors.
3. Supply production Whisper signing and catalog authority, connect managed lifecycle to Settings
   and Caption, and qualify offline, GPU, source rebuild and recognition behavior.
4. Close authentic Sony, external metadata, cloud/FTP/SFTP, accessibility, display/HDR/solar,
   performance, recovery, protected CI and qualified privacy/legal evidence gates.
5. Verify the exact signed/notarized candidate, complete final user acceptance and obtain publication
   authorization. AI-origin detection remains conditional; llama.cpp remains deferred to 3.1.
