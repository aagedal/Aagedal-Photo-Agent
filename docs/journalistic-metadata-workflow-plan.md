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
  - [x] Generated CC0 TIFF, PNG, and JPEG XL plus a representative RAW XMP sidecar, with
    pixel/codestream/source-byte preservation tests and explicit carrier capability checks.
  - [ ] Confirmed-redistributable decodable HEIC/HEIF and representative camera RAW originals.
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
pass 30 tests. The official IPTC asset, redistributable HEIC/camera-RAW fixtures, and Bridge/Photo
Mechanic/IPTC external round trips remain the Phase 0 exit-gate work.

**Progress — 2026-08-21:** A deterministic CC0 container corpus now covers TIFF, PNG, JPEG XL, and
the authentic RAW/XMP-sidecar safety boundary. Production writes preserve TIFF/PNG pixels, the JXL
codestream, Camera Raw/foreign sidecar properties, and opaque RAW bytes. The fixtures exposed and
fixed a TIFF serialization-shell false positive without excluding unrelated EXIF/IPTC changes.
Fourteen container/preservation tests pass; see
[the container fixture validation record](editorial-container-fixture-validation.md). HEIC cannot
be finalized by ImageIO on this sandboxed host, no redistributable camera RAW is local, and the
official IPTC reference JPEG lacks an explicit asset-level redistribution grant.

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
- [x] Separate canonical stored values from localized display labels for controlled vocabularies.
- [x] Preserve Creator as an ordered sequence across JSON, XMP, repeatable IIM By-line, history,
  templates, import, batch editing, validation, and read-back while retaining the shipped scalar
  compatibility key.
- [x] Model Date Created with explicit precision and timezone-known/offset semantics while retaining
  the shipped lexical JSON/API contract and only projecting losslessly representable parts to IIM.
- [ ] Split Headline from localized `dc:title` and preserve every `rdf:Alt` language entry. The
  pinned SwiftExif API currently collapses a language alternative to `x-default`; this requires an
  upstream carrier-model change or an explicitly maintained local dependency fork before the app
  can claim lossless support.

  **Partial progress — 2026-08-23:** Headline writes now target only IPTC-IIM Headline (2:105)
  and `photoshop:Headline`; they no longer create, clear, or replace IIM Object Name (2:05) or
  `dc:title`. Existing Title carriers are preserved at the value boundary SwiftExif exposes, and
  focused builder plus embedded-JPEG tests cover distinct and absent Title values. The item stays
  open because the compatibility read fallback is still scalar and SwiftExif 1.9.10 still drops
  non-default `rdf:Alt` entries when it parses a packet.
- [x] Update metadata history so new fields produce human-readable changes without logging
  sensitive values unnecessarily.

**Progress — 2026-08-21:** Metadata history now records stable field identifiers while decoding
previously shipped label-only entries, renders canonical controlled values with human-readable
labels, and stores repeatable fields as lossless JSON arrays instead of delimiter-dependent text.
Long free text is summarized and identifiers, contact/location data, and GPS are redacted rather
than copied into the audit trail. Restore is available only when every preceding entry is exact;
unknown legacy events fail closed. Thirty-four focused history and sidecar tests pass, including
legacy migration, comma-bearing repeatable values, privacy policy, and safe restore; see
[the dated validation record](metadata-history-validation.md).

### Read/write boundary

- [x] Implement XMP and IPTC-IIM mappings from the support matrix in `SwiftExifReadService`,
  `IPTCMetadataParsing`, `SwiftExifWriteEngine`, `XMPDataBuilder`, and sidecar services.
- [x] Define normalization rules for comparison: array order, duplicate values, language
  alternatives, whitespace, URI aliases, date precision, and coordinate precision.
- [x] Ensure a descriptive save preserves Camera Raw settings and unmodeled XMP.
- [x] Ensure RAW descriptive writes update the XMP sidecar and never embed into proprietary RAW.
- [x] Make overwrite, append, clear, and untouched explicit per field. An empty value must not
  ambiguously mean both “clear” and “leave unchanged.”
- [x] Add a read-after-write verification API that returns normalized expected/actual differences.
- [x] Keep low-level I/O non-UI and `Sendable`; batch work must remain cancellable and off the main
  actor.

**Progress — 2026-08-21:** A non-UI, `Sendable` verification boundary now canonicalizes writable
metadata and returns structured per-field expected/actual differences. Its explicit rules cover
line endings and boundary whitespace, XMP Bag order and duplicates, NewsCodes URI/QCode aliases,
date precision and timezone-known state, writer-level GPS precision, ordered contact address lines,
and unordered structured Location bags. `SwiftExifReadService.verifyReadBack` reads the actual file
through the production parser before comparing it. Eight focused tests, including a real embedded
JPEG write/read/verify cycle, pass; see
[the dated validation record](metadata-read-back-verification-validation.md). Localized language
alternatives still need a richer model before they can be compared independently.

**Progress — 2026-08-21:** A separate non-UI descriptive-write boundary now treats proprietary
RAW as a hard safety boundary: embedded and dual-write requests resolve to one adjacent XMP write,
including previously unsafe persisted settings. It distinguishes merge from authoritative replace,
preserves Camera Raw plus unmodeled CRS/Lightroom XMP, rejects stale sidecar snapshots, checks
cancellation before mutation, and is used by explicit write/clear-history and RAW reverse-geocode
paths. Ten focused boundary and preset tests pass, including proof that source RAW bytes remain
unchanged; see [the dated validation record](raw-descriptive-write-boundary-validation.md).

**Progress — 2026-08-21:** All 33 stable fields now participate in exhaustive writer and
verification mappings plus a typed `Sendable` mutation contract with explicit untouched,
overwrite, append, and clear operations. Controlled values retain canonical storage independently
of display labels, and Scene history replay uses the same canonicalizer. Per-field contract,
sidecar, embedded-JPEG, preservation, and concurrency runs passed 182 tests across fifteen suites;
see [the field-operation validation record](metadata-field-operation-contract-validation.md).
Language-specific `rdf:Alt` variants remain deliberately outside the scalar model, and external
IPTC/Bridge/Photo Mechanic evidence remains manual.

**Progress — 2026-08-21:** Subject Codes, typed Media Topic CV-Terms, the separate structured Genre
property, canonical PLUS Image Supplier/Image Supplier Image ID, ordered Creator sequences, and a
precision/timezone-aware Date Created value now flow through the shared model, migration, XMP/IIM,
history, template/import, batch, UI, validation, and read-back boundaries. Earlier Photo Agent
supplier-ID namespace values and scalar Creator JSON migrate without data loss. The controlled and
Supplier gate passed 51 tests; the ordered Creator/Date gate passed 211 tests across 19 suites,
including real embedded-JPEG evidence. Full localized `rdf:Alt` editing remains blocked on the
pinned SwiftExif value model, which currently retains only `x-default`.
See the [controlled-structure validation record](metadata-controlled-structures-validation.md) and
the [Creator/Date validation record](metadata-creator-date-validation.md).

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

- [x] Unit tests for every selected field: empty, single, repeated, Unicode, clear, append,
  overwrite, and unknown-value behavior.
- [x] Fixture tests for embedded XMP, IPTC-IIM, sidecar XMP, and conflicting representations.
- [x] No-op and single-field-edit tests prove unrelated fields survive byte-semantically.
- [ ] Run IPTC Interoperability Tests 1, 2, and 3 manually and store dated results in `docs/`.
- [ ] Open representative outputs in current Bridge and Photo Mechanic and record discrepancies.
- [x] Add a CI-friendly generated support report so README claims cannot drift from tests.

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
is not mistaken for a template variable. Seven focused tests pass. At that checkpoint, versioned
profile import/export and cross-container verification remained open; profile persistence is
completed below.

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
[the dated validation record](metadata-structured-xmp-validation.md). The previously Planned
Genre, Media Topic, and Image Supplier structures are completed in the later 2026-08-21 record;
external-tool evidence and language-alternative fidelity remain open.

**Progress — 2026-08-20:** Description Writer and Creator Job Title now share stable field IDs and
flow through typed metadata, JSON persistence, history, batch editing, import, templates and
variables, rendered export, and FTP/SFTP preparation. The Additional Fields editors expose both
roles. Sidecar and embedded writes use the IPTC 2025.1 scalar Photoshop XMP properties alongside
legacy IIM 2:122 and 2:85, including authoritative clears and 32-byte compatibility warnings; the
read boundary prefers XMP and falls back to IIM. Focused interoperability, Codable, validation,
template-variable, and real-file export coverage guards the complete path. Caption placement is now
available through the profile navigator; external-tool/cross-container evidence remains open.

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
Job ID, filenames, and the structured supplier identity across typed metadata, versioned
JSON, history, batch editing, import, templates and variables, browser search, rendered export, and
FTP/SFTP preparation. New XMP sidecars and embedded JPEGs write canonical
`plus:ImageSupplierImageID`, while reads accept the legacy namespace emitted by earlier builds;
authoritative clears remove both representations and unrelated edits preserve the value. The
ordered `plus:ImageSupplier` structure separately carries supplier name/identifier pairs with
explicit batch mutations and read-back verification. The earlier scalar model, persistence,
variable, interoperability, and real-file export suites passed 166 tests; the current combined
controlled-field/Supplier gate passed 51 tests across four suites; see
[the dated validation record](metadata-image-supplier-id-validation.md).
External-tool and cross-container verification remains open.

## Phase 2 — Caption Workspace

**Exit gate:** a photographer can caption a folder image by image using the keyboard, never lose an
edit during navigation, and see exactly what prevents each image from being desk-ready.

### Workspace and session model

- [x] Add `MainViewMode.caption` and a first-class Caption Workspace entry in the layout/workspace
  selector and View menu.
- [x] Introduce `CaptionSession` to own ordered images, current index, selection, dirty state,
  validation results, and focus restoration.
- [x] Reuse `MetadataViewModel` write/reconciliation behavior; do not create a second metadata save
  path inside the view.
- [x] Keep current non-destructive behavior: navigation commits edits to the app sidecar, while an
  explicit command writes pending metadata to the image/XMP boundary.
- [x] Flush buffered text before navigation, selection changes, template application, write, send,
  workspace exit, and quit.
- [x] Prevent a stale asynchronous load for the previous image from replacing the current draft.

**Progress — 2026-08-21:** `CaptionSession` now backs a first-class workspace entered from the
layout selector or View menu. The workspace reuses `MetadataPanel`/`MetadataViewModel`, commits
buffered AppKit text to the app sidecar before navigation, filmstrip selection, templates, explicit
write, close, and outside workspace transitions, and leaves the current image in place when the
flush fails. Explicit Write remains a separate configured image/XMP reconciliation action. The UI
adds a large preview/filmstrip, sticky filename/position/rating/label/pending/readiness status, and
Previous, Save & Next, Write, Apply Template, and Close actions. Generation tokens reject stale
preview results, and validation uses the shared engine. Nine focused tests and the full app/test
target build pass; see [the dated validation record](caption-session-validation.md). Full-resolution
native-pixel tiled preview and the manual focus/accessibility pass remain outside this original
session slice; the bounded edited preview, profile navigator, speed tools, and termination flush are
recorded below.

**Progress — 2026-08-21:** Application termination now defers AppKit's reply, drains Caption's
existing persistence FIFO before Develop, retains failed drafts for exact retry, and offers retry,
keep-open, or explicit quit-without-saving outcomes behind a duplicate-reply latch. Rapid opposite
navigation, failed-write retry, no duplicate capture, flush ordering, and focus-return cases pass in
a 53-test five-suite run; see
[the termination durability record](caption-termination-durability-validation.md). The real macOS
termination modal and live AppKit responder behavior remain manual observations.

### Layout

- [x] Large, color-managed image/edited-preview area on the left.
- [x] Compact profile-ordered priority navigator on the right that focuses the established durable
  MetadataPanel controls; a future component refactor may physically reorder those stateful fields.
- [x] Sticky top status: filename, position, rating/label, pending state, and Ready/Warnings/Blocked.
- [x] Sticky bottom actions: Previous, Save & Next, Write, Apply Template, Copy Previous, and Fix
  Next Issue.
- [x] Allow secondary and technical fields to expand without pushing the priority caption fields
  off screen.
- [x] Show per-field required/warning state inline with concise remediation, not only as a tooltip.
- [x] Show caption/headline character counts and optional profile limits.
- [x] Provide fit/bounded-preview 100% zoom, full-screen preview, and confirmed face rectangles
  without intentionally leaving caption focus.

### 3.0 hands-on usability follow-up

The following items come from hands-on testing on 2026-08-23 and remain release work even though
the underlying Caption, validation, and metadata-field infrastructure is implemented:

- [x] Reduce the Caption Workspace metadata-checklist footprint. Keep readiness and the next
  actionable issue visible, but make the complete checklist compact or collapsible so it does not
  reserve a disproportionate share of the editing area.
- [x] For a fresh install or an explicit reset to defaults, show only Headline, Description,
  Keywords, Creator, Copyright Notice, Person Shown, and Rights Usage Terms. Preserve an existing
  user's customized visibility and ordering during upgrade.
- [x] Add a persistent footer below the visible Caption metadata fields explaining that additional
  IPTC fields can be enabled in Settings → Metadata, with a direct action to open that settings
  pane when practical.
- [x] Give every metadata field label concise IPTC guidance: its common editorial use plus a short
  example. Expose the same guidance through hover help, keyboard focus/accessibility help, and
  localization-ready copy rather than making it pointer-only.
- [ ] Replace the separate visible/hidden and required-field management lists in Metadata Settings
  with one coherent field-management UI that shows visibility and required state together and
  supports drag, keyboard, and VoiceOver reordering. The configured order must be reflected
  consistently in the metadata panel and Caption field navigator, while required validation stays
  independent of whether a field is currently visible.
- [ ] Add migration/default tests, ordering persistence and unknown-field recovery tests, and UI
  coverage for the compact checklist, settings link, field guidance, and accessible reordering.

**Progress — 2026-08-23:** Caption's metadata checklist now starts collapsed and retains a compact,
always-visible readiness/count summary plus the shared engine's next actionable blocker or first
actionable remaining issue as a direct focus action. The full priority and secondary field lists
remain available behind native disclosure controls, and the no-Deadline-profile navigator now
excludes fields hidden by the existing metadata visibility settings. Twelve focused speed-tool and
guidance tests and the production app build pass; see
[the compact-checklist validation record](caption-workspace-checklist-validation.md). Fresh-install
and explicit-reset visibility now use the seven-field editorial default while an existing stored
visibility choice remains authoritative during upgrade. Every stable field now supplies localized
editorial-use/example guidance through shared Metadata panel hover help and accessibility hints;
see [the field-guidance validation record](metadata-field-guidance-validation.md). Unified field
management, persisted ordering, and their broader migration/accessibility coverage remain owned by
the separate items above. A persistent footer below the editor now explains where to enable
additional IPTC fields and opens Settings directly on its Metadata section through a consumed,
non-persisted navigation request.

### Caption speed tools

- [x] “Save & Next” and “Write & Next,” with separately configurable shortcuts.
- [x] Copy selected fields from previous image; default to caption/headline/persons/keywords while
  protecting capture-specific fields.
- [x] Apply metadata template in replace or append mode without losing focus.
- [x] Field-aware autocomplete from approved lists, structured keywords, Known People, current
  folder values, and optional UTF-8 text lists.
- [x] Photo Mechanic-compatible tab-delimited code-replacement lists with explicit delimiters,
  enable/disable state, source-file diagnostics, and a replacement preview.
- [x] Never replace text inside an uncommitted IME composition or silently expand an ambiguous
  code.
- [x] Keep confirmed face/roster names separate from suggestions; inserting a suggestion is an
  explicit user action.
- [x] Add “persons left to right” ordering UI without inferring the order when face geometry is
  uncertain or the user has not confirmed identities.
- [x] Add system spelling/grammar support to caption-like fields without modifying names or codes.

**Progress — 2026-08-21:** Caption Workspace now offers Copy Previous in replace or append mode
after crossing the same buffered-text/sidecar flush barrier as navigation. A pure configurable
service defaults to caption, headline, people, and keywords, preserves list order while
deduplicating appends, and returns structured applied/skipped/protected results without logging
values. GUID/supplier ID, creation/capture dates, legacy and structured created location/GPS,
rating/label, Camera Raw, and orientation remain protected even when explicitly requested and
allowlisted. Previous metadata is resolved read-only with pending app sidecar precedence and a
stale-load token prevents publishing into a changed session. Seventeen focused service/session
tests pass; see [the dated validation record](caption-copy-previous-validation.md).

**Progress — 2026-08-21:** A pure code-replacement foundation now parses the interoperable
Photo Mechanic-style UTF-8 `code<TAB>replacement` subset with explicit delimiters and enable state,
line-ending/BOM handling, source-line diagnostics, deterministic preview, and literal delimiter
escaping. Conflicting duplicate codes and delimiter-containing codes remain unchanged with typed
diagnostics, invalid encoding blocks the list, and active IME composition refuses the whole
operation. Security-scoped source settings expose every diagnostic, and the explicit Caption
Workspace command checks the real AppKit marked-text state before flushing, previews eligible
caption fields atomically, and revalidates the exact image plus complete draft before Apply.
Thirty-one combined parser/integration/session tests pass; see the
[engine record](code-replacement-validation.md) and
[Caption Workspace integration record](caption-code-replacement-validation.md).

**Progress — 2026-08-21:** Caption Workspace now combines field-scoped suggestions from approved
lists, structured keyword/person vocabularies, Known People, already loaded current-folder values,
and UTF-8 quick lists. The explicit Option-Space/toolbar action captures the exact focused field,
checks real marked text before opening and insertion, and applies scalar replacement or ordered
repeatable append/dedup semantics. Known People remain provenance-only suggestions and never alter
confirmed face/roster identity. Twelve focused tests pass; see
[the dated validation record](caption-autocomplete-validation.md). Live VoiceOver, native menu/
responder behavior, and manual keyboard/IME validation remain open.

**Progress — 2026-08-21:** Caption Workspace now uses the bounded production edited/color-managed
preview with Fit/100%, Full Screen, and confirmed-face overlays; exposes a Deadline-profile-ordered
priority navigator plus secondary fields, inline issues, counts/limits, and Fix Next; and provides
durable Save/Write & Next, template/copy modes, confirmed left-to-right people, and prose-only
spelling/grammar. Its two independently persisted shortcuts route through a marked-text-aware local
monitor. Thirty-one speed/session/accessibility tests pass; see
[the speed-tools validation record](caption-workspace-speed-tools-validation.md). A referenced
validation profile is not synchronously resolved here, and native-resolution tiled viewing plus
hands-on focus/IME/VoiceOver/visual checks remain explicit.

### Keyboard and accessibility

- [x] Replace the read-only rating/label shortcut reference with assignable commands and conflict
  detection; keep broader fixed app/menu/tool commands documented until an app-wide rebinding
  architecture is deliberately introduced.
- [x] Ship Photo Agent, Photo Mechanic-like, and Bridge-like culling shortcut presets.
- [x] Define predictable Tab/Shift-Tab order and an escape route from token editors/popovers.
- [x] Keep bare rating/label keys active only when a text editor is not consuming them.
- [x] Add VoiceOver labels, issue summaries, and privacy-safe announcements after Save & Next and
  Write & Next.

**Progress — 2026-08-21:** All ten primary workspaces now expose stable accessibility semantics and
keyboard-operable controls, including real metadata rating/label buttons and adaptive Caption/
Activity sizing. A persisted fifteen-command culling registry supplies Photo Agent, Photo
Mechanic-like, Bridge-like, and Custom profiles with bounded assignment, explicit unassigned state,
conflict remediation, and shared Browser/Comparison/Develop/Full Screen routing that refuses text,
IME, and repeat events. Ninety-four focused/adjacent tests pass; see
[the accessibility and keyboard audit](accessibility-keyboard-audit-validation.md). App-wide dynamic
rebinding and the manual assistive-technology pass remain outside this bounded implementation.

### Verification

- [x] Navigation/dirty-state tests, including rapid next/previous and failed sidecar writes.
- [x] Focus tests for template, code replacement, autocomplete, popovers, and workspace return.
- [x] Tests proving copy-previous never overwrites excluded capture-specific fields.
- [x] Batch selection tests for common/mixed/partial list values.
- [ ] Manual keyboard-only pass through at least 100 images without mouse use.
- [ ] Manual test at small and large window sizes, with long Unicode captions and many people.

## Phase 3 — Batch Rename

**Exit gate:** users can preview every resulting filename and associated artifact action, resolve all
conflicts before execution, cancel safely, and trust rollback/reporting after failure.

### Rename recipe and token engine

- [x] Introduce versioned `BatchRenameRecipe`, reusable by browser rename, import, export, and later
  Deadline Mode.
- [x] Support literal components and documented tokens at minimum:
  - Original basename and extension.
  - Sequence with start, increment, and zero padding.
  - Capture date/time with explicit format and file-date fallback policy.
  - Metadata fields such as creator, job ID, event, city, and country code.
  - Camera make/model/serial where available.
  - Rating and color label.
- [x] Use the existing variable/interpolation concepts where semantics match, but keep filename
  sanitation and missing-token policy specific to rename.
- [x] Add literal and regular-expression substitution stages with testable ordering.
- [x] Provide case conversion, whitespace replacement, and filesystem-safe sanitization.
- [x] Optionally write the original filename to the appropriate XMP field before rename.
- [x] Make a missing value an explicit recipe choice: empty, fallback text, preserve original, skip,
  or block.

**Progress — 2026-08-21:** A versioned, pure `BatchRenameRecipe` and renderer now cover literal and
typed tokens, configurable sequences, POSIX/date-timezone formatting with capture fallbacks,
metadata/camera/rating/label/job/import values, ordered literal/regex substitutions, deterministic
case and whitespace transforms, filesystem sanitation, Unicode normalization, and all five
missing-value outcomes. The engine has no UI or filesystem dependency, so browser, import, export,
and Deadline Mode can share it. Eleven focused tests and a production build pass; see
[the dated validation record](batch-rename-recipe-validation.md). Planning, preview, and execution
are now integrated below; recipe persistence and original-filename XMP writing remain open.

### Plan and preview UI

- [x] Replace the `NSAlert` with a resizable sheet.
- [x] Show preset selector, component editor, live sample, and complete old → new preview table.
- [x] Preview in the same sorted order used to allocate sequence numbers.
- [x] Show conflicts, invalid names, missing values, duplicates within the batch, existing
  destinations, and case-only collisions before enabling Rename.
- [x] Add collision policies: block batch (default), skip, or append a deterministic suffix.
- [x] Save, duplicate, rename, import, and export recipes.
- [x] Display a summary of associated artifacts that will follow each image.

**Progress — 2026-08-21:** `RenamePlanningService` now turns the renderer's visible-order results
into an immutable old-to-new plan with structured issues, complete destination reservations, and
associated-artifact actions/summaries. An extensible registry currently discovers the image, XMP,
current and legacy `.photo_metadata` sidecars, plus caller-supplied filename-keyed artifacts.
Injected existing paths and case sensitivity make duplicate, occupied, case-only, invalid-name,
and missing-value behavior deterministic under block, skip, or suffix policies. Fixed-point source
dependency validation permits two-way and longer rename cycles only when every source will really
move. Thirteen planner tests pass; see
[the dated validation record](batch-rename-planning-validation.md). The browser editor/preview and
transactional executor integration are now recorded below.

**Progress — 2026-08-21:** Browser single and batch image rename commands now share a resizable
SwiftUI component editor and complete old/requested/planned preview table over a frozen path and
case-sensitivity snapshot. Typed row text and aggregate badges expose conflicts, missing/invalid
values, case behavior, collision policy, and associated artifacts. Rename executes only the
confirmed immutable plan through `RenameExecutionService`; the former direct image `FileManager`
paths are gone. Success projects cycle-safe URLs into selection, last-click, manual order, and
old/new cache invalidation. Failure reloads authoritative folder state and cannot reuse a stale
plan; only a clean rollback may refresh the original request. The integrated recipe/planner/
executor/sheet run passes 44 tests in four suites; see
[the dated validation record](batch-rename-ui-validation.md). Recipe persistence/presets and the
richer renderer token/transform editor remain open.

**Progress — 2026-08-21:** The browser sheet now includes a versioned, atomically persisted recipe
library with stable IDs, deterministic selection, schema migration, collision/no-overwrite rules,
and a FIFO gate over complete read/modify/write transactions. Ad Hoc and per-preset drafts survive
switching, all management/import/export actions rebuild the immutable plan, and the complete
renderer representation round-trips even when an advanced option has no compact editor control.
Twenty-eight recipe/repository/sheet tests pass, including deliberately overlapping mutations; see
[the dated validation record](batch-rename-recipe-library-validation.md). Direct controls for the
remaining advanced transforms and tokens remain open.

### Transactional execution

- [x] Create `RenamePlanningService` and `RenameExecutionService`; remove filesystem mutation from
  `BrowserViewModel`.
- [x] Treat each image and its sidecars/references as one rename bundle.
- [x] Audit and include:
  - Image file.
  - `.xmp` sidecar.
  - Current and legacy `.photo_metadata` JSON sidecars and their `sourceFile` value.
  - Folder face-data references.
  - Any filename-dependent analysis/project references.
  - Cached thumbnails and in-memory browser/manual-order selections.
  - Any future filename-keyed artifact through one registry/service rather than another view-model
    special case.
- [x] Preflight permissions and reserve all destinations before the first mutation.
- [x] Handle rename cycles (`A` → `B`, `B` → `A`) through unique temporary names in the same
  directory.
- [x] Use staged two-phase execution and best-effort rollback with a detailed recovery result.
- [x] Update original-filename metadata before or after filesystem mutation according to an
  explicitly tested transaction order.
- [x] Invalidate affected metadata, full-screen, thumbnail, and edited-preview caches.
- [x] Keep selection and manual order stable after a successful rename.
- [x] Provide cancellation only at safe transaction boundaries.

**Progress — 2026-08-21:** `RenameExecutionService` now consumes only an executable immutable
plan, rechecks live sources, exact destinations, directory writability, reservations, and bounded
same-directory temporary paths, stages every artifact before committing any destination, and
supports two-way and longer cycles. Cancellation and injected failures are observed only at safe
boundaries and trigger best-effort rollback with actual-path probing, explicit rollback status,
and precise residuals including missing artifacts. Current and legacy metadata JSON sidecars update
`sourceFile` on success and restore original bytes on rollback. Fourteen tests pass across
single/many/no-sidecar cases, full image/XMP/JSON/custom cycles, every forward failure/cancellation
boundary, permission refusal, and rollback failure; see
[the dated validation record](batch-rename-execution-validation.md). Browser sheet/state/cache
integration is now complete below; filename-keyed registry reassociation and original-filename XMP
are recorded in the following progress entries.

**Progress — 2026-08-21:** The successful browser path now flushes pending named Develop changes,
then reassociates every proven URL-keyed app record with the complete cycle-safe mapping. Folder
face/number-detection/scanned-file references and analysis source hints persist at their new paths
without changing identity hashes, while live comparison/Clean Feed and analysis state preserve
focus, layout, viewports, representations, case identity, and evidence. Content-hash-keyed Develop
catalogs are intentionally not rewritten; a real two-way RAW/XMP cycle proves settings and named
versions follow the correct source bytes. Sixty-five integrated tests pass; see
[the reassociation validation record](batch-rename-reassociation-validation.md). Post-success
face/analysis persistence reports typed recovery issues.

**Hardening — 2026-08-21:** Comparison rename mapping and availability reconciliation now publish
as one coordinator transition, and face/analysis/comparison mappings share the same symlink-aware
canonical URL identity as captured source revisions. Race-order and symlinked-folder regressions
pass in the independent 51-test audit run.

**Hardening — 2026-08-21:** A target-folder writer barrier now cancels and awaits the exact active
face scan through final persistence, drains lens-prewarm/face-metadata work, and gates Analysis
saves across the filesystem transaction. Late Analysis changes drain only after destination hints
are applied; preparation failure performs zero moves, and a failed executor cannot later restore
an old hint. The final 118-test run covers actual session ordering, scan restart reservation, and
late Analysis persistence under a real rename.

**Progress — 2026-08-21:** Recipes now opt in explicitly to preserving the pre-rename filename as
Adobe XMP Media Management `xmpMM:PreservedFileName`; legacy recipes default off and IPTC
Transmission Reference remains the independent Job ID. JPEG embedded XMP and existing RAW sidecars
join the staged transaction, RAW without a sidecar blocks, and cancellation/failure restores exact
metadata bytes before source paths. Fifty-seven rename tests plus the final four transaction-order
cases pass; see [the original-filename validation record](batch-rename-original-filename-validation.md).

### Verification

- [x] Pure recipe/token tests, including locale-independent dates and Unicode normalization.
- [x] Plan tests for duplicate targets, existing files, case-insensitive volumes, and missing data.
- [x] Execution tests for single, many, cycles, XMP/JSON sidecars, and no-sidecar files.
- [x] Failure injection after every move step proves rollback or precise partial-failure reporting.
- [x] RAW + XMP develop settings still load after rename.
- [x] Face data, named Develop versions, comparison, and analysis reassociate after rename.
- [ ] Manual cross-tool check that preserved original filename is visible in Bridge/Photo Mechanic.

## Phase 4 — Deadline Mode foundation

**Exit gate:** an assignment can have one saved definition of “ready,” and every selected image has
a deterministic, actionable preflight result before delivery starts.

### Deadline profile

- [x] Add versioned `DeadlineProfile` containing references or snapshots for:
  - Metadata validation profile.
  - Visible/ordered caption fields.
  - Metadata template and variable-processing policy.
  - Filename recipe and collision policy.
  - Export/render settings and output naming.
  - Destination connection identifier and remote path template.
  - GPS removal/retention policy.
  - Metadata write strategy: originals, XMP sidecars, or staged delivery copies.
- [x] Store secrets only in Keychain-backed connection records; exported profiles contain stable
  connection references, never passwords or private keys.
- [x] Detect missing templates, lists, connections, and unsupported newer profile versions.
- [x] Make profiles importable/exportable. A richer assignment package with rosters and vocabulary
  files can be added later without changing delivery execution.

**Progress — 2026-08-21:** A pure, versioned `DeadlineProfile` now carries reference-or-snapshot
validation, template, rename, and export configuration; ordered/visible caption fields; required
list references; collision and template-variable policies; stable destination connection ID/path;
GPS policy; and originals/XMP/staged-copy write strategy. JSON import/export uses safe defaults for
the initial unversioned shape, rejects newer schemas before decode, and refuses to overwrite a
newer destination. Profiles cannot contain connection credentials; existing connection passwords
remain in Keychain. Deterministic diagnostics report every missing referenced profile, template,
list, recipe, export configuration, and connection. Seven focused tests and the full app/test
target build pass; see [the dated validation record](deadline-profile-validation.md). The first
preflight/workspace integration is recorded below.

**Progress — 2026-08-21:** Deadline profiles now live in an atomically persisted, versioned catalog
with stable IDs, deterministic selection, schema migration, and create/duplicate/rename/import/
export/confirmed-delete management. Deadline Workspace evaluates only the selected saved profile;
it no longer manufactures a `Current Deadline` definition. Live template and secret-free
connection inventories are projected safely, while stores without stable adapters and uncaptured
permission/rename/render/staging/reachability facts remain typed blockers. Twenty combined
repository/preflight/coordinator tests pass; see
[the saved-profile validation record](deadline-profile-repository-validation.md). At that
checkpoint, a complete editor, revisioned resource adapters, and delivery execution remained open;
the live adapters and verified Send path are completed in the later records.

**Hardening — 2026-08-21:** An independent concurrency/security pass added an exclusive async gate
around every complete Deadline repository transaction, disabled overlapping management actions,
restricted destination references to the canonical UUID used by the Keychain-backed FTP store,
and added 24-way overlapping-mutation plus token/credential rejection regressions.

### Preflight engine

- [x] Implement `DeadlinePreflightService` as a pure/cancellable coordinator over existing engines.
- [x] Check per image:
  - Metadata profile rules.
  - Unresolved variables and pending/failed sidecar writes.
  - Filename recipe result and conflicts.
  - Source availability, permissions, and supported render/write format.
  - Stale XMP/embedded descriptive conflicts.
  - C2PA consequences, reported separately from ordinary metadata readiness.
  - Export dimensions, format, gamut, and maximum-size requirements.
- [x] Check per batch:
  - Duplicate output names.
  - Destination free space and staging availability.
  - Connection configuration and optional non-destructive reachability test.
  - Remote-path validity.
- [x] Classify results as blocker, warning, or information and order “Fix Next Issue” predictably.
- [x] Cache only against explicit source/metadata/profile revision tokens; invalidate immediately on
  relevant edits.

**Progress — 2026-08-21:** `DeadlinePreflightService` now evaluates immutable snapshots through the
shared validation and rename-planning engines, with cooperative cancellation and deterministic
severity/check/image ordering. Typed issues cover missing referenced profiles/templates/lists/
recipes/exports; scalar and structured contact/location placeholders; pending or failed sidecars;
source access/decode/write capability; stale descriptive conflicts; distinct C2PA consequences;
SDR/HDR format and gamut capability; dimensions/downscaling; rename collisions; free space,
staging, connection reachability, and remote paths. Seven focused tests pass; see
[the dated validation record](deadline-preflight-validation.md). The coordinator supports a seven-part composite revision
token, bounded invalidation, cancellation, latest-wins publication, and an explicit bypass used by
the first live workspace while some backing stores lack trustworthy revisions; see the integration
record below.

**Progress — 2026-08-21:** Export snapshots now carry an optional backward-compatible per-output
encoded-byte ceiling. Preflight blocks trustworthy estimates over the limit and reports an explicit
warning when the production adapter cannot predict the encoder result. The authoritative staging
boundary measures the final bytes after metadata read-back and preservation verification, refuses
oversized artifacts before SHA/upload eligibility, and retains the frozen limit in confirmation
and receipt evidence. Seventy-seven focused tests pass; see
[the maximum-output-size validation record](deadline-maximum-output-size-validation.md).

### Deadline UI

- [x] Redesign the Deadline Workspace information hierarchy based on hands-on testing. Make the
  selected profile, current phase, readiness summary, next required action, planned outputs, and
  Send eligibility understandable without knowledge of the internal preflight model; provide
  useful empty, partially configured, blocked, running, failed, and completed states.
- [ ] Run a first-use usability pass for Deadline with representative incomplete and ready
  assignments, then record the observed confusion points and approved layout/remediation changes in
  a dated validation note.
- [x] Add a Deadline Mode workspace with a phase/status strip:
  `Select → Caption → Verify → Send`.
- [x] Show aggregate readiness (`21 of 24 ready`) and counts by issue type.
- [x] Filter current per-image preflight to blockers, warnings, or ready; show failed and sent
  delivery batches in Activity rather than fabricating per-image state from privacy-shaped receipts.
- [x] “Fix Next Issue” opens the correct image and focuses the relevant Caption Workspace field or
  rename/profile setting.
- [x] Show the exact output filenames, format, destination, and write policy before enabling Send.
- [x] Keep the rest of the app usable while preflight runs.

**Progress — 2026-08-21:** A first-class Deadline Workspace now evaluates the selected image
snapshot asynchronously and presents the four-stage strip, readiness totals, blockers/warnings/
ready filters, exact planned filenames, write strategy, and destination. Fix Next routes an
image-scoped issue into Caption Workspace; the verified Phase 5 Send composition is now recorded
below.
The actor coordinator caches only exact seven-part revision tokens, cancels superseded work, and
suppresses evaluators that ignore cancellation. The live adapter deliberately bypasses caching
until every backing store has a trustworthy revision and blocks original-file strategies when
writability is unknown instead of assuming permission. Thirteen combined service/coordinator
tests pass; see [the dated validation record](deadline-workspace-validation.md). Saved profile
selection, revisioned live resource adapters, and export-format confirmation are now implemented.
Failed/sent per-image row filters remain open because privacy-safe batch history has no image
identity; typed field-level remediation is recorded below.

**Progress — 2026-08-21:** Every typed preflight issue now resolves to an exhaustive semantic
remediation destination. Editable fields carry the exact image and `MetadataFieldID` into Caption
focus; source, rename, export, connection, profile, and staging issues route to their real existing
surfaces and fail closed when required image identity is absent. Thirty-seven focused/adjacent tests
pass; see [the remediation validation record](deadline-remediation-validation.md). Sent/Failed remain
honest batch history in Activity because privacy-safe receipt/workflow summaries deliberately omit
per-image identity; the current-preflight image filter does not fabricate that association.

**Progress — 2026-08-21:** The live workspace now captures filesystem/source/decode, rename
inventory and case sensitivity, resource registries, exact production export/write capabilities,
and application staging write/capacity facts outside SwiftUI body evaluation. Replaced captures
cancel the actual detached scan and stale results cannot publish. Runtime and preflight share one
capability matrix, so unsupported originals/XMP-sidecar delivery strategies and carriers are typed
blockers rather than late execution failures. Twenty-three combined tests pass; see
[the live snapshot validation record](deadline-live-preflight-validation.md). Event-backed
permission/reachability revisions and broader custom resource stores remain open; per-output size
limits and honest estimate semantics are completed below.

**Progress — 2026-08-24:** Deadline Workspace now presents the selected saved profile, one coherent
current phase, readiness, next required action, Send eligibility, and planned outputs as distinct
top-level concepts. Caption blockers lock Verify instead of marking both phases current. Empty,
evaluating, partially configured/blocked, warning-ready, running, failed, cancelled, and completed
delivery states provide state-specific guidance. The Send button and its explanatory copy share one
execution-owned availability result, so stale preflight, blockers, unsupported write policy,
missing exact source identities, active confirmation, and retained resumable work cannot acquire an
optimistic UI label. Eighteen focused coordinator/workspace tests pass; see
[the information-hierarchy validation record](deadline-information-hierarchy-validation.md).
The separate first-use hands-on usability pass remains open.

### Verification

- [x] Profile Codable/migration tests and secret-exclusion tests.
- [x] Deterministic preflight results for identical input/profile revisions.
- [x] Cancellation and stale-result suppression tests.
- [x] Tests that every blocker links to a valid remediation target.
- [ ] Manual preflight on mixed JPEG/RAW, missing sidecars, offline iCloud files, C2PA files, and
  read-only sources.

## Phase 5 — verified send and delivery receipt

**Exit gate:** a ready batch can be staged, written, read back, uploaded, retried, and audited without
silently delivering a file whose metadata differs from the confirmed plan.

### Delivery plan and staging

- [x] Freeze a `DeliveryPlan` from the current profile, selected source revisions, resolved
  metadata, rename outputs, render settings, and preflight results.
- [x] Default to creating staged delivery files so source photographs are not mutated during a
  deadline send. Allow in-place metadata writes only as an explicit profile policy.
- [x] Stage into a unique batch directory with sufficient free-space preflight and bounded cleanup.
- [x] Render/copy, apply resolved descriptive metadata, then read back from the actual staged bytes.
- [x] Compare normalized expected/actual values for every field controlled by the profile.
- [x] Confirm unrelated metadata preservation against the source according to the format's support
  boundary.
- [x] Block upload on read-back mismatch unless the user explicitly returns to fix/replan; do not
  offer “send anyway” for hard verification failures.

**Progress — 2026-08-21:** A pure, versioned `DeliveryPlanningService` now freezes the exact
profile/preflight revision and result, source and Develop identities, resolved metadata, output
names, render/write/GPS settings, destination UUID/path, and explicitly accepted warning IDs into
deterministic batch and per-item fingerprints. It rejects blockers, unaccepted warnings, stale or
incomplete inputs, profile/source/metadata/Develop/rename drift, unsafe paths, credential-shaped
destinations, and fingerprint tampering. Strict JSON import/export fails closed for newer schemas
and existing destinations. Eight focused tests pass; see
[the dated validation record](delivery-plan-validation.md). This was the frozen planning
foundation; staging, verification, upload, and receipt execution are completed in the records below.

**Progress — 2026-08-21:** `StagedDeliveryCoordinator` now revalidates plan/profile/source identity,
requires a renderer-aware estimate within captured free capacity, creates one unique batch
directory, and processes items sequentially through render/copy, descriptive write, actual-byte
read-back, and every controlled verification field. Mismatch cannot cross the sealed upload
boundary. The exact verified bytes receive a SHA-256 consumed by upload, while typed failure/
cancellation results retain files until explicit path-constrained cleanup. A mandatory independent
EXIF/IPTC/XMP/Camera Raw comparison now rejects both concrete loss and unconfirmed reads while
retaining explicit unsupported carrier outcomes; C2PA carriage is reported separately from
provenance validity. Seventeen combined preservation/staging tests pass; see
[the staging record](staged-delivery-validation.md) and
[preservation record](delivery-metadata-preservation-validation.md). The production adapter and
composition work is recorded below.

### Upload and activity

- [x] Extend activity state to explicit stages: queued, staging, writing, verifying, uploading,
  remote-confirming, sent, failed, cancelled.
- [x] Resume/retry at file boundaries without rerendering already verified staged files whose plan
  fingerprint still matches.
- [x] For FTP/SFTP, confirm remote existence and size after transfer when supported. Do not label
  that as cryptographic remote verification.
- [x] Keep local SHA-256 for the delivered bytes and record protocol/server acknowledgement.
- [x] Abort leaves verified staging files recoverable until the user chooses cleanup.
- [x] Never log credentials, captions, private keys, or full sensitive metadata by default.

**Progress — 2026-08-21:** A sealed verified-staging boundary and injected upload coordinator now
require exact plan/stage fingerprints, controlled-field success, safe paths, and the SHA-256/size of
the exact read-back bytes. Current bytes are re-inspected before every file, so same-size tampering
is refused. Protocol acknowledgement remains distinct from optional non-cryptographic remote stat;
typed state and coherent sequential-prefix checkpoints support failure/relaunch retry, while
cancellation waits for the active file and retains staging. Eight focused tests pass; see
[the dated validation record](verified-delivery-upload-validation.md).

**Progress — 2026-08-21:** The production transport adapter resolves only canonical connection
UUIDs, validates all non-secret upload inputs before Keychain access, and confines credential use to
a mode-0600 netrc file inside the FTP service boundary. FTP, explicit FTPS, and SFTP uploads preserve
the coordinator's active-file cancellation contract; optional remote HEAD/SIZE evidence is recorded
as non-cryptographic and remains unavailable when a server cannot support it. Eight transport tests
and sixteen adjacent legacy FTP tests pass; see
[the production transport record](delivery-ftp-transport-validation.md). Password/netrc SFTP is
supported; SSH private-key identity remains outside the current connection model.

**Progress — 2026-08-21:** The production staging factory now binds the frozen plan to the existing
renderer, safe rendered-file metadata writer, actual-byte reader, controlled/unrelated verifiers,
source revision inspector, and conservative capacity estimator. Preflight and execution share the
same staged-copy/format/gamut matrix, and output ICC evidence is retained and verified. Six live
adapter tests plus twenty-five adjacent preservation/write/export tests pass; see
[the production staging record](delivery-production-staging-validation.md).

**Progress — 2026-08-21:** The delivery workflow now persists the explicit lifecycle and
file-boundary checkpoint, separately seals full staging evidence, resumes without rerendering,
repairs the staging-evidence/manifest crash window, and de-duplicates a receipt written just before
terminal-manifest failure. Twelve focused declarations pass across success, boundary failure,
relaunch, invalidation, privacy, and cancellation; see
[the workflow validation record](delivery-workflow-validation.md). Production registry and Deadline
Send composition are recorded below.

**Progress — 2026-08-21:** A private per-workflow registry now atomically claims canonical UUID
directories, stores an immutable frozen plan plus manifest/staging evidence with restrictive
permissions and backup exclusion, validates exact staged SHA-256/size evidence on relaunch, and
publishes only privacy-safe state/count summaries. It fails closed for path escape, symlinks,
duplicates, corrupt or partial state outside the intentional crash window, newer schemas, identity
drift, and missing bytes. Nine focused tests pass; see
[the registry validation record](delivery-workflow-registry-validation.md). New profiles default to
staged-copy writes while the decoder preserves the documented legacy strategy fallback.

**Progress — 2026-08-21:** Deadline Workspace now retains exact preflight publications, aligned
Develop snapshots, and off-main source SHA-256 revisions; a fresh source hash plus current
metadata/Develop/profile/token state is revalidated before freezing the confirmation. Explicit
batch-scoped warning acceptance, complete output/destination/render/C2PA confirmation, production
registry/staging/transport/receipt composition, safe-boundary cancellation, receipt reload, and
fail-closed relaunch recovery are wired. Sixty-three focused tests across six suites pass; see
[the Deadline Send validation record](deadline-send-validation.md). Automatic recovery deliberately
refuses to guess among multiple retained workflows; explicit Activity selection is tracked below.

**Progress — 2026-08-21:** An independent integration audit hardened actor reentrancy, staging and
upload cancellation propagation, immediate pre-transport byte reinspection, canonical connection
identifiers, remote-path validation, and registry symlink classification. The unique audit sweep
passed 127 tests across fourteen suites; see
[the integration hardening record](delivery-integration-hardening-validation.md). The remaining
path-to-curl-open interval is documented as a transport-level TOCTOU requiring an fd-backed design
to eliminate completely.

**Progress — 2026-08-21:** Activity now lists privacy-safe workflow summaries for all explicit
lifecycle stages, supports exact UUID-selected recovery when multiple workflows are retained, and
requires confirmation before removing only the selected local workflow/staging. A session-owned
reservation closes the validation/navigation/cleanup race and is released on abandonment or
failure. Thirty-six focused Activity/Deadline/registry/receipt tests pass; see
[the workflow Activity validation record](delivery-workflow-activity-validation.md). No lifecycle
path automatically deletes staging or receipts.

### Receipt

- [x] Write an atomic, versioned JSON receipt containing:
  - Batch/profile/app version and timestamps.
  - Source identity and delivered filename for each image.
  - Delivered-byte SHA-256 and size.
  - Metadata verification result and controlled field IDs, without duplicating sensitive values by
    default.
  - Render settings and destination identifier/path.
  - Upload and remote-stat result.
  - Warnings accepted before the delivery plan was frozen.
- [x] Provide a concise human-readable summary/export generated from the receipt.
- [x] Make receipts inspectable from Activity and resilient to app relaunch.
- [x] Define retention and manual deletion; never sync receipts implicitly through iCloud.

**Progress — 2026-08-21:** A schema-v2 privacy-shaped receipt and atomic local repository now cover
batch/profile/app/timestamps; content identities and delivered-byte hashes/sizes; the complete typed
verification-field registry and identifier-only issues; actual render/destination facts; distinct
protocol-upload and remote-size-stat acknowledgements; and uniquely scoped accepted warning IDs.
Deterministic retention/list/read/manual-delete operations, v1 migration, corrupt recovery,
duplicate no-overwrite, and nested future-schema downgrade protection are tested. Human summaries
omit hashes, filenames, credentials, and editorial values. Twelve focused repository tests pass;
see [the dated validation record](delivery-receipt-validation.md).

**Progress — 2026-08-21:** The pure terminal assembler now revalidates frozen plan, staging,
preservation, exact bytes, upload, checkpoint, render, warning-scope, and timestamp evidence before
it can construct a persistable receipt. Nine focused tests pass; see
[the assembly validation record](delivery-receipt-assembly-validation.md). Activity reloads the
repository across app launches and provides privacy-safe inspection, confirmed deletion, and
exclusive no-overwrite summary export. Eighteen repository/Activity tests pass; see
[the Activity validation record](delivery-receipt-activity-validation.md). The delivery workflow
now records the receipt only after revalidating terminal staging/upload evidence, retains the
assembled receipt and staging evidence if repository persistence fails, and de-duplicates the
receipt/terminal-manifest crash window on relaunch.

### Verification

- [x] End-to-end tests with fake metadata writer, renderer, filesystem, and uploader.
- [x] Failure injection at copy/render/write/read-back/upload/remote-stat/receipt stages.
- [x] Relaunch/resume tests and plan-fingerprint invalidation tests.
- [x] Prove that an edited caption after plan freeze cannot be mistaken for the already verified
  staged file.
- [x] Large-batch memory and responsiveness test.
- [ ] Manual send to test FTP and SFTP servers, then inspect delivered files in Bridge and Photo
  Mechanic.

## Phase 6 — migration and release hardening

**Exit gate:** existing users upgrade without losing metadata/templates/settings, published support
claims match evidence, and the four workflows remain reliable under deadline conditions.

- [x] Full existing test suite plus all new fixture, failure-injection, migration, and UI tests.
- [x] Upgrade tests from representative 2.0, 2.1, and 2.2 JSON sidecars, templates, keyword lists,
  requirements, and preferences.
- [x] Current stores document and test newer-schema, backup-downgrade, and no-overwrite behavior.
- [ ] Run a signed 2.0/2.1/2.2 older-binary downgrade drill; released binaries cannot be
  retroactively hardened by the current source.
- [x] Thread Sanitizer and strict-concurrency review of caption navigation, preflight, rename, and
  delivery coordinators.
- [ ] File-permission, security-scoped bookmark, read-only volume, iCloud-offline, network drop, and
  disk-full drills.
  - [x] Automated failure-injection coverage for permission denial, bookmark denial/refresh,
    offline sources, read-only staging, capacity/disk-full refusal, and network loss/retry.
  - [ ] Real revoked bookmark, iCloud eviction, external-volume ACL/TCC/read-only media, physical
    disk exhaustion, and representative FTP/FTPS/SFTP disconnect/credential drills.
- [ ] Accessibility pass and menu/shortcut conflict audit in every workspace.
  - [x] Automated semantics, identifiers, keyboard-operable controls, adaptive-layout anchors, and
    bounded shortcut-conflict/routing tests across all ten workspaces.
  - [ ] Manual VoiceOver, Full Keyboard Access, accessibility-size/localization, contrast/motion,
    window-extreme, live IME, and external-display Clean Feed pass.
- [x] Performance targets measured on representative Apple Silicon tiers:
  - Caption navigation never waits for metadata write or full-resolution decode.
  - Rename preview remains interactive for at least 10,000 files.
  - Preflight streams incremental results and is cancellable.
  - Delivery memory is bounded independently of batch size.
- [x] Update README with a generated field-support table and precise format/write-mode caveats.
- [ ] Publish dated IPTC interoperability and Bridge/Photo Mechanic round-trip results.
- [x] Update user help, privacy text, CHANGELOG, and release notes.
- [x] Only describe C2PA as experimental until its independent release gate is complete.

**Progress — 2026-08-21:** A tag-derived migration matrix now exercises the actual 2.0.0, 2.1.0,
and 2.2.0 sidecar, template, template-bundle, requirements, and keyword-manifest shapes plus their
real per-key preference evolution. Current-only Deadline/rename/delivery/code-replacement stores
receive nested-future and backup-downgrade protection without being mislabeled as historical
migrations. The isolated gate passed 131 tests across twelve suites; see
[the persistence migration record](persistence-migration-schema-validation.md). Historical keyword
payloads are plain UTF-8 and preferences have no aggregate JSON artifact. A real older-binary
downgrade drill remains open because published binaries cannot be retroactively hardened.

**Progress — 2026-08-21:** README, documentation index, IPTC support ledger, privacy/retention
guidance, and the unreleased CHANGELOG now describe the implemented boundaries without claiming
unperformed external interoperability or real-server validation. A deterministic generator derives
33 stable descriptive field rows plus seven structured/GPS/rating/label verification rows from the
Swift registries and fails on drift. Carrier/gamut/write-policy, RAW/XMP, semantic read-back,
preservation, FTP/SFTP acknowledgement/authentication/TOCTOU, local-retention, and C2PA-experimental
caveats are explicit. This repository has no separate help, privacy, or release-note artifacts, so
the existing README/docs/CHANGELOG surfaces were updated rather than inventing duplicates.

**Progress — 2026-08-21:** A 1,000-item delivery stress gate proves sequential staging/upload,
one-item artifact-byte working memory across 64 MiB cumulative payload processing, cancellation
during initial artifact inspection and later boundaries, and privacy-bounded per-item evidence.
Thirty-five coordinator tests pass in under twenty seconds of parallel suite runtime; see
[the large-batch validation record](delivery-large-batch-validation.md). Plan/result/checkpoint
records remain necessarily O(item count), while file payload bytes are not accumulated.

**Progress — 2026-08-21:** Fifty-two logical environmental tests (62 parameterized executions)
simulate permission denial, offline sources, read-only staging, capacity/disk-full failures,
bookmark denial/refresh, and network loss/retry while verifying evidence retention and error/privacy
sanitization. Real local checks confirm restrictive workflow/document modes. See
[the environmental-drill record](environmental-failure-drills-validation.md). Actual revoked macOS
bookmarks, iCloud eviction/offline recovery, external-volume ACL/TCC/read-only media, physical disk
exhaustion, and representative FTP/FTPS/SFTP disconnect/credential behavior remain manual; the
combined checklist therefore remains open.

**Progress — 2026-08-21:** A fresh isolated current-source build succeeded, then the complete
unfiltered target passed 1,338 logical tests in 153 suites and all 1,465 expanded executions with
zero failures, skips, or expected failures. Thirty-six dynamic tests expanded to 163 argument runs.
All 96 top-level Swift test files have complete PBX membership, including the activated
Accessibility, Image Analysis archive, Editorial Date Created, and Image Supplier suites. Generator,
21-fixture/24-repository JSON, PBX, conflict-hunk, and diff static gates also passed. See
[the full-suite validation record](full-test-suite-validation.md).

**Progress — 2026-08-21:** Caption navigation now snapshots and queues persistence off-main while
durable actions drain FIFO; held persistence/decode gates return in under 0.002 seconds. Rename
preview uses a debounced serial off-main worker with latest-wins publication and planned 10,000
files/40,000 artifacts in 3.824 seconds with +56.4 MiB process RSS on an M5 Pro. Preflight streams
immutable stage/count/partial-report snapshots with cancellation and stale suppression. Combined
current-source performance suites produced 114 passing executions; see
[the workflow performance record](workflow-performance-validation.md) and
[the delivery stress record](delivery-large-batch-validation.md). Device-specific UI/codec
benchmarks remain release observations rather than universal throughput promises.

**Progress — 2026-08-21:** The full app/test graph compiles under Swift 6 complete strict
concurrency, warn-concurrency, and actor race checks with zero diagnostics. Thread Sanitizer passed
181 logical Caption/sidecar/preflight/rename/delivery tests with no race reports, plus explicit
upload/workflow overlap and 32-way receipt-transaction regressions. See
[the concurrency validation record](concurrency-sanitizer-validation.md). Cross-process workflow
remove/recreate locking and callers that bypass the production rename owner remain explicit
architectural limits rather than hidden guarantees.

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
