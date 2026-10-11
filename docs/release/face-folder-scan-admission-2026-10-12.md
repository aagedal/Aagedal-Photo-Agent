# Complete-folder face-scan admission and outcomes — 2026-10-12

Baseline: `f2794dc` (published Beta 3), initially clean. This continuation changes
development source; it does not replace the published beta. State remains **IMPLEMENTING**.
Implementation: `412e4ae`. Tests exercised those exact source contents before commit;
all nine final Swift source/test hashes match `build/continuation-8/source-sha256.json`.

## Behavior

The native folder scanner now returns shared typed scheduling/refusal and completion
values. Scheduling is not mutation admission: the existing folder reservation must
succeed, then the serialized filesystem service compares the supplied photo set with
the complete immediate supported-image inventory before reset or incremental pruning.
Subset, duplicate, out-of-folder, symbolic-link image and pending-cloud inputs refuse
without changing the saved face document. Hidden supported-image `.icloud` placeholders
also refuse, preserving results for unavailable photos. GUI scan actions filter supported
images so All Files and Media browser visibility do not add videos or other files to
the scan request.

Completion separates detection counts, missing signatures, cancellation and persistence
errors. Failed detections remain incomplete and retryable. A previously incomplete
snapshot whose images already have current signatures is durably completed instead of
only updating presentation. Cancelled classification preserves prior unsigned faces,
groups and jersey numbers. Failed final persistence keeps the GUI incomplete and
suppresses automatic Known People matching and lens work that could obscure the failure.

The folder lease coordinates participating app/helper writers; inventory inspection is
not an atomic snapshot against external filesystem edits. The existing full-reset
semantics remain: cancellation after scheduling can still perform the admitted reset
and then save incomplete results. This change does not expose `start_face_scan`, create
a durable automation operation, silently download a model or grant new mutation authority.

## Verification

Evidence lives under ignored `build/continuation-8/`. Host: arm64, macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a). The existing reviewed AuraFace source package was copied into this
worktree and its pinned bytes verified. No user photos or production authorization changed.

Debug app: `build/continuation-8/Build/Products/Debug/Aagedal Photo Agent.app`, version
3.0.0, build 742. This is a development build of the new source, not the published Beta 3 artifact.

- Focused verification: **39 tests / three Swift suites**, zero failures/skips, 87 expanded
  cases (`focused.xcresult`, `focused-summary.json`, `focused.log`). Swift test execution:
  0.331 seconds. Covers complete-folder refusal before full reset and incremental pruning,
  pending placeholders, busy reservations, partial detection, cancellation preservation,
  durable incomplete-snapshot completion and successful-worker failed-save presentation.
- Integrated regression: **3,953 passed, two opt-in Sony skips, zero failures** out of
  3,955 tests / 391 Swift suites, 124.271 seconds (`full.xcresult`, `full-summary.json`,
  `full.log`). Four existing Caption/metadata-read QoS priority-inversion warnings and
  test-host `MDB_MAP_FULL` diagnostics remain observations; performance gates stay open.
- Native workflows: **two passed**, zero failures/skips (`native-face.xcresult`,
  `native-face-summary.json`, `native-face.log`). Complete-folder scanning of two generated
  JPEGs saves both signatures and completion, displays the completion control, and retains
  byte-identical saved face data after relaunch (23.629 seconds). Explicit jersey-rescan
  cancellation creates no face-data directory (12.822 seconds). Known People uses an empty
  disposable root; browse-bar expansion uses process-only defaults. These synthetic images
  qualify zero-face scan/persistence behavior, not recognition accuracy on real subjects.
  Native results also report two “This method should not be called on the main thread”
  runtime warnings; performance qualification remains open. All test app instances were
  stopped after teardown, confirmed through the desktop inventory.
- Repository validation, final bundled-model validation and development signature verification
  pass (`repository-final.log`, `model-bundle-final.log`, `signature-final.log`).
- Actual persistent STDIO helper: **35 tools**, valid discovery/argument refusals, zero stderr
  (`mcp-helper-final.json`). No face-scan endpoint is advertised.
- Independent implementation, final-source and evidence-scope review pass. Review findings
  about All/Media input filtering, cloud placeholders, cancellation preservation, failed-save
  presentation and hover-sensitive native assertions were corrected before final verification.

The first sandboxed build could not resolve dependencies; approved network/compiler-cache
access completed the build. Xcode result extraction also required report-cache access.
An early signature check ran before signing finished; another overlapped the integrated
build's resource signing and refused. The final post-native-build signature verification
passes. No failed test assertion was weakened.

Commands (all use the same derived-data directory):

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-8 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-8/full.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-8/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

The focused command adds selectors `ActivityHistoryTests`, `FaceFolderScanContractTests`
and `FaceScanFileSignatureServiceTests` under `Aagedal Photo Agent Tests` and uses
`focused.xcresult`. Native testing switches to scheme `Aagedal Photo Agent UI Smoke Tests`,
selects `CoreWorkflowSmokeTests/testCompleteFolderFaceScanPersistsAcrossRelaunch` and
`CoreWorkflowSmokeTests/testExplicitJerseyScanCancellation`, and uses `native-face.xcresult`.

## Remaining work

Connect these production contracts to authenticated rooted folder authority, durable
operation admission/progress/cancellation and the MCP `start_face_scan` executor. Native
whole-workflow, actual cloud/device, accessibility and broader release gates remain open.
