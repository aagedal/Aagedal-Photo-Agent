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
- [x] **Increase Develop preview zoom to 4000%.** (2026-07-26)
  Magnify gestures, scroll-wheel zoom, and the cursor-anchored 100% toggle now share
  the same 4000% upper bound as the full-screen viewer.
- [x] Rounded-rectangle masks no longer develop an X-like feather pattern at
  intermediate corner radii. Feather contours now preserve the selected corner
  proportion consistently from rectangle through ellipse. (2026-07-26)
- [x] Adjusting the corner radius of an ellipse mask now updates the mask outline
  continuously while the slider is dragged. (2026-07-26)
- [x] In the GPS/map area, add a button to use the Mac's current location as the
  image location, including permission and error handling. (2026-07-26)
- [x] When a crop is applied, only leave space around the image for adjustment handles
  while the crop tool is active. Confirmed crops now use the full Develop preview pane.
  (2026-07-26)
- [ ] Add film emulation creative effect sliders:
  - [ ] Film grain
  - [ ] Halation
  - [ ] Bloom
  - [ ] Vignette
  - [ ] Edge blur
- [ ] Add an app setting to hide specific sliders.
- [ ] Add an app setting to add/remove IPTC metadata fields.
- [ ] Add support for more IPTC metadata fields.
- [ ] Improve AI-masks to support Face, not just person.
- [ ] Warning in XCode logs: "{CSInlineDonation[async]: "aagedal.Aagedal-Photo-Agent" add-update-items:0 delete-items:1}: Failed to request donation Error Domain=CSIndexErrorDomain Code=-1000 "Failed to request donation" UserInfo={NSDebugDescription=Failed to request donation, NSUnderlyingError=0x786c7b26d0 {Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.SetStoreUpdateService was invalidated from this process." UserInfo={NSDebugDescription=The connection to service named com.apple.SetStoreUpdateService was invalidated from this process.}}}"


## Future version 2.3
- [ ] Image analysis layout mode
  - [ ] Two modes
    - [ ] Pixel analysis (is this manipulated or AI-generated)
    - [ ] OSINT (where was this image taken and when)
  - [ ] Bigger scopes, on hover detail zoom
  - [ ] Scope/view to more easily view compression, side by side with real image
  - [ ] Pixel analysis to detect common AI-generated artifacts
  - [ ] Suspicious metadata detection (e.g.: real images are rarely png)
    - [ ] Output non-technical language
  - [ ] Markup tools for manual verification
    - [ ] Draw lines
    - [ ] Meassure (optional pixel to cm conversion)
    - [ ] Circle or put rectangle objects with labels (color pallet)
    - [ ] Place images on a satellite map, as a OSINT companion tool.
      - [ ] The satellite image itself may also need to support the markup tools, as to easily mark the location of objects/buildings with the same color as the markuplabel in the photo.
  - [ ] Analysis report PDF export
- [ ] Comparison view, letting the user select two images to view next to each other
  - [ ] Zoom and pan lock, to make it easy to compare details. (should be possible to unlock/offset)
  - [ ] Accessible both in the develop view, the full screen, and clean feed view.
