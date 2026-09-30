# Cycle 105 — removal witnesses and recovery history reconciliation

Baseline: `9554fa8`, initially clean. Implementation commit: `e25940b`.
State remains **IMPLEMENTING**; no whole 3.0
release gate is newly closed. Two implementation agents and an independent reviewer
worked on the recovery and history slices; the parent integrated and validated them.

## Implemented

- Restoration of an originally absent XMP or app-history carrier now retains its exact
  published inode as an exclusive same-parent removal witness. Before rename, the
  journal binds its device/inode, size/modification generation, unique witness name and
  rooted parent identity. Rename and parent synchronization precede its receipt.
- An interrupted removal can resume only with the exact no-follow, single-link witness,
  exact candidate bytes, unchanged source/peer generations and current authorization.
  Absence alone remains insufficient. Pre-rename interruption can retry without
  overwriting or deleting a foreign collision. Replaced/missing witnesses, changed
  parents, links and reappearing carriers refuse restoration.
- Removal receipts retain cleanup evidence in unresolved journal version 12. Explicit
  restoration retries validate all retained witnesses before further carrier mutation.
  Cleanup verifies and removes only the admitted generations, synchronizes each parent,
  and rechecks absence before version 8 records completed restoration. A crash after
  physical cleanup but before that receipt can retry idempotently.
- Operation History reconciles only an opaque disposition issued from the exact resolved
  recovery journal while its transaction lock is retained. A matching uncertain terminal
  IPTC operation gets a separate restored/unchanged marker and receipt digest; its
  original publication outcome stays unchanged. Resolved records can be explicitly
  removed to free capacity, retaining the recovery receipt and live metadata.
- Refresh and native publication retry the receipt-to-history handoff before another
  journal can replace the evidence. Released owner locks are reconciled first; live
  owners remain protected. Already removable failed/cancelled publication records
  require no uncertainty marker. Legacy or unrelated IDs are never matched by inference.
  The registry itself now refuses removal of unresolved uncertain records. Native
  feedback distinguishes completed recovery from a failed history-storage handoff.
- The bundled helper compiles the shared recovery evidence types. Its exposed tool
  surface and mutation authority are unchanged.

## Verification

Environment: arm64 macOS 27.0.1, Xcode 27.0, Debug 3.0.0 (739). Tests use
disposable local metadata fixtures; no user-photo mutation, model download or remote
write was performed.

- Focused final run: **176 tests / 9 suites**, zero failures, 19.558 seconds,
  `build/qa-v3-cycle105-focused-v3.{log,xcresult}`. Selection covers recovery store and
  service, publication/preflight, operation history/registry/coordinator, native plan
  review and server core. Two later store-only schema-validation parameter cases are
  covered by the final integrated run below.
- Serial integrated suite: **3,481 tests / 354 suites**, zero failures, 154.783 seconds,
  `build/qa-v3-cycle105-full-serial.{log,xcresult}`. This includes the final removal-journal
  schema cases. The host emitted the previously observed `MDB_MAP_FULL` diagnostics
  without a failing test. Xcode also recorded four QoS priority-inversion warnings in
  `CaptionSessionTests` and `MetadataEditorReadServiceTests`; those tests passed.
- Native UI target builds, `build/qa-v3-cycle105-ui-build.log`. Both actual XCTest
  methods pass: `testAutomationResolvesInterruptedUnchangedXMPStaging` and
  `testAutomationRestoresAppPublicationInterruptedBeforeReceipt`, **2 tests**, zero
  failures, 118.128 seconds, `build/qa-v3-cycle105-ui.{log,xcresult}`.
  They verify explicit recovery, original photo/carrier bytes, truthful original
  history outcomes, a separate restored marker, cancelled removal, confirmed removal,
  byte-identical retained recovery receipts and empty history across relaunch.
- The actual bundled STDIO helper probe passes ten correlated requests, 17-tool
  discovery, malformed-input recovery, argument refusal and zero stderr,
  `build/qa-v3-cycle105-helper.{log,json}`.
- Repository validation and whitespace checks pass,
  `build/qa-v3-cycle105-repository-final.log`.
- Initial focused builds found two test-only Swift Testing macro errors: an omitted
  inner `try` and nested `#require` expansion. Both were corrected before the passing
  run. The first helper probe used an incorrect bundle subdirectory; the successful
  probe uses the verified `Contents/MacOS/photo-agent-mcp` executable.
- Independent review resolved registry removal bypass, arbitrary-digest resolution,
  clean refused/cancelled staging blocking later publication, stale cleanup witness
  admission before remaining app mutation, and abandoned-owner handoff behavior.
  No actionable correctness finding remains in the reviewed slices.

The exact commands are retained at the start of each build/test log. Focused and full
runs use `xcodebuild test`, scheme `Aagedal Photo Agent Tests`, Debug, destination
`platform=macOS`, `-disableAutomaticPackageResolution`, and
`-parallel-testing-enabled NO`; the shared derived-data directory is
`build/qa-v3-whisper-lifecycle-derived`. The UI run uses `test-without-building`,
scheme `Aagedal Photo Agent UI Smoke Tests`, the two method selections above, and
120/180-second default/maximum execution allowances.

## Remaining before final release

1. Finish guarded helper commits, embedded-write preservation and broader native
   interruption/cancellation/accessibility qualification. Originally absent-carrier
   interruption boundaries are injected in automated tests; the two native flows above
   validate unchanged staging and existing-carrier restoration/history integration.
2. Extend keyword authority to iCloud and cooperative list-writer reservations; complete
   production metadata, Develop, face-scan, template and transcription executors.
3. Supply production Whisper signing/catalog authority and connect managed lifecycle
   repair to Settings/Caption; qualify offline/GPU recognition and distribution.
4. Close authentic Sony, external metadata, cloud/FTP/SFTP, display/HDR/solar,
   performance, protected CI and qualified privacy/legal evidence gates.
5. Verify the exact signed/notarized candidate, complete user acceptance and obtain
   publication authorization. AI-origin detection stays conditional; llama.cpp stays 3.1.

Checksums detect journal corruption, not malicious modification by the same account.
Noncooperating filesystem writers remain outside cooperative process reservations.
Physical power-loss durability and broader real-volume recovery qualification remain
release evidence requirements.
