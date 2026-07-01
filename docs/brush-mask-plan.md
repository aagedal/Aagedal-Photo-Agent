# Brush mask layer (freeform paint mask)

## Progress

Implement one phase at a time (see Sequencing below), each in its own session/thread.

- [x] Phase 1 — Model + XMP (read/write additive `Dabs`, preserve-unparseable-correction fallback) — **done 2026-07-01**. `BrushDab`/`BrushStroke`/`BrushMaskGeometry` + `MaskAdjustment.brush` + `.brushMask` LayerKind in IPTCMetadata.swift; `parseMaskGroupBasedCorrections` now returns `ParsedMaskCorrections{masks, preserved}` (brush parse via `parseBrushGeometry`/`parseDabs`; unmodeled corrections kept verbatim as `PreservedMaskCorrection`/`PreservedXMPNode` in `CameraRawSettings.unparsedMaskCorrections`); encode via `ACRMaskNode` tree + `encodeBrushCorrectionMasks`/`encodeDabs`; writer threads preserved through `XMPDataBuilder.applyMasks`/`applyLayerChain` (sidecar) and `StructuredWriteData.unparsedMaskCorrections` → `SwiftExifWriteEngine` + the two `MetadataViewModel` develop-save sites (embedded). Brush masks filtered out of `MetalEditPipeline` render until Phase 2/3 (no misrender as placeholder ellipse). 6 new tests in `BrushMaskTests` (parse/dabs/encode/preserve/sidecar round-trip) all green; existing ellipse/anonymizer/layer suites still green. Verified SwiftExif 1.9.9 (the resolved dep, not just the local fork) round-trips the deep nesting. **Fork fidelity fix shipped 2026-07-01 (user-approved):** added `"Masks"` to `XMPWriter.seqProperties` in the SwiftExif fork so the nested `crs:Masks` container emits as `rdf:Seq` (matching ACR) instead of `rdf:Bag`, with a regression test (`testACRBrushMaskNestedSeqContainersRewritten`). Released as **SwiftExif 1.9.10** (committed 752d185, tagged + pushed to codeberg); the app's `project.pbxproj` dependency + `Package.resolved` are bumped to 1.9.10 and all brush tests pass against it. So `crs:Masks` now writes as Seq in the app.
- [x] Phase 2 — Metal: lazy alpha texture array + `stampBrush` rasterization kernel — **done 2026-07-01**. Two new kernels in `EditAdjustments.metal`: `stampBrush` (rasterizes one dab into an R16Float `texture2d_array` slice, bounded to the dab's bbox via `originPx` grid origin; soft circular profile where `hardness`=CenterWeight is the full-coverage inner fraction; `max()` blend for additive, subtract for erase; `coverage = min(falloff·flow, density)`) and `clearBrushAlpha` (zeros all slices before a rebuild). CPU side in `MetalEditPipeline`: `BrushDabParams` struct (40-byte layout matching Metal), optional `stampBrush`/`clearBrushAlpha` pipeline states (graceful degradation like the overlay pipeline), lazily-(re)allocated `brushAlphaTexture` (`.type2DArray`, one slice per brush mask, nil when none — zero GPU cost for non-brush edits), and `rebuildBrushAlpha(_:size:)` which clears + stamps every stroke's dabs in ONE serial-dispatch command buffer (serial dispatch is what makes read_write accumulation across overlapping dabs race-free) and `waitUntilCompleted`. Radius→pixels via `brushRadiusPixels(normalized:size:)` = `radius · longEdge` (long-edge normalization, self-consistent with `anonymizerBlockSize`; absolute scale is a Phase 6 calibration constant). Dabs uploaded per-dispatch via `setBytes` (not a shared buffer) to avoid parameter aliasing. **Not yet wired into `editAdjustments` compositing — that's Phase 3;** this is inert infrastructure. 4 new GPU tests in `BrushRasterizationTests` (centered-dab coverage, empty-frees-texture, erase-subtracts, independent-slices-per-mask) verified against hardcoded stroke lists on the real GPU; skip cleanly when no Metal device. Existing brush XMP suite still green.
- [ ] Phase 3 — Compositing kernel: `maskType` branch in `editAdjustments`
- [ ] Phase 4 — UI: bare-`B` paint tool, `BrushMaskOverlayNSView`, brush settings toolbar
- [ ] Phase 5 — Undo, layer-strip icon, paste-to-other-images plumbing
- [ ] Phase 6 — Calibration pass against real ACR sample files (see below)

Real-world sample files used to reverse-engineer the format (all in `~/Pictures/TestImages/`, not in this repo — reference by absolute path):
- `Vixen 2026 05.jpg` — single additive stroke, readable `Dabs` format
- `Nepobaby sesong 2 01.jpg` — two additive strokes, different brush settings (small corner dab + softer larger stroke), readable `Dabs` format
- `NTB_oOD3jlPaJbo.jpg` — soft stroke over a person + 16 near-duplicate harder-edge clicks in one spot, readable `Dabs` format, confirms `CenterWeight` = hardness
- `NTB_HsALq2LsjH8.jpg` — a circle split by an eraser drag through the middle, opaque `MaskBrushTable` encoding (not decodable)

## Context

Masks today are purely analytic ellipses (`EllipseMaskGeometry`: center/radii/rotation/feather, sampled via an SDF in the Metal shader). That's fine for vignettes and radial dodging, but many real edits — a face, a hand, a stray limb crossing into an anonymizer region — aren't ellipse-shaped. This plan adds a second mask *kind*, a freeform paint mask, that plugs into the existing `MaskAdjustment` struct so every adjustment already built (exposure, contrast, Anonymizer, Temperature/Tint) works on brush masks automatically, with zero duplicated adjustment code.

**This plan was revised after inspecting four real ACR/Lightroom-authored brush-mask files** (see above) — the original assumption that `Mask/Paint` is an undocumented opaque blob was wrong for the common case, which changes both the scope and the risk profile of ACR compatibility.

## Real-world XMP format (reverse-engineered from 4 sample files)

Four files inspected, all edited with Camera Raw 18.4 per `HistorySoftwareAgent` (the `Software`/`CreatorTool` tags reflect whichever tool originally produced the JPEG, not necessarily the mask edit, and are not a reliable signal — confirmed by the user).

**Additive-only brush masks (3 of 4 files) use a readable, parseable XML structure**, one level deeper than today's flat `crs:CorrectionMasks` shape:

```xml
<crs:CorrectionMasks><rdf:Seq><rdf:li>
  <rdf:Description crs:What="Mask/Aggregate" crs:MaskName="Brush 1" crs:MaskValue="1" ...>
    <crs:Masks><rdf:Seq>
      <rdf:li><rdf:Description crs:What="Mask/Paint" crs:MaskValue="0.674528"
                crs:Radius="0.326681" crs:Flow="0.561039" crs:CenterWeight="0.195981">
        <crs:Dabs><rdf:Seq>
          <rdf:li>f 0.5610</rdf:li>        <!-- sets flow for subsequent dabs -->
          <rdf:li>h 0.1960</rdf:li>        <!-- sets hardness/center-weight (omitted when 0) -->
          <rdf:li>d 0.119346 0.855057</rdf:li>   <!-- a dab: normalized UV, can slightly exceed [0,1] at edges -->
          <rdf:li>d 0.069446 0.918315</rdf:li>
          ...
        </rdf:Seq></crs:Dabs>
      </rdf:Description></rdf:li>
      <!-- a "Brush 1" mask can contain MANY Mask/Paint sub-masks, one per mouse-down/up
           gesture or per repeated click — one file had 17 sub-masks under one Aggregate.
           They union together (add) to form the final mask. A NEW sub-mask starts when
           Radius changes; Flow/CenterWeight can change inline via f/h records within one
           sub-mask. -->
    </rdf:Seq></crs:Masks>
  </rdf:Description>
</rdf:li></rdf:Seq></crs:CorrectionMasks>
```

Confirmed field mapping: `CenterWeight` = hardness (0.196 on a user-described "soft" stroke, 0.619 on a "harder edge" stroke — monotonic, confirmed). `MaskValue` on the `Mask/Paint` sub-mask is constant across many clicks in the same session (0.674528 repeated 16 times) — most likely ACR's "Density" ceiling (a brush-tool-level cap on max accumulated opacity), not a per-stamp value; **unconfirmed, flag for calibration**. `crs:Radius`'s normalization reference (image width? height? long edge?) is also **unconfirmed** — inferred relative sizes are self-consistent across samples but the absolute scale needs a side-by-side comparison against Lightroom's own brush-size display, which nobody has done yet.

**The 4th file (an eraser stroke splitting a circle in two) uses a different, opaque encoding**:
```xml
<rdf:li crs:What="Mask/Aggregate" crs:MaskName="Brush 1" crs:MaskValue="1"
        crs:MaskBrushTable="9F8737DEECAFF5C8FE6BB4B9D438EAF2"
        crs:MaskBrushUncompressedBytes="13258"/>
```
No nested `crs:Masks`/`Dabs` at all — `MaskBrushTable` is a 32-hex-char value, far too short to hold 13KB of data inline, and no matching binary payload exists elsewhere in this file (checked via `exiftool -a -G1`). This is a reference/hash into a rasterized-and-compressed representation, not a text description — likely because once an erase operation exists, ACR needs to track actual accumulated per-pixel coverage rather than a flat additive dab list, and switches to a rasterized internal representation for that. **This is the corrected theory** (superseding an earlier, wrong hypothesis that the split was about which app — Camera Raw vs. Lightroom Classic — authored the file; the user confirmed all four files were edited with the same ACR version, which rules that out and points at erase specifically as the trigger).

**Conclusion**: additive-only brush masks are genuinely readable and — with care — writable in ACR's own format. Masks involving erase are not decodable from the file at all, by any tool other than Adobe's own engine, regardless of how much reverse-engineering effort goes in.

## Decision this makes for scope

- **Read**: parse the real `Mask/Aggregate` → `crs:Masks` → `Mask/Paint` → `Dabs` structure (additive case). When a mask correction can't be parsed — `MaskBrushTable` present, or anything else unrecognized — **do not drop it**. Preserve its raw field/value data verbatim and never let a develop save wipe it, even though this app can't render or edit it. This is the actual fix for the real data-loss risk this investigation surfaced: today, any unparseable mask (this includes every real Lightroom Classic erase-brush edit) is silently dropped, and a subsequent full develop save (`replaceCameraRawBlock`, an existing and intentional Adobe-faithful behavior) permanently deletes it from the file. That's a correctness bug independent of this feature and worth fixing regardless of brush-mask work, but this plan is what surfaced it.
- **Write, from our own paint tool**: additive-only brush masks get written in the real ACR `Mask/Paint`/`Dabs` shape — genuinely interoperable with Camera Raw/Bridge/Photoshop (untested against Lightroom Classic specifically, since we now know its read path for this data is unclear). Masks that include an erase stroke fall back to an app-private `aaphoto:BrushStamps` field (same pattern as the Anonymizer) and simply don't populate the `crs:` mask structure — so they're invisible-but-harmless in Lightroom/ACR (same category of caveat as the Anonymizer) rather than being rendered wrong.

## Data model

```swift
nonisolated struct BrushDab: Codable, Sendable, Equatable {
    var x: Double         // normalized UV [0,1] — matches ACR's Dabs convention, can slightly exceed [0,1] at frame edges
    var y: Double
    var flow: Double      // 0-1, set by the most recent "f" record in ACR terms
    var hardness: Double  // 0-1, set by the most recent "h" record (CenterWeight)
}

nonisolated struct BrushStroke: Codable, Sendable, Equatable {
    var dabs: [BrushDab]
    var radius: Double    // normalized, constant per stroke (matches one ACR Mask/Paint sub-mask)
    var density: Double   // 0-1 opacity ceiling (ACR's per-submask MaskValue) — best-effort mapping, needs calibration
    var erase: Bool       // true = subtract this stroke from the accumulated mask
}

nonisolated struct BrushMaskGeometry: Codable, Sendable, Equatable {
    var strokes: [BrushStroke]   // one entry per mouse-down/up gesture, mirrors ACR's own Mask/Paint granularity
    var isEmpty: Bool { strokes.isEmpty }
}
```

This shape is a deliberate near-mirror of ACR's own structure (stroke = one `Mask/Paint` sub-mask, dab = one `d` record with its own flow/hardness) rather than a simplified reinvention — that's what makes the additive case genuinely round-trippable through the real `crs:` fields instead of just app-private ones.

`MaskAdjustment` (IPTCMetadata.swift:277) gets one new sibling field, matching how `anonymizer` was added: `var brush: BrushMaskGeometry?` (nil = ellipse mask; existing `geometry: EllipseMaskGeometry` field stays and is simply unused for brush masks — touching every call site that reads `mask.geometry` to make it a true polymorphic sum type is a much bigger refactor for no real benefit here).

`MaskAdjustment.layerKind` becomes `brush != nil ? .brushMask : .ellipseMask`; add `.brushMask` to `LayerKind` (IPTCMetadata.swift:324) with SF Symbol `"paintbrush.pointed"`. Confirmed via grep: `LayerKind`'s `systemImage` switch (line 332) is the ONLY exhaustive switch on this enum — no other call site breaks.

**Also generalize the "preserve unrecognized correction" mechanism beyond brush**: today `parseMaskGroupBasedCorrections` (IPTCMetadataParsing.swift:200) drops any correction whose `CorrectionMasks[0].What` isn't `Mask/CircularGradient`. Add a case that keeps the correction's raw dict alongside the drop-reason, and thread it through so a save that doesn't touch masks re-emits it byte-for-byte instead of it vanishing on the next `replaceCameraRawBlock` wipe. This generalizes to any future Adobe mask type we don't understand, not just brush/`MaskBrushTable`.

## Metal rendering architecture

**Alpha texture per brush mask**: `texture2d_array<half>` kernel argument, R16Float, allocated lazily (only for masks that are actually brush type, not all 8 slots unconditionally — an unconditional 8-layer array at export resolution would be ~1-1.5GB).

**Rasterization** (`stampBrush`, new function in `EditAdjustments.metal`): given one `BrushDab` (position/radius/hardness/flow) and the target texture's pixel dimensions, dispatch a kernel bounded to just that dab's bounding box, writing a soft circular falloff — `max()` blend for normal strokes, subtractive for `erase` strokes. Same incremental-write shape as the existing LUT `MTLTexture.replace(region:)` pattern (MetalEditPipeline.swift) — cheap, bounded, not a full-texture rebuild per dab.

**Two population paths**: (1) live painting stamps directly into the current alpha texture as the user drags (batched per display tick, not per raw mouse event); (2) full rebuild from `strokes: [BrushStroke]` for anything that doesn't already reflect the model — image load, undo/redo, switching between live-preview and export resolution. This is what makes the format resolution-independent: normalized UV / long-edge-fraction coordinates rebuild correctly into a 1500px preview texture or a 9000px export texture from the same stroke list.

**Compositing kernel**: `MaskParams` gets `uint maskType` (0 = ellipse, 1 = brush); the per-mask branch in `editAdjustments`'s order-buffer loop picks `maskWeight()` (SDF) or a texture-array sample based on this flag. `applyMaskColor` is completely unchanged — every adjustment already built keeps working on brush masks with no new code, because it only ever sees a resolved `weight` + `rgb`.

## UI / interaction

Genuinely new territory (unlike Temp/Tint, which only added sliders): ellipse masks are edited via discrete draggable handles (`MaskOverlayNSView`); a brush needs continuous mouse-drag interpreted as paint. The closest existing precedent for a persistent "tool mode" is `showCropControls` (EditWorkspaceView.swift:47), toggled by bare `C`.

Bare `B` (confirmed free) toggles `@State private var isBrushPainting: Bool`, following that precedent — deselects/hides other overlays on entry, shows a brush-size cursor (plain SwiftUI circle, no Metal needed for the cursor itself). New `BrushMaskOverlayNSView` (parallel to `MaskOverlayNSView`) captures `mouseDown`/`mouseDragged`/`mouseUp` as a paint gesture: live-stamps into the GPU alpha texture per drag sample (spacing-filtered to ~25% of brush diameter, to avoid thousands of redundant dabs from a slow drag) for immediate feedback, and on `mouseUp` appends the whole gesture as **one** `BrushStroke` via a single `updateCameraRaw` call — matching the exact one-undo-entry-per-gesture granularity ellipse dragging already gives (EditWorkspaceView.swift:2268).

Brush tool settings (size, hardness, flow, add/erase) are transient UI state describing what's about to be painted, not per-mask XMP fields — already-painted strokes keep whatever settings they were painted with, matching every reference app's convention.

## Sequencing

1. Model + XMP: `BrushDab`/`BrushStroke`/`BrushMaskGeometry`, real `Mask/Aggregate`/`Mask/Paint`/`Dabs` parse (additive case) and encode, generalized "preserve unrecognized correction verbatim" fallback, `layerKind` case. Testable in isolation with the real sample files as fixtures before any rendering exists.
2. Metal: lazy alpha texture array, `stampBrush` kernel, full-rebuild-from-strokes function — verify against a hardcoded stroke list first.
3. Compositing kernel: `maskType` branch; confirm exposure/Anonymizer/Temp-Tint render correctly on a brush-shaped mask.
4. UI: bare-`B` tool mode, `BrushMaskOverlayNSView`, brush settings toolbar, live-stamp-while-dragging.
5. Undo, layer-strip icon, paste-to-other-images (mirrors existing mask-array handling, no special-casing needed).
6. **Calibration pass**: with real painting available, compare a painted brush against the four real sample files' `Radius`/`MaskValue` values to nail down what they're normalized against — flagged throughout as the two genuinely unconfirmed constants.

## Verification

- Unit tests using the four real sample files (or fixtures extracted from them) as regression anchors — same approach as the Anonymizer/Temp-Tint round-trip tests anchored to a real ACR file this session.
- Confirm an unparseable mask correction (simulate a `MaskBrushTable`-bearing correction) survives a save/reload cycle byte-for-byte instead of vanishing.
- Manual: paint a stroke, confirm one undo entry undoes it; confirm exposure/Anonymizer/Temp-Tint sliders render on a brush mask; export and confirm the mask holds at export resolution; reload the sidecar; if possible, open an app-painted additive-only brush mask in an actual Camera Raw/Bridge install to confirm real interop (can't be verified in this session — flag as a manual check for the user).
