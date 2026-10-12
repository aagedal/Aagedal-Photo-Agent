# Text watermark creator verification — 2026-10-12

Settings → Watermarks now has **Create Text…** beside PNG import. The creator supports
multiline text, System/Serif/Monospaced fonts, pixel font size, bold/italic, RGBA color,
and a debounced preview over a dark transparency checkerboard. Creating selects the
saved library asset. Text is rasterized to an immutable transparent PNG and uses the
existing watermark placement and export pipeline.

CoreText layout, bitmap drawing, PNG encoding and private temporary-file I/O run on a
serial actor executor. Rendering validates text, font/color inputs and 4,096-pixel
canvas bounds before bitmap allocation. Per-line fallback-font metrics and glyph
bounds preserve Unicode overhangs. Creation retains the original storage generation
and uses the existing library commit boundary; temporary PNGs are cleaned up, and a
durable commit remains authoritative if cancellation arrives afterwards.

## Validation

- Xcode focused tests: **20 passed**, zero failures/skips. Covers renderer transparency,
  visible glyphs, multiline Unicode, invalid inputs, bounds, durable reload, temporary
  cleanup, pre-cancellation, existing store behavior and the gated disposable test root.
- Native macOS UI smoke: **1 passed**, zero failures. Exercises disabled empty Create,
  text entry, live preview, named creation, sheet closure and durable PNG/metadata.
  A gated disposable watermark library prevents writes to the user's library.
- Repository validation, final model-bundle validation and strict deep development
  signature verification passed. `git diff --check` passed.

Evidence is under `build/text-watermarks-2026-10-12/` (focused/native result bundles,
summaries and validation logs). The build uses `build/continuation-12` derived data.
The complete test suite was not rerun for this scoped feature; the previous continuation
completed it before this change.

The saved PNG has no editable text recipe. Create a new asset to revise the text/style.
Microsoft Project Provenance emblems are not bundled by this change.
