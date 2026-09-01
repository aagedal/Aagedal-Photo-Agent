# Plan-status Develop input-session continuation — 2026-09-01

## Scope and checklist result

This continuation advances the Phase 4.1 Develop state-owner and view-decomposition gate. Local AppKit
keyboard, scroll-wheel, and middle-mouse monitor registrations plus transient preview-hover, Space-hand,
filmstrip-hover, and keyboard-scroll-target state previously lived as separate values in
`EditWorkspaceView`. They now share one workspace-lifetime owner. Broader persistence lifetime, render/source
publication, geometry presentation, and remaining view decomposition stay open, so the audit remains
**63 of 75 checklist substeps complete**.

## Input-session ownership

`DevelopWorkspaceInputCoordinator` owns the complete process-local input lifetime. It installs and replaces
the three injected AppKit monitor tokens, removes an inactive registration immediately, removes each replaced
or ended registration exactly once, and defensively cleans an interrupted prior presentation when a workspace
begins again. Workspace teardown clears monitor registrations, preview and filmstrip hover, the held-Space hand
tool, and the keyboard filmstrip scroll target as one operation.

`EditWorkspaceView` still interprets concrete `NSEvent` values and performs navigation, zoom, copy-grade, and
cursor effects. This preserves UI behavior while removing AppKit registration ownership and five transient
input values from the feature monolith.

## Validation

Five coordinator characterizations cover inactive registration, same-kind monitor replacement, exact complete
teardown, interrupted reappearance, and the view-source ownership contract. The focused suite passed **5 tests**.
The adjacent Develop interaction regression passed **41 tests in 4 suites**, covering the new coordinator,
persistence/undo routing, interactive render cancellation and throttling, and established Develop interaction
behavior. The result bundle is
`/tmp/aagedal-v3-input-derived/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_10-29-49-+0200.xcresult`.

The complete `scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata,
JSON/plist/project validation, bundled artifact provenance, unified-log and investigation privacy checks,
conflict scanning, and whitespace validation.

The final serial unfiltered current-source gate passed **1,832 tests in 215 suites** in 59.311 seconds. Its
result bundle is
`/tmp/aagedal-v3-input-derived/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_10-30-42-+0200.xcresult`.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 retains lower-priority direct filesystem paths and
its local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread
Performance Checker evidence. Phase 4.1 retains broader Develop persistence task lifetime/cancellation/result
publication and remaining source/render/geometry view decomposition.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
