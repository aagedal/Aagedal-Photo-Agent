# SwiftMediaMetadata 3 migration validation

**Date:** 2026-09-02  
**Status:** implementation and automated validation complete

## Scope

Photo Agent now resolves the renamed metadata package directly from
[`aagedal/SwiftMediaMetadata`](https://github.com/aagedal/SwiftMediaMetadata) instead of the checked-in
`Vendor/SwiftExif` snapshot. The Xcode package requirement starts at `3.0.0`; the lockfile currently
resolves tag `3.0.0` at revision `c2d77c2dcefcb997623e52beca57bc61ce302cb9`.

## Application migration

- Replaced the local Xcode package reference and `SwiftExif` product with the remote
  `SwiftMediaMetadata` package and product.
- Migrated application and test imports plus direct module-qualified calls to the renamed module.
- Removed the old 1.9.10 vendored package source.
- Removed the app-owned PLUS Image Supplier XML postprocessor. Version 3 writes the required ordered
  `rdf:Seq` representation itself.
- Removed manual file-creation-date capture and restoration. Version 3 preserves the creation date by
  default as part of its atomic write policy.
- Removed the rendered-TIFF unsafe-RAW override. Version 3 distinguishes raster TIFF output from
  proprietary RAW containers without using a camera Make tag as the deciding signal.
- Replaced the legacy IIM-to-XMP synchronizer plus app-owned title, editorial-role, and Date Created
  repair passes with version 3's standards-aware synchronization policy.
- Updated public architecture, security, licensing, and in-app license references to the new package
  name and repository.

The existing `SwiftExifReadService`, `SwiftExifWriteEngine`, and related adapter type names are internal
application abstractions and remain source-compatible in this migration. Renaming those types is cosmetic
and is intentionally separate from the package relink.

## Automated evidence

- Xcode package resolution succeeded and selected SwiftMediaMetadata `3.0.0`.
- The app and test targets passed `build-for-testing` after the package relink and again after removal of
  the compatibility code. The only emitted diagnostics were pre-existing AppKit event-monitor warnings in
  `EditWorkspaceView.swift`.
- A focused metadata/import selection passed 77 tests with zero failures. It covers editorial supplier
  serialization, IPTC/XMP behavior, raster-TIFF and RAW write boundaries, preservation verification,
  container fixtures, rename metadata, metadata-engine concurrency, and import metadata/voice-memo scans.
- `scripts/ci/validate_repository.sh` passed after the vendored package removal. Generated metadata
  documentation, release metadata, JSON/property-list/project structure, bundled-component provenance,
  privacy logging/surfaces, conflict markers, and whitespace checks were all clean.
- `xcodebuild test -quiet -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS'
  -parallel-testing-enabled NO` passed in 63.247 seconds with zero failures, skips, or expected
  failures. Xcode reports 1,888 logical tests and 2,015 expanded device/configuration executions;
  36 parameterized tests produced 163 runs. Result bundle:
  `Test-Aagedal Photo Agent Tests-2026.09.02_15-29-47-+0200.xcresult`.

## Deliberately deferred package adoption

Version 3 also offers higher-level standards synchronization, `PhotoMetadata`, transactional sidecar,
semantic preservation comparison, carrier-capability, lossless structured-patching, and typed GPS APIs.
The app already has mature workflow-specific policy and evidence around these concerns. Replacing those
layers during the dependency migration would widen risk without being required for correctness. They are
good candidates for small, separately validated reductions of app-owned metadata plumbing.

## Remaining release boundaries

This migration does not close the nine manual, device, external-service, interoperability, performance,
accessibility, and release-packaging gates still open in the 3.0 app-improvement audit. It removes a stale
local dependency and several package workarounds; it does not change the 66-of-75 checklist count.
