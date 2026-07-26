# TODO

## Priority

- [x] **Avoid ImageIO QoS priority inversion during embedded RAW preview extraction.**
  (2026-07-21) `FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation`
  now confines synchronous ImageIO extraction to an enforced default-QoS dispatch work
  item and resumes foreground callers through a checked continuation. The edit preview,
  Clean Feed fallback, and full-screen RAW preview all use the async boundary. A focused
  `.userInitiated` regression test passes with Thread Performance Checker enabled.

## Planned layer types

- [x] **Secondary global layers.** Add reorderable full-frame adjustment layers while
  retaining the primary Global layer as the XMP-compatible base adjustment block.
- [x] **LUT / Color Space Transform layers.** Add reorderable LUT and CST nodes, including
  persistence, import/validation, GPU resources, and consistent preview/export behavior.

## Known issues / bugs
- [x] **Archive RAW as TIFF did not properly copy IPTC metadata.** (2026-07-26)
  Sidecar overlay now uses an explicit rendered-file metadata boundary, allowing a
  generated Sony-tagged raster TIFF to bypass SwiftExif's conservative ARW-content
  heuristic without weakening the normal proprietary RAW write guard.
- [x] **Archived files with XMP edits could take a long time to load at high resolution.**
  (2026-07-26) Adaptive HDR gain-map expansion is now limited to JPEG/HEIF
  containers. Direct-HDR TIFF/JXL/PNG files no longer perform the unnecessary
  auxiliary-data probe that delayed edited retina/full-resolution loading and emitted
  `CGImageSourceCopyAuxiliaryDataInfoAtIndexWithOptionsEx` errors.
- [x] **The layout selector made Metadata Review awkward to exit.** (2026-07-26)
  The redundant Thumbnail Browser command is hidden; selecting Single, either split
  layout, or Tabs now enters the thumbnail browser and applies that layout. Layout
  checkmarks are shown only while the thumbnail browser is active.

## Other improvements
- [ ] Zooming in the edit view can't zoom as far as the full screen view (1000% vs. 4000%). Increase edit view zoom to support 4000% zoom.
- [ ] Adjusting the corner radius of an ellipse mask to be a square can cause an X-like render pattern where the corners of the rectangle mask seems to expand further/stronger than the edges.
- [ ] Adjusting the corner radius of an ellipse mask, the mask itself changes instantly, but the mask outline preview only changes after letting go of the slider.
- [ ] In the GPS/map area, make a button to quickly select the users current location as the image location.
- [ ] When a crop is applied, even when the crop UI isn't active the image is zoomed out as to leave space for crop adjustments. This should only be the case when the crop tool is active.
- [ ] Add film emulation creative effect sliders:
  - [ ] Film grain
  - [ ] Halation
  - [ ] Bloom
- [ ] Add an app setting to hide specific sliders.
- [ ] Add an app setting to add/remove IPTC metadata fields.
- [ ] Add support for more IPTC metadata fields.
