# Cycle 106 — keyword history, publication requirements and removal recovery

Baseline: `4b1cb86`, initially clean. Implementation commits: `a663846`, `da1959a`, `5bfe016` and `5e897d1`.
State remains **IMPLEMENTING**; no whole 3.0 release gate is newly closed.
Two implementation agents and an independent reviewer worked on separate slices;
the parent owned integration, native UI tests, builds, documentation and commits.

## Implemented

- Approved Keywords authority now binds current settings to a persisted generation
  recorded by cooperating app preference writers. Changing a setting away and back,
  including local/cloud/local routing, invalidates old keyword plans. A pending
  envelope is synchronized before preference mutation, and a ready envelope binds
  all four effective values after synchronization. Failed final synchronization
  reinstates pending evidence. Failed initial synchronization leaves the preference
  unchanged. A synchronized invalid sentinel permits explicit repair of malformed
  old settings without accepting malformed authority. Incomplete, malformed or value-mismatched history
  refuses authority. The helper refreshes CFPreferences before copying settings and
  history together; double capture refuses generation changes during inspection.
- Legacy preferences without history remain explicitly untracked. Read-only previews
  do not initialize or repair history. Existing Strict-mode canonical spelling,
  duplicate handling and iCloud refusal remain enforced. Opaque generations cover
  cooperating app writers, not arbitrary preference editors or malicious rollback.
- The helper exposes `inspect_iptc_patch_publication_requirements`, accepting only an
  exact `planID`. It binds the immutable plan digest, expiry, authorization and every
  photo/carrier revision under the photo reservation, then rechecks outer descriptor
  and ancestor admission. Its 16 KiB result reports the XMP target, pending-draft
  consequences and required native publication gates. It stages no candidate,
  transports no consent, creates no operation/recovery record and grants no writes.
  `commitAvailable` and native preflight/approval evaluation remain explicitly false.
- Native recovery qualification now includes originally absent XMP and app-history
  removals interrupted after witness rename but before their first restoration
  receipt. Explicit UI-test relaunch retains only the disposable fixture's exact
  authorization. Production launches cannot enable these hooks. Cancel preserves
  the witness and journal; confirmed retry verifies retained evidence, finishes both
  carrier restorations, removes all witnesses and retains a completed receipt.
  Operation History preserves the original recovery-required outcome with a separate
  restored marker; cancelled/confirmed record removal and another relaunch retain
  the exact receipt and original photo bytes.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug
3.0.0 (739). App path: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Final integrated code: `5e897d1`; final tests ran on identical implementation
bytes before its commit. Native tests ran on `5bfe016`; the later correction changes
only keyword preference-history mutation, outside those native recovery workflows.
All photo, metadata, preference and recovery inputs are disposable synthetic fixtures;
no user-photo mutation, model download or remote write was performed.

- Initial focused tests: **128 tests / 9 suites**, zero failures, 3.868 seconds,
  `build/qa-v3-cycle106-focused-v2.{log,xcresult}`. Includes both new suites
  `MCPKeywordSettingsHistoryTests` and `MCPIPTCPatchPublicationRequirementsTests`,
  plus keyword snapshots/preparation, helper core, keyword store, native plan review
  and UI launch configuration. Covers changes away/back, CFPreferences parity,
  all synchronization failure boundaries, malformed/mixed history, read-only tool
  annotations, arguments, same-byte replacement, newly created XMP, revoke/regrant,
  busy reservations and expiry.
- Final affected focused tests after the pending-sync review correction: **82 tests /
  8 suites**, zero failures, 7.567 seconds, `build/qa-v3-cycle106-focused-v3.{log,xcresult}`.
  Adds first-sync/all-sync refusal without preference mutation and explicit malformed
  settings repair; includes native publication admission and plan review regressions.
- Native UI target builds: `build/qa-v3-cycle106-ui-build.log`. Both actual XCTest
  methods pass, **2 tests**, zero failures, 154.575 seconds,
  `build/qa-v3-cycle106-ui.{log,xcresult}`:
  `testAutomationResumesAbsentHistoryRemovalAfterRelaunch` (78.235 seconds) and
  `testAutomationResumesAbsentXMPRemovalAfterRelaunch` (76.340 seconds).
- Serial integrated suite: **3,498 tests / 356 suites**, zero failures, 154.517 seconds,
  `build/qa-v3-cycle106-full-serial-v2.{log,xcresult}`. The initial integrated run
  passed 3,496 tests / 356 suites in 172.050 seconds before the final correction. The host emitted the previously
  observed `MDB_MAP_FULL` diagnostics and 12 Thread Performance Checker QoS
  priority-inversion warnings without a failing test. These remain observations;
  this cycle does not close the performance gate.
- The actual bundled STDIO helper passes 11 correlated requests, **18-tool** discovery,
  malformed-input recovery, strict argument refusal and zero stderr,
  `build/qa-v3-cycle106-helper-final.{log,json}`. Helper SHA-256:
  `9a05e6ecb25694fb34bbf9ec52b5290ca1f036666dde3bab0db6e04d0e624311`.
- Repository validation and whitespace checks pass,
  `build/qa-v3-cycle106-repository.log` and `build/qa-v3-cycle106-repository-final-v2.log`.
- Independent review found a ready-history envelope could survive a failed final
  preference synchronization. The implementation now reinstates pending evidence;
  tests cover failures at all three boundaries. Final review also required refusing
  preference mutation when initial pending synchronization fails; this is corrected
  with refusal/repair tests and revalidation. No actionable correctness finding
  remains in the reviewed slices.
- The initial sandboxed focused command could not write existing Swift/Xcode caches.
  The authorized normal Xcode retry succeeded; this was an execution restriction,
  not an application test failure. UI logs contain the previously observed AppKit
  display-rectangle and debugger lookup diagnostics without failing a test.

Exact Xcode commands are retained at the start of the logs. Focused/full commands use
`xcodebuild test`, scheme `Aagedal Photo Agent Tests`, Debug, `platform=macOS`,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`. The native
command uses `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
the two method selections above, and 120/180-second execution allowances. Shared
derived data is `build/qa-v3-whisper-lifecycle-derived`. The helper probe command is
`python3 -B scripts/ci/probe_mcp_helper.py '<app>/Contents/MacOS/photo-agent-mcp' --output build/qa-v3-cycle106-helper-final.json`.

## Remaining before final release

1. Build an authenticated native-consent/executor handoff before exposing helper
   commits. Process-lifetime app consent cannot be inferred from the new digest or
   requirement result. Embedded preservation, broader interruption/cancellation,
   real-volume recovery and accessibility qualification remain.
2. Add cooperative managed-list writer reservations and iCloud keyword authority;
   qualify actual independent-process preferences and power-loss behavior. Complete
   production metadata, Develop, face-scan, template and transcription executors.
3. Supply production Whisper signing/catalog authority and connect managed repair
   to Settings/Caption; qualify offline/GPU recognition and distribution.
4. Close authentic Sony, external metadata, cloud/FTP/SFTP, display/HDR/solar,
   performance, protected CI and qualified privacy/legal evidence gates.
5. Verify the exact signed/notarized candidate, complete user acceptance and obtain
   publication authorization. AI-origin detection stays conditional; llama.cpp stays 3.1.

No new Release candidate was built. Cooperative reservations do not constrain
noncooperating filesystem writers. Checksums and preference generations are not
protection against malicious modification by the same account; actual physical
power-loss durability remains a release evidence requirement.
