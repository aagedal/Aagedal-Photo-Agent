# Phase 10 — named-version workflow validation

## Implemented slice

- Develop shows a source-bound selector containing virtual **Primary (XMP)** and every named
  version in the catalog.
- The in-context menu creates, duplicates, renames, deletes, and marks a default named version;
  the active version shows its adjustment summary and persistence state.
- Named-version edits update the JSON catalog after a 650 ms debounce and surface Unsaved,
  Saving, Saved, and Save Failed states. Application Support fallback storage shows its
  portability warning.
- Switching first snapshots the named version being left and atomically persists that snapshot
  together with the new active selection. The editor changes only after persistence succeeds.
- Applying a destination replaces `editingMetadata.cameraRaw` once, resets the edit undo stack,
  invalidates edited thumbnail/full-screen caches, and refreshes preview, scopes, viewport, and
  Clean Feed state.
- Primary remains an in-memory/XMP-backed virtual entry. Named-version edits clear the metadata
  dirty flag and use `DevelopVersionCatalogRepository`; they do not enter the XMP commit path.
- Changed-source and newer-schema catalogs remain unavailable for editing and show an explicit
  notice instead of being silently applied.

## Automated validation

On 2026-08-09:

```text
xcodebuild build-for-testing -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/DevelopVersionCatalogTests"

Result: TEST BUILD SUCCEEDED
```

```text
xcodebuild test-without-building -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/DevelopVersionCatalogTests"

Result: 10 tests in 1 suite passed
```

The added switch test verifies that the version being left is snapshotted, Primary is never added
to `versions`, a named snapshot restores exactly, and an invalid destination leaves the catalog
unchanged. Existing repository tests continue to verify atomic persistence, XMP isolation,
fallback storage, schema handling, reassociation, and full settings round trips.

## Manual follow-up before Phase 10 exit

- Exercise rapid slider edits followed by named-version switching and image navigation.
- Force folder-local and Application Support write failures and verify the visible version does not
  switch after a failed flush.
- Verify create/duplicate/rename/default/delete menus with VoiceOver and keyboard navigation.
- Confirm crop, masks, LUT layers, watermarks, HDR controls, scopes, and Clean Feed redraw after
  repeated Primary/named switches.
- Verify the remaining Phase 10 work: dependency diagnostics, version comparison, explicit Primary
  promotion/recovery, promotion read-back, and complete navigation/termination failure handling.
