# Deadline remediation validation — 2026-08-21

Deadline preflight issues now resolve through a typed, deterministic remediation destination rather
than a generic image-selection callback. The mapping is exhaustive across all 39 top-level issue
codes, every stable editable metadata field, every rename issue kind, and all actionable C2PA
consequences. Per-image destinations require the exact image URL and fail closed when it is absent.

Editable metadata rules route to Caption Workspace with the exact image and `MetadataFieldID`; the
field is made visible and focused on appearance/change. Source issues select only the affected image.
Rename and export issues use the exact ordered Deadline request (or abort when it is empty), while
connection issues open the configured UUID when it exists. Profile/reference issues open the saved
profile surface, and staging/capacity issues open the existing privacy-safe Activity workflow review
and cleanup surface. No remediation silently selects an unrelated browser image.

Blockers, Warnings, and Ready remain current-preflight image filters. Sent/Failed are intentionally
not fabricated as per-image filters because privacy-safe workflow and receipt summaries contain no
image identity; actual batch lifecycle history remains in Activity, where it can be represented
without weakening the privacy boundary.

Validation used isolated DerivedData at `/private/tmp/aagedal-deadline-remediation-01`.
`DeadlinePreflightCoordinatorTests` passed 16/16; adjacent Deadline service, workflow Activity, and
receipt Activity suites passed 21/21. Coverage includes exhaustive target resolution, exact
selection, missing-identity refusal, and filter-scope copy. `git diff --check` passed.

The current app has no dedicated field-level editors for profile internals or staging configuration.
Those targets therefore open the closest real management surface (profile library or Activity)
rather than claiming a nonexistent focus location.
