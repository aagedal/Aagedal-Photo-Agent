# Deadline live preflight validation

**Validated:** 2026-08-21  
**Scope:** Phase 4 production-safe live resource, source, rename, export, and staging snapshots

## Implemented contract

- SwiftUI constructs value-only capture requests and reads one published immutable workspace
  input. Filesystem inventory, source readability/decode, case sensitivity, export capability,
  staging write, and capacity probes run in the actual cancellable detached capture task.
- A latest-wins coordinator cancels replaced captures and suppresses stale results. Live evaluation
  still uses cache bypass because source permission and remote reachability lack event-backed
  revisions.
- Stable inventories cover saved validation profiles, metadata templates, approved required lists,
  rename recipes, current frozen export configuration, and credential-free connection UUIDs.
  Revisions hash deterministic full resource contents rather than names or counts alone.
- Rename facts contain the captured directory/artifact inventory, real volume case sensitivity, and
  an explicit completeness flag. Unknown facts remain blockers; no case behavior is guessed.
- Export formats/gamuts and executable metadata-write strategies come from the same production
  staging capability matrix used at runtime. Current live delivery supports staged copies only;
  originals and XMP-sidecar strategies receive typed blockers instead of failing after Send.
- The application-owned staging root must pass an actual write probe and capacity measurement.
  Browser security-scope ownership is not changed, source writability is never inferred, and no
  network probe or credential access occurs.

## Test evidence

The focused live-adapter suite passed **9 tests**. Combined preflight service, coordinator, and live
adapter suites passed **23 tests** in isolated DerivedData. Coverage includes exact resources,
missing-resource blockers, case-sensitivity incompleteness, staging write/capacity refusal, shared
capability parity, full-content revisions, source observations, unsupported write strategies,
cancellation, and stale-result suppression. The app target compiled; PBX parsing and
`git diff --check` passed.

## Known boundaries

- Renderer-aware output-size estimation is not yet connected, so preflight reports delivery-size
  uncertainty instead of substituting unsafe source-byte estimates.
- Connection reachability remains unknown until an explicit user-authorized probe or upload.
- Custom validation/export repositories and required-list adapters beyond approved keywords do not
  yet exist; absent references remain typed blockers.
