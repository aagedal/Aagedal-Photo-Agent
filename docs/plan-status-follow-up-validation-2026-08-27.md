# Plan status follow-up validation — 2026-08-27

## Reconciled status

The clean `main` baseline at `c30824c` had no stored task-plan object, so status was reconstructed from
`TODO.md`, `app-improvement-audit-plan.md`, `v2.3/delivery-plan.md`, current source, and dated validation
records. Before this follow-up, those files reported three TODO items, 16 audit substeps, and 23 delivery
gates open. The lists overlap and are not 42 independent tasks.

One audit checkbox was stale: Metal live/offscreen/cross-pipeline owner and executor preconditions are already
implemented and validated. Reconciling it moves the audit to **60 of 75 complete, 15 open**. The remaining
Metal facade and mutable-storage isolation bullets stay open.

The AuraFace runtime already implements signed HTTPS descriptor handling, complete artifact verification,
atomic install, receipt revalidation, rollback, and failure injection. Its unchecked wording now names only
the genuine production gate: publish the artifact/descriptor at `aagedal.me`, build a model-omitted release
candidate, and run real-server tests on supported macOS tiers.

## Code-completable progress

- Rename, Duplicate, Reset All Edits, and Remove All IPTC moved from process-wide notifications to the
  scene-owned typed command router. The focused router suite passed **7 of 7 tests**.
- Primary and secondary-card import discovery moved behind a serialized actor with cooperative cancellation,
  stale-result protection, explicit errors, regular-file filtering, and privacy-safe scan signposts. Its
  focused suite passed **2 of 2 tests** in isolated DerivedData.

A combined integration rerun of `AppCommandRouterTests` and `ImportSourceDiscoveryServiceTests` then passed
all **9 tests in 2 suites** with `** TEST SUCCEEDED **`.

These are bounded advances toward the broad Phase 3.1 and Phase 4.1 bullets; they do not falsely close those
incremental project-wide items.

## Integrated repository validation

`scripts/ci/validate_repository.sh` passed after integration. It verified generated documentation, release
metadata, JSON/plist/project syntax, bundled-component provenance, deterministic AuraFace build contracts,
unified-log and investigation privacy invariants, conflict-marker absence, and `git diff --check`.

## Remaining dependency classes

Local code work remains in lower-priority filesystem boundaries, coordinator extraction, remaining command
families, and Metal facade/storage isolation. Other gates require external authority or environments:
protected-branch configuration, focused privacy/legal review, production AuraFace hosting, real FTP/FTPS/SFTP
servers, target-hardware/Instruments runs, hands-on accessibility/display/localization exercises, recovery
drills, and signed release packaging. The conditional AI-origin analyzer remains unapproved and should not be
started until its model, licensing, validation-corpus, and product-language gates are explicitly approved.
