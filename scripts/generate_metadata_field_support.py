#!/usr/bin/env python3
"""Generate the user-facing metadata field-support table from Swift registries."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIELD_ID_PATH = ROOT / "Aagedal Photo Agent/Models/MetadataFieldID.swift"
FIELD_KEY_PATH = ROOT / "Aagedal Photo Agent/Models/MetadataFieldKey.swift"
METADATA_PATH = ROOT / "Aagedal Photo Agent/Models/IPTCMetadata.swift"
VERIFICATION_PATH = ROOT / "Aagedal Photo Agent/Models/IPTCMetadataVerification.swift"
OUTPUT_PATH = ROOT / "docs/metadata-field-support.md"

RULE_LABELS = {
    "scalarWhitespace": "scalar text; line endings and outer whitespace normalized",
    "unorderedUniqueText": "unique trimmed values; order ignored",
    "orderedUniqueText": "unique trimmed values; sequence order retained",
    "controlledVocabularyURI": "canonical controlled-vocabulary identifier",
    "datePrecision": "instant plus stored precision/timezone-known state",
    "integerExact": "exact integer",
    "coordinateSixDecimalPlaces": "decimal degrees rounded to 6 places",
    "structuredContact": "normalized structured contact",
    "unorderedStructuredLocations": "unique normalized locations; order ignored",
    "unorderedControlledVocabularyTerms": "unique normalized CV-Term structures; order ignored",
    "orderedStructuredImageSuppliers": "normalized PLUS supplier structures; sequence order retained",
    "orderedLocalizedText": "language-tagged text alternatives; sequence order retained",
}


def typed_switch_mapping(source: str, declaration: str, end_marker: str) -> dict[str, str]:
    """Parse the direct `case .field: .mappedValue` switches used by MetadataFieldID.

    The field registry deliberately owns these mappings. Deriving them from presentation helpers
    such as `textValue` is brittle because structured fields may serialize to JSON or labels rather
    than returning one `IPTCMetadata` property expression.
    """
    try:
        region = source.split(declaration, 1)[1].split(end_marker, 1)[0]
    except IndexError:
        fail(f"could not locate {declaration!r}")
    return dict(
        re.findall(
            r"case \.([A-Za-z][A-Za-z0-9_]*):\s*\.([A-Za-z][A-Za-z0-9_]*)",
            region,
        )
    )


def fail(message: str) -> None:
    raise RuntimeError(message)


def enum_cases(source: str, declaration: str, end_marker: str) -> list[tuple[str, str]]:
    try:
        region = source.split(declaration, 1)[1].split(end_marker, 1)[0]
    except IndexError:
        fail(f"could not locate {declaration!r}")
    result: list[tuple[str, str]] = []
    for match in re.finditer(r"^\s*case\s+([^\n]+)", region, re.MULTILINE):
        declaration_text = match.group(1).split("//", 1)[0]
        for entry in declaration_text.split(","):
            parts = entry.strip().split("=", 1)
            name = parts[0].strip()
            raw_value = parts[1].strip().strip('"') if len(parts) == 2 else name
            if name:
                result.append((name, raw_value))
    return result


def named_array(source: str, name: str) -> list[str]:
    match = re.search(
        rf"static let {re.escape(name)}: \[Self\] = \[(.*?)\n\s*\]",
        source,
        re.DOTALL,
    )
    if not match:
        fail(f"could not locate {name}")
    return re.findall(r"\.([A-Za-z][A-Za-z0-9_]*)", match.group(1))


def comparison_rules(source: str, verification_fields: list[str]) -> dict[str, str]:
    try:
        region = source.split(
            "static func rule(for field: IPTCMetadataVerificationField)", 1
        )[1].split("static func canonicalValue", 1)[0]
    except IndexError:
        fail("could not locate verification rule switch")
    rules: dict[str, str] = {}
    default_rule: str | None = None
    pending_fields: list[str] = []
    for line in region.splitlines():
        case_match = re.match(r"\s*case\s+(.+):\s*$", line)
        if case_match:
            pending_fields = re.findall(r"\.([A-Za-z][A-Za-z0-9_]*)", case_match.group(1))
            continue
        default_match = re.match(r"\s*default:\s*$", line)
        if default_match:
            pending_fields = ["__default__"]
            continue
        rule_match = re.match(r"\s*\.([A-Za-z][A-Za-z0-9_]*)\s*$", line)
        if rule_match and pending_fields:
            rule = rule_match.group(1)
            for field in pending_fields:
                if field == "__default__":
                    default_rule = rule
                else:
                    rules[field] = rule
            pending_fields = []
    if default_rule is None:
        fail("verification switch has no parsed default rule")
    for field in verification_fields:
        rules.setdefault(field, default_rule)
    unknown_rules = set(rules.values()) - set(RULE_LABELS)
    if unknown_rules:
        fail(f"add labels for comparison rules: {sorted(unknown_rules)}")
    return rules


def build_document() -> str:
    field_source = FIELD_ID_PATH.read_text(encoding="utf-8")
    key_source = FIELD_KEY_PATH.read_text(encoding="utf-8")
    metadata_source = METADATA_PATH.read_text(encoding="utf-8")
    verification_source = VERIFICATION_PATH.read_text(encoding="utf-8")

    field_cases = enum_cases(field_source, "enum MetadataFieldID", "var displayName")
    field_names = [name for name, _ in field_cases]

    display_names = dict(
        re.findall(r'case \.([A-Za-z][A-Za-z0-9_]*): return "([^"]+)"', field_source)
    )
    if set(display_names) != set(field_names):
        fail("MetadataFieldID display-name switch does not match its cases")

    primary = named_array(field_source, "primaryEditorFields")
    additional = named_array(field_source, "additionalEditorFields")
    editor_fields = set(primary + additional)

    write_key_by_field = typed_switch_mapping(
        field_source, "var metadataWriteKey", "var verificationField"
    )
    verification_by_field = typed_switch_mapping(
        field_source, "var verificationField", "fileprivate func setRepeatableValues"
    )
    if set(write_key_by_field) != set(field_names):
        fail("MetadataFieldID.metadataWriteKey does not map every field")
    if set(verification_by_field) != set(field_names):
        fail("MetadataFieldID.verificationField does not map every field")

    key_cases = {
        name
        for name, _ in enum_cases(key_source, "enum MetadataFieldKey", "// MARK: - GPS")
    }
    overwrite_region = metadata_source.split("func toOverwriteFields()", 1)[1].split(
        "return fields", 1
    )[0]
    overwrite_keys = set(
        re.findall(r"fields\[\.([A-Za-z][A-Za-z0-9_]*)\]\s*=", overwrite_region)
    )

    verification_cases = enum_cases(
        verification_source,
        "enum IPTCMetadataVerificationField",
        "/// Fields emitted by the descriptive",
    )
    verification_fields = [name for name, _ in verification_cases]
    if "Self.allCases.filter { $0 != .captureDate }" not in verification_source:
        fail("writable verification-field policy changed; review this generator")
    writable_verification = set(verification_fields) - {"captureDate"}
    rules = comparison_rules(verification_source, verification_fields)

    field_registry: dict[str, tuple[str, str]] = {}
    for field in field_names:
        write_key = write_key_by_field[field]
        verification_field = verification_by_field[field]
        if write_key not in overwrite_keys:
            fail(f"{field}: write key {write_key} is absent from toOverwriteFields()")
        if write_key not in key_cases:
            fail(f"{field}: write key {write_key} is not a descriptive MetadataFieldKey")
        if verification_field not in writable_verification:
            fail(f"{field}: {verification_field} is not writable/read-back verified")
        field_registry[field] = (write_key, verification_field)

    table_rows = []
    for field, raw_value in field_cases:
        write_key, verification_field = field_registry[field]
        if field in editor_fields:
            exposure = "Metadata panel"
        elif field == "digitalSourceType":
            exposure = "Dedicated Metadata/Import control"
        elif field == "dateCreated":
            exposure = "Import control; not in Metadata panel"
        else:
            exposure = "Not directly exposed"
        table_rows.append(
            "| {label} | `{identifier}` | {exposure} | `{write_key}` | `{verification}` | {rule} |".format(
                label=display_names[field],
                identifier=raw_value,
                exposure=exposure,
                write_key=write_key,
                verification=verification_field,
                rule=RULE_LABELS[rules[verification_field]],
            )
        )

    bridged_verification = {verification for _, verification in field_registry.values()}
    additional_verification = [
        field
        for field in verification_fields
        if field in writable_verification and field not in bridged_verification
    ]
    additional_rows = [
        f"| `{field}` | {RULE_LABELS[rules[field]]} |"
        for field in additional_verification
    ]

    return "\n".join(
        [
            "<!-- Generated by scripts/generate_metadata_field_support.py. Do not edit by hand. -->",
            "# Metadata field and delivery support",
            "",
            "This document describes the current implementation boundary. The field rows are generated",
            "from `MetadataFieldID`, `MetadataFieldKey`, `IPTCMetadata.toOverwriteFields()`, and the",
            "semantic read-back verification registry. Regenerate it with",
            "`python3 scripts/generate_metadata_field_support.py`; CI-style drift checking is available",
            "with `python3 scripts/generate_metadata_field_support.py --check`.",
            "",
            "The table is an app-support statement, not a claim that every field has completed manual",
            "round trips through Adobe Bridge, Photo Mechanic, or every image carrier. See the",
            "[IPTC 2025.1 editorial support matrix](iptc-2025.1-editorial-support.md) for standards-level",
            "mapping and the external interoperability evidence that is still required.",
            "",
            "## Descriptive field registry",
            "",
            "The stable ID is the JSON/preferences identity. The write key selects the internal metadata",
            "writer mapping; the read-back field and rule are what staged delivery compares after parsing",
            "the exact output bytes.",
            "",
            "| Field | Stable ID | Editor exposure | Write key | Read-back field | Semantic comparison |",
            "| --- | --- | --- | --- | --- | --- |",
            *table_rows,
            "",
            "## Other writable read-back fields",
            "",
            "These fields are in the writable verification registry but are not represented by",
            "`MetadataFieldID`. They are written through structured-editorial, GPS, rating, or label",
            "boundaries.",
            "",
            "| Read-back field | Semantic comparison |",
            "| --- | --- |",
            *additional_rows,
            "",
            "`captureDate` is parsed and can be compared with date precision, but it is deliberately",
            "excluded from the writable set because it is source technical metadata rather than an",
            "editor-managed write target.",
            "",
            "## Carrier and write-mode boundaries",
            "",
            "- For ordinary metadata editing, non-RAW files can use history-only, embedded, adjacent XMP,",
            "  or embedded-plus-XMP modes. A merge overlays populated values; an authoritative replacement",
            "  also clears descriptive values that the user cleared.",
            "- Proprietary RAW containers are never rewritten for descriptive metadata. Any physical-write",
            "  request is reduced to one adjacent XMP sidecar write. The descriptive XMP path preserves the",
            "  existing Camera Raw Develop block and refuses to overwrite a sidecar that changed after the",
            "  edit snapshot was captured.",
            "- Deadline delivery does not upload originals and does not accept an XMP-sidecar-only strategy.",
            "  It supports staged copies only: SDR JPEG or TIFF, and HDR Adaptive JPEG with a gain map or",
            "  16-bit TIFF. SDR supports sRGB, Display P3, Rec. 2020, and Adobe RGB; HDR supports sRGB,",
            "  Display P3, and Rec. 2020. A RAW source is rendered to one of these staged derivatives; its",
            "  proprietary original is never rewritten or uploaded by Deadline Send.",
            "- JPEG/JPEG gain-map and TIFF/TIFF16 are the only carriers with the current end-to-end Deadline",
            "  embedded-write and preservation contract. PNG, HEIC/HEIF, AVIF, and JPEG XL may be readable",
            "  or exportable elsewhere in the app, but are rejected for Deadline staging rather than being",
            "  treated as verified delivery carriers.",
            "- A Deadline staged copy first receives source metadata, then the frozen resolved descriptive",
            "  record is written authoritatively. The exact staged bytes are parsed again and compared using",
            "  the rules above before upload.",
            "- Unrelated EXIF, IPTC, and XMP are compared using privacy-safe semantic fingerprints. Expected",
            "  rendition changes such as dimensions, orientation, renderer-authored XMP, and baked Develop",
            "  state are excluded from that identity. A proven mismatch or unknown preservation support",
            "  fails staging; an explicitly unsupported carrier/domain boundary is reported as such.",
            "- C2PA is an **experimental preview**. A manifest's absent/carried/removed/added/changed result is",
            "  recorded as a carriage consequence, not proof that a content credential remains valid for the",
            "  newly rendered asset.",
            "",
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit nonzero if the checked-in document differs from generated output",
    )
    args = parser.parse_args()
    try:
        generated = build_document()
    except (OSError, RuntimeError) as error:
        print(f"metadata support generation failed: {error}", file=sys.stderr)
        return 2

    if args.check:
        current = OUTPUT_PATH.read_text(encoding="utf-8") if OUTPUT_PATH.exists() else ""
        if current != generated:
            print(
                f"{OUTPUT_PATH.relative_to(ROOT)} is stale; run "
                "python3 scripts/generate_metadata_field_support.py",
                file=sys.stderr,
            )
            return 1
        print(f"{OUTPUT_PATH.relative_to(ROOT)} is current")
        return 0

    OUTPUT_PATH.write_text(generated, encoding="utf-8")
    print(f"wrote {OUTPUT_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
