# Phase 2 — Image Analysis shell validation

## Automated coverage

- A new case binds to the exact `SourceImageRevision` SHA-256.
- Reopening unchanged bytes selects the existing case.
- Replacing bytes at the same path surfaces the previous case as source changed rather than
  rebinding it.
- Creating and reopening a case does not change the source bytes or create an XMP sidecar.
- Multi-selection entry follows the last-clicked supported image.
- Entry is unavailable without a selected supported image.

## Manual validation

1. Open a folder, select one supported image, and choose **Image Analysis** from the layout menu.
2. Confirm the workspace opens on **Pixel Analysis**, shows an original preview, and exposes the
   case SHA-256.
3. Switch between **Pixel Analysis** and **OSINT**, close the workspace, reopen the same image, and
   confirm the last mode is restored.
4. For an image with loaded Develop settings, switch between **Original Source** and
   **Developed Preview** and confirm the visible preview and label change together.
5. Select several images, make one the last-clicked item, and confirm Image Analysis opens that
   image without collapsing the browser selection.
6. Replace the selected file's bytes outside the app, reopen Image Analysis, and confirm the
   source-changed banner appears with a deliberate **Create Case for Current Source** action.
7. Use the Close button and Escape key and confirm focus returns to the browser grid.
8. With VoiceOver enabled, confirm the workspace, mode selector, representation selector, source
   hash, source-change warning, and close action have understandable labels.

## Current slice boundary

The source preview, case lifecycle, navigation, and integrity banner are functional. Source facts,
finding details, analyzer progress/cancellation, provenance, and metadata rules are the next Phase 2
slice and are intentionally represented by empty-state panels here.
