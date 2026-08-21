# Delivery integration hardening validation — 2026-08-21

An independent Phase 5 audit exercised the seams between frozen planning, live preflight, staging,
workflow cancellation, verified upload, production transport, registry persistence, and receipts.
The audit found and corrected several cross-component issues that isolated suites could not fully
demonstrate.

- Staging now rejects actor-reentrant concurrent batches and preserves a cancellation request made
  while an injected render/preflight operation is awaited.
- Workflow cancellation reaches both staging and upload. It stops at the next safe boundary,
  retains verified evidence, and does not claim to interrupt an active renderer/file transfer.
- Production FTP rechecks regular-file identity, size, and SHA-256 immediately before credential
  lookup and the curl boundary.
- Profile import, live preflight, frozen planning, and transport agree on canonical lowercase UUID
  connection identifiers.
- Remote paths fail closed when relative, doubled-slash, dot-segment, backslash/control-bearing, or
  URI/query-shaped.
- Registry staging-file symlinks retain the typed unsafe-path result instead of being flattened into
  an unrelated missing-evidence failure.

Validation used isolated DerivedData at `/private/tmp/aagedal-phase5-audit-02`. The final
staging/workflow/upload gate passed 40 tests in four suites; the changed-component sweep passed 60
tests in six suites; and an adjacent receipt/repository/Activity/production-staging/metadata/
registry/upload/preflight sweep passed 67 tests in eight suites. The unique aggregate was 127 tests
across 14 suites. Project-file lint and `git diff --check` passed.

The production FTP boundary remains path-based, leaving a narrow interval between the final hash
and curl opening the path. Removing that operating-system-level TOCTOU would require an fd-backed
transport or uploading an immutable sealed-byte handle. The current boundary detects all changes
before credential lookup and documents this residual limitation explicitly.
