# Cycle 104 — history recovery, keyword authority and signed Whisper repair

Baseline: `44cd592`, clean. Signed Whisper repair is committed as `c028267`;
integrated metadata recovery and keyword changes are committed as `add11b4`.
State remains **IMPLEMENTING**; no whole 3.0 release gate is newly closed.

## Implemented

- Native recovery retains the exact staged generation before app-history publication
  and existing-carrier XMP/app-history restoration. An interruption after rename but
  before its receipt can resume after fresh explicit review, matching rooted identity,
  exact bytes, original source, peer carriers and current authorization. A stage that
  never reached its destination can be abandoned only when receipted carriers remain
  exact. Interrupted unlink of an originally absent carrier stays fail-closed.
- Keyword patch preparation now captures exact local managed-list bytes, file and
  ancestor identities, and effective Approved Keywords settings. GUI and helper share
  parsing, normalization, canonical spelling and bulk duplicate handling. Strict
  user-origin values are refused when unapproved; structured bypass cannot be claimed
  by MCP. Previews retain exact requested values alongside canonical proposed values.
  Retrieval, native review/approval and final draft/XMP/history mutation recheck this
  authority. Helper responses preserve dedicated keyword failure codes. No new MCP
  commit endpoint is exposed.
- The signed Whisper lifecycle can explicitly repair missing current or rollback
  bytes using the exact authenticated retained descriptor. Verified installed bytes
  require no transfer; stale/missing/corrupt authority, another signer and corrupt
  existing content refuse before transfer. Final generation checks prevent publication
  after a concurrent release change. Repair preserves ledger bytes, replay floor and
  rollback intent; it neither accepts a new release nor selects rollback.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). All metadata and
model tests use disposable local files; signed-model tests use disposable signing keys
and injected local transfers. No model downloads, user-photo mutation or remote writes.

- Final focused run: **175 tests / 13 suites**, zero failures, 12.483 seconds,
  `build/qa-v3-cycle104-focused-v3.{log,xcresult}`. Coverage includes strict rejection
  through the MCP response boundary, preview/native canonical parity, list drift,
  byte-identical file replacement, interrupted publication/restoration, empty and
  absent originals, source/peer/authority refusal, signed release repair, concurrent
  generation changes and cancellation.
- Independent review found and resolved stale keyword authority across the asynchronous
  gap between approval and installation. Final policy checks now run at each carrier's
  mutation boundary. Final review reports no remaining actionable correctness finding
  in these slices.
- Initial focused attempts found fixture setup errors for pending history with absent
  XMP, and Foundation's `/var` temporary-path alias. Fixtures now parse their exact XMP
  bytes when the live sidecar is deliberately absent and retain POSIX canonical paths.
  Production no-follow and exact-byte checks were preserved.
- Serial integrated suite: **3,467 tests / 354 suites**, zero failures, 160.382 seconds,
  `build/qa-v3-cycle104-full-serial.{log,xcresult}`. Source is identical to `add11b4`;
  only release/help documentation changed afterward. The host emitted the previously
  observed `MDB_MAP_FULL` diagnostics without a failing test.
- Repository validation and whitespace checks passed,
  `build/qa-v3-cycle104-repository.log`; final documentation validation uses
  `build/qa-v3-cycle104-repository-final.log`.
- The actual bundled STDIO helper protocol probe passed with ten correlated requests,
  successful discovery/argument refusal/malformed-input recovery and zero stderr,
  `build/qa-v3-cycle104-helper.{log,json}`.
- The native UI smoke target builds, `build/qa-v3-cycle104-ui-build.log`, including
  `testAutomationRestoresAppPublicationInterruptedBeforeReceipt`. The XCTest UI method
  was compiled, not executed this cycle; its equivalent native flow was exercised
  through CUA as recorded below.

### Native recovery and persistence

The actual Debug app at
`build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`
was launched with the explicit UI-test fixture arguments and test-process defaults.
No Photo Agent app was running before the drill. CUA operated the native controls;
all fixture originals and receipts remain under `build/qa-v3-cycle104-native/`.

1. Open Settings → Automation, paste the fixture plan ID and inspect it.
2. Verify XMP Dry Run, acknowledge C2PA/preservation and all pending draft values,
   approve the candidate, then publish. The test-only `beforeAppReceipt` hook throws
   after app history is replaced. The UI reports recovery required. Source bytes
   remain unchanged, both metadata carriers differ from their originals, and the
   prepared generation journal has version 10.
3. Clear Review, inspect retained recovery, choose Restore Original Metadata and
   confirm. The UI reports **Original metadata restored**. Photo, XMP and app-history
   bytes exactly equal their originals; the retained restoration journal has version 8.
4. Quit and relaunch, then inspect recovery again. The UI reports **No unresolved XMP
   publication staging is retained**. All original bytes and the restoration receipt
   remain unchanged. Quit the QA app normally afterward.

Result: **pass**. `native-result.json`, `original-hashes.json`, original/published
carrier copies and `restored-journal.json` retain the byte comparison evidence.
The native drill used the focused-final recovery build before the later keyword bulk
parity and helper error-mapping changes; recovery source was unchanged by those changes.
Final keyword behavior is covered by focused-v3 and integrated tests. The reusable native
smoke test for this interruption also builds.

Operation History still retains the interrupted publication's original recovery-required
outcome, labeled Last recorded. Restoration does not rewrite that publication as verified.
History reconciliation/removal is a remaining release UX/capacity gate, including the
256-record limit; the resolved recovery journal governs mutation admission.

## Remaining before final release

1. Finish authenticated originally absent-carrier unlink interruption recovery, history
   reconciliation, guarded helper commits and embedded-write preservation. Broader native
   cancellation/interruption and accessibility cases remain open.
2. Extend keyword authority to iCloud and cooperative list-writer reservations. Settings
   evidence compares current effective content: restoring the same settings can revalidate;
   it is not a historical monotonic settings revision. Complete production metadata,
   Develop, face-scan, template and transcription executors and real-client workflows.
3. Supply production Whisper signing/catalog authority and connect managed release repair
   to Settings and Caption. Missing-ledger recovery still needs external monotonic
   authority. Complete offline/GPU/recognition, source rebuild and distribution qualification.
4. Close authentic Sony, external metadata, cloud/FTP/SFTP, accessibility, display/HDR/solar,
   performance, recovery, protected CI and qualified privacy/legal evidence gates.
5. Verify the exact signed/notarized candidate, complete final user acceptance and obtain
   publication authorization. AI-origin detection remains conditional; llama.cpp stays 3.1.
