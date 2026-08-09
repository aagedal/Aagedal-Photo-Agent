# Version 2.3 — delivery plan

## Delivery strategy

Build 2.3 as independently shippable vertical slices. The shared foundation comes first;
metadata/provenance analysis, comparison, and version storage can then proceed without waiting for
the highest-risk forensic algorithms.

No phase is complete with only a view mockup. Each phase includes model, persistence where relevant,
tests, error states, accessibility, and a manual validation note.

## Phase 0 — research, decisions, and fixtures

**Exit gate:** the project can make evidence claims and distribute every required dependency/fixture
legally and reproducibly.

- [ ] Define the exact 2.3 must/conditional scope from the release plan.
- [ ] Create architecture decision records for storage location, source identity, map imagery in
  reports, and named-version save semantics.
- [ ] Build the redistributable analysis fixture corpus and provenance README.
- [ ] Inventory existing comparison/loupe/viewport code suitable for extraction.
- [ ] Benchmark current preview, RAW decode, scopes, hashing, and two-image memory use.
- [ ] Decide target hardware tiers and concrete memory/latency budgets.
- [ ] Prototype raw metadata graph extraction without flattening conflicting namespaces.
- [ ] Prototype one compression/residual view and document benign counterexamples.
- [x] Verify MapKit satellite snapshot/report redistribution and attribution requirements.
- [ ] Evaluate candidate on-device AI-origin models and licenses; record a ship/no-ship decision.
- [ ] Decide version treatment of decoder/process state and unparsed corrections.
- [ ] Choose keyboard shortcuts after auditing existing shortcuts.
- [ ] Decide folder-local vs Application Support fallback UX.

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
- [x] Add linked hover sampling and source-pixel readout.
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
- [ ] Test all orientations, view sizes, source changes, and report transforms.
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
- [x] Build side-by-side, stacked, and A/B layouts.
- [x] Add adjustable divider, focus, badges, and fit/100%/custom zoom.
- [x] Add Browser entry for exactly two selected images.
- [x] Add source replacement/navigation and deletion behavior.
- [x] Add original/committed/live/named representation labels.
- [x] Add sync math and feedback-loop tests.
- [x] Add two-RAW memory and cancellation validation.
- [x] Decide whether wipe/difference views pass the 2.3 gate (deferred; neither blocks 2.3).

## Phase 8 — comparison integrations

**Exit gate:** Develop, full-screen, and Clean Feed use the same session semantics and leave focus in
a valid state.

- [x] Add Develop comparison-target selection and live-current rendering.
- [ ] Add full-screen entry/exit with safe window teardown and focus restoration.
- [ ] Extend Clean Feed to side-by-side, stacked, and focused-pane presentation.
- [ ] Add View-menu controls for Clean Feed comparison layout.
- [ ] Add rating/label focused-image behavior.
- [ ] Add shortcut help/settings entries.
- [ ] Validate monitor disconnect/reconnect, HDR/SDR pairing, and live edit load.
- [ ] Add version-to-version comparison hook for Phase 10.

## Phase 9 — version storage

This can begin after Phase 1 independently of the analysis UI.

**Exit gate:** catalogs are source-bound, atomic, migration-safe, and losslessly snapshot the intended
Develop state.

- [ ] Define catalog/settings schema and source binding.
- [ ] Implement dedicated version snapshot sanitization.
- [ ] Define decoder/as-shot/unparsed-correction handling.
- [ ] Add dependency manifest for LUTs, watermarks, and raster masks.
- [ ] Implement catalog create/read/update/delete with backup recovery.
- [ ] Add Application Support fallback/read-only behavior.
- [ ] Add source move/rename/change and reassociation behavior.
- [ ] Verify new JSON never enters XMP.
- [ ] Add round-trip tests for every current layer/effect type.

## Phase 10 — version workflow and promotion

**Exit gate:** users can work among versions without losing dirty state or accidentally overwriting
Primary.

- [ ] Add Primary/named version selector in Develop.
- [ ] Add create, duplicate, rename, delete, default, and summary.
- [ ] Add debounced auto-save with Saving/Saved/Failed state.
- [ ] Flush on switch/navigation/quit and block silent switch after a failed flush.
- [ ] Apply a version as one edit-model transaction.
- [ ] Define undo-stack reset and communicate it.
- [ ] Invalidate every dependent preview/cache/feed.
- [ ] Add missing/changed dependency UI.
- [ ] Add version-to-version Compare.
- [ ] Implement explicit Promote to Primary with recovery snapshot and XMP read-back.
- [ ] Test failure at every promotion step.

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

- [ ] Full existing test suite.
- [ ] New fixture-driven unit/render/persistence suites.
- [ ] Performance and memory budgets on target hardware tiers.
- [ ] Profile representative two-RAW comparison sessions on every target hardware tier.
- [ ] Thread Sanitizer/strict concurrency review for case, catalog, runner, and render coordination.
- [ ] GPU validation and long-running analysis cancellation.
- [ ] Source/folder permission regression, including launch behavior.
- [ ] Security/privacy review of logs, temp files, map requests, and reports.
- [ ] Accessibility and localization readiness.
- [ ] Menu/shortcut conflict audit.
- [ ] Upgrade/downgrade/newer-schema manual tests.
- [ ] Backup/restore and crash-interruption drills.
- [ ] README, feature help, limitations, privacy text, licenses, and CHANGELOG draft.
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
