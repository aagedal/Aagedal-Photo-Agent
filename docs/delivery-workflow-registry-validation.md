# Delivery workflow registry validation — 2026-08-21

Verified delivery workflows are now stored as independently recoverable private units below a
canonical lowercase UUID directory. Each unit contains an immutable frozen plan, an atomic
lifecycle manifest, an atomic staging-evidence document, and a staging root constrained to that
workflow. Plan contents never enter the discovery catalog: public summaries contain only the
workflow UUID, lifecycle state, item counts, retained-staging fact, and a typed failure code.

The registry creates workflow directories as an exclusive no-overwrite claim, applies `0700`
directory and `0600` document permissions, and excludes the private root/documents from backup.
Relaunch reconstructs the exact plan, profile, staging root, and coordinator persistence factories
only after cross-document identity checks and a fresh size/SHA-256 inspection of every retained
staged file. It permits only the workflow coordinator's documented evidence-before-manifest crash
window; other partial, corrupt, mismatched, duplicate, symlinked, missing-byte, or newer-schema
states fail closed.

Validation used isolated DerivedData at `/private/tmp/aagedal-workflow-registry-tests-01`.
`DeliveryWorkflowRegistryTests` passed 9/9, including concurrent UUID claims, restrictive
permissions, exact relaunch, the intentional two-document crash window, privacy scanning,
terminal-only retention/manual cleanup, symlink containment, duplicate identities, schema drift,
plan/profile drift, and missing staged bytes. The full production/test targets rebuilt, the project
file passed `plutil -lint`, and `git diff --check` was clean.

The registry deliberately does not synchronize through iCloud and does not clean active or
non-terminal crash states automatically. User-facing selection and confirmed cleanup belong to the
Activity/Deadline composition layer.
