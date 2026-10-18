# Core shortcut editor continuation — 2026-10-18

This extends the shortcut editor to core application commands while keeping customization
inside Settings. Release performance, metadata durability and signed packaging qualification
remain open; no browsing or export speed improvement is claimed here.

## Changes

The shared profile now owns folder/import, export, metadata, navigation, Develop, scope,
upload and template menu shortcuts alongside rating and label bindings. Native command
builders observe the selected profile directly. Application commands have one menu shortcut;
culling commands retain focus-aware aliases. Cross-category reassignment requires an explicit
conflict confirmation and persists atomically in the existing profile document.

Version-one custom profiles preserve saved assignments and explicit removals. Migration adds
only unoccupied application defaults. Reserved text-editing, window and Caption Return keys
remain protected. Recording normalizes shifted characters to the underlying logical key and
distinguishes backward from forward Delete.

Isolated SwiftUI-hosted native menu tests exercise actual menu actions using unposted,
CGEvent-backed NSEvents. Initial hand-built fixtures incorrectly gave Command+Shift events
the same shifted character in both character fields. Probes using macOS-generated fields
confirmed the existing logical-key conversion; the speculative shifted-character translation
was removed. No US symbol map or keyboard-layout scan was added to production.
Realistic events also exposed Forward Delete retranslating to Backspace. Normalization now
retains the fixed Delete, Forward Delete and Return hardware identities before layout translation.

Settings provides a searchable categorized command list and a logical keyboard preview with
independent modifier toggles, assigned/free/reserved states and contextual descriptions.
One scroll container keeps the header, preview and longer command catalog inside the window.
Caption advance settings remain separate. The preview describes Develop overrides and its
forward-Delete compatibility fallback only when those gestures actually remain available.

Browser, fullscreen and comparison culling input resolve the same profile. Develop's local
event monitor is limited to its owning key window, preventing a Settings recording session
from editing the image behind it. Application bindings pass through to native menu handling;
old fixed template and Caption navigation shortcuts no longer bypass reassignment.

## Verification

Native inspection of a separately identified disposable QA app verified the scroll layout,
command selection and recording Shift-Command-9 into the Open Folder assignment. End-to-end
invocation was inconclusive before the final direct command-builder registration change.
Further native inspection is blocked by the automation backend error
`Sky Computer Use native pipe closed before response`, reproduced after reconnecting.
The production app and its media were excluded from this QA scope.

The final full regression passed 4,327 tests in 416 suites: 4,325 passed, two existing
skips and zero failures, in 144.000 seconds. This includes all four SwiftUI-hosted menu
invocation cases, profile migration/conflict persistence, event normalization and Develop
window ownership. Repository validation and whitespace checks passed.

Result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_17-40-07-+0200.xcresult`.
Existing MDB_MAP_FULL runtime diagnostics remain visible; the passing run does not establish
that those diagnostics or real-volume performance concerns are resolved.

## Remaining qualification

Final native invocation after live reassignment, broader keyboard-layout/accessibility testing,
real-volume browsing/export timing, peak-memory evidence and signed release checks remain
open. This continuation does not declare the application release-ready.
