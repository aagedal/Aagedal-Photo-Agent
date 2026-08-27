# Next release — delivery plan (historical `v2.3` working path)

## Delivery strategy

Build the next release as independently shippable vertical slices. The shared foundation comes first;
metadata/provenance analysis, comparison, and version storage can then proceed without waiting for
the highest-risk forensic algorithms.

No phase is complete with only a view mockup. Each phase includes model, persistence where relevant,
tests, error states, accessibility, and a manual validation note.

**Open-item reconciliation (2026-08-25):** 118 of 142 checklist items are complete and 24 remain open.
The remaining items are genuine gates: three Phase 0 benchmark/model decisions, three manual
validation passes in Phases 3/4/8, all eight unapproved conditional-analyzer steps in Phase 11, and ten
Phase 12 performance, device, privacy, accessibility, recovery, documentation, and release tasks. Current
source and dated validation records do not justify closing any of those 24 items.

## Phase 0 — research, decisions, and fixtures

**Exit gate:** the project can make evidence claims and distribute every required dependency/fixture
legally and reproducibly.

- [x] Define the exact next-release must/conditional scope from the release plan.
- [x] Create architecture decision records for [storage location](adr-001-analysis-version-storage.md),
  [source identity](adr-002-source-revision-identity.md),
  [map imagery in reports](adr-004-map-report-evidence.md), and
  [named-version save semantics](adr-003-named-version-save-semantics.md).
- [x] Build the
  [redistributable analysis fixture corpus and provenance README](analysis-fixture-corpus-validation.md).
- [x] Inventory existing comparison/loupe/viewport code suitable for extraction; see
  [Existing components to reuse](README.md#existing-components-to-reuse).
- [ ] Benchmark current preview, RAW decode, scopes, hashing, and two-image memory use.
- [ ] Decide target hardware tiers and concrete memory/latency budgets.
- [x] Prototype raw metadata graph extraction without flattening conflicting namespaces; see the
  [Phase 2 analysis-shell validation](phase-2-analysis-shell-validation.md).
- [x] Prototype one compression/residual view and document benign counterexamples; see the
  [Phase 3 pixel-inspection validation](phase-3-pixel-inspection-validation.md).
- [x] Verify MapKit satellite snapshot/report redistribution and attribution requirements.
- [ ] Evaluate candidate on-device AI-origin models and licenses; record a ship/no-ship decision.
- [x] Decide version treatment of decoder/process state and unparsed corrections; see the
  [implemented source-bound snapshot policy](comparison-and-versions.md#implemented-source-bound-snapshot-policy).
- [x] Choose keyboard shortcuts after auditing existing shortcuts; see the
  [accessibility and keyboard audit](../accessibility-keyboard-audit-validation.md).
- [x] Decide folder-local vs Application Support fallback UX.

**Implementation reconciliation (2026-08-24):** ADR-001 through ADR-004 now record all four
required architecture decisions. The shipped implementation and dated validation notes also
provide the Phase 0 component inventory, namespace-preserving raw metadata extraction, bounded
compression-residual prototype and benign counterexamples, source-bound decoder/unparsed-correction
policy, shortcut-conflict audit, and hash-bound CC0 analysis corpus linked above. The corpus records
authentic camera/HEIC/HDR/signed-C2PA additions as explicit non-claims; this reconciliation does not
claim the still-open benchmark, target-hardware, model/licensing, or manual-validation gates.

**Scope lock (2026-08-24):** The authoritative `README.md` in this directory now provides explicit
**Must ship in 3.0**, **Conditional scope**, and **Explicitly out of scope** lists. None of the
Phase 11 forensic analyzers has passed its research, licensing, calibration, and product-language
gates, so those analyzers are excluded from the 3.0 release requirement and do not block the core
investigation, comparison, or versioning release. The separately approved deterministic
solar-position direction overlay is part of the OSINT/report scope; it is not approval for the
broader sun/shadow consistency analyzer. Difference blend, non-MapKit online imagery/search,
report signing, and C2PA attachment likewise remain deferred unless their documented conditional
gates are completed before release-candidate scope freeze.

**Deliverables:** decision records, fixture inventory, benchmarks, proof-of-concept screenshots, and
updated conditional-scope decision.

## Phase 1 — shared source, persistence, and transforms

**Exit gate:** an unchanged source can be identified, persisted records recover from failure, and
all coordinate round-trips pass.

- [x] Implement `SourceImageRevision` and cancellable streaming SHA-256.
- [x] Add source discovery/reassociation by resource ID and hash.
- [x] Implement versioned atomic JSON document storage with bounded backup.
- [x] Define unknown/newer schema behavior.
- [x] Implement normalized display/source pixel transforms for all EXIF orientations.
- [x] Implement shared viewport state and view/image coordinate mapping.
- [x] Add transform fixtures for crop/straighten and different aspect ratios.
- [x] Audit security-scoped access and avoid repeat prompts.
- [x] Add folder monitor filtering and invalidation for new hidden stores.
- [x] Add corruption, read-only, iCloud-offline, rename/move, and source-changed tests.

## Phase 2 — analysis shell and source facts

**Exit gate:** one selected image opens a persistent case, fast evidence appears, and analysis never
modifies the source.

- [x] Add `MainViewMode.imageAnalysis` and layout-menu entry.
- [x] Create `AnalysisCase` owner and workspace navigation.
- [x] Add Pixel Analysis / OSINT mode selector.
- [x] Implement source revision validation and stale-case banner.
- [x] Add original/developed representation selector with explicit labels.
- [x] Implement analyzer runner states, progress, cancellation, and cache keys.
- [x] Add source facts and raw metadata/provenance analyzer.
- [x] Integrate C2PA validation states without collapsing validity and trust.
- [x] Add metadata consistency rule engine and initial rule set.
- [x] Add plain-language finding detail, technical detail, alternatives, and report inclusion.
- [x] Verify no metadata/source writes with file-system observation tests.

## Phase 3 — pixel views, scopes, and hover inspection

**Exit gate:** normal and derived views remain spatially aligned and useful at fit and true pixels.

- [x] Extract reusable true-pixel/normalized hover utilities from Advanced Export.
- [x] Generalize scope requests and output sizing without regressing the existing scope sidebar.
- [x] Build resizable one/two/four-up scope layouts.
- [x] Add linked hover sampling, source-pixel readout, and a source-resolution 100% /
  nearest-neighbor magnified hover loupe to Image Analysis.
- [x] Add selected-region scopes.
- [x] Add channel/luminance views.
- [x] Ship the calibrated compression/residual view with method/parameter label.
- [x] Add cost-bounded derived-view cache and cancellation.
- [x] Add HDR/SDR, alpha, orientation, crop, and malformed-source tests.
- [ ] Manually validate alignment and color behavior on the fixture corpus.

## Phase 4 — photo markup and measurement

**Exit gate:** annotations are precise, persistent, accessible, reversible, and stable across zoom.

- [x] Implement annotation model and migrations.
- [x] Build select, line/arrow, distance, rectangle, ellipse, and label tools.
- [x] Add fixed accessible palette and custom color.
- [x] Add per-surface undo/redo transactions.
- [x] Add annotation list/layer visibility and keyboard operations.
- [x] Add source-pixel measurement.
- [x] Add user-defined calibration segment and unit conversion.
- [x] Add linked finding/annotation references.
- [x] Test all orientations, view sizes, source changes, and report transforms.
- [ ] Validate keyboard-only and VoiceOver workflows.

## Phase 5 — OSINT map and timeline

**Exit gate:** embedded, inferred, and user-entered time/location evidence is distinguishable and
reportable without editing IPTC.

- [x] Implement timestamp evidence model with source, precision, and timezone-known state.
- [x] Build timeline/conflict UI.
- [x] Reuse coordinate parsing, place search, and reverse geocoding patterns.
- [x] Add satellite/hybrid map with persisted viewport.
- [x] Add map marker, line, shape, distance, label, and visibility tools.
- [x] Separate Photo and Map tool groups in one OSINT toolbar outside the draggable split.
- [x] Let every photo/map annotation kind carry an editable label.
- [x] Let photo annotations carry a separate case-only note.
- [x] Link map annotations to any photo annotation by stable ID and preserve its color.
- [x] Optionally add a bearing/angle/range field-of-view cone with the photo location.
- [x] Add a working-folder thumbnail rail and This Photo / Working Folder map-layer scope.
- [x] Show Photo Annotations and Map Annotations side by side below a full-height map column.
- [x] Add case-only observations without a timestamp.
- [x] Ensure analysis coordinates never silently write IPTC GPS.
- [x] Add offline/network-failure and no-imagery states.
- [x] Capture attribution-compliant report evidence.
- [x] Decide and, if approved, implement any sun/shadow conditional analyzer.

## Phase 6 — PDF report

**Exit gate:** a report generated from a frozen case snapshot is visually correct, reproducible, and
honest about methods and limitations.

- [x] Define immutable report snapshot.
- [x] Revalidate source hash at export.
- [x] Implement cover, facts/provenance, findings, figures, timeline/map, user observations,
  methodology, limitations, and appendix.
- [x] Add selectable sensitive fields and redaction warning.
- [x] Add evidence crop export with pixel/interpolation scale.
- [x] Add annotation legend and calibrated-measurement disclosure.
- [x] Add map attribution or schematic fallback.
- [x] Add progress, cancellation, atomic output, and cleanup.
- [x] Add PDF semantic/structural tests.
- [x] Render every page to images and visually verify A4 and US Letter.
- [x] Test long findings, Unicode, missing figures, many annotations, and multi-page cases.

## Phase 7 — comparison core

This can begin after Phase 1 in parallel with Analysis phases once implementation work starts.

**Exit gate:** two images compare reliably across aspect/orientation/crop differences without sync
feedback or memory spikes.

- [x] Implement comparison source/session models.
- [x] Implement coordinator transactions, lock, temporary unlock, offset, and reset.
- [x] Build side-by-side, stacked, and adjustable wipe layouts.
- [x] Add adjustable divider, focus, badges, and fit/100%/custom zoom.
- [x] Add Browser entry for exactly two selected images.
- [x] Add source replacement/navigation and deletion behavior.
- [x] Add original/committed/live/named representation labels.
- [x] Add sync math and feedback-loop tests.
- [x] Add two-RAW memory and cancellation validation.
- [x] Ship the wipe view; keep the difference view deferred.

## Phase 8 — comparison integrations

**Exit gate:** Develop, full-screen, and Clean Feed use the same session semantics and leave focus in
a valid state.

- [x] Add Develop comparison-target selection and live-current rendering.
- [x] Add full-screen entry/exit with safe window teardown and focus restoration.
- [x] Extend Clean Feed to side-by-side, stacked, and focused-pane presentation.
- [x] Add View-menu controls for Clean Feed comparison layout.
- [x] Add rating/label focused-image behavior.
- [x] Add shortcut help/settings entries.
- [ ] Validate monitor disconnect/reconnect, HDR/SDR pairing, and live edit load.
- [x] Add version-to-version comparison hook for Phase 10.

## Phase 9 — version storage

This can begin after Phase 1 independently of the analysis UI.

**Exit gate:** catalogs are source-bound, atomic, migration-safe, and losslessly snapshot the intended
Develop state.

- [x] Define catalog/settings schema and source binding.
- [x] Implement dedicated version snapshot sanitization.
- [x] Define decoder/as-shot/unparsed-correction handling.
- [x] Add dependency manifest for LUTs, watermarks, and raster masks.
- [x] Implement catalog create/read/update/delete with backup recovery.
- [x] Add Application Support fallback/read-only behavior.
- [x] Add source move/rename/change and reassociation behavior.
- [x] Verify new JSON never enters XMP.
- [x] Add round-trip tests for every current layer/effect type.

## Phase 10 — version workflow and promotion

**Exit gate:** users can work among versions without losing dirty state or accidentally overwriting
Primary.

- [x] Add Primary/named version selector in Develop.
- [x] Add create, duplicate, rename, delete, default, and summary.
- [x] Add debounced auto-save with Saving/Saved/Failed state.
- [x] Flush on switch/navigation/quit and block silent switch after a failed flush.
- [x] Apply a version as one edit-model transaction.
- [x] Define undo-stack reset and communicate it.
- [x] Invalidate every dependent preview/cache/feed.
- [x] Add missing/changed dependency UI.
- [x] Add version-to-version Compare.
- [x] Implement explicit Promote to Primary with recovery snapshot and XMP read-back.
- [x] Test failure at every promotion step.

## Phase 11 — conditional forensic analyzers

Only run this phase for gates approved in Phase 0.

- [ ] Lock analyzer/model license and attribution.
- [ ] Freeze validation corpus split before tuning.
- [ ] Record calibration and per-class error rates.
- [ ] Implement on-device inference with versioned cache key.
- [ ] Add alternatives/limitations and model card in UI/report.
- [ ] Add resource download/bundling, cleanup, and offline behavior.
- [ ] Validate false positives on screenshots, scans, exports, composites, and recompressions.
- [ ] Obtain explicit release sign-off on product language.

## Phase 12 — release hardening

**Exit gate:** all release criteria in `README.md` pass.

**Automated hardening follow-up (2026-08-25):** migration recovery notices, bundled-component provenance,
delivery transport defaults/evidence, and Metadata Review accessibility semantics are complete and validated
in the [parallel plan-status follow-up](../plan-status-parallel-follow-up-validation.md). These changes do not
close the broader manual performance, hardware, privacy, accessibility, recovery, documentation, or packaging
gates below.

**Release preflight follow-up (2026-08-26):** credential-free validation now rejects inconsistent Xcode,
Info.plist, CHANGELOG, SECURITY, and appcast release metadata before CI credentials, keychain access, signing,
or notarization. The [validation record](../release-metadata-preflight-validation-2026-08-26.md) strengthens
the final packaging prerequisite but does not close the signed release item or any of the 24 open gates.

- [x] Full existing test suite; see the current-source follow-up in
  [full-test-suite validation](../full-test-suite-validation.md#plan-status-hardening-integration-follow-up--2026-08-25).
- [x] New fixture-driven unit/render/persistence suites; included in the same fresh, unfiltered
  [full-suite evidence](../full-test-suite-validation.md#plan-status-hardening-integration-follow-up--2026-08-25).
- [ ] Performance and memory budgets on target hardware tiers.
- [ ] Profile representative two-RAW comparison sessions on every target hardware tier.
- [x] Thread Sanitizer/strict concurrency review for case, catalog, runner, and render coordination;
  see the [investigation concurrency validation](investigation-concurrency-validation.md).
- [ ] GPU validation and long-running analysis cancellation.
- [ ] Source/folder permission regression, including launch behavior.
- [ ] Security/privacy review of logs, temp files, map requests, and reports; automated review and
  remediations are recorded in the
  [investigation privacy review](../investigation-privacy-review-validation.md), while runtime log,
  filesystem-interruption, and network-capture evidence remains open.
- [ ] Accessibility and localization readiness.
- [x] Menu/shortcut conflict audit; see the
  [accessibility and keyboard audit](../accessibility-keyboard-audit-validation.md).
- [ ] Upgrade/downgrade/newer-schema manual tests.
- [ ] Backup/restore and crash-interruption drills; additive automated case and project-import
  boundary evidence is recorded in the
  [2026-08-25 recovery-drill validation](../backup-restore-crash-drill-validation-2026-08-25.md),
  while hands-on process-kill, filesystem, and restore exercises remain open.
- [x] README, feature help, limitations, privacy text, licenses, and CHANGELOG draft; the
  [2026-08-25 documentation-readiness validation](../documentation-readiness-validation-2026-08-25.md)
  records the complete drafts and the 2026-08-27 authoritative GPL-3.0 reconciliation for the pinned
  SwiftExif revision, vendor copy, in-app Licenses tab, and public component table.
- [ ] Version/build bump, notarized archive, Sparkle/appcast, and Homebrew release steps only after
  release candidate sign-off.

## Test matrix

| Axis | Required cases |
|---|---|
| Format | JPEG, PNG, HEIC/HEIF, TIFF, AVIF, JXL, each supported RAW family represented where practical |
| Dynamic range | SDR, direct HDR, gain map, RAW headroom |
| Orientation | 1–8, plus user rotation and straightened crop |
| Metadata | complete, stripped, conflicting, malformed, XMP sidecar, C2PA states |
| Storage | writable folder, read-only, iCloud online/offline, moved, renamed, changed |
| Display | single, external Clean Feed, disconnect, Retina/non-Retina, HDR/SDR pairing |
| Input size | tiny, ordinary, very large, panorama |
| Versions | empty, many, missing dependency, old schema, corrupt/latest backup |
| Comparison | same/different aspect, original/edit, edit/edit, named/named |
| Accessibility | keyboard, VoiceOver, reduced motion, increased contrast |

## Risk register

| Risk | Likelihood | Impact | Mitigation / gate |
|---|---:|---:|---|
| AI-origin false positives harm trust | High | High | Conditional model gate; no aggregate verdict |
| Compression visualizations are overinterpreted | High | High | Method labels, alternatives, fixture counterexamples |
| Scope expands beyond one release | High | High | Must/conditional split; core ships without model |
| Two live high-resolution sources exceed GPU memory | Medium | High | Bounded decode, one live/one cached fallback, budgets |
| Named version promotion loses XMP state | Low | High | Recovery snapshot, atomic writer, read-back verification |
| Source changes make annotations invalid | Medium | High | Strong revision binding and explicit reassociation |
| Map imagery cannot be embedded in reports | Medium | Medium | Phase 0 licensing decision and schematic fallback |
| New hidden stores break move/delete/backup | Medium | High | Integration audit and transactional file-operation tests |
| Coordinate transforms diverge between surfaces | Medium | High | One shared transform module and orientation fixtures |
| `ContentView` becomes unmaintainable | High | Medium | Feature models; navigation-only integration |
| Repeated permission prompts continue | Medium | Medium | Phase 1 security-scope audit and launch regression |
| Reports expose sensitive GPS/serial/notes | Medium | High | Inclusion controls and explicit export warning |
| JSON conflicts on iCloud/shared folders | Medium | High | coordinated writes, external-change conflict UI |

## Recommended milestone cuts

### Milestone A — foundation preview

- source identity;
- analysis shell with source facts;
- shared viewport;
- version catalog storage tests.

### Milestone B — useful investigation build

- metadata/provenance findings;
- larger scopes and compression view;
- photo annotations and measurements;
- comparison core.

### Milestone C — complete workflow beta

- OSINT map/timeline;
- PDF report;
- all comparison integrations;
- named version UI and promotion.

### Milestone D — release candidate

- conditional analyzers that passed;
- performance, accessibility, recovery, privacy, documentation, and release gates.

## Definition of done for an implementation task

A checklist item is complete only when:

1. behavior and failure state are implemented;
2. automated tests cover pure logic/persistence where possible;
3. rendering/UI behavior has a documented manual check;
4. cancellation and source-change behavior are defined;
5. accessibility labels and keyboard behavior exist;
6. logs do not expose sensitive source/case data;
7. plan documentation is updated when behavior differs from the baseline.
