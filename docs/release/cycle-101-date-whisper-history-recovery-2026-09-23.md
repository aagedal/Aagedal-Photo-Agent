# Cycle 101 — retained date previews, signed Whisper lifecycle, and history recovery

Baseline: `b21ee50`, clean. Implementation commits: `959082b`, `da26a04`, and
`94ec45b`. State remains **IMPLEMENTING**; no whole release gate is newly closed.

## Implemented

- Read-only metadata template previews resolve retained `{dateCreated}` and
  `{dateCaptured}` from the exact effective metadata snapshot. Invalid date sources
  are refused. The MCP helper uses its own bounded parser, so both targets compile.
- An internal Whisper lifecycle bridge verifies a signed descriptor before transfer,
  downloads model bytes, and commits through the existing durable, byte-verifying
  state store. Installed lookup and explicit rollback use that same state boundary.
  Production signing and user-facing integration remain open.
- A native Automation smoke case replaces the app-history carrier atomically with
  identical bytes after the user inspects interrupted XMP publication. Restoration
  refuses the changed carrier identity, retains the candidate XMP and recovery
  journal, and preserves that refusal across relaunch.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). Tests used
disposable photos, isolated recovery storage, and disposable model bytes/signing keys.

- Date preview focused suite: 23 tests passed, zero failures,
  `build/qa-v3-template-date-focused-2.{log,xcresult}`.
- Whisper state-store focused suite: 34 tests passed, zero failures,
  `build/qa-v3-whisper-lifecycle-derived/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.23_11-29-40-+0200.xcresult`.
  The integrated run below includes the new lifecycle test.
- Native same-byte history replacement: one UI test passed, zero failures, 51.231
  seconds, `build/qa-v3-cycle101-history-replacement-ui.{log,xcresult}`.
- Integrated unit suite: **3,435 tests / 353 suites**, zero failures, 140.944
  seconds, `build/qa-v3-cycle101-full.{log,xcresult}`. The host emitted the known
  `MDB_MAP_FULL` diagnostics without a failing test.
- Repository validation and whitespace checks passed,
  `build/qa-v3-cycle101-repository-final.log`.

An exploratory native zero-byte original XMP fixture failed during setup: effective
automation metadata reads require a complete RDF document, so this source cannot
enter publication review. The fixture experiment was removed. Existing unit tests
still cover restoration of an originally empty XMP carrier from synthetic recovery
material. Two exploratory UI results in `build/qa-v3-cycle101-empty-xmp-*` are not
passing evidence.

## Remaining before final release

1. Define authenticated policy for XMP mutation interrupted before a durable
   installed-carrier receipt, then complete guarded helper commit and verified
   embedded-write preservation. Broader native interruption cases remain.
2. Finish authoritative Approved Keywords, other contextual template variables,
   production metadata/Develop/face-scan/transcription executors, cancellation and
   real-client workflows.
3. Supply production Whisper signing key and catalog endpoint, connect Settings and
   Caption lifecycle, and qualify source distribution/rebuild, offline operation,
   GPU paths and recognition. Lost-ledger recovery still needs external monotonic
   authority.
4. Close authentic Sony, external metadata, cloud/FTP/SFTP, accessibility,
   display/HDR/solar, performance, recovery, protected CI and qualified privacy/legal
   evidence gates.
5. Verify the exact signed/notarized candidate, complete final user acceptance, and
   obtain publication authorization. AI-origin detection remains conditional;
   llama.cpp remains deferred to 3.1.
