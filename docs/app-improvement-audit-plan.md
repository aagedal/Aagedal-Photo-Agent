# App improvement audit plan

**Status:** implementation in progress — 66 of 75 checklist substeps complete
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

**AuraFace production-publication update (2026-09-01):** the model archive, distribution descriptor, and detached
signature are now live at their fixed `aagedal.me` endpoints and each returned HTTP 200. Publication is complete;
the combined checklist item remains open only for the model-omitted release candidate and supported-macOS
production-server install/offline/update/rollback/removal/interrupted-or-corrupt-download drills.
([validation](auraface-on-demand-runtime-validation-2026-08-27.md#remaining-external-validation))

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

**Cleanup, storage, and white-balance continuation (2026-08-30):** the checklist remains 63 of 75. RAW archive
signing-failure compensation, Known People recursive storage measurement, and edited-folder backup destination
preparation now cross serialized asynchronous boundaries with immutable cancellation/durability evidence and
stale-result protection. `DevelopWhiteBalanceSessionCoordinator` owns as-shot neutral, picker/marquee lifecycle,
sample request identity, geometry/value projection, and preview-versus-commit intent. The combined selection
passed 39 tests in four suites, the strengthened white-balance suite passed all seven tests after final late-result
hardening, and the final serial unfiltered gate passed 1,707 tests in 197 suites. The broader filesystem
inventory/measurement and Develop ownership gates remain open.
([validation](plan-status-cleanup-storage-white-balance-continuation-2026-08-30.md))

**Template, import-planning, and Develop-export continuation (2026-08-30):** the checklist remains 63 of 75.
Metadata-template import preview and image/WAV bundle collision planning now cross serialized actors with immutable
complete/cancelled evidence and stale-result protection. `DevelopExportSessionCoordinator` owns the export task,
workspace lifetime, request identity, busy/error state, and durable output evidence while render policy remains
injected. The combined selection passed 36 tests in four suites; after reconciling two superseded source contracts
and parallel-load polling ceilings, the final unfiltered gate passed 1,844 expanded test-case runs across 198 suites.
The remaining filesystem inventory/measurement and broader Develop ownership gates stay open.
([validation](plan-status-template-bundle-export-continuation-2026-08-30.md))

**Approved-list, template-commit, and Develop-layer continuation (2026-08-30):** the checklist remains 63 of 75.
Approved-list source reads and managed commits plus metadata-template bundle commits now cross serialized actors
with explicit cancellation, partial/durable commit evidence, and stale-publication suppression. A new
`DevelopLayerSessionCoordinator` owns layer selection, strip interaction, rename/reorder/delete policy, lifecycle,
and persistence intent. The combined implementation selection passed 52 tests in seven suites, the repository
gate passed, and the final serial unfiltered run recorded 1,859 passing expanded test cases. Remaining direct
paths, real-volume measurements, and broader Develop render/persistence ownership keep the Phase 3.1 and 4.1
substeps open. ([validation](plan-status-approved-template-layer-continuation-2026-08-30.md))

**Archive-preview, raw-metadata, and Clean Feed continuation (2026-08-30):** the checklist remains 63 of 75.
Keyword-list archive previews and raw-metadata app-sidecar loads now cross serialized actors with immutable
cancellation evidence, request-identity gating, and stale-result rejection. A new
`DevelopCleanFeedPublicationCoordinator` owns Clean Feed workspace lifecycle, Metal mirror installation,
live/fallback publication policy, crop freeze, redraw, and continuous-rendering state. The combined selection
passed 17 tests in four suites, the repository gate passed, and the final serial unfiltered run passed 1,745
tests in 203 suites. Remaining direct paths, real-volume measurements, and broader Develop render/persistence
ownership keep the Phase 3.1 and 4.1 substeps open.
([validation](plan-status-archive-preview-raw-metadata-clean-feed-continuation-2026-08-30.md))

**Import, image, keyword-export, and LUT continuation (2026-08-30):** the checklist remains 63 of 75. Import
destination-directory batches now cross the serialized export-directory actor with exact durable-prefix
evidence. Full-screen XMP/ImageIO presentation reads and keyword-list archive export now cross dedicated
serialized actors with immutable cancellation or commit evidence and stale-publication protection. A new
`DevelopColorLUTImportCoordinator` owns importer presentation, image lifetime, security scope, request identity,
cancellation, and typed persistence intent while the existing undo/XMP/version commit stays injected. These
slices passed 26 focused tests, the repository gate, and the serial unfiltered current-source gate of 1,779
tests in 207 suites. They advance the broad Phase 3.1 and 4.1 gates without completing their remaining
inventory, real-volume, manual, or architectural exit conditions.
([validation](plan-status-import-image-keyword-lut-continuation-2026-08-30.md))

**Browser sidecar, keyword editor, and Develop persistence continuation (2026-08-31):** the checklist remains
63 of 75. Browser XMP batch reads and flat keyword-list editor load/save operations now cross serialized actors
with immutable complete, cancellation, partial-prefix, and durable-commit evidence; their MainActor owners reject
stale publication while still broadcasting every durable keyword commit after dismissal. A new
`DevelopPersistenceSessionCoordinator` owns workspace/image lifecycle, image-scoped undo/redo, stale-restoration
rejection, edited-preview URL inventory, and explicit Primary-versus-named-version persistence intent. Existing
XMP and version file commits remain at the injected view boundary. The combined selection passed 52 tests, the
repository gate passed, and the serial unfiltered current-source gate passed 1,923 tests. Lower-priority direct
paths, real-volume measurements, broader Develop persistence/modal/geometry ownership, and manual or external
exit gates remain incomplete. ([validation](plan-status-browser-keyword-develop-persistence-continuation-2026-08-31.md))

**Watermark import and Develop modal/geometry continuation (2026-08-31):** the checklist remains 63 of 75.
Watermark PNG imports now cross a serialized actor with security-scope ownership, explicit cancellation states,
compensated two-file commits, durable evidence, and stale-presentation rejection. Dedicated coordinators now own
named-version modal intent and image-scoped mask/watermark interaction geometry with consume-once persistence
intent. Instance-injected watermark test storage removed a parallel-suite race, and an injected throttle delay
made the interactive-render coalescing test independent of MainActor saturation. The final unfiltered gate passed
1,804 tests in 212 suites. Remaining direct paths, real-volume measurements, broader metadata/sidecar persistence
routing and view decomposition, and manual or external exit gates remain incomplete.
([validation](plan-status-watermark-version-geometry-continuation-2026-08-31.md))

**Quick List mutation and iCloud routing continuation (2026-08-31):** the checklist remains 63 of 75.
Metadata-panel Quick List additions now share the serialized editor persistence actor, including first-use
security-scoped text/CSV import, no-op and cancellation evidence, durable write publication, and stale-result
rejection. Keyword Lists iCloud route resolution and reconciliation now run on a serialized actor; superseded
requests are cancelled, only the latest completion changes the preference, disabling remains available without
a reachable container, and the existing flat-union/structured-preserve merge policy is characterized. The
affected eight-suite selection passed 55 tests, the repository gate passed, and the serial unfiltered gate
passed 1,817 tests in 212 suites. Remaining direct paths, real-volume evidence, broader Develop persistence/view
decomposition, and manual or external gates remain incomplete.
([validation](plan-status-quick-list-routing-continuation-2026-08-31.md))

**Develop persistence-routing continuation (2026-08-31):** the checklist remains 63 of 75. The existing
`DevelopPersistenceSessionCoordinator` now owns Primary-versus-named-version commit dispatch as well as intent:
it publishes the in-memory image snapshot exactly once before invoking exactly one injected durable boundary,
and inactive or unchanged workspaces invoke neither. Normal adjustments and reset commits both use the same
policy owner while retaining their established XMP-only versus embedded-CRS reset modes. The affected four-suite
selection passed 34 tests, the repository gate passed, and the serial unfiltered gate passed 1,818 tests in 212
suites. Broader persistence lifetime/cancellation and view decomposition, direct filesystem inventory and
real-volume evidence, and manual or external gates remain incomplete.
([validation](plan-status-develop-persistence-routing-continuation-2026-08-31.md))

**Settings keyword-archive inventory continuation (2026-08-31):** the checklist remains 63 of 75. The
Quick Lists and Keywords archive sheets no longer synchronously probe and read every managed list while
SwiftUI evaluates export availability or prepares import defaults. `KeywordListsArchiveInventoryService`
serializes coordinated existence/read work away from MainActor, returns immutable ordered counts with exact
cancelled-prefix evidence, and lets export requests reuse the inspected source routes without a second read.
Both sheets own task/request lifetime and reject stale publication; the import sheet retains one request
identity across archive inspection and local inventory. The affected 11-suite selection passed 65 tests, the
repository gate passed, and the serial unfiltered gate passed 1,822 tests in 213 suites. Remaining roster-store
and other direct paths, real-volume evidence, broader Develop persistence/view decomposition, and manual or
external gates remain incomplete.
([validation](plan-status-settings-keyword-archive-inventory-continuation-2026-08-31.md))

**Roster-library persistence continuation (2026-08-31):** the checklist remains 63 of 75. Teams-library root
preparation, enumeration, coordinated record reads/writes, tombstone cleanup, corrupt backup, iCloud conflict
resolution, verified deletion, and remote reload now cross `RosterLibraryPersistenceService` instead of running
synchronously on MainActor. Immutable results distinguish pre-access cancellation, an exact inspected prefix
with already-durable cleanup, cancellation before mutation, and cancellation after a durable write. The
observable owner publishes only current complete snapshots while retaining every durable commit. The affected
seven-suite selection passed 55 tests, the repository gate passed, and the fresh-derived serial unfiltered gate
passed 1,827 tests in 214 suites. Remaining direct paths, real-volume evidence, broader Develop
persistence/view decomposition, and manual or external gates remain incomplete.
([validation](plan-status-roster-library-persistence-continuation-2026-08-31.md))

**Develop input-session continuation (2026-09-01):** the checklist remains 63 of 75. A dedicated
`DevelopWorkspaceInputCoordinator` now owns keyboard, scroll-wheel, and middle-mouse monitor registration plus
preview/filmstrip hover, Space-hand, and keyboard-scroll-target state for one workspace lifetime. Replacement,
reappearance, and teardown remove each injected monitor exactly once, while concrete event interpretation stays
at the existing view boundary. The adjacent four-suite selection passed 41 tests, the repository gate passed,
and the serial unfiltered gate passed 1,832 tests in 215 suites. Broader persistence lifetime, render/source
publication, geometry/view decomposition, filesystem measurement, and manual/external gates remain open.
([validation](plan-status-develop-input-session-continuation-2026-09-01.md))

**Develop batch-persistence continuation (2026-09-01):** the checklist remains 63 of 75. The existing
`DevelopPersistenceSessionCoordinator` now owns the multi-image Develop paste task, request identity, pending
count, explicit cancellation, and success/failure publication. Overlapping writes retain every durable operation
but only the latest request may publish UI state. Workspace teardown deliberately lets a possibly partially
committed write finish while rotating session identity to reject its late result, and write failures now surface
in an active-workspace alert instead of only a log entry. The focused suite passed 10 tests, the adjacent
four-suite selection passed 44 tests, the repository gate passed, and the fresh-derived serial unfiltered gate
passed 1,835 tests in 215 suites. Primary XMP/history task ownership, remaining source/render/geometry view
decomposition, filesystem measurement, and manual/external gates remain open.
([validation](plan-status-develop-batch-persistence-continuation-2026-09-01.md))

**Develop Primary-persistence continuation (2026-09-01):** the checklist remains 63 of 75. The existing
`DevelopPersistenceSessionCoordinator` now owns each Primary XMP/history request's awaiting task, request/image/
workspace identities, pending state, explicit cancellation, and success/cancellation/failure publication while
the serialized durable transaction remains injected. Only the latest overlapping request may publish, image or
workspace replacement rejects late completion, and current failures appear in a Develop alert. The focused suite
passed 13 tests, the adjacent four-suite selection passed 47 tests, the repository gate passed, and the serial
unfiltered gate passed 1,838 tests in 215 suites. Remaining source-decode, render-policy, Metal-publication,
geometry/view decomposition, filesystem measurement, and manual/external gates remain open.
([validation](plan-status-develop-primary-persistence-continuation-2026-09-01.md))

**Develop source-publication continuation (2026-09-01):** the checklist remains 63 of 75. The existing
`DevelopPreviewSessionCoordinator` now owns the retained decoded `NSImage` and `CIImage` together with their
image URL, orientation, session generation, progress, and producer tasks. Quick previews, thumbnail fallbacks,
materialized final decodes, and in-memory rotations publish through image/generation-gated APIs, so an A → B →
A navigation cannot install the first A session's late pixels. Image replacement and teardown clear both
representations at the same lifecycle boundary. The focused suite passed 5 tests, the adjacent four-suite
selection passed 36 tests, the repository gate passed, and the serial unfiltered gate passed 1,841 tests in 215
suites. Remaining decode execution, render-policy, Metal-publication, geometry/view decomposition, filesystem
measurement, and manual/external gates remain open.
([validation](plan-status-develop-source-publication-continuation-2026-09-01.md))

**Develop Metal-publication continuation (2026-09-01):** the checklist remains 63 of 75. Every asynchronous
Develop source-texture upload now carries the preview-session generation into a lock-backed final-publication
gate shared by the editor texture and Clean Feed mirror. Navigation and teardown either reject an obsolete
completed upload or clear it before returning, and in-memory rotation advances identity without blanking the
last good texture so same-URL pre-rotation work is also rejected. The focused three-suite selection passed 16
tests, the repository gate passed, and the serial unfiltered gate passed 1,845 tests in 216 suites. Remaining
decode execution,
render-policy, geometry/view decomposition, filesystem measurement, and manual/external gates remain open.
([validation](plan-status-develop-metal-publication-continuation-2026-09-01.md))

**Develop source-decode continuation (2026-09-01):** the checklist remains 63 of 75. A dedicated
`DevelopSourceDecodeService` actor now owns embedded-RAW preview extraction, HDR-first non-RAW fallback routing,
screen/full-resolution source decode, orientation correction, and bounded preview materialization. Foreground
RAW, zoom-upgrade, and adjacent-image pre-cache requests use one serialized RAW executor, avoiding independent
CIRAWFilter transient-memory peaks while preserving cancellation checks and the existing preview-session/Metal
publication gates. The focused suite passed 4 tests, the adjacent five-suite selection passed 78 tests, the
repository gate passed, and the serial unfiltered gate passed 1,849 tests in 217 suites. Remaining render-policy,
geometry/view decomposition, filesystem measurement, and manual/external gates remain open.
([validation](plan-status-develop-source-decode-continuation-2026-09-01.md))

**Develop preview-geometry continuation (2026-09-01):** the checklist remains 63 of 75. The existing
`DevelopPreviewNavigationCoordinator` now owns normal and confirmed-crop viewport derivation, crop-tool framing,
cursor-anchored zoom, and pan-limit geometry. The view publishes its immutable viewport to Metal/Core Image but
no longer defines the duplicate letterbox, crop-fit, rotation, zoom-anchor, or pan-bound formulas. Seven focused
characterizations and the adjacent 41-test selection passed, the repository gate passed, and the serial
unfiltered gate passed 1,856 tests in 217 suites. Mask/watermark geometry, broader render policy and view
decomposition, filesystem measurement, and manual/external gates remained open.
([validation](plan-status-develop-preview-geometry-continuation-2026-09-01.md))

**Develop layer-geometry continuation (2026-09-01):** the checklist remains 63 of 75. The existing image-scoped
`DevelopLayerGeometryInteractionCoordinator` now owns pane-to-UV projection, EXIF/straighten transforms for
ellipse masks and watermark anchors, brush display-to-sensor conversion, AI-pick source projection, confirmed-
crop watermark framing, and size/margin reclamping from one immutable projection snapshot. The view supplies
current image/presentation facts and retains Metal publication plus durable metadata commits, but no longer
defines those formulas. Seven focused characterizations and the adjacent 56-test selection preserve round trips,
crop framing, overlay/render geometry, and the existing transient commit lifecycle; the repository gate passed,
and the serial unfiltered gate passed 1,860 tests in 217 suites. Broader render policy and view decomposition,
filesystem measurement, and manual/external gates remain open.
([validation](plan-status-develop-layer-geometry-continuation-2026-09-01.md))

**Develop workspace-session continuation (2026-09-01):** the checklist remains 63 of 75. A dedicated
`DevelopWorkspaceSessionCoordinator` now owns the workspace-lifetime named-version flush registration and
replaceable copy/paste/template notice task, including exact-token teardown and identity-gated rejection of an
older timer clearing newer feedback. The view also removes a redundant Core Image preview-publication slot that
was never assigned a rendered value, leaving `DevelopPreviewRenderCoordinator` as the single materialized AppKit
preview owner. Six new characterizations, the adjacent 42-test selection, the repository gate, and the serial
unfiltered 1,871-test run all passed. Further Develop view decomposition, filesystem measurement, and
manual/external gates keep the audit at 63 of 75.
([validation](plan-status-develop-workspace-session-continuation-2026-09-01.md))

**Develop Metal-session and Phase 4.1 completion (2026-09-01):** the checklist advances to 66 of 75, with nine
remaining. `DevelopMetalPreviewSessionCoordinator` now owns live-preview pipeline creation and warmup, its view
coordinator, workspace/source generations, continuous-render state, redraw routing, and teardown. A current
`EditWorkspaceView` inventory finds every major Develop feature state behind a named, characterized owner; its
remaining direct state is presentation, layout, focus, or nested-helper state. The three open Phase 4.1 ownership,
lifecycle/test-seam, and characterization substeps are complete. Four new characterizations, the adjacent
37-test selection, the repository gate, and the serial unfiltered 1,875-test run all passed.
([validation](plan-status-develop-metal-session-phase-completion-2026-09-01.md))

**Import metadata-scan continuation (2026-09-01):** the checklist remains 66 of 75. Import capture-date reads
and same-date destination-folder discovery now cross injected serialized actors instead of ad-hoc detached tasks.
Both boundaries return immutable complete or exact cancelled-prefix evidence, check cancellation around each
non-preemptible read, and let the MainActor publish only the current request. Eight new characterizations, the
adjacent 38-test selection, the repository gate, and the serial unfiltered 1,883-test run all passed. Other
lower-priority direct paths and the real-volume/signpost/Thread Performance Checker evidence keep all three broad
Phase 3.1 substeps open. ([validation](plan-status-import-metadata-scan-continuation-2026-09-01.md))

**Import voice-memo association continuation (2026-09-01):** the checklist remains 66 of 75. Sony dual-card
voice-memo EXIF and file-date reads, security-scope lifetime, and deterministic association now cross one injected
serialized actor instead of an ad-hoc detached task. The boundary returns immutable complete reports or exact
cancelled-prefix counts, while `ImportViewModel` cancels and identity-gates replacement, clear, reset, and teardown
work. Five new characterizations, the adjacent 37-test selection, the repository gate, and the serial unfiltered
1,888-logical-test/2,015-expanded-run gate passed. Other lower-priority direct paths and real-volume/signpost/Thread
Performance Checker evidence keep all three broad Phase 3.1 substeps open.
([validation](plan-status-import-voice-memo-association-continuation-2026-09-01.md))

**Batch Rename relocation continuation (2026-09-02):** the checklist remains 66 of 75. Successful rename
publication in Browser, Compare, and Analysis now uses a pure immutable `ImageFile` relocation projection instead
of synchronously reading destination and sidecar resource values from three MainActor owners. The filesystem-
backed copy initializer remains only in the serialized Duplicate service, where destination facts are required.
Two new characterizations, the focused 17-test suite, the integrated 131-test selection, and the repository gate
passed. The unchanged 10,000-file planning benchmark passed in isolation after one full-suite contention failure.
A follow-up 58.697-second serial run excluding only that separately passing benchmark covered the rest of the suite
without failures. Other lower-priority direct paths and real-volume/signpost/Thread Performance Checker evidence
keep all three broad Phase 3.1 substeps open.
([validation](plan-status-batch-rename-relocation-continuation-2026-09-02.md))

**Face folder-load continuation (2026-09-02):** the checklist remains 66 of 75. Folder navigation now sends
`.face_data` decode, expiration cleanup, and complete all-face thumbnail reads through one injected serialized
actor. The boundary returns immutable complete or exact cancelled-prefix evidence, records cleanup that committed
before cancellation, and lets `FaceRecognitionViewModel` publish only the current folder request. SwiftUI
thumbnail lookup is cache-only; scans publish newly written thumbnail bytes directly and refresh the final cache
through the same actor. Six new characterizations, the adjacent 33-test selection, the repository gate, and the
serial unfiltered 1,896-test run passed. Remaining face-data mutations, other lower-priority direct paths, and
real-volume/signpost/Thread Performance Checker evidence keep all three broad Phase 3.1 substeps open.
([validation](plan-status-face-folder-load-continuation-2026-09-02.md))

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

**Template-preview and import-bundle follow-up (2026-08-30):** metadata-template bundle preview now serializes
the selected-bundle read and current-template inventory on `TemplateImportPreviewService`, and voice-memo bundle
collision planning resolves image, memo, and backup suffixes on `ImportPreflightService`. Both return immutable
complete/cancelled evidence and their MainActor owners reject stale publication before mutation. Template
load/save/delete/export/import-commit and other direct paths plus the real-volume measurement gate remain open.
([validation](plan-status-template-bundle-export-continuation-2026-08-30.md))

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

**Cleanup and storage-summary follow-up (2026-08-30):** failed RAW archive signing now submits both newly
created output removals to a serialized compensation actor, which protects the source sidecar and reports
per-artifact durable evidence even under cancellation or partial failure. Known People recursive byte counting
runs on a cancellable serialized actor with request-identity publication in Settings. Back Up Edited Files now
prepares its deterministic destination-directory set through `ExportDirectoryService` and suppresses copy work
when cancellation is observed after a durable directory commit. Remaining direct paths and the real-volume/
Thread Performance Checker gate stay open.
([validation](plan-status-cleanup-storage-white-balance-continuation-2026-08-30.md))

**Template CRUD and keyword-archive import follow-up (2026-08-30):** metadata and Develop template inventory,
save, delete, shortcut-conflict clearing, and export now cross one serialized generic actor with immutable
read/commit evidence, durable-prefix reporting, request-identity publication, and stale-result rejection.
Keyword-list archive extraction, manifest reads, append/replace merging, and multi-file commits cross a separate
serialized actor that reports cancellation before mutation versus cancellation/failure after an exact durable
prefix. Store notifications are published for every committed destination even after the sheet disappears.
Other lower-priority direct paths and the real-volume/Thread Performance Checker gate remain open.
([validation](plan-status-template-keyword-interactive-render-continuation-2026-08-30.md))

**Quick List mutation and iCloud routing follow-up (2026-08-31):** Metadata-panel appends, missing-list
detection, and first-use file import now share `KeywordListEditorPersistenceService` with Settings editor
loads/saves, eliminating the read/merge/write race and synchronous MainActor probes. Keyword Lists iCloud root
resolution and tree reconciliation now cross `KeywordListsRoutingService`; the UI publishes a pending desired
state, cancels superseded requests, and applies only the latest result. The prior destination-ordered union for
flat lists and preserve-existing policy for structured trees remains intact. Lower-priority direct paths and the
real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-quick-list-routing-continuation-2026-08-31.md))

**Roster-library persistence follow-up (2026-08-31):** reusable Teams-library enumeration, coordinated reads
and writes, tombstone retention/cleanup, corrupt backup, conflict resolution, verified deletion, and remote
reload now run on a serialized actor. MainActor owns only the observable snapshot, request identity, durable
commit publication, and self-write stamps. Loads report complete or exact cancelled-prefix evidence; mutations
distinguish cancellation before commit from cancellation observed after durability. Other lower-priority direct
paths and the real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-roster-library-persistence-continuation-2026-08-31.md))

**Import metadata-scan follow-up (2026-09-01):** capture-date EXIF/modification-time discovery and existing
same-date destination-folder suggestions now run on injected serialized actors. Each actor returns immutable
complete or exact cancelled-prefix evidence and samples cancellation before and after every synchronous read.
`ImportViewModel` owns request identity, cancels replacement/source-reset work, rejects late evidence, and applies
the current import title only after a complete capture scan. Eight focused characterizations cover grouping,
fallbacks, actor serialization, post-read cancellation, replacement rejection, and source delegation. The
adjacent five-suite selection passed 38 tests, the repository gate passed, and the serial unfiltered gate passed
1,883 tests in 221 suites. Other lower-priority direct paths and real-volume signpost/Thread Performance Checker
evidence remain open. ([validation](plan-status-import-metadata-scan-continuation-2026-09-01.md))

**Import voice-memo association follow-up (2026-09-01):** Sony dual-card primary/companion EXIF reads and WAV
resource-date reads now run on `ImportVoiceMemoAssociationScanService`, which also owns security-scoped access and
final association on one serialized actor. Cancellation reports exact processed-prefix counts around every
non-preemptible read; the view model publishes only a complete result carrying its current request identity. Other
lower-priority direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-import-voice-memo-association-continuation-2026-09-01.md))

**SwiftMediaMetadata 3 migration (2026-09-02):** the checklist remains 66 of 75. The app now resolves the
renamed upstream package at version 3.0.0 instead of compiling a checked-in SwiftExif 1.9.10 snapshot.
Imports and direct API references are migrated, the obsolete vendored tree is removed, and version-3
behavior replaces app-owned PLUS Image Supplier, file-creation-date, and rendered-TIFF compatibility
workarounds. Focused metadata and import validation passed 77 tests; the complete serial gate passed
1,888 logical tests (2,015 expanded executions) with zero failures or skips.
([validation](swift-media-metadata-3-migration-validation-2026-09-02.md))

**Batch Rename relocation follow-up (2026-09-02):** successful rename publication no longer reconstructs
`ImageFile` values by reading destination and sidecar resource values from MainActor owners. Browser, Compare,
and Analysis use an immutable path-only relocation projection that preserves the already-captured file facts; the
filesystem-backed copy initializer remains on `FileSystemService` for Duplicate. Other lower-priority direct paths
and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-batch-rename-relocation-continuation-2026-09-02.md))

**Face folder-load follow-up (2026-09-02):** folder navigation no longer decodes `.face_data`, evaluates expiry,
or reads face thumbnails on the MainActor. `FaceDataFolderLoadService` serializes the complete snapshot, reports
exact cancellation and committed-cleanup evidence, and `FaceRecognitionViewModel` identity-gates publication.
Render-time thumbnail lookup is cache-only, including during scans. Remaining face-data mutations, other direct
paths, and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-face-folder-load-continuation-2026-09-02.md))

**Face persistence follow-up (2026-09-02):** interactive face edits, scan preparation/finalization, document and
thumbnail commits, cleanup/deletion, Caption, metadata variables, FTP preflight, rename reassociation, and lens
prewarming now share the serialized face-data actor. Immutable results distinguish pre-commit cancellation from
durable document commits and exact thumbnail-cleanup outcomes; ordered view-model revisions keep UI updates
immediate without blocking MainActor. Other lower-priority direct paths and real-volume/signpost/Thread Performance
Checker exit evidence remain open.
([validation](plan-status-face-persistence-continuation-2026-09-02.md))

**Source revision capture follow-up (2026-09-02):** canonical path resolution, both resource-value probes, and
streamed SHA-256 hashing now run as one contiguous transaction on `SourceImageRevisionCaptureService`. Cancellation
is sampled around every non-preemptible filesystem stage, and overlapping captures cannot interleave their stat-hash-
stat sequences. Three new characterizations, the integrated 151-test selection, repository gate, and serial
unfiltered 1,906-test run passed. Other lower-priority direct paths and real-volume/signpost/Thread Performance
Checker exit evidence remain open.
([validation](plan-status-source-revision-capture-continuation-2026-09-02.md))

**AuraFace component-probe follow-up (2026-09-02):** signed installed-component verification, package enumeration,
file reads, hashing, and bundled fallback resolution now run on `AuraFaceComponentProbeService` instead of during
MainActor manager/embedder initialization. Immutable resolution, explicit Checking state, cancellation, and request
identity prevent partial or stale availability publication; install and removal re-enter the same fail-closed probe.
Two new characterizations, the adjacent face/Known People selection, repository gate, and serial unfiltered
1,908-logical-test/2,035-expanded-run gate passed. Other lower-priority direct paths and real-volume/signpost/Thread
Performance Checker exit evidence remain open.
([validation](plan-status-auraface-probe-continuation-2026-09-02.md))

**Browser and Compare presentation-facts follow-up (2026-09-02):** Browser retina pre-cache and committed-source
comparison now await the existing serialized `FullScreenImagePresentationFactsService` instead of reading XMP
sidecars and image headers from their MainActor orchestration. Browser gates both the facts result and final decode
by request identity plus current selection; Compare validates request/image identity and keeps its existing session
publication gate. Two new characterizations, the focused 6-test suite, the adjacent 47-test selection, repository
gate, and serial unfiltered 1,910-test run passed. Other lower-priority direct paths and real-volume/signpost/Thread
Performance Checker exit evidence remain open.
([validation](plan-status-browser-comparison-presentation-facts-continuation-2026-09-02.md))

**Face scan signature follow-up (2026-09-02):** incremental face-scan classification and the signature captured
after each successful detection now use one serialized `FaceScanFileSignatureService` actor. Complete immutable
path sets cross back to the scan owner; cancellation reports an exact processed prefix and never installs partial
classification, while cancelled or unreadable post-detection signatures keep the image eligible for a future scan.
Four new characterizations, the focused 17-test selection, repository gate, and serial unfiltered 1,914-test run
passed. Other lower-priority direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain
open. ([validation](plan-status-face-scan-signature-continuation-2026-09-02.md))

**Metadata inspector filesystem follow-up (2026-09-02):** Raw Metadata XMP loading and the technical-metadata
ImageIO/file-stat fast path now run on dedicated serialized actors rather than ad hoc detached work started by
MainActor-owned views. Immutable request/image-keyed results, explicit before/after-read cancellation, disappearance
invalidation, and repeated publication guards close stale A → B → A selection races through SwiftExif enrichment.
Eight new characterizations, the focused 12-test selection, adjacent 73-test selection, repository gate, and serial
unfiltered 1,922-test run passed. Other lower-priority direct paths and real-volume/signpost/Thread Performance
Checker exit evidence remain open.
([validation](plan-status-metadata-inspector-filesystem-continuation-2026-09-02.md))

**Browser orientation filesystem follow-up (2026-09-02):** eager XMP/ImageIO orientation reads for initial folder
loads and incremental refresh now run as one transaction on the Browser's existing serialized `FileSystemService`
instead of an ad hoc parallel task group. Immutable request-tagged snapshots distinguish complete results from exact
cancelled prefixes; replacement folder loads invalidate request identity before issuing new I/O. A privacy-safe
signpost records only result state and aggregate counts. Five new characterizations, the focused 24-test suite,
adjacent 39-test selection, repository gate, and serial unfiltered 1,927-test run passed. Other lower-priority direct
paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-browser-orientation-filesystem-continuation-2026-09-02.md))

**Clean Feed browse-render follow-up (2026-09-03):** passive Clean Feed rendering now crosses a request-tagged
actor instead of owning a detached RAW/ImageIO pipeline in its SwiftUI view. Image-header facts reuse the serialized
presentation boundary, RAW previews share Develop's serialized draft decoder, and immutable complete/cancelled
evidence is validated against request identity, image identity, current selection, and browse-mode ownership.
Entering Develop mode or removing the view cancels and invalidates browse work. Five new characterizations and the
adjacent 48-test selection, repository gate, and serial unfiltered 1,932-test run passed. Other lower-priority direct
paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-clean-feed-browse-render-continuation-2026-09-03.md))

**Voice-memo rename-planning follow-up (2026-09-03):** Browser batch-rename entry now sends hidden relationship
enumeration and record decoding through a serialized actor instead of performing that synchronous work on
MainActor. Immutable request-tagged snapshots distinguish complete results from exact cancelled or failed prefixes;
request, folder, and current-selection guards prevent partial or stale plans from opening the rename sheet. A
privacy-safe signpost records only result state and aggregate counts. Four new characterizations, the adjacent
66-test selection, repository gate, and serial unfiltered 1,936-test run passed. Other lower-priority direct paths
and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-voice-memo-rename-planning-continuation-2026-09-03.md))

**Path-containment and cached-identity follow-up (2026-09-03):** Import primary/voice-memo destination safety and
Browser folder-rename containment now cross one serialized actor instead of walking existing ancestors and resolving
symlinks on MainActor. Immutable request-tagged results distinguish complete containment or the first escape from an
exact cancelled prefix. The voice-memo association actor also returns its canonical source map, removing repeated
filesystem canonicalization from Import's computed UI projections. Four new characterizations, the focused 12-test
selection, adjacent Import/Browser regressions, repository gate, and serial unfiltered 1,940-test run passed. Other
lower-priority direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-path-containment-identity-continuation-2026-09-03.md))

**Export Camera Raw sidecar-resolution follow-up (2026-09-03):** local Save/Export/Archive and FTP render/preflight
no longer load RAW XMP fallback settings through a MainActor helper. One serialized actor receives the live workspace
snapshot, reads only RAW files that lack a live value, and returns immutable complete or exact cancelled-prefix
evidence. A privacy-safe signpost records result state and aggregate inspected counts. Three new characterizations
and the adjacent 30-test export/FTP selection passed; the repository gate and serial unfiltered 1,943-test run also
passed. Other lower-priority direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain
open.
([validation](plan-status-export-camera-raw-resolution-continuation-2026-09-03.md))

**Browser HDR-classification follow-up (2026-09-03):** Browser metadata batches no longer inspect ImageIO headers
and mapped JPEG/HEIF gain-map container data while merging results on MainActor. One serialized actor returns
immutable request-tagged classifications with complete or exact cancelled-prefix evidence, and Browser publication
requires a complete snapshot for the exact current batch. A privacy-safe signpost records only result state and
aggregate inspected counts. Four new characterizations and the focused 9-test Browser filesystem-boundary selection
passed; the adjacent 71-test selection, repository gate, and serial unfiltered 1,947-test run also passed. Other
lower-priority direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-browser-hdr-classification-continuation-2026-09-03.md))

**Export artifact-finalization follow-up (2026-09-04):** post-render RAW sidecar copying, compensation that removes
an incomplete archive when its authoritative sidecar cannot be finalized, and the Finder-visibility postcondition now
run on one serialized actor rather than returning to the caller's actor after rendering. Immutable durable evidence
records sidecar finalization, visibility repair, and cancellation observed before or after the intentionally
non-preemptible transaction. A privacy-safe signpost records only outcome flags. Three new characterizations and the
focused 22-test export suite passed; the adjacent 53-test export/archive/FTP selection, repository gate, and serial
unfiltered 1,950-test run also passed. Other lower-priority direct paths and real-volume/signpost/Thread Performance
Checker exit evidence remain open.
([validation](plan-status-export-artifact-finalization-continuation-2026-09-04.md))

**Settings Quick List cache follow-up (2026-09-04):** initial and replacement Settings/Metadata Quick List reads now
cross the existing serialized keyword-list actor and publish only a complete result for the current request. SwiftUI
entry and availability queries are cache-only; route-change notifications invalidate cached URLs before reloading.
Import, append, replace, and delete mutations use the same actor and publish every durable commit without repeating
file I/O on MainActor. Immutable results distinguish complete work from exact cancellation prefixes, and a privacy-
safe signpost records only outcome state and aggregate counts. Four new characterizations and the focused 15-test
suite passed; the adjacent 30-test selection, repository gate, and serial unfiltered 1,954-test run also passed. Other
lower-priority direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-settings-quick-list-cache-continuation-2026-09-04.md))

**Browser monitor-setup follow-up (2026-09-04):** Browser pane synchronization no longer performs the synchronous
directory probe and FSEvents construction on MainActor. A serialized actor returns immutable created, unavailable,
pre-setup-cancelled, or post-setup-cancelled evidence and stops a stream created by cancelled work. Per-pane setup
tasks plus request/folder identity reject stale monitor publication after navigation, pane removal, stop, or teardown.
A privacy-safe signpost records only setup outcome. Four new characterizations and the focused 31-test monitor/
sidecar selection passed; the repository gate and serial unfiltered 1,958-test run also passed. Other lower-priority
direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-browser-monitor-setup-continuation-2026-09-04.md))

**Known People iCloud-routing follow-up (2026-09-04):** enable/disable no longer resolves the ubiquity container or
recursively reconciles the Known People database from `ICloudSyncCoordinator` on MainActor. One serialized actor
returns immutable unavailable, pre-commit cancellation, or durable-commit evidence; request identity gates the
preference, cache route, privacy confirmation, and cloud watcher. The watcher and Settings storage summary reuse
actor-resolved roots instead of probing iCloud from MainActor. Three new characterizations cover direction,
off-main execution, unavailable iCloud, and cancellation stages. The adjacent 52-test selection, repository gate,
and serial unfiltered 1,961-test run passed. Other lower-priority direct paths and real-volume/signpost/Thread
Performance Checker exit evidence remain open.
([validation](plan-status-known-people-icloud-routing-continuation-2026-09-04.md))

**Teams and Watermark iCloud-routing follow-up (2026-09-04):** enable/disable no longer resolves the ubiquity
container or recursively reconciles either library from `ICloudSyncCoordinator` on MainActor. Two instances of one
serialized actor return immutable unavailable, pre-commit cancellation, or durable-commit evidence; independent
request identities gate each preference, cache route, reload, and cloud watcher. Both watchers reuse actor-resolved
roots for startup and notification filtering rather than probing or preparing iCloud on MainActor. Two new
characterizations cover direction, off-main execution, unavailable iCloud, and durable cancellation. The focused
18-test suite, adjacent 30-test selection, repository gate, and serial unfiltered 1,963-test run passed. Other lower-
priority direct paths, the security-scoped Templates route, and real-volume/signpost/Thread Performance Checker
exit evidence remain open.
([validation](plan-status-library-icloud-routing-continuation-2026-09-04.md))

**Templates iCloud-routing follow-up (2026-09-04):** enable/disable no longer resolves the custom-folder bookmark,
holds its security scope, resolves the ubiquity container, or recursively reconciles metadata and Develop templates
from `ICloudSyncCoordinator` on MainActor. One serialized actor balances the local security scope for unavailable,
cancelled, durable, and throwing paths and returns immutable cancellation or commit evidence. Request identity gates
preference publication; Settings and the main window reload template inventories only after a post-commit storage-
change notification. Three new characterizations cover direction, off-main execution, exact scope-release counts,
unavailable iCloud, both cancellation stages, and errors. The focused 21-test suite, adjacent 48-test selection,
repository gate, and serial unfiltered 1,966-test run passed. Other lower-priority direct paths and real-volume/
signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-template-icloud-routing-continuation-2026-09-04.md))

**iCloud availability-cache follow-up (2026-09-04):** the Sync footer and Preferences toggle no longer resolve
the app's ubiquity container on MainActor. One serialized actor returns immutable available, unavailable,
pre-resolution-cancelled, or post-resolution-cancelled evidence and records a privacy-safe outcome signpost. The
coordinator owns cached checking/available/unavailable presentation state, replacement task identity, and pending
Preferences intent; it enables Preferences sync only after the current probe reports available. Three new
characterizations cover off-main execution, both availability outcomes, both cancellation stages, and the exact
preference-commit gate. The focused 24-test suite and adjacent 51-test selection passed. Other lower-priority
direct paths and real-volume/signpost/Thread Performance Checker exit evidence remain open. The repository gate
and final serial unfiltered run also passed, with 1,969 tests in 228 suites.
([validation](plan-status-icloud-availability-cache-continuation-2026-09-04.md))

**Advanced Export preview-cleanup follow-up (2026-09-04):** releasing a comparison preview no longer recursively
removes its full-resolution private artifact folder from a SwiftUI-owned storage object's `deinit`. One serialized
actor returns immutable pre-removal cancellation, durable removal with post-commit cancellation, or failure evidence;
the lifetime fallback performs only a non-cancellable asynchronous handoff, and a privacy-safe signpost records the
outcome. Four new characterizations prove off-main execution, serialization, both cancellation stages, injected
failure evidence, and nonblocking final release. The focused 4-test suite, adjacent 26-test export selection,
repository gate, and final serial unfiltered run of 1,973 tests in 229 suites passed. Other lower-priority direct
paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-advanced-export-preview-cleanup-continuation-2026-09-04.md))

**Analysis annotation-index follow-up (2026-09-04):** Analysis thumbnail and map annotation counts no longer
resolve each presented image path's symlinks from a synchronous SwiftUI lookup. `AnalysisWorkspaceModel` publishes
an in-memory URL-to-case index whenever its actor-loaded folder cases, current case, or presented source changes.
Canonical stored identity and the known Browser folder route are both indexed, preserving security-scoped/symlinked
presentation and rename behavior without another filesystem projection. Two new characterizations cover a removed
presentation symlink and the filesystem-free lookup source contract. The focused 70-test Analysis suite, repository
gate, and final serial unfiltered run of 1,975 tests in 229 suites passed. Other lower-priority direct/cached-model
paths and real-volume/signpost/Thread Performance Checker exit evidence remain open.
([validation](plan-status-analysis-annotation-index-continuation-2026-09-04.md))

**Watermark persistence/cache follow-up (2026-09-04):** opening and remotely refreshing the Watermark library,
reading PNG previews, renaming assets, updating defaults, and deleting assets no longer perform coordinated
filesystem work from the MainActor store. One serialized actor owns root preparation, complete metadata/PNG loads,
tombstone cleanup, conflict resolution, security-scoped import, metadata commits, and durable deletion. Immutable
snapshots and explicit cancellation/commit evidence feed cache-only synchronous presentation accessors; initial
iCloud/local root resolution also uses the routing actor. Two new characterizations and source contracts cover
off-main snapshot loading, pre-access cancellation, serialized mutations, and cache-only presentation. The focused
39-test Watermark/iCloud selection, repository gate, and final serial unfiltered run of 1,977 tests in 229 suites
passed. Other lower-priority direct/cached-model paths and real-volume/signpost/Thread Performance Checker exit
evidence remain open.
([validation](plan-status-watermark-persistence-cache-continuation-2026-09-04.md))

**Known People thumbnail-cache follow-up (2026-09-04):** person and embedding thumbnail JPEG reads no longer
run synchronously from SwiftUI or the MainActor service. One serialized actor returns immutable data with explicit
pre/post-read cancellation evidence and privacy-safe signposts; storage revision and request identity reject stale
publication. Bounded person/embedding caches serve synchronous presentation and are invalidated by storage changes,
resets, deletes, and remote events. Known People views and team roster export now await the actor boundary and use
in-memory rendering inputs. Two new characterizations, the focused 43-test Known People/iCloud/roster selection,
repository gate, and final serial unfiltered run of 1,979 tests in 229 suites passed. Other lower-priority direct/
cached-model paths and real-volume/signpost/Thread Performance Checker evidence remain open.
([validation](plan-status-known-people-thumbnail-cache-continuation-2026-09-04.md))

**Known People archive-preparation follow-up (2026-09-04):** Known People ZIP export no longer creates and
populates its temporary tree, reads coordinated person/embedding thumbnails, or launches `ditto` from MainActor.
ZIP import extraction, directory discovery, `people.json` decoding, and thumbnail reads now use the same
exclusive serialized actor and return one immutable payload. Cancellation is sampled around every synchronous
read and archive command, and a storage-revision guard prevents a payload prepared before a local/iCloud switch
from committing into the newly selected store. An off-main/cancellation characterization and a real ZIP
people/thumbnail round trip pass with the focused Known People suite; the repository gate and final serial
unfiltered run of 1,981 tests in 229 suites also pass. Import destination commits, other lower-priority direct/
cached-model paths, and real-volume/signpost/Thread Performance Checker evidence remain open.
([validation](plan-status-known-people-archive-continuation-2026-09-04.md))

**Known People import-commit follow-up (2026-09-04):** archive import destination writes now cross the same
serialized actor as preparation. An immutable request freezes the storage root, duplicate-filtered people, and
thumbnail bytes; complete, cancelled, and failed results return exact durable person and thumbnail evidence.
`KnownPeopleService` revision-gates publication, stamps every committed local write, and installs the durable
person prefix before surfacing cancellation or a later failure, keeping its MainActor cache aligned with disk.
A cancellation-after-first-write characterization, production source contract, and real ZIP round trip pass in
the 16-test focused suite; the adjacent 44-test selection, repository gate, and serial unfiltered run of 1,982
tests in 229 suites also pass. Other lower-priority direct/cached-model paths and real-volume/signpost/Thread
Performance Checker evidence remain open.
([validation](plan-status-known-people-import-commit-continuation-2026-09-04.md))

**Approved List cache follow-up (2026-09-04):** Approved Keywords initialization, anonymous-notification refresh,
legacy save, and deletion now reuse the serialized keyword-list persistence actor instead of synchronously reading
or mutating the managed file through the MainActor store. Loads own cancellable tasks and request identity; only a
complete current URL snapshot is published, while imports and saves install exact durable-entry evidence without a
second read. Identified writers own their publication, and anonymous editor, migration, routing, or remote changes
schedule a serialized refresh. Two new characterizations and source contracts cover off-main normalized loading,
cache-only synchronous accessors, actor-backed save/delete, and the awaited Settings removal. The focused 22-test
selection, adjacent 56-test selection, repository gate, and serial unfiltered run of 1,984 tests in 229 suites
passed. Other lower-priority direct/cached-model paths and real-volume/signpost/Thread Performance Checker evidence
remain open.
([validation](plan-status-approved-list-cache-continuation-2026-09-04.md))

**Open Recent bookmark follow-up (2026-09-04):** launch-time stale-bookmark resolution, security-scope retention,
and bookmark creation when opening a folder no longer run synchronously on MainActor. One serialized actor returns
an immutable complete snapshot or exact cancellation-prefix evidence; the observable store publishes only current
complete loads, and Clear Menu invalidates late load or creation results. Folder scanning awaits the actor so access
is retained before descendant work starts without blocking the UI executor. Two new characterizations cover
off-main resolution/creation and pre-access cancellation. The focused 8-test suite, adjacent 18-test selection,
repository gate, and serial unfiltered run of 1,986 tests in 229 suites passed. Favorite-folder bookmarks, other
lower-priority direct/cached-model paths, and real-volume/signpost/Thread Performance Checker evidence remain open.
([validation](plan-status-recent-folder-bookmark-continuation-2026-09-04.md))

**Favorite-folder bookmark follow-up (2026-09-04):** launch-time stale-bookmark resolution, security-scope
retention, Add to Favorites bookmark creation, and bookmark refresh after moving a favorite root no longer invoke
the bookmark APIs on MainActor. A serialized actor returns immutable request-tagged snapshots and commits with
explicit pre-access, inspected-prefix, and post-access cancellation evidence. The browser publishes only complete
current loads, waits for launch resolution before scanning favorite roots, preserves an existing move-following
bookmark if refresh produces no replacement, and persists refreshed or newly created bookmark data. Three new
characterizations cover off-main resolution/creation, complete publication and persistence, pre-access cancellation,
and cancellation observed after a non-preemptible bookmark API. The focused 13-test selection, adjacent 28-test
selection, repository gate, and serial unfiltered run of 1,989 tests in 229 suites passed. Other lower-priority
direct/cached-model paths and real-volume/signpost/Thread Performance Checker evidence remain open.
([validation](plan-status-favorite-folder-bookmark-continuation-2026-09-04.md))

**Settings template bookmark follow-up (2026-09-04):** launch-time custom Templates-folder bookmark resolution,
stale refresh, and chooser-time bookmark creation no longer invoke security-scoped bookmark APIs on MainActor. A
serialized actor returns immutable request-tagged failure, cancellation, snapshot, or creation evidence and balances
temporary security-scope access around creation. Settings publishes only a complete current restoration or creation,
persists refreshed data without a second bookmark call, and cancels and invalidates pending work when replacing or
clearing the selection. Template reloads await the selected-folder request. Four new characterizations cover off-main
execution, balanced scope access, durable publication and clearing, and both cancellation stages. The focused 4-test
suite, adjacent 53-test selection, repository gate, and serial unfiltered run of 1,993 tests in 230 suites passed.
The Import backup bookmark, other lower-priority direct/cached-model paths, and real-volume/signpost/Thread
Performance Checker evidence remain open.
([validation](plan-status-settings-template-bookmark-continuation-2026-09-04.md))

**Import destination bookmark follow-up (2026-09-04):** launch-time primary and backup destination bookmark
resolution, stale refresh, and chooser-time creation no longer invoke security-scoped bookmark APIs on MainActor.
One serialized actor returns immutable request-tagged failure, cancellation, snapshot, or creation evidence and
balances temporary security-scope access. Import publishes only complete current restorations and creations,
persists stale refreshes without a second bookmark call, rejects superseded results, and cancels and invalidates
pending backup work when Clear is selected. Four new characterizations cover off-main execution, balanced scope
access, complete publication and persistence, late-result rejection, and cancellation around non-preemptible APIs.
The focused 21-test suite, adjacent 41-test selection, repository gate, and serial unfiltered run of 1,997 tests in
230 suites passed. Other lower-priority direct/cached-model paths and real-volume/signpost/Thread Performance
Checker evidence remain open.
([validation](plan-status-import-destination-bookmark-continuation-2026-09-04.md))

**SwiftExif technical-snapshot follow-up (2026-09-04):** full technical-metadata enrichment no longer returns the
generic SwiftExif dictionary to MainActor before optionally opening the image container for native profile and bit-
depth facts. The existing per-photo metadata executor now retains its lock across parsing, ImageIO inspection, and
construction of one Sendable `TechnicalMetadata` snapshot, preventing both UI blocking and a write interleaving
between the two source reads. Three new characterizations cover off-main assembly, exact native-read intent, and the
source contract. The adjacent 118-logical-test/123-expanded-run selection, repository gate, and serial unfiltered
2,000-logical-test/2,127-expanded-run gate passed. Other lower-priority direct/cached-model paths and real-volume/
signpost/Thread Performance Checker evidence remain open.
([validation](plan-status-swiftexif-technical-snapshot-continuation-2026-09-04.md))

**Import source security-scope follow-up (2026-09-04):** primary and optional voice-memo source discovery now owns
its complete security-scope lifetime on the existing serialized discovery actor. The synchronous file-provider
access call no longer runs in the MainActor-inheriting voice-memo scan task, both source paths use the same boundary,
and cancellation is sampled before and after acquisition while every successfully acquired scope is balanced by an
actor-owned stop. Four new characterizations cover executor isolation, balanced and unavailable access, cancellation
before and during the non-preemptible API, and the caller source contract. The focused 8-test suite, adjacent 45-test
import selection, repository gate, and serial unfiltered 2,004-test run passed. Other lower-priority direct/cached-
model paths and real-volume/signpost/Thread Performance Checker evidence remain open.
([validation](plan-status-import-source-security-scope-continuation-2026-09-04.md))

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

- [x] Extract state-owning coordinators such as Develop session, versions, masks, and rendering; do not merely
  move extensions between files.
  ([validation](plan-status-develop-metal-session-phase-completion-2026-09-01.md), 2026-09-01)
- [x] Define lifecycle, cancellation, persistence, and test seams for each coordinator.
  ([validation](plan-status-develop-metal-session-phase-completion-2026-09-01.md), 2026-09-01)
- [x] Replace the global command notification bus incrementally with a typed, scene-scoped `AppCommand`
  router; retain NotificationCenter for genuine system/process broadcasts.
  ([validation](plan-status-follow-up-validation-2026-08-29.md#scene-ui-handoff-router-completion), 2026-08-29)
- [x] Add a characterization test before each extraction and keep UI behavior unchanged.
  ([validation](plan-status-develop-metal-session-phase-completion-2026-09-01.md), 2026-09-01)

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

**White-balance state-owner follow-up (2026-08-30):** `DevelopWhiteBalanceSessionCoordinator` now owns
image-scoped as-shot neutral values, eyedropper/marquee lifecycle, sample request replacement, RAW/non-RAW
display and clamping projections, logarithmic Kelvin mapping, pane-to-source geometry, and preview-only versus
durable-commit intent. Navigation, deactivation, replacement, and teardown reject late neutral/sample results.
Pixel averaging, Metal solving, render publication, and metadata persistence remain at their existing injected
boundaries. Layer, broader render-policy/publication, export, and persistence ownership remain open.
([validation](plan-status-cleanup-storage-white-balance-continuation-2026-08-30.md#develop-white-balance-state-owner))

**Export state-owner follow-up (2026-08-30):** `DevelopExportSessionCoordinator` now owns workspace lifetime,
single-flight export task and request identity, cancellation, busy/error presentation, and durable output evidence.
Rendering, destination preparation, metadata copying, and thumbnail invalidation remain injected at their existing
boundaries, and late work cannot publish into a closed or replacement workspace. Layer, broader render-policy, and
metadata/sidecar persistence ownership remain open.
([validation](plan-status-template-bundle-export-continuation-2026-08-30.md#develop-export-state-owner))

**Interactive-render state-owner follow-up (2026-08-30):** `DevelopInteractiveRenderCoordinator` now owns
workspace/image interaction lifetime, slider-active state, preview-only versus commit intent, CPU-scope
throttling, cancellation, and stale-publication identity. Slider, curve, HSL, mask, and watermark interactions
delegate to the coordinator while concrete rendering, scope notifications, and XMP/named-version persistence
remain injected at the view boundary. Broader metadata/sidecar persistence and undo ownership remain open.
([validation](plan-status-template-keyword-interactive-render-continuation-2026-08-30.md))

**Persistence-routing state-owner follow-up (2026-08-31):** `DevelopPersistenceSessionCoordinator` now owns
the final Primary-versus-named-version dispatch policy used by normal adjustments and Develop reset. It publishes
the image snapshot before exactly one injected durable action and suppresses every action outside an active
workspace. Concrete XMP/history and version-catalog writers remain injected, preserving their current file
semantics and keeping broader task lifetime, cancellation, publication, and view decomposition work open.
([validation](plan-status-develop-persistence-routing-continuation-2026-08-31.md))

**Workspace-input state-owner follow-up (2026-09-01):** `DevelopWorkspaceInputCoordinator` now owns the local
keyboard, scroll-wheel, and middle-mouse monitor registrations together with preview/filmstrip hover, temporary
Space-hand, and keyboard-scroll-target state. Replaced, inactive, interrupted, and ended sessions remove their
monitor tokens through one lifecycle boundary; `EditWorkspaceView` retains event interpretation and UI effects.
Five focused characterizations and the adjacent 41-test regression preserve established input behavior. Broader
persistence task lifetime and remaining source/render/geometry view decomposition stay open.
([validation](plan-status-develop-input-session-continuation-2026-09-01.md))

**Batch-persistence state-owner follow-up (2026-09-01):** `DevelopPersistenceSessionCoordinator` now owns
multi-image Develop paste task creation, request identity, pending state, explicit cancellation, and observable
success/failure publication. Concurrent requests continue across the existing serialized metadata engine, with
latest-request-wins UI publication and retained durable completion for older requests. Ending the workspace does
not cancel a write that may already be partially committed; it rotates session identity so that completion cannot
publish into a closed or replacement workspace. XMP serialization, crop aspect grouping, and structured-data
semantics remain at their existing injected boundaries. Three new lifecycle characterizations plus updated source
contracts cover success, failure, cancellation, overlap, teardown, and view routing. Primary XMP/history task
ownership and remaining source/render/geometry view decomposition stay open.
([validation](plan-status-develop-batch-persistence-continuation-2026-09-01.md))

**Primary-persistence state-owner follow-up (2026-09-01):** `DevelopPersistenceSessionCoordinator` now owns
the awaiting task, request/image/workspace identities, pending state, explicit cancellation, and typed result
publication for normal Primary XMP/history saves and Develop resets. The durable metadata transaction remains at
its established injected boundary; overlapping saves retain that writer's semantics while only the latest active
image request may publish. Image/workspace replacement rejects late completion, and current failures surface in
the Develop workspace. Remaining source-decode, render-policy, Metal-publication, geometry, and view decomposition
keep the broad Phase 4.1 extraction gate open.
([validation](plan-status-develop-primary-persistence-continuation-2026-09-01.md))

**Source-publication state-owner follow-up (2026-09-01):** `DevelopPreviewSessionCoordinator` now owns the
retained decoded `NSImage` and `CIImage` as well as source identity, orientation, progress, and all source-lifecycle
tasks. Quick/fallback pixels, materialized final decodes, and in-memory rotations cross image- and generation-
checked publication methods; navigation and teardown clear them through the same owner. Decode execution and
Metal texture publication remain injected at the view/pipeline boundary, and broader render-policy, geometry,
and view decomposition stay open.
([validation](plan-status-develop-source-publication-continuation-2026-09-01.md))

**Metal-publication state-owner follow-up (2026-09-01):** the preview-session generation now gates the final
source-texture mutation inside `MetalEditPipeline`, including its zero-copy Clean Feed mirror. The lock orders
publication against image replacement and teardown, while in-memory rotation advances the same identity boundary
without clearing the valid fallback texture. Every interactive Develop quick, final, rotation, and zoom-upgrade
upload uses the generation-bearing live-preview facade; isolated pipeline callers retain the unscoped entry.
Decode execution, render policy, geometry, and broader view decomposition remain open.
([validation](plan-status-develop-metal-publication-continuation-2026-09-01.md))

**Source-decode execution follow-up (2026-09-01):** `DevelopSourceDecodeService` now owns the concrete quick,
final, zoom-upgrade, and speculative-precache decode paths that previously lived in `EditWorkspaceView`. Its
actor serializes every CIRAWFilter request across those paths, applies the file-to-session orientation correction,
preserves HDR-first non-RAW fallback order, and returns completed immutable image references to the existing
preview-session publication owner. Decoder and orientation dependencies are injectable, so serialization,
pre-cancellation, representation alignment, and view delegation are independently characterized. Render policy,
geometry, and broader view decomposition remain open.
([validation](plan-status-develop-source-decode-continuation-2026-09-01.md))

**Preview-geometry ownership follow-up (2026-09-01):** `DevelopPreviewNavigationCoordinator` now derives the
normal fitted viewport, confirmed-crop viewport, crop-tool image framing, cursor-anchored zoom, and normal/cropped
pan limits from its owned zoom and pan snapshot. The view no longer maintains a private crop-viewport type or
duplicates the letterbox, crop-fit, rotation, zoom-anchor, and pan-bound formulas; it only publishes the
coordinator's immutable viewport to Metal and the Core Image fallback. Seven new characterizations cover normal
and rotated-crop projection, normal/cropped cursor anchoring, shared crop framing/pan limits, inert invalid-size
behavior, and view delegation. Mask/watermark transforms, broader render policy, and view decomposition remain
open.
([validation](plan-status-develop-preview-geometry-continuation-2026-09-01.md))

**Layer-geometry ownership follow-up (2026-09-01):** `DevelopLayerGeometryInteractionCoordinator` now pairs its
image-scoped mask/watermark drag state with the coordinate policy used by every local-layer gesture. An immutable
projection snapshot supplies orientation, display size, crop, straighten, and zoom facts; the coordinator maps
preview points, ellipse and watermark sensor/display frames, brush strokes, AI picks, confirmed-crop watermark
content, and size/margin reclamping. The view retains layout, Metal updates, and durable commits without defining
those formulas. Seven focused tests and the adjacent seven-suite selection passed 56 tests, the repository gate
passed, and the serial unfiltered gate passed 1,860 tests in 217 suites. Broader render policy and view
decomposition remain open.
([validation](plan-status-develop-layer-geometry-continuation-2026-09-01.md))

**Render-policy ownership follow-up (2026-09-01):** `DevelopRenderPolicyCoordinator` now selects the exact
missing-source fallback, interactive Metal-scope, throttled CPU-scope, crop-only Metal, or settled materialization
path from one immutable input. The same decision owns comparison refresh, scope-crop synchronization, Metal
parameter/redraw requirements, SDR/HDR display-gamut selection, and the clipping shader mapping. Concrete decode,
Metal mutation, preview/scope materialization, comparison, and Clean Feed publication remain in their existing
lifecycle owners. Five new characterizations and an adjacent 36-test selection preserve the dispatch behavior;
the serial unfiltered gate passes 1,865 tests in 218 suites. Further view decomposition keeps the broad Phase 4.1
gate open. ([validation](plan-status-develop-render-policy-continuation-2026-09-01.md))

**Workspace-session ownership follow-up (2026-09-01):** `DevelopWorkspaceSessionCoordinator` now owns the
workspace-lifetime named-version flush registration and replaceable copy/paste/template notice task. Repeated
appearance replaces the complete session, disappearance unregisters the exact token, and timer cancellation plus
request identity prevents an older notice task from clearing newer feedback. The unused `previewCIImage` slot is
also removed, leaving `DevelopPreviewRenderCoordinator` as the single materialized AppKit preview owner while
Metal retains interactive rendering. Six new characterizations and an adjacent 42-test selection passed; the
repository gate passed, and the serial unfiltered gate passed 1,871 tests in 219 suites. Further view
decomposition keeps the broad Phase 4.1 gate open.
([validation](plan-status-develop-workspace-session-continuation-2026-09-01.md))

**Metal-preview session and Phase 4.1 completion follow-up (2026-09-01):**
`DevelopMetalPreviewSessionCoordinator` now owns the live-preview pipeline and view coordinator, lazy creation and
warmup, workspace/source generations, image-scoped GPU reset, continuous rendering, redraw routing, and teardown.
The expensive pipeline remains reusable across appearances while inactive publication starts and redraws are
rejected and replaced source generations cannot publish stale textures.
The current view inventory places every major Develop feature state behind a named coordinator or store; only
presentation, layout, focus, and nested-helper cursor state remain direct. Four new characterizations and updated
source contracts cover this final extraction; the adjacent selection passed 37 tests, the repository gate passed,
and the serial unfiltered gate passed 1,875 tests in 220 suites. All Phase 4.1 checklist items and its exit gate are
now satisfied. ([validation](plan-status-develop-metal-session-phase-completion-2026-09-01.md))

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
- [ ] The pre-converted quantized Core ML archive, descriptor, and detached signature are published at their
  production `aagedal.me` endpoints and returned HTTP 200 with the expected content types and lengths on
  2026-09-01. Build a model-omitted release candidate and validate clean install, offline, update, rollback,
  removal, interrupted/corrupt download, and relaunch behavior against the production server on every supported
  macOS tier. The HTTPS runtime, signature/hash verification, atomic install, receipt revalidation, rollback, and
  failure-injection tests are implemented.
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
