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
- [ ] Archive RAW as TIFF will not properly copy IPTC metadata. "overlaySidecarIPTC XMP writeFields failed for TRA05549-3.ARW → TRA05549-3 2.tiff: Refusing to embed metadata into proprietary RAW (.arw) — rewriting it would corrupt maker-private data (e.g. Sony SR2Private). Use an XMP sidecar, or pass WriteOptions.allowUnsafeRawEmbed to override."
- [ ] Looking at Archived files it can take a long time for the hires version to load in full screen view. (When XMP edits are applied.) Possibly related log item "*** ERROR: CGImageSourceCopyAuxiliaryDataInfoAtIndexWithOptionsEx:5923: auxiliary data read failed"
- [ ] Confusing UI in the layout selector. Exiting the Metadata Review requires the user to select Thumbnail Browser instead og Single or other view modes. It would be more intuitive if Single always meant Thumbnail browser, and that the Thumbnail browser was hidden.

## Other improvements
- [ ] Zooming in the edit view can't zoom as far as the full screen view (1000% vs. 4000%). Increase edit view zoom to support 4000% zoom.
- [ ] Adjusting the corner radius of an ellipse mask to be a square can cause an X-like render pattern where the corners of the rectangle mask seems to expand further/stronger than the edges.
- [ ] Adjusting the corner radius of an ellipse mask, the mask itself changes instantly, but the mask outline preview only changes after letting go of the slider.
- [ ] In the GPS/map area, make a button to quickly select the users current location as the image location.


