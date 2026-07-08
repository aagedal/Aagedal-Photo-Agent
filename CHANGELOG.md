# Changelog

All notable user-visible changes are documented here. Signed, notarized DMGs are self-hosted and delivered as in-app updates via Sparkle.

## 2.1.0 — Unreleased

### Highlights

- Sports lens is now enabled, with a confirm-before-write review workflow for jersey numbers, bibs, team sheets, and player claims.
- New freeform brush masks for local edits, including paint / erase controls, red mask coverage preview, persistent brush settings, and XMP round-tripping.
- New watermark layer system with a PNG watermark library, Metal compositing, crop-aware placement, and iCloud-backed storage.
- New anonymizer controls combine distortion, blur, and mosaic for global and mask-based redaction.
- Browser and editing workflows are smoother: split/tabbed browser panes, improved thumbnail spacing, keyboard-driven sports review, and compact edit controls.
- Card import is more flexible, with date-folder skipping, split-shoot subfolders, slow-card thumbnail fallback, and already-imported photo detection.

### Sports lens

- Added a safety-first sports tagging model where detected numbers are stored as reviewable claims instead of silently renaming face groups.
- Added Confirm, Reject, Home / Away assignment, drag-to-person binding, and manual number correction for detected jersey or bib numbers.
- Confirmed sports claims write metadata only while the Sports lens is active; rejected claims stay rejected.
- Added auto-confirm only when an independently identified face agrees with the roster-resolved number.
- Added support for individual-event bib mode, single-team matches, home / away kit colours, and team sport categorisation.
- Added number-crop thumbnails in review rows so photographers can quickly verify ambiguous digits.
- Added team sheet naming from the face-group menu and surfaced Teams management in Settings.
- Improved sports overlay alignment with cropped images and labelled number-derived face groups.

### Brush masks and anonymizer

- Added brush-mask data model, ACR-style `Dabs` XMP read / write support, and preservation of unrecognized Adobe mask corrections to avoid data loss on save.
- Added Metal brush rasterization and compositing so exposure, colour, temperature / tint, and anonymizer adjustments work on painted regions.
- Added bare-B paint mode, brush size / hardness / flow controls, Add / Erase mode, X to toggle add / erase, and one-gesture undo for committed strokes.
- Added additive multi-stroke flow, per-mask opacity handling, symmetric soft erasing, and paste-to-other-images support for brush masks.
- Added red coverage overlay for masks and improved add-mask controls with separate radial and brush buttons.
- Expanded anonymizer redaction with resolution-relative mosaic, blur / distortion layering, and support for mask-specific temperature / tint.

### Watermarks

- Added a watermark library for PNG assets, including local storage, iCloud coordination, and dedicated management UI.
- Added GPU-composited watermark layers in the edit view, with controls for placement, scale, opacity, and visibility.
- Fixed watermark aspect and scaling when crop editing is active.

### RAW editing, previews, and browser

- Added RAW decoding settings for decode profile and decoder version.
- Added a global Density adjustment and compacted edit slider controls.
- Improved edited RAW thumbnail generation by using the real RAW pipeline, off-main finalization, decode caps, and cancellable prefetch.
- Added split / tab browser panes with a stable divider and less face-bar flicker.
- Updated the thumbnail grid to fill rows evenly.
- Added a collapsible full-screen keyboard-shortcut hint card.
- Improved cropped edit zoom rendering and full-screen orientation cache reuse.
- Fixed RAW white balance first-touch shifts and endpoint-only tone curves.
- Restored grid focus after closing the template palette.
- Kept sidebar subfolder lists in sync with changes on disk.

### Import and upload

- Added per-date-folder import checkboxes so individual days can be skipped before copying from a card.
- Added an option to place split shoots inside the date folder (`date / Shoot 1`, `date / Shoot 2`) instead of creating sibling date folders, and remembered that preference across sessions.
- Added automatic detection for previously imported photos using stable source fingerprints, with a toggle to skip those files even when importing to a different destination.
- Import preview thumbnails now prefetch by default, but switch to hover/on-demand loading and warn the user when card thumbnail generation takes more than 10 seconds.
- Added a quit warning while import, upload, or upload rendering is still running.

### Metadata and templates

- Added metadata date-format aliases and expanded template variable editing.
- Added synonym selection for structured keywords.
- Improved metadata panel resizing.
- Expanded IPTC parsing / serialization coverage and metadata engine concurrency tests.

### Bug fixes and reliability

- Gated sports number-derived metadata to the Sports lens.
- Fixed cropped edit zoom rendering, RAW full-screen orientation caching, and orientation cache reuse.
- Fixed watermark scaling and aspect handling during crop workflows.
- Fixed RAW white balance first-touch shifts and endpoint-only tone curve persistence.
- Improved small safety issues across editing, metadata, and view-model code.
- Added targeted test coverage for sports tagging, watermarks, brush rendering, IPTC metadata, tone curves, thumbnail/full-screen cache behavior, and metadata concurrency.

## 2.0.1 — 2026-06-23

### Highlights

- Fixed "Remove All IPTC Metadata" leaving embedded XMP behind — IPTC and XMP are now fully stripped from JPEG, PNG, and JPEG XL files.

### Bug fixes

- **Remove All IPTC Metadata** previously cleared the IPTC block but left the embedded XMP packet intact, so descriptive fields (keywords, title, creator, headline, …) survived the operation. Fixed in the bundled SwiftExif 1.9.9 metadata engine, which now removes the XMP segment / chunk / box whenever metadata is stripped.

## 2.0.0 — 2026-06-23

### Highlights

- Native pure-Swift metadata engine replaces the ExifTool subprocess — faster, no external binary, no per-call process overhead.
- Rebuilt face recognition with a bundled on-device model and improved, fully editable face grouping — Known People suggestions, eye-aligned crops, and a dedicated Unmatched group.
- Ingest verification with dual-destination backup, plus PhotoMechanic-style cull shortcuts for faster culling sessions.
- Per-color HSL (Hue / Saturation / Density) adjustments matched to the vectorscope channels.
- CIE 1931 chromaticity scope with HDR-aware display gamut and target-gamut soft proofing.
- New app icon.

### Native metadata engine

Replaced ExifTool with **SwiftExif**, a pure-Swift in-process engine. Metadata reads and writes no longer spawn subprocesses, eliminating per-call startup cost and removing the external binary dependency.

- Mirror to both IPTC and XMP automatically on every save.
- New `{seq}` sequence variable and explicit date-format support in templates (e.g. `{date:yyyy-MM-dd}`).
- Copy and paste metadata between images.
- New **Variable Reference** menu item lists every supported template variable.
- Recent folders quick access and richer subfolder management.
- Browser search now matches IPTC metadata fields in addition to filenames.
- Option to automatically include the Job ID as a keyword during variable processing.
- Pre-upload IPTC check warns when required fields are missing before sending to FTP / SFTP.
- IPTC `CodedCharacterSet` is now correctly tagged so Nordic characters round-trip through other apps.
- All metadata-loading paths consolidated through a single overload; batch reads parallelized off the main actor.

### Camera RAW & local adjustments

- **HDR / EDR rendering** in both edit and full-screen views, with auto-detection of HDR images. The H key toggles HDR (previously Cmd+H, which conflicted with the system Hide shortcut).
- **ACR-matching mask tones** and the full set of previously-missing local adjustment sliders.
- **Per-color HSL** (Hue / Saturation / Density) below the tone curve, with hue range tuned to ±25 and widened Gaussian sigma to reduce harsh edges at the extremes.
- **Cmd+D** mutes the selected mask, or — on Global with no mask selected — mutes the global layer while keeping mask effects visible.
- As-shot white balance read directly from RAW files via `CIRAWFilter` and propagated through all rendering paths.
- RAW first-frame preview uploads straight to Metal for immediate WB and tonal feedback while the full-resolution decode continues in the background.
- Edited thumbnails update with crop preview when leaving the edit workspace; dual cache for edited vs. unedited variants.
- Metal-native viewport replaces the SwiftUI zoom path; cursor-anchored zoom in UV space.
- Tone curve edits now save and load reliably, including the 2-point endpoint-drag case.
- White balance, tint, and tone curve restore correctly from XMP sidecars on folder open and after Cmd+S render.
- Highlight desaturation tuned to reduce magenta cast at extremes.
- Reset Edits now clears CRS data in the sidecar; XMP orientation no longer mismatches after rotation.

### Content Authenticity (C2PA)

> **Experimental preview** — C2PA signing has not yet been verified end-to-end and may change, or be turned off by default, in a future release. It is intentionally kept off the headline feature list above and labelled experimental in the app.

- Sign images with C2PA content credentials. Certificate and private key storage in the macOS Keychain.
- Render-and-sign flow with detailed edit-action manifests and format-aware output folders.
- C2PA RAW edit settings persist in the XMP sidecar across restarts.
- Failed output moves now restore the C2PA backup, so signing cannot silently destroy originals.
- C2PA orientation correction fixed for rotated images.
- More C2PA metadata visible in the overlay (carried over from 1.6.9).

### Ingest & file management

- **Ingest verification** with **dual-destination backup**, so primary and backup copies are checksummed before the source is released.
- **PhotoMechanic-style cull shortcuts** for keyboard-driven culling sessions.
- Non-blocking import with a progress bar, capture-date sorting, and Move to Folder.
- Year-grouped date folders when sorting by date, with Import Title applied automatically.
- Folder drag-and-drop in the sidebar; multi-select photo drag onto a sidebar folder.
- Folder-switch race condition fixed; drag-onto-sidebar freeze (and stalls from blocking I/O on the main actor) resolved.

### Face recognition & Known People

- **Interactive Known People suggestions** with multi-face matching during metadata editing.
- **Per-embedding thumbnails** and sample management UI per known person.
- **Eye-aligned face crops** for more reliable clustering.
- New **Unmatched** faces group with right-click menu, group interactions, and direct drag-to-new-group / ungroup actions.
- Set as Key Art on face groups, scroll-to-group, and a compact face bar layout.
- Cancellation honoured in clustering hot paths; stale `featurePrintCache` entries cleared on person or embedding removal.

### Custom templates

- Custom templates folder location with JSON export and import, so template sets can be moved between machines or shared.

### Scopes & visualization

- **CIE 1931 chromaticity diagram** (Shift+4) with target gamut settings, Adobe RGB gamut, and HDR-aware display gamut indicator.
- **Gamut-clipping soft proof** in both Metal edit and browse views; toggle with the G key (previously C, which conflicted with crop).
- HSL stage added to the Metal scope pipeline; scopes update on D and M key holds; per-section mute toggles.
- CIE 1931 background pre-generated at launch and cached to disk to eliminate slow first render.
- Imaginary-color guard, dimmed sRGB gamut triangle, and corrected Y-flip in the chromaticity scope.

### FTP / SFTP upload

- Smooth upload progress, completion state, and clearly visible error reporting.
- Automatic retry with human-readable error messages.
- Pre-upload IPTC check warns about missing fields before sending.
- Upload overlay no longer shows 0 images on first open.

### Performance

- ExifTool subprocess overhead eliminated for metadata reads and writes.
- Batch metadata reads, sidecar loads, and pending-status refreshes parallelized via `TaskGroup` off the main actor.
- Browser cache rebuilds coalesced; redundant sort / filter / UI rebuilds suppressed during batch metadata loading.
- O(N²) → O(N) write path for RAW + JPEG pairs.
- O(N) → O(1) lookups in face recognition, filmstrip shift-click range selection, and import date-group grouping.
- Hierarchical face clustering uses an in-place distance matrix; lowercased `personShown` / `keywords` cached on `ImageFile` for faster search.
- `NSCache` replaces ad-hoc `Dictionary` + `NSLock` caches in face detection; cost-based cache eviction in the full-screen image cache.
- Task cancellation now propagates correctly through metadata loading, FTP, face recognition, and full-screen preview generation. Subprocesses terminate on cancellation to stop wasted work.

### UI polish

- New app icon.
- Inline color label and star rating filter bars in the toolbar.
- Persistent metadata panel width across sessions.
- Auto-scroll metadata panel; deduplicated keywords and personShown; partial values shown when batch-editing across images.
- Keyboard shortcuts settings tab.
- Licenses settings tab with attribution and full license texts for bundled components (FFmpeg, c2patool, Sparkle, SwiftExif, AuraFace).
- Bundled FFmpeg rebuilt as a minimal image-only GPL build (19 MB, down from 53 MB) with no non-redistributable components.
- Empty-state in the template palette no longer cramped.
- Sidebar chevron only appears for folders that actually have subfolders.
- Full-screen scaling-filter toggle moved to Option+S, freeing bare S for selection.
- Non-image files no longer open in the edit workspace.

### Bug fixes

- Drag-onto-sidebar freeze and main-actor I/O stalls.
- Race conditions in `FullScreenImageCache` preview generation.
- Renderer ExifTool path ignoring user settings; consolidated path resolution.
- XMP orientation mismatch and Reset Edits not clearing sidecar CRS.
- FTP upload overlay showing 0 images on first open.
- Silent metadata loss in batch export, plus cancellation support added.
- Stuck loading overlay when toggling edit preview with E.
- RAW preview aspect ratio stretch; deferred EXIF orientation reads.
- Full-screen black screen on E-key toggle.
- Zoom jump on G, image shift on D, resolution drop on slider release, and RAW draft decode.
- Display gamut not updating on settings change or HDR toggle.
- Metal chromaticity Y-flip and gamut triangles hidden by background.
- Scan cancellation leaving stale UI, silent detection errors, and missing bounds checks.
- Notification observer leak and missing-task cancellation in `BrowserViewModel`.
- Stale `featurePrintCache` entries after person or embedding removal.
- Previously-silent `try?` failures in `FaceDataStorageService` and `FTPViewModel` now log properly.
- Unsafe force casts replaced; metadata reload guarded against unsaved changes.

### Known issues

- Mask XMP compatibility with Adobe Camera Raw is exact only at **Angle = 0**. Rotated radial masks use an undocumented ACR encoding and may render differently in other tools.
- Metadata variables may not always process when the image is signed with C2PA.
- The RAW metadata overlay shows embedded metadata only; XMP-sidecar metadata is not yet listed.
