#!/usr/bin/env python3
"""Focused negative tests for bundled-component provenance validation."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import validate_bundled_components as validator


class BundledComponentValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "recipe.txt").write_text("pinned recipe\n", encoding="utf-8")
        (self.root / "LICENSE").write_text("license\n", encoding="utf-8")
        self.component = {
            "id": "fixture",
            "artifactPath": "artifact",
            "required": False,
            "version": "1.0",
            "upstream": {"url": "https://example.invalid/source", "revision": "abc123"},
            "license": "MIT",
            "licensePath": "LICENSE",
            "buildRecipe": {
                "repositoryPath": "recipe.txt",
                "revision": f"sha256:{validator.sha256(self.root / 'recipe.txt')}",
            },
            "targetArchitectures": ["arm64"],
            "runtimeCapabilities": ["test capability"],
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_local_recipe_content_revision_is_accepted(self) -> None:
        validator.validate_declaration(self.root, self.component)

    def test_recipe_drift_fails_closed(self) -> None:
        (self.root / "recipe.txt").write_text("changed recipe\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "build recipe revision mismatch"):
            validator.validate_declaration(self.root, self.component)

    def test_missing_required_artifact_fails_closed(self) -> None:
        component = dict(self.component)
        component["required"] = True
        with self.assertRaisesRegex(ValueError, "required artifact is missing"):
            validator.validate_artifact(self.root, component)

    def test_missing_version_expectation_fails_closed(self) -> None:
        artifact = self.root / "artifact"
        artifact.write_bytes(b"fixture")
        component = dict(self.component)
        component.update({
            "artifactSHA256": validator.sha256(artifact),
            "versionCommand": ["--version"],
        })
        with self.assertRaisesRegex(ValueError, "expectedVersionPrefix is required"):
            validator.validate_artifact(self.root, component)


if __name__ == "__main__":
    unittest.main()
