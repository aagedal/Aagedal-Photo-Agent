# Aagedal Photo Agent 3.0: known limitations

**Last reviewed:** 2026-10-25

This page lists what 3.0 does not do, or does only partly, so you can plan around it. For how
features work, see the [3.0 feature guide](feature-help-3.0.md).

## Before you upgrade

- **Back up your app data first.** 3.0 replaces 2.x and uses the same data locations. Older versions
  may not understand some data written by 3.0. Export your Known People library (Settings ▸ Known
  People ▸ People Library ▸ Export People Library…), metadata templates (Settings ▸ Templates ▸ Export All…) and keyword
  lists (Settings ▸ Keywords ▸ Export Lists…), or copy
  `~/Library/Application Support/Aagedal Photo Agent/`.
- **Update every Mac that syncs through iCloud.** 2.x and 3.0 can read the same synced Known People,
  templates and keyword lists. If you use **Replace iCloud Library and Sync** in 3.0, Macs still on 2.x
  keep seeing the old library.

## Not in 3.0

- **Deadline Workspace** (frozen, staged deadline delivery) is hidden until 3.1. Normal FTP/FTPS upload
  is unaffected. Saved Deadline profiles and history are kept.
- **Expression and Red Carpet face lenses** are still turned off. The normal Face lens and the Sports
  lens (jersey numbers) are available.
- **No AI-origin detection.** Image Analysis has no AI-image detector, no automatic copy-move
  detector and no automatic shadow check. The Meta and Google entries only open those services'
  websites. Photo Agent does not upload your image to them.
- **SFTP.** Uploads use macOS's built-in `curl`, which has no SFTP support. Use FTPS (the default) or FTP.
- **Browser undo** for ratings, labels and moves is planned for 3.1. The import time estimate is
  based on files copied so far, so a mix of small photos and large videos makes it less exact. HSL and the vertical color sliders don't accept typed values.

## Experimental in 3.0

- **C2PA signing** has not been verified end to end. Reading and displaying content credentials works.
  Treat signing as a preview: it may change, or be off by default, in a later release.
- **Local automation (MCP)** is off by default and limited to reading and previewing. An AI client can
  inspect photos, metadata, templates and voice memos in folders you explicitly allow. It cannot write
  metadata, apply templates, run face scans or start Develop batches. The few actions that lead to a
  change (queuing a metadata or transcription review, adding a team) always wait for your approval in
  the app. Granting a folder limits what Photo Agent shares, not what the AI client can do on your Mac
  or send over the network.

## Voice memos and transcription

- Automatic photo/WAV pairing recognises **Sony** cameras' voice-memo layout. Other cameras' memos
  are not paired automatically, and there is no manual "link this WAV" command beyond Caption's
  **Find matching voice memo…** for Sony folders.
- **Apple Speech** is the default and needs no download. **Whisper** is optional: download a model in
  Settings ▸ Transcription. Models are checked against a pinned SHA-256 checksum. That confirms the file
  is the expected one. It does not guarantee accuracy.
- The Norwegian **NbAiLab** Whisper models write Norwegian even when the speaker uses another language
  (they translate), and can repeat the end of a recording. Settings warns when one is selected.
- All transcripts are drafts. Read them before they go into a caption.

## Metadata and other apps

- Photo Agent follows Photo Mechanic for metadata and Adobe Camera Raw for Develop settings. Other
  apps can still read some fields differently. The [metadata field table](metadata-field-support.md)
  shows exactly what is written where. Not every Bridge or Photo Mechanic round trip has been tested.
- **RAW files are never modified.** Their metadata and edits go into the `.xmp` sidecar next to them.
- **Named Develop versions, Image Analysis cases and map notes are Photo Agent-only.** Other apps
  cannot see them. Choose **Make Main Edit…** on a version to write it as ordinary Camera Raw settings.
- Film emulation, watermark layers and the Anonymizer (face blur) are saved in Photo Agent's own XMP
  fields. Camera Raw and Lightroom ignore them.
- Exports keep **Person Shown** names and keywords even when those people are blurred with the
  Anonymizer. Remove the names yourself if the blur is meant to hide who they are.

## Develop and export

- At most **8 local layers** (masks, extra Global, LUT layers) and **4 watermark layers** render per
  photo, in preview and export alike. The add-layer buttons are disabled at the limit. Files from Camera
  Raw with more layers show a warning; only the first 8 render.
- The **Output Resolution** limit applies to Export, Develop Save and signed renders. Save As and FTP
  uploads render at full size.
- Very large images, two RAW files side by side in Compare, and HDR on external displays can be slow
  on Macs with less memory.
- The Clone Detection view in Pixel Analysis only highlights repeated blocks for you to inspect. It
  misses rotated or scaled copies and flags naturally repeating texture.

## Image Analysis is evidence, not a verdict

- Metadata conflicts, C2PA state, pixel views, maps and the sun-direction overlay help an
  investigation. None of them proves that an image is authentic, edited or AI-generated. Compression
  views also react to ordinary sharpening, resizing and re-saving.
- Map imagery and place search can be missing, out of date or wrong. Sun directions assume a flat
  horizon and a correct camera clock.
- PDF reports are not signed or legal attestations. Keep the original files.

## Delivery

- A successful FTP/FTPS upload means the server accepted the file. Photo Agent does not re-download it
  to compare bytes. Files are uploaded under a temporary name and renamed when complete, so hot folders
  never pick up a partial file. Some servers refuse renames; Photo Agent then falls back to the final
  name.
- FTPS checks the server certificate the normal macOS way. Certificate pinning is not available.

## Requirements

- macOS 26 or later on Apple Silicon. Apple Foundation Models in the Description Assistant needs
  macOS 27 with Apple Intelligence; otherwise the Description Assistant uses a downloaded local model.
- Face recognition needs the bundled AuraFace model. A build without it shows face recognition as
  unavailable.
