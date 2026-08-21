# Deadline preflight validation

**Validated:** 2026-08-21  
**Scope:** Phase 4 pure, cancellable per-image and per-batch readiness coordinator

## Implemented contract

- `DeadlinePreflightService` evaluates only immutable profile, image, resource, filesystem,
  capability, and delivery snapshots. It performs no filesystem reads, writes, caching, or network
  probes.
- Missing referenced validation profiles, metadata templates, required lists, rename recipes, and
  export configurations are typed blocking issues instead of silently skipped dependencies.
- Per-image checks reuse `MetadataValidationEngine` and `RenamePlanningService`, report unresolved
  scalar and structured creator-contact/Location Created/Shown variables with typed paths, and
  distinguish pending from failed sidecar persistence.
- Source availability/readability/writability, supported format/decode state, stale XMP versus
  embedded descriptive conflicts, and C2PA consequences remain separate typed results.
- Export checks cover quality, source dimensions, downscaling, active SDR/HDR format capability,
  and active SDR/HDR gamut capability. The current profile has no per-item maximum-byte field, so
  that requirement cannot yet be represented; batch estimated size is checked against destination
  and staging capacity.
- Per-batch checks cover rename reservations and duplicate outputs, delivery-size/free-space facts,
  staging availability, configured/reachable connections, and invalid or unresolved remote paths.
- Results sort deterministically by severity, pipeline check order, input image order, and stable
  occurrence. The report exposes aggregate counts, per-image issues, the immutable rename plan,
  and a predictable next issue.
- Cancellation is checked before work and between images and major async planning boundaries.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-deadline-preflight-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightServiceTests'
```

Result: **7 tests passed**, and the application target compiled in the same run. The project file
passes `plutil` validation and whitespace checks are clean.

## Integration and remaining work

Revision-safe coordination, stale suppression, an explicit no-cache live policy, and the first
Deadline Workspace are now complete; see
[the workspace validation record](deadline-workspace-validation.md).

- Add a portable maximum encoded-byte requirement to the deadline export profile before claiming
  per-item maximum-size preflight.
- Keep reachability optional and non-destructive; actual upload and remote verification remain
  Phase 5 work.
