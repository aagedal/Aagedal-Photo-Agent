# ADR-004 — Map evidence in exported reports

**Status:** accepted for 2.3  
**Date:** 2026-08-02

## Decision

Version 2.3 reports will not persist or embed Apple Maps tiles, satellite imagery, or MapKit
snapshots. They will include an app-rendered schematic that freezes:

- the exact WGS-84 center and latitude/longitude span;
- the selected live-map style as contextual metadata;
- investigator location evidence; and
- visible case-owned geographic annotations.

The report will state that the figure is a schematic without embedded Apple imagery and will
include an `https://maps.apple.com` reference for reopening the captured viewport in the live
service. The snapshot records when this evidence was frozen. It does not claim that the linked live
map will remain visually identical.

## Rationale

`MKMapSnapshotter` is an API for capturing MapKit content, but Apple's current Developer Program
License Agreement also treats snapshot content as part of the Apple Maps Service. Attachment 6
restricts copying, publishing, public display, caching, and storage of Map Data except where Apple
expressly permits it. The native MapKit documentation does not expressly grant redistribution of a
snapshot inside a durable, shareable PDF.

A schematic preserves the report's evidentiary requirements without treating a transient MapKit
health-check image as a redistributable asset. It is reproducible offline, carries no third-party
tile attribution, and makes the distinction between case evidence and provider context explicit.

## Consequences

- Live satellite/hybrid imagery remains available in the analysis workspace.
- The report renderer must project case coordinates into the frozen viewport itself.
- Provider place names remain evidence with their recorded provenance; they are not rendered as a
  provider basemap.
- A future imagery-export option requires written terms or other explicit permission plus a new ADR.
- The existing availability probe remains temporary and is never persisted or exported.

## Primary references reviewed

- Apple Developer Program License Agreement, Attachment 6, especially sections 2.1–2.5.
- `MKMapSnapshotter` documentation.
- Apple Maps unified/map-link documentation for reopening a coordinate and span.
