# Project planning overview

**Status:** living planning index  
**Last reviewed:** 2026-09-04

**Next release label:** 3.0. The combined investigation workspace, journalistic metadata workflow,
and solar-position overlay form a major product expansion rather than a 2.3 point release. Existing
`v2.3/` paths retain their historical working name so links and implementation history stay stable.
All three portfolio initiatives below are intended for 3.0. The Xcode marketing version remains at
its development value until the release-packaging gate.

This document is the top-level index for product and implementation planning. It tracks the major
initiatives, their order and dependencies, while each linked sub-plan remains authoritative for its
own scope, tasks, exit gates, and technical decisions.

Release-facing 3.0 documentation lives outside the implementation plans:

- [Feature guide](feature-help-3.0.md) — how to use the new focused workspaces and evidence workflows.
- [Known limitations](limitations-3.0.md) — material product, evidence, interoperability, and release
  boundaries.
- [Privacy draft](../PRIVACY.md) — local storage, optional sync, network use, retention, and deletion.
- [README](../README.md) and [CHANGELOG](../CHANGELOG.md) — public overview and release draft.

## Portfolio

| Initiative | Detailed plan | Status | Current gate |
| --- | --- | --- | --- |
| Investigation and review foundations | [Working release plan](v2.3/README.md) and [delivery checklist](v2.3/delivery-plan.md) | Core implementation complete; automated orientation/view/report transform coverage expanded; release hardening remains | Close manual fixture/color, accessibility, display/HDR, performance, security, recovery, and packaging gates |
| Journalistic metadata workflow | [Implementation plan](journalistic-metadata-workflow-plan.md) | Caption, unified metadata-field customization, Batch Rename, Deadline preflight/delivery and information hierarchy, typed editorial metadata, schema migration, preservation, verification, and recovery are implemented; Headline and every localized Title alternative round-trip independently; ILCE-1 v4.00 one/two-source RAW/JPEG voice-memo ingest and transactional rename foundations are implemented with fail-closed evidence | Persist voice-memo identity beyond ingest and complete playback/transcription/delivery plus broader Sony samples, external interoperability, real-server, device, accessibility, and first-use Deadline drills |
| SunCalc-style solar overlay | [Implementation plan](suncalc-plan.md) | Calculation, persistence, controls, equivalent live-map rendering, immutable report evidence, and the supported-arm64 automated boundary matrix are implemented; interactive release validation remains | Validate live and reported rays across actual map styles, camera interactions, rapid time changes, offline behavior, and accessibility paths |

## Default delivery order

1. Close the investigation/review release gates. Its source identity, case persistence, OSINT map/timeline,
   immutable report snapshot, and rendering behavior are foundations for later analysis features.
2. Close journalistic workflow release hardening. Caption Workspace, Batch Rename, Deadline Mode,
   and verified delivery now share the field model, preservation policy, validation engine, and
   recovery boundaries; remaining work is the final support-ledger model decisions, Sony Alpha
   voice-memo persistence/playback/transcription/delivery integration beyond the implemented
   ILCE-1 v4.00 ingest and transactional-rename foundation, plus broader real-sample compatibility,
   external interoperability, real-environment, and manual accessibility evidence.
3. Finish solar-overlay release validation after the implemented calculator, persistence, controls,
   live-map rendering, and report-evidence phases. It remains a bounded map/report feature and does
   not block the journalistic workflow.

These are workstreams of the same next release. Once their shared foundations are stable, the
journalistic workflow and solar overlay can proceed independently:

```text
Investigation/review foundations and release hardening
├── Journalistic metadata workflow
│   └── Standards → Caption → Rename → Deadline → Verified delivery
└── Solar-position overlay
    └── Calculator → Persistence → Controls → Map → Report → Validation
```

## Plan ownership and status rules

- This overview owns initiative ordering, dependencies, and portfolio-level status.
- Each initiative plan owns its detailed scope, sequencing, checkboxes, estimates, and exit gates.
- A checked implementation task is not release evidence by itself. Dated validation documents own
  test commands, results, manual review, and known limitations.
- Architecture and evidence-claim changes belong in an ADR or dated decision log, not only in a
  checklist edit.
- Capability matrices describe what the app supports; they do not replace implementation plans.
- When status changes materially, update this table and the affected detailed plan in the same
  change.

## Investigation and review document set

The [working release plan](v2.3/README.md) is the entry point for this workstream. Its supporting
documents remain grouped under the historical `docs/v2.3/` path until the final release number is
selected:

- [Delivery plan](v2.3/delivery-plan.md) — phase checklists and release gates.
- [Image Analysis](v2.3/image-analysis.md) — evidence workspace, pixel tools, OSINT map/timeline,
  markup, and reporting.
- [Comparison and versions](v2.3/comparison-and-versions.md) — synchronized comparison and named
  Develop versions.
- [Storage and architecture](v2.3/storage-and-architecture.md) — schemas, ownership, transforms,
  migration, security, and recovery.
- [Wireframes](v2.3/wireframes.md) — interaction and layout references.
- `phase-*-validation.md` — dated implementation and validation records.
- [Analysis and named-version storage ADR](v2.3/adr-001-analysis-version-storage.md) — folder-local
  app-private JSON, Application Support fallback, and atomic recovery policy.
- [Exact source revision identity ADR](v2.3/adr-002-source-revision-identity.md) — authoritative hash
  binding, discovery hints, and reassociation boundaries.
- [Named-version save semantics ADR](v2.3/adr-003-named-version-save-semantics.md) — JSON snapshot,
  durable flush, and verified Primary-promotion policy.
- [Map report evidence ADR](v2.3/adr-004-map-report-evidence.md) — map imagery and report policy.

## Journalistic metadata document set

The [journalistic metadata workflow plan](journalistic-metadata-workflow-plan.md) is the parent for
Caption Workspace, standards coverage, Batch Rename, Deadline Mode, and verified delivery.

Supporting documents:

- [Generated metadata field and delivery support](metadata-field-support.md) — current stable field IDs,
  writer mappings, semantic read-back rules, and exact carrier/write-mode boundaries; checked for drift
  by `scripts/generate_metadata_field_support.py --check`.
- [IPTC 2025.1 editorial support matrix](iptc-2025.1-editorial-support.md) — field-level support
  ledger and next conformance work.
- [ADR-005: IPTC 2025.1 editorial metadata baseline](adr-005-iptc-2025-1-editorial-metadata.md) —
  selected standard and compatibility baseline.
- [Metadata conflict and container policy](metadata-conflict-and-container-policy.md) — canonical
  values, conflicting representations, and preservation behavior.
- [Metadata JSON persistence validation](metadata-json-persistence-validation.md) — migration and
  newer-schema overwrite protection evidence for app sidecars and metadata templates.
- [Metadata validation profile validation](metadata-validation-profile-validation.md) — portable
  profile JSON contract, semantic import boundaries, and focused test evidence.
- [Metadata interoperability boundary-corpus validation](metadata-interoperability-corpus-validation.md)
  — IIM UTF-8 byte ceilings, timezone/precision variants, and real serializer evidence.
- [Structured editorial XMP validation](metadata-structured-xmp-validation.md) — creator-contact and
  created/shown-location mappings, embedded/sidecar round trips, and preservation evidence.
- [Editorial rights XMP validation](metadata-rights-xmp-validation.md) — usage-terms and web-rights
  mappings, URL validation, embedded/sidecar round trips, and delivery-path evidence.
- [Editorial urgency validation](metadata-urgency-validation.md) — bounded integer semantics,
  XMP/IIM conflict precedence, validation, and embedded/sidecar round trips.
- [Scene Code validation](metadata-scene-code-validation.md) — controlled-vocabulary semantics,
  alias normalization, repeated XMP bag I/O, and unknown-value preservation.
- [Digital Image GUID validation](metadata-digital-image-guid-validation.md) — explicit identifier
  ownership, XMP I/O, clear semantics, and unrelated-edit preservation.
- [Image Supplier Image ID validation](metadata-image-supplier-id-validation.md) — supplier-ID
  separation, XMP I/O, workflow propagation, clear semantics, and unrelated-edit preservation.
- [Full test-suite validation](full-test-suite-validation.md) — fresh-build, complete-suite,
  parameterized-execution, stress-repeat, and static release-gate evidence.
- [Deadline maximum output-size validation](deadline-maximum-output-size-validation.md) — frozen
  per-file limits, honest estimate semantics, final-byte enforcement, and receipt evidence.
- [Deadline information-hierarchy validation](deadline-information-hierarchy-validation.md) —
  coherent phase/readiness/action/output presentation and execution-owned Send eligibility.
- [Metadata field-operation contract validation](metadata-field-operation-contract-validation.md) —
  exhaustive stable-field mappings, explicit mutation semantics, canonical values, and round trips.
- [Controlled editorial structures validation](metadata-controlled-structures-validation.md) —
  Subject Codes, Media Topics, separate Genre, canonical PLUS Supplier mappings, migration, and
  exact structured-XMP evidence.
- [Ordered Creator and typed Date Created validation](metadata-creator-date-validation.md) — ordered
  XMP/IIM creators, compatibility aliases, precision/timezone semantics, and embedded read-back.
- [Headline and localized Title validation](metadata-headline-localized-title-validation.md) —
  independent Headline semantics, ordered `rdf:Alt` preservation, legacy migration, explicit-clear
  persistence, and embedded/export/delivery/read-back evidence.
- [Accessibility and keyboard audit](accessibility-keyboard-audit-validation.md) — workspace
  semantics, adaptive controls, assignable culling profiles, conflict routing, and manual limits.
- [Privacy-safe accessibility announcement validation](accessibility-announcement-validation.md) —
  centralized fixed copy for action success, failure, cancellation, and recovery.
- [Batch Rename original-filename validation](batch-rename-original-filename-validation.md) —
  standards-correct XMP mapping, transaction order, RAW safety, and exact rollback evidence.
- [Manual release-prerequisite audit](manual-release-prerequisite-audit.md) — sanitized local
  availability matrix and the smallest external actions for the remaining real-world gates.
- [Caption Workspace speed-tools validation](caption-workspace-speed-tools-validation.md) — edited
  preview, profile navigator, durable actions, shortcuts, confirmed people, and prose checking.
- [Caption Workspace compact-checklist validation](caption-workspace-checklist-validation.md) —
  collapsed field navigation, persistent readiness/next-issue remediation, and visibility-aware
  focus routing, concise fresh-install defaults, and the direct Metadata Settings affordance.
- [IPTC metadata field guidance validation](metadata-field-guidance-validation.md) — exhaustive
  localized editorial-use/example copy shared by Metadata panel hover help and accessibility hints.
- [Metadata field customization validation](metadata-field-customization-validation.md) — unified
  ordering/visibility/requirement controls, durable order, migration, and unknown-field recovery.
- [Editorial container fixture validation](editorial-container-fixture-validation.md) — generated
  TIFF/PNG/JPEG XL and RAW-sidecar corpus, pixel/codestream preservation, and HEIC boundary.
- [Caption termination durability validation](caption-termination-durability-validation.md) —
  deferred AppKit termination, FIFO retry, Caption-before-Develop ordering, and focus evidence.
- [Sony Alpha voice-memo companion foundation](sony-alpha-voice-memo-companion-validation.md) —
  private-sample-validated ILCE-1 v4.00 one/two-source ingest plus transactional rename/rollback;
  persistence, playback/transcription/delivery, and broader body/firmware compatibility remain
  gated.
- [SwiftMediaMetadata 3 migration](swift-media-metadata-3-migration-validation-2026-09-02.md) — remote
  package relink, removal of the old vendored source and app-owned compatibility workarounds, and
  focused/full regression evidence.
- [Batch Rename relocation continuation](plan-status-batch-rename-relocation-continuation-2026-09-02.md) —
  nonblocking immutable rename projection for Browser, Compare, and Analysis publication, while destination
  file-fact reads for Duplicate remain on the serialized filesystem actor.
- [Face folder-load continuation](plan-status-face-folder-load-continuation-2026-09-02.md) — serialized,
  cancellation-aware `.face_data` and complete thumbnail reads with request-gated publication and cache-only
  render lookup.
- [AuraFace component-probe continuation](plan-status-auraface-probe-continuation-2026-09-02.md) — serialized signed
  component verification and model-path resolution with explicit Checking state and stale-result rejection.
- [Browser and Compare presentation-facts continuation](plan-status-browser-comparison-presentation-facts-continuation-2026-09-02.md) —
  serialized XMP/header snapshots for retina pre-cache and committed comparison with cancellation and stale-selection
  rejection.
- [Metadata inspector filesystem continuation](plan-status-metadata-inspector-filesystem-continuation-2026-09-02.md) —
  serialized Raw Metadata XMP and technical ImageIO/file-stat snapshots with cancellation and request/image-gated
  publication through SwiftExif enrichment.
- [Browser orientation filesystem continuation](plan-status-browser-orientation-filesystem-continuation-2026-09-02.md) —
  serialized, request-tagged Browser XMP/ImageIO orientation snapshots with exact cancellation-prefix evidence and
  aggregate performance signposts.
- [Path-containment and cached-identity continuation](plan-status-path-containment-identity-continuation-2026-09-03.md) —
  serialized symlink-aware Import/Browser containment plus actor-captured voice-memo source identity for cache-only
  MainActor projection.

## Solar overlay document set

The [SunCalc-style solar overlay plan](suncalc-plan.md) owns its next-release workstream. Its first
five phases now provide the app-owned Swift calculator, explicit time/location inputs, map
presentation, persistence, immutable report evidence, numerical fixtures, and the boundary between
a direction overlay and later forensic shadow comparison. Phase 6 owns the remaining release
validation.

The [calculation conventions and reference corpus](solar-calculation-conventions.md) freeze the
`meeusNOAAV1` equations, supported range, event/refraction conventions, tolerances, and sources.

Any future shadow-length, capture-time inference, terrain, or obstruction work requires a separate
gate or ADR; it must not silently expand the first-release plan.

## Independent and completed feature plans

These documents retain useful implementation history or track features outside the three main
initiatives. Their own status sections are authoritative:

- [Brush mask plan](brush-mask-plan.md) — largely implemented; includes remaining calibration and
  manual-validation notes.
- [Face-lens follow-up](scan-modes-followup.md) — implemented redesign with remaining Sports work.
- [Sports mode 2.1 plan](sports-2.1-plan.md) — specialist sports-tagging trust and review workflow.

They should not be used as the top-level project backlog unless promoted into the portfolio table.

## Cross-cutting improvement backlog

The [app improvement audit plan](app-improvement-audit-plan.md) is a proposed, risk-ordered backlog
covering data-loss prevention, release reproducibility, security/privacy, accessibility,
responsiveness, and maintainability. It is not a fourth 3.0 portfolio initiative, and its unchecked
items do not claim implementation or replace the release gates in the three authoritative plans
above. The audit baseline is reconciled to the latest recorded current-source run of 1,936 passing
tests; manual, external-service, hardware, legal, and credential-dependent actions
remain explicitly gated in that document.

The latest [code-boundary continuation](plan-status-continuation-validation-2026-08-30.md) records the
main-actor Metal live-preview facade, FTP Recent Uploads filesystem snapshot, and Develop comparison-render
coordinator, including the current 63-of-75 audit status and integrated focused test evidence.

The subsequent [implementation continuation](plan-status-implementation-continuation-2026-08-30.md) records
the serialized Structured Keyword import boundary, the Develop preview-render publication owner, and the
clean 1,613-test unfiltered run after full-load timing stabilization. These slices advance broad open gates;
the audit remains 63 of 75.

The latest [responsiveness and navigation continuation](plan-status-responsiveness-navigation-continuation-2026-08-30.md)
records serialized roster import and keyword-backup preview reads, stable filesystem measurement signposts and
a repeatable blocked-volume gate, plus the Develop preview-navigation state owner. Real-volume, Instruments,
Thread Performance Checker, manual, and external release gates remain open, so the audit stays 63 of 75.

The [filesystem and transient-preview continuation](plan-status-filesystem-transient-preview-continuation-2026-08-30.md)
records actor-owned keyword backup inventory/restore, roster export and Remove All IPTC preflight work, plus
the Develop transient-preview state owner and its clean 1,646-test integrated run.

The latest [certificate, export, and section-mute continuation](plan-status-certificate-export-mutes-continuation-2026-08-30.md)
records transactional C2PA certificate/Keychain I/O, serialized atomic keyword exports, app-scoped fail-closed
certificate availability, and the Develop section-mute owner. The current-source gate passes 1,658 tests in
190 suites; the remaining filesystem inventory, real-volume, broader state-owner, manual, and external gates
keep the audit at 63 of 75.

The subsequent [source-file import continuation](plan-status-source-file-import-continuation-2026-08-30.md)
records serialized Code Replacement bookmark/source loading, Metadata Quick List file creation, and Develop
color-LUT import with explicit cancellation and stale-result rejection. The current-source gate passes 1,672
tests in 193 suites; remaining filesystem inventory, real-volume/Thread Performance Checker evidence, broader
Develop ownership, and manual/external gates keep the audit at 63 of 75.

The latest [archive, roster, license, and crop continuation](plan-status-archive-roster-crop-continuation-2026-08-30.md)
records serialized Image Analysis project archives, match-roster persistence, bundled license-text loading,
and the Develop crop-session state owner. After disabling a stalled parallel Xcode test worker, the combined
four-suite selection passed 21 focused tests and the serial unfiltered result recorded 1,817 expanded cases
across 196 named suites. The broad audit remains 63 of 75.

The subsequent [cleanup, storage, and white-balance continuation](plan-status-cleanup-storage-white-balance-continuation-2026-08-30.md)
records serialized RAW signing-failure compensation, Known People storage measurement, edited-folder backup
directory preparation, and the Develop white-balance session owner. The combined selection passed 39 tests,
final picker late-result hardening passed all seven focused white-balance tests, and the final serial unfiltered
gate passed 1,707 tests in 197 suites. Remaining inventory, real-volume, broader state-owner, manual, and external
gates keep the audit at 63 of 75.

The latest [approved-list, template-commit, and Develop-layer continuation](plan-status-approved-template-layer-continuation-2026-08-30.md)
records serialized approved-list source/commit ownership, partial-durable metadata-template import commits, and
the Develop layer-session state owner. The final serial unfiltered gate passed 1,859 expanded test cases; the
broad filesystem inventory/measurement and Develop render/persistence ownership gates remain open, so the audit
stays 63 of 75.

The subsequent [archive-preview, raw-metadata, and Clean Feed continuation](plan-status-archive-preview-raw-metadata-clean-feed-continuation-2026-08-30.md)
records actor-owned keyword-list backup preview and raw-metadata app-sidecar loading plus the Clean Feed
publication state owner. The combined selection passed 17 tests in four suites, and the serial unfiltered gate
passed 1,745 tests in 203 suites. Remaining filesystem inventory/measurement, Develop render/persistence,
manual, and external gates keep the audit at 63 of 75.

The latest [template, keyword-import, and interactive-render continuation](plan-status-template-keyword-interactive-render-continuation-2026-08-30.md)
records serialized metadata/Develop template CRUD, partial-durable keyword-list archive import commits, and the
Develop interactive-render state owner. The combined selection passed 71 tests in seven suites, and the serial
unfiltered gate passed 1,763 tests in 205 suites. Remaining filesystem inventory/measurement, broader Develop
persistence ownership, manual, and external gates keep the audit at 63 of 75.

The subsequent [import, image, keyword-export, and LUT continuation](plan-status-import-image-keyword-lut-continuation-2026-08-30.md)
records serialized import-directory batch commits, full-screen XMP/ImageIO presentation snapshots, atomic
keyword-list archive export, and the Develop Color LUT import state owner. All 26 focused tests and the serial
unfiltered 1,779-test current-source gate passed. Remaining filesystem inventory and real-volume measurements,
direct Develop undo/persistence ownership, and manual/external gates keep the audit at 63 of 75.

The latest [Browser sidecar, keyword editor, and Develop persistence continuation](plan-status-browser-keyword-develop-persistence-continuation-2026-08-31.md)
records serialized Browser XMP batch reads, actor-owned flat keyword-list load/save commits, and the Develop
persistence-session owner for undo, lifecycle, edited-preview inventory, and Primary-versus-named-version intent.
The combined selection passed 52 tests, the repository gate passed, and the serial unfiltered current-source gate
passed 1,923 tests. Lower-priority filesystem inventory, real-volume evidence, broader Develop ownership, and
manual/external gates keep the audit at 63 of 75.

The subsequent [Watermark import and Develop modal/geometry continuation](plan-status-watermark-version-geometry-continuation-2026-08-31.md)
records actor-owned security-scoped watermark PNG imports, named-version dialog state, and image-scoped
mask/watermark interaction geometry. The final unfiltered gate passed 1,804 tests in 212 suites. Remaining
direct filesystem paths and real-volume evidence, broader metadata/sidecar persistence and view decomposition,
and manual/external gates keep the audit at 63 of 75.

The latest [Quick List mutation and iCloud routing continuation](plan-status-quick-list-routing-continuation-2026-08-31.md)
records serialized Metadata-panel Quick List append/import transactions and actor-owned Keyword Lists iCloud
route reconciliation. The merge keeps destination-ordered unions for flat lists and preserves existing
structured trees. The serial unfiltered gate passed 1,817 tests in 212 suites. Remaining lower-priority direct
paths, real-volume and Thread Performance Checker evidence, broader Develop persistence/view decomposition, and
manual/external gates keep the audit at 63 of 75.

The subsequent [Develop persistence-routing continuation](plan-status-develop-persistence-routing-continuation-2026-08-31.md)
records coordinator-owned dispatch from Develop persistence intent to the injected Primary XMP/history or named-
version boundary. Both normal adjustment and reset paths publish their image snapshot exactly once before one
durable action. The affected four-suite selection passed 34 tests, and the serial unfiltered gate passed 1,818
tests in 212 suites. Broader persistence lifetime/cancellation and view decomposition, filesystem measurement,
manual, and external gates keep the audit at 63 of 75.

The latest [Settings keyword-archive inventory continuation](plan-status-settings-keyword-archive-inventory-continuation-2026-08-31.md)
records actor-owned Quick List and structured-keyword archive inventory, ordered immutable counts, exact
cancelled-prefix evidence, and export-request reuse without a second file read. The affected 11-suite selection
passed 65 tests and the serial unfiltered gate passed 1,822 tests in 213 suites. Remaining direct paths,
real-volume evidence, broader Develop persistence/view decomposition, and manual/external gates keep the audit
at 63 of 75.

The subsequent [roster-library persistence continuation](plan-status-roster-library-persistence-continuation-2026-08-31.md)
records serialized Teams-library scans, coordinated record reads/writes, tombstone cleanup, corrupt backup,
iCloud conflict resolution, verified deletion, and complete remote reloads. The affected seven-suite selection
passed 55 tests, the repository gate passed, and the fresh-derived serial unfiltered gate passed 1,827 tests in
214 suites. Remaining lower-priority direct paths, real-volume and Thread Performance Checker evidence, broader
Develop persistence/view decomposition, and manual/external gates keep the audit at 63 of 75.

The latest [Develop input-session continuation](plan-status-develop-input-session-continuation-2026-09-01.md)
records coordinator-owned keyboard, scroll-wheel, and middle-mouse monitor lifetimes plus preview/filmstrip
hover, temporary Space-hand, and keyboard-scroll-target state. Replacement and teardown remove each monitor
exactly once while the view retains concrete event interpretation. The adjacent four-suite selection passed
41 tests, the repository gate passed, and the serial unfiltered gate passed 1,832 tests in 215 suites. Broader
persistence lifetime and remaining source/render/geometry view decomposition, filesystem measurement, manual,
and external gates keep the audit at 63 of 75.

The latest [Develop batch-persistence continuation](plan-status-develop-batch-persistence-continuation-2026-09-01.md)
records coordinator-owned multi-image Develop paste tasks, request identity, pending state, explicit cancellation,
and observable outcomes. Every durable write is retained, only the newest overlapping request may publish UI
state, and workspace teardown suppresses late results without cancelling a possibly partially committed write.
Failures now appear in an active-workspace alert. The focused suite passed 10 tests, the adjacent four-suite
selection passed 44 tests, the repository gate passed, and the fresh-derived serial unfiltered gate passed 1,835
tests in 215 suites. Primary XMP/history task ownership, remaining source/render/geometry view decomposition,
filesystem measurement, and manual/external gates keep the audit at 63 of 75.

The latest [Develop Primary-persistence continuation](plan-status-develop-primary-persistence-continuation-2026-09-01.md)
records coordinator-owned awaiting tasks, request/image/workspace identity, pending state, explicit cancellation,
and typed result publication for Primary XMP/history saves and Develop resets. The existing serialized durable
writer remains injected; only the newest active-image request may publish, late completion after navigation or
teardown is rejected, and current failures surface in the workspace. The focused suite passed 13 tests, the
adjacent four-suite selection passed 47 tests, the repository gate passed, and the serial unfiltered gate passed
1,838 tests in 215 suites. Remaining source/render/geometry view decomposition, filesystem measurement, and
manual/external gates keep the audit at 63 of 75.

The latest [Develop source-publication continuation](plan-status-develop-source-publication-continuation-2026-09-01.md)
records coordinator ownership of the retained decoded `NSImage`/`CIImage`, image URL, orientation, generation,
progress, and source producer tasks. Quick previews, thumbnail fallbacks, materialized final decodes, and
in-memory rotations now use image/generation-gated publication, while navigation and teardown clear both
representations together. The focused suite passed 5 tests, the adjacent four-suite selection passed 36 tests,
the repository gate passed, and the serial unfiltered gate passed 1,841 tests in 215 suites. Decode execution,
render-policy, Metal publication, geometry/view decomposition, filesystem measurement, and manual/external gates
keep the audit at 63 of 75.

The latest [Develop Metal-publication continuation](plan-status-develop-metal-publication-continuation-2026-09-01.md)
records generation-gated source-texture replacement across the editor and zero-copy Clean Feed mirror. Navigation,
teardown, and same-image rotation now reject late quick/final/zoom uploads at the final Metal state mutation even
when an already-committed command buffer cannot be cancelled. The focused three-suite selection passed 16 tests;
the repository gate passed, and the serial unfiltered gate passed 1,845 tests in 216 suites. Remaining decode execution,
render-policy, geometry/view decomposition, filesystem measurement, and manual/external gates keep the audit at
63 of 75.

The latest [Develop source-decode continuation](plan-status-develop-source-decode-continuation-2026-09-01.md)
records actor-owned embedded-RAW preview extraction, HDR-first non-RAW fallback routing, screen/full-resolution
decode, orientation correction, and preview materialization. Foreground RAW, zoom-upgrade, and adjacent pre-cache
requests now share one serialized CIRAWFilter executor while existing session-generation and Metal gates retain
publication ownership. The focused suite passed 4 tests, the adjacent five-suite selection passed 78 tests, the
repository gate passed, and the serial unfiltered gate passed 1,849 tests in 217 suites. Remaining render-policy,
geometry/view decomposition, filesystem measurement, and manual/external gates keep the audit at 63 of 75.

The subsequent [Develop preview-geometry continuation](plan-status-develop-preview-geometry-continuation-2026-09-01.md)
records coordinator-owned normal/cropped viewport projection, crop framing, cursor-anchored zoom, and pan limits.
Seven characterizations cover normal and rotated-crop geometry, the adjacent three-suite selection passed 41
tests, the repository gate passed, and the serial unfiltered gate passed 1,856 tests in 217 suites. Mask/watermark
geometry, broader render policy/view decomposition, filesystem measurement, and manual/external gates kept the
audit at 63 of 75.

The latest [Develop layer-geometry continuation](plan-status-develop-layer-geometry-continuation-2026-09-01.md)
records coordinator-owned pane-to-UV mapping, ellipse/watermark EXIF and straighten transforms, brush and AI-pick
projection, confirmed-crop watermark framing, and size/margin reclamping. Seven focused tests and the adjacent
seven-suite selection passed 56 tests; the repository gate passed, and the serial unfiltered gate passed 1,860
tests in 217 suites. Broader render policy/view decomposition, filesystem measurement, and manual/external gates
keep the audit at 63 of 75.

The subsequent [Develop render-policy continuation](plan-status-develop-render-policy-continuation-2026-09-01.md)
records one immutable dispatch decision for source fallback, Metal/CPU interactive scopes, crop-only Metal, settled
materialization, comparison refresh, scope crop, and gamut mapping. Five new characterizations, the adjacent
36-test selection, the repository gate, and the serial unfiltered 1,865-test run all passed. Further Develop view
decomposition, filesystem measurement, and manual/external gates keep the audit at 63 of 75.

The latest [Develop workspace-session continuation](plan-status-develop-workspace-session-continuation-2026-09-01.md)
records coordinator ownership of the workspace-lifetime named-version flush registration and replaceable transient
notices, including exact-token teardown and protection against an older timer clearing newer feedback. It also
removes a redundant Core Image preview-publication slot so the existing preview coordinator is the single
materialized AppKit owner. Six new characterizations, the adjacent 42-test selection, the repository gate, and
the serial unfiltered 1,871-test run all passed. Further Develop view decomposition, filesystem measurement, and
manual/external gates keep the audit at 63 of 75.

The latest [Develop Metal-session and Phase 4.1 completion](plan-status-develop-metal-session-phase-completion-2026-09-01.md)
records ownership of live-preview pipeline creation and warmup, the Metal view coordinator, workspace/source
generations, continuous rendering, redraw routing, image-scoped GPU reset, and teardown. A current Develop state
inventory confirms every major feature has a named owner and independently characterized lifecycle/test seam,
completing the three remaining Phase 4.1 checklist items. Four new characterizations, the adjacent 37-test
selection, the repository gate, and the serial unfiltered 1,875-test run all passed. The audit is now 66 of 75,
with nine filesystem/performance, manual, and external release gates remaining.

The latest [Import metadata-scan continuation](plan-status-import-metadata-scan-continuation-2026-09-01.md)
records serialized actor ownership of Import capture-date reads and same-date destination-folder discovery.
Immutable complete/cancelled-prefix evidence, request identities, and source/reset cancellation prevent obsolete
work from publishing. Eight new characterizations, the adjacent 38-test selection, the repository gate, and the
serial unfiltered 1,883-test run passed. The audit remains 66 of 75 while Phase 3.1's remaining direct-path
inventory and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Import voice-memo association continuation](plan-status-import-voice-memo-association-continuation-2026-09-01.md)
records serialized actor ownership of Sony dual-card EXIF/file-date reads, security-scoped access, and final
association. Immutable complete or exact cancelled-prefix evidence and request-identity publication prevent stale
work from replacing a newer report. Five new characterizations, the adjacent 37-test selection, the repository
gate, and the serial unfiltered 1,888-logical-test/2,015-expanded-run gate passed. The audit remains 66 of 75 while
the remaining Phase 3.1 direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

AuraFace production publication is recorded in the
[on-demand runtime validation](auraface-on-demand-runtime-validation-2026-08-27.md#remaining-external-validation):
the archive, descriptor, and detached-signature endpoints were live and returned HTTP 200 on 2026-09-01.
Publication is complete; the model-omitted release candidate and supported-macOS production-server drills remain.

The latest [Batch Rename relocation continuation](plan-status-batch-rename-relocation-continuation-2026-09-02.md)
removes destination and sidecar resource probes from the three MainActor owners that publish successful rename
results. A pure `ImageFile` relocation projection preserves the executor's already-known immutable file facts;
the filesystem-backed copy initializer remains only in the serialized Duplicate service. Two new
characterizations, the focused 17-test suite, the integrated 131-test selection, and the repository gate passed.
The unchanged 10,000-file planning benchmark also passed alone after exceeding its existing tripwire once under
full-suite host contention; a 58.697-second serial run excluding only that separately passing benchmark covered
the rest of the suite without failures. The audit remains 66 of 75 while Phase 3.1's remaining direct paths and
real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Face folder-load continuation](plan-status-face-folder-load-continuation-2026-09-02.md) moves folder
navigation `.face_data` decode, expiration cleanup, and complete thumbnail reads onto one serialized actor.
Immutable complete or exact cancelled-prefix evidence, durable-cleanup reporting, and request identity prevent
stale folder snapshots from publishing. Render-time thumbnail lookup is now cache-only, while scans hand newly
written bytes to the cache and refresh the final snapshot through the same boundary. Six new characterizations
and the adjacent 33-test selection, repository gate, and serial unfiltered 1,896-test run passed. The audit
remains 66 of 75 while remaining face mutations, other direct paths, and real-volume/signpost/Thread Performance
Checker evidence stay open.

The latest [Face persistence continuation](plan-status-face-persistence-continuation-2026-09-02.md) extends that
actor across scan preparation/finalization, interactive document mutations, thumbnail commits and cleanup,
whole-folder deletion, Caption, metadata-variable resolution, FTP preflight, rename reassociation, and secondary-
lens reads. Seven new characterizations, the integrated 68-test selection, repository gate, and final serial
unfiltered 1,903-logical-test/2,030-expanded-run gate passed. The audit remains 66 of 75 while Phase 3.1's other
direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Source revision capture continuation](plan-status-source-revision-capture-continuation-2026-09-02.md)
moves canonical-path resolution, pre/post resource probes, and streamed hashing from MainActor callers to one
serialized, non-reentrant stat-hash-stat transaction. Three new characterizations, the focused 10-test suite, the
integrated 151-test selection, repository gate, and serial unfiltered 1,906-test run passed. The audit remains 66 of
75 while Phase 3.1's lower-priority direct paths and real-volume/signpost/Thread Performance Checker evidence stay
open.

The latest [AuraFace component-probe continuation](plan-status-auraface-probe-continuation-2026-09-02.md) moves
signed descriptor verification, package enumeration and hashing, and compiled/bundled model resolution out of
MainActor manager and embedder initialization onto one serialized actor. Explicit Checking state, cancellation,
request identity, and pre-resolved URL publication prevent partial or stale availability. Two new characterizations,
the adjacent face/Known People selection, repository gate, and serial unfiltered 1,908-logical-test/2,035-expanded-
run gate passed. The audit remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/Thread
Performance Checker evidence stay open.

The latest [Browser and Compare presentation-facts continuation](plan-status-browser-comparison-presentation-facts-continuation-2026-09-02.md)
moves retina pre-cache and committed comparison XMP/header reads from MainActor orchestration onto the existing
serialized presentation-facts actor. Browser validates request identity and the current selection after both facts
loading and decode; Compare validates request/image identity before rendering and retains its session publication
gate. Two new characterizations, the focused 6-test suite, adjacent 47-test selection, repository gate, and serial
unfiltered 1,910-test run passed. The audit remains 66 of 75 while Phase 3.1's other direct paths and real-volume/
signpost/Thread Performance Checker evidence stay open.

The latest [Face scan signature continuation](plan-status-face-scan-signature-continuation-2026-09-02.md) moves
incremental scan classification and post-detection file attribute reads onto one serialized actor. Complete
immutable path sets cross back to the face scanner; exact cancelled-prefix evidence prevents partial classification
from discarding faces, and cancelled signature capture leaves an image eligible for a later scan. Four new
characterizations, the focused 17-test selection, repository gate, and serial unfiltered 1,914-test run passed. The
audit remains 66 of 75 while Phase 3.1's other direct paths and real-volume/signpost/Thread Performance Checker
evidence stay open.

The latest [Metadata inspector filesystem continuation](plan-status-metadata-inspector-filesystem-continuation-2026-09-02.md)
moves Raw Metadata XMP loading and the technical-metadata ImageIO/file-stat fast path from MainActor-owned views to
dedicated serialized actors. Immutable request/image identities, explicit cancellation, disappearance invalidation,
and repeated selection guards prevent stale publication through SwiftExif enrichment. Eight new characterizations,
the focused 12-test selection, adjacent 73-test selection, repository gate, and serial unfiltered 1,922-test run
passed. The audit remains 66 of 75 while Phase 3.1's other direct paths and real-volume/signpost/Thread Performance
Checker evidence stay open.

The latest [Browser orientation filesystem continuation](plan-status-browser-orientation-filesystem-continuation-2026-09-02.md)
moves eager initial-load and incremental-refresh XMP/ImageIO orientation reads from an ad hoc parallel task group to
the Browser's existing serialized filesystem actor. Immutable request-tagged snapshots, exact cancelled-prefix
evidence, replacement-load invalidation, and complete-result guards prevent partial or stale orientation publication;
a privacy-safe signpost records only state and aggregate counts. Five new characterizations, the focused 24-test
suite, adjacent 39-test selection, repository gate, and serial unfiltered 1,927-test run passed. The audit remains
66 of 75 while Phase 3.1's other direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Clean Feed browse-render continuation](plan-status-clean-feed-browse-render-continuation-2026-09-03.md)
moves passive external-display source loading, orientation resolution, and committed-edit materialization out of
the SwiftUI view and behind a request-tagged actor. RAW previews reuse Develop's serialized draft decoder; entering
Develop mode, selection replacement, and view disappearance invalidate old work before publication. Five new
characterizations, the adjacent 48-test selection, repository gate, and serial unfiltered 1,932-test run passed.
The audit remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/Thread Performance
Checker evidence stay open.

The latest [voice-memo rename-planning continuation](plan-status-voice-memo-rename-planning-continuation-2026-09-03.md)
moves hidden companion-relationship enumeration and JSON decoding out of the MainActor Browser rename entry and
behind a serialized actor. Immutable request-tagged snapshots expose complete, exact cancelled-prefix, or exact
failed-prefix evidence; request, folder, and current-selection guards prevent partial or stale plans from opening
the sheet. Four new characterizations, the adjacent 66-test selection, repository gate, and serial unfiltered
1,936-test run passed. The audit remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/
Thread Performance Checker evidence stay open.

The latest [path-containment and cached-identity continuation](plan-status-path-containment-identity-continuation-2026-09-03.md)
moves symlink-aware Import destination batches and Browser folder-rename safety checks behind one serialized actor
with immutable complete or exact cancelled-prefix evidence. The voice-memo association actor now also returns the
canonical source map consumed by Import's computed selection and plan projections, avoiding repeated filesystem
canonicalization on MainActor. Four new characterizations, the focused 12-test selection, adjacent Import/Browser
regressions, repository gate, and serial unfiltered 1,940-test run passed. The audit remains 66 of 75 while Phase
3.1's remaining direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [export Camera Raw sidecar-resolution continuation](plan-status-export-camera-raw-resolution-continuation-2026-09-03.md)
moves the RAW XMP fallback batch used by local Save/Export/Archive and FTP render/preflight from a MainActor helper
to one serialized actor. Live workspace values are captured before the boundary, so the actor reads only missing
RAW fallbacks and returns immutable complete or exact cancelled-prefix evidence. Three new characterizations and
the adjacent 30-test export/FTP selection, repository gate, and serial unfiltered 1,943-test run passed. The audit
remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/Thread Performance Checker
evidence stay open.

The latest [Browser HDR-classification continuation](plan-status-browser-hdr-classification-continuation-2026-09-03.md)
moves ImageIO/native-HDR and mapped JPEG/HEIF gain-map inspection out of the MainActor metadata merge and behind a
serialized actor. Immutable request-tagged results distinguish complete classification from exact cancelled prefixes;
the Browser accepts only complete evidence for the current batch. Four new characterizations and the focused 9-test
Browser filesystem-boundary selection, adjacent 71-test selection, repository gate, and serial unfiltered 1,947-test
run passed. The audit remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/Thread
Performance Checker evidence stay open.

The latest [export artifact-finalization continuation](plan-status-export-artifact-finalization-continuation-2026-09-04.md)
moves post-render RAW sidecar copying, fail-closed incomplete-archive cleanup, and Finder-visibility repair onto one
serialized actor. Immutable evidence records the durable sidecar/visibility outcome and cancellation observed around
the intentionally non-preemptible finalization. Three new characterizations, the focused 22-test export suite,
adjacent 53-test export/archive/FTP selection, repository gate, and serial unfiltered 1,950-test run passed. The audit
remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/Thread Performance Checker evidence
stay open.

The latest [Settings Quick List cache continuation](plan-status-settings-quick-list-cache-continuation-2026-09-04.md)
moves initial and replacement Settings/Metadata Quick List reads plus import, append, replace, and delete mutations
onto the existing serialized keyword-list actor. Immutable complete or exact cancellation-prefix evidence and
request-identity gating prevent partial or stale cache publication; SwiftUI queries are cache-only, and route changes
invalidate cached URLs before reloading. Four new characterizations, the focused 15-test suite, adjacent 30-test
selection, repository gate, and serial unfiltered 1,954-test run passed. The audit remains 66 of 75 while Phase 3.1's
remaining direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Browser monitor-setup continuation](plan-status-browser-monitor-setup-continuation-2026-09-04.md) moves
the directory probe and FSEvents construction used for pane auto-refresh off MainActor and behind a serialized actor.
Immutable setup outcomes, per-pane task cancellation, and request/folder identity prevent obsolete streams from being
installed after navigation or teardown; cancelled work stops any monitor it created. Four new characterizations, the
focused 31-test monitor/sidecar selection, repository gate, and serial unfiltered 1,958-test run passed. The audit
remains 66 of 75 while Phase 3.1's remaining direct paths and real-volume/signpost/Thread Performance Checker evidence
stay open.

The latest [Known People iCloud-routing continuation](plan-status-known-people-icloud-routing-continuation-2026-09-04.md)
moves ubiquity-container resolution and the complete preserve-newer database reconciliation out of the MainActor
sync coordinator and behind one serialized actor. Immutable cancellation/durable evidence plus request identity
gate preference, cache-route, privacy-confirmation, and cloud-watcher publication. The watcher and Settings storage
summary reuse actor-resolved roots instead of probing iCloud from MainActor. Three new characterizations cover both
directions, off-main execution, unavailable iCloud, and cancellation stages. The adjacent 52-test selection,
repository gate, and serial unfiltered 1,961-test run passed. The audit remains 66 of 75 while Phase 3.1's remaining
direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Teams and Watermark iCloud-routing continuation](plan-status-library-icloud-routing-continuation-2026-09-04.md)
moves ubiquity-container resolution and complete preserve-newer reconciliation for both libraries out of the
MainActor sync coordinator and behind independently serialized actor instances. Per-library request identity gates
preferences, resolved cache routes, reloads, and watchers; both watchers now reuse actor-resolved roots for startup
and filtering. Two new characterizations cover both directions, off-main execution, unavailable iCloud, and durable
cancellation. The focused 18-test suite, adjacent 30-test selection, repository gate, and serial unfiltered
1,963-test run passed. The audit remains 66 of 75 while the security-scoped Templates route, other direct paths,
and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Templates iCloud-routing continuation](plan-status-template-icloud-routing-continuation-2026-09-04.md)
moves security-scoped bookmark resolution and lifetime, ubiquity-container resolution, and complete preserve-newer
reconciliation out of the MainActor sync coordinator and behind one serialized actor. Request identity gates the
preference commit, and metadata/Develop inventories reload only from a post-commit storage-change notification.
Three characterizations cover both directions, off-main execution, balanced security-scope release for unavailable,
cancelled, durable, and failing paths, plus current-request publication. The focused 21-test suite, adjacent 48-test
selection, repository gate, and serial unfiltered 1,966-test run passed. The audit remains 66 of 75 while other
direct paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [iCloud availability-cache continuation](plan-status-icloud-availability-cache-continuation-2026-09-04.md)
moves the remaining Sync-settings ubiquity-container availability lookup out of SwiftUI/MainActor evaluation and
behind a serialized, cancellation-aware actor. Settings now presents cached unknown/checking/available/unavailable
state, and Preferences sync commits only after the current probe reports available. Three characterizations cover
off-main execution, both outcomes, cancellation around the non-preemptible lookup, and preference gating. The
focused 24-test suite, adjacent 51-test selection, repository gate, and serial unfiltered 1,969-test run passed.
The audit remains 66 of 75 while other direct paths and real-volume/signpost/Thread Performance Checker evidence
stay open.

The latest [Advanced Export preview cleanup continuation](plan-status-advanced-export-preview-cleanup-continuation-2026-09-04.md)
moves recursive removal of full-resolution comparison-preview artifacts out of SwiftUI-owned storage `deinit` and
behind a serialized actor. Final release performs only a non-cancellable asynchronous handoff, while explicit actor
results distinguish pre-removal cancellation, durable removal with post-commit cancellation, and failure. Four
characterizations cover off-main execution, serialization, both cancellation stages, injected failure evidence, and
nonblocking final release. The focused 4-test suite, adjacent 26-test export selection, repository gate, and serial
unfiltered 1,973-test run passed. The audit remains 66 of 75 while other direct paths and real-volume/signpost/Thread
Performance Checker evidence stay open.

The latest [Analysis annotation-index continuation](plan-status-analysis-annotation-index-continuation-2026-09-04.md)
removes repeated symlink resolution from synchronous SwiftUI photo-annotation count lookups. The Analysis workspace
now publishes an in-memory case index for canonical stored URLs and the already-known Browser presentation folder,
so security-scoped/symlinked routes and rename updates remain coherent without another filesystem projection. Two
new characterizations, the focused 70-test Analysis suite, repository gate, and serial unfiltered 1,975-test run
passed. The audit remains 66 of 75 while other direct/cached-model paths and real-volume/signpost/Thread Performance
Checker evidence stay open.

The latest [Watermark persistence and cache continuation](plan-status-watermark-persistence-cache-continuation-2026-09-04.md)
moves complete metadata/PNG inventory, tombstone cleanup, conflict resolution, import, metadata mutation, deletion,
and initial local/iCloud root resolution behind one serialized actor. The MainActor store now publishes immutable
asset and PNG caches, and its synchronous Settings/Develop accessors are filesystem-free. Remote events replace one
complete snapshot rather than patching individual files on MainActor. Two new characterizations and source contracts,
the focused 39-test Watermark/iCloud selection, repository gate, and serial unfiltered 1,977-test run passed. The
audit remains 66 of 75 while other direct/cached-model paths and real-volume/signpost/Thread Performance Checker
evidence stay open.

The latest [Known People thumbnail cache continuation](plan-status-known-people-thumbnail-cache-continuation-2026-09-04.md)
moves person and embedding JPEG reads out of synchronous SwiftUI/MainActor presentation and behind one serialized,
cancellation-aware actor. Bounded caches, storage revision, and request identity prevent obsolete local/iCloud or
remote content from publishing; the affected Known People screens and roster PDF export now await immutable data
and render from memory. Two new characterizations, the focused 43-test Known People/iCloud/roster selection,
repository gate, and serial unfiltered 1,979-test run passed. The audit remains 66 of 75 while other lower-priority
direct/cached-model paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Approved List cache continuation](plan-status-approved-list-cache-continuation-2026-09-04.md) moves
Approved Keywords initialization, anonymous-notification refresh, legacy save, and deletion through the existing
serialized keyword-list persistence actor. Synchronous Settings and validation accessors now use only the published
parsed cache; replacement loads cancel and identity-gate publication, and durable save/delete evidence is published
without a second MainActor read. Two new characterizations, the focused 22-test selection, adjacent 56-test
selection, repository gate, and serial unfiltered 1,984-test run passed. The audit remains 66 of 75 while other
lower-priority direct/cached-model paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Open Recent bookmark continuation](plan-status-recent-folder-bookmark-continuation-2026-09-04.md) moves
launch-time stale-bookmark resolution, security-scope retention, and per-folder bookmark creation behind one
serialized actor. The MainActor store publishes only complete current snapshots, cancellation carries exact prefix
evidence, folder scanning waits until scope retention completes, and Clear Menu rejects late results. Two new
characterizations, the focused 8-test suite, adjacent 18-test selection, repository gate, and serial unfiltered
1,986-test run passed. The audit remains 66 of 75 while Favorite-folder bookmarks, other lower-priority direct/
cached-model paths, and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Favorite-folder bookmark continuation](plan-status-favorite-folder-bookmark-continuation-2026-09-04.md)
moves launch resolution, Add to Favorites, and moved-favorite bookmark refresh behind a serialized actor. Favorite
publication is request-tagged and complete-only; cancellation distinguishes no access, an inspected but unpublished
prefix, and a completed bookmark API that observed cancellation afterward. Three new characterizations, the focused
13-test selection, adjacent 28-test selection, repository gate, and serial unfiltered 1,989-test run passed. The
audit remains 66 of 75 while lower-priority direct/cached-model paths and real-volume/signpost/Thread Performance
Checker evidence stay open.

The latest [Settings template bookmark continuation](plan-status-settings-template-bookmark-continuation-2026-09-04.md)
moves launch resolution, stale refresh, and chooser-time creation for the custom Templates folder behind a serialized
actor. Settings publishes only complete current results, Clear invalidates pending work, and security-scope access
remains balanced. Four new characterizations, the focused 4-test suite, adjacent 53-test selection, repository gate,
and serial unfiltered 1,993-test run passed. The audit remains 66 of 75 while the Import backup bookmark, other
lower-priority direct/cached-model paths, and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Import destination bookmark continuation](plan-status-import-destination-bookmark-continuation-2026-09-04.md)
moves launch restoration, stale refresh, and chooser-time creation for both the primary and optional backup Import
destinations behind one serialized actor. Import publishes only complete current results, rejects superseded
restorations and creations, and Clear invalidates pending backup work while security-scope access remains balanced.
Four new characterizations, the focused 21-test suite, adjacent 41-test selection, repository gate, and serial
unfiltered 1,997-test run passed. The audit remains 66 of 75 while other lower-priority direct/cached-model paths and
real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [SwiftExif technical snapshot continuation](plan-status-swiftexif-technical-snapshot-continuation-2026-09-04.md)
keeps the complete technical-metadata enrichment inside the existing per-photo metadata executor. SwiftExif parsing,
optional ImageIO profile/bit-depth inspection, and immutable `TechnicalMetadata` construction now share one lock and
return one Sendable value to MainActor, so an intervening metadata write cannot split the snapshot. Three new
characterizations, the adjacent 118-logical-test/123-expanded-run selection, repository gate, and serial unfiltered
2,000-logical-test/2,127-expanded-run gate passed. The audit remains 66 of 75 while other lower-priority direct/
cached-model paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [Import source security-scope continuation](plan-status-import-source-security-scope-continuation-2026-09-04.md)
moves security-scope acquisition and release for both primary and optional voice-memo source scans into the existing
serialized discovery actor. The scope now covers the recursive enumeration on the same executor, successful access
is always balanced, and cancellation is explicit on both sides of the non-preemptible acquisition call. Four new
characterizations, the focused 8-test suite, adjacent 45-test import selection, repository gate, and serial unfiltered
2,004-test run passed. The audit remains 66 of 75 while other lower-priority direct/cached-model paths and real-volume/
signpost/Thread Performance Checker evidence stay open.

The latest [RAW archive security-scope continuation](plan-status-raw-archive-security-scope-continuation-2026-09-04.md)
moves configured ingest/archive-root security-scope acquisition and release out of the MainActor-inheriting archive
task and behind one serialized actor. Unique roots receive at most one claim, unavailable optional claims preserve
the existing permissive behavior, and cancellation during a synchronous acquisition releases the exact successful
prefix before returning. Four new characterizations, the focused 24-test RAW archive suite, repository gate, and
serial unfiltered 2,008-test run passed. The audit remains 66 of 75 while other lower-priority direct/cached-model
paths and real-volume/signpost/Thread Performance Checker evidence stay open.

The latest [import execution security-scope continuation](plan-status-import-execution-security-scope-continuation-2026-09-04.md)
moves primary source, optional voice-memo source, destination, and optional backup access lifetimes behind a
serialized actor-owned lease. Roots are standardized and deduplicated per phase, only successful optional claims are
released, cancellation during a non-preemptible access releases the exact successful prefix, and every normal,
early-return, cancellation, or failure exit releases in reverse order. Five new characterizations, the focused
34-test import selection, repository gate, and serial unfiltered 2,013-test run passed. The audit remains 66 of 75
while other lower-priority direct/cached-model paths and real-volume/signpost/Thread Performance Checker evidence
stay open.

The latest [Settings structured-keyword import continuation](plan-status-settings-structured-keyword-import-continuation-2026-09-04.md)
moves both Structured Keywords and Structured Person Shown picker reads, security-scope lifetimes, and managed-text
commits through serialized actors. Replacement requests reject stale reads, view disappearance cancels pending work,
and durable commits publish their in-memory hierarchical text so observers do not synchronously re-read the managed
file on MainActor. Five new characterizations, the focused 32-test selection, repository gate, and serial unfiltered
2,018-test run passed. The audit remains 66 of 75 while other lower-priority direct/cached-model paths and real-volume/
signpost/Thread Performance Checker evidence stay open.

The latest [Advanced Export preparation continuation](plan-status-advanced-export-preparation-continuation-2026-09-04.md)
moves selection-scaled RAW XMP sidecar reads and native-dimension probes out of `ContentView`'s MainActor path and
through a serialized actor. The service preserves live Camera Raw precedence, pending-iCloud and EXIF-orientation
behavior, exact cancellation evidence, and serialized access; the caller cancels replacements and rejects stale
request or ordered-selection publication. Five new characterizations, the focused 15-test Advanced Export suite,
repository gate, and serial unfiltered 2,023-test run passed. The audit remains 66 of 75 while other lower-priority
direct/cached-model paths and real-volume/signpost/Thread Performance Checker evidence stay open.

## File organization convention

- `docs/README.md` — master planning index.
- `docs/*-plan.md` — cross-release initiative or specialist implementation plans.
- `docs/adr-*.md` — durable architecture/product decisions that apply across releases.
- `docs/*-support.md`, `docs/*-policy.md`, and matrices — supporting capability or policy ledgers.
- `docs/vX.Y/README.md` — one release's overview and decision log.
- `docs/vX.Y/delivery-plan.md` — that release's executable checklist.
- `docs/vX.Y/phase-*-validation.md` — dated evidence that a phase met its gate.

Avoid renaming existing documents solely for consistency; stable links and history are more useful
than cosmetic uniformity. New documents should follow this convention.
