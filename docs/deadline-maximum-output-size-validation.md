# Deadline maximum output-size validation — 2026-08-21

Deadline export snapshots now carry an optional per-output encoded-byte ceiling. Missing values in
previously saved profiles decode as unlimited, while zero and negative values are rejected. The
limit is frozen into delivery-plan and staging fingerprints, shown in the confirmation surface,
and retained as render evidence in privacy-shaped delivery receipts.

Preflight accepts a captured per-item encoded-size estimate. A trustworthy estimate above the
ceiling is a typed blocker; a missing or invalid estimate is a typed warning that explains the
authoritative post-render check. The current production live adapter does not claim an encoder
estimate it cannot support, so a profile with a byte ceiling requires explicit warning acceptance
before staging.

Staging enforces the hard boundary against the final encoded bytes after descriptive metadata
write/read-back and unrelated-metadata preservation verification. An oversized output fails with a
typed result before SHA verification, upload eligibility, or receipt assembly. Receipt assembly
also requires the recorded ceiling to match the frozen plan exactly.

The isolated focused gate passed 77 tests across Deadline profile, preflight service/coordinator,
delivery planning, staging, and receipt repository suites with zero failures. `git diff --check`
and the conflict-marker scan passed.

This is a hard delivery-size constraint, not a promise that the current encoder will automatically
iterate quality until an arbitrary target is met. A future renderer-specific estimator or bounded
quality-search policy can improve preflight certainty without weakening the final-byte refusal.
