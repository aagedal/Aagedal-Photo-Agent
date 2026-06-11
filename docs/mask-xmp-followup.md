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

## ISSUE 1 RESOLVED (2026-06-11): mask becomes "generic" after reopening edit view

Root cause (read-side, deterministic — no race): SwiftExif's `XMPReader` keys
structured-XMP fields as `<namespaceURI><Property>` (e.g.
`http://ns.adobe.com/camera-raw-settings/1.0/Top`) — its own
XMPNestedStructureTests assert this. `unwrapXMPStruct` (SwiftExifDictAdapter)
passes keys through verbatim, but `parseMaskGroupBasedCorrections` looked up
BARE names (`mask["Top"]`, `corr["CorrectionMasks"]`), so every read from disk
missed every field and silently fell back to the default 0.5/0.5/0.15/0.10
ellipse. First render after creating a mask uses in-memory state (correct);
any reload goes through the read path (generic). Also explains masks "losing"
their slider values on reopen (the `Local*` lookups missed too).

Fix (Services/IPTCMetadataParsing.swift):
- `crsMaskField(_:_:)` helper — accepts bare AND URI-prefixed keys, used for
  every correction/mask field lookup.
- Parser now DROPS (and logs, category `IPTCMetadataParsing`) corrections whose
  geometry fails to parse (unsupported mask type like Mask/Paint, missing
  corner) instead of substituting the default ellipse.

Tests: "mask corrections parse SwiftExif's namespace-URI-prefixed field keys" +
"corrections with unparseable mask geometry are dropped, not defaulted"
(IPTCMetadataTests.swift) and an end-to-end engine write→file→read roundtrip
"radial mask roundtrips geometry and local adjustments through write then read"
(MetadataEngineConcurrencyTests.swift). Full suite 240/240 green.

Note: dropped corrections (e.g. ACR brush masks) are now invisible in our UI
and will be REMOVED on our next mask write (applyMasks replaces the whole
array) — same data-loss semantics as before (they were previously mangled into
generic ellipses instead), but worth revisiting alongside open issue 4.

## Open issues 2–5 (queued)

2. **Mask slider persistence**: user set exposure+contrast on a mask; written XMP
   had all mask Local* = 0, exposure landed GLOBAL (Exposure2012), contrast
   nowhere. Re-test now that detection works AND issue 1 is fixed (the read-side
   key miss also wiped slider values on reload, which may have fed zeros back
   into the next write); if it still reproduces, trace mask-slider bindings
   (EditWorkspaceView ~2790) → MaskAdjustment → write.
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
