# Plan-status filesystem and transient-preview continuation — 2026-08-30

## Scope and checklist result

This continuation implements three Phase 3.1 filesystem slices and one Phase 4.1 Develop state-owner
extraction. It advances the broad open gates without completing their remaining inventory, real-volume,
manual, or architectural exit conditions, so the app-improvement audit remains **63 of 75 complete**.

## Keyword-list backup filesystem owner

Keyword backup inventory, snapshot/prune enumeration, restore reads, and restore writes now cross the
serialized `KeywordListBackupFileService` actor rather than performing synchronous Foundation work from
the MainActor service or SwiftUI sheet. Inventory and restore results are immutable and distinguish complete
loads, cancelled prefixes, cancellation after a non-preemptible read, and cancellation observed after a
durable coordinated commit. The sheet owns request identities and tasks, cancels superseded or disappearing
work, rejects stale completion, and presents loading and retained restore feedback. Store observers receive
the same change notification after an actor-owned restore commit.

Five new actor/view characterizations plus the five existing backup-preview tests cover off-main execution,
actor serialization, queued cancellation, post-read cancellation, durable-after-cancel evidence, sorting,
and stale-result contracts.

## Team roster export filesystem owner

Team roster PDF and text writes now cross `TeamRosterExportService`, a serialized actor that returns evidence
for every requested artifact. A result preserves committed byte counts, write failures, pre-write cancellation,
cancellation observed after a durable commit, and batch partial success. Existing PDF write options, atomic
UTF-8 text writes, save panels, and informative `NSAlert` error details are preserved. The editor owns task and
request identity, cancels superseded/disappearing exports, and cannot publish an old result. Six new focused
tests cover off-main execution, serialization, both cancellation boundaries, partial success, and UI wiring.

## Remove All IPTC sidecar preflight

The destructive Remove All IPTC confirmation no longer probes every possible XMP sidecar synchronously on
the main actor. `FileSystemService` returns an immutable sidecar-presence snapshot with requested and checked
counts plus complete/cancelled status, checks cancellation around each non-preemptible existence probe, and
short-circuits at the first match. The browser cancels replaced work and requires both matching request identity
and the original current selection before presenting either destructive confirmation path. Four new
characterizations cover early-match evidence, off-main execution, cancellation during a blocked probe, and the
stale-selection source contract.

## Develop transient-preview owner

`DevelopTransientPreviewCoordinator` now owns M-key Before comparison, D-key whole-Develop mute, Command-D
Global/selected-mask mute, image/workspace teardown, and the render-only settings projection. Selected-mask
comparison no longer temporarily disables the editable mask model. Repeated key-down retains the original
target, D release is independent of modifier-release order, and RAW sources retain their tonemap-only fallback.
Five new tests characterize image-session cleanup and the selected-mask, Global, section/Develop, and RAW
projections.

## Integrated validation

A clean build of the complete application and unit-test targets succeeded:

```text
xcodebuild build-for-testing -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-v3-continuation CODE_SIGNING_ALLOWED=NO
** TEST BUILD SUCCEEDED **
```

The combined touched selection passed **40 tests in 5 suites**:

```text
/tmp/aagedal-v3-continuation/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_10-55-01-+0200.xcresult
```

The unfiltered current-source run passed **1,646 tests in 188 suites** in 40.423 seconds of Swift Testing
runtime:

```text
/tmp/aagedal-v3-continuation/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_10-55-11-+0200.xcresult
```

The complete `scripts/ci/validate_repository.sh` gate passed generated-document checks, release metadata,
JSON/plist/project validation, bundled-component provenance, logger and investigation privacy checks,
conflict-marker scanning, and whitespace validation. `git diff --check` passed. The host emitted the previously
documented App Intents/KVS, LMDB map-size, detached-signature, and SwiftUI background-publication diagnostics;
they did not produce a build or test issue.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work includes Settings C2PA
certificate I/O, keyword/structured-keyword export writes, broader roster and approved-list stores, code-
replacement source loading, and other lower-priority direct filesystem paths. Phase 4.1 still includes sticky
Develop section mutes, crop/layer/white-balance interaction, broader render/clean-feed publication, export
presentation, and persistence ownership.

Manual/external gates remain protected release-branch configuration; Known People privacy/legal review; real
FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
actual local/network/iCloud/read-only/large-folder Thread Performance Checker captures; Instruments RAW/HDR
memory benchmarks; and production AuraFace publishing plus supported-macOS validation.
