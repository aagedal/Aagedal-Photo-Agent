# Investigation security/privacy review — 2026-08-25

## Disposition

The locally automatable review of unified logs, temporary files, map requests, and analysis PDF
reports is complete. Two concrete privacy weaknesses were corrected: report export previously
opted users into exact coordinates, raw metadata, and a network map by default; and both
OpenStreetMap clients used the default persistent URL cache.

The Phase 12 checklist item remains open. Static evidence cannot substitute for a release-candidate
runtime log capture, crash/interruption residue inspection, or a network-proxy capture of the
MapKit and OpenStreetMap workflows. Those limitations are listed explicitly below.

## Automated evidence

### Unified logs

The existing fail-closed gate in `scripts/ci/validate_logger_privacy.py` scans every application
Swift file and rejects explicit public interpolation except a narrow reviewed allowlist for
non-identifying operational values. Its negative self-test covers public paths, filenames,
identifiers, metadata, destinations, subprocess arguments, and localized errors. The detailed
classification and privacy-manifest result remain in
[Logger privacy and privacy-manifest validation](logger-privacy-and-manifest-validation.md).

At review time the source inventory contained 67 `Logger` constructions and 257 lexical severity
calls across 338 application Swift files. No new privacy exemption was added by this review.

### Temporary files

A repository scan found direct `FileManager.temporaryDirectory` use in 12 application Swift files.
The higher-sensitivity paths were inspected directly:

- analysis-project import/export uses UUID-named staging directories and removes them with `defer`
  on both successful and throwing paths;
- report output is assembled in memory and written to the user-selected destination with an atomic
  Foundation write, so it creates no app-owned durable report intermediate;
- advanced-export previews retain a UUID-named folder only for the preview lifetime and remove it
  in `AdvancedExportPreviewStorage.deinit`;
- AVIF/JXL intermediates and C2PA manifest/output/ingredient files use randomized names and
  explicit deferred cleanup; and
- FTP credentials are created with `open(... O_CREAT | O_EXCL, 0o600)`, never placed in the process
  argument list, and removed after upload or connection testing.

The new investigation gate locks the unpredictable project-archive staging names, success/error
cleanup, owner-only FTP credential permissions, and credential cleanup. Existing focused archive,
FTP, C2PA, and export tests continue to own their functional behavior.

### Map requests

The investigation workspace has four intentional online request classes:

| Request | Information sent | Persistence/disclosure control |
|---|---|---|
| Apple MapKit display and availability probe | visible region and selected map style | transient framework content; the probe is not persisted or exported |
| Apple place search/autocomplete | investigator-entered query plus visible search region | initiated by search text/action; selected result provenance is stored in the case |
| Apple reverse geocoding | selected coordinate and requested locale | user invokes naming; an offline GeoNames setting is available |
| OpenStreetMap live/report tiles | standard HTTPS `z/x/y` tile coordinates, app version in User-Agent | exact reviewed origin, required attribution, and now ephemeral cache-free URL sessions |

Report export now defaults to the offline coordinate schematic. Selecting OpenStreetMap displays a
warning that the visible region is sent as tile coordinates to OpenStreetMap. Both the live map and
the report snapshotter use `URLSessionConfiguration.ephemeral`, set `urlCache = nil`, and ignore
local cached data, preventing a durable app URL-cache history of viewed regions.

### Reports

Both the export options model and its UI now default canonical path, camera serial number, exact
coordinates/live-map link, and raw metadata to omitted. The map background defaults to the offline
schematic. Users can deliberately include each sensitive class; the export sheet retains its
sharing warning. Rendering filters location/path/serial keys from an explicitly enabled raw
metadata appendix when the corresponding sensitive field is still disabled. Existing report tests
exercise source re-hashing, immutable snapshots, sensitive-value omission, raw-metadata exclusion,
atomic destination behavior, and A4/US Letter structure.

### New fail-closed gate

`scripts/ci/validate_investigation_privacy.py` checks 22 reviewed invariants across report defaults
and atomic writes, the two OpenStreetMap clients, project-archive staging cleanup, and FTP
credential files. `scripts/ci/test_investigation_privacy_validator.py` first validates current
source, then proves that regressions to coordinate defaults, report-map caching, live-map session
persistence, and credential-file permissions fail. Both commands now run from
`scripts/ci/validate_repository.sh`.

Local results:

```text
investigation privacy validator self-test passed (positive plus 4 regressions)
investigation privacy validation passed (22 invariants)
```

The focused clean-derived-data Xcode run also passed all 14 `AnalysisReportSnapshotTests` methods in
one suite. It covered both paper sizes, the privacy-oriented export options, exact-revision
rejection, immutable snapshots, coordinate/raw-metadata omission, report structure, long content,
crop geometry, and solar evidence. The complete `scripts/ci/validate_repository.sh` command passed
after integration, including both privacy gates, generated-document checks, manifest/property-list
validation, bundled-component provenance, conflict-marker scanning, and `git diff --check`.

## Manual and external limitations

These checks are still required before closing the Phase 12 item:

1. Capture release-build unified logs while importing, face-scanning, editing/exporting, opening
   every map style, searching/reverse-geocoding, generating both report map variants, and delivering
   files. Confirm no path, name, coordinate, query, credential, metadata value, or tool output is
   readable.
2. Cancel and force-terminate project archive, advanced preview, C2PA, AVIF/JXL, FTP, and report
   operations at multiple stages; inspect the app temporary container after restart and verify that
   sensitive residue is absent or safely recovered/removed.
3. Capture traffic with a controlled proxy or packet metadata tool. Verify map/search/geocoder
   requests go only to the OS-selected Apple services or `tile.openstreetmap.org`, use encrypted
   transport, contain no app-added case metadata, and stop promptly after cancellation/navigation.
4. Manually export every combination of sensitive report toggles and inspect both visible PDF text
   and document metadata. Confirm excluded paths, serials, coordinates, live links, and raw keys do
   not survive, and confirm the OpenStreetMap opt-in disclosure and attribution are visible.
5. Reconcile the OpenStreetMap tile and Apple service behavior against current provider terms and
   the final published privacy text; repository inspection cannot provide external legal approval.

Because these are substantive runtime and external-provider checks, the delivery-plan checkbox is
intentionally not marked complete.
