# Aagedal Photo Agent 2.3 — release plan

**Status:** implementation in progress

**Plan date:** 2026-07-26

**Target platform:** macOS 26, Apple Silicon

**Implementation status:** Phase 1 source identity, reassociation, atomic JSON persistence, EXIF
and developed crop/straighten coordinate transforms, shared viewport geometry, browser-folder
security-scope lifecycle, and hidden-store change routing implemented

Version 2.3 is a broad investigation and review release. It adds three connected
capabilities:

1. an **Image Analysis** workspace for pixel forensics and OSINT-oriented review;
2. a reusable **Comparison** experience for two images with synchronized navigation;
3. **named Develop versions**, stored privately as JSON rather than multiplying XMP
   representations.

This directory converts the short backlog in `TODO.md` into an implementation-ready
release plan and tracks progress as the application code is built.

## Product intent

2.3 should help a photographer, editor, or investigator answer three different questions:

- **What does the file itself support?** Inspect pixels, compression, metadata, provenance,
  and internally inconsistent signals.
- **How do these two images differ?** Compare framing, detail, edits, and compression at the
  same location and scale.
- **Which interpretation of this image should I keep?** Save and revisit named grading
  alternatives without duplicating source files.

The app must separate observations from conclusions. Image analysis can surface evidence
and explain why it matters, but must not claim that an image is authentic, manipulated, or
AI-generated when the evidence cannot establish that.

## Release principles

### Evidence, not verdicts

Analysis results use the terms **observation**, **warning**, and **limitation**. They do not
use a single “real/fake” score. Every automated finding records:

- what was observed;
- which analyzer produced it and its version;
- the source data used;
- a plain-language explanation;
- confidence in that narrow observation;
- known alternative explanations;
- whether the result can be reproduced from the unchanged source.

### Non-destructive by default

- Opening or running analysis never edits the source image or its metadata.
- Analysis cases and named Develop versions are app-private JSON.
- Report export produces a new PDF.
- Existing XMP behavior remains the compatibility path for the primary Develop state.
- A named JSON version is not written into XMP unless the user explicitly promotes it to
  the primary edit.

### Source integrity

Analysis is always tied to a specific source revision. A case records a strong source hash
when analysis starts and re-checks it before reopening or exporting a report. If the bytes
changed, the old results remain readable but are visibly marked **source changed** and are
not silently applied to the new revision.

### Shared interaction model

Image Analysis, Comparison, full-screen, Develop, and Clean Feed should share:

- normalized display-oriented coordinates;
- the same zoom limits and scaling choices where practical;
- one definition of “fit,” 100%, and synchronized pan;
- the same edited/original rendering rules;
- keyboard focus that belongs to the visible window.

## Scope

### Must ship in 2.3

- A first-class Image Analysis entry in the main layout selector.
- Pixel Analysis and OSINT modes within the analysis workspace.
- Source facts, metadata/provenance inspection, suspicious metadata rules, and
  human-readable explanations.
- At least one useful compression/residual visualization beside the normal image.
- Larger existing scopes with hover inspection.
- Normalized photo markup: line, distance, rectangle, ellipse, label, and color.
- Pixel measurements and optional real-world calibration.
- Satellite/hybrid map companion with linked colored labels and map markup.
- Analysis case persistence with source-revision validation.
- Analysis report PDF containing findings, evidence images, annotations, methodology,
  limitations, source hash, and map attribution when applicable.
- Two-image Comparison with synchronized zoom and pan, temporary unlock/offset, reset, and
  a clear alignment status.
- Comparison entry from Browser, Develop, and full-screen; a comparison presentation option
  for Clean Feed.
- Named Develop versions in an app-private version store, including create, rename,
  duplicate, switch, delete, and promote-to-primary.
- Backward-compatible storage and recovery behavior.
- Unit, rendering, persistence, performance, accessibility, and manual validation gates.

### Conditional scope

The following items ship only if their research gates pass:

- an on-device AI-origin detector;
- automatic highlight regions for “common AI artifacts”;
- automatic clone/copy-move detection;
- sun/shadow time consistency;
- an online imagery or place-search provider beyond MapKit;
- report signing or C2PA attachment.

Conditional work must not delay the evidence workspace, comparison, or versioning core.

### Explicitly out of scope

- A legally dispositive authenticity verdict.
- Face recognition against public or third-party databases.
- Reverse-image search scraping.
- Cloud upload of source pixels without a separate, explicit product decision.
- Silent metadata correction based on analysis.
- Writing the complete named-version catalog to XMP.
- Pixel-to-centimeter conversion inferred from DPI metadata alone.
- A general vector illustration editor.
- Collaborative cases, shared annotations, or multi-user merge in 2.3.

## Proposed user journeys

### Analyze one image

1. Select an image and choose **Image Analysis**.
2. The app creates or reopens a case tied to the current source hash.
3. Fast local analyzers produce source facts and metadata/provenance findings.
4. The user selects Pixel Analysis or OSINT.
5. Expensive analyzers run on demand and can be cancelled.
6. The user inspects scopes, compression views, and finding details; adds annotations.
7. The user optionally places the image on a satellite map and links matching labels.
8. The user exports a reproducible PDF report.

### Compare two images

1. Select exactly two images and choose **Compare**.
2. Both images start fit-to-view with synchronization enabled.
3. Zooming or panning either pane moves the other to the corresponding normalized position.
4. The user temporarily unlocks a pane to establish an alignment offset, then re-locks.
5. The same session can be opened in full-screen or sent to Clean Feed.
6. Leaving comparison returns selection and navigation to the previous workspace.

### Keep alternate grades

1. In Develop, choose **New Version from Current**.
2. Name the version and continue editing.
3. Switch among versions without overwriting the other snapshots.
4. The primary/XMP-backed edit remains identifiable.
5. Choose **Promote to Primary** to deliberately replace the current primary Develop state
   and write through the existing XMP save path.

## Product information architecture

```mermaid
flowchart TD
    Browser["Browser / selection"] --> Analysis["Image Analysis"]
    Browser --> Compare["Compare two images"]
    Browser --> Develop["Develop"]
    Develop --> Compare
    Develop --> Versions["Named versions"]
    FullScreen["Full-screen"] --> Compare

    Analysis --> Pixel["Pixel Analysis"]
    Analysis --> OSINT["OSINT"]
    Pixel --> Findings["Evidence findings"]
    Pixel --> Scopes["Scopes and forensic views"]
    OSINT --> Map["Satellite map"]
    OSINT --> Timeline["Time and location evidence"]
    Findings --> Markup["Linked annotations"]
    Scopes --> Markup
    Map --> Markup
    Timeline --> Report["PDF report"]
    Markup --> Report

    Compare --> CleanFeed["Clean Feed presentation"]
    Versions --> Develop
```

## Architecture direction

Do not add all 2.3 state directly to `ContentView`. Introduce bounded feature models and
services, with `ContentView` responsible only for navigation and shared dependencies.

```mermaid
flowchart LR
    Source["SourceImageRevision\nURL + size + dates + hash"] --> Case["AnalysisCase"]
    Source --> Pair["ComparisonSession"]
    Source --> Versions["DevelopVersionCatalog"]

    Case --> Runner["AnalysisRunner"]
    Runner --> Analyzers["Independent analyzers"]
    Case --> Annotation["Normalized annotations"]
    Case --> MapState["Map evidence"]
    Case --> Report["AnalysisReportExporter"]

    Pair --> Viewport["Shared ViewportState"]
    Versions --> Snapshot["CameraRawSettings snapshot"]
    Viewport --> AnalysisUI["Analysis UI"]
    Viewport --> CompareUI["Comparison UI"]
    Viewport --> FullScreenUI["Full-screen / Clean Feed"]
```

### Shared foundations

The first implementation phase should establish:

- `SourceImageRevision`: canonical file URL, resource identifier when available, byte size,
  modification date, and SHA-256;
- `DisplayImageTransform`: sensor orientation, displayed pixel size, crop/rotation context,
  and normalized point/rect transforms;
- `ViewportState`: scale, center, fit mode, interpolation, and optional synchronization
  offset;
- atomic, versioned JSON persistence with backup-before-replace;
- explicit schema migrations and unknown-field tolerance.

The names above describe responsibilities, not mandatory Swift type names.

## Existing components to reuse

| Existing component | Reuse in 2.3 | Constraint |
|---|---|---|
| `MainViewMode` and layout menu | Add Image Analysis navigation | Keep mode-specific toolbars out of one giant branch |
| `FullScreenImageCache` | Oriented/edited source loading | Analysis needs an explicit original-vs-developed policy |
| `ScopeViewModel`, `MetalScopePipeline`, `ScopeRenderService` | Existing four scopes | Generalize output sizing and hover sampling |
| Advanced Export comparison/loupe | Coordinate math, true-pixel crop ideas | Extract reusable behavior; do not couple analysis to export formats |
| `TechnicalMetadata` and metadata read services | Source facts and metadata observations | Analysis needs raw-value provenance, not display strings alone |
| C2PA validation services | Credential state and manifest detail | Report trusted/valid/invalid separately |
| `GPSSectionView` and `GeocodingService` | MapKit patterns and coordinate formatting | Analysis map state is evidence, not IPTC editing |
| `RosterPDFExporter` | Core Graphics PDF precedent | Analysis requires pagination, evidence figures, and accessibility metadata |
| `CameraRawSettings` | Version snapshot payload | Strip render-time/transient fields and preserve unknown corrections safely |
| Clean Feed controller/window | Secondary-display lifecycle | Comparison needs a new two-source presentation contract |

## Workstreams

| ID | Workstream | Primary output | Depends on |
|---|---|---|---|
| F0 | Research and fixtures | Decision records, reference corpus, licensing answer | none |
| F1 | Shared source and viewport foundation | Identity, transforms, persistence, sync model | F0 |
| A1 | Analysis case and workspace shell | Navigation, case lifecycle, mode switch | F1 |
| A2 | Metadata/provenance analyzers | Findings with explanations | A1 |
| A3 | Pixel views and analyzer runner | Compression/residual views, large scopes | A1 |
| A4 | Markup and measurement | Photo/map annotations, calibration | A1, F1 |
| A5 | OSINT map and timeline | Map placement and time/location evidence | A1, A4 |
| A6 | PDF report | Reproducible export | A2–A5 |
| C1 | Comparison core | Two-source session and synchronized viewport | F1 |
| C2 | Comparison integrations | Browser, Develop, full-screen, Clean Feed | C1 |
| V1 | Version storage | Catalog, migration, atomic writes | F1 |
| V2 | Version workflow | Develop UI, dirty state, promotion | V1 |
| R1 | Release hardening | Performance, accessibility, docs, regression | all shipping tracks |

Detailed sequencing and gates are in [delivery-plan.md](delivery-plan.md).

## Release gates

2.3 is release-ready only when all of the following are true:

1. Existing XMP edits open and save without semantic change.
2. Analysis and version JSON survive interruption and a failed write without losing the
   previous valid record.
3. A changed source file cannot silently inherit stale findings or annotations.
4. Every automated finding exposes its basis and limitations.
5. Comparison sync stays stable across different aspect ratios, orientations, crops, and
   edited/original display choices.
6. Switching versions cannot silently overwrite the previous dirty version.
7. Report figures match the on-screen source revision and include required attribution.
8. Full-screen and Clean Feed continue to transfer focus and tear down cleanly.
9. Large RAW and HDR inputs remain cancellable and stay within agreed memory limits.
10. VoiceOver, keyboard-only use, reduced motion, contrast, and minimum window size have
    documented manual passes.

## Decisions made by this plan

- Analysis results are persisted separately from IPTC JSON sidecars, XMP, and face data.
- The UI reports individual evidence, not an aggregate authenticity score.
- Analysis is original-source-first; a developed rendering can be inspected as a clearly
  labeled secondary representation.
- Measurements are pixels until the user supplies a calibration.
- Comparison synchronization uses normalized displayed-image coordinates and supports a
  user-defined offset.
- Named Develop versions are app-private JSON snapshots. The existing primary edit remains
  the XMP interoperability surface.
- Online or model-backed analyzers are opt-in additions, not requirements for the core
  analysis workspace.

## Open product decisions

These decisions should be resolved during F0 before their dependent phase begins:

1. Should analysis cases live beside the image in a hidden folder or in Application Support
   with a folder-local pointer? The recommendation is folder-local by default for portability,
   with Application Support fallback for read-only locations.
2. Should the report embed the full source image, a bounded preview, or only annotated crops?
   The recommendation is a bounded preview plus user-selected evidence crops.
3. Should satellite imagery be limited to MapKit, and can snapshots be redistributed inside
   exported reports under the applicable terms and attribution rules?
4. What calibrated model and corpus, if any, justify shipping AI-origin scoring?
5. Should a version switch auto-save the current named version, prompt, or keep an in-memory
   dirty buffer? The recommendation is auto-save to the version JSON after explicit version
   creation, with visible dirty/error state and undo remaining session-local.
6. Does Clean Feed show side-by-side, wipe, or the currently focused comparison pane by
   default? The recommendation is side-by-side with a View-menu choice.

## Plan documents

- [image-analysis.md](image-analysis.md) — analysis workspace, evidence model, pixel tools,
  OSINT, markup, maps, and reporting.
- [comparison-and-versions.md](comparison-and-versions.md) — synchronized comparison and
  named Develop versions.
- [storage-and-architecture.md](storage-and-architecture.md) — proposed schemas, ownership,
  transforms, migration, security, and recovery.
- [delivery-plan.md](delivery-plan.md) — phases, task breakdown, test strategy, risks, and
  release checklist.
- [wireframes.md](wireframes.md) — low-fidelity layouts and interaction states.

## Change-control rule

As implementation begins, update the checklists in `delivery-plan.md` and record material
scope or architecture changes in a dated decision log at the bottom of this file. Do not
silently redefine forensic claims or persistence behavior in code.

## Decision log

| Date | Decision | Reason |
|---|---|---|
| 2026-07-26 | Establish evidence-first analysis with no real/fake score | The requested evidence is useful; a universal verdict is not supportable |
| 2026-07-26 | Share source identity and viewport foundations across all three tracks | Prevent divergent orientation, crop, and stale-file behavior |
| 2026-07-26 | Keep named versions in JSON and retain one explicit primary XMP state | Meets app-private versioning goal while preserving interoperability |
| 2026-07-26 | Persist source SHA-256 as lowercase hex and treat filesystem identifiers as opaque discovery hints | Keeps exact byte identity portable while still supporting fast rename/move discovery |
