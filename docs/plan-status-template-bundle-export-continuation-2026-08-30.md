# Plan-status template, bundle-planning, and export continuation — 2026-08-30

## Scope and checklist result

This continuation implemented three independent code-only slices from the v3.0 app-improvement audit. Metadata
template import preview and voice-memo bundle collision planning advance the broad Phase 3.1 filesystem boundary,
while a new Develop export coordinator advances Phase 4.1 state ownership. These slices do not complete the
remaining filesystem inventory, real-volume measurement, or broader Develop layer/render-policy/persistence exit
conditions, so the audit remains **63 of 75 checklist substeps complete**.

## Metadata-template import preview boundary

Settings no longer reads a selected metadata-template bundle and inventories current templates synchronously on
the main actor. `TemplateImportPreviewService` serializes the complete preview operation and returns immutable
prepared, cancelled-before-read, or cancelled-after-read evidence. Post-read cancellation reports only counts and
identity; it cannot publish the decoded template payload.

`TemplateViewModel` owns the preview task and request identity, cancels replacement or dismissal, and rejects stale
success and error publication. Template DTOs and storage are explicitly nonisolated so Codable and filesystem work
can legally execute on the actor under the app target's default MainActor isolation. Focused tests cover completion,
both cancellation boundaries, actor serialization, replacement, stale-result rejection, and the source contract.

## Import voice-memo bundle collision planning

`ImportViewModel` no longer performs repeated `FileManager.fileExists` probes while its main-actor import setup
chooses a shared image/WAV conflict suffix. It freezes lightweight bundle requests and awaits
`ImportPreflightService`, whose existing actor now resolves primary and optional backup destinations as one unit.

The actor returns immutable complete or cancelled evidence with the exact completed prefix. The caller rejects
cancelled, incomplete, or stale evidence before duplicate/overwrite preflight or any destination mutation. Shared
suffix behavior, RAW/JPEG memo deduplication, copy prerequisites, skip semantics, and backup mirroring are preserved.
Tests cover a shared primary/backup suffix, pre-cancellation with zero probes, and reset-time rejection of a blocked
late plan.

## Develop export state owner

`DevelopExportSessionCoordinator` is the named MainActor owner for one-at-a-time Develop export presentation,
workspace lifetime, request identity, task cancellation, busy/error state, and durable output evidence. Rendering,
directory creation, and metadata-copy policy remain injected at the existing persistence boundary.

The persistence result distinguishes a completely saved image from a durable image whose metadata-copy leg failed.
Workspace disappearance invalidates every late success or failure; appearance begins a fresh lifetime, including
when SwiftUI reuses the coordinator. The save button, format label, renderer, metadata copier, thumbnail invalidation,
and existing user-facing warning text retain their behavior. Four characterizations cover single-flight ownership,
durable metadata-warning evidence, teardown against an uncooperative late failure, and view delegation.

## Integrated validation

A clean build of the complete application and unit-test targets succeeded:

```text
xcodebuild build-for-testing -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-v3-template-import-export-integration \
  CODE_SIGNING_ALLOWED=NO
** TEST BUILD SUCCEEDED **
```

The combined implementation selection passed **36 tests in 4 suites**:

```text
/private/tmp/aagedal-v3-template-import-export-integration/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_20-04-58-+0200.xcresult
```

The first unfiltered run exposed two source contracts that still expected the former view-owned export shape and
one export-coordinator polling deadline under full parallel load. After reconciling the contracts and using the
suite's existing 30-second long-load diagnostic ceiling, the next run exposed the same scheduler starvation in the
new template replacement test. Its polling ceiling was reconciled without adding a sleep or slowing the success
path. The final unfiltered run passed **1,844 expanded test-case runs across 198 suites** in 42.980 seconds:

```text
/private/tmp/aagedal-v3-template-import-export-integration/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_20-08-30-+0200.xcresult
```

`scripts/ci/validate_repository.sh` passed generated-document checks, release metadata, JSON/plist/project
validation, bundled-component provenance, logger and investigation privacy checks, conflict-marker scanning, and
whitespace validation. The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature,
SwiftUI background-publication, and file-watcher diagnostics; none produced a build issue or final test failure.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable work remains in lower-priority synchronous template
load/save/delete/export/import-commit and other filesystem paths, plus broader Develop layer, render-policy, and
persistence ownership. Phase 3.1 still requires local-SSD, network-volume, iCloud-placeholder, read-only-volume,
large-folder, signpost, and Thread Performance Checker evidence.

Manual and external gates remain protected release-branch configuration; focused Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
