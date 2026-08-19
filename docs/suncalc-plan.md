# SunCalc-style solar overlay implementation plan

> Project planning index: [README.md](README.md)

## Status

**Proposed post-2.3 feature.** This plan replaces the previously rejected broad sun/shadow analyzer
with a narrower first release: an offline solar-position overlay with explicit inputs, reproducible
calculations, and conservative evidence language.

The first release is not an authenticity verdict, a capture-time inference tool, or a simulation of
real shadows cast by terrain and structures.

## Goal

Add an app-owned Swift implementation to the OSINT map that lets an investigator select a known
location and timezone-qualified instant, inspect the calculated position of the Sun, and visualize
the corresponding directions on both Apple Maps and OpenStreetMap.

The feature must:

- calculate locally without a service or network dependency;
- preserve the provenance and uncertainty of location and time inputs;
- never interpret timezone-unknown metadata using the Mac's current timezone;
- distinguish the direction toward the Sun from the expected opposite shadow direction;
- persist enough input, method, and output data to reproduce a reported calculation; and
- avoid implying that a direction overlay models terrain, buildings, weather, or the photographed
  scene.

## Version 1 scope

### Inputs

- The case's explicit Photo Location (`AnalysisMapState.investigationLocation`). Embedded GPS may
  be used after the existing explicit **Set as Photo Location** action records that provenance.
- A timezone-qualified capture, GPS, or user-entered timeline timestamp; or
- A manually entered case-only date, time, and UTC offset.

The UI must not enable a calculation until both the coordinate and an absolute instant are valid.
Day-only timestamps and timezone-unknown wall-clock timestamps are insufficient.

### Calculated values

- Solar azimuth in degrees clockwise from true north.
- Geometric solar elevation.
- Apparent, refraction-adjusted solar elevation.
- Sunrise, solar noon, and sunset for the selected civil day when those events occur.
- Sunrise and sunset azimuths.
- Explicit polar-day, polar-night, and Sun-below-horizon states.

### Map presentation

- A solid yellow direction-to-Sun ray.
- A dashed neutral or purple ray exactly 180 degrees opposite the Sun, labelled **Expected shadow
  direction**.
- Subdued sunrise and sunset bearing rays.
- A compact legend with selected local time, UTC offset, azimuth, and apparent elevation.
- A time-of-day slider that updates the derived overlay without creating annotation history.

All rays are direction indicators. Their displayed geographic length is derived from the visible
map span and must not be described as a measured or predicted ground distance.

### Persistence and reports

- Persist the selected time, UTC offset, optional source-evidence link, visibility settings, and
  calculation-method version.
- Recompute display geometry from persisted calculation inputs rather than storing editable map
  annotations.
- Freeze calculation inputs and outputs in `AnalysisReportSnapshot`.
- Draw the same direction rays in report map figures and include a compact solar-calculation table.
- State the flat, unobstructed-horizon and atmospheric assumptions in report methodology and
  limitations.

## Explicitly out of scope for version 1

- Inferring or validating a capture time from a photographed shadow.
- Object-height entry or physical shadow-length calculation.
- Image-space shadow measurement or camera-orientation comparison.
- Terrain, elevation-model, building, vegetation, or horizon-obstruction simulation.
- Weather or historical-atmosphere lookup.
- Golden hour, blue hour, Moon position, or other astronomical bodies.
- Automatic findings, confidence scores, or authenticity conclusions.

## Calculation conventions

- Coordinates use WGS 84.
- Instants are calculated from explicit Gregorian components and UTC offset.
- Azimuth is normalized to `0..<360`, clockwise from true north.
- Positive elevation is above the astronomical horizon.
- The direction toward the Sun uses the calculated solar azimuth.
- Expected shadow direction is `solarAzimuth + 180`, normalized to `0..<360`.
- Sunrise and sunset use the documented apparent-horizon altitude convention selected by the
  calculator implementation.
- The calculation method is versioned. A method change must not silently alter the meaning of an
  existing report.

The implementation should be original Swift based on published Meeus/NOAA equations. Do not add a
runtime package or embed JavaScript. Record the equations, constants, refraction model, valid date
range, numerical tolerances, and reference fixtures in source documentation.

## Proposed model

Add a dedicated model rather than encoding solar output as `AnalysisMapAnnotation`:

```swift
nonisolated struct AnalysisSolarOverlayState: Codable, Equatable, Sendable {
    var isVisible: Bool
    var timestamp: AnalysisTimestampValue
    var linkedTimestampEvidenceID: UUID?
    var showsSunDirection: Bool
    var showsShadowDirection: Bool
    var showsSunriseDirection: Bool
    var showsSunsetDirection: Bool
    var calculationMethod: AnalysisSolarCalculationMethod
}

nonisolated enum AnalysisSolarCalculationMethod: String, Codable, Sendable {
    case meeusNOAAV1
}
```

Validation must require:

- a timezone-qualified timestamp;
- minute, second, or subsecond precision;
- a supported calculation-method value; and
- a linked timestamp UUID only as provenance, not as the sole copy of the calculation input.

If linked timeline evidence is later removed, retain the frozen timestamp and mark the link as
unavailable. This matches the existing behavior for stable annotation references.

`AnalysisMapState` owns the optional solar state because its coordinate input is the case Photo
Location. Changing or removing that location should update the result or make the overlay
unavailable without fabricating a replacement coordinate.

## Proposed calculation API

Create a pure, Foundation-only calculator:

```swift
nonisolated struct AnalysisSolarInput: Equatable, Sendable {
    let instant: Date
    let coordinate: AnalysisGeoCoordinate
}

nonisolated struct AnalysisSolarPosition: Equatable, Sendable {
    let azimuthDegrees: Double
    let geometricElevationDegrees: Double
    let apparentElevationDegrees: Double
}

nonisolated struct AnalysisSolarDay: Equatable, Sendable {
    let position: AnalysisSolarPosition
    let sunrise: AnalysisSolarEvent?
    let solarNoon: AnalysisSolarEvent
    let sunset: AnalysisSolarEvent?
    let polarCondition: AnalysisSolarPolarCondition?
    let method: AnalysisSolarCalculationMethod
}

nonisolated enum AnalysisSolarPositionCalculator {
    static func calculate(
        input: AnalysisSolarInput,
        civilDayOffsetMinutes: Int
    ) throws -> AnalysisSolarDay
}
```

The calculator must not read `TimeZone.current`, locale, map state, SwiftUI state, or the network.
Rise and set events should use a bounded iterative solve or bisection with documented convergence
limits rather than coarse minute-by-minute sampling.

## Delivery phases

### Phase 1 — calculation contract and fixtures

**Exit gate:** solar position and event calculations pass the reference corpus independently of UI
and persistence.

- [ ] Write the calculation-conventions note and choose the supported date range.
- [ ] Add reference fixtures from published NOAA/NREL examples and record their provenance.
- [ ] Implement Julian date/time conversion without using the current timezone.
- [ ] Implement solar coordinates, local hour angle, azimuth, and elevation.
- [ ] Implement the documented atmospheric-refraction correction.
- [ ] Implement sunrise, solar-noon, sunset, and polar-condition solving.
- [ ] Add invalid-input and non-convergence errors with useful descriptions.
- [ ] Verify repeatability and Swift 6 concurrency safety.

### Phase 2 — state, validation, and migration

**Exit gate:** solar settings round-trip without modifying source media and all version-8 cases
migrate with the overlay disabled.

- [ ] Add `AnalysisSolarOverlayState` and calculation-method types.
- [ ] Add optional solar state to `AnalysisMapState` and its validation.
- [ ] Bump `AnalysisCase.currentSchemaVersion` from 8 to 9.
- [ ] Add an explicit version-8 migration with `solarOverlay = nil`.
- [ ] Add `AnalysisCase` mutations for setting and clearing solar state.
- [ ] Add `AnalysisWorkspaceModel` mutations routed through the existing repository.
- [ ] Preserve source-changed read-only behavior.
- [ ] Add round-trip, invalid-state, migration, unchanged-source, and no-sidecar-write tests.

### Phase 3 — OSINT controls

**Exit gate:** a keyboard user can create, adjust, hide, and remove a valid calculation without any
implicit timezone assumption.

- [ ] Pass eligible timeline evidence into `AnalysisMapEvidenceView`.
- [ ] Add a Solar Position button beside the field-of-view control.
- [ ] Build a focused `AnalysisSolarControls` popover.
- [ ] Show Photo Location coordinate and provenance as a read-only input.
- [ ] Offer only timezone-qualified, minute-or-better timeline rows in the source picker.
- [ ] Add manual date, time, and explicit UTC-offset controls.
- [ ] Add a **Use Capture Time** action only when capture evidence resolves to an instant.
- [ ] Add a selected-civil-day time slider.
- [ ] Show solar values, events, polar states, and calculation limitations.
- [ ] Add per-ray visibility controls and a clear/remove action.
- [ ] Add accessibility labels, help text, focus order, and keyboard adjustment behavior.

### Phase 4 — live map rendering

**Exit gate:** Apple and OpenStreetMap styles render equivalent derived geometry while all current
map interactions continue to work.

- [ ] Extract or share the existing great-circle destination-coordinate helper used by the
  field-of-view cone.
- [ ] Derive a legible ray length from the visible region rather than persisting a distance.
- [ ] Add solar polylines and legend content to the SwiftUI `Map` path.
- [ ] Pass a small derived render model into `AnalysisOpenStreetMapView`.
- [ ] Add dedicated `MKPolyline` types and renderers above OSM tiles.
- [ ] Keep solar geometry out of map annotation selection, layer undo, and evidence counts.
- [ ] Verify panning, zooming, selection, map rotation, pitch, and style switching.
- [ ] Avoid recalculating rise/set events unnecessarily during slider movement.

### Phase 5 — immutable report evidence

**Exit gate:** a report freezes and explains the same solar calculation shown in the workspace.

- [ ] Add frozen solar input and output data to `AnalysisReportMapEvidence`.
- [ ] Verify the frozen output against a fresh calculation during snapshot creation.
- [ ] Draw solar, shadow-direction, sunrise, and sunset rays in the report map.
- [ ] Add a compact table for time, offset, coordinate provenance, azimuth, elevation, and events.
- [ ] Add calculation method/version to report methodology.
- [ ] Add flat-horizon, obstruction, atmosphere, clock, terrain, and camera-orientation limitations.
- [ ] Add deterministic snapshot, report-structure, and report-rendering tests.

### Phase 6 — release validation

**Exit gate:** the feature is numerically bounded, accessible, reproducible, and does not regress
existing OSINT behavior.

- [ ] Run calculator fixtures on supported macOS architectures.
- [ ] Test equatorial, mid-latitude, high-latitude, polar-day, and polar-night cases.
- [ ] Test leap day, date-line, positive/negative UTC offset, and DST-transition inputs.
- [ ] Test missing location, removed location, missing linked evidence, and source-changed cases.
- [ ] Test rapid slider movement and repeated map-style switching.
- [ ] Test Apple standard, muted, hybrid, satellite, and OpenStreetMap styles.
- [ ] Test rotated and pitched maps.
- [ ] Verify fully offline operation after cached map content is unavailable.
- [ ] Complete keyboard-only and VoiceOver review.
- [ ] Render A4 and US Letter reports and visually compare rays and values with the live workspace.
- [ ] Update the OSINT validation document with the approved scope and measured tolerances.

## Reference-test coverage

The unit corpus should include at least:

- a published NREL SPA reference instant;
- a published NOAA calculator example;
- Oslo summer and winter cases;
- an equatorial equinox case;
- locations above and below 72 degrees latitude;
- polar day and polar night;
- sunrise/sunset absence;
- Sun below horizon;
- the international date line;
- UTC-12, UTC, and UTC+14 offsets;
- leap day; and
- invariant tests for angle normalization and opposite shadow direction.

Record expected-value source, source retrieval date, input conventions, and permitted tolerance
with every fixture. Tests must not call online calculators.

## Acceptance criteria

- A user cannot enable the overlay without a valid Photo Location and absolute instant.
- A timezone-less EXIF timestamp is never interpreted using the machine timezone.
- The same inputs produce identical persisted and reported numeric outputs.
- Apple Maps and OpenStreetMap show the same true-north directions.
- Sun-below-horizon and polar conditions are explicit and do not display misleading active-sun rays.
- Direction-ray length is never presented as shadow length or map distance.
- Removing linked timeline evidence does not erase the frozen calculation input.
- Changing/removing Photo Location does not retain a silently stale coordinate.
- Slider changes do not create map-annotation undo entries.
- Source image bytes and metadata sidecars remain unchanged.
- Reports disclose the calculation method, input provenance, and material limitations.
- Existing map annotation, field-of-view, availability, and export tests continue to pass.

## Expected implementation surface

New files:

- `Aagedal Photo Agent/Models/AnalysisSolarState.swift`
- `Aagedal Photo Agent/Services/AnalysisSolarPositionCalculator.swift`
- `Aagedal Photo Agent/Views/Analysis/AnalysisSolarControls.swift`
- `Aagedal Photo Agent Tests/AnalysisSolarPositionCalculatorTests.swift`

Primary edits:

- `Aagedal Photo Agent/Models/AnalysisMapState.swift`
- `Aagedal Photo Agent/Models/AnalysisCase.swift`
- `Aagedal Photo Agent/ViewModels/AnalysisWorkspaceModel.swift`
- `Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift`
- `Aagedal Photo Agent/Views/Analysis/AnalysisMapEvidenceView.swift`
- `Aagedal Photo Agent/Views/Analysis/AnalysisOpenStreetMapView.swift`
- `Aagedal Photo Agent/Models/AnalysisReportSnapshot.swift`
- `Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift`
- `Aagedal Photo Agent Tests/AnalysisCaseTests.swift`
- `Aagedal Photo Agent Tests/AnalysisReportSnapshotTests.swift`

## Estimate

- Calculation core and fixtures: 2 days.
- Persistence and migration: 1 day.
- Controls and timeline integration: 1.5–2 days.
- Apple/OSM rendering: 1–1.5 days.
- Report snapshot and PDF rendering: 1–1.5 days.
- Accessibility, manual validation, and documentation: 1–2 days.

Expected total: **8–10 engineering days** for the report-backed first version, or approximately
**5–6 days** for a map-only slice.

## Follow-up gate

Do not extend this feature into shadow-length comparison or capture-time consistency findings until
a separate decision defines:

- image measurement and object-height calibration;
- timestamp and clock-error uncertainty propagation;
- camera orientation and perspective assumptions;
- ground-plane, terrain, and horizon assumptions;
- a redistributable validation corpus; and
- evidence language for ranges and inconclusive results.

That later gate must treat calculated solar direction as one input to an investigator's reasoning,
not as proof of location, time, manipulation, or intent.
