# Production delivery staging validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 live render, metadata, verification, preservation, and capacity adapters

## Implemented contract

- `DeliveryStagingProductionFactory` is the single construction boundary for the live staging
  coordinator. It validates the frozen plan and passes frozen export and Develop settings directly
  to `EditedImageRenderer`; mutable export defaults cannot change a confirmed delivery.
- Current production execution is staged-copy only and never writes an original. Scratch renders
  must remain inside the unique batch directory, output must not preexist, and the source revision
  is checked before staging and again after rendering/metadata copy.
- SwiftExif copies source metadata to the rendered artifact while retaining the renderer-authored
  destination ICC profile, then writes the exact resolved descriptive/structured metadata. The
  actual staged bytes are parsed for full controlled-field and unrelated-metadata verification.
- Output carrier, bit depth, actual pixel dimensions, HDR mode, and ICC gamut must match the frozen
  contract before `DeliveryRenderSettings` is evidence. Missing or substituted profiles fail.
- A renderer-aware conservative byte estimate uses frozen source dimensions, resolution limit,
  HDR depth, and source metadata allowance; capacity refusal occurs before rendering.
- Deadline preflight and runtime admission share `DeliveryStagingProductionCapabilities`, including
  supported write strategies, formats, and gamuts.

## Test evidence

An isolated production-target build succeeded. `DeliveryStagingProductionFactoryTests` passed
**6 tests**. Adjacent metadata-preservation, descriptive rendered-write, and export-pipeline suites
passed **25 tests**, zero failures. Coverage includes a real JPEG staged write/read-back,
unrelated-metadata evidence, frozen-config immunity to mutable defaults, actual dimensions/ICC,
source mutation refusal, capacity refusal before render, cancellation retention, and unsupported
strategy/carrier/gamut rejection. PBX parsing and `git diff --check` passed.

## Explicit support boundary

- Supported now: staged copies; SDR JPEG/TIFF; HDR gain-map JPEG/16-bit TIFF; SDR sRGB, Display P3,
  Rec. 2020, and Adobe RGB; HDR sRGB, Display P3, and Rec. 2020.
- Refused now: originals, XMP-only delivery, PNG/HEIC/AVIF/JPEG XL carriers, HDR Adobe RGB
  substitution, missing/mismatched ICC evidence, and guessed exact-copy delivery.
- Exact copy needs a future frozen render-vs-copy discriminator; matching file extensions are not
  enough to ignore frozen quality, gamut, resolution, or Develop settings.
