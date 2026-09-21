# Cycle 89 — native operation history and stopped-owner recovery

Baseline: `94b8847`, initially clean. Status remains **IMPLEMENTING**.
Implementation commits: `ee576d2` (Whisper removal) and `172b68c` (operation history/recovery).
The application/test sources were validated together before local commits; later edits only
corrected a native-test selector and updated release documentation. No broad release gate closes.

## Implemented behavior

Settings → Automation → **Operation History** now presents retained operation IDs, kinds,
timestamps and outcomes without photo paths or field values. Refresh reads current evidence on a
serialized filesystem executor. Cancellation is explicitly a request until an executor confirms
an outcome. A refresh failure preserves the last records, labels them potentially stale and
disables mutation controls until a successful refresh.

Confirmed removal is available only for definite terminal outcomes. It removes the coordination
record, not metadata or pending drafts, allowing bounded archive capacity to be reused. Unfinished,
partial/uncertain and recovery-required records remain protected. No automatic eviction is added.

New native executors enroll an exclusively created per-owner lock and retain its kernel lease
through execution and drained shutdown. Opening or refreshing history can acquire only abandoned
owners' released locks, then marks their unfinished managed records `recoveryRequired` while
preserving cancellation evidence. The archive transaction retains those locks through durable
publication. Live owners, legacy records and missing lock evidence never imply stopped work.
Unsafe lock paths and clock rollback refuse reconciliation. No writes are replayed or repaired.
Lock filenames remain reserved permanently to prevent an old owner identity from being reused.

Managed Whisper removal now opens and validates the cache directory before deleting relative to
its retained descriptor. Removing an already absent cache succeeds without creating storage;
linked ancestors and directory-shaped model entries remain protected. Cancellation before effects
preserves the installed bytes. This does not implement signed updates or model rollback.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug app 3.0.0 (739).
App path: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures use generated JPEGs and isolated private operation/model directories. Every UI-test
launch now isolates history, including launches without patch-review fixtures.

- Focused checks: **45 tests / four suites pass**, 1.066 seconds, zero issues.
  `build/qa-v3-cycle89-focused-allowed.{log,xcresult}` covers history, operation registry/coordinator
  and Whisper download/removal. The first sandboxed build could not write Xcode caches; the
  authorized build used normal Xcode caches and macOS test services.
- Complete integrated regression: **3,278 tests / 342 suites pass**, 112.929 seconds, zero failures.
  Evidence: `build/qa-v3-cycle89-full.{log,xcresult}`.
- Native stopped-owner workflow passes in **30.054 seconds**. The fixture holds a real process
  lock with a running/cancellation-requested record. Refresh preserves live status; actual process
  termination/relaunch changes it to recovery required with no removal control or work replay.
  Evidence: `build/qa-v3-cycle89-native.{log,xcresult}`.
- The first native draft/history run reached the removal sheet but its unscoped Cancel selector
  also matched the Touch Bar. The selector was corrected to the sheet; application behavior and
  production source were unchanged. The corrected rerun passes in **42.245 seconds**, verifying
  explicit apply, unpublished-draft status, cancellation of removal, confirmed removal, unchanged
  draft/source/XMP state and relaunch persistence. Evidence:
  `build/qa-v3-cycle89-native-removal-rerun.{log,xcresult}`.
- Repository validation passes: `build/qa-v3-cycle89-repository.log` and final tracked-file/documentation validation
  `build/qa-v3-cycle89-repository-final.log`.
- Actual embedded helper persistent-pipe probe passes all 15 advertised tools and honest executor
  boundaries: `build/qa-v3-cycle89-mcp-probe.{log,json}`. No mutation tool is added.
- Independent review checked lock lifetime, live-owner refusal, recovery retention, cancellation,
  stale presentation and removal semantics. It found and corrected a test-isolation issue before
  integrated validation. CUA observed the running app's empty Browser; native XCTest supplies the
  concrete interaction/relaunch assertions.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'`, Debug,
`-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, the unit/native schemes and
named result bundles. Focused suites: `AutomationOperationHistoryTests`,
`AutomationOperationExecutionCoordinatorTests`, `AutomationOperationRegistryTests`, and
`WhisperModelDownloadServiceTests`. Native selectors: `testAutomationHistoryRecoversStoppedOwnerAfterRelaunch`
and `testAutomationPatchAppliesOnlyToPendingDraft`. Repository validation uses
`scripts/ci/validate_repository.sh`; the real helper uses `scripts/ci/probe_mcp_helper.py`.

## Remaining release work

- Explicit physical write-mode/publication/C2PA consent, carrier preservation/read-back,
  recoverable physical installation and MCP `commit_iptc_patch` remain mandatory.
- Face, metadata/Develop-template and transcription production executors remain unfinished.
- Recovery currently records uncertainty; it does not restore, undo or replay work. Legacy/missing
  owner evidence stays unresolved. Lock-file pruning needs a coordinated protocol; record removal
  deliberately retains lock files. Broader multi-window, interruption-at-write and power-loss
  qualification remains open. Refresh is a snapshot, not confirmed continuous activity monitoring.
- Whisper corresponding-source publication/clean reproduction, signed updates/rollback,
  offline/GPU/audio-format and recognition-quality acceptance remain open.
- Authentic Sony/real-server/cloud evidence, external interoperability, accessibility, display/HDR,
  performance/hardware, qualified privacy/legal review, remote CI protection, final signed/notarized
  candidate and user acceptance remain release gates.
