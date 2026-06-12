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
4. **RESOLVED (2026-06-12): crs block replacement on write**. SwiftExif 1.9.3
   shipped `removeAll(namespace:)` / `replaceAll(namespace:from:)` /
   `properties(in:)`; app pin bumped to 1.9.3. `StructuredWriteData` gained
   `replaceCameraRawBlock` — when true (the three full develop saves in
   MetadataViewModel + the develop reset in BrowserViewModel), the engine
   removes the entire crs namespace before applying live state, then stamps
   AlreadyApplied="False" + CompatibleVersion whenever the new block carries
   settings (masks or not). Partial crs writes (develop-settings paste in
   EditWorkspaceView) stay merge-style, and a replacement write carrying no
   crs content at all (caption-only save of a file with an unmodeled crs
   block) skips the wipe. `copyMetadataToRenderedFile` now drops the whole
   crs namespace on rendered exports instead of the hardcoded property list
   (which leaked unlisted props like Texture/HSL into exports). Covered by
   "full develop save replaces the crs block; partial writes preserve
   unmanaged settings" in MetadataEngineConcurrencyTests.
   NOTE for manual verification: a develop save from our app now intentionally
   drops ACR-only settings (Texture, vignette, HSL, brush masks…) from the
   file — Adobe-faithful, but worth seeing once on a real ACR-edited JPEG.
   FOLLOW-UP FIXES from manual testing (2026-06-12 evening):
   - Caption-only saves were wiping ACR develop settings (every metadata save
     wrote the full crs field set, which with the replace flag nuked the
     block). All three MetadataViewModel save sites now gate on
     `developSettingsChanged(edited, baseline)` (render-time-only fields
     ignored) and skip crs fields + structuredData entirely when develop
     state is unchanged; the batch pending-writes path gates on the sidecar
     carrying cameraRaw at all (no per-file baseline exists there).
   - Develop-settings paste (Cmd+C/V in edit view) dropped masks, tone curve,
     HSL and vibrance. Single-image paste now carries all of them (masks get
     fresh UUIDs); paste-to-multiple writes toneCurve+masks via structuredData
     — masks only when the source HAS masks, merge-style (no replace flag), so
     pasting from a mask-less source can't strip targets' masks.
5. **EXIF-orientation transform for masks** (UserTODO.md): masks need
   `transformedForDisplay(orientation:)` like crop has, for images with
   orientation ≠ 1.

6. **RESOLVED (2026-06-12 late evening): angled-crop XMP encoding converted to
   Adobe's at the boundary.** `CameraRawCrop.encodedForACR(aspect:)` /
   `decodedFromACR(aspect:)` (Models/IPTCMetadata.swift) rotate the corner
   diagonal by ±CropAngle in pixel-proportional space about the shared center
   (the corner midpoint is the crop center in BOTH conventions, so only the
   diagonal rotates; identity at angle 0 and when aspect is unknown). Decode of
   the repro values reproduces ACR's rendered aspect 0.94973 to 4 decimals.
   Boundary sites wired: iptcMetadataFromDict + BrowserViewModel cropRegion/
   cameraRawSettings (aspect from the dict's EXIF ImageWidth/Height;
   SwiftExifReadService.readDict back-fills dims from the container header when
   EXIF lacks them and an angled crop is present), XMPSidecarService read+write
   (lazy header read via new Services/ImagePixelAspect.swift, only for angled
   crops), MetadataViewModel appendCameraRawFields/overwriteFields (aspect
   closure from the save's imageURL), EditWorkspaceView pasteToMultipleImages
   (targets grouped by pixel aspect; per-group encode). JSON .photo_metadata
   sidecars stay app-convention (Codable) as planned. Migration: pre-fix files
   carry app-convention crs values — angled crops from old saves will read
   slightly differently now (accepted; straight crops unaffected).
   BONUS FIX: overwriteFields' `includeCameraRaw:` parameter from d054f90 was
   declared but never applied — caption-only saves still rewrote the modeled
   crs fields merge-style. The gate is now real (crs fields skipped entirely
   when develop state is unchanged).
   Tests: "CameraRawCrop ACR boundary conversion" suite (IPTCMetadataTests) —
   repro-file decode, encode/decode inverses across angles/aspects, identity
   cases, bounds-fitted encode stays in [0,1], dict parse with/without dims —
   plus "XMP sidecar angled-crop ACR conversion (real file)" end-to-end
   roundtrip (MetadataEngineConcurrencyTests.swift). 250/250 green.
   NOT yet manually verified in ACR: write an angled crop in our app and
   confirm Camera Raw 18.3.2 renders it identically (and vice versa).
   Original diagnosis below for reference.
   Repro: `~/Downloads/20260610_RødLøper/Tise Awards 16.jpg`
   (7008×4672, CropAngle −12.786738): our app renders its crop as 5335×3556
   (aspect 1.5), ACR 18.3.2 renders 3743×3941 (aspect 0.9498).
   - **Adobe's model — SAME CORNER MODEL AS THE MASKS**: stored
     CropLeft/Top/Right/Bottom are the crop rect's two opposite corners in the
     UN-ROTATED original frame (normalized by original W/H, image-centered when
     converted to px). Rotate both corners about the IMAGE CENTER by CropAngle
     → the actual axis-aligned crop rect in the straightened canvas. Decoded
     this way, the stored values give 4415×4649 (aspect 0.94973) — ACR's render
     matches that aspect to 4 decimals.
   - Authority: darktable `src/develop/lightroom.c` (LR-XMP import) decodes
     exactly this (image-centered px → rotate_xy both corners by the angle →
     normalize by the rotated-AABB canvas). Validated against the repro file.
   - The 4415→3743 difference is ACR **auto-shrinking an invalid crop**
     (uniform 0.8477 both axes, aspect preserved): under Adobe's reading our
     values poke outside the valid rotated pixels. Authentic Adobe crops are
     always inside, so this is a tell that OUR writer produced the values.
   - Our app writes its INTERNAL "upright actual rect" (see
     crop-rotation-representation memory — that representation was chosen to
     fix in-app drag drift and is fine INTERNALLY) verbatim into the crs
     fields, and parses them the same way. Conventions coincide ONLY at
     angle = 0, which is why straight crops round-trip fine.
   - **Fix plan**: convert at the XMP boundary only (keep the internal
     representation): write = rotate the upright rect's corners from the
     straightened canvas back into the original frame (inverse of darktable's
     decode), read = the forward decode. Needs image dims (aspect) at the
     boundary — mirror how `EllipseMaskGeometry.trueRadii(aspect:)` handles
     the same problem for masks. Touch points: parseMaskGroupBasedCorrections'
     sibling crop parse in iptcMetadataFromDict, MetadataViewModel
     appendCameraRawFields, EditWorkspaceView pasteToMultipleImages,
     XMPSidecarService. JSON .photo_metadata sidecars keep the app convention
     (Codable, internal). Migration caveat: previously-written files carry
     app-convention values in crs fields — indistinguishable from Adobe ones;
     accept the breakage for angled crops or detect via our Version "15.4".

## Memory

`mask-xmp-acr-compat.md` in the project memory mirrors this state — update both
as issues close.
