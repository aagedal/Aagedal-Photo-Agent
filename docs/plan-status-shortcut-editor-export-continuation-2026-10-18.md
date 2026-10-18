# Shortcut editor and export metadata continuation — 2026-10-18

This continuation follows the 3.0 priority of reliable core workflows and a compact main UI.
It does not close the release performance or packaging gates.

## Changes

Settings → Shortcuts now includes a logical keyboard preview with modifier layers,
assigned/free/reserved states, tooltips and accessible descriptions. Rating and label
commands open a dedicated editor with local key recording, alternate bindings, individual
removal and confirmed reassignment. Unsupported chords remain reserved for workspace/system
commands. Preset selection, custom bindings and restore defaults persist through the existing
registry. Caption advance assignments remain separate; other commands remain a searchable
reference rather than offering unimplemented remapping. Search now matches individual
rating/label command names and their assigned chords.

Native Rating & Label menu equivalents observe the selected profile instead of silently
retaining fixed Command-number label mappings. Default Photo Agent Command+0–8 label
shortcuts are explicit profile aliases, so the preview includes their actual occupancy.
Bare culling keys remain with the focus-aware workspace router. Ambiguous chords receive
no menu equivalent. Older custom profiles retain their explicit saved bindings; Command-number
aliases can be added in the editor.

Rendered export now selects pending app JSON metadata before an older physical XMP sidecar,
matching the effective metadata shown in the editor. Existing partial-record safeguards and
structured metadata handling remain intact. Real JPEG regressions cover both replacement
and explicit clearing of editorial metadata, read back the exported file and check that
source/XMP bytes and the pending draft remain unchanged. No write verification was removed.

## Verification

The initial integrated focused run passed 48 tests in three suites. The full regression
run completed 4,313 tests in 412 suites (4,311 passed, two existing skips, zero failures),
including the profile/menu regressions, in 149.440 seconds. Repository validation and
whitespace checks passed. The full run preceded the final UI-only sheet-selection correction;
the final focused run passed all 51 tests in four suites, with no skips or failures.
Repository validation passed again against the final implementation.

Result bundles:

- Full: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_16-28-47-+0200.xcresult`
- Final focused: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.18_16-32-02-+0200.xcresult`

Native UI inspection used a temporary, separately identified, ad-hoc-signed QA copy so the
existing application and its preferences could remain open. Keyboard states and tooltips,
alternate bindings and Command+2 capture into an explicit reassignment alert were inspected.
The alert was cancelled without changing the profile. Inspection exposed a stale selected-key
capture in the sheet; command and suggested chord now travel together in one sheet item.
The final QA build confirmed selecting the free Command+9 key presents “Assign ⌘9 to
Clear rating” in the sheet. The temporary QA process was closed after verification.

Reviewed ignored model and web-download runtime assets were copied from the main checkout
for the development build. They are not tracked changes. Existing MDB_MAP_FULL runtime
messages remain visible in test logs; successful tests do not establish that diagnostic is fixed.

## Remaining qualification

Arbitrary workspace-command remapping, a physical locale-specific keyboard rendering,
real local/network/iCloud volume timing, Instruments and peak-memory evidence, complete
VoiceOver/display testing and signed release qualification remain open. No end-to-end
speedup is claimed by this correctness/editor continuation.
