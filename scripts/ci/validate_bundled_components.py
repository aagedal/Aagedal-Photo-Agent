#!/usr/bin/env python3
"""Validate declared bundled binary/model provenance against local artifacts."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
REQUIRED_COMPONENT_KEYS = {
    "id",
    "artifactPath",
    "required",
    "version",
    "upstream",
    "license",
    "licensePath",
    "buildRecipe",
    "targetArchitectures",
    "runtimeCapabilities",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> None:
    raise ValueError(message)


def require_nonempty_mapping(component_id: str, key: str, value: object) -> dict:
    if not isinstance(value, dict) or not value:
        fail(f"{component_id}: {key} must be a non-empty object")
    return value


def validate_declaration(root: Path, component: dict) -> None:
    component_id = component.get("id", "<missing id>")
    missing = sorted(REQUIRED_COMPONENT_KEYS - component.keys())
    if missing:
        fail(f"{component_id}: missing manifest fields: {', '.join(missing)}")

    upstream = require_nonempty_mapping(component_id, "upstream", component["upstream"])
    if not upstream.get("url") or not upstream.get("revision"):
        fail(f"{component_id}: upstream URL and immutable revision are required")

    recipe = require_nonempty_mapping(component_id, "buildRecipe", component["buildRecipe"])
    if not recipe.get("revision") or not (recipe.get("url") or recipe.get("repositoryPath")):
        fail(f"{component_id}: build recipe location and revision are required")
    if repository_path := recipe.get("repositoryPath"):
        revision = recipe["revision"]
        if not isinstance(revision, str) or not revision.startswith("sha256:"):
            fail(f"{component_id}: repository build recipe revision must be a SHA-256 content revision")
        recipe_path = root / repository_path
        if not recipe_path.is_file():
            fail(f"{component_id}: repository build recipe is missing: {repository_path}")
        actual_recipe_revision = f"sha256:{sha256(recipe_path)}"
        if revision != actual_recipe_revision:
            fail(
                f"{component_id}: build recipe revision mismatch: "
                f"expected {revision}, got {actual_recipe_revision}"
            )

    for key in ("targetArchitectures", "runtimeCapabilities"):
        value = component[key]
        if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
            fail(f"{component_id}: {key} must be a non-empty string array")

    license_path = root / component["licensePath"]
    if not license_path.is_file():
        fail(f"{component_id}: missing declared license file: {component['licensePath']}")


def validate_artifact(root: Path, component: dict) -> str:
    component_id = component["id"]
    artifact = root / component["artifactPath"]
    if not artifact.exists():
        if component["required"]:
            fail(f"{component_id}: required artifact is missing: {component['artifactPath']}")
        return "optional artifact absent (declaration validated)"

    if artifact.is_file():
        expected = component.get("artifactSHA256")
        if not expected:
            fail(f"{component_id}: artifactSHA256 is required for a file artifact")
        actual = sha256(artifact)
        if actual != expected:
            fail(f"{component_id}: SHA-256 mismatch: expected {expected}, got {actual}")
    elif artifact.is_dir():
        declared = component.get("artifactFiles")
        if not isinstance(declared, dict) or not declared:
            fail(f"{component_id}: artifactFiles is required for a directory artifact")
        actual_files = {
            str(path.relative_to(artifact))
            for path in artifact.rglob("*")
            if path.is_file()
        }
        if actual_files != set(declared):
            missing = sorted(set(declared) - actual_files)
            extra = sorted(actual_files - set(declared))
            fail(f"{component_id}: artifact file set mismatch; missing={missing}, extra={extra}")
        for relative, expected in sorted(declared.items()):
            actual = sha256(artifact / relative)
            if actual != expected:
                fail(f"{component_id}: SHA-256 mismatch for {relative}: expected {expected}, got {actual}")
    else:
        fail(f"{component_id}: artifact is neither a file nor directory")

    version_command = component.get("versionCommand")
    if version_command:
        expected_prefix = component.get("expectedVersionPrefix")
        if not isinstance(expected_prefix, str) or not expected_prefix:
            fail(f"{component_id}: expectedVersionPrefix is required with versionCommand")
        result = subprocess.run(
            [str(artifact), *version_command],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        output = result.stdout + result.stderr
        if result.returncode != 0 or not output.startswith(expected_prefix):
            fail(
                f"{component_id}: version probe did not start with {expected_prefix!r} "
                f"(exit {result.returncode})"
            )

    if artifact.is_file():
        architecture_probe = subprocess.run(
            ["lipo", "-archs", str(artifact)],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if architecture_probe.returncode != 0:
            fail(f"{component_id}: could not inspect Mach-O architectures")
        actual_architectures = set(architecture_probe.stdout.split())
        expected_architectures = set(component["targetArchitectures"])
        if actual_architectures != expected_architectures:
            fail(
                f"{component_id}: architecture mismatch: "
                f"expected {sorted(expected_architectures)}, got {sorted(actual_architectures)}"
            )

    return "artifact and provenance validated"


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
    if len(sys.argv) > 2:
        print(f"usage: {Path(sys.argv[0]).name} [REPOSITORY_ROOT]", file=sys.stderr)
        return 2

    try:
        document = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
        if document.get("schemaVersion") != 1:
            fail("unsupported bundled-component manifest schema")
        components = document.get("components")
        if not isinstance(components, list) or not components:
            fail("bundled-component manifest must contain components")
        if not all(isinstance(component, dict) for component in components):
            fail("every bundled-component entry must be an object")
        identifiers = [component.get("id") for component in components]
        if len(identifiers) != len(set(identifiers)):
            fail("bundled-component identifiers must be unique")

        for component in components:
            validate_declaration(root, component)
            status = validate_artifact(root, component)
            print(f"{component['id']}: {status}")
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"bundled component validation failed: {error}", file=sys.stderr)
        return 1

    print(f"validated {len(components)} bundled component declaration(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
