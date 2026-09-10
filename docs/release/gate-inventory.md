# 3.0 open-gate inventory

**Reconciled:** 2026-09-09. **Source baseline:** `8f6f11f45d873861d22266206049f87219612ca1` (clean when inspected).
This inventory preserves the unchecked baseline criteria. Current dispositions are updated
only when integration, review and evidence are recorded; historical checkbox text stays verbatim.
Cycle 1 completes the narrow playback implementation criterion while broader gates remain open.
Stable IDs below survive future source-line changes; line numbers refer to this baseline.

**Cycle 1 continuation:** [Integrated source and native test evidence](cycle-01-voice-memo-thumbnail-2026-09-09.md)
advances J-VOICE-LIFECYCLE with production Duplicate and J-VOICE-PLAYBACK with explicit Caption
playback. Thumbnail provider/orientation worker gaps also advance the open filesystem gates.
The verbatim inventory below remains the baseline snapshot; current entry dispositions note
these improvements without claiming the remaining broad gates closed.

[Planning ownership](../README.md#plan-ownership-and-status-rules) makes the three portfolio
plans authoritative for their criteria. The improvement audit is a cross-cutting backlog
also explicitly authorized by the [coordinator](coordinator.md). Historical `v2.3` paths
still target 3.0. Checked tasks and historical passing tests do not replace current-candidate
UI, failure/recovery, device or external evidence.

Every unchecked checkbox is reproduced, including nested parents and multi-line text.
Overlapping gates may share a dated run, but each exact criterion needs a disposition.
“External prerequisite” identifies a dependency to recheck, not proof that it is currently
unavailable. Finish local preparatory work before escalation. No mandatory external gate
below is reassigned to final human acceptance; the coordinator explicitly requires its
evidence before READY_FOR_USER_TESTING. Post-acceptance distribution is separately labelled.

## Reconciliation anchors

- [Latest storage/recovery/render validation](../plan-status-shared-transactions-recovery-render-continuation-2026-09-09.md)
  records 2,383 passing tests and the earlier `3bb9542` unsigned model-free package. These
  are historical evidence, not a fresh execution on the baseline above.
- [Voice memo foundation](../sony-alpha-voice-memo-companion-validation.md) and committed
  `Services/VoiceMemoCompanionRepository.swift` provide import records, lookup and batch
  rename artifacts. Baseline Caption workspace/session, variable and delivery models do
  not implement playback/transcription/variable/receipt integration. In-progress edits
  seen during reconciliation are deliberately excluded from completion claims.
- [Filesystem boundary validation](../filesystem-async-boundary-validation-2026-08-27.md)
  plus later continuation notes provide real implementation progress, not a complete
  remaining-call-site inventory or physical-volume responsiveness proof.
- [Scope lock](../v2.3/delivery-plan.md#phase-0--research-decisions-and-fixtures) explicitly
  excludes all unapproved Phase 11 forensic analyzers. The deterministic solar overlay
  is mandatory; it does not promote a forensic sun/shadow consistency analyzer.
- [Prerequisite audit](../manual-release-prerequisite-audit.md) is historical: Bridge,
  Photo Mechanic, VoiceOver and Instruments were available, but activation, credentials,
  signed old binaries and real devices/volumes need rechecking. It is not a fresh blocker audit.
- [CI evidence](../continuous-integration-release-gate-validation.md) distinguishes local
  exact-revision release checks from external branch-protection enforcement. Qualified
  privacy/legal review likewise has no local engineering substitute.

## Summary and execution order

| Authoritative plan | Unchecked criteria |
| --- | ---: |
| [app-improvement-audit-plan.md](../app-improvement-audit-plan.md) | 9 |
| [v2.3/delivery-plan.md](../v2.3/delivery-plan.md) | 23 |
| [journalistic-metadata-workflow-plan.md](../journalistic-metadata-workflow-plan.md) | 23 |
| [suncalc-plan.md](../suncalc-plan.md) | 6 |
| **Total (including nested parents)** | **61** |


First complete the remaining voice-memo feature chain and finish the filesystem ownership
inventory. In parallel with implementation, prepare disposable fixtures and perform actual
local Caption/Deadline/Analysis/solar/accessibility/recovery observations as desktop access
allows. Start fixture-rights, hardware/budget, test-server, signed-old-binary, legal-review
and branch-protection dependency preparation early. Then close the cross-tier and external
runs, integrate/regress/review the exact candidate, and finalize the HTML acceptance checklist.
Do not spend release time implementing excluded conditional analyzers.

## Cross-cutting improvement audit

### A-CI-PROTECTION

**Class:** External prerequisite. **Source:** [1.1 Add continuous integration and a mandatory release test gate](../app-improvement-audit-plan.md), line 721.

```text
- [ ] Require the workflow on the protected release branch.
```

**Current status:** Repository CI and exact-revision release preflight are implemented; remote enforcement is unverified.

**Smallest next action/evidence:** Inspect the protected release branch read-only; obtain authorized admin enforcement of macOS CI / Clean build and unfiltered tests, then record the rule and failing-test rejection.

### A-PRIVACY-LEGAL

**Class:** External prerequisite. **Source:** [2.2 Add a clear face-data and iCloud lifecycle checkpoint](../app-improvement-audit-plan.md), line 823.

```text
- [ ] Obtain a focused privacy/legal review of Known People, embeddings, thumbnails, clothing samples,
  folder-local face data, export, deletion, and optional iCloud sync.
```

**Current status:** Disclosures, consent and data-management controls are implemented; no qualified legal/privacy approval is recorded.

**Smallest next action/evidence:** Prepare the implemented Known People storage/export/deletion/sync evidence for a qualified reviewer and obtain their dated findings and disposition. Engineering review cannot satisfy this gate.

### A-TRANSPORT-SERVERS

**Class:** Agent validation + external prerequisite. **Source:** [2.3 Harden delivery transport decisions](../app-improvement-audit-plan.md), line 850.

```text
- [ ] Add real-server drills for FTP, explicit FTPS, and SFTP, including certificate/host-key failures.
```

**Current status:** Transport policy and injected failure tests exist; representative real-server evidence remains open.

**Smallest next action/evidence:** Recheck or provision disposable FTP, explicit FTPS and SFTP destinations; exercise verified success, invalid certificate/host key, disconnect and retry, preserving sanitized receipts.

### A-ACCESSIBILITY

**Class:** Agent validation + external prerequisite. **Source:** [2.4 Add UI automation and finish manual accessibility validation](../app-improvement-audit-plan.md), line 878.

```text
- [ ] Run and record VoiceOver rotor/order, Full Keyboard Access, IME, high contrast, Reduce Motion,
  text/localization stress, window extremes, and external-display Clean Feed.
```

**Current status:** Semantics and a UI smoke target exist; full OS behavior and external-display evidence remain unobserved.

**Smallest next action/evidence:** Run the built candidate through each named assistive-technology/display case; record app revision, steps, announced results and defects; recheck available display hardware.

### A-FILESYSTEM-BOUNDARIES

**Class:** Mandatory implementation + agent validation. **Source:** [3.1 Move blocking file work off the main actor](../app-improvement-audit-plan.md), line 895.

```text
- [ ] Put potentially blocking filesystem operations behind async, serialized service boundaries.
```

**Current status:** Many services and shared storage transactions now run off MainActor. The latest 2026-09-09 continuation explicitly leaves the broad gate open.

**Smallest next action/evidence:** Inventory remaining synchronous filesystem call sites by owning executor and workflow; prioritize core UI paths, implement any missing serialized boundary, then run Thread Performance Checker on slow-volume workflows.

### A-IMMUTABLE-CANCELLATION

**Class:** Mandatory implementation + agent validation. **Source:** [3.1 Move blocking file work off the main actor](../app-improvement-audit-plan.md), line 896.

```text
- [ ] Return immutable results to the main actor and make cancellation/partial success explicit.
```

**Current status:** Recent transaction/render/recovery slices preserve caller context, cancellation and guarded publication; no complete remaining-path disposition exists.

**Smallest next action/evidence:** For the remaining filesystem inventory, record immutable result ownership, cancellation before/during mutation, durable partial outcomes and stale-publication rejection; add focused regressions for uncovered boundaries.

### A-FILESYSTEM-MEASUREMENTS

**Class:** Agent validation + external prerequisite. **Source:** [3.1 Move blocking file work off the main actor](../app-improvement-audit-plan.md), line 897.

```text
- [ ] Add signposts and benchmarks for local SSD, network volume, iCloud placeholder, read-only volume, and
  large folder cases.
```

**Current status:** Privacy-bounded signposts and simulated blocking evidence exist; real SSD/network/iCloud/read-only/large-folder results do not close this criterion.

**Smallest next action/evidence:** Run the documented blocked-volume procedure on a disposable local SSD fixture first; record timing/signposts and responsiveness, then cover actual network, placeholder and read-only volumes when available.

### A-RAW-HDR-INSTRUMENTS

**Class:** Agent validation + external prerequisite. **Source:** [3.2 Coordinate image/GPU memory under one budget](../app-improvement-audit-plan.md), line 1573.

```text
- [ ] Benchmark rapid navigation/edit/export of representative large RAW/HDR files with Instruments.
```

**Current status:** Shared memory admission and regression coverage are implemented; representative RAW/HDR Instruments measurements remain open.

**Smallest next action/evidence:** Capture navigation/edit/export traces on real disposable RAW/HDR fixtures with hardware/OS, peak memory and cancellation outcomes; compare to agreed target budgets.

### A-MODEL-LIFECYCLE

**Class:** Agent validation + external prerequisite. **Source:** [4.3 Move the face model to a verified on-demand component](../app-improvement-audit-plan.md), line 1956.

```text
- [ ] The pre-converted quantized Core ML archive, descriptor, and detached signature are published at their
  production `aagedal.me` endpoints and returned HTTP 200 with the expected content types and lengths on
  2026-09-01. Build a model-omitted release candidate and validate clean install, offline, update, rollback,
  removal, interrupted/corrupt download, and relaunch behavior against the production server on every supported
  macOS tier. The HTTPS runtime, signature/hash verification, atomic install, receipt revalidation, rollback, and
  failure-injection tests are implemented.
  ([validation](auraface-on-demand-runtime-validation-2026-08-27.md))
```

**Current status:** The plan already records published model endpoints and implemented verified installation. An unsigned model-free package exists historically; required runtime lifecycle and OS-tier evidence is absent.

**Smallest next action/evidence:** Launch a fresh model-omitted candidate with isolated test state; verify production download/install, offline, update, rollback, removal, corrupt/interrupted download and relaunch on each supported macOS tier. Recheck endpoints; do not treat historical HTTP 200 or mocked tests as lifecycle evidence.

## Investigation and review delivery

### I-BASELINE-PERFORMANCE

**Class:** Agent validation + external prerequisite. **Source:** [Phase 0 — research, decisions, and fixtures](../v2.3/delivery-plan.md), line 267.

```text
- [ ] Benchmark current preview, RAW decode, scopes, hashing, and two-image memory use.
```

**Current status:** Automated workflow measurements exist, but the requested preview/RAW/scopes/hash/two-image baseline is unrecorded.

**Smallest next action/evidence:** Measure each workload on this host with identified authentic fixtures; record latency, memory, OS/hardware and trace paths.

### I-HARDWARE-BUDGETS

**Class:** Mandatory implementation / release decision. **Source:** [Phase 0 — research, decisions, and fixtures](../v2.3/delivery-plan.md), line 268.

```text
- [ ] Decide target hardware tiers and concrete memory/latency budgets.
```

**Current status:** Target hardware tiers and concrete budgets remain undecided; Apple Silicon-only support does not define performance tiers.

**Smallest next action/evidence:** Propose a bounded target-tier/fixture matrix and numeric budgets from measurements, record the engineering decision, and identify unrepresented tiers as external dependencies.

### I-AI-ORIGIN-DECISION

**Class:** Explicitly conditional/deferred. **Source:** [Phase 0 — research, decisions, and fixtures](../v2.3/delivery-plan.md), line 274.

```text
- [ ] Evaluate candidate on-device AI-origin models and licenses; record a ship/no-ship decision.
```

**Current status:** The 2026-08-24 scope lock excludes unapproved forensic analyzers from mandatory 3.0. No analyzer research gate has passed.

**Smallest next action/evidence:** Retain the documented no-ship scope disposition for 3.0. Evaluate candidates/licenses only if this conditional feature is explicitly promoted; do not implement it to clear an unchecked box.

### I-PIXEL-COLOR

**Class:** Agent validation + external prerequisite. **Source:** [Phase 3 — pixel views, scopes, and hover inspection](../v2.3/delivery-plan.md), line 349.

```text
- [ ] Manually validate alignment and color behavior on the fixture corpus.
```

**Current status:** Automated transform/render tests and synthetic fixtures exist; actual alignment/color review is open.

**Smallest next action/evidence:** Compare normal/residual/scopes/hover output against known orientation/color fixtures in the built app, including representative RAW/HDR when available; record visual evidence.

### I-MARKUP-ACCESSIBILITY

**Class:** Agent validation. **Source:** [Phase 4 — photo markup and measurement](../v2.3/delivery-plan.md), line 364.

```text
- [ ] Validate keyboard-only and VoiceOver workflows.
```

**Current status:** Markup implementation and accessibility semantics exist; keyboard/VoiceOver completion is unobserved.

**Smallest next action/evidence:** Create, select, edit and delete each markup type using keyboard and VoiceOver; verify calibration, focus and announced states.

### I-COMPARE-DISPLAYS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 8 — comparison integrations](../v2.3/delivery-plan.md), line 436.

```text
- [ ] Validate monitor disconnect/reconnect, HDR/SDR pairing, and live edit load.
```

**Current status:** Comparison/Clean Feed implementation exists; physical display transitions and mixed HDR/SDR loads remain open.

**Smallest next action/evidence:** Recheck attached hardware; exercise disconnect/reconnect, mixed HDR/SDR comparison and live edits with observed recovery, alignment and memory evidence.

### I-ANALYZER-LICENSE

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 477.

```text
- [ ] Lock analyzer/model license and attribution.
```

**Current status:** Phase 11 is excluded by the scope lock; no analyzer is approved for 3.0.

**Smallest next action/evidence:** Only upon explicit scope promotion, lock the selected analyzer/model license and attribution before distribution.

### I-ANALYZER-CORPUS

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 478.

```text
- [ ] Freeze validation corpus split before tuning.
```

**Current status:** Phase 11 is excluded by the scope lock.

**Smallest next action/evidence:** Only upon scope promotion, freeze independently separated tuning/validation corpus provenance and split before tuning.

### I-ANALYZER-CALIBRATION

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 479.

```text
- [ ] Record calibration and per-class error rates.
```

**Current status:** Phase 11 is excluded by the scope lock.

**Smallest next action/evidence:** Only upon scope promotion, record held-out calibration and per-class false-positive/negative rates.

### I-ANALYZER-INFERENCE

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 480.

```text
- [ ] Implement on-device inference with versioned cache key.
```

**Current status:** Phase 11 is excluded by the scope lock.

**Smallest next action/evidence:** Only upon scope promotion, implement local inference with cache identity tied to source/model/algorithm versions.

### I-ANALYZER-LIMITATIONS

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 481.

```text
- [ ] Add alternatives/limitations and model card in UI/report.
```

**Current status:** Phase 11 is excluded by the scope lock.

**Smallest next action/evidence:** Only upon scope promotion, add calibrated alternatives/limitations and a model card to UI and report.

### I-ANALYZER-RESOURCES

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 482.

```text
- [ ] Add resource download/bundling, cleanup, and offline behavior.
```

**Current status:** Phase 11 is excluded by the scope lock; it is separate from mandatory AuraFace lifecycle gate A-MODEL-LIFECYCLE.

**Smallest next action/evidence:** Only upon scope promotion, validate analyzer resource installation, cleanup and offline behavior.

### I-ANALYZER-FALSE-POSITIVES

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 483.

```text
- [ ] Validate false positives on screenshots, scans, exports, composites, and recompressions.
```

**Current status:** Phase 11 is excluded by the scope lock.

**Smallest next action/evidence:** Only upon scope promotion, run the named benign/counterexample classes and preserve held-out error evidence.

### I-ANALYZER-SIGNOFF

**Class:** Explicitly conditional/deferred. **Source:** [Phase 11 — conditional forensic analyzers](../v2.3/delivery-plan.md), line 484.

```text
- [ ] Obtain explicit release sign-off on product language.
```

**Current status:** Phase 11 is excluded by the scope lock; model-language sign-off cannot be inferred from engineering tests.

**Smallest next action/evidence:** Only upon scope promotion, obtain explicit release sign-off on tested product language.

### I-PERFORMANCE-EXIT

**Class:** Agent validation + external prerequisite. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 505.

```text
- [ ] Performance and memory budgets on target hardware tiers.
```

**Current status:** Phase 12 performance exit remains open despite passing architecture/stress tests.

**Smallest next action/evidence:** After I-HARDWARE-BUDGETS, measure workloads on every target tier and record pass/fail against each numeric budget.

### I-TWO-RAW-TIERS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 506.

```text
- [ ] Profile representative two-RAW comparison sessions on every target hardware tier.
```

**Current status:** Representative two-RAW sessions have not been profiled across all target tiers.

**Smallest next action/evidence:** Profile a repeatable two-RAW session on the current host, then remaining agreed hardware tiers; capture responsiveness, memory and trace evidence.

### I-GPU-CANCELLATION

**Class:** Agent validation. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 509.

```text
- [ ] GPU validation and long-running analysis cancellation.
```

**Current status:** Concurrency and render-task cancellation regressions pass historically; interactive GPU validation/long-running analysis remains open.

**Smallest next action/evidence:** Run GPU validation with repeated analysis start/cancel, navigation and export loads; inspect diagnostics and verify no stale result or retained workload after cancellation.

### I-PERMISSIONS-LAUNCH

**Class:** Agent validation + external prerequisite. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 510.

```text
- [ ] Source/folder permission regression, including launch behavior.
```

**Current status:** Permission/error handling has automated coverage; source/folder launch behavior needs actual OS evidence.

**Smallest next action/evidence:** Use disposable sources to exercise allowed/denied/revoked access at launch and after relaunch, including unavailable volumes, with retry/recovery observations.

### I-PRIVACY-RUNTIME

**Class:** Agent validation. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 511.

```text
- [ ] Security/privacy review of logs, temp files, map requests, and reports; automated review and
  remediations are recorded in the
  [investigation privacy review](../investigation-privacy-review-validation.md), while runtime log,
  filesystem-interruption, and network-capture evidence remains open.
```

**Current status:** Static privacy review/remediations exist; runtime logs, interrupted temp-file cleanup and network-capture evidence remain open.

**Smallest next action/evidence:** Run representative report/map workflows on non-sensitive fixtures while collecting sanitized logs/temp-file lifecycle/network destinations; verify no undisclosed source-pixel or private metadata disclosure.

### I-ACCESSIBILITY-LOCALIZATION

**Class:** Agent validation. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 515.

```text
- [ ] Accessibility and localization readiness.
```

**Current status:** Automatic semantics and shortcut audit do not establish OS-level accessibility/layout readiness. Localization readiness does not authorize a new full translation project.

**Smallest next action/evidence:** Run the common accessibility matrix plus text-expansion/localization layout stress in Analysis/Compare/Versions; record any actual localization product decision separately.

### I-SCHEMA-MANUAL

**Class:** Agent validation + external prerequisite. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 518.

```text
- [ ] Upgrade/downgrade/newer-schema manual tests.
```

**Current status:** Automated schema migration/newer-version protections exist; signed older-binary and interactive drills remain open.

**Smallest next action/evidence:** Create isolated backed-up test stores; exercise current upgrade/newer-schema refusal, then signed historical downgrade binaries when obtained; compare bytes and recovery UX.

### I-RECOVERY-DRILLS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 519.

```text
- [ ] Backup/restore and crash-interruption drills; additive automated case and project-import
  boundary evidence is recorded in the
  [2026-08-25 recovery-drill validation](../backup-restore-crash-drill-validation-2026-08-25.md),
  while hands-on process-kill, filesystem, and restore exercises remain open.
```

**Current status:** Additive automated recovery coverage exists; actual process-kill/filesystem/restore drills remain open.

**Smallest next action/evidence:** On disposable cases/version stores, kill during a controlled save/import, relaunch, restore a backup and verify exact retained content plus visible recovery state.

### I-DISTRIBUTION

**Class:** Post-user-acceptance release gate. **Source:** [Phase 12 — release hardening](../v2.3/delivery-plan.md), line 527.

```text
- [ ] Version/build bump, notarized archive, Sparkle/appcast, and Homebrew release steps only after
  release candidate sign-off.
```

**Current status:** Historical unsigned 3.0.0 (738) packaging does not satisfy notarization, update channels or public distribution. The criterion explicitly requires candidate sign-off first.

**Smallest next action/evidence:** Before handoff, identify and verify the candidate/package; after user acceptance and separate release authorization, perform any necessary final version/build bump, signing/notarization, Sparkle/appcast and Homebrew steps.

## Journalistic metadata workflow

### J-CORPUS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 0 — standards decisions and interoperability fixtures](../journalistic-metadata-workflow-plan.md), line 155.

```text
- [ ] Complete the legally redistributable fixture corpus:
```

**Current status:** Parent gate remains open because the two unchecked child fixture groups below lack complete provenance/decoding evidence; generated corpus coverage already exists.

**Smallest next action/evidence:** Close J-IPTC-FIXTURE and J-CAMERA-FIXTURES, then rerun applicable no-op/unrelated-write preservation tests. Do not count this parent as an additional independent fixture.

### J-IPTC-FIXTURE

**Class:** External prerequisite. **Source:** [Phase 0 — standards decisions and interoperability fixtures](../journalistic-metadata-workflow-plan.md), line 160.

```text
  - [ ] IPTC 2025.1 reference image containing all current fields; confirm redistribution terms
    before committing the official image.
```

**Current status:** Official all-fields reference-image redistribution terms were not established in the recorded validation.

**Smallest next action/evidence:** Recheck asset-level permission/license and preserve its provenance; commit the official image only when redistribution is established, then run field/preservation checks.

### J-CAMERA-FIXTURES

**Class:** Agent validation + external prerequisite. **Source:** [Phase 0 — standards decisions and interoperability fixtures](../journalistic-metadata-workflow-plan.md), line 165.

```text
  - [ ] Confirmed-redistributable decodable HEIC/HEIF and representative camera RAW originals.
```

**Current status:** Generated TIFF/PNG/JXL and RAW-sidecar tests exist; they do not supply decodable authentic RAW or HEIC originals.

**Smallest next action/evidence:** Obtain or create non-sensitive decodable HEIC and representative camera RAW with confirmed redistribution rights; record hashes/provenance and verify decoding/metadata preservation.

### J-IPTC-TESTS

**Class:** Agent validation + external prerequisite. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 319.

```text
- [ ] Run IPTC Interoperability Tests 1, 2, and 3 manually and store dated results in `docs/`.
```

**Current status:** Serializer and support-matrix tests exist; dated manual IPTC Interoperability Tests 1–3 results are absent.

**Smallest next action/evidence:** Acquire required authorized reference inputs, execute each official interoperability procedure against the candidate, and store dated field-level results/discrepancies.

### J-EXTERNAL-EDITORS

**Class:** Agent validation + external prerequisite. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 320.

```text
- [ ] Open representative outputs in current Bridge and Photo Mechanic and record discrepancies.
```

**Current status:** Historical local audit found Bridge and Photo Mechanic installed; activation and actual round trips remain unverified.

**Smallest next action/evidence:** Recheck availability/activation and round-trip representative JPEG plus RAW/XMP outputs in both tools; compare supported/unknown fields and document discrepancies.

### J-VOICE-LIFECYCLE

**Class:** Mandatory implementation + agent validation. **Source:** [Sony Alpha voice memos — ingest foundation implemented for 3.0](../journalistic-metadata-workflow-plan.md), line 647.

```text
- [ ] Persist the relationship through browser refresh, copy/archive, rename, move/reject,
  rollback, and source reassociation without presenting the WAV as a photo.
```

**Current status:** Import and rename foundations now also include production Duplicate, independently copied shared memos, hash/record stability checks and rollback. General Move and Reject are added in [cycle 2](cycle-02-memo-moves-toolbar-2026-09-09.md). [Cycle 3](cycle-03-memo-trash-2026-09-10.md) adds recoverable memo Trash and sibling metadata preservation; see its separate verification status. Archive/reassociation remain incomplete.

**Smallest next action/evidence:** Implement archive/reassociation using the [ownership design](voice-memo-archive-design.md). Cycle 3 passed automated and narrow native recovery checks; its [separate Caption correction](cycle-03-caption-baseline-2026-09-10.md) records remaining Restore/history baseline work. Preserve explicit shared/missing states and rollback. Real-sample end-to-end validation remains.

### J-VOICE-PLAYBACK

**Class:** Mandatory implementation + agent validation. **Source:** [Sony Alpha voice memos — ingest foundation implemented for 3.0](../journalistic-metadata-workflow-plan.md), line 649.

```text
- [ ] Expose the associated memo in Caption Workspace with playback, duration/source identity, and
  clear missing/ambiguous/unsupported states. Never transcribe or mutate metadata implicitly.
```

**Current status:** Explicit Caption WAV playback, filename/duration, Refresh and missing/unavailable states are integrated. Cancellation, source changes, teardown and synthetic native behavior have cycle 1 evidence. Rebuilt native checks expose duration, reject schema 99, and resolve duplicated records after relaunch. The authoritative implementation checkbox is now complete; real-Sony/audio/accessibility breadth remains in the related release validation gates. The quoted checkbox above preserves the baseline snapshot.

**Smallest next action/evidence:** Implementation criterion complete in cycle 1. Retain broader real-sample, audible playback and keyboard/VoiceOver acceptance as open required validation.

### J-VOICE-TRANSCRIPTION

**Class:** Mandatory implementation + agent validation. **Source:** [Sony Alpha voice memos — ingest foundation implemented for 3.0](../journalistic-metadata-workflow-plan.md), line 651.

```text
- [ ] Add cancellable local transcription with explicit language/model state, offline behavior, and
  review/edit-before-apply. Keep the audio source and generated transcript provenance distinguishable.
```

**Current status:** Baseline local transcription, review/provenance and model/language UI are not implemented.

**Smallest next action/evidence:** Choose a bounded local transcription integration, document language/model/offline availability, implement cancellable requests with stale-result rejection, and require review/edit before explicit apply.

### J-VOICE-VARIABLE

**Class:** Mandatory implementation + agent validation. **Source:** [Sony Alpha voice memos — ingest foundation implemented for 3.0](../journalistic-metadata-workflow-plan.md), line 653.

```text
- [ ] Add a carrier-neutral metadata variable such as `{voiceMemoTranscript}`. Resolve it through
  the existing template/variable engine so a user can place the reviewed transcript in Description,
  Extended Description, or another compatible field without silently overwriting existing text.
```

**Current status:** The baseline shared variable engine has no voiceMemoTranscript integration.

**Smallest next action/evidence:** Expose reviewed transcript through the shared carrier-neutral variable resolver; cover compatible targets, absent/unreviewed text and preservation of existing field values.

### J-VOICE-DELIVERY

**Class:** Mandatory implementation + agent validation. **Source:** [Sony Alpha voice memos — ingest foundation implemented for 3.0](../journalistic-metadata-workflow-plan.md), line 656.

```text
- [ ] Define whether delivery includes, excludes, or optionally carries the WAV; make the choice
  visible in Deadline preflight and receipts instead of silently dropping an ingested companion.
```

**Current status:** Baseline delivery plan/receipt has no visible WAV policy integration.

**Smallest next action/evidence:** Record an explicit include/exclude/optional policy; surface the chosen companion disposition in frozen Deadline preflight and receipts, and test no silent omission.

### J-VOICE-END-TO-END

**Class:** Mandatory implementation + agent validation + external prerequisite. **Source:** [Sony Alpha voice memos — ingest foundation implemented for 3.0](../journalistic-metadata-workflow-plan.md), line 658.

```text
- [ ] Add fixture-driven association, ingest, rename/rollback, transcription-state, variable,
  sidecar-durability, and delivery tests, followed by a manual card-to-caption pass on real samples.
```

**Current status:** Association, ingest and rename fixtures already exist; transcription/variable/delivery and full lifecycle coverage plus real card-to-caption observations remain incomplete.

**Smallest next action/evidence:** Extend fixture tests alongside J-VOICE-LIFECYCLE through J-VOICE-DELIVERY, then exercise real authorized Sony card samples from ingest to reviewed caption/delivery; widen body/firmware claims only with additional samples.

### J-CAPTION-100-KEYBOARD

**Class:** Agent validation. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 726.

```text
- [ ] Manual keyboard-only pass through at least 100 images without mouse use.
```

**Current status:** Caption navigation semantics and durability tests exist; the specified 100-image mouse-free pass is unobserved.

**Smallest next action/evidence:** Prepare 100 disposable images and navigate/edit/save through them entirely by keyboard; verify focus, persistence and failure/retry behavior with recorded counts.

### J-CAPTION-LAYOUT

**Class:** Agent validation. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 727.

```text
- [ ] Manual test at small and large window sizes, with long Unicode captions and many people.
```

**Current status:** Adaptive layouts and Unicode fixtures exist; interactive window/long-caption/many-people review remains open.

**Smallest next action/evidence:** Exercise minimum/large windows with long Unicode captions and many confirmed people; inspect navigation, wrapping, clipping, focus and persistence.

### J-RENAME-EXTERNAL-FILENAME

**Class:** Agent validation + external prerequisite. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 879.

```text
- [ ] Manual cross-tool check that preserved original filename is visible in Bridge/Photo Mechanic.
```

**Current status:** Standards-correct original-filename mapping has serializer/rollback tests; cross-tool visibility is unobserved.

**Smallest next action/evidence:** Rename a disposable embedded JPEG and RAW/XMP pair, open each in Bridge and Photo Mechanic, and record the actual original-filename field/value.

### J-DEADLINE-FIRST-USE

**Class:** Agent validation. **Source:** [Deadline UI](../journalistic-metadata-workflow-plan.md), line 976.

```text
- [ ] Run a first-use usability pass for Deadline with representative incomplete and ready
  assignments, then record the observed confusion points and approved layout/remediation changes in
  a dated validation note.
```

**Current status:** Information hierarchy and remediation changes are implemented; representative first-use observations are still required.

**Smallest next action/evidence:** Walk incomplete and ready assignments from opening Deadline through remediation and confirmation, record observed confusion and justified layout changes, then retest fixes; preserve final human acceptance as separate.

### J-DEADLINE-PREFLIGHT

**Class:** Agent validation + external prerequisite. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 1038.

```text
- [ ] Manual preflight on mixed JPEG/RAW, missing sidecars, offline iCloud files, C2PA files, and
  read-only sources.
```

**Current status:** Automated mixed-state preflight tests exist; real source-state UI evidence remains open.

**Smallest next action/evidence:** Run mixed JPEG/RAW/missing-sidecar/C2PA/read-only cases on disposable fixtures, then actual offline iCloud inputs; verify accurate reasons, remediation and Send eligibility.

### J-DELIVERY-SEND

**Class:** Agent validation + external prerequisite. **Source:** [Verification](../journalistic-metadata-workflow-plan.md), line 1204.

```text
- [ ] Manual send to test FTP and SFTP servers, then inspect delivered files in Bridge and Photo
  Mechanic.
```

**Current status:** Staging, transport, read-back and receipt tests exist; real send plus external-editor inspection is absent.

**Smallest next action/evidence:** Send only to disposable FTP/SFTP endpoints, retrieve delivered bytes and inspect them in both external editors; compare final metadata/filename/security receipt evidence.

### J-SIGNED-DOWNGRADE

**Class:** Agent validation + external prerequisite. **Source:** [Phase 6 — migration and release hardening](../journalistic-metadata-workflow-plan.md), line 1216.

```text
- [ ] Run a signed 2.0/2.1/2.2 older-binary downgrade drill; released binaries cannot be
  retroactively hardened by the current source.
```

**Current status:** Tag-derived current-store migration tests cannot prove behavior of signed released 2.0/2.1/2.2 binaries.

**Smallest next action/evidence:** Obtain the authentic signed historical applications, use isolated disposable backed-up state, and document upgrade/downgrade outcomes and any irreversible old-binary behavior.

### J-ENVIRONMENT-DRILLS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 6 — migration and release hardening](../journalistic-metadata-workflow-plan.md), line 1220.

```text
- [ ] File-permission, security-scoped bookmark, read-only volume, iCloud-offline, network drop, and
  disk-full drills.
```

**Current status:** Parent criterion has checked automated failure injection but its real OS/device/server child remains open.

**Smallest next action/evidence:** Execute J-REAL-ENVIRONMENT and verify user-visible retry/recovery plus data retention for every named condition; do not double-count the parent as independent evidence.

### J-REAL-ENVIRONMENT

**Class:** Agent validation + external prerequisite. **Source:** [Phase 6 — migration and release hardening](../journalistic-metadata-workflow-plan.md), line 1224.

```text
  - [ ] Real revoked bookmark, iCloud eviction, external-volume ACL/TCC/read-only media, physical
    disk exhaustion, and representative FTP/FTPS/SFTP disconnect/credential drills.
```

**Current status:** Historical audit lacked evicted iCloud fixtures, disposable media and server credentials; availability must be rechecked.

**Smallest next action/evidence:** Prepare disposable sources/endpoints, then exercise actual revoked bookmark, iCloud eviction, ACL/TCC/read-only media, bounded disposable-volume exhaustion and transport disconnect/credentials. Never exhaust the user system disk or mutate production recipients.

### J-ACCESSIBILITY-ALL

**Class:** Agent validation + external prerequisite. **Source:** [Phase 6 — migration and release hardening](../journalistic-metadata-workflow-plan.md), line 1226.

```text
- [ ] Accessibility pass and menu/shortcut conflict audit in every workspace.
```

**Current status:** Parent gate has checked automated semantics/shortcut routing across ten workspaces; its OS-level child is open.

**Smallest next action/evidence:** Execute J-ACCESSIBILITY-OS in every workspace and verify menu/shortcut behavior interactively; retain per-workspace outcomes and fixes.

### J-ACCESSIBILITY-OS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 6 — migration and release hardening](../journalistic-metadata-workflow-plan.md), line 1229.

```text
  - [ ] Manual VoiceOver, Full Keyboard Access, accessibility-size/localization, contrast/motion,
    window-extreme, live IME, and external-display Clean Feed pass.
```

**Current status:** Manual VoiceOver/Full Keyboard Access/IME/layout/display evidence is absent despite automated semantics.

**Smallest next action/evidence:** Run the named modes with disposable fixtures in each workspace; record focus order, announcements, text composition, contrast/motion/window behavior and external-display Clean Feed.

### J-INTEROP-RESULTS

**Class:** Agent validation + external prerequisite. **Source:** [Phase 6 — migration and release hardening](../journalistic-metadata-workflow-plan.md), line 1237.

```text
- [ ] Publish dated IPTC interoperability and Bridge/Photo Mechanic round-trip results.
```

**Current status:** No completed dated external interoperability report is recorded. This overlaps the actual runs above.

**Smallest next action/evidence:** After J-IPTC-TESTS, J-EXTERNAL-EDITORS, J-RENAME-EXTERNAL-FILENAME and J-DELIVERY-SEND, commit a consolidated dated field/carrier/tool-version results matrix and explicit discrepancies; publishing here means repository documentation, not public release.

## Solar overlay

### S-MAP-INTERACTIONS

**Class:** Agent validation. **Source:** [Phase 4 — live map rendering](../suncalc-plan.md), line 267.

```text
- [ ] Verify panning, zooming, selection, map rotation, pitch, and style switching.
```

**Current status:** Shared geometry and persisted camera-state tests exist; actual rendered camera/selection behavior is unobserved.

**Smallest next action/evidence:** On a known location/time, pan, zoom, select markup, rotate, pitch and switch all map styles; verify true-north rays, label placement and unaffected selection/undo.

### S-SLIDER-STYLES

**Class:** Agent validation. **Source:** [Phase 6 — release validation](../suncalc-plan.md), line 318.

```text
- [ ] Manually test rapid slider interaction and actual Apple/OSM rendered style transitions.
```

**Current status:** 1,440-minute and out-of-order/model-style stress tests pass historically; they do not exercise actual rendering.

**Smallest next action/evidence:** Scrub time rapidly while switching Apple standard/muted/hybrid/satellite and OSM; verify final values/rays match the latest input and responsiveness remains acceptable.

### S-ROTATION-PITCH

**Class:** Agent validation. **Source:** [Phase 6 — release validation](../suncalc-plan.md), line 319.

```text
- [ ] Manually test rotated and pitched map rendering.
```

**Current status:** The shared ray model is invariant under persisted heading/pitch; rendered parity still needs observation.

**Smallest next action/evidence:** Compare rays at north-up/rotated and flat/pitched views across Apple/OSM; confirm geographic direction rather than screen-relative rotation, preserving screenshots.

### S-OFFLINE-UNCACHED

**Class:** Agent validation. **Source:** [Phase 6 — release validation](../suncalc-plan.md), line 320.

```text
- [ ] Verify fully offline operation after cached map content is unavailable.
```

**Current status:** Calculation/report geometry are network-independent in tests; no uncached live-map offline drill is recorded.

**Smallest next action/evidence:** Use an uncached disposable location with network unavailable through an approved safe test setup; verify calculator/rays/values remain usable and unavailable imagery is explicit without falsely retaining location imagery.

### S-ACCESSIBILITY

**Class:** Agent validation. **Source:** [Phase 6 — release validation](../suncalc-plan.md), line 321.

```text
- [ ] Complete keyboard-only and VoiceOver review.
```

**Current status:** Solar controls exist; keyboard-only and VoiceOver review is open.

**Smallest next action/evidence:** Set location/date/time/offset, scrub time and inspect sun/polar/below-horizon states with keyboard and VoiceOver; record focus and accessible value/status announcements.

### S-REPORT-VISUAL

**Class:** Agent validation. **Source:** [Phase 6 — release validation](../suncalc-plan.md), line 322.

```text
- [ ] Render A4 and US Letter reports and visually compare rays and values with the live workspace.
```

**Current status:** A4/Letter media boxes, labels, values and exact live/report geometry have automated assertions; visual parity is unobserved.

**Smallest next action/evidence:** Export A4 and US Letter from a frozen known workspace, open/render both PDFs, and compare rays, values, provenance, method/limitations and clipping against the live view.
