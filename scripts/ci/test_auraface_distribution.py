#!/usr/bin/env python3
"""Offline tests for deterministic AuraFace on-demand distribution packaging."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "package_auraface_distribution.py"
SPEC = importlib.util.spec_from_file_location("package_auraface_distribution", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
packager = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = packager
SPEC.loader.exec_module(packager)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class AuraFaceDistributionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        defaults = self.root / "Aagedal Photo Agent/Models/FaceRecognitionDefaults.swift"
        defaults.parent.mkdir(parents=True)
        defaults.write_text("static let embeddingVersion = 3\n", encoding="utf-8")
        self.package = self.root / "AuraFaceR100.mlpackage"
        self.files = {
            "Data/com.apple.CoreML/model.mlmodel": b"model",
            "Data/com.apple.CoreML/weights/weight.bin": b"weights",
            "Manifest.json": b'{"model":"fixture"}\n',
        }
        for relative, data in self.files.items():
            path = self.package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.manifest = self.root / "manifest.json"
        self.write_manifest()
        self.contract = packager.load_contract(self.manifest, self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_manifest(self, *, embedding_version: int = 3) -> None:
        self.manifest.write_text(json.dumps({
            "components": [{
                "id": packager.COMPONENT_ID,
                "version": "AuraFace-v1/glintr100",
                "artifactFiles": {name: digest(data) for name, data in self.files.items()},
                "buildContract": {"embeddingVersion": embedding_version},
            }],
        }), encoding="utf-8")

    def package_to(self, stem: str) -> tuple[Path, Path]:
        archive = self.root / f"{stem}.zip"
        descriptor = self.root / f"{stem}.json"
        packager.package_distribution(
            self.package,
            archive,
            descriptor,
            self.contract,
            f"https://aagedal.me/models/{archive.name}",
            False,
        )
        return archive, descriptor

    def test_packages_are_byte_identical_and_self_verifying(self) -> None:
        first_archive, first_descriptor = self.package_to("first")
        second_archive, second_descriptor = self.package_to("second")
        self.assertEqual(first_archive.read_bytes(), second_archive.read_bytes())
        first = json.loads(first_descriptor.read_text(encoding="utf-8"))
        second = json.loads(second_descriptor.read_text(encoding="utf-8"))
        self.assertEqual(first["archive"]["sha256"], second["archive"]["sha256"])
        self.assertEqual(first["embeddingVersion"], 3)
        packager.verify_distribution(first_archive, first_descriptor, self.contract)

    def test_rejects_embedding_version_drift(self) -> None:
        self.write_manifest(embedding_version=4)
        with self.assertRaisesRegex(packager.DistributionError, "FaceRecognitionDefaults"):
            packager.load_contract(self.manifest, self.root)

    def test_rejects_non_aagedal_or_mutable_download_url(self) -> None:
        for url in (
            "http://aagedal.me/models/model.zip",
            "https://example.com/model.zip",
            "https://aagedal.me/models/model.zip?latest=1",
        ):
            with self.subTest(url=url):
                with self.assertRaisesRegex(packager.DistributionError, "HTTPS artifact URL"):
                    packager.validate_download_url(url)

    def test_corrupt_archive_and_extra_package_file_fail_closed(self) -> None:
        archive, descriptor = self.package_to("candidate")
        data = bytearray(archive.read_bytes())
        data[-1] ^= 0x01
        archive.write_bytes(data)
        with self.assertRaisesRegex(packager.DistributionError, "SHA-256"):
            packager.verify_distribution(archive, descriptor, self.contract)

        (self.package / "unexpected.txt").write_text("unexpected", encoding="utf-8")
        with self.assertRaisesRegex(packager.DistributionError, "file set mismatch"):
            packager.verify_package(self.package, self.contract)

    def test_failed_replacement_preserves_existing_outputs(self) -> None:
        archive = self.root / "existing.zip"
        descriptor = self.root / "existing.json"
        archive.write_bytes(b"old archive")
        descriptor.write_bytes(b"old descriptor")
        with self.assertRaisesRegex(packager.DistributionError, "destination exists"):
            packager.package_distribution(
                self.package,
                archive,
                descriptor,
                self.contract,
                "https://aagedal.me/models/existing.zip",
                False,
            )
        self.assertEqual(archive.read_bytes(), b"old archive")
        self.assertEqual(descriptor.read_bytes(), b"old descriptor")


if __name__ == "__main__":
    unittest.main()
