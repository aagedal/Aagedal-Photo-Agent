# Cycle 98 — native restoration, list fields and rollback content

Baseline: `1747bf9`, initially clean. Three sub-agents handled independent recovery,
template/native UI and model work. The coordinator integrated changes, added native smoke
coverage and an operation-lifecycle fix, and owns validation and commits. State remains
**IMPLEMENTING**. No whole release gate is newly closed.

## Implemented behavior

Automation Settings now offers **Restore Original Metadata…** for interrupted publication
whose photo and installed metadata generations still match retained evidence. A separate,
one-use confirmation binds to the inspected review. Reinspection, path changes, cancellation
and dismissal invalidate it. Execution reserves the photo, refuses selected metadata editors,
and rechecks authority, journal and carrier identities before mutation.

Restoration reinstalls original XMP/app-history bytes or removes files that were originally
absent through retained directory descriptors. Restoration progress and completion use distinct
version-7/version-8 journal payloads. A durable XMP restoration receipt can resume without
rewriting that generation; completion is not misreported as successful publication. Receipt
replay, version relabeling, same-byte external replacement and stale review are refused.
Original photo bytes remain unchanged. Empty original carriers and interruption after mutation
but before receipt persistence remain unresolved. The app-history directory itself is retained.

Template previews now resolve six canonical retained list field references: Person Shown,
creators, organisation names/codes and scene/subject codes. Comma-space joining matches the
production interpolator, preserves list order, and checks the 32 KiB limit before allocation.
Recursive scalar/list dependencies are reported; cycles, modified source fields, malformed
values and unsupported contextual variables remain refused. Approved Keywords and production
template application remain open.

The signed Whisper state store now restores missing rollback-candidate content under its
existing authenticated ledger, without selecting the candidate, consuming rollback or changing
the replay floor. Correct bytes are verified and staged exclusively; existing corrupt files
are preserved and refused. This remains an internal API; production signed catalog and Settings
integration are not complete.

The operation coordinator now closes an unsolicited cancelled executor result conservatively
as failed or recovery-required according to possible effects. It no longer leaves a running
record behind after the retained executor exits.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
Fixtures are generated disposable photos/model bytes/signing keys. Native launches isolate
automation roots and history; no user photos or production recipients are used.

Initial sandboxed Xcode execution could not write compiler caches. Approved elevated execution
restored access. Two early builds encountered in-progress shared-checkout edits; verification
was restarted after source freeze. Independent reviews found and resolved a helper-target type
dependency, a potentially blocking FIFO open, a misplaced service method and restoration receipt
progression/version separation. Review found no remaining blocking defect within this bounded
change; this is not a whole-candidate audit.

Implementation commits: `87279a8` (rollback content), `649925c` (list references),
`cc0dc16` (operation lifecycle) and `ec4a738` (native restoration and tests).
Application and test sources in the final native/full runs match `ec4a738`; only documentation
follows that revision.

- Focused integrated verification passes **107 tests / eight suites**, zero failures, 4.018 seconds:
  `build/qa-v3-cycle98-focused-final.{log,xcresult}`. The separately added confirmation suite was
  initially outside the explicit Xcode source list; it was moved into the existing recovery test file.
- Confirmation-model verification passes **four tests / one suite**, zero failures, 0.157 seconds:
  `build/qa-v3-cycle98-confirmation-retry.{log,xcresult}`. The first included run exposed a fixture
  that held its installation reservation while requesting inspection; releasing it fixed the fixture.
- Complete regression passes **3,419 tests / 353 suites**, zero failures, 83.997 seconds:
  `build/qa-v3-cycle98-full.{log,xcresult}`. Application/test sources match `ec4a738`.
  Existing test-host `MDB_MAP_FULL` diagnostics recur without failing a test.
- Native retry passes **three workflows**, zero failures, 132.978 seconds:
  `build/qa-v3-cycle98-ui-retry.{log,xcresult}`. Covers unchanged staging, confirmation cancellation,
  successful originally absent XMP restoration, same-byte XMP replacement refusal, preservation
  of journal/photo/peer metadata, and persistence across relaunch. Teardown removes fixtures and
  terminates the QA app. Existing-original and both-carrier restoration also have unit evidence;
  their broader native cases remain open.
- The first native attempt failed all three tests during app activation, before recovery interaction:
  `build/qa-v3-cycle98-ui.{log,xcresult}`. A CUA exact-app lookup then took approximately 192 seconds
  before desktop access returned. After a normal app-menu quit attempt, retry restored native test execution.
  No host protection was bypassed and no shared service was reset.
- Repository validation and whitespace checks pass: `build/qa-v3-cycle98-repository-final.log`.
  Checklist JSON has 39 unique cases with existing source links; human outcomes remain unrun.
- Actual helper persistent pipes, pipelining, malformed-input recovery, discovery and honest executor
  boundaries pass: `build/qa-v3-cycle98-helper.{log,json}`. SHA-256:
  `c6b229b4bd50d4c13838cfdd0d971e6af07cbd891fe54164019167acff157d9e`.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3` with the unit/UI smoke schemes,
`scripts/ci/validate_repository.sh`, `git diff --check` and `scripts/ci/probe_mcp_helper.py`.
App: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.

## Remaining before final release

1. Finish unreceipted/empty-carrier recovery policy and broader native restoration cases, then
   guarded helper commit and embedded-write preservation. Native smoke does not replace those gates.
2. Finish authoritative Approved Keywords, remaining contextual variables, production metadata/
   Develop template, face-scan and transcription executors, cancellation and real-client workflows.
3. Configure production signed Whisper descriptors and Settings/download lifecycle, missing-ledger
   and partial-orphan recovery, source distribution/rebuild and offline/GPU/recognition qualification.
4. Complete authentic Sony, external metadata interoperability, real cloud/FTP/SFTP, accessibility,
   display/HDR/solar, performance and recovery evidence. Qualified privacy/legal review and protected
   release CI remain external dependencies.
5. Verify the exact signed/notarized candidate, complete final user acceptance and obtain publication
   authorization. AI-origin detection remains conditional; llama.cpp remains deferred to 3.1.
