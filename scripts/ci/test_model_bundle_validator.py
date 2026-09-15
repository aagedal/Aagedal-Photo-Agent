#!/usr/bin/env python3
"""Focused app-bundle admission cases for the bundled AuraFace release gate."""

from __future__ import annotations

import hashlib
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import validate_model_bundle as validator


class ModelBundleValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.app = Path(self.temporary.name) / "Aagedal Photo Agent.app"
        contents = self.app / "Contents"
        resources = contents / "Resources"
        self.model = resources / validator.MODEL_NAME
        self.weights = self.model / "weights/weight.bin"
        for relative in validator.REQUIRED_COMPILED_FILES:
            path = self.model / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"reviewed fixture")
        executable = contents / "MacOS/Aagedal Photo Agent"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"fixture executable")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Aagedal Photo Agent",
            "CFBundleShortVersionString": "3.0.0",
            "CFBundleVersion": "738",
        }))
        self.expected_hash = hashlib.sha256(self.weights.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def inspect(self) -> dict:
        with mock.patch.object(validator, "expected_weights_hash", return_value=self.expected_hash):
            return validator.inspect_app(self.app)

    def test_reviewed_compiled_model_is_admitted(self) -> None:
        result = self.inspect()
        self.assertTrue(result["modelBundled"])
        self.assertEqual(result["weightsSHA256"], self.expected_hash)

    def test_missing_or_changed_model_is_rejected(self) -> None:
        self.weights.write_bytes(b"changed weights")
        with self.assertRaisesRegex(ValueError, "differ from the reviewed package"):
            self.inspect()
        self.weights.unlink()
        with self.assertRaisesRegex(ValueError, "missing weights/weight.bin"):
            self.inspect()

    def test_duplicate_developer_package_is_rejected(self) -> None:
        duplicate = self.app / "Contents/Resources/AuraFaceR100.mlpackage"
        duplicate.mkdir()
        with self.assertRaisesRegex(ValueError, "duplicate AuraFace payload"):
            self.inspect()


if __name__ == "__main__":
    unittest.main()
