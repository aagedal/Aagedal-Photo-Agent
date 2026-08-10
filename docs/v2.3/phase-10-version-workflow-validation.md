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
- Filmstrip clicks, arrow-key image navigation, workspace exits, and app termination now await the
  same active-version flush contract. Failed navigation or workspace saves retain the current
  selection; failed termination offers **Keep App Open** or an explicit **Quit Without Saving**.
- Toolbar/layout transitions out of Develop also use the registered flush contract rather than
  relying on a non-blocking `onDisappear` write.
- Applying a destination replaces `editingMetadata.cameraRaw` once, resets the edit undo stack,
  invalidates edited thumbnail/full-screen caches, and refreshes preview, scopes, viewport, and
  Clean Feed state.
- New snapshots hash referenced watermark PNG bytes. The version menu and active-version summary
  distinguish missing and content-changed watermarks without making legacy, unhashed snapshots
  unreadable. Duplicating a version preserves its original dependency contract.
- Primary remains an in-memory/XMP-backed virtual entry. Named-version edits clear the metadata
  dirty flag and use `DevelopVersionCatalogRepository`; they do not enter the XMP commit path.
- Changed-source and newer-schema catalogs remain unavailable for editing and show an explicit
  notice instead of being silently applied.

## Automated validation

On 2026-08-11:

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

Result: 13 tests in 1 suite passed
```

The switch test verifies that the version being left is snapshotted, Primary is never added to
`versions`, a named snapshot restores exactly, and an invalid destination leaves the catalog
unchanged. Dependency tests distinguish matching, changed, missing, and legacy-unhashed watermark
states. The flush-coordinator test verifies failure forwarding, stale-registration safety, and the
no-active-workspace success path. Existing repository tests continue to verify atomic
persistence, XMP isolation, fallback storage, schema handling, reassociation, and full settings
round trips.

## Manual follow-up before Phase 10 exit

- Exercise rapid slider edits followed by named-version switching and image navigation.
- Force folder-local and Application Support write failures and verify the visible version does not
  switch after a failed flush.
- Force a quit-time write failure and verify both **Keep App Open** and explicit
  **Quit Without Saving** choices.
- Verify create/duplicate/rename/default/delete menus with VoiceOver and keyboard navigation.
- Confirm crop, masks, LUT layers, watermarks, HDR controls, scopes, and Clean Feed redraw after
  repeated Primary/named switches.
- Verify the remaining Phase 10 work: version comparison, explicit Primary promotion/recovery, and
  promotion read-back.
