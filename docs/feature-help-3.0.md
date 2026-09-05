# Aagedal Photo Agent 3.0 feature guide

**Status:** release-candidate draft  
**Last reviewed:** 2026-08-25

This guide covers the new 3.0 investigation, comparison, versioning, caption, rename, and deadline
workflows. It supplements the control-level hover help and accessibility hints in the app. Commands and
shortcuts shown in Settings → Keyboard Shortcuts are authoritative when they differ from examples here.

## Open a focused workspace

Use the view/layout menu above the browser to open one of these workspaces:

- **Caption Workspace** works through the visible folder with a compact field navigator, validation,
  Previous, Save & Next, Write & Next, templates, Copy Previous, and Fix Next Issue. Save keeps the
  app-sidecar edit; Write commits through the supported metadata path and only advances after success.
- **Deadline Workspace** builds a frozen preflight for the selected/visible images and a selected
  Deadline profile. Resolve blockers with Fix Next Issue, review warnings, then stage and send supported
  derivatives. A failed or cancelled retained workflow can be inspected, resumed, or removed in Activity.
- **Image Analysis** opens the selected image. Analysis work is bound to that source revision and never
  silently writes analysis locations, notes, annotations, or findings into IPTC/XMP.
- **Compare Two Images** is enabled when exactly two images are selected.

## Image Analysis

### Inspect pixels and evidence

1. Select one image and open **Image Analysis**.
2. Choose the original or developed representation. Source-byte findings remain bound to the original.
3. In Pixel Analysis, choose Normal, channel/luminance, Alpha, Edges, or Compression / Residual. The
   residual result is a visualization with fixed disclosed parameters, not proof of manipulation.
4. Use the linked hover sample, source-pixel readout, and true-pixel loupe to inspect corresponding areas.
   Toggle the loupe with **Z** while pointing at the image, or use the **Loupe** button. Its compact
   panel moves to the corner opposite the pointer to keep the inspected area visible.
5. Open finding details to read the observation, technical basis, alternatives, limitation, analyzer
   version, and report-inclusion state.

The app deliberately does not combine findings into a real/fake or AI-generated score.

### Annotate and measure

Use the Photo tools for line/arrow, distance, rectangle, ellipse, and label annotations. Measurements are
in source pixels unless you explicitly calibrate a known segment and unit. Calibration is case evidence,
not camera metadata, and does not infer physical size from DPI alone.

### Build OSINT context

In OSINT mode you can:

- distinguish embedded, inferred, and user-entered timestamp/location evidence;
- add untimed observations or timezone-qualified timeline rows;
- use Apple or OpenStreetMap map styles, add map annotations, and link them to photo annotations;
- define photo location and optional field-of-view bearing/range; and
- save an offline solar-position calculation for a known coordinate, civil time, timezone/offset, and
  calculation method.

The solar overlay supplies geometric directions under its documented flat-horizon and atmosphere model.
It does not analyze shadows in the photograph or establish when or where an image was made.

### Export or move a case

Use the export menu in Image Analysis to create a PDF report or a portable `.pint` Image Analysis Project.
Report export rechecks the source revision and freezes the selected evidence. Review sensitive-field,
map, and redaction choices before saving. A project archive contains the working-folder images, matching
XMP sidecars, and folder-local Photo Agent case/metadata/version documents. Its manifest checks the size
and SHA-256 of every payload file before import, and import requires a new or empty destination. Treat the
archive as sensitive evidence: it is a portable copy of the source images and their associated data.

## Compare two images

1. Select exactly two images and choose **Compare Two Images**.
2. Choose side-by-side, stacked, or wipe. Select a pane to make it the focused image.
3. Keep pan/zoom locked for normalized navigation. Temporarily unlock when the images need manual
   alignment, then save the offset and relock.
4. Use Fit, 100%, or a custom zoom. Reset clears the saved alignment offset.
5. Close Compare to return to the originating Browser, Develop, or full-screen workflow.

Comparison aligns display-oriented normalized positions. It does not register image content
automatically, and the wipe view is not a computed difference image.

## Use named Develop versions

In Develop, the version control starts at **Primary (XMP)**.

- Create or duplicate a named version to preserve an alternative Develop snapshot.
- Rename, delete, or compare named versions from the version controls.
- Wait for the visible Saved state before leaving when a save is in progress. A failed flush blocks a
  silent version switch.
- Choose **Promote to Primary…** only when the named version should replace the interoperable Primary XMP
  state. Photo Agent creates a dated recovery version, writes Primary, and verifies read-back.

Named versions live in Photo Agent's app-private JSON store. Other applications see only Primary XMP.

## Rename and deadline delivery

Batch Rename previews the full rename plan, companion artifacts, collisions, and rollback boundary before
moving files. Original Filename is written only through the supported metadata contract.

Deadline Send accepts staged derivatives only: SDR JPEG/TIFF or HDR Adaptive JPEG gain-map/16-bit TIFF.
It refuses originals and XMP-sidecar-only delivery. A successful FTP/FTPS/SFTP response and optional
remote size observation are acknowledgements, not a remote cryptographic hash. Review Activity for the
privacy-limited receipt and any explicitly retained workflow.

## External authenticity checks

Image Analysis contains links to Meta's Content Seal identification page and Google Gemini for SynthID
checking. Opening a link does not send the current image. If you choose to upload an image on the external
site, that action is governed by the external provider's terms and privacy practices and is outside Photo
Agent's report reproducibility boundary.

## Where to read the boundaries

- [Known limitations](limitations-3.0.md)
- [Privacy draft](../PRIVACY.md)
- [Metadata field and delivery support](metadata-field-support.md)
- [Bundled licenses and source offer](../README.md#license)
