# App improvement audit plan

**Status:** implementation in progress — 28 of 75 checklist substeps complete
**Created:** 2026-08-24  
**Baseline reconciled:** 2026-08-25  
**Scope:** application, tests, release process, bundled artifacts, and user-facing documentation  
**Non-goal:** this document does not claim that any unchecked item has been implemented or manually validated

## Outcome

Improve Photo Agent without weakening its strongest existing properties: explicit plans before destructive
work, atomic persistence, metadata preservation, privacy-aware delivery evidence, strict concurrency, and a
large deterministic test suite.

The recommended order is risk-based. Phase 0 should pre-empt feature work because its items can lose or
resurrect user data. Phase 1 makes releases reproducible and auditable. Later phases improve user trust,
accessibility, responsiveness, and maintainability.

## Audit baseline

The evidence blocks below describe the original audit findings; checked implementation work may have
removed the cited behavior or moved the cited lines.

- A fresh isolated `build-for-testing` succeeded on 2026-08-24. The latest repository validation
  record reports 1,413 logical tests passing across 155 suites after the Command-S export-safety
  integration; this audit reconciliation did not rerun the test bundle.
- The project has only the app and unit-test targets; there is no UI-test target.
- At the original audit baseline, the only GitHub Actions workflow published the backup appcast; the
  checked Phase 1.1 work below has since added build-and-test CI.
- The worktree was already modified before this audit. This plan is a new file and does not alter app code.

**Checklist reconciliation (2026-08-25):** the status count is exact: 28 of 75 substeps are checked and
47 remain open. Each checked substep links to dated validation. A baseline current-source and
validation-record review found no definitive evidence that another unchecked substep was already complete;
partial foundations such as the existing bookmark lifecycle tests, accessibility semantics, bounded image
caches, and focused concurrency coverage do not satisfy their broader manual, system-level, or
cross-workflow exit gates.

## Phase 0 — Stop silent data loss and destructive surprises

### 0.1 Make synced deletions durable before deleting local data

**Priority:** P0  
**Evidence:**

- Tombstone encoding/write errors are suppressed in
  `Aagedal Photo Agent/Services/KnownPeopleService.swift:402-407`, followed by destructive work at
  `:613-630` and `:798-806`.
- The same pattern appears in `RosterStore.swift:207-212,252-257` and
  `WatermarkStore.swift:308-313,341-346`.

**Plan:**

- [x] Make tombstone creation throwing and verify the installed marker can be decoded.
  ([validation](durable-synced-deletion-validation.md), 2026-08-25)
- [x] Abort deletion/merge if the marker cannot be made durable.
  ([validation](durable-synced-deletion-validation.md), 2026-08-25)
- [x] Delete thumbnails and derived caches only after the record/tombstone transition succeeds.
  ([validation](durable-synced-deletion-validation.md), 2026-08-25)
- [x] Share one tested deletion-transaction abstraction across Known People, Teams, and Watermarks.
  ([validation](durable-synced-deletion-validation.md), 2026-08-25)
- [x] Surface a recoverable error rather than presenting a successful deletion.
  ([validation](durable-synced-deletion-validation.md), 2026-08-25)

**Exit gate:** injected encode/write/remove failures leave the original record usable; a simulated peer cannot
resurrect a successfully deleted record; interrupted merges have a documented recoverable state.

### 0.2 Make all one-shot migrations fail closed and retryable

**Priority:** P0  
**Evidence:**

- Known People embedding migration logs backup failure, then still clears data and stamps the new version at
  `KnownPeopleService.swift:865-887`.
- Legacy keyword parsing and writes use `try?`, but the global completion stamp is always set at
  `KeywordListsStore.swift:325-365`.

**Plan:**

- [x] Require a complete, read-back-verified backup before resetting incompatible embeddings.
  ([validation](one-shot-migration-recovery-validation.md), 2026-08-25)
- [x] Stamp the embedding version only after backup and reset both succeed.
  ([validation](one-shot-migration-recovery-validation.md), 2026-08-25)
- [x] Record keyword migration completion per list/key, retaining retry state for failures.
  ([validation](one-shot-migration-recovery-validation.md), 2026-08-25)
- [x] Preserve source bookmarks until each corresponding import is verified.
  ([validation](one-shot-migration-recovery-validation.md), 2026-08-25)
- [ ] Show a plain-language recovery notice naming the affected category without exposing private values.

**Exit gate:** disk-full, permission, unavailable security scope, corrupt input, and iCloud-placeholder tests
prove that no source is cleared or permanently skipped after a failed migration.

### 0.3 Add an overwrite preflight to photo ingest

**Priority:** P0  
**Evidence:** overwrite is selectable at `Views/Import/ImportView.swift:518-537`; import begins at `:919-924`;
the service can replace both primary and backup destinations at
`Services/ImportCopyService.swift:157-200,380-393` without an exact collision confirmation.

**Plan:**

- [x] Keep Rename as the safe default.
  ([validation](import-overwrite-preflight-validation.md), 2026-08-25)
- [x] Preflight primary and backup destinations and show exact collision counts and destination roots.
  ([validation](import-overwrite-preflight-validation.md), 2026-08-25)
- [x] Require an explicit **Replace N existing files** confirmation immediately before the first write.
  ([validation](import-overwrite-preflight-validation.md), 2026-08-25)
- [x] Allow cancellation after preflight with zero destination mutations.
  ([validation](import-overwrite-preflight-validation.md), 2026-08-25)
- [x] Include replaced/skipped/renamed counts in the durable import result.
  ([validation](import-overwrite-preflight-validation.md), 2026-08-25)

**Exit gate:** collision counts match execution for both legs; cancellation writes nothing; UI tests prove that
Overwrite cannot begin without explicit confirmation.

### 0.4 Serialize complete sidecar read/merge/write transactions

**Priority:** P1, but schedule with Phase 0 because the impact is lost edits.  
**Evidence:** XMP and JSON services separately read, merge, and replace at
`XMPSidecarService.swift:118-183,290-296` and `MetadataSidecarService.swift:255-287`; caption and metadata
workflows can write independently (`CaptionSession.swift:13-16`, `MetadataViewModel.swift:1533-1552`).

**Plan:**

- [ ] Introduce a URL-keyed persistence actor for the entire read/merge/history/install transaction.
- [ ] Compare a source revision/content token before install and retry a merge when it changed.
- [ ] Route Caption, Metadata, face, and Develop sidecar writes through the same boundary.
- [ ] Preserve the existing atomic staging, backup, schema, and read-back practices.

**Exit gate:** stress tests overlapping descriptive, face, and Develop writes never lose unrelated fields and
produce deterministic history.

## Phase 1 — Make every release reproducible, tested, and accurately documented

### 1.1 Add continuous integration and a mandatory release test gate

**Priority:** P1  
**Evidence:** `.github/workflows/publish-backup-appcast.yml:19-50` only uploads an appcast;
`scripts/release.sh:308-315` can archive without a test gate; `README.md:268-279` does not require one.

**Plan:**

- [x] Add a macOS workflow that performs a clean `build-for-testing` and unfiltered
  `test-without-building` run.
  ([validation](continuous-integration-release-gate-validation.md), 2026-08-25)
- [x] Run the metadata support generator check, JSON/plist validation, conflict-marker scan, and
  `git diff --check` in CI.
  ([validation](continuous-integration-release-gate-validation.md), 2026-08-25)
- [x] Publish the `.xcresult` and concise test summary on failure.
  ([validation](continuous-integration-release-gate-validation.md), 2026-08-25)
- [ ] Require the workflow on the protected release branch.
- [x] Make `release.sh` require a passing result tied to the exact source revision, with a noisy, recorded
  emergency override.
  ([validation](continuous-integration-release-gate-validation.md), 2026-08-25)

**Exit gate:** a deliberately failing test blocks CI and the normal release path; a stale result from another
commit is rejected.

### 1.2 Create a verified manifest for bundled binaries and models

**Priority:** P1  
**Evidence:** the tracked FFmpeg binary reports 9.0.1, while `README.md:297-302` offers 8.1.1 source. The
approximately 125 MB AuraFace model is ignored (`.gitignore:12-14`), can be absent without failing the build,
and is fetched without a pinned revision/checksum (`Resources/Models/README.md:9-12,25-48`).

**Plan:**

- [ ] Track a manifest containing component version, immutable upstream revision, SHA-256, license, build
  recipe revision, target architecture, and expected runtime capability.
- [ ] Correct the FFmpeg corresponding-source offer and keep it generated from the manifest.
- [ ] Add deterministic fetch/build/verify tooling for AuraFace with a pinned Hugging Face revision.
- [ ] Make release preflight fail on a missing or mismatched required artifact.
- [ ] If a feature is intentionally omitted, compile/package an explicit unavailable state and disclose it in
  release notes rather than silently degrading.

**Exit gate:** two release builds from one source revision resolve identical declared artifacts; modifying or
omitting any artifact fails preflight; shipped source/license claims match runtime versions.

### 1.3 Refresh the security and privacy release boundary

**Priority:** P1/P2  
**Evidence:** `SECURITY.md:3-17` describes only 2.0.x and names Codeberg while linking GitHub;
`:49-53` describes obsolete native SwiftExif dependencies. Sensitive paths/arguments are marked public in
`FFmpegService.swift:35-45`, `FaceDataStorageService.swift:45-66`, `FolderChangeMonitor.swift:143`, and
`BrowserAutoRefreshCoordinator.swift:94`.

**Plan:**

- [x] Update supported versions, reporting destination, response process, and parser/dependency inventory.
  ([validation](security-policy-release-boundary-validation.md), 2026-08-25)
- [x] Add a release check that the security policy covers the marketing version.
  ([validation](security-policy-release-boundary-validation.md), 2026-08-25)
- [x] Inventory all `Logger` calls and classify filenames, paths, face identifiers, metadata, destinations,
  subprocess arguments, and errors by sensitivity.
  ([validation](logger-privacy-and-manifest-validation.md), 2026-08-25)
- [x] Default potentially identifying values to private/redacted and add static tests for prohibited public
  interpolation.
  ([validation](logger-privacy-and-manifest-validation.md), 2026-08-25)
- [x] Audit whether a privacy manifest is required and document the conclusion.
  ([validation](logger-privacy-and-manifest-validation.md), 2026-08-25)
- [ ] Evaluate App Sandbox feasibility; if full sandboxing is impractical, document why and assess a
  constrained XPC/helper boundary for untrusted parsing and bundled tools.

**Exit gate:** a log capture from import, face scan, edit/export, and delivery contains no source path,
filename, editorial value, credential, or private command argument; security documentation matches the ship
candidate.

## Phase 2 — Improve workflow trust and accessibility

### 2.1 Never dismiss or go silent after a failed user action

**Priority:** P1  
**Evidence:** template save errors are caught internally but editors always close
(`TemplateViewModel.swift:23-37,55-59`; `DevelopTemplateViewModel.swift:30-43,60-63`). Initial C2PA detail
read failure is swallowed at `ContentView.swift:2923-2939`.

**Plan:**

- [x] Make save operations return/throw a typed result; dismiss only after durable success.
  ([validation](template-save-recovery-validation.md), 2026-08-25)
- [x] Preserve the draft and show inline Retry/Save As actions on failure.
  ([validation](template-save-recovery-validation.md), 2026-08-25)
- [x] Present C2PA loading immediately, then distinguish absent, malformed, unavailable-tool, access-denied,
  and validation-failed states with Retry.
  ([validation](c2pa-inspector-recovery-validation.md), 2026-08-25)
- [ ] Centralize privacy-safe accessibility announcements for success, failure, cancellation, and recovery.

**Exit gate:** injected failures retain all edits, focus the error, remain keyboard operable, and produce one
useful VoiceOver announcement.

### 2.2 Add a clear face-data and iCloud lifecycle checkpoint

**Priority:** P1, pending legal/privacy review; do not claim a legal conclusion from this audit.  
**Evidence:** the open privacy/legal question remains in `TODO.md` under **Version 2.3**; automatic matching is described at
`SettingsView.swift:567-585`; iCloud can sync reference faces and clothing samples at `:1538-1544`.

**Plan:**

- [ ] Obtain a focused privacy/legal review of Known People, embeddings, thumbnails, clothing samples,
  folder-local face data, export, deletion, and optional iCloud sync.
- [ ] Add first-use plain-language disclosure of on-device processing, persisted data, locations, retention,
  export/delete scope, and optional cloud transfer.
- [ ] Require explicit confirmation before enabling Known People iCloud sync for the first time.
- [ ] Provide a single Data Management summary with counts, storage destinations, export, and deletion paths.

**Exit gate:** a new user can state what is stored locally, what may be uploaded, and how to export/delete it;
copy is reviewed and does not overclaim compliance.

### 2.3 Harden delivery transport decisions

**Priority:** P1/P2  
**Evidence:** plain FTP and disabled verification are available with an inline warning at
`Views/FTP/FTPServerForm.swift:34-69`, but saving does not require acknowledgement at `:87-95`.

**Plan:**

- [ ] Recommend SFTP/verified FTPS by default and visually badge insecure profiles everywhere selected.
- [ ] Require acknowledgement when saving an insecure profile and before its first upload.
- [ ] Record transport and verification state in privacy-safe Activity/receipt evidence.
- [ ] Add real-server drills for FTP, explicit FTPS, and SFTP, including certificate/host-key failures.

**Exit gate:** insecure transport cannot be used accidentally; receipts accurately describe the security mode;
representative server tests cover failure and retry.

### 2.4 Add UI automation and finish manual accessibility validation

**Priority:** P2  
**Evidence:** no UI-test target exists; `docs/manual-release-prerequisite-audit.md:27-29` and
`docs/accessibility-keyboard-audit-validation.md:25-29` list unverified assistive-technology behavior.

**Plan:**

- [ ] Add a small XCUITest smoke target for launch/open folder, import preflight, Caption save, Batch Rename,
  Deadline preflight, and recovery/error states.
- [x] Convert full-screen rating stars and label dots to labelled Buttons.
  ([validation](accessibility-keyboard-audit-validation.md), 2026-08-25)
- [ ] Convert face selection, ingest split cells, scope modes, and copyable metadata rows from gesture-only
  interactions to keyboard/VoiceOver-operable controls.
- [ ] Give Metadata Review failures persistent icons/reasons and accessibility severity, not color/hover alone.
- [ ] Run and record VoiceOver rotor/order, Full Keyboard Access, IME, high contrast, Reduce Motion,
  text/localization stress, window extremes, and external-display Clean Feed.

**Exit gate:** core workflows are completable without a pointing device; every destructive action and async
result is announced once; CI runs the smoke suite; dated manual evidence covers the remaining OS behavior.

## Phase 3 — Improve responsiveness and resource control

### 3.1 Move blocking file work off the main actor

**Priority:** P1  
**Evidence:** default isolation is MainActor (`project.pbxproj:647`); synchronous sidecar work occurs at
`MetadataViewModel.swift:1533-1552`; folder listing/trash/rename/create operations occur at
`BrowserViewModel.swift:2442-2445,2461-2464,2519-2523,2593-2597`.

**Plan:**

- [ ] Put potentially blocking filesystem operations behind async, serialized service boundaries.
- [ ] Return immutable results to the main actor and make cancellation/partial success explicit.
- [ ] Add signposts and benchmarks for local SSD, network volume, iCloud placeholder, read-only volume, and
  large folder cases.

**Exit gate:** Thread Performance Checker finds no blocking file/sidecar work on the main thread in core
workflows; UI remains responsive during slow-volume simulations.

### 3.2 Coordinate image/GPU memory under one budget

**Priority:** P2  
**Evidence:** full-screen cache limits total up to 768 MiB (`FullScreenImageCache.swift:44-52`), while two
full-resolution edit textures can use about 726 MiB for 45 MP files (`MetalEditPipeline.swift:486-493`),
before thumbnails, scopes, masks, and render intermediates.

**Plan:**

- [ ] Create a shared image-memory coordinator across full-screen, Develop, thumbnail, and scope caches.
- [ ] Scale prefetch and limits by source dimensions and available memory.
- [ ] Respond to memory pressure by cancelling speculative work and evicting in a documented order.
- [ ] Benchmark rapid navigation/edit/export of representative large RAW/HDR files with Instruments.

**Exit gate:** the benchmark has an agreed peak-memory budget, no IOSurface/allocation failures, and bounded
recovery after memory pressure.

### 3.3 Profile startup and expensive reactive recomputation

**Priority:** P2  
**Evidence:** app initialization starts several singleton migrations/watchers plus detached precomputation and
network refresh at `Aagedal_Photo_AgentApp.swift:12-45`. Deadline identity re-encodes broad state in response
to general defaults changes at `ContentView.swift:230,237-238,1321-1452`.

**Plan:**

- [ ] Add launch and first-interaction signposts before deciding what to defer.
- [ ] Make startup jobs dependency-ordered, cancellable, and lazy when they are not needed for first paint.
- [ ] Give Deadline an owned typed revision model; ignore unrelated preferences and debounce capture work.
- [x] Add the existing full-screen guidance to turn off edited previews when faster high-resolution loading
  matters, with Retry/Reveal/Copy Details on hard failure (`TODO.md:34-36`).
  ([validation](full-screen-loading-recovery-validation.md), 2026-08-25)

**Exit gate:** recorded cold/warm launch and first-folder metrics meet explicit budgets; unrelated settings no
longer restart Deadline capture; slow high-resolution loads offer actionable recovery.

## Phase 4 — Reduce change risk and distribution size

### 4.1 Split feature monoliths by state ownership

**Priority:** P2  
**Evidence:** `EditWorkspaceView.swift` is 9,051 lines, `ContentView.swift` 3,827,
`BrowserViewModel.swift` 3,722, `MetadataViewModel.swift` 3,475, and `FaceRecognitionViewModel.swift` 3,185.
`EditWorkspaceView` alone owns versioning, decode/render, layer/mask tools, export, and navigation.

**Plan:**

- [ ] Extract state-owning coordinators such as Develop session, versions, masks, and rendering; do not merely
  move extensions between files.
- [ ] Define lifecycle, cancellation, persistence, and test seams for each coordinator.
- [ ] Replace the global command notification bus incrementally with a typed, scene-scoped `AppCommand`
  router; retain NotificationCenter for genuine system/process broadcasts.
- [ ] Add a characterization test before each extraction and keep UI behavior unchanged.

**Exit gate:** major feature state has one named owner; command payloads are compiler checked and scoped to
the intended window/pane; extracted units are independently testable.

### 4.2 Reduce unchecked concurrency in the Metal pipeline

**Priority:** P2  
**Evidence:** `MetalEditPipeline.swift:457` declares `@unchecked Sendable` and has extensive mutable
`nonisolated(unsafe)` state beginning around `:489`; only a subset has explicit locking.

**Plan:**

- [ ] Split a main-actor live-preview facade from a serialized offscreen renderer actor/executor.
- [ ] Reduce unsafe nonisolated state to audited immutable Metal resources.
- [ ] Add owner/executor preconditions for remaining call-site contracts.
- [ ] Schedule a TSAN stress scenario combining preview, Clean Feed, export, cancellation, and navigation.

**Exit gate:** every remaining unsafe isolation escape has a written invariant and enforcement; the stress
scenario is repeatable and clean.

### 4.3 Move the face model to a verified on-demand component

**Priority:** P3; depends on the artifact manifest and privacy checkpoint.  
**Evidence:** AuraFace occupies about 125 MB and the existing roadmap already proposes an on-demand,
versioned model in `TODO.md` under **Version 2.3**.

**Plan:**

- [ ] Define model availability states: not installed, downloading, ready, update available, incompatible,
  verification failed, and offline.
- [ ] Download over HTTPS, verify the manifest signature/hash before install, stage atomically, and retain a
  rollback version during migration.
- [ ] Never reset stored embeddings until the new model and backup are both verified.
- [ ] Explain download size, on-device use, removal, and offline behavior before downloading.

**Exit gate:** clean install/offline/update/rollback/corrupt-download scenarios are tested; app update size
drops by the model payload without silently disabling face features.

## Deferred candidates

These are worthwhile after the higher-risk phases unless user research promotes them:

- Recoverable/undoable deletion for metadata and Develop templates.
- Separate Workspace switching from pane Layout and add an explicit exit from Metadata Review.
- Adaptive Advanced Export layout based on the presenting window/display rather than `NSScreen.main`.
- A strings catalog, pseudolocalization, and layout tests if multilingual distribution is planned.
- A project-wide audit replacing production forced casts with typed boundaries where practical.

## Delivery discipline

For every completed item:

1. Add failure-injection or interaction tests before changing the implementation.
2. Preserve unrelated metadata, sidecar fields, sync records, and user files.
3. Record exact commands/results in a dated validation document.
4. Separate automated evidence from manual, real-device, external-tool, and real-server evidence.
5. Update this plan and the owning release plan together; a checked box must link to its validation record.
