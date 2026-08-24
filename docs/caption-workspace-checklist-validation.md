# Caption Workspace compact-checklist validation

**Validated:** 2026-08-23  
**Scope:** Phase 2 Caption Workspace compact checklist, defaults, and field-discovery follow-up

## Implemented contract

- The metadata checklist starts collapsed instead of permanently reserving a scrolling block above
  the editor.
- Readiness, blocker/warning/information counts, and either the next actionable issue, an explicit
  no-visible-remediation state, or the ready state remain visible while the full checklist is
  collapsed.
- Next-issue selection reuses the shared validation ordering among fields exposed by the current
  layout: the first actionable blocker wins, otherwise the first actionable remaining issue is
  shown. Readiness/counts still include every validation issue, including required fields hidden
  from the current layout. The compact Fix action moves focus through the existing Caption focus
  boundary rather than introducing another editor path.
- The complete priority list and Secondary & Technical list remain available through native
  disclosure controls. Expanded priority content is height-bounded.
- Without a Deadline profile, the navigator derives its visible fields from the existing metadata
  visibility settings. A Deadline profile continues to supply its frozen ordered/visible field
  snapshot.
- A fresh install and the explicit Reset to Defaults action show only Headline, Description,
  Keywords, Creator, Copyright Notice, Person Shown, and Rights Usage Terms. The absence of a stored
  visibility value is distinct from an explicitly stored empty hidden set, so existing users'
  choices remain authoritative during upgrade.
- Stable accessibility identifiers distinguish the checklist, disclosure, next-issue action, and
  ready state; the issue action has a field-specific label and focus hint.
- A persistent footer below the visible metadata editor explains that additional IPTC fields can be
  enabled in Settings → Metadata. Its keyboard-accessible button requests the Metadata destination
  and opens the system Settings scene.
- The Settings view consumes that ephemeral destination on appearance or while already open,
  selects Metadata, and clears the request so later ordinary Settings launches retain normal
  behavior.

This record does not claim field ordering, required-field semantics, field guidance, or unified
Metadata Settings management.

## Automated evidence

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionWorkspaceSpeedToolsTests'
```

Result: **10 tests passed** in the Caption Workspace speed-tools suite. The run covers blocked,
warning-only, and ready compact summaries; blocker-first/actionable-field selection; existing field
layout, counts, preview, focus order, shortcut, announcement, static accessibility contracts, and
the Caption-to-Metadata-Settings navigation contract. The production application target compiled
and validated successfully as the test dependency.

The same build compiled the adjacent fresh-install and stored-upgrade visibility tests in
`IPTCMetadataTests.swift`. Those cases encode the seven-field default and the absent-versus-stored
visibility migration boundary; they were not part of this selected 10-test execution and remain
available to the combined release run.

Additional static checks passed:

```sh
xcrun swiftc -frontend -parse \
  'Aagedal Photo Agent/Models/CaptionWorkspaceSpeedTools.swift' \
  'Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift' \
  'Aagedal Photo Agent Tests/CaptionWorkspaceSpeedToolsTests.swift'
git diff --check
```

The test host emitted existing environment/runtime diagnostics for detached-signature logging,
LMDB map capacity, repeated per-frame observation, and a background SwiftUI publication; they did
not fail the build or selected tests and are not assertions from this checklist slice.

## Remaining observations

- Live VoiceOver disclosure announcements, Full Keyboard Access focus rings, narrow-window layout,
  localization expansion, and IME behavior remain part of the plan's manual accessibility pass.
- Field guidance, unified field management, and persisted custom ordering are tracked by separate
  3.0 usability items.
