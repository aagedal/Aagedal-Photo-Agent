# Phase 5 OSINT map slice — validation

## Implemented

- Added a source-bound map state with a persisted satellite/hybrid style and camera viewport.
- Bumped `AnalysisCase` to schema version 7. Version 6 map cases migrate with an empty map-markup
  collection, version 5 timeline cases migrate with a default map state, and earlier analyzer,
  markup, calibration, link, and timeline migrations remain intact.
- Display embedded source GPS as blue source evidence without copying it into editable case state.
- Added one orange investigator location with explicit entered-coordinate, place-search, or
  map-center provenance.
- Reused the shared DD/DMS/DDM `CoordinateParser`, existing MapKit place-search completer, and the
  configured online/offline `GeocodingService`.
- Preserve whether a displayed place name came from the selected search result or a reverse
  geocoder. A place name never replaces the coordinate evidence or its origin.
- Added direct map-center pinning, coordinate entry, place search, reverse naming, pin removal,
  embedded/investigator evidence cards, and source-changed read-only behavior.
- Kept viewport and investigator location writes inside `AnalysisCaseRepository`. The analysis map
  has no dependency on metadata writers, and its UI explicitly states that source and sidecar GPS
  remain unchanged.
- Added case-owned marker, line, polygon, geographic-distance, and label annotations with stable
  UUIDs, validated geographic geometry, shared accessible palette colors, visibility, selection,
  deletion, and an independent bounded undo/redo history.
- Added a map-center authoring workflow that keeps MapKit pan/zoom gestures available and gives
  keyboard and assistive-technology users explicit start, endpoint, vertex, and finish actions.
- Added stable links from map annotations to photo-label UUIDs. Link display resolves current label
  text but preserves a missing UUID rather than silently discarding evidence when a label is
  temporarily unavailable.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisCaseTests"
```

Result: 41 tests passed in 1 suite.

Map-specific coverage includes:

- version 5 timeline migration and version 6 map-state migration with evidence preservation;
- map style, viewport, place provenance, and coordinate persistence;
- every map-markup geometry kind, stable photo-label references, visibility, validation, bounded
  undo/redo, and geographic distance calculation;
- unchanged source bytes and absence of a newly written XMP sidecar after map persistence; and
- rejection of non-finite, out-of-range, or degenerate map coordinates and viewports.

## Remaining Phase 5 work

- Add explicit offline/network/no-imagery map states.
- Resolve report snapshot/attribution requirements and capture attribution-compliant evidence.
- Decide the conditional sun/shadow analyzer gate.
