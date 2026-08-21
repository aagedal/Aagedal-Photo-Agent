# Accessibility and keyboard audit — 2026-08-21

The Browser, Caption Workspace, Batch Rename, Metadata Tools, Comparison, Clean Feed, Develop,
Analysis, Deadline Workspace, and Activity now expose stable automation identifiers and improved
accessibility semantics. Image cells/previews, filmstrips, result and receipt rows, toolbar actions,
sliders, filters, and icon-only controls have explicit labels or combined semantics. Metadata
rating stars and color-label dots are real keyboard-operable buttons rather than gesture-only
graphics. Caption and Activity use adaptive minimum/ideal sizing instead of fixed toolbar heights
or a single rigid detail width.

A persisted culling-shortcut registry provides Photo Agent, Photo Mechanic-like, Bridge-like, and
Custom profiles for all fifteen rating/color-label commands. Settings expose every command through
a bounded assignment picker plus an explicit Unassigned state. Same-chord conflicts are grouped
deterministically, ambiguous chords do nothing until remediated, and the UI can resolve conflicts.
The finite chord set excludes known fixed menu/tool conflicts. Browser, Comparison, Develop, and
Full Screen share one router that suppresses these keys while a text editor or IME owns input and
also ignores key-repeat events. Previously conflicting global bare and Command-W actions were moved
to scoped Control-Option or Option chords.

The isolated accessibility suite now passes eleven tests, including source audits for the accurately
named accessibility-description control and the structured contact/location editor. The six
adjacent workspace/interaction suites passed 83 tests, for 94 tests with no failures. Swift parsing
and `git diff --check` passed.

This is the automatable audit, not a manual accessibility certification. The culling registry is
deliberately limited to fifteen commands, while Caption owns a separate two-command registry;
broader app/menu/Develop-tool commands remain fixed and documented. VoiceOver rotor/order and announcements, Full Keyboard Access focus rings,
live IME composition, accessibility text-size/localization truncation, high contrast/reduce motion,
window extremes, and external-display Clean Feed still require manual observation.

Caption Workspace additionally has a deterministic circular logical Tab/Shift-Tab order from
profile priority fields through its action bar, skipping unavailable actions and yielding while an
IME or transient editor owns input. Escape closes autocomplete, code-replacement, and template
transients and explicitly requests the prior Caption field where app-owned dismissal permits it.
Successful Save & Next and Write & Next post fixed, privacy-safe accessibility announcements with
no filename, path, or editorial value. The expanded Caption speed/session/accessibility selector
passed 31 logical tests with no failure and a warning-free incremental build. Native menu focus,
responder timing, and actual announcement speech/coalescing remain OS/manual observations.
