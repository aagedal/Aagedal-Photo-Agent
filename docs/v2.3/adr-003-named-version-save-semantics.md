# ADR-003 — Named Develop version save and Primary promotion semantics

**Status:** accepted for 3.0
**Decision date:** 2026-07-26
**Recorded:** 2026-08-24

## Decision

**Primary** remains the existing virtual, XMP-backed Develop state. Named versions are app-private
JSON snapshots bound to one exact source revision; `activeVersionID == nil` means Primary and
Primary is never duplicated into the catalog merely to appear in the selector.

Creating or editing a named version captures a dedicated `DevelopVersionSnapshot`. It preserves
decoder/process state, as-shot white balance, source-bound crop and layer geometry, unparsed Adobe
mask corrections, embedded LUT and AI-mask data, layer identities/order, and external dependency
identities. The decode-time `sourceHasHDRHeadroom` hint is recomputed from the source and is the
only intentionally stripped render-time field. Dependency manifests distinguish matching,
changed, missing, and unsupported resources without silently substituting same-named bytes.

Named-version edits save atomically to the JSON catalog after a short debounce and expose
Unsaved, Saving, Saved, or Save Failed state. Switching versions, navigating images, leaving
Develop, and application termination use an explicit flush boundary. A switch first snapshots and
persists the version being left plus the new active selection; the editor installs the destination
state as one transaction only after that save succeeds. A failed flush does not silently switch or
discard the current editor state. Undo/redo remains session-local and is reset when a different
snapshot is installed.

Promotion from a named version to Primary is an explicit JSON-to-XMP transaction:

1. Flush the live named source version and persist a named recovery snapshot of the old Primary.
2. Write the promoted settings through the existing XMP sidecar path.
3. Read the XMP back and compare its canonical managed payload with the promoted settings.
4. Only after successful read-back, persist Primary as active in the JSON catalog.

The promoted named source remains intact. If the recovery write fails, XMP is untouched. If a later
step fails, the durable recovery version remains available and the failure identifies the exact
transaction boundary.

## Rationale

Keeping named versions in JSON supports multiple source-bound edit states without turning XMP into
an app-private catalog. Explicit flushes make navigation and termination failure behavior honest.
The recovery-first, verified promotion sequence protects the interoperable Primary while crossing
two independent persistence systems that cannot form one filesystem transaction.

## Consequences

- Ordinary named-version edits never enter the XMP commit path.
- Switching applies one complete edit-model transaction and deliberately replaces the undo stack.
- Missing or changed dependencies are visible states rather than implicit substitutions.
- Promotion can report partial completion precisely, and a verified XMP write can coexist with a
  failed final catalog write without claiming the selector is fully committed.
- Changing snapshot contents, flush behavior, or promotion ordering requires a compatible schema or
  a new ADR.

## Implementation evidence

- [Implemented source-bound snapshot policy](comparison-and-versions.md#implemented-source-bound-snapshot-policy)
- [Save semantics](comparison-and-versions.md#save-semantics)
- [Named-version workflow validation](phase-10-version-workflow-validation.md)
- `DevelopVersionSnapshot`, `DevelopVersionCatalog`, `DevelopVersionFlushCoordinator`,
  `DevelopVersionCatalogRepository`, and `DevelopVersionPromotionService`
