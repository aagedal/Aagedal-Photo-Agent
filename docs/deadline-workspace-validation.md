# Deadline Workspace validation

**Validated:** 2026-08-21  
**Scope:** Phase 4 revision-safe preflight publication and first read-only Deadline Workspace

## Implemented contract

- `DeadlinePreflightCoordinator` is actor-isolated, cancels superseded evaluation, and uses a
  generation gate so an evaluator that ignores cancellation still cannot publish stale output.
- Normal caching requires an exact seven-part composite revision token covering selection/source,
  metadata, profile, resources, rename environment, export capabilities, and delivery snapshot.
  Invalidation cancels active work and clears the bounded cache.
- An explicit bypass policy performs no cache read or write. The first live workspace uses bypass
  because resource/capability/delivery stores do not yet all expose trustworthy revisions; it
  never reuses a convenient but stale zero token.
- `MainViewMode.deadline` provides `Select → Caption → Verify → Send` status, aggregate
  readiness/blocker/warning counts, blockers/warnings/ready filters, exact planned filenames,
  metadata write strategy, and destination summary while preflight runs asynchronously.
- Fix Next and row activation route to the affected image in Caption Workspace. Field-level focus
  remains open because the current editor has no typed focus target API.
- Send is visibly disabled and labelled as Phase 5 work; this foundation cannot imply delivery.
- The live adapter never claims unobserved original-file permissions. Unknown writability produces
  a typed blocking issue when a profile requests original-file writes; SwiftUI performs no
  filesystem or network probe.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-deadline-workspace-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightCoordinatorTests'
```

Result: **13 tests passed** across both suites, and the application/UI target compiled. Coverage
includes cache hit/bypass/invalidation, input-token change, latest-wins stale suppression,
workspace state/filter/output projection, and unknown source writability.

## Remaining integration

- Replace the in-memory placeholder profile with a repository and real profile selection/import/
  export management.
- Add trustworthy revisioned adapters for validation/template/list/recipe/export/connection and
  delivery facts, then enable composite-token caching in the live workspace.
- Add typed field/profile remediation targets and filters for later failed/sent delivery states.
- Show configured export format and any future maximum encoded-byte constraint before Phase 5 can
  enable Send.
