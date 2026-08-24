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
- Added a live connectivity monitor and cancellable MapKit snapshot probe for the visible region.
  Offline connectivity, connected request failures, and missing satellite imagery now have distinct
  accessible banners with retry behavior; the health-check snapshot is never persisted or exported.
- Kept coordinate entry and existing case evidence available offline, disabled only the online place
  search, and surfaced autocomplete failures that the shared search completer previously discarded.
- Recorded ADR-004 after reviewing Apple's current Developer Program License Agreement and MapKit
  documentation. Reports freeze the exact viewport and visible geographic evidence for a WGS-84
  schematic, state that no Apple map imagery is embedded, and include a live Apple Maps reference.
  The MapKit snapshot probe remains temporary and is not reused as report content.
- Did not approve a sun/shadow analyzer for 2.3. A defensible implementation still needs explicit
  terrain/elevation assumptions, timezone and clock uncertainty, shadow measurement calibration,
  and a validation corpus; a nominal solar bearing without those inputs would overstate the case.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisCaseTests"
```

Result: 42 tests passed in 1 suite.

Map-specific coverage includes:

- version 5 timeline migration and version 6 map-state migration with evidence preservation;
- map style, viewport, place provenance, and coordinate persistence;
- every map-markup geometry kind, stable photo-label references, visibility, validation, bounded
  undo/redo, and geographic distance calculation;
- unchanged source bytes and absence of a newly written XMP sidecar after map persistence; and
- rejection of non-finite, out-of-range, or degenerate map coordinates and viewports.
- deterministic classification and user-facing recovery text for offline, network-failure, and
  no-imagery states.

## Manual availability validation

1. Open Image Analysis > OSINT with a connected network. Pan or change map style and confirm the
   availability probe completes without obstructing map controls.
2. Disable the active network interface. Confirm the map displays **Map is offline**, place search
   is disabled with an explanation, and coordinate entry, saved pins, and map layers remain usable.
3. Restore the network. Confirm the current visible region retries automatically and the offline
   banner clears after MapKit returns imagery.
4. Exercise a failed place search and confirm its error appears below the evidence controls rather
   than silently clearing the result list.
5. Trigger Retry in a connected failure state and confirm only the temporary health-check snapshot
   is requested; no map image is added to the case JSON or source folder.

## Phase 5 disposition

- Automated map/timeline/report-evidence foundations are complete.
- Manual fixture-corpus, keyboard, and VoiceOver validation remains part of the cross-phase release
  hardening pass.
- Sun/shadow analysis remains a post-2.3 conditional feature unless a later gate supplies the
  required assumptions and validation evidence.

## 3.0 follow-on — approved solar-position scope

The 3.0 workstream subsequently approved the narrower offline solar-position overlay documented in
the [solar implementation plan](../suncalc-plan.md) and
[calculation contract](../solar-calculation-conventions.md). It is not the broad sun/shadow analyzer
rejected for 2.3: it calculates true-north Sun and opposite expected-shadow directions from an
explicit WGS 84 Photo Location and timezone-qualified instant. It does not infer capture time,
measure photographed shadows, compare camera orientation, or model terrain, buildings, vegetation,
weather, or horizon obstructions. A separately labelled reference-object shadow-length estimate is
limited to a vertical object on level ground.

`meeusNOAAV1` is bounded to civil years 1800–2100. The executable reference fixtures allow 0.03
degree for the NREL position comparison and two minutes for the Greenwich NOAA rise/noon/set
comparison. NOAA's real-world rise/set guidance remains approximately one minute within ±72 degrees
latitude and approximately ten minutes outside that band, before atmospheric and horizon effects;
the UI and report limitations disclose those constraints.

On 2026-08-23, arm64 macOS runs passed all 22 solar-calculator methods (26 parameterized
invocations), three focused solar lifecycle/reproduction/report tests, and all 62 Analysis Case
tests. Coverage includes the equator, mid- and high latitudes, both hemispheres above 72 degrees,
polar day/night, leap day, the international date line, UTC-12/UTC/UTC+14, explicit offsets across
a DST transition, removed/replaced location, removed timestamp provenance, source-changed behavior,
all persisted map-style states sharing derived geometry, and structural solar report assertions for
A4 and US Letter.

Still manual for the 3.0 gate: rapid slider and actual style switching, rotated/pitched maps,
uncached offline behavior, keyboard-only and VoiceOver review, and visual live/report ray
comparison. The arm64 automated run covers the product's Apple-Silicon-only architecture support.
