# Phase 5 OSINT workspace refinement — validation

## Implemented

- Moved the OSINT markup toolbar above the vertical split so dragging the lower evidence pane
  cannot cover or remove access to its controls.
- Replaced separate photo/map tool pickers with one shared tool, color, undo/redo, label, and delete
  bar. The selected photo or map annotation determines which independent history receives edits.
- Added optional text labels to every photo and map annotation kind. Existing dedicated label
  annotations still require non-empty text.
- Expanded stable map links from dedicated photo-label annotations to any labeled photo annotation.
  The persisted `linkedPhotoLabelID` key is retained for schema compatibility.
- Moved Map Layers beside evidence in the lower pane, with selection, visibility, and photo-link
  controls available from each compact row.
- Replaced horizontal time cards with compact vertical disclosure rows. Timestamp provenance,
  precision, timezone status, and delete actions appear only when a row is expanded.
- Added investigator observations without a timestamp as a distinct case-only model and editor.
  Untimed notes appear in the same vertical list with an explicit **No time** status.
- Bumped `AnalysisCase` to schema version 8. Version 7 cases migrate with an empty untimed-note
  collection while preserving map markup and stable links.
- Bumped the immutable report snapshot schema to version 2 and included untimed observations in its
  deterministic frozen inputs.

## Automated validation

Command:

```sh
xcodebuild test \
  -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisCaseTests" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisReportSnapshotTests"
```

Result: 49 tests passed in 2 suites.

Coverage includes:

- version 7 to version 8 migration with map annotation preservation;
- untimed-note validation, persistence, and unchanged source/XMP state;
- report-snapshot capture of untimed observations;
- non-text photo annotation labels as stable map-link targets; and
- existing annotation, map, timestamp, migration, and source-integrity suites.

## Manual validation

1. Open Image Analysis > OSINT, drag the lower divider to both limits, and confirm the shared markup
   bar remains visible and operable.
2. Draw and select markup on each surface. Confirm color, label, delete, undo, and redo apply to the
   active surface and the other surface's history remains unchanged.
3. Label a photo line, rectangle, ellipse, arrow, or distance. Link a map layer to it and confirm the
   current label appears in Map Layers and survives relabeling.
4. Expand and collapse timestamp and untimed-note rows. Confirm collapsed rows remain compact and
   expanded rows show the complete provenance or note.
5. Add an untimed note, reopen the source-bound case, and confirm the note returns without any
   source-byte or XMP change.
