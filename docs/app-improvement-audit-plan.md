# App improvement audit plan

**Status:** implementation in progress — 63 of 75 checklist substeps complete
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

**Checklist reconciliation (2026-08-25):** the status count is exact: 52 of 75 substeps are checked and
23 remain open. Each checked substep links to dated validation. A baseline current-source and
validation-record review found no definitive evidence that another unchecked substep was already complete;
partial foundations such as the existing bookmark lifecycle tests, accessibility semantics, bounded image
caches, and focused concurrency coverage do not satisfy their broader manual, system-level, or
cross-workflow exit gates.

**Implementation follow-up (2026-08-26):** 54 of 75 substeps are now checked and 21 remain open. Startup
work is dependency-ordered, deferred until after first content, idempotent, and cancellable, and the optional
AuraFace component now has seven explicit fail-closed availability states. The broader startup performance
gate and AuraFace download/install/rollback exit gate remain open.

**Resource-control follow-up (2026-08-27):** 57 of 75 substeps are now checked and 18 remain open. A shared
image-memory coordinator now budgets full-screen, Develop, thumbnail, analysis, and scope caches; adapts
limits and prefetch to source dimensions and available memory; and performs ordered warning/critical
eviction after cancelling full-screen prefetch, analysis renders, thumbnail producers, and Metal precache.
The Instruments and target-hardware benchmark remains open.

**On-demand model runtime follow-up (2026-08-27):** 59 of 75 substeps are now checked and 16 remain open.
The fixture-tested runtime verifies a signed HTTPS descriptor and complete artifact file set, installs
atomically with rollback, revalidates signed receipts, defers embedding migration until the new model is
verified, and provides download/removal/offline disclosure. The production-download item remains open until
the artifacts are published at `aagedal.me`, a model-omitted release candidate is built, and real-server
macOS-tier drills pass.

**Executor-contract reconciliation (2026-08-27):** 60 of 75 substeps are now checked and 15 remain open.
The existing executor-isolation validation proves owner/executor preconditions at live render-state,
offscreen-renderer, and cross-pipeline boundaries. The compile-time live-preview facade and remaining
mutable Metal storage extraction are still open.

**Parallel implementation continuation (2026-08-29):** the checklist remains 60 of 75 because the three
completed slices advance broader open gates rather than satisfying them in full. Face-group photo deletion
now crosses the serialized filesystem actor with immutable commit/failure/cancellation evidence and stale
result rejection. Twelve more metadata, template, Caption, and C2PA user commands are typed and scene
scoped. Five separately unsafe viewport fields are now one executor-owned atomic snapshot, reducing
`MetalEditPipeline`'s explicit `nonisolated(unsafe)` declarations from 29 to 24. The combined application
and test targets compiled and all 30 focused tests passed.

**Scene-boundary completion follow-up (2026-08-29):** 61 of 75 substeps are now checked and 14 remain open.
Known People browsing, split-pane sidebar root registration, and Caption focus restoration were the final
application/UI handoffs still using the process-wide notification bus. They now cross the scene-owned typed
router, while the remaining notifications are system events or passive process/state broadcasts. UI-test
source enumeration and all four export-output directory creation paths also cross serialized filesystem
actors with cancellation/commit evidence, and four mutable Metal live-state fields are now one
executor-owned snapshot, reducing explicit unsafe declarations from 18 to 14. The full app/test targets
compiled and all 47 integrated focused tests passed.

**Further parallel continuation (2026-08-29):** the checklist remains 61 of 75 because these slices advance
three broad open gates without satisfying their manual or architectural exit conditions. Batch Rename
planning now captures its root, companion-directory, and volume-case-sensitivity evidence on an injected
serialized actor with cancellation checks around each synchronous read. `DevelopMaskInteractionCoordinator`
now owns brush preferences/tool mode, image-session binding, and matte-hover identity. Six watermark GPU
and cache fields now share executor-checked storage, reducing `MetalEditPipeline`'s explicit
`nonisolated(unsafe)` declarations from 14 to 8. A fresh application/test build and all 34 integrated focused
tests passed.

**Final unsafe-state and filesystem continuation (2026-08-30):** 62 of 75 substeps are now checked and 13
remain open. Develop single-image destination creation and main content-area folder-drop classification now
cross existing serialized filesystem actors. The final four explicit `MetalEditPipeline`
`nonisolated(unsafe)` declarations were replaced by executor-owned or lock-backed state, with a documented
immutable cached-texture boundary; the separate compile-time live-preview facade remains open. All 44 focused
tests across the touched filesystem, export, Metal, memory, and stress suites passed.

**Live-preview facade continuation (2026-08-30):** 63 of 75 substeps are now checked and 12 remain open.
Interactive Develop, scope, and Clean Feed owners now retain a main-actor `MetalLivePreviewPipeline` facade;
the raw live-engine initializer is file-private, while the existing serialized offscreen executor remains
separate. FTP Recent Uploads availability checks also moved from SwiftUI body evaluation to an immutable,
cancellable actor snapshot, and a new Develop comparison coordinator owns render request identity,
cancellation, output, and stale-result rejection. The broader filesystem inventory/measurement gate and
the remaining Develop render-publication ownership work stay open. All 36 integrated focused tests passed.
([validation](plan-status-continuation-validation-2026-08-30.md))

**Further implementation continuation (2026-08-30):** the checklist remains 63 of 75 because the two code
slices advance broad open gates rather than completing them. Structured Keyword import now reads through a
serialized, cancellable actor and rejects stale UI publication. A new Develop preview-render coordinator owns
materialized-preview publication, request identity, fallback/scope output, cancellation, and image-session
teardown. Seven test-only polling ceilings were reconciled with the suite's documented full-load budget; the
unfiltered gate then passed 1,613 tests in 182 suites. Lower-priority filesystem paths, broader Develop
gesture/render/persistence ownership, and the manual/external gates remain open.
([validation](plan-status-implementation-continuation-2026-08-30.md))

**Responsiveness and navigation continuation (2026-08-30):** the checklist remains 63 of 75. Team roster
imports and keyword-backup previews now use cancellable serialized readers with request-identity gating, and
three common filesystem-read boundaries expose stable privacy-safe signposts plus a repeatable blocked-volume
responsiveness gate. `DevelopPreviewNavigationCoordinator` now owns the live/committed zoom and pan session for
the normal Develop preview. These slices advance the open Phase 3.1 measurement/inventory and Phase 4.1
state-owner items without claiming real-volume, Thread Performance Checker, Instruments, or broader extraction
exit gates. ([validation](plan-status-responsiveness-navigation-continuation-2026-08-30.md))

**Filesystem and transient-preview continuation (2026-08-30):** the checklist remains 63 of 75. Keyword-list
backup inventory, snapshot/prune enumeration, and restore commits; team roster PDF/text writes; and Remove All
IPTC sidecar preflight probes now cross serialized actor boundaries with immutable cancellation, partial-success,
and durable-commit evidence plus stale-result rejection. `DevelopTransientPreviewCoordinator` now owns the
press-and-hold Before, whole-Develop, Global, and selected-mask comparison lifetime and render-only settings
projection, so selected-mask comparison no longer mutates editable metadata. These slices advance the broad open
Phase 3.1 filesystem and Phase 4.1 state-owner items without satisfying their remaining inventory, real-volume,
manual, or architectural exit conditions. ([validation](plan-status-filesystem-transient-preview-continuation-2026-08-30.md))

**Certificate, export, and section-mute continuation (2026-08-30):** the checklist remains 63 of 75. C2PA
certificate import, status, removal, transaction rollback, and Keychain coordination now cross a serialized
actor with immutable cancellation and durable-commit evidence; app-scoped availability fails closed and is
injected into FTP presentation. Keyword and Structured Keyword exports now use a serialized atomic UTF-8
writer with request-identity gating. `DevelopSectionMuteCoordinator` owns all six sticky render-only section
mutes as one workspace-lifetime snapshot. These slices advance the broad Phase 3.1 filesystem and Phase 4.1
state-owner items without satisfying their remaining inventory, real-volume, manual, or architectural exit
conditions. ([validation](plan-status-certificate-export-mutes-continuation-2026-08-30.md))

**Source-file import continuation (2026-08-30):** the checklist remains 63 of 75. Code Replacement bookmark
and source loading, Metadata Quick List conditional file creation, and Develop color-LUT reads now cross
serialized actors with immutable cancellation evidence. Their MainActor owners cancel superseded or
disappearing work and reject stale publication. The combined selection passed 40 tests and the unfiltered gate
passed 1,672 tests in 193 suites. Remaining direct paths and the real-volume/Thread Performance Checker gate
keep the broad Phase 3.1 items open.
([validation](plan-status-source-file-import-continuation-2026-08-30.md))

**Archive, roster, license, and crop continuation (2026-08-30):** the checklist remains 63 of 75. Image
Analysis archive export/inspect/import, match-roster load/save, and bundled license-text reads now cross
serialized asynchronous boundaries with immutable cancellation/commit evidence and stale-result protection.
`DevelopCropSessionCoordinator` owns crop tool, preview zoom, aspect, transient gesture geometry, lifecycle,
display/sensor transforms, and explicit preview-versus-commit intent. The roster selection passed five tests;
after disabling the stalled parallel test worker, the combined four-suite selection passed 21 tests and the
serial unfiltered result recorded 1,817 expanded cases across 196 named suites. The broader filesystem
inventory/measurement and Develop ownership gates remain open.
([validation](plan-status-archive-roster-crop-continuation-2026-08-30.md))

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
- [x] Show a plain-language recovery notice naming the affected category without exposing private values.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)

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

- [x] Introduce a URL-keyed persistence actor for the entire read/merge/history/install transaction.
  ([validation](sidecar-transaction-serialization-validation.md), 2026-08-25)
- [x] Compare a source revision/content token before install and retry a merge when it changed.
  ([validation](sidecar-transaction-serialization-validation.md), 2026-08-25)
- [x] Route Caption, Metadata, face, and Develop sidecar writes through the same boundary.
  ([validation](sidecar-transaction-serialization-validation.md), 2026-08-25)
- [x] Preserve the existing atomic staging, backup, schema, and read-back practices.
  ([validation](sidecar-transaction-serialization-validation.md), 2026-08-25)

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

- [x] Track a manifest containing component version, immutable upstream revision, SHA-256, license, build
  recipe revision, target architecture, and expected runtime capability.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
- [x] Correct the FFmpeg corresponding-source offer and keep it generated from the manifest.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
- [x] Add deterministic fetch/build/verify tooling for AuraFace with a pinned Hugging Face revision.
  ([validation](auraface-deterministic-build-validation.md), 2026-08-25)
- [x] Make release preflight fail on a missing or mismatched required artifact.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
- [x] If a feature is intentionally omitted, compile/package an explicit unavailable state and disclose it in
  release notes rather than silently degrading.
  ([validation](auraface-packaged-unavailable-validation.md), 2026-08-25)

**Deterministic-build follow-up (2026-08-25):** manifest-driven `hf` fetch and SHA-256 verification are
combined with a content-pinned, transitive `uv` lock and an executable conversion gate
([validation](auraface-deterministic-build-validation.md)). The gate normalizes conversion metadata and
package identifiers, requires two byte-identical clean builds, and compares three deterministic inputs in
Torch and Core ML before it installs an output.

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
- [x] Evaluate App Sandbox feasibility; if full sandboxing is impractical, document why and assess a
  constrained XPC/helper boundary for untrusted parsing and bundled tools.
  ([validation](app-sandbox-feasibility-validation.md), 2026-08-25)

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
- [x] Centralize privacy-safe accessibility announcements for success, failure, cancellation, and recovery.
  ([validation](accessibility-announcement-validation.md), 2026-08-25)

**Exit gate:** injected failures retain all edits, focus the error, remain keyboard operable, and produce one
useful VoiceOver announcement.

### 2.2 Add a clear face-data and iCloud lifecycle checkpoint

**Priority:** P1, pending legal/privacy review; do not claim a legal conclusion from this audit.  
**Evidence:** the open privacy/legal question remains in `TODO.md` under **Version 2.3**. The implementation
stores face-only Known People samples separately from folder-local scan/clothing features and now explains
that boundary before optional iCloud transfer.

**Plan:**

- [ ] Obtain a focused privacy/legal review of Known People, embeddings, thumbnails, clothing samples,
  folder-local face data, export, deletion, and optional iCloud sync.
- [x] Add first-use plain-language disclosure of on-device processing, persisted data, locations, retention,
  export/delete scope, and optional cloud transfer.
  ([validation](known-people-privacy-lifecycle-validation.md), 2026-08-25)
- [x] Require explicit confirmation before enabling Known People iCloud sync for the first time.
  ([validation](known-people-privacy-lifecycle-validation.md), 2026-08-25)
- [x] Provide a single Data Management summary with counts, storage destinations, export, and deletion paths.
  ([validation](known-people-privacy-lifecycle-validation.md), 2026-08-25)

**Exit gate:** a new user can state what is stored locally, what may be uploaded, and how to export/delete it;
copy is reviewed and does not overclaim compliance.

### 2.3 Harden delivery transport decisions

**Priority:** P1/P2  
**Evidence:** plain FTP and disabled verification are available with an inline warning at
`Views/FTP/FTPServerForm.swift:34-69`, but saving does not require acknowledgement at `:87-95`.

**Plan:**

- [x] Recommend SFTP/verified FTPS by default and visually badge insecure profiles everywhere selected.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
- [x] Require acknowledgement when saving an insecure profile and before its first upload.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
- [x] Record transport and verification state in privacy-safe Activity/receipt evidence.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
- [ ] Add real-server drills for FTP, explicit FTPS, and SFTP, including certificate/host-key failures.

**Acknowledgement follow-up (2026-08-25):** insecure saves, the legacy upload first-use path, and Deadline's
confirmation sheet now require explicit acknowledgement tied to the exact protocol/verification state.
Deadline also retains the fail-closed transport boundary; see the
[parallel follow-up validation](plan-status-parallel-follow-up-validation.md).

**Exit gate:** insecure transport cannot be used accidentally; receipts accurately describe the security mode;
representative server tests cover failure and retry.

### 2.4 Add UI automation and finish manual accessibility validation

**Priority:** P2  
**Evidence:** no UI-test target exists; `docs/manual-release-prerequisite-audit.md:27-29` and
`docs/accessibility-keyboard-audit-validation.md:25-29` list unverified assistive-technology behavior.

**Plan:**

- [x] Add a small XCUITest smoke target for launch/open folder, import preflight, Caption save, Batch Rename,
  Deadline preflight, and recovery/error states.
  ([validation](macos-ui-smoke-validation.md), 2026-08-25)
- [x] Convert full-screen rating stars and label dots to labelled Buttons.
  ([validation](accessibility-keyboard-audit-validation.md), 2026-08-25)
- [x] Convert face selection, ingest split cells, scope modes, and copyable metadata rows from gesture-only
  interactions to keyboard/VoiceOver-operable controls.
  ([validation](accessibility-keyboard-audit-validation.md), 2026-08-25)
- [x] Give Metadata Review failures persistent icons/reasons and accessibility severity, not color/hover alone.
  ([validation](plan-status-parallel-follow-up-validation.md), 2026-08-25)
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

**Async-boundary follow-up (2026-08-27):** Browser folder scans and mutations, batch trash/move/duplicate
operations, the audited Metadata JSON-history/XMP save, FTP upload inventory/staging, and Delivery Receipt
summary export now cross serialized actor boundaries and return immutable results with explicit cancellation
and durable-partial-success semantics. Primary and secondary-card import discovery also crosses a serialized
actor boundary with cooperative cancellation, stale-result rejection, explicit enumeration errors, and
privacy-safe scan signposts. The Import window now exposes that discovery state immediately and receives
immutable file/image/WAV count snapshots every five seconds for both source selectors. Lower-priority direct
filesystem paths, volume benchmarks, and Thread Performance Checker evidence remain open.
([validation](filesystem-async-boundary-validation-2026-08-27.md))

**Rejected-bundle follow-up (2026-08-29):** Move Rejected to Folder now performs destination creation,
collision probing, image/XMP/editorial-sidecar moves, and rollback on the serialized filesystem actor.
Cancellation stops between transactional bundles, and stale completion after folder navigation cannot
reload the previous folder. Before release-candidate integration, manually verify a slow external/network
volume, navigation during the move, rollback presentation, and Thread Performance Checker behavior using the
[dated procedure](plan-status-follow-up-validation-2026-08-29.md#manual-validation-still-required).
Lower-priority direct paths and the broader measurement exit gate remain open.

**Import-preflight follow-up (2026-08-29):** Same-date duplicate discovery and primary/backup overwrite
collision probes now cross a serialized `ImportPreflightService` actor boundary. The service returns one
immutable job plan with duplicate skips and exact collision evidence frozen together; cancellation is
explicit, reset invalidates late results, and the execution boundary still revalidates the confirmed
collision signature before writing. Other direct filesystem paths and the broader measurement exit gate
remain open. ([validation](plan-status-follow-up-validation-2026-08-29.md#import-preflight-async-boundary))

**Analysis-export follow-up (2026-08-29):** final PDF, annotated-photo JPEG, and annotated-map JPEG writes
now cross a serialized `AnalysisExportFileService` actor instead of calling synchronous `Data.write` from
the main-actor workspace. Immutable commit evidence distinguishes cancellation before a write from
cancellation observed after a durable atomic commit; request identities and source/case invalidation prevent
late results from clearing or replacing newer export UI state. Other direct filesystem paths, slow-volume
measurements, and the broader exit gate remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#analysis-export-filesystem-boundary))

**Face-group deletion follow-up (2026-08-29):** deleting a face group with its source photos now sends the
photo-trash batch through the serialized `FileSystemService` actor. The main actor receives immutable
committed URLs, item failures, cancellation status, and face-data disposition. Pre-cancellation performs no
filesystem or model mutation, and a face-data revision guard prevents a slow completion from overwriting a
newly loaded folder's state. Individual trash failures retain the existing group-deletion semantics while
remaining explicit in the result. The broader lower-priority filesystem audit and measurement exit gate
remain open. ([validation](plan-status-follow-up-validation-2026-08-29.md#face-group-photo-deletion-async-boundary))

**Export/source-discovery follow-up (2026-08-29):** the UI-smoke import fixture no longer enumerates its
source directory on the main actor; `FileSystemService` returns a filtered, stable, immutable supported-URL
snapshot with cancellation checks before, during, and after enumeration. The four batch render/save/archive
workflows now create output directories through a serialized `ExportDirectoryService`, which distinguishes
pre-cancellation from cancellation arriving after the synchronous durable commit. The broader filesystem
inventory, slow-volume drills, and signpost/benchmark gate remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#additional-filesystem-boundaries))

**Batch-rename planning follow-up (2026-08-29):** rename planning no longer relies on an ad-hoc detached
task for its directory snapshot. An injected `BatchRenamePlanningSnapshotService` actor serializes the root
and registered companion-directory reads plus volume case-sensitivity lookup, checks cancellation before
and after each non-preemptible Foundation call, and publishes only the complete immutable planning
environment. A blocked-reader characterization proves the main actor remains responsive. The broader
filesystem inventory and slow-volume/signpost/benchmark exit gate remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#batch-rename-planning-filesystem-boundary))

**Sidebar-drop and receipt-export follow-up (2026-08-30):** dropped sidebar URLs are now classified on the
serialized filesystem actor instead of probing slow paths on the main actor, with immutable directory/file/
missing evidence and pre-cancellation before any probe. Delivery Receipt summary commits use an injected,
serialized exclusive-create writer with off-main execution, queued-cancellation, durable-after-cancel, and
stale-result coverage. Lower-priority direct paths and the slow-volume/signpost/benchmark gate remain open.
([validation](plan-status-follow-up-validation-2026-08-30.md))

**Develop single-image export follow-up (2026-08-30):** the Develop Save action now creates its `Edited`
output directory through the serialized `ExportDirectoryService` instead of calling synchronous
`FileManager` from its inherited main-actor task. Pre-commit cancellation creates nothing; cancellation
reported after the synchronous directory commit retains that harmless folder and suppresses the expensive
render. Other direct filesystem paths and the slow-volume/signpost/benchmark gate remain open.
([validation](plan-status-follow-up-validation-2026-08-30.md#develop-single-image-export-directory-boundary))

**Content-area folder-drop follow-up (2026-08-30):** the main content drop target now sends each provider URL
through `FileSystemService.dropSourceSnapshot` before loading a folder, reusing the same serialized,
cancellable classification boundary as sidebar drops. Direct `FileManager.fileExists` probing has been
removed from the provider callback. Other direct filesystem paths and the slow-volume/signpost/benchmark
gate remain open.
([validation](plan-status-follow-up-validation-2026-08-30.md#content-area-folder-drop-boundary))

**FTP Recent Uploads follow-up (2026-08-30):** expanding upload history no longer evaluates repeated
`FileManager.fileExists` probes in the SwiftUI body. The existing FTP filesystem actor returns ordered,
immutable availability evidence with explicit complete or cancelled-prefix status; the view installs only a
complete snapshot for the entry that remains expanded. Other lower-priority direct paths and the slow-volume/
signpost/benchmark exit gate remain open.
([validation](plan-status-continuation-validation-2026-08-30.md#ftp-recent-uploads-filesystem-boundary))

**Structured Keyword import follow-up (2026-08-30):** the user-selected keyword-file read now crosses a
serialized `TextFileImportService` actor instead of calling `Data(contentsOf:)` from the MainActor editor
action. Immutable results distinguish complete load, cancellation before the reader, and cancellation after
the non-preemptible read; the view cancels superseded work and rejects stale completion by request identity.
Other direct filesystem paths and the slow-volume/signpost/benchmark gate remain open.
([validation](structured-keyword-import-filesystem-validation-2026-08-30.md))

**Roster import and keyword-backup preview follow-up (2026-08-30):** user-selected team-roster imports now
reuse the serialized `TextFileImportService` rather than reading synchronously in the team editor. Backup
preview reads use a dedicated serialized reader with immutable loaded/pre-read-cancelled/post-read-cancelled
evidence. Both views cancel disappearing or superseded work and reject stale completion by request identity.
Other direct filesystem paths and the real-volume measurement gate remain open.
([validation](plan-status-responsiveness-navigation-continuation-2026-08-30.md))

**Filesystem measurement follow-up (2026-08-30):** browser folder scans, supported-file snapshots, and drop
classification now publish stable `OSSignposter` intervals containing only private aggregate counts and result
state. A deterministic blocked-probe characterization and bounded repeat-run script prove the actor keeps the
main actor responsive and cancels a queued request before another volume probe. This makes the required manual
measurement repeatable; it does not replace captures on local SSD, network, iCloud-placeholder, read-only, and
large-folder fixtures or Thread Performance Checker evidence.
([validation](slow-volume-measurement-gate-2026-08-30.md))

**C2PA certificate and keyword-export follow-up (2026-08-30):** PEM/PKCS#12 reads, parsing, transactional
certificate/Keychain replacement with rollback, status, and removal now cross the serialized
`C2PASigningConfigurationService`. App and Settings owners use request identities and immutable evidence;
certificate availability fails closed until verified. Keyword-list and Structured Keyword writes now cross
the serialized `TextFileExportService` with atomic UTF-8 commits, queued cancellation, durable-after-cancel
evidence, and stale-result rejection. Lower-priority direct filesystem paths and the real-volume measurement
gate remain open. ([validation](plan-status-certificate-export-mutes-continuation-2026-08-30.md))

**Source-file import follow-up (2026-08-30):** Code Replacement bookmark creation/resolution, source reads,
resource-value reads, and parsing now cross one serialized actor with immutable loaded/cancelled evidence and
stale-publication rejection. Metadata Quick List conditional file creation and Develop `.cube` LUT reads also
cross serialized actors; both UI owners cancel replacement/disappearance work and reject late completion. The
three slices remove their direct blocking calls from MainActor presentation while preserving bookmark,
best-effort Quick List, security-scope, parser, and edit-commit behavior. The combined 40-test selection and
the unfiltered 1,672-test gate passed. Lower-priority direct paths and real-volume/Thread Performance Checker
evidence remain open. ([validation](plan-status-source-file-import-continuation-2026-08-30.md))

**Exit gate:** Thread Performance Checker finds no blocking file/sidecar work on the main thread in core
workflows; UI remains responsive during slow-volume simulations.

### 3.2 Coordinate image/GPU memory under one budget

**Priority:** P2  
**Evidence:** full-screen cache limits total up to 768 MiB (`FullScreenImageCache.swift:44-52`), while two
full-resolution edit textures can use about 726 MiB for 45 MP files (`MetalEditPipeline.swift:486-493`),
before thumbnails, scopes, masks, and render intermediates.

**Plan:**

- [x] Create a shared image-memory coordinator across full-screen, Develop, thumbnail, and scope caches.
  ([validation](image-memory-coordination-validation-2026-08-27.md), 2026-08-27)
- [x] Scale prefetch and limits by source dimensions and available memory.
  ([validation](image-memory-coordination-validation-2026-08-27.md), 2026-08-27)
- [x] Respond to memory pressure by cancelling speculative work and evicting in a documented order.
  ([validation](image-memory-coordination-validation-2026-08-27.md), 2026-08-27)
- [ ] Benchmark rapid navigation/edit/export of representative large RAW/HDR files with Instruments.

**Exit gate:** the benchmark has an agreed peak-memory budget, no IOSurface/allocation failures, and bounded
recovery after memory pressure.

### 3.3 Profile startup and expensive reactive recomputation

**Priority:** P2  
**Evidence:** app initialization starts several singleton migrations/watchers plus detached precomputation and
network refresh at `Aagedal_Photo_AgentApp.swift:12-45`. Deadline identity re-encodes broad state in response
to general defaults changes at `ContentView.swift:230,237-238,1321-1452`.

**Plan:**

- [x] Add launch and first-interaction signposts before deciding what to defer.
  ([validation](startup-signpost-validation-2026-08-25.md), 2026-08-25)
- [x] Make startup jobs dependency-ordered, cancellable, and lazy when they are not needed for first paint.
  ([validation](startup-work-orchestration-validation-2026-08-26.md), 2026-08-26)
- [x] Give Deadline an owned typed revision model; ignore unrelated preferences and debounce capture work.
  ([validation](deadline-capture-revision-validation-2026-08-25.md), 2026-08-25)
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
- [x] Replace the global command notification bus incrementally with a typed, scene-scoped `AppCommand`
  router; retain NotificationCenter for genuine system/process broadcasts.
  ([validation](plan-status-follow-up-validation-2026-08-29.md#scene-ui-handoff-router-completion), 2026-08-29)
- [ ] Add a characterization test before each extraction and keep UI behavior unchanged.

**Command-router follow-ups (2026-08-27 through 2026-08-29):** Open Folder/Open Recent, rating/label, core
export, previous/next-image, clockwise/counterclockwise rotation, Rename, Duplicate, Reset All Edits, Remove
All IPTC, Import Photos, Back Up Edited Files, internal/external editor opening, Move to Trash, and Move
Rejected to Folder, Upload Selected, and Upload All commands now use a typed, scene-owned
`AppCommandRouter`, including explicit AppKit bridging and typed payload/sequence contract coverage. The
migrated slices removed their process-wide
notification names while preserving existing menu, context-menu, shortcut, preference, and browser behavior.
Other command families and state-owning coordinator extractions remain incremental work.
([validation](app-command-router-validation-2026-08-27.md))

**Develop/scope command follow-up (2026-08-29):** Add Mask, Remove/Reset Selected Layer, Toggle HDR,
scope-mode selection, and Gamut Clipping now use five more typed scene commands. Develop-only and
single-selection scope ownership is preserved, while rendered scope-image and slider-drag state remain
process-local state broadcasts. Menu, shortcut, focus, unavailable-workspace, and multi-window behavior must
be checked manually before release-candidate integration using the
[dated procedure](plan-status-follow-up-validation-2026-08-29.md#manual-validation-still-required).

**Metadata/Caption command follow-up (2026-08-29):** Process Variables (selected/all), Write All Pending
Metadata, template palette and numbered-template application, Caption Workspace, Render and Sign, Copy/Paste
IPTC, Variable Reference, Raw Metadata, and Structured Keywords now cross the same scene-owned router.
Numbered templates retain a typed `Int` slot payload, the AppKit thumbnail key handler and C2PA detail sheet
send through their owning scene, and twelve obsolete notification names were removed. The internal Develop
template handoff and genuine state broadcasts remain notifications. Other user-command families and manual
multi-window/menu/focus verification keep the broad router item open.
([validation](plan-status-follow-up-validation-2026-08-29.md#metadata-template-caption-and-c2pa-command-router-continuation))

**Develop-template payload follow-up (2026-08-29):** the remaining template-to-Develop handoff now uses a
typed `AppCommand.applyDevelopTemplate(DevelopTemplate)` payload in the owning scene. Both palette and
numbered-shortcut paths preserve the editable-single-image guard, and the obsolete notification declaration,
publisher, and modifier have been removed. Genuine process/state notifications and a small number of other
UI handoffs remain subject to separate ownership review; the broad router item and manual multi-window gate
remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#develop-template-command-payload))

**Final UI-handoff follow-up (2026-08-29):** Known People browsing from Settings, split-pane root-folder
registration, and Caption editor focus restoration now use typed scene delivery, including the exact folder
URL payload. A current-source audit finds only system notifications and passive process/state broadcasts
remaining, so the command-bus checklist item is complete. Menu/focus/multi-window behavior still requires
the existing manual release-candidate procedure, and the other Phase 4.1 coordinator/extraction items remain
open. ([validation](plan-status-follow-up-validation-2026-08-29.md#scene-ui-handoff-router-completion))

**State-owner follow-up (2026-08-27):** `DevelopVersionSessionCoordinator` now owns named-version catalog,
revision, storage, cancellation, debounce/flush persistence, and stale-result gating. A separate
`AIMaskSelectionCoordinator` owns AI-mask selection/generation request identity, cancellation, image-session
binding, and late-result rejection. Characterization tests cover both extractions; at that point
brush/matte/gesture and render ownership still remained in `EditWorkspaceView`.

**Mask-interaction state-owner follow-up (2026-08-29):** `DevelopMaskInteractionCoordinator` now owns brush
preferences, paint-tool lifecycle, image-session binding, and matte-hover identity. The extraction preserves
brush tool state across navigation while clearing image-specific matte previews, rejects stale hover exits,
and keeps view-to-Metal synchronization at the existing UI boundary. Three focused characterizations cover
the extracted lifecycle; broader gesture, render, and persistence ownership remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#develop-mask-interaction-state-owner))

**Preview-session state-owner follow-up (2026-08-30):** `DevelopPreviewSessionCoordinator` now owns decoded
source identity/orientation, preview/full-resolution progress, and four image-scoped producer task lifecycles.
Navigation and workspace teardown cancel the complete producer set through one boundary, while retained-source
rotation is identity-gated and stale A→B→A completions are rejected by session generation. Decode/Metal
publication and broader render ownership remain in the view.
([validation](plan-status-follow-up-validation-2026-08-30.md#develop-preview-session-state-owner))

**Comparison-render state-owner follow-up (2026-08-30):** `DevelopComparisonRenderCoordinator` now owns
image/version comparison mode, both rendered outputs, errors, debounce/cancellation lifetime, and monotonic
request identity. Replaced or closed comparisons reject late pixels and errors even when injected work ignores
cooperative cancellation, and a version comparison publishes its two rendered sources as one coordinator
result. Broader Develop source decode, Metal publication, and interactive render ownership remain open.
([validation](plan-status-continuation-validation-2026-08-30.md#develop-comparison-render-coordinator))

**Preview-render state-owner follow-up (2026-08-30):** `DevelopPreviewRenderCoordinator` now owns the
materialized Develop preview, render-task replacement, request identity, fallback publication, scope output,
and image-session teardown. Replacement, cancellation, and teardown reject late pixels even from injected
work that ignores cooperative cancellation. Core Image/Metal render policy remains in the view, and broader
gesture, interactive-render, and persistence ownership remains open.
([validation](plan-status-implementation-continuation-2026-08-30.md#develop-preview-render-publication-owner))

**Preview-navigation state-owner follow-up (2026-08-30):** `DevelopPreviewNavigationCoordinator` now owns the
normal preview's paired live/committed zoom and pan state. Scroll, keyboard, magnify, drag, Space-hand, clamp,
recenter, and image-reset transitions cross that owner, while the view retains cursor geometry, crop-tool zoom,
and Metal viewport publication. Five characterizations cover bounds, gesture anchoring, recentering, clamping,
and teardown. Other Develop interaction, layer, render-policy, and persistence owners remain open.
([validation](develop-preview-navigation-validation-2026-08-30.md))

**Section-mute state-owner follow-up (2026-08-30):** `DevelopSectionMuteCoordinator` now owns the sticky
Color, Exposure, Detail, Tone Curve, HSL, and Film mute values as one workspace-lifetime snapshot. All section
bindings and toggles route through that owner while remaining render-only and surviving image navigation.
Crop, layer, white-balance, broader render-policy/publication, export, and persistence ownership remain open.
([validation](plan-status-certificate-export-mutes-continuation-2026-08-30.md))

**Crop-session state-owner follow-up (2026-08-30):** `DevelopCropSessionCoordinator` now owns crop-tool
visibility, preview zoom/aspect, locked and transient gesture geometry, image/workspace cleanup, and the
display-to-sensor crop transformation boundary. Its mutation operations return explicit preview-only versus
durable-commit intent. Layer, white-balance, broader render-policy/publication, export, and persistence
ownership remain open.
([validation](plan-status-archive-roster-crop-continuation-2026-08-30.md#develop-crop-state-owner))

**Exit gate:** major feature state has one named owner; command payloads are compiler checked and scoped to
the intended window/pane; extracted units are independently testable.

### 4.2 Reduce unchecked concurrency in the Metal pipeline

**Priority:** P2  
**Evidence:** `MetalEditPipeline.swift:457` declares `@unchecked Sendable` and has extensive mutable
`nonisolated(unsafe)` state beginning around `:489`; only a subset has explicit locking.

**Plan:**

- [x] Split a main-actor live-preview facade from a serialized offscreen renderer actor/executor.
  ([validation](plan-status-continuation-validation-2026-08-30.md#compile-time-metal-live-preview-facade), 2026-08-30)
- [x] Reduce unsafe nonisolated state to audited immutable Metal resources.
  ([validation](plan-status-follow-up-validation-2026-08-30.md#final-metal-unsafe-escape-isolation), 2026-08-30)
- [x] Add owner/executor preconditions for remaining call-site contracts.
  MetalEditPipeline live render-state entry points enforce main-thread
  ownership, while the shared export renderer asserts its dedicated serial queue. Worker-safe source
  upload/precache paths remain explicitly documented exceptions; cross-pipeline owner contracts are also
  enforced. Broader facade/actor isolation remains open; the unsafe-state reduction is completed by the
  final 2026-08-30 follow-up below.
  ([validation](metal-edit-pipeline-executor-validation.md), 2026-08-27)
- [x] Schedule a TSAN stress scenario combining preview, Clean Feed, export, cancellation, and navigation.
  ([validation](metal-pipeline-tsan-stress-validation-2026-08-25.md), 2026-08-25)

**Executor-isolation follow-up (2026-08-27):** a dedicated serialized offscreen renderer owns its queue,
cancellation, and reusable pipeline; source/mirror/white-balance state is lock-backed; executor and
cross-pipeline owner preconditions are enforced; and immutable Metal handles reduced explicit
`nonisolated(unsafe)` declarations from 41 to 30. A bounded 2026-08-27 follow-up moved the compiled render
plan behind executor-checked replace/snapshot accessors, reducing the count again to 29. A compile-time
live-preview facade and extraction of the remaining mutable caches/scratch state remain open.
([validation](metal-edit-pipeline-executor-validation.md))

**Viewport-state follow-up (2026-08-29):** five separately unsafe viewport fields (origin, size, center,
rotation, and crop extent) now publish as one `ViewportStateSnapshot` through executor-checked replace and
snapshot accessors. Parameter upload takes one coherent snapshot, so a render cannot combine fields from
different zoom/pan or crop generations. This reduces explicit unsafe isolation escapes from 29 to 24; the
live-preview facade and remaining mutable cache/scratch extraction are still open.
([validation](plan-status-follow-up-validation-2026-08-29.md#metal-viewport-state-isolation))

**CPU cache/scratch follow-up (2026-08-29):** LUT half/interleave scratch, color-LUT payload/parse caches,
and white-balance key/matrix caching now share one `ExecutorOwnedCacheState`. Its only access wrapper checks
the selected state executor and exposes synchronous `inout` value storage, preventing the holder reference
from escaping the checked scope. Six former unsafe fields are gone and the explicit
`nonisolated(unsafe)` count is reduced from 24 to 18. Brush/watermark GPU lifecycle state, owner callbacks,
memory registration, and the live-preview facade remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#metal-cpu-cache-and-scratch-isolation))

**Live-state follow-up (2026-08-29):** gamut clipping, selected-mask overlay/matte identity, and the redraw
callback now share one `ExecutorOwnedLiveState` snapshot. Checked accessors enforce the selected state
executor for reads and writes, and parameter upload consumes one coherent snapshot for each generation while
preserving gamut mirroring and callback order. Four more unsafe stored properties are gone, reducing the
explicit count from 18 to 14; GPU brush/watermark lifecycle storage, memory registration, render timing, and
the compile-time live-preview facade remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#metal-live-state-isolation))

**Watermark-state follow-up (2026-08-29):** watermark texture identity, decoded asset/aspect caches, active
display layers, frame selection, and image size now share one `ExecutorOwnedWatermarkState`. Existing
property call sites cross snapshot/update accessors that enforce the live-main-thread or offscreen-render
executor contract. Six more unsafe stored properties are gone, reducing the explicit count from 14 to 8;
texture-cache payload, image-memory registration, brush GPU state, render timing, and the compile-time
live-preview facade remain open.
([validation](plan-status-follow-up-validation-2026-08-29.md#metal-watermark-state-isolation))

**Brush-raster-state follow-up (2026-08-30):** brush alpha/envelope textures and their source/size cache key
now share `ExecutorOwnedBrushRasterState`, accessed only through executor-checked snapshot/update wrappers.
Four more unsafe stored properties are gone, reducing the explicit count from 8 to 4. Texture-cache payload,
image-memory registration, render timing, and the compile-time live-preview facade remain open.
([validation](plan-status-follow-up-validation-2026-08-30.md#metal-brush-raster-state-isolation))

**Final unsafe-escape follow-up (2026-08-30):** render-log width now belongs to the executor-checked live
state generation, while speculative textures and their image-memory registration share one lock-backed
lifetime holder. Cache limit changes, eviction, publication, and promotion are serialized, and cancellation
holds its generation lock across final publication so a late precache cannot repopulate an evicted cache.
The fully populated cached `MTLTexture` crosses one precisely documented `@unchecked Sendable` wrapper and
is immutable while cached. Explicit `nonisolated(unsafe)` declarations are reduced from 4 to 0, completing
the unsafe-state reduction substep. The separate compile-time live-preview facade remains open.
([validation](plan-status-follow-up-validation-2026-08-30.md#final-metal-unsafe-escape-isolation))

**Compile-time live-preview facade follow-up (2026-08-30):** interactive owners now use
`@MainActor MetalLivePreviewPipeline`, while raw live `MetalEditPipeline` construction is file-private and
the dedicated serialized offscreen executor retains the reusable export engine. Only the audited worker-safe
source upload, adjacent precache, CI-context warmup, and white-balance solver cross the facade as explicit
`nonisolated` operations. Develop, preview, scope, Clean Feed, memory, and stress call sites are facade-typed;
source contracts reject a raw optional live engine in those production owners.
([validation](plan-status-continuation-validation-2026-08-30.md#compile-time-metal-live-preview-facade))

**Exit gate:** every remaining unsafe isolation escape has a written invariant and enforcement; the stress
scenario is repeatable and clean.

### 4.3 Move the face model to a verified on-demand component

**Priority:** P3; depends on the artifact manifest and privacy checkpoint.  
**Evidence:** AuraFace occupies about 125 MB and the existing roadmap already proposes an on-demand,
versioned model in `TODO.md` under **Version 2.3**.

**Distribution decision (2026-08-25):** Hugging Face remains upstream source/provenance for developers.
Users will download the existing pre-converted, quantized Core ML artifact from `aagedal.me`; they will not
download ONNX or run Python/PyTorch/Core ML Tools conversion. Prefer a versioned `.mlpackage` archive unless
cross-version testing proves a compiled `.mlmodelc` archive is portable across every supported macOS tier.
Normal one-time Core ML preparation of an `.mlpackage` is not model conversion and requires no ML toolchain.

**Plan:**

- [x] Define model availability states: not installed, downloading, ready, update available, incompatible,
  verification failed, and offline.
  ([validation](auraface-on-demand-packaging-validation.md), 2026-08-26)
- [ ] Publish the pre-converted quantized Core ML artifact and signed descriptor at `aagedal.me`, build a
  model-omitted release candidate, and validate clean install, offline, update, rollback, and corrupt-download
  behavior against the production server on every supported macOS tier. The HTTPS runtime, signature/hash
  verification, atomic install, receipt revalidation, rollback, and failure-injection tests are implemented.
  ([validation](auraface-on-demand-runtime-validation-2026-08-27.md))
- [x] Never reset stored embeddings until the new model and backup are both verified.
  ([validation](auraface-on-demand-runtime-validation-2026-08-27.md), 2026-08-27)
- [x] Explain download size, on-device use, removal, and offline behavior before downloading.
  ([validation](auraface-on-demand-runtime-validation-2026-08-27.md), 2026-08-27)

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
