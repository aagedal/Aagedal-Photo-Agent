# Persistence migration and schema validation — 2026-08-21

The release-hardening migration matrix is derived from the repository's exact `2.0.0`, `2.1.0`,
and `2.2.0` tags. Explicit per-release fixtures cover the persistence formats that actually existed:
metadata sidecars using top-level `version: 1`, unversioned metadata templates, version-1 template
bundles, unversioned requirement-level maps, and version-1 keyword archive manifests. Separate
fixtures cover the 2.0 legacy required-field array and the 2.2 minimum-length map. Parameterized
tests decode each release independently rather than treating one generic “legacy” fixture as all
three.

Preferences in those releases were individual UserDefaults keys rather than an aggregate export.
A tag-derived key matrix therefore tests the real boundary: 2.0 and 2.1 have the same relevant
metadata/list keys; 2.2 adds minimum lengths and hidden IPTC fields. Keyword/approved-list payloads
are plain UTF-8 text. No JSON document is invented for either case.

The audit also hardened present-day downgrade boundaries. Metadata requirement saves retain unknown
field IDs, level raw values, and unknown/nonpositive minimum-length entries. Deadline-profile and
rename-recipe repositories preflight nested future item schemas before backup recovery; workflow
manifests do the same for nested upload checkpoints. Code-replacement settings become disabled and
read-only when saved configuration is future or unreadable, preserving both configuration and
bookmark bytes. Existing sidecar, template, receipt, atomic-store, and workflow-registry future-
schema protections remain in the matrix.

Validation used isolated DerivedData at `/private/tmp/aagedal-phase6-migration-01`. The test build
succeeded and 131 tests across twelve suites passed. All fixture JSON passed `jq empty`, the project
file passed `plutil -lint`, and `git diff --check` was clean.

Deadline profiles, rename recipes, delivery plans/receipts/workflows/registry, and code-replacement
settings are absent from all three historical tag trees, so their coverage is correctly labeled
current-schema future/no-overwrite behavior rather than a fictional 2.x migration. Representative
fixtures use exact tag source shapes; no captured end-user files were available locally. Already
released older binaries cannot be retroactively hardened, so an actual downgrade launch remains a
manual release drill before claiming universal cross-version overwrite safety.
