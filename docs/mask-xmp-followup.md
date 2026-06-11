# Mask XMP — handoff for follow-up (2026-06-11)

## Context: what is DONE and verified (don't redo)

The ACR radial-mask XMP encoding is fully reverse-engineered, implemented, and
empirically verified against Camera Raw 18.3.2. Full model documented on
`EllipseMaskGeometry` (Models/IPTCMetadata.swift); history in UserTODO.md.

- **Encoding**: crs Top/Left/Bottom/Right are opposite corners of the ellipse's
  ORIENTED bounding rect; the corner vector rotates with the ellipse in
  aspect-corrected (pixel) space. `radiusX/radiusY` in our geometry are the SIGNED
  box half-extents (Left can exceed Right in rotated masks). True semi-axes =
  un-rotate the corner vector (`EllipseMaskGeometry.trueRadii(aspect:)`).
- **Rendering**: rigid pixel-space rotation (verified by fitting an ACR export's
  darkened region: 129.4° measured vs 130.0° predicted). Implemented in
  EditAdjustments.metal, MaskOverlay.metal, MaskOverlayNSView (all decode the
  corner box per-pixel; degenerate = render nothing, matching ACR).
- **Angle range**: ACR only accepts Angle ∈ (−45°, 45°]; out-of-range renders
  nothing in ACR. Our overlay canonicalizes during rotation drag (axis swap per
  quarter turn). A live degree readout shows while rotating.
- **Reading ACR masks**: required a SwiftExif fix (rdf:Seq structured arrays +
  attribute-form rdf:li). Shipped as SwiftExif **1.9.2** (codeberg, tagged); app
  pin updated. Regression test uses the exact ACR 18.3.2 packet shape.
- **Writing for ACR/Bridge detection** (commit c750692): mask struct keys must be
  namespace-prefixed or SwiftExif drops them; `crs:AlreadyApplied` must be written
  EXPLICITLY `"False"` (absence = Bridge shows file as unedited); CompatibleVersion
  stamped. Verified: Bridge now badges our writes.
- Unit tests: "EllipseMaskGeometry ACR corner encoding" suite in
  IPTCMetadataTests.swift decodes real ACR sample values.

## Test assets

`~/Downloads/NorgeMarokko/MaskXMPTests/` — generated JPEGs with embedded mask XMP.
Generator scripts: `/tmp/gen_mask_xmp2.swift`, `/tmp/embed_variants.swift`
(template-substitution via CGImageMetadataCreateFromXMPData +
CGImageDestinationCopyImageSource, merge=false). Key fact: **ACR ignores .xmp
sidecars for JPEGs — only embedded XMP counts.** Inspect packets with:
`perl -0777 -ne 'print $1 if /(<x:xmpmeta.*?<\/x:xmpmeta>)/s' FILE.jpg`

## OPEN ISSUE 1 (priority): mask becomes "generic" after reopening edit view

Repro: create a mask in the edit view (renders correctly), close the edit view,
reopen → mask shows wrong aspect ratio. Working theory (user's, plausible): the
reload sometimes fails to parse the stored mask and silently falls back to default
geometry. Mechanism: in `parseMaskGroupBasedCorrections`
(Services/IPTCMetadataParsing.swift), `var geometry = EllipseMaskGeometry()`
(defaults 0.5/0.5/0.15/0.10) is only overwritten if the nested `CorrectionMasks`
parses AND `What == "Mask/CircularGradient"` — on failure the MaskAdjustment is
still appended with DEFAULT geometry, i.e. a generic ellipse.

Investigate:
1. Reproduce, then immediately dump the file's embedded XMP (perl above). If the
   stored geometry is correct but the app shows generic → read-side parse failure
   or a read/write race (the metadata write on close is async via
   `metadataWriteTask`; reopening quickly may read mid-write — same race family
   as the fixed orientation bug, see commit b5e3b02's message).
2. If parse failure: the two-pass write (CGImageDestination then SwiftExif) means
   ImageIO re-serializes the packet — real files contain Bag + attribute-form
   `<rdf:Description crs:.../>` inside li, nested CorrectionMasks Bag. Add a
   SwiftExif test with the exact shape from a real file, fix the reader (fork at
   ~/Developer/SwiftExif, tests in Tests/SwiftExifTests/XMP/).
3. Either way: make the parser DROP (and log) corrections whose mask geometry
   fails to parse instead of silently substituting defaults.

## Open issues 2–5 (queued)

2. **Mask slider persistence**: user set exposure+contrast on a mask; written XMP
   had all mask Local* = 0, exposure landed GLOBAL (Exposure2012), contrast
   nowhere. Re-test now that detection works; if it reproduces, trace mask-slider
   bindings (EditWorkspaceView ~2790) → MaskAdjustment → write.
3. **Sidecar write skips masks**: the app's .xmp sidecar contained no mask block
   and wasn't rewritten on the last save (mtime older than the JPEG). Check the
   dual-write path for develop settings.
4. **crs block replacement on write**: ACR, when editing a previously-exported
   JPEG, ZEROES the baked globals (Texture, vignette, HSL…) rather than keeping
   them. Our writer currently preserves them, so with AlreadyApplied=False ACR
   re-applies them → ACR preview slightly more processed than ours. Adobe-faithful
   fix: replace the whole crs namespace with our live state on write. Needs a
   namespace-wide removal API in the SwiftExif fork (then tag 1.9.3, bump pin).
5. **EXIF-orientation transform for masks** (UserTODO.md): masks need
   `transformedForDisplay(orientation:)` like crop has, for images with
   orientation ≠ 1.

## Memory

`mask-xmp-acr-compat.md` in the project memory mirrors this state — update both
as issues close.
