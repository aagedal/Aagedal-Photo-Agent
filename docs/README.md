# Project planning overview

**Status:** living planning index  
**Last reviewed:** 2026-08-25

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
above. The audit baseline is reconciled to the latest recorded current-source run of 1,923 passing
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
