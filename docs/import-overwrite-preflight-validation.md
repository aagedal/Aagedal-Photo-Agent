# Import overwrite preflight validation

**Date:** 2026-08-25
**Scope:** App improvement audit plan 0.3

## Implemented boundary

Rename remains the default conflict policy. Selecting Overwrite now always stops on a
frozen preflight, including when the count is zero. The alert presents exact primary and
backup collision counts and roots, with **Cancel** and an explicit destructive
**Replace N existing files** action.

Preflight excludes duplicate-skipped work, includes collisions created by earlier jobs in
the same batch, and binds confirmation to the ordered destination/existence signature.
The complete primary/backup signature is revalidated before destination-folder creation
and again immediately before staging begins. A changed signature returns to preflight.
Confirmation is single-use.

Activity history now stores backward-compatible replaced, backup-replaced, skipped, and
renamed totals.

## Automated evidence

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/ImportViewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/ImportCopyServiceTests'
```

Result: 17 tests across 2 suites passed. Coverage includes primary plus backup count/
execution agreement, cancellation with unchanged bytes and no created destination,
same-batch conflicts, stale-confirmation invalidation, activity JSON round trips, and the
existing atomic-overwrite cases.

The project still has no UI-test target, so the exit gate's literal XCUITest requirement
remains open under item 2.4. Model integration tests prove that overwrite cannot schedule
execution without confirmation; the SwiftUI alert provides the explicit destructive action.
