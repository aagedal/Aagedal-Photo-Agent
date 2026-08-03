# Phase 2 — Image Analysis shell validation

## Automated coverage

- A new case binds to the exact `SourceImageRevision` SHA-256.
- Reopening unchanged bytes selects the existing case.
- Replacing bytes at the same path surfaces the previous case as source changed rather than
  rebinding it.
- Creating and reopening a case does not change the source bytes or create an XMP sidecar.
- Multi-selection entry follows the last-clicked supported image.
- Entry is unavailable without a selected supported image.
- Analyzer cache identity includes source SHA-256, analyzer ID/version, and sorted parameters.
- Runner cancellation is published as state rather than as an evidence finding.
- Existing schema-1 shell cases migrate to schema 2 with an empty analyzer cache.
- Raw values from conflicting metadata namespaces remain separate evidence entries.
- C2PA cryptographic validity and signer trust remain separate states.
- Running source-facts analysis leaves source bytes and the folder's sidecar set unchanged.

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
9. Confirm **Source Facts** shows container, dimensions, capture fields, C2PA validity/trust, and
   raw metadata while analysis is running or complete.
10. Cancel the analyzer, confirm the cancelled state offers **Run Again**, then rerun it and confirm
    progress reaches completion.
11. Select findings of each available severity and confirm the plain-language observation,
    technical detail, alternatives/limitations, analyzer version, and report-inclusion toggle are
    understandable.
12. Reopen the unchanged image and confirm the completed source-facts result appears without rerun.

## Phase 2 boundary

The source preview, case lifecycle, navigation, integrity banner, fast analyzer runner, source
facts, raw metadata evidence, C2PA state, metadata consistency findings, and finding detail are
functional. Pixel-derived views, larger scopes, linked hover inspection, and derived-view caching
begin in Phase 3.
