# Plan-status source-file import continuation — 2026-08-30

## Scope and checklist result

This continuation implements three more code-only slices from the v3.0 Phase 3.1 filesystem audit:
Code Replacement source/bookmark loading, Metadata Quick List file creation, and Develop color-LUT import.
The changes advance the broad async-boundary and immutable-result items without completing the remaining
filesystem inventory, real-volume measurement, or Thread Performance Checker exit conditions, so the audit
remains **63 of 75 complete**.

## Code Replacement source and bookmark owner

`CodeReplacementSourceService` now serializes security-scoped bookmark creation/resolution, mapped source
reads, modification-date reads, and parsing away from the main actor. It returns either one immutable loaded
snapshot or typed cancellation evidence naming the last completed non-preemptible stage. Bookmark bytes remain
separate from Codable settings and stale bookmarks are refreshed only after the source has been read.

`CodeReplacementSettingsStore` owns operation tasks and request identities, cancels selection/reload
replacement and source removal, rejects stale publication, and begins restored-source loading asynchronously.
The settings view awaits explicit selection and reload operations. Existing fail-closed configuration behavior,
sanitized source errors, and bookmark separation remain intact. The focused Code Replacement selection passed
**30 tests** across three suites.

## Metadata Quick List creation owner

The Metadata panel no longer calls `FileManager.fileExists` or `String.write` when the user chooses a new Quick
List file. `QuickListFileCreationService` serializes the existence probe and conditional atomic empty-file
commit, returning immutable existing-file, pre-commit cancellation, or durable-commit evidence. The panel owns
task and request identity, cancels superseded or disappearing work, and rejects stale completion while retaining
the prior best-effort managed-list behavior if external file creation fails. Six focused tests cover off-main
execution, existing-file preservation, serialization, both cancellation boundaries, and the view source contract.

## Develop color-LUT import owner

User-selected `.cube` reads now cross the serialized `ColorLUTImportService` actor instead of calling
`Data(contentsOf:)` from `EditWorkspaceView`. Immutable results distinguish cancellation before the read from
cancellation observed after a non-preemptible read, and cancelled results never expose LUT bytes for publication.
The workspace owns request identity and task lifetime, cancels replacement, image navigation, and disappearance,
and checks identity before parsing, publishing errors, or committing a layer update. Security-scoped access,
parser validation, display-name selection, and edit-commit behavior are preserved. Four focused tests cover
off-main reads, serialized queued cancellation, post-read cancellation evidence, and the view source contract.

## Integrated validation

A fresh build of the complete application and unit-test targets succeeded:

```text
xcodebuild build-for-testing -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-v3-session-final CODE_SIGNING_ALLOWED=NO
** TEST BUILD SUCCEEDED **
```

The combined implementation selection passed **40 tests in 5 suites** without exclusions:

```text
/private/tmp/aagedal-v3-session-final/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_12-22-18-+0200.xcresult
```

The unfiltered current-source run passed **1,672 tests in 193 suites** in 44.922 seconds of Swift Testing
runtime:

```text
/private/tmp/aagedal-v3-session-final/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_12-21-24-+0200.xcresult
```

The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature, SwiftUI
background-publication, file-watcher, and fixture-decoding diagnostics. They did not produce a build or test
issue.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work includes the remaining direct
filesystem inventory and lower-priority store/import/export paths; its exit gate still requires local SSD,
network-volume, iCloud-placeholder, read-only, and large-folder measurements plus Thread Performance Checker
evidence. Phase 4.1 still includes crop, layer, white-balance, broader render-policy/publication, export, and
persistence ownership.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing plus supported-macOS validation.
