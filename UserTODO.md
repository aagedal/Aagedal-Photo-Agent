# Mask XMP Compatibility — Empirical Testing Needed

## Background

Adobe Camera Raw stores radial gradient mask geometry (Top/Left/Bottom/Right/Angle) in an undocumented encoding. For **Angle=0** our parsing works correctly (simple bounding box). For **Angle≠0** the encoding is fundamentally different — `Left` can be greater than `Right`, proving it's not a bounding box. No public documentation or open-source implementation exists.

Additionally, masks need an **orientation transform** (like crop already has) for images with EXIF orientation ≠ 1.

## Test Plan — Controlled ACR Experiments

All tests on a **landscape 3:2** image (e.g., 6000×4000). Use Feather=0 for clarity. Record the XMP values after each step.

### Test 1: Circle at various rotations
1. Create a radial gradient mask, keep it perfectly circular
2. Place it at roughly the center, note approximate pixel radius
3. Save with **Angle=0** → read XMP (Top/Left/Bottom/Right/Angle)
4. Rotate to **15°** → read XMP
5. Rotate to **30°** → read XMP
6. Rotate to **45°** → read XMP
7. Rotate to **60°** → read XMP
8. Rotate to **90°** → read XMP

### Test 2: 2:1 ellipse at various rotations
1. Create a radial gradient mask, stretch so one axis is **exactly 2× the other**
   (use ACR's pixel readout if available, or carefully match half-width to full-height)
2. Save at **Angle=0** → read XMP
3. Rotate to **30°** → read XMP
4. Rotate to **45°** → read XMP
5. Rotate to **-30°** → read XMP

### Test 3: Portrait image (Orientation=8)
1. Open a portrait/vertical RAW image (EXIF Orientation=8)
2. Create a circular mask at center → read XMP
3. Create a tall vertical ellipse → read XMP
4. Compare coordinates with the landscape tests

### Test 4: Square image (optional)
1. Crop a 3:2 image to 1:1 in ACR
2. Create a circular mask → read XMP
3. Rotate it → read XMP
4. This eliminates aspect ratio as a variable

## How to Read XMP Quickly

```bash
# Sidecar XMP (RAW files) is plain XML:
cat FILENAME.xmp | grep -A5 "CircularGradient"

# For embedded XMP, install exiftool from Homebrew (not bundled with the app)
# and run e.g. `exiftool -j -struct -XMP-crs:MaskGroupBasedCorrections FILENAME.JPG`.
```

## SOLVED (2026-06-11): the Angle≠0 encoding

Empirically reverse-engineered from Camera Raw 18.3.2 (rotation-only edits of a known
ellipse, plus synthetic probe files): **(Left,Top)/(Right,Bottom) are opposite corners
of the ellipse's ORIENTED bounding rect** — the corner half-diagonal is the corner
vector `(rx·aspect, ry)` rotated by Angle in aspect-corrected (pixel) space. That's why
Left can exceed Right (corner crosses the center) and why it's not a bounding box.
Decode = un-rotate the half-diagonal; both components must come out positive or the
mask is degenerate (ACR renders nothing). Both rotated ACR samples decoded to the
authored ellipse within 4 decimals. Full model documented on `EllipseMaskGeometry`.

## Known Issues to Fix

- [ ] **Orientation transform for masks** — masks need `transformedForDisplay(orientation:)` like crop does (`IPTCMetadataParsing.swift` → `parseMaskGroupBasedCorrections`)
- [x] **Rotated mask decoding** — geometry now stores ACR's signed corner half-extents; shaders/overlay decode the true semi-axes per the corner model (`EllipseMaskGeometry.trueRadii`)
- [x] **Rotated mask rendering** — all mask rotation now happens in aspect-corrected pixel space (edit shader, Metal overlay, AppKit overlay); UV-space rotation sheared by image aspect

## Files for Reference

- Existing test images: `/Users/traag222/Downloads/ftpTV2Sync/` (SKY08481, SKY07575, SKY07577, SKY07588)
- RAW test XMPs: `/Users/traag222/Downloads/20240404_SpellemannprisenRødLøper/` (TRA05888, TRA05897, TRA05910, TRA05915)
- Parsing code: `IPTCMetadataParsing.swift` → `parseMaskGroupBasedCorrections()`
- Shader code: `EditAdjustments.metal` → `editAdjustments` kernel
- Overlay code: `EllipseMaskOverlayView.swift`
