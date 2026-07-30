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
- [ ] In full-screen help or loading guidance, suggest turning off edit previews when
  faster high-resolution loading matters more than previewing the current Develop edits.
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
- [x] Add film emulation creative effect sliders:
  - [x] Film grain
  - [x] Halation
  - [x] Bloom
  - [x] Vignette
  - [x] Edge blur
  (2026-07-26) The primary Global layer now includes persisted 0–100 film controls.
  Spatial effects use the ordered multi-pass Metal graph, and preview, Clean Feed,
  scopes, copied settings, templates, sidecars, embedded XMP, and exports share the
  same settings and rendering behavior.
- [x] Add an app setting to hide specific sliders. Exposure, white balance, and the
  crop tool cannot be hidden. Optional global and matching local-mask sliders are
  organized by category in Settings → General, default to visible, persist across
  launches, and participate in portable preference sync. (2026-07-26)
- [x] Add an app setting to add/hide IPTC metadata fields. Headline, Description,
  Keywords, and Copyright always remain available; optional fields default to visible,
  persist across launches, and participate in portable preference sync. Hiding a field
  does not remove its stored metadata. (2026-07-26)
- [x] Hiding all sliders within a section now removes its otherwise-empty header.
  Each Develop slider group also has a section-wide visibility toggle while protected
  core controls remain available. (2026-07-26)
- [x] Add support for more IPTC metadata fields. (2026-07-26)
  Added Sublocation, State / Province, Instructions, and Source across embedded
  IPTC/XMP, sidecars, templates, import, batch editing, Metadata Review, required
  field checks, history, and customizable field visibility.
- [x] Improve AI-masks to support Face, not just person. (2026-07-26)
  Face is now a distinct Auto / Face / Person / Object target. Vision face detection
  selects the clicked face and authors a soft facial matte without expanding the
  selection to the person's body. The target persists through sidecars and existing
  pre-Face masks remain compatible.
- [x] Triaged the Xcode `CSInlineDonation` / `SetStoreUpdateService` warning.
  (2026-07-26) The app has no App Intents or Core Spotlight dependency, and Xcode's
  metadata processor confirms that extraction is skipped. The warning is emitted by
  the macOS 26 system service when the test host starts and is also reproducible in
  Apple's own sample apps. No ineffective app-side suppression was added.
- [x] The app no longer relies on plain paths for previously granted browser folders.
  (2026-07-26) Recent and favorite folder records now persist security-scoped
  bookmarks, resolve and refresh them on launch, and retain one balanced access claim
  for asynchronous thumbnails, metadata, exports, and folder monitoring. Legacy
  path-only records still decode and acquire a bookmark the next time they are opened.
- [x] Improve edge blur quality. (2026-07-26)
  Replaced direct coarse-mip sampling with a smooth multi-tap optical blur in both the
  main edit/export shader and the scopes shader, removing visible square mip blocks.
- [x] Improve film grain. (2026-07-26)
  Grain now uses correlated, multi-scale monochrome density variation with a
  midtone-weighted film response instead of independent additive per-pixel noise.
- [x] Increase vignette strength. (2026-07-26)
  The control now reaches farther into the frame and provides substantially stronger
  corner falloff while preserving the image center.



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
- [ ] Grading version: the ability for an image to store different edit versions (json only, not XMP)
