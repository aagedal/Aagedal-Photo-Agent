# Project planning overview

**Status:** living planning index  
**Last reviewed:** 2026-08-19

This document is the top-level index for product and implementation planning. It tracks the major
initiatives, their order and dependencies, while each linked sub-plan remains authoritative for its
own scope, tasks, exit gates, and technical decisions.

## Portfolio

| Initiative | Detailed plan | Status | Current gate |
| --- | --- | --- | --- |
| Version 2.3 | [Release plan](v2.3/README.md) and [delivery checklist](v2.3/delivery-plan.md) | Implementation and release hardening in progress | Close remaining manual fixture, accessibility, performance, and cross-phase validation |
| Journalistic metadata workflow | [Implementation plan](journalistic-metadata-workflow-plan.md) | Standards decisions largely established; foundation and fixture work remains | Complete the redistributable interoperability corpus, then finish the shared metadata model/I/O/validation foundation |
| SunCalc-style solar overlay | [Implementation plan](suncalc-plan.md) | Proposed post-2.3; implementation not started | Approve calculation conventions and reference corpus before calculation code or UI work |

## Default delivery order

1. Close the Version 2.3 release gates. Its source identity, case persistence, OSINT map/timeline,
   immutable report snapshot, and rendering behavior are foundations for later analysis features.
2. Continue the journalistic metadata standards foundation. Caption Workspace, Batch Rename, and
   Deadline Mode depend on one consistent field model, preservation policy, validation engine, and
   interoperability corpus.
3. Start the solar overlay after the 2.3 OSINT foundations are stable, unless it is explicitly
   reprioritized. It is a bounded map/report feature and does not block the journalistic workflow.

After the 2.3 gate, the journalistic workflow and solar overlay can proceed independently:

```text
Version 2.3 foundations and release hardening
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

## Version 2.3 document set

The [2.3 release plan](v2.3/README.md) is the entry point for this release. Its supporting documents
remain grouped under `docs/v2.3/`:

- [Delivery plan](v2.3/delivery-plan.md) — phase checklists and release gates.
- [Image Analysis](v2.3/image-analysis.md) — evidence workspace, pixel tools, OSINT map/timeline,
  markup, and reporting.
- [Comparison and versions](v2.3/comparison-and-versions.md) — synchronized comparison and named
  Develop versions.
- [Storage and architecture](v2.3/storage-and-architecture.md) — schemas, ownership, transforms,
  migration, security, and recovery.
- [Wireframes](v2.3/wireframes.md) — interaction and layout references.
- `phase-*-validation.md` — dated implementation and validation records.
- [Map report evidence ADR](v2.3/adr-004-map-report-evidence.md) — map imagery and report policy.

## Journalistic metadata document set

The [journalistic metadata workflow plan](journalistic-metadata-workflow-plan.md) is the parent for
Caption Workspace, standards coverage, Batch Rename, Deadline Mode, and verified delivery.

Supporting documents:

- [IPTC 2025.1 editorial support matrix](iptc-2025.1-editorial-support.md) — field-level support
  ledger and next conformance work.
- [ADR-005: IPTC 2025.1 editorial metadata baseline](adr-005-iptc-2025-1-editorial-metadata.md) —
  selected standard and compatibility baseline.
- [Metadata conflict and container policy](metadata-conflict-and-container-policy.md) — canonical
  values, conflicting representations, and preservation behavior.

## Solar overlay document set

The [SunCalc-style solar overlay plan](suncalc-plan.md) owns the post-2.3 first release. It defines
the app-owned Swift calculator, explicit time/location inputs, map presentation, persistence,
reports, numerical fixtures, and the boundary between a direction overlay and later forensic
shadow comparison.

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

