# Delivery workflow Activity validation — 2026-08-21

Activity now exposes the private workflow registry through a deliberately narrow projection. Each
row contains only a workflow UUID, one of the eleven explicit lifecycle stages, completed/total
item counts, a retained-staging indicator, and a generic typed failure. Frozen plans, source and
output names/paths, hashes, destination facts, and editorial values cannot be represented by the
UI model. A corrupt or newer-schema catalog clears any stale partial list and fails closed.

Users can explicitly select one recoverable workflow even when several are retained. Validation
claims a session-owned reservation for that exact UUID before the registry actor hop; cleanup and
competing resume are blocked until matching Deadline recovery consumes the reservation. Rejection,
navigation abandonment, view disappearance, and recovery failure release it. This closes the
validate-to-navigation deletion race without guessing among workflows.

Manual removal requires confirmation and calls only `DeliveryWorkflowRegistry.removeWorkflow`,
deleting the selected local workflow and retained staged copies. It never deletes a receipt or
touches a delivered remote file. Receipt deletion remains the separate existing Activity action,
and no lifecycle path automatically removes staging.

Validation used isolated DerivedData at `/private/tmp/aagedal-delivery-workflow-activity-02`.
Activity plus Deadline tests passed 21/21; workflow-registry plus receipt-Activity tests passed
15/15. Coverage includes multiple candidates/exact selection, relaunch, cleanup, executing/reserved
busy guards, reservation overlap/abandonment, corrupt/newer schemas, privacy serialization, and all
stage titles. Project-file lint and relevant `git diff --check` passed.

The slice uses model/session integration tests rather than an automated SwiftUI click-through. A
manual accessibility and interaction pass remains part of release hardening.
