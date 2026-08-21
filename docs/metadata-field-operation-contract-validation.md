# Metadata field-operation contract validation — 2026-08-21

All 33 stable `MetadataFieldID` cases now participate in exhaustive writer and verification
mappings. A non-UI, `Sendable` mutation boundary represents `untouched`, `overwrite`, `append`, and
`clear` explicitly. Invalid field/value shapes fail the complete mutation transaction rather than
silently clearing or partially applying metadata. Append is available only for the five repeatable
fields and performs normalized deduplication.

Controlled values retain canonical storage independently of localized/display labels. Digital
Source Type accepts supported aliases and stores its typed canonical value, Scene retains canonical
codes independently of display text, country values use canonical alpha-3 codes, and urgency keeps
its bounded integer identity. Metadata-history replay now applies the same Scene canonicalization.

Tests cover overwrite, clear, and untouched for every selected field; append for every repeatable
field; Unicode, duplicate, and invalid-shape behavior; detached mutation preparation; all-selected-
field XMP sidecar and embedded-JPEG write/read-back; and an exact-byte empty embedded no-op. The
focused run passed 87 tests in eight suites and the supporting metadata/concurrency run passed 95
tests in seven suites, for 182 tests with no failures. The metadata support generator, PBX lint,
conflict-marker scan, and `git diff --check` passed.

External and representational limits remain explicit. The repository does not contain licensed
IPTC Interoperability Test 1/2/3 artifacts or current Bridge/Photo Mechanic observations. Embedded
fixtures are generated through the production SwiftExif path rather than authored by those tools.
The scalar metadata model cannot independently retain language-specific `rdf:Alt` variants, and
XMP preservation is semantic rather than lexical packet-byte identity because serialization may
legitimately change. Unknown Digital Source Type identifiers remain unmodelled and typed mutations
therefore reject them instead of silently clearing them.
