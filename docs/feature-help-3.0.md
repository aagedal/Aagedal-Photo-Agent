# Aagedal Photo Agent 3.0 feature guide

**Status:** release-candidate draft  
**Last reviewed:** 2026-10-30

This guide covers the new 3.0 investigation, comparison, versioning, caption, and rename
workflows. It supplements the control-level hover help and accessibility hints in the app. Commands and
shortcuts shown in Settings → Shortcuts are authoritative when they differ from examples here. Open this guide, the known limitations and What's New from the **Help** menu.

## Find a setting

Open Settings and type in **Search Settings**, or press **Command+F** while the Settings
window is active. Search matches category names, control labels, and related terms such as
Whisper, certificate, thumbnails, or place-name language. Matching categories remain in the
sidebar with brief control hints; select a category to edit its settings. Search opens the
category rather than jumping to an individual control. Clear the field with its clear button
or **Escape** to restore all categories. Links from Caption and automation reviews still open
their requested category and clear any active search.

## Open a focused workspace

Use the **Workspace** menu in the toolbar to open one of these workspaces. The separate
**Layout** menu in Browser adds a New Tab, splits the active pane right or down, merges every pane
into tabs, or returns to a Single Pane. Drag a pane's tab onto the edge of any pane to split it there,
or onto another tab bar to move it in as a tab. Click a pane (or its tab), then a sidebar folder, to
open that folder in it; the sidebar shows the active pane's folder with a solid highlight and the
other panes' folders with a split icon. Returning to Browser preserves the layout. Metadata Review also has a **Back to Browser**
button for leaving the review table.

- **Caption Workspace** works through the visible folder with a compact field navigator, validation,
  Previous, Save & Next, Write & Next, templates, Copy Previous, and Fix Next Issue. Save keeps the
  app-sidecar edit; Write commits through the supported metadata path and only advances after success.
- **Image Analysis** opens the selected image. Analysis work is bound to that source revision and never
  silently writes analysis locations, notes, annotations, or findings into IPTC/XMP.
- **Compare Two Images** is enabled when exactly two images are selected.

## Create a text watermark

Open **Settings → Watermarks → Create Text…** beside the PNG import control. Give the
overlay a name, enter one or more lines of text, and choose System, Serif or Monospaced,
font size, bold/italic, color and opacity. The checkerboard preview shows transparency.
Choose **Create** to save and select the watermark in the library, then adjust its default
placement in the editor. Use it through the existing Develop watermark controls.

Text watermarks are saved as transparent PNG assets. Create another overlay to change the
text or style later. Text supports up to 2,048 UTF-16 units, font sizes of 8–512 pixels,
and an output canvas of at most 4,096 pixels in either dimension.

## Restore metadata edits

Open **Metadata editing history** to choose a saved history point or **Original State**.
Original State uses the saved metadata snapshot from before the pending edits. Restoring saves
an editorial draft and its XMP mirror; use **Write to Image** when you want to commit it to the
image. Develop settings and orientation are preserved. Field markers compare the draft against
the saved original; they can clear after Original State while the overall draft remains pending.

An older record without an original snapshot cannot restore Original State. A history point
cannot be reversed across later summarized or hidden values. The app explains those unavailable
actions instead of inventing missing metadata. If restoration reports an incomplete mirror or
changed files, follow its reload/retry guidance before another action.

## Listen to a linked voice memo

If you open an existing Sony camera folder directly, select its photo in Caption and use
**Find matching voice memo…**. The app checks the WAV files beside the photo against the
camera's recording information. Confirm **Link Voice Memo** to save the link. Opening or
checking the folder makes no changes; linking saves a small link file in the folder without
changing the photo or WAV. Duplicate or uncertain matches are refused. **Find Link in Another
Folder…** is for recovering a link that was saved before the photo was moved, not for linking
a memo the first time.

After linking, choose **Apple Speech** in Settings → Transcription. Caption’s Voice memo panel
then exposes the language picker and **Download Language** when the selected locale needs its
on-device asset. If **Transcribe** appears, the selected language is already installed.

Caption Workspace shows a **Voice memo** panel beneath the preview. When an imported photo
has a linked WAV, the panel displays its filename and duration. Press **Play voice
memo** to listen and **Pause voice memo** to pause. Drag the playhead to listen from any point,
including while paused. Selecting another photo or leaving Caption
stops playback. Playback does not transcribe audio or alter metadata.
Browser thumbnails and the Caption filmstrip show an orange waveform on photos with a voice memo awaiting transcription,
and the same waveform in green when a saved transcript matches the current memo. The filmstrip
focuses one photo for editing; batch transcription is available from the Browser thumbnail context menu.

If the memo is missing, restore the WAV beside its photo and press **Refresh voice memo**.
Damaged links, links saved by a newer version of Photo Agent and unplayable audio stay unavailable.
Refresh also reloads a changed photo or memo before another playback attempt. Caption automatically detects and links a unique supported WAV in the same folder using the
same matching rules as import. Existing links are kept. Ambiguous matches
and moved or replaced memos still use the manual recovery controls.

**Duplicate** copies a linked memo and its link along with the photo. When a RAW
and JPEG share a source memo, duplicating either creates its own WAV without changing the
source pair. Missing/invalid companions block duplication; existing output files are preserved.
**Add to Subfolder**, **Move to Folder** and **Move Rejected to Folder** also carry the proven
WAV and its link. Moving one photo from a shared memo group keeps the source memo
for the photos left behind and gives the moved photo its own copy. If a link is damaged, the
WAV is an alias, or the destination already has a file with the same name, nothing is moved. A cleanup warning can mean the
photo moved successfully but private source backups remain; follow the reported paths before
retrying. General Move reports XMP/editorial sidecar failures separately from the moved photo.

**Move to Trash** places a photo with a voice memo, its WAV and owned metadata in one recoverable
folder. Shared audio remains available to surviving photos. In Finder's Trash, use **Put Back**
on the complete folder, keep its contents together, and open that folder in Photo Agent.
If an operation reports an issue, open **Details** for all affected paths and recovery guidance.

Archive, source reassociation, reviewed Apple on-device transcription, transcript-template application,
and explicit WAV delivery policy are implemented with the boundaries described below and in Known
Limitations. Configure the provider in **Settings → Transcription**. Caption contains playback, Transcribe, and a compact read-only transcript; language selection is available in Caption and Settings. Custom file selection, translation, GPU and consent controls live in Settings.
Select **Whisper** to use the embedded FFmpeg engine. Choose Tiny (about 78 MB), Base
(about 148 MB), Small (about 488 MB), multilingual Turbo (about 1.6 GB), or multilingual Large v3
(about 3.1 GB), then explicitly download the model in Settings.
Norwegian Tiny, Small, Medium (about 1.5 GB), and Large (about 3.1 GB) from NbAiLab are also available.
Choose a Norwegian model and select **Norwegian** for Norwegian voice memos.
Downloads come from pinned whisper.cpp or NbAiLab model repositories over HTTPS; the app checks the exact
byte count and SHA-256 before installing in local Application Support. Progress and cancellation
are available. After installation, Settings shows **Verifying transcription files…** while preparing
the local engine and model. Cancelling shows **Cancelling model setup…** until that work finishes;
a model already installed remains available for removal or **Retry Setup**, without enabling transcription.
Installed models can be removed from Settings and used offline after preparation.
No executable selection is needed for this provider. Inference starts only after an explicit single-photo or batch action.
Language defaults to **Detect Automatically**. Choose a named language in Settings or Caption, request translation into English,
and request GPU acceleration. GPU use is requested rather than verified. Each draft records the
engine/model identities and settings used. Single-photo transcripts are saved and ready for
`{voiceMemoTranscript}` automatically, without an approval step. Process the variable in
Description, Extended Description, Headline, or Instructions, then edit the resulting metadata
text there. Processing transcript variables needs no additional confirmation. Saved batch transcripts are ready for variables directly in the Browser; opening each photo in Caption is unnecessary. Transcription itself does not change IPTC fields.
Caption reserves a fixed transcript area; the settings cog and reset arrow sit beside the transcription controls.
Use the **Reset Transcript** arrow in Caption to remove the saved transcript and transcribe the memo again.
The batch confirmation also offers **Reset Selected Transcripts…**, then rechecks the captured selection.
Both resets preserve the WAV files and any text already inserted into metadata fields.

**Custom FFmpeg Whisper** remains available for advanced users. Choose compatible executable/model
files, grant execution consent, and select **Enable Custom Files** to record their current identities.
This preparation does not execute the files. Provider choice, settings and security-scoped file
bookmarks persist; custom execution consent and identity admission must be renewed after relaunch.
**Clear Custom Files** forgets those saved selections. Custom files are unverified; hashes establish
identity, not software trust. No provider automatically falls back to Apple Speech. Downloads require
an explicit action and do not send voice memos, photos or transcripts to the hosting service.

To transcribe several memos, select 1–8 photos in Browser, right-click a selected thumbnail,
and choose **Transcribe Voice Memos…**. The batch retains that selection in Browser order. Check the photo names,
provider and language in the confirmation. Select a language for this batch (or **Detect Automatically**
with Whisper), then press **Transcribe N Photos** to authorize and start it. The batch language choice
does not change your Settings default; changing it rechecks the captured selection. Apple Speech lists
supported locales and requires the chosen on-device language to be installed.
Every photo needs a linked WAV. Photos sharing a metadata sidecar cannot
be included together. Existing saved transcripts refuse preparation; an active or unsaved current review must finish before a batch starts.
The chosen provider must already be set up: if it isn't, the sheet offers **Transcription Settings…**,
and if the Apple Speech language isn't installed it offers **Download Language**. The batch never
downloads Whisper models or switches providers. Changed photos, WAVs or links require a fresh confirmation.

The confirmation closes when transcription starts, and processing continues in the background.
Open **Activity** in the left sidebar to view progress or cancel the batch. Completed batches remain
in Activity history, with per-photo results and a **Transcriptions** filter.
Saved batch transcripts are ready for metadata
variables straight away; IPTC fields are unchanged. **Cancel Transcription** in the Activity header requests cancellation and waits for the active item to stop.
Drafts already saved remain available in Caption, even if the
batch fails or is cancelled. An uncertain save stops the remaining photos and requires inspection
before retrying. The current empty transcript panel reloads a saved batch draft without replacing an existing transcript.

## Improve descriptions with a local model

Open the wand beside **Description**, or use batch description improvement for a fixed
selection. Choose **Settings → Description Assistant → Provider**:

- **Local GGUF / MLX model** downloads or selects local weights; Gemma 4 12B is the
  recommended download. Existing local model choices remain saved when switching providers.
- **Apple Foundation Models** uses Apple’s on-device model on macOS 27 or later, without
  a Photo Agent model download. It requires an eligible Mac, Apple Intelligence enabled,
  and Apple’s model ready. Use **Check Availability** after changing Apple Intelligence
  settings. Supported caption languages are shown for this Mac; choose a local model for
  a language Apple’s model does not support.

**Correct grammar** and **Improve wording** work from the existing description and editorial
prompt only; they do not look at the image. **Write from image** drafts a new description from
the photo itself plus its metadata. It needs Apple Foundation Models with image support or a
vision-capable MLX model folder; the GGUF runner cannot receive images. Review and edit each suggestion before
**Apply to Description** or **Queue Reviewed Description**. A changed original description
or editor load refuses stale application. Cancellation discards unfinished output; a batch
retains completed suggestions for review. Provider failures do not switch models automatically.

## Connect a local automation client

Open **Settings → Automation**. Local automation is off by default. Add only the folders a client should
be able to address, enable the local server, and copy the setup shown for your client. Settings provides
CLI commands for Codex and Claude Code, an `opencode.json` entry for OpenCode 1.x, and a global CLI
command for OpenCode v2. OpenCode 1.x places server names directly under `mcp`; merge the displayed
entry into your existing config. OpenCode v2 uses `mcp.servers` when configured by JSON. The bundled
`photo-agent-mcp` process communicates through STDIO and does not listen on the network. Removing a folder
or disabling automation applies to later calls from an already connected client.

Automation is **experimental** in 3.0 and read-only: a client can read effective metadata, inspect
voice memo links and templates, and prepare previews in the folders you allow. It cannot write
metadata, apply templates, run face scans or start Develop work. Requests that lead to a change (a
metadata or transcription review, or adding a team when **Allow team creation** is on) wait in
Settings → Automation until you approve them there. Review history and recovery sections appear when
you turn on **Show reviews, history and recovery**. Returned paths and metadata can be sensitive and are
subject to the connected client's own privacy and retention policy.

The complete tool reference is in the
[developer automation reference](developer/local-automation-mcp.md#tool-reference-from-the-feature-guide).

## Apply a template: Replace, Fill Empty or Append

Pick a metadata template in the template palette, Caption Workspace or the import sheet. The
modifier keys held when you choose it decide how it combines with existing values; only the fields
the template contains are touched:

- **Return** (or a plain click) — **Replace**: the template's values replace the fields, and an empty
  template field clears that field.
- **Option-Return** — **Fill Empty Fields**: values go only into fields that are empty. On a
  multi-photo selection this is decided per photo. Date Created, Urgency, Digital Source Type and
  Image Supplier can't be filled on a mixed selection; the app names those fields instead.
- **Shift-Return** — **Append**: text and lists are added after each photo's own existing value.
  Appending over an unsaved Fill Empty Fields on the same field asks you to save first.

## Import from a card

The sidebar shows import progress with a time-left estimate. When an import from a memory card or
removable disk finishes, the sidebar banner and **Import Complete** offer **Eject** for that card.
If macOS can't eject it yet, the app says which apps or files to close first. Eject is never offered
for the import destination or backup disk.

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
3. In Pixel Analysis, choose Normal, channel/luminance, Alpha, Edges, Compression Residual, Noise
   Residual, Level Sweep, or Clone Detection from **Pixel View**. Every view is a visualization with
   fixed disclosed parameters, rendered from a bounded preview (at most 2048 px; Clone Detection 1024 px),
   not proof of manipulation:
   - **Noise Residual** amplifies the difference between luminance and a median-filtered copy, so
     regions with different noise or sharpening can stand out.
   - **Level Sweep** stretches a narrow luminance band around the chosen level to expose subtle tonal
     edges; drag the level to sweep through the image.
   - **Clone Detection** tints 8 × 8 blocks whose coarse brightness pattern repeats elsewhere at the same
     offset. It is a visual aid for manual review, not an automated copy-move detector: it misses
     rotated, scaled, flat, or heavily altered copies, and repeated textures (sky, walls, fabric) produce
     harmless matches.
4. Use the linked hover sample, source-pixel readout, and true-pixel loupe to inspect corresponding areas.
   RGB values come from the full-resolution decode, converted to 16-bit sRGB (wide-gamut and HDR
   files therefore read differently from their stored numbers); while it is still loading the readout is marked
   **Preview pixel**. Toggle the loupe with **Z** while pointing at the image, or use the **Loupe**
   button. Its compact panel moves to the corner opposite the pointer to keep the inspected area visible.
   Press **Esc** to cancel an in-progress polygon or map shape, then to return to the Select tool, then to
   clear the selection. With nothing left to cancel, Esc closes Image Analysis (not while an export is running).
5. Open finding details to read the observation, technical basis, alternatives, limitation, analyzer
   version, and report-inclusion state.

The app deliberately does not combine findings into a real/fake or AI-generated score.

### Annotate and measure

Use the Photo tools for line/arrow, distance, rectangle, ellipse, polygon (shape), and label annotations,
and the Hand tool (or hold Space) to pan a zoomed photo. The tools' letter shortcuts work while the
pointer is over the photo. Scroll or pinch to zoom; markers, labels and click targets stay the same size
on screen at any zoom. Right-click an annotation to rename it, add a note, or delete it. Measurements are
in source pixels unless you explicitly calibrate a known segment and unit. Calibration is case evidence,
not camera metadata, and does not infer physical size from DPI alone.

Choose **Counter** (C, while pointing at the photo) and click each person, car, or other item you want to count. Each color has its
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
- add untimed observations or timezone-qualified timeline rows (deleting one asks first, because notes
  and timed observations have no Undo). A capture time is absolute when the file records its UTC offset
  (EXIF OffsetTimeOriginal); otherwise it is shown as "timezone unresolved";
- use Apple or OpenStreetMap map styles, add map annotations, and link them to photo annotations;
- define photo location and optional field-of-view bearing/range; and
- save an offline solar-position calculation for a known coordinate, civil time, timezone/offset, and
  calculation method. Only capture, GPS and your own timed observations can supply the time; file and
  sidecar dates record when bytes were written, not when the photo was taken. Coordinates can be typed as
  decimal degrees (also with decimal commas, such as `59,9139 10,7522`), or as degrees-minutes(-seconds)
  with the hemisphere letter before or after each number.

The solar overlay supplies geometric directions under its documented flat-horizon and atmosphere model.
It does not analyze shadows in the photograph or establish when or where an image was made.

### Export or move a case

Use the export menu in Image Analysis to create a PDF report, an Annotated Image or Annotated Map (JPEG),
or a portable `.pint` Image Analysis Project; the same menu imports a project.
Report export rechecks the source revision and freezes the selected evidence. Review sensitive-field,
map, and redaction choices before saving. A project archive contains the working-folder images, matching
XMP sidecars, and folder-local Photo Agent case/metadata/version documents. Its manifest checks the size
and SHA-256 of every payload file before import, and import requires a new or empty destination. Treat the
archive as sensitive evidence: it is a portable copy of the source images and their associated data.
Exports and project operations show progress with **Cancel** in the Image Analysis header and keep
running if you select another photo. Closing Image Analysis while one runs asks whether to cancel it. If a case change cannot be saved, a banner keeps your edits in
the workspace and offers **Retry Save**; selecting another photo or closing first asks whether to retry,
discard the unsaved edits, or cancel, and project export retries the save before it runs.

## Compare two images

1. Select exactly two images and choose **Compare Two Images**.
2. Choose side-by-side, stacked, or wipe. Select a pane to make it the focused image.
3. Keep pan/zoom locked for normalized navigation. Temporarily unlock when the images need manual
   alignment, then save the offset and relock.
4. Use Fit, 100%, or a custom zoom. Reset clears the saved alignment offset.
5. Close Compare to return to the originating Browser, Develop, or full-screen workflow.

Comparison aligns display-oriented normalized positions. It does not register image content
automatically, and the wipe view is not a computed difference image.

## Adjust Develop sliders precisely

Drag a slider, or hold Option while dragging for finer steps. Double-click a slider to reset it.
Click a slider's value to type an exact number, then press Return or click elsewhere; Escape cancels. Units such as
K, % or px can be left out, and a comma works as the decimal mark. With a slider selected, the Up
and Down arrow keys step it (hold Shift for bigger steps). Each change is one Undo step.

## Use named Develop versions

In Develop, the version control starts at **Main Edit**. The main edit is the one saved in the photo's
XMP, so it is what other apps such as Lightroom and Camera Raw see.

- Create or duplicate a named version to keep an alternative look.
- Rename, delete, or compare named versions from the version controls.
- Wait for the Saved state before leaving while a save is in progress. If a save fails, Photo Agent
  doesn't switch versions silently.
- Choose **Make Main Edit…** to have a named version replace the main edit. Photo Agent first keeps the
  current main edit as a dated version, then saves and checks the result.

Named versions are stored only in Photo Agent. Other apps see only the main edit.

## Batch Rename

Batch Rename previews the full rename plan, companion artifacts, collisions, and rollback boundary before
moving files. Original Filename is written only through the supported metadata contract.

Deadline Workspace and its profile management are deferred to 3.1 and hidden in 3.0. Existing saved
profiles and retained delivery evidence are preserved. Activity can still show and remove retained
workflows, but resuming them through Deadline Workspace is unavailable in 3.0.

## External authenticity checks

The verification menu in Image Analysis links to outside tools: reverse image search (TinEye, Google
Lens), provenance and watermark checks (Content Credentials Verify, Meta's Content Seal identification
page, Google's [SynthID Detector](https://synthid.com/)), and manipulation analysis (ImageWhisperer,
Forensically). Opening a link does not
send the current image. If you choose to upload an image on the external
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
