# Cycle 102 — recovery receipts, urgency previews, and Analysis run isolation

Baseline: `4779741`, clean. State remains **IMPLEMENTING**; no whole 3.0 release gate is newly closed.
The integrated run tested this baseline plus the six source/test file changes described below.

## Implemented

- XMP recovery refuses verified publication until both the XMP and app-history installed-carrier
  receipts are durable. Unreceipted staging and XMP-only publication retain their unresolved journal.
- Read-only metadata template previews resolve retained `{field:urgency}` from an integer/null effective
  metadata snapshot. A malformed source or template that changes the referenced field is refused.
- Analysis runs now bind progress, terminal status and task-handle cleanup to a unique run ID. A
  superseded analyzer cannot publish over or cancel its replacement.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). Tests used disposable
files and the normal signed app/helper build. No user photos or model downloads were used.

- Analysis focused suite: 81 tests, zero failures,
  `/private/tmp/aagedal-v30-runner-race/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.23_13-06-36-+0200.xcresult`.
- XMP recovery focused suite: 17 tests, zero failures,
  `/private/tmp/apa-xmp-recovery-agent/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.23_13-05-53-+0200.xcresult`.
- Template preview, signed Whisper runtime and MCP helper focused suites: 91 tests, zero failures,
  `build/qa-v3-cycle102-focused.{log,xcresult}`.
- Serial integrated suite: **3,438 tests / 353 suites**, zero failures, 139.937 seconds,
  `build/qa-v3-cycle102-full-signed.{log,xcresult}`.
- Repository validation and whitespace checks passed after the documentation update,
  `build/qa-v3-cycle102-repository-final.log`.

An exploratory integrated run disabled code signing and exposed a test fixture error for the new
integer field. The fixture was corrected. That run's signed-runtime checks could not pass on an
unsigned helper. The subsequent affected suites and complete suite passed with normal signing;
`build/qa-v3-cycle102-full.{log,xcresult}` is not passing release evidence.

## Remaining before final release

1. Define authenticated recovery for carrier mutation interrupted before its first installed receipt;
   complete guarded helper commit and verified embedded-write preservation, with broader native
   interruption cases.
2. Finish authoritative Approved Keywords, contextual template variables, production metadata,
   Develop, face-scan and transcription executors, cancellation, and real-client workflows.
3. Supply production Whisper signing key and catalog endpoint; connect Settings/Caption lifecycle and
   qualify source distribution/rebuild, offline operation, GPU paths and recognition. Lost-ledger
   recovery still requires external monotonic authority.
4. Close authentic Sony, external metadata, cloud/FTP/SFTP, accessibility, display/HDR/solar,
   performance, recovery, protected CI and qualified privacy/legal evidence gates.
5. Verify the exact signed/notarized candidate, complete final user acceptance, and obtain publication
   authorization. AI-origin detection remains conditional; llama.cpp remains deferred to 3.1.
