# Aagedal Photo Agent 3.0 feature guide

**Status:** release-candidate draft  
**Last reviewed:** 2026-09-15

This guide covers the new 3.0 investigation, comparison, versioning, caption, rename, and deadline
workflows. It supplements the control-level hover help and accessibility hints in the app. Commands and
shortcuts shown in Settings → Keyboard Shortcuts are authoritative when they differ from examples here.

## Open a focused workspace

Use the **Workspace** menu in the toolbar to open one of these workspaces. The separate
**Layout** menu in Browser arranges its panes as Single, Split Side by Side, Split Top and Bottom,
or Tabs. Returning to Browser preserves that layout. Metadata Review also has a **Back to Browser**
button for leaving the review table.

- **Caption Workspace** works through the visible folder with a compact field navigator, validation,
  Previous, Save & Next, Write & Next, templates, Copy Previous, and Fix Next Issue. Save keeps the
  app-sidecar edit; Write commits through the supported metadata path and only advances after success.
- **Deadline Workspace** builds a frozen preflight for the selected/visible images and a selected
  Deadline profile. Resolve blockers with Fix Next Issue, review warnings, then stage and send supported
  derivatives. A failed or cancelled retained workflow can be inspected, resumed, or removed in Activity.
- **Image Analysis** opens the selected image. Analysis work is bound to that source revision and never
  silently writes analysis locations, notes, annotations, or findings into IPTC/XMP.
- **Compare Two Images** is enabled when exactly two images are selected.

## Restore metadata edits

Open **Metadata editing history** to choose a retained history point or **Original State**.
Original State uses the saved metadata snapshot from before the pending edits. Restoring saves
an editorial draft and its XMP mirror; use **Write to Image** when you want to commit it to the
image. Develop settings and orientation are preserved. Field markers compare the draft against
the saved original; they can clear after Original State while the overall draft remains pending.

An older record without an original snapshot cannot restore Original State. A history point
cannot be reversed across later summarized or hidden values. The app explains those unavailable
actions instead of inventing missing metadata. If restoration reports an incomplete mirror or
changed files, follow its reload/retry guidance before another action.

## Listen to an associated voice memo

Caption Workspace shows a **Voice memo** panel beneath the preview. When an imported photo
has a saved WAV relationship, the panel displays its filename and duration. Press **Play voice
memo** to listen and **Pause voice memo** to pause. Selecting another photo or leaving Caption
stops playback. Playback does not transcribe audio or alter metadata.

If the memo is missing, restore the WAV beside its photo and press **Refresh voice memo**.
Invalid records, unsupported relationship schemas and unplayable audio remain unavailable.
Refresh also reloads a changed photo or memo before another playback attempt. The app does
not infer an association merely because a WAV has a similar filename.

**Duplicate** preserves a proven memo and its relationship as independent copies. When a RAW
and JPEG share a source memo, duplicating either creates its own WAV without changing the
source pair. Missing/invalid companions block duplication; existing output files are preserved.
**Add to Subfolder**, **Move to Folder** and **Move Rejected to Folder** also carry the proven
WAV and saved relationship. Moving one photo from a shared memo group keeps the source memo
for the photos left behind and gives the moved photo its own copy. Missing/invalid records,
linked audio and existing destination companions fail closed. A cleanup warning can mean the
photo moved successfully but private source backups remain; follow the reported paths before
retrying. General Move reports XMP/editorial sidecar failures separately from the moved photo.

**Move to Trash** places an associated photo, its WAV and owned metadata in one recoverable
folder. Shared audio remains available to surviving photos. In Finder's Trash, use **Put Back**
on the complete folder, keep its contents together, and open that folder in Photo Agent.
If an operation reports an issue, open **Details** for all affected paths and recovery guidance.

Archive, source reassociation, reviewed Apple on-device transcription, transcript-template application,
and explicit WAV delivery policy are implemented with the boundaries described below and in Known
Limitations. Caption also offers **Custom FFmpeg Whisper** in the transcription-provider picker.
Choose a compatible patched FFmpeg executable and model, grant explicit execution consent,
then select **Enable Custom Files** to record their identities. This step does not execute them;
**Transcribe** starts local CPU inference with automatic language detection. Results use the same
editable review and explicit approval flow as Apple Speech. Provider choice and security-scoped
file bookmarks are saved. Reopening restores available files, but requires fresh execution consent
and **Enable Custom Files** to validate their current identities. **Clear Custom Files** forgets
the selections across relaunch. Unavailable saved files can be reselected after reconnecting the volume. Custom files are unverified; hashes establish identity, not safety or trust.
No assets download automatically and an unavailable custom provider never falls back to Apple Speech.
Curated models and the bundled Whisper artifact remain in development.

## Connect a local automation client

Open **Settings → Automation**. Local automation is off by default. Add only the folders a client should
be able to address, enable the local server, and copy the setup shown for your client. Settings provides
CLI commands for Codex and Claude Code, an `opencode.json` entry for OpenCode 1.x, and a global CLI
command for OpenCode v2. OpenCode 1.x places server names directly under `mcp`; merge the displayed
entry into your existing config. OpenCode v2 uses `mcp.servers` when configured by JSON. The bundled
`photo-agent-mcp` process communicates through STDIO and does not listen on the network. Removing a folder
or disabling automation applies to later calls from an already connected client.

The server exposes read-only capability, photo-format, metadata-field, authorized-root, path-admission, revision, owned-draft,
and effective metadata tools. Call `list_metadata_fields` to discover the stable editorial JSON keys,
typed value shapes and read limits. This catalog contains no photo values and grants no write authority.
Call `get_photo_metadata` with one absolute `path` to read the same effective
editorial values selected by Photo Agent, including per-field carrier, pending/conflict state and captured
revision tokens. These tokens describe that read and do not authorize a later write. It rejects
relative/traversal paths, symlinks, Finder aliases, hard links, special files, changed folder identities,
Photo Agent private folders, and targets outside the selected roots. Unreadable carriers and oversized
metadata records fail as a whole. Face scan, template application, transcription, and IPTC mutation tools are not yet
exposed. Returned paths and metadata values can be
sensitive and are subject to the connected client's privacy and retention policy.

Call `prepare_iptc_patch` to preview proposed changes after `get_photo_metadata`. Supply the same
absolute `path`, all three returned revision strings (`sourceRevision`, `xmpSidecarRevision`,
`appSidecarRevision`), and an `operations` array. Each operation has a supported `field` and
`operation: "set"` with a typed `value`, or `operation: "clear"` without a value. The tool schema
lists the supported descriptive text fields and keyword/person arrays. Unknown fields, duplicate
operations, stale revisions and unresolved XMP conflicts are refused. Empty `set` values are
refused; use `clear` to remove a value explicitly.

The schema-3 result shows production-normalized before/after values, exact `sourceValue` and
`requestedValue`, each field's comparison rule, edited-field legacy IPTC byte-limit warnings, a content-bound
preview ID, a `planID` and a five-minute expiry. Call `get_iptc_patch_plan` with only that `planID`
to retrieve the same preview after authorization and photo/sidecar revisions are checked again.
The bundled helper restores unexpired plans after restart from its private local PatchPlans archive.
Expiry, edits or changed authorization require a fresh read and preparation. At most 64 live plans
fit within an 8 MiB serialized-result budget. Expired records are removed on the next successful
preparation; see the privacy guide for local archive removal.
The preservation preflight records exact carrier hashes, parsed-format capabilities, a production
semantic baseline and possible write destinations, including RAW protection. It selects no write mode.
These are read-only plans: no commit endpoint is available, actual write support, preservation and
publication approval are not yet verified, and no photo or sidecar is changed. Returned proposals remain
untrusted content and do not grant publication approval.

To inspect a plan in Photo Agent, open **Settings → Automation → Proofreading Plan Review**,
paste its exact `planID`, and choose **Inspect Plan**. The app rechecks the current authorization
and photo/sidecar revisions on a background worker before displaying normalized before/proposed
values and warnings. Repeatable values use quoted lists to preserve item boundaries. Changing the
ID or leaving the view clears the displayed review; expired plans require fresh preparation.
This is a checked snapshot, not live monitoring, approval, or a metadata write.

Call `list_transcription_providers` without arguments for stable provider IDs and setup guidance.
The helper cannot observe the app’s runtime, installed language assets, or admitted custom files;
it reports unknown availability and requires an app session. This catalog does not enable transcription.

Call `list_templates` with `kind: "metadata"` or `kind: "develop"` to discover stable template
UUIDs, names and exact-content revision hashes. Disable Templates iCloud sync and explicitly
authorize the active folder in **Settings → Automation**: either your custom folder from
**Settings → Templates**, or `~/Library/Application Support/Aagedal Photo Agent/Templates` for
the default local library. The library must already exist; discovery does not create it.
iCloud template libraries are currently unavailable through this tool. Discovery
reads headers only, exposes no template field values, and does not grant application authority.
Changed, ambiguous, unsupported or oversized inventories refuse as a whole. Template names are
untrusted user-authored content and may be sensitive.

Client setup references: [Codex MCP](https://developers.openai.com/codex/mcp),
[Claude Code MCP](https://code.claude.com/docs/en/mcp),
[OpenCode 1.x MCP](https://opencode.ai/docs/mcp-servers/), and
[OpenCode v2 MCP](https://opencode.ai/v2/docs/mcp-servers).

## Import templates

In **Settings → Templates → Metadata**, choose **Import…**, select a JSON bundle and review
its new/overwrite counts. Confirmation is bound to the previewed folder and exact existing JSON
bytes. If another process changes the inventory or the storage folder changes, import refuses;
open the bundle again to review a fresh preview. A failure after some templates were saved reports
those completed writes rather than claiming that the whole batch succeeded.

## Recover a deleted template

**Move to Trash** removes metadata and Develop templates from their lists while retaining the
original files in Finder’s Trash until it is emptied. Restore the JSON file to its original
Templates or DevelopTemplates folder, then reopen the template list to reload it. If moving to
Trash fails, the template remains available and the list displays an error.

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

Choose **Counter** (C) and click each person, car, or other item you want to count. Each color has its
own sequence, starting at 1. Changing color starts or continues that color's sequence. Deleting a marker
renumbers the remaining markers of its color; Undo restores the marker and count. Counter Evidence
shows the totals automatically, and the PDF report includes those totals with the individual markers.
These are manual counts stored with the analysis case, not IPTC/XMP fields.

In Pixel Analysis, open the right-hand **Layers** tab (also opened when selecting Counter). In OSINT,
use the Photo Annotations pane. Filter the list by type and color, then show or hide matching layers.
Expand **Groups by Type and Color** to toggle a whole group. Filters narrow the list; visibility
controls hide markers in the image and exported image. Hidden markers still contribute to counter
evidence. Delete a marker to remove it from the count.

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

## Apple RAW decoder

In Settings, **Apple RAW Decoder → Auto (Newest)** explicitly selects the newest decoder
Apple supports for each file. This includes RAW 9 on macOS 27 for supported cameras.
Choose **Version 8** to retain the older processing when available. A version unsupported
for a particular file falls back to Auto.

This controls sensor decoding in Develop and rendered previews/exports. Embedded camera
JPEG previews are unaffected. Restart the app after changing the decoder to clear existing
decoded images.
