# Journalistic metadata workflow — implementation plan

> Project planning index: [README.md](README.md)

## Objective

Make Aagedal Photo Agent a credible replacement for Adobe Bridge and Photo Mechanic for
deadline-driven journalistic metadata work, with one clear product promise:

> From card to picture desk — captioned, standards-checked, and delivered with proof.

This plan covers four connected initiatives:

1. A dedicated **Caption Workspace** for fast, image-by-image metadata work.
2. Stronger **IPTC standards coverage and interoperability guarantees**.
3. A safe, previewable, preset-driven **Batch Rename** workflow.
4. **Deadline Mode**, which combines validation, metadata writing, rendering, verification, and
   delivery into one resumable workflow.

The order below is deliberate. Standards and validation become shared infrastructure; Caption
Workspace and Batch Rename then use that infrastructure; Deadline Mode composes all three rather
than reimplementing their rules.

## Product principles

- **Confirm before write.** Suggestions, replacements, rename plans, and delivery plans are
  previewed before they mutate files or metadata.
- **Preserve what the app does not edit.** Unknown XMP namespaces, unsupported IPTC fields, Camera
  Raw settings, C2PA data, and unrelated technical metadata must not be silently removed.
- **One meaning per field.** UI labels, validation, variables, templates, embedded IPTC-IIM, XMP,
  JSON sidecars, export, and upload all use the same field definitions.
- **A plan before an operation.** Rename and delivery workflows first produce immutable plans that
  can be validated and tested without touching the filesystem.
- **Failure is recoverable.** Multi-file operations use staging and rollback where possible, and
  otherwise report exactly what completed and what did not.
- **Keyboard first, mouse friendly.** A captioner must be able to complete an assignment without
  repeatedly moving focus between the image, fields, and browser.
- **No speculative facts.** This scope does not include free-form generative captions or automatic
  publication of unconfirmed face/roster suggestions.
- **Local by default.** Captioning, validation, renaming, and metadata verification do not require a
  cloud service or account.

## Scope boundaries

### In scope

- Current IPTC Photo Metadata Standard mapping for the fields needed by editorial/newsroom users.
- Backward-compatible migration of existing templates, JSON sidecars, required-field settings, and
  metadata history.
- JPEG and other writable raster metadata, plus XMP sidecars for RAW and protected formats.
- Photo Mechanic-style captioning ergonomics, code replacement, autocomplete, and rename recipes.
- Existing FTP/SFTP delivery profiles and the existing export renderer.
- Machine-readable delivery receipts and resumable activity history.

### Deferred

- A full catalog/DAM or cross-folder database.
- Multi-user live collaboration and server-side assignment management.
- Free-form AI caption generation.
- Production claims for C2PA signing until the existing experimental implementation is verified
  end to end against external validators and trusted signing identities.
- Every specialist stock, artwork, licensing, and accessibility field in IPTC Extension. The model
  must be extensible to them, but the first UI should target editorial use.

## Shared architecture

### Metadata field registry

Replace scattered field switches with one authoritative registry. A field definition should
describe:

- Stable internal identifier and migration aliases.
- IPTC name, concise UI label, help text, and section.
- Value kind: text, localized text, date/time, integer, URI, controlled vocabulary, repeatable text,
  or structured value.
- Cardinality and whether the field has IPTC-IIM, XMP, or both representations.
- XMP namespace/property and IIM dataset mapping where applicable.
- Normalization and comparison rules used for round-trip verification.
- Editor type, variable support, template support, validation support, and default visibility.
- Legacy length constraints separately from newsroom-configured validation constraints.

Probable types:

```swift
struct MetadataFieldDefinition: Sendable {
    let id: MetadataFieldID
    let valueKind: MetadataValueKind
    let cardinality: MetadataCardinality
    let xmpMapping: XMPFieldMapping?
    let iimMapping: IIMFieldMapping?
    let capabilities: MetadataFieldCapabilities
}
```

The registry is metadata about fields, not a replacement for strongly typed structured values.
Contact information and locations should remain real Codable models rather than untyped string
dictionaries.

### Validation engine

Generalize the existing empty/minimum-length checks into reusable profiles:

```swift
struct MetadataValidationProfile: Codable, Sendable {
    var name: String
    var rules: [MetadataValidationRule]
}

enum MetadataValidationRule: Codable, Sendable {
    case required(field: MetadataFieldID)
    case minimumLength(field: MetadataFieldID, count: Int)
    case maximumLength(field: MetadataFieldID, count: Int)
    case pattern(field: MetadataFieldID, expression: String)
    case allowedValues(field: MetadataFieldID, values: [String])
    case requires(field: MetadataFieldID, whenPresent: MetadataFieldID)
    case forbidsPlaceholder(field: MetadataFieldID)
}
```

Every result carries image URL, field, severity, concise message, optional technical detail, and a
stable issue identifier. The browser filter, Metadata Review, Caption Workspace, pre-upload check,
and Deadline Mode must all consume the same results.

### Immutable operation plans

`RenamePlan` and `DeliveryPlan` are value types containing resolved source/destination URLs,
sidecar/artifact actions, conflicts, warnings, and a configuration snapshot. UI previews these
plans; executors consume them. Executors must not quietly reinterpret recipes after confirmation.

## Phase 0 — standards decisions and interoperability fixtures

**Exit gate:** the supported editorial field set and expected representations are documented, and
reference fixtures can detect unrelated metadata loss before the data model changes.

- [x] Freeze the target IPTC specification version in a short ADR; begin with IPTC Photo Metadata
  Standard 2025.1 unless a newer final version exists when implementation starts.
- [x] Create a support matrix with columns for field, XMP property, IIM dataset, value type,
  read/write/UI/template/validation support, and Bridge/Photo Mechanic round-trip notes.
- [x] Select the first editorial field set. At minimum, review:
  - Description/Caption Writer.
  - Creator Job Title and Creator Contact Info.
  - Country Code.
  - Genre, Urgency, Scene Codes, and Subject Codes.
  - Rights Usage Terms and Web Statement of Rights.
  - Location Created and Location Shown as distinct structured values.
  - Organisation and Person Shown.
  - Digital Image GUID and Image Supplier identifiers.
  - Current Digital Source Type NewsCodes.
- [x] Decide which legacy IPTC-IIM fields remain editable for wire-service compatibility even when
  modern XMP guidance discourages their use.
- [ ] Complete the legally redistributable fixture corpus:
  - [x] Generated complex XMP with multiple creators/locations/people, unknown properties, Unicode,
    commas, semicolons, and newlines.
  - [x] Generated no-metadata JPEG for embedded write coverage.
  - [x] Deterministic conflicting XMP/IIM values for adapter precedence coverage.
  - [ ] IPTC 2025.1 reference image containing all current fields; confirm redistribution terms
    before committing the official image.
  - [x] Maximum legacy byte lengths and timezone-offset variants.
  - [ ] TIFF, PNG, HEIC/HEIF, JPEG XL, and representative RAW plus XMP.
- [x] Snapshot the current XMP/JPEG fixtures before and after no-op or unrelated-field writes and
  fail tests if unrelated metadata is changed or removed.
- [x] Record expected behavior when embedded XMP and IPTC-IIM disagree.
- [x] Audit `DigitalSourceType`: accept legacy short tokens on read for compatibility, normalize
  known values internally, and write canonical IPTC NewsCodes URIs in XMP.
- [x] Decide how dates retain date, time, timezone-known, and precision rather than collapsing them
  into a display string.
- [x] Document the format support boundary of SwiftExif and add upstream tasks for any missing
  structures or container mappings.

**Deliverables:** standards ADR, field support matrix, fixture README, baseline preservation tests.

**Progress — 2026-08-18:** IPTC 2025.1 is frozen in ADR-005, the first editorial field set is
tracked in `iptc-2025.1-editorial-support.md`, and Digital Source Type now reads legacy short
tokens/URI/QCode forms while writing canonical IPTC NewsCodes URIs. A CC0 synthetic XMP corpus and
generated JPEG now prove semantic no-op and unrelated-edit preservation, including unknown
namespaces, planned structured fields, and multi-creator sequences. Conflict precedence, legacy
IIM editing, date precision, and container boundaries are documented. The focused standards suites
pass 30 tests. Real cross-container fixtures and Bridge/Photo Mechanic/IPTC external round trips
remain the Phase 0 exit-gate work.

## Phase 1 — metadata model, I/O, and validation foundation

**Exit gate:** the selected editorial fields round-trip through supported files/sidecars, untouched
metadata survives, existing user data migrates, and every UI can ask one engine whether an image is
ready.

### Model and persistence

- [x] Introduce stable `MetadataFieldID` values without invalidating existing
  `IPTCMetadata.FieldKey` data stored in UserDefaults or JSON.
- [x] Add typed models for creator contact information and created/shown locations.
- [x] Expand `IPTCMetadata` or introduce a versioned editorial metadata aggregate without turning
  structured fields into delimiter-dependent strings.
- [x] Version JSON sidecars and templates; add decoding defaults and migration tests for all
  previously shipped shapes.
- [x] Preserve unknown/newer sidecar fields through read-modify-write where feasible; otherwise
  reject a newer schema without overwriting it.
- [ ] Separate canonical stored values from localized display labels for controlled vocabularies.
- [ ] Update metadata history so new fields produce human-readable changes without logging
  sensitive values unnecessarily.

### Read/write boundary

- [ ] Implement XMP and IPTC-IIM mappings from the support matrix in `SwiftExifReadService`,
  `IPTCMetadataParsing`, `SwiftExifWriteEngine`, `XMPDataBuilder`, and sidecar services.
- [ ] Define normalization rules for comparison: array order, duplicate values, language
  alternatives, whitespace, URI aliases, date precision, and coordinate precision.
- [ ] Ensure a descriptive save preserves Camera Raw settings and unmodeled XMP.
- [ ] Ensure RAW descriptive writes update the XMP sidecar and never embed into proprietary RAW.
- [ ] Make overwrite, append, clear, and untouched explicit per field. An empty value must not
  ambiguously mean both “clear” and “leave unchanged.”
- [ ] Add a read-after-write verification API that returns normalized expected/actual differences.
- [ ] Keep low-level I/O non-UI and `Sendable`; batch work must remain cancellable and off the main
  actor.

### Validation

- [x] Implement the generalized rule engine and severity model.
- [x] Migrate current requirement levels and minimum lengths into the default profile.
- [x] Add dependencies and controlled-vocabulary validation, including canonical NewsCodes URIs.
- [x] Flag unresolved template variables separately from ordinary punctuation containing braces.
- [x] Expose aggregate counts and “next blocking issue” ordering.
- [x] Use the same engine in the browser missing-metadata filter, Metadata Review, and FTP/SFTP
  preflight.
- [x] Add profile import/export as versioned JSON. Portable assignment packages can build on this
  later without changing the rule engine.

### Verification

- [ ] Unit tests for every selected field: empty, single, repeated, Unicode, clear, append,
  overwrite, and unknown-value behavior.
- [ ] Fixture tests for embedded XMP, IPTC-IIM, sidecar XMP, and conflicting representations.
- [ ] No-op and single-field-edit tests prove unrelated fields survive byte-semantically.
- [ ] Run IPTC Interoperability Tests 1, 2, and 3 manually and store dated results in `docs/`.
- [ ] Open representative outputs in current Bridge and Photo Mechanic and record discrepancies.
- [ ] Add a CI-friendly generated support report so README claims cannot drift from tests.

**Progress — 2026-08-18:** `MetadataFieldID` is now the top-level identity used by metadata
settings, browser filters, Metadata Review, and upload validation. The semantic `.headline` case
retains the previously shipped `"title"` persistence key, and `IPTCMetadata.FieldKey.title`
remains source- and Codable-compatible. Requirement-level maps, minimum lengths, hidden-field
preferences, and legacy required-field arrays retain their existing storage shapes. Nine focused
compatibility tests pass.

**Progress — 2026-08-19:** `CreatorContactInfo` and `EditorialLocation` now preserve contact
channels, identifiers, address parts, coordinates, and created/shown location roles as typed
Codable values. `IPTCMetadata` carries these structures through JSON round trips, additive merges,
authoritative sidecar clears, descriptive-content detection, and reconciliation without flattening
repeated values. XMP/IIM mapping and editor exposure remain separate Phase 1 work.

**Progress — 2026-08-19:** Metadata sidecars, metadata templates, and template export bundles now
write explicit `schemaVersion` markers. The decoders migrate the shipped `version` and unversioned
shapes, including the earliest `presetType` template key and later optional template flags. A newer
document remains in place, is excluded from editing, and blocks overwrite with a specific error;
same-schema sidecar saves preserve unknown top-level and metadata extension fields without reviving
known values that were cleared, and filename-only relocation preserves an otherwise unknown JSON
graph. The focused persistence suites pass 31 tests; see
[the dated validation record](metadata-json-persistence-validation.md).

**Progress — 2026-08-20:** The shared metadata validation engine now emits stable field/rule issue
identities with information, warning, and blocker severities; supports required, length, pattern,
allowed-value, dependency, and unresolved-template rules; and provides deterministic aggregate
counts plus next-blocker ordering. Existing requirement levels and minimum lengths are bridged into
the default profile, so the browser missing-metadata filter, Metadata Review, and FTP/SFTP preflight
now use the same engine without changing their stored settings. Digital Source Type rules compare
canonical NewsCodes URIs while accepting supported URI/QCode/legacy aliases, and brace punctuation
is not mistaken for a template variable. Seven focused tests pass. Versioned profile import/export
and the remaining cross-container field verification remain open.

**Progress — 2026-08-20:** Validation profiles now use an explicit, stable JSON rule schema rather
than Swift's synthesized enum representation. The reusable import/export boundary writes canonical
sorted JSON atomically; rejects missing/newer schemas, oversized documents, duplicate or empty rule
identities, invalid length bounds or regular expressions, empty controlled vocabularies, and
self-dependencies; migrates the short-lived synthesized version-one rule shape; and round-trips a
CC0 example desk profile byte-for-byte. The focused validation suite passes 13 tests; see
[the dated validation record](metadata-validation-profile-validation.md).
Profile selection/editing UI remains part of the later workflow surfaces, while assignment packages
can reuse this file boundary without changing the validation engine.

**Progress — 2026-08-20:** A CC0 recipe corpus now covers the exact UTF-8 byte ceiling for all 15
editable IPTC-IIM text mappings and seven date/time variants spanning date-only, unknown timezone,
UTC, half-hour offsets, and the civil-offset edges. The shared validation contract distinguishes
character limits from byte limits, checks repeatable values independently, and provides a stable
built-in IIM compatibility warning profile without truncating richer XMP values. Exact-limit and
one-byte-over values exercise SwiftExif's real IIM writer/reader; XMP and paired IIM timestamp
values retain their lexical precision and timezone state. The focused interoperability and
validation suites pass 19 tests; see
[the dated validation record](metadata-interoperability-corpus-validation.md). Real cross-container
and external-tool fixtures remain the Phase 0 gate.

**Progress — 2026-08-20:** Creator Contact Info and repeatable Location Created/Shown now read and
write their IPTC 2025.1 structured XMP representations in sidecars and embedded JPEG metadata.
Location identifiers remain bags, localized location names remain language alternatives, GPS
coordinates use XMP coordinate syntax, and signed model altitudes map to XMP rational altitude plus
reference. The write boundary distinguishes untouched structured values from authoritative replace
or clear operations; scalar-only edits and structured rewrites preserve unmodeled XMP members. The
same structured write data now flows through ordinary saves, rendered exports, and FTP/SFTP
sidecar preparation. Ten focused interoperability tests and all 11 real-file export/sidecar tests
pass; see
[the dated validation record](metadata-structured-xmp-validation.md). UI exposure, the remaining
support-matrix mappings, and external-tool/cross-container fixtures remain open.

**Progress — 2026-08-20:** Description Writer and Creator Job Title now share stable field IDs and
flow through typed metadata, JSON persistence, history, batch editing, import, templates and
variables, rendered export, and FTP/SFTP preparation. The Additional Fields editors expose both
roles. Sidecar and embedded writes use the IPTC 2025.1 scalar Photoshop XMP properties alongside
legacy IIM 2:122 and 2:85, including authoritative clears and 32-byte compatibility warnings; the
read boundary prefers XMP and falls back to IIM. Focused interoperability, Codable, validation,
template-variable, and real-file export coverage guards the complete path. Caption Workspace
placement, remaining support-matrix fields, and external-tool/cross-container fixtures remain open.

**Progress — 2026-08-21:** Country Code now stores a canonical uppercase ISO 3166-1 alpha-3 value
separately from its localized picker label. The 249 current assignments drive the metadata and
import pickers plus a default blocker rule; unknown incoming values remain visible and preserved
until corrected. Sidecar and embedded JPEG writes dual-write `Iptc4xmpCore:CountryCode` and IIM
2:100, reads prefer XMP and fall back to IIM, and authoritative clears remove both representations.
The field participates in JSON persistence, history, batch editing, templates, browser search,
rendered export, FTP/SFTP preparation, and the 16-field IIM boundary corpus. Five focused suites
pass 56 tests; external-tool and cross-container fixtures remain open.

**Progress — 2026-08-21:** Editorial Urgency now uses integer storage separate from the labels in
its bounded 1–8 pickers and participates in JSON persistence, history, batch editing, import,
templates, variables, browser search, rendered export, and FTP/SFTP preparation. XMP sidecars and
embedded JPEGs dual-write `photoshop:Urgency` and IIM 2:10, prefer XMP on conflicts, and clear both
representations authoritatively. The default validation profile blocks out-of-range values, and
the generated IIM boundary corpus covers the one-byte dataset. Focused model, interoperability,
template, variable, validation, and export tests pass; external-tool and cross-container fixtures
remain open.

**Progress — 2026-08-21:** Organisation Shown Name and Organisation Shown Code now use distinct,
ordered repeatable values across the metadata model, versioned JSON, templates and variables,
import, single and additive batch editing, metadata history, browser search, rendered export, and
FTP/SFTP preparation. Sidecar and embedded JPEG writes use independent
`Iptc4xmpExt:OrganisationInImageName` and `Iptc4xmpExt:OrganisationInImageCode` bags, including
authoritative clears; reads retain unknown incoming values for newsroom-specific code profiles.
The CC0 preservation fixture and focused sidecar/embedded tests cover multiple values and unrelated
metadata preservation. External-tool and cross-container fixtures remain open.

**Progress — 2026-08-21:** Rights Usage Terms and Web Statement of Rights now flow through typed
metadata, versioned JSON, history, batch editing, import, templates and variables, browser search,
rendered export, and FTP/SFTP preparation. XMP sidecar and embedded JPEG writes use
`xmpRights:UsageTerms` as a language alternative and `xmpRights:WebStatement` as a URL, including
authoritative clears and unrelated-property preservation. The default validation profile blocks
malformed non-empty web statements while leaving the field optional. Focused model,
interoperability, validation, template-variable, and real-file export suites pass; see
[the dated validation record](metadata-rights-xmp-validation.md). Additional language alternatives,
external-tool checks, and cross-container fixtures remain open.

**Progress — 2026-08-21:** Scene Codes now use a frozen 24-entry IPTC Scene NewsCodes vocabulary
with canonical six-digit storage and human-readable type-ahead labels. Common Scene URI and `scn:`
projections normalize at the model boundary; unknown incoming values remain visible and survive
unrelated edits while the default validation profile blocks them. Ordered, deduplicated values flow
through JSON, history, batch editing, import, templates, variables, browser search, copy/paste,
rendered export, and FTP/SFTP preparation. Sidecar and embedded JPEG writes use an
`Iptc4xmpCore:Scene` bag with authoritative clear behavior. The focused suites pass 69 tests; see
[the dated validation record](metadata-scene-code-validation.md). External-tool and cross-container
verification remains open.

**Progress — 2026-08-21:** Digital Image GUID now remains a stable, explicitly managed identifier
across typed metadata, versioned JSON, history, batch editing, import, templates and variables,
browser search, rendered export, and FTP/SFTP preparation. XMP sidecars and embedded JPEGs read and
write `Iptc4xmpExt:DigImageGUID`, including authoritative clears and preservation through unrelated
caption edits. Empty images stay empty: ordinary metadata editing never generates or rotates a
GUID; assignment through an editor, import configuration, or template is always explicit. The
focused model, persistence, validation, variable, interoperability, and real-file export suites
pass 160 tests across two focused runs; see
[the dated validation record](metadata-digital-image-guid-validation.md). External-tool and
cross-container verification remains open.

**Progress — 2026-08-21:** Image Supplier Image ID now remains distinct from Digital Image GUID,
Job ID, filenames, and the planned structured supplier identity across typed metadata, versioned
JSON, history, batch editing, import, templates and variables, browser search, rendered export, and
FTP/SFTP preparation. XMP sidecars and embedded JPEGs read and write
`Iptc4xmpExt:ImageSupplierImageID`, including authoritative clears and preservation through
unrelated edits. The focused model, persistence, variable, interoperability, and real-file export
suites pass 166 tests across two focused runs; see
[the dated validation record](metadata-image-supplier-id-validation.md).
External-tool and cross-container verification remains open.

## Phase 2 — Caption Workspace

**Exit gate:** a photographer can caption a folder image by image using the keyboard, never lose an
edit during navigation, and see exactly what prevents each image from being desk-ready.

### Workspace and session model

- [ ] Add `MainViewMode.caption` and a first-class Caption Workspace entry in the layout/workspace
  selector and View menu.
- [ ] Introduce `CaptionSession` to own ordered images, current index, selection, dirty state,
  validation results, and focus restoration.
- [ ] Reuse `MetadataViewModel` write/reconciliation behavior; do not create a second metadata save
  path inside the view.
- [ ] Keep current non-destructive behavior: navigation commits edits to the app sidecar, while an
  explicit command writes pending metadata to the image/XMP boundary.
- [ ] Flush buffered text before navigation, selection changes, template application, write, send,
  workspace exit, and quit.
- [ ] Prevent a stale asynchronous load for the previous image from replacing the current draft.

### Layout

- [ ] Large, color-managed image/edited-preview area on the left.
- [ ] Compact priority editor on the right, ordered by the active metadata validation profile.
- [ ] Sticky top status: filename, position, rating/label, pending state, and Ready/Warnings/Blocked.
- [ ] Sticky bottom actions: Previous, Save & Next, Write, Apply Template, Copy Previous, and Fix
  Next Issue.
- [ ] Allow secondary and technical fields to expand without pushing the priority caption fields
  off screen.
- [ ] Show per-field required/warning state inline with concise remediation, not only as a tooltip.
- [ ] Show caption/headline character counts and optional profile limits.
- [ ] Provide fit/100% zoom, full-screen preview, and face rectangles without leaving caption focus.

### Caption speed tools

- [ ] “Save & Next” and “Write & Next,” with separately configurable shortcuts.
- [ ] Copy selected fields from previous image; default to caption/headline/persons/keywords while
  protecting capture-specific fields.
- [ ] Apply metadata template in replace or append mode without losing focus.
- [ ] Field-aware autocomplete from approved lists, structured keywords, Known People, current
  folder values, and optional UTF-8 text lists.
- [ ] Photo Mechanic-compatible tab-delimited code-replacement lists with explicit delimiters,
  enable/disable state, source-file diagnostics, and a replacement preview.
- [ ] Never replace text inside an uncommitted IME composition or silently expand an ambiguous
  code.
- [ ] Keep confirmed face/roster names separate from suggestions; inserting a suggestion is an
  explicit user action.
- [ ] Add “persons left to right” ordering UI without inferring the order when face geometry is
  uncertain or the user has not confirmed identities.
- [ ] Add system spelling/grammar support to caption-like fields without modifying names or codes.

### Keyboard and accessibility

- [ ] Replace the read-only shortcut reference with assignable commands and conflict detection.
- [ ] Ship Photo Agent, Photo Mechanic-like, and Bridge-like shortcut presets.
- [ ] Define predictable Tab/Shift-Tab order and an escape route from token editors/popovers.
- [ ] Keep bare rating/label keys active only when a text editor is not consuming them.
- [ ] Add VoiceOver labels, issue summaries, and announcements after Save & Next.

### Verification

- [ ] Navigation/dirty-state tests, including rapid next/previous and failed sidecar writes.
- [ ] Focus tests for template, code replacement, autocomplete, popovers, and workspace return.
- [ ] Tests proving copy-previous never overwrites excluded capture-specific fields.
- [ ] Batch selection tests for common/mixed/partial list values.
- [ ] Manual keyboard-only pass through at least 100 images without mouse use.
- [ ] Manual test at small and large window sizes, with long Unicode captions and many people.

## Phase 3 — Batch Rename

**Exit gate:** users can preview every resulting filename and associated artifact action, resolve all
conflicts before execution, cancel safely, and trust rollback/reporting after failure.

### Rename recipe and token engine

- [ ] Introduce versioned `BatchRenameRecipe`, reusable by browser rename, import, export, and later
  Deadline Mode.
- [ ] Support literal components and documented tokens at minimum:
  - Original basename and extension.
  - Sequence with start, increment, and zero padding.
  - Capture date/time with explicit format and file-date fallback policy.
  - Metadata fields such as creator, job ID, event, city, and country code.
  - Camera make/model/serial where available.
  - Rating and color label.
- [ ] Use the existing variable/interpolation concepts where semantics match, but keep filename
  sanitation and missing-token policy specific to rename.
- [ ] Add literal and regular-expression substitution stages with testable ordering.
- [ ] Provide case conversion, whitespace replacement, and filesystem-safe sanitization.
- [ ] Optionally write the original filename to the appropriate XMP field before rename.
- [ ] Make a missing value an explicit recipe choice: empty, fallback text, preserve original, skip,
  or block.

### Plan and preview UI

- [ ] Replace the `NSAlert` with a resizable sheet.
- [ ] Show preset selector, component editor, live sample, and complete old → new preview table.
- [ ] Preview in the same sorted order used to allocate sequence numbers.
- [ ] Show conflicts, invalid names, missing values, duplicates within the batch, existing
  destinations, and case-only collisions before enabling Rename.
- [ ] Add collision policies: block batch (default), skip, or append a deterministic suffix.
- [ ] Save, duplicate, rename, import, and export recipes.
- [ ] Display a summary of associated artifacts that will follow each image.

### Transactional execution

- [ ] Create `RenamePlanningService` and `RenameExecutionService`; remove filesystem mutation from
  `BrowserViewModel`.
- [ ] Treat each image and its sidecars/references as one rename bundle.
- [ ] Audit and include:
  - Image file.
  - `.xmp` sidecar.
  - Current and legacy `.photo_metadata` JSON sidecars and their `sourceFile` value.
  - Folder face-data references.
  - Any filename-dependent analysis/project references.
  - Cached thumbnails and in-memory browser/manual-order selections.
  - Any future filename-keyed artifact through one registry/service rather than another view-model
    special case.
- [ ] Preflight permissions and reserve all destinations before the first mutation.
- [ ] Handle rename cycles (`A` → `B`, `B` → `A`) through unique temporary names in the same
  directory.
- [ ] Use staged two-phase execution and best-effort rollback with a detailed recovery result.
- [ ] Update original-filename metadata before or after filesystem mutation according to an
  explicitly tested transaction order.
- [ ] Invalidate affected metadata, full-screen, thumbnail, and edited-preview caches.
- [ ] Keep selection and manual order stable after a successful rename.
- [ ] Provide cancellation only at safe transaction boundaries.

### Verification

- [ ] Pure recipe/token tests, including locale-independent dates and Unicode normalization.
- [ ] Plan tests for duplicate targets, existing files, case-insensitive volumes, and missing data.
- [ ] Execution tests for single, many, cycles, XMP/JSON sidecars, and no-sidecar files.
- [ ] Failure injection after every move step proves rollback or precise partial-failure reporting.
- [ ] RAW + XMP develop settings still load after rename.
- [ ] Face data, named Develop versions, comparison, and analysis reassociate after rename.
- [ ] Manual cross-tool check that preserved original filename is visible in Bridge/Photo Mechanic.

## Phase 4 — Deadline Mode foundation

**Exit gate:** an assignment can have one saved definition of “ready,” and every selected image has
a deterministic, actionable preflight result before delivery starts.

### Deadline profile

- [ ] Add versioned `DeadlineProfile` containing references or snapshots for:
  - Metadata validation profile.
  - Visible/ordered caption fields.
  - Metadata template and variable-processing policy.
  - Filename recipe and collision policy.
  - Export/render settings and output naming.
  - Destination connection identifier and remote path template.
  - GPS removal/retention policy.
  - Metadata write strategy: originals, XMP sidecars, or staged delivery copies.
- [ ] Store secrets only in Keychain-backed connection records; exported profiles contain stable
  connection references, never passwords or private keys.
- [ ] Detect missing templates, lists, connections, and unsupported newer profile versions.
- [ ] Make profiles importable/exportable. A richer assignment package with rosters and vocabulary
  files can be added later without changing delivery execution.

### Preflight engine

- [ ] Implement `DeadlinePreflightService` as a pure/cancellable coordinator over existing engines.
- [ ] Check per image:
  - Metadata profile rules.
  - Unresolved variables and pending/failed sidecar writes.
  - Filename recipe result and conflicts.
  - Source availability, permissions, and supported render/write format.
  - Stale XMP/embedded descriptive conflicts.
  - C2PA consequences, reported separately from ordinary metadata readiness.
  - Export dimensions, format, gamut, and maximum-size requirements.
- [ ] Check per batch:
  - Duplicate output names.
  - Destination free space and staging availability.
  - Connection configuration and optional non-destructive reachability test.
  - Remote-path validity.
- [ ] Classify results as blocker, warning, or information and order “Fix Next Issue” predictably.
- [ ] Cache only against explicit source/metadata/profile revision tokens; invalidate immediately on
  relevant edits.

### Deadline UI

- [ ] Add a Deadline Mode workspace with a phase/status strip:
  `Select → Caption → Verify → Send`.
- [ ] Show aggregate readiness (`21 of 24 ready`) and counts by issue type.
- [ ] Filter to blockers, warnings, ready, failed, or sent.
- [ ] “Fix Next Issue” opens the correct image and focuses the relevant Caption Workspace field or
  rename/profile setting.
- [ ] Show the exact output filenames, format, destination, and write policy before enabling Send.
- [ ] Keep the rest of the app usable while preflight runs.

### Verification

- [ ] Profile Codable/migration tests and secret-exclusion tests.
- [ ] Deterministic preflight results for identical input/profile revisions.
- [ ] Cancellation and stale-result suppression tests.
- [ ] Tests that every blocker links to a valid remediation target.
- [ ] Manual preflight on mixed JPEG/RAW, missing sidecars, offline iCloud files, C2PA files, and
  read-only sources.

## Phase 5 — verified send and delivery receipt

**Exit gate:** a ready batch can be staged, written, read back, uploaded, retried, and audited without
silently delivering a file whose metadata differs from the confirmed plan.

### Delivery plan and staging

- [ ] Freeze a `DeliveryPlan` from the current profile, selected source revisions, resolved
  metadata, rename outputs, render settings, and preflight results.
- [ ] Default to creating staged delivery files so source photographs are not mutated during a
  deadline send. Allow in-place metadata writes only as an explicit profile policy.
- [ ] Stage into a unique batch directory with sufficient free-space preflight and bounded cleanup.
- [ ] Render/copy, apply resolved descriptive metadata, then read back from the actual staged bytes.
- [ ] Compare normalized expected/actual values for every field controlled by the profile.
- [ ] Confirm unrelated metadata preservation against the source according to the format's support
  boundary.
- [ ] Block upload on read-back mismatch unless the user explicitly returns to fix/replan; do not
  offer “send anyway” for hard verification failures.

### Upload and activity

- [ ] Extend activity state to explicit stages: queued, staging, writing, verifying, uploading,
  remote-confirming, sent, failed, cancelled.
- [ ] Resume/retry at file boundaries without rerendering already verified staged files whose plan
  fingerprint still matches.
- [ ] For FTP/SFTP, confirm remote existence and size after transfer when supported. Do not label
  that as cryptographic remote verification.
- [ ] Keep local SHA-256 for the delivered bytes and record protocol/server acknowledgement.
- [ ] Abort leaves verified staging files recoverable until the user chooses cleanup.
- [ ] Never log credentials, captions, private keys, or full sensitive metadata by default.

### Receipt

- [ ] Write an atomic, versioned JSON receipt containing:
  - Batch/profile/app version and timestamps.
  - Source identity and delivered filename for each image.
  - Delivered-byte SHA-256 and size.
  - Metadata verification result and controlled field IDs, without duplicating sensitive values by
    default.
  - Render settings and destination identifier/path.
  - Upload and remote-stat result.
  - Warnings accepted before the delivery plan was frozen.
- [ ] Provide a concise human-readable summary/export generated from the receipt.
- [ ] Make receipts inspectable from Activity and resilient to app relaunch.
- [ ] Define retention and manual deletion; never sync receipts implicitly through iCloud.

### Verification

- [ ] End-to-end tests with fake metadata writer, renderer, filesystem, and uploader.
- [ ] Failure injection at copy/render/write/read-back/upload/remote-stat/receipt stages.
- [ ] Relaunch/resume tests and plan-fingerprint invalidation tests.
- [ ] Prove that an edited caption after plan freeze cannot be mistaken for the already verified
  staged file.
- [ ] Large-batch memory and responsiveness test.
- [ ] Manual send to test FTP and SFTP servers, then inspect delivered files in Bridge and Photo
  Mechanic.

## Phase 6 — migration and release hardening

**Exit gate:** existing users upgrade without losing metadata/templates/settings, published support
claims match evidence, and the four workflows remain reliable under deadline conditions.

- [ ] Full existing test suite plus all new fixture, failure-injection, migration, and UI tests.
- [ ] Upgrade tests from representative 2.0, 2.1, and 2.2 JSON sidecars, templates, keyword lists,
  requirements, and preferences.
- [ ] Downgrade/newer-schema behavior documented; no older build may overwrite data it cannot
  understand.
- [ ] Thread Sanitizer and strict-concurrency review of caption navigation, preflight, rename, and
  delivery coordinators.
- [ ] File-permission, security-scoped bookmark, read-only volume, iCloud-offline, network drop, and
  disk-full drills.
- [ ] Accessibility pass and menu/shortcut conflict audit in every workspace.
- [ ] Performance targets measured on representative Apple Silicon tiers:
  - Caption navigation never waits for metadata write or full-resolution decode.
  - Rename preview remains interactive for at least 10,000 files.
  - Preflight streams incremental results and is cancellable.
  - Delivery memory is bounded independently of batch size.
- [ ] Update README with a generated field-support table and precise format/write-mode caveats.
- [ ] Publish dated IPTC interoperability and Bridge/Photo Mechanic round-trip results.
- [ ] Update user help, privacy text, CHANGELOG, and release notes.
- [ ] Only describe C2PA as experimental until its independent release gate is complete.

## Delivery sequence

Each milestone is independently useful and should be releasable without waiting for all later work:

1. **Standards foundation:** field registry, editorial fields, preservation, validation, and
   published interoperability evidence.
2. **Caption release:** Caption Workspace, Save & Next, autocomplete/code replacement, and
   configurable shortcut presets.
3. **Rename release:** recipe engine, full preview, artifact-safe execution, and presets.
4. **Deadline preview:** profiles, readiness dashboard, and Fix Next Issue, without transmission.
5. **Verified delivery:** frozen plan, staging, read-back, upload confirmation, and receipt.

Do not hide incomplete foundations behind feature flags and call a milestone complete. A phase is
complete only when model, persistence, migration, error states, tests, accessibility, documentation,
and a dated manual validation note are present.

## Cross-phase test matrix

| Axis | Required cases |
|---|---|
| File type | JPEG, TIFF, PNG, HEIC/HEIF, JPEG XL, supported RAW + XMP |
| Metadata representation | IIM only, XMP only, both in sync, conflicting, sidecar, none |
| Text | ASCII, Nordic, CJK, emoji, composed/decomposed Unicode, multiline, delimiters |
| Selection | One, mixed batch, 1,000+, filtered subset, changed during async work |
| Storage | Local, removable, read-only, security-scoped, iCloud online/offline |
| Sidecars | None, JSON only, XMP only, both, stale, corrupt, newer schema |
| Provenance | No C2PA, valid/trusted, valid/untrusted, invalid, protected source |
| Failure | Permission, disk full, collision, source changed, cancellation, network loss, app relaunch |
| Interop | Reopen in Photo Agent, current Bridge, current Photo Mechanic, IPTC test service |

## Product success criteria

- A new user can enter Caption Workspace and understand the primary workflow without reading the
  manual.
- A Photo Mechanic user can import code-replacement lists, choose familiar shortcuts, and caption
  without changing established muscle memory.
- A newsroom can define “ready” once and receive identical validation in review, captioning, and
  delivery.
- A batch rename cannot start with unresolved target conflicts and cannot orphan known sidecars.
- A delivered file is uploaded only after the metadata read from its actual bytes matches the
  frozen delivery plan.
- The app can publish an honest, reproducible IPTC field-support and interoperability report.
- No test or manual validation finds silent loss of unrelated metadata.

## Decisions to confirm during Phase 0

Defaults below allow implementation to proceed unless evidence supports changing them:

1. **Caption navigation:** commit to Photo Agent's non-destructive sidecar on Save & Next; keep
   embedded/XMP writing explicit. **Default: yes.**
2. **Rename collision:** block the full batch until resolved. **Default: yes.**
3. **Deadline mutation policy:** stage delivery copies rather than modify originals. **Default:
   staged copies.**
4. **Standards UI scope:** IPTC Core plus editorially relevant Extension structures, with the model
   extensible to the complete standard. **Default: editorial subset.**
5. **Receipt privacy:** store hashes, field IDs, and results but not caption/person/location values
   unless explicitly requested. **Default: privacy-preserving.**
6. **C2PA:** warn and preserve existing credentials where possible, but keep signing outside the
   production Deadline Mode promise until separately verified. **Default: experimental only.**
