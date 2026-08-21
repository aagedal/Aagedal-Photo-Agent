# Delivery workflow validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 lifecycle orchestration, crash recovery, resume, and terminal receipt recording

## Implemented contract

- `DeliveryWorkflowCoordinator` captures the batch start before staging and projects queued,
  staging, writing, verifying, preservation-verifying, uploading, remote-confirming,
  recording-receipt, sent, failed, and cancelled states without persisting raw dependency errors.
- A privacy-safe atomic central manifest stores identifiers, fingerprints, counts, lifecycle, and
  the upload checkpoint. A separate atomic staging-evidence document necessarily retains the local
  batch paths/relative names and complete verified result, but no credentials or editorial values.
- Resume revalidates the exact plan/profile, staged batch, preservation evidence, byte hashes,
  checkpoint, and workflow identity. It never calls render/write for already verified bytes.
- The two-document crash window is repairable: if staging evidence became durable just before the
  central reference, resume validates it and repairs only an eligible pre-upload manifest while
  preserving the original start time.
- Receipt assembly runs only after terminal upload evidence. Receipt persistence failure retains
  the pending identity and all staging/upload evidence. If the receipt write succeeds just before
  terminal-manifest failure, relaunch finds and fingerprints the existing batch receipt rather than
  uploading or recording a duplicate.
- Manifest persistence failure during execution requests upload cancellation at the next safe file
  boundary. Staging cancellation remains caller-task cancellation; active renderer interruption is
  not promised.

## Test evidence

An isolated run in `/private/tmp/aagedal-delivery-workflow-compile-02` passed **12 Swift Testing
declarations**, including parameterized renderer, writer, read, controlled verification,
preservation, upload, remote-stat, receipt, and persistence failures. Coverage also includes full
stage projection/privacy, exact checkpoint relaunch without rerender, staged-evidence crash repair,
receipt crash-window de-duplication, metadata/plan/staging invalidation, both cancellation
contracts, and atomic backup recovery. PBX parsing and `git diff --check` passed.

## Remaining composition

- Production must assign secure per-workflow storage URLs, persist the sensitive frozen plan under
  explicit retention, discover resumable workflows, and own cleanup.
- Deadline UI must create the frozen plan from the exact current revisions, compose the live
  staging/transport/receipt boundaries, display lifecycle, and publish recorded receipts.
