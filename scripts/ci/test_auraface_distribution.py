#!/usr/bin/env python3
"""Offline tests for deterministic AuraFace on-demand distribution packaging."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "package_auraface_distribution.py"
REPOSITORY = SCRIPT.parents[1]
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
        archive = self.root / stem / "AuraFaceR100.mlpackage.zip"
        descriptor = self.root / stem / "AuraFaceR100.distribution.json"
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
        self.assertEqual(first["schemaVersion"], 2)
        self.assertEqual(first["packageFiles"], {
            name: {"byteCount": len(data), "sha256": digest(data)} for name, data in self.files.items()
        })
        expected_descriptor = json.dumps(first, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.assertEqual(first_descriptor.read_bytes(), expected_descriptor)
        self.assertFalse(first_descriptor.read_bytes().endswith(b"\n"))
        self.assertEqual(first_archive.read_bytes(), self.expected_zip32())
        # Independent standard-library extraction confirms exact unchanged model bytes.
        with zipfile.ZipFile(first_archive) as source:
            for relative, data in self.files.items():
                self.assertEqual(source.read("AuraFaceR100.mlpackage/" + relative), data)
        self.assertEqual({name: (self.package / name).read_bytes() for name in self.files}, self.files)
        packager.verify_distribution(first_archive, first_descriptor, self.contract)

    def expected_zip32(self) -> bytes:
        """Independent fixed fixture wire construction; no producer constants/helpers."""
        local = bytearray()
        central = bytearray()
        for path in sorted(self.files):
            name = ("AuraFaceR100.mlpackage/" + path).encode("utf-8")
            data = self.files[path]
            crc = zlib.crc32(data)
            offset = len(local)
            local += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0x0800, 0, 0, 23585,
                                 crc, len(data), len(data), len(name), 0) + name + data
            central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 788, 20, 0x0800, 0, 0, 23585,
                                   crc, len(data), len(data), len(name), 0, 0, 0, 0, 2175008768, offset) + name
        end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 3, 3, len(central), len(local), 0)
        return bytes(local + central + end)

    def test_rejects_embedding_version_drift(self) -> None:
        self.write_manifest(embedding_version=4)
        with self.assertRaisesRegex(packager.DistributionError, "FaceRecognitionDefaults"):
            packager.load_contract(self.manifest, self.root)

    def test_rejects_non_aagedal_or_mutable_download_url(self) -> None:
        for url in (
            "http://aagedal.me/models/model.zip",
            "https://example.com/model.zip",
            "https://aagedal.me/models/model.zip",
            "https://aagedal.me/models/model.zip?latest=1",
            "https://aagedal.me:443/models/model.zip",
            "https://aagedal.me:8443/models/model.zip",
            "https://aagedal.me:invalid/models/model.zip",
            "https://user@aagedal.me/models/model.zip",
            "https://aagedal.me/models/model.zip#fragment",
            "https://aagedal.me/models/\nmodel.zip",
            "https://aagedal.me/models/model.zip?",
            "https://aagedal.me/models/model.zip#",
            "HTTPS://aagedal.me/models/model.zip",
            "https://aagedal.me/models/å.zip",
            "https://aagedal.me/models/%invalid.zip",
            "https://[broken/model.zip",
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
        archive = self.root / "AuraFaceR100.mlpackage.zip"
        descriptor = self.root / "AuraFaceR100.distribution.json"
        archive.write_bytes(b"old archive")
        descriptor.write_bytes(b"old descriptor")
        with self.assertRaisesRegex(packager.DistributionError, "destination exists"):
            packager.package_distribution(
                self.package,
                archive,
                descriptor,
                self.contract,
                "https://aagedal.me/models/AuraFaceR100.mlpackage.zip",
                False,
            )
        self.assertEqual(archive.read_bytes(), b"old archive")
        self.assertEqual(descriptor.read_bytes(), b"old descriptor")

    def test_replacement_install_fault_restores_both_prior_outputs(self) -> None:
        archive, descriptor = self.package_to("replacement")
        prior = (archive.read_bytes(), descriptor.read_bytes())
        real_link = packager.os.link
        failed = False

        def injected_link(source, destination, **kwargs):
            nonlocal failed
            if Path(destination) == descriptor and not failed:
                failed = True
                raise OSError("injected second install failure")
            return real_link(source, destination, **kwargs)

        with mock.patch.object(packager.os, "link", side_effect=injected_link):
            with self.assertRaisesRegex(OSError, "second install failure"):
                packager.package_distribution(self.package, archive, descriptor, self.contract,
                    "https://aagedal.me/models/AuraFaceR100.mlpackage.zip", True)
        self.assertTrue(failed)
        self.assertEqual((archive.read_bytes(), descriptor.read_bytes()), prior)

    def test_descriptor_rejects_noncanonical_and_duplicate_bytes(self) -> None:
        archive, descriptor = self.package_to("canonical")
        valid = descriptor.read_bytes()
        for altered in (valid + b"\n", json.dumps(json.loads(valid), indent=2).encode(),
                        valid.replace(b'"schemaVersion":2', b'"schemaVersion":2,"schemaVersion":2')):
            with self.subTest(altered=altered[-70:]):
                descriptor.write_bytes(altered)
                with self.assertRaises(packager.DistributionError):
                    packager.verify_distribution(archive, descriptor, self.contract)

    def test_strict_schema_sizes_and_configured_filename(self) -> None:
        archive, descriptor = self.package_to("schema")
        original = json.loads(descriptor.read_bytes())
        mutations = [
            lambda d: d.update(schemaVersion=1),
            lambda d: d.update(schemaVersion=True),
            lambda d: d.update(extra="unknown"),
            lambda d: d["archive"].update(fileName="another.zip"),
            lambda d: d["archive"].update(byteCount=268435457),
            lambda d: d["archive"].update(byteCount=True),
            lambda d: d["packageFiles"]["Manifest.json"].update(byteCount=0),
            lambda d: d["packageFiles"]["Manifest.json"].update(byteCount=True),
            lambda d: d["packageFiles"]["Manifest.json"].update(byteCount=201326593),
            lambda d: d["packageFiles"]["Manifest.json"].update(byteCount=len(self.files["Manifest.json"]) + 1),
            lambda d: d["packageFiles"]["Manifest.json"].update(sha256="0" * 64),
        ]
        for mutation in mutations:
            candidate = json.loads(json.dumps(original)); mutation(candidate)
            descriptor.write_bytes(json.dumps(candidate, sort_keys=True, separators=(",", ":")).encode())
            with self.assertRaises(packager.DistributionError):
                packager.verify_distribution(archive, descriptor, self.contract)
        with self.assertRaisesRegex(packager.DistributionError, "filename"):
            packager.create_archive(self.package, self.root / "not-the-configured-name.zip")

    def test_resigned_archive_header_and_payload_tampering_is_refused(self) -> None:
        archive, descriptor = self.package_to("headers")
        original = archive.read_bytes()
        document = json.loads(descriptor.read_bytes())
        central = original.index(b"PK\x01\x02")
        first_data = 30 + struct.unpack_from("<H", original, 26)[0]
        # Recompute outer hash so these reach independent inner/header admission.
        for offset in (6, 8, 14, 18, 28, central + 8, central + 10, central + 30,
                       central + 32, central + 38, len(original) - 2, first_data):
            with self.subTest(offset=offset):
                altered = bytearray(original); altered[offset] ^= 1
                archive.write_bytes(altered)
                document["archive"]["sha256"] = digest(altered)
                descriptor.write_bytes(json.dumps(document, sort_keys=True, separators=(",", ":")).encode())
                with self.assertRaises(packager.DistributionError):
                    packager.verify_distribution(archive, descriptor, self.contract)

    def test_size_admission_and_linked_package_do_not_publish_outputs(self) -> None:
        archive = self.root / "AuraFaceR100.mlpackage.zip"
        descriptor = self.root / "candidate.json"
        with mock.patch.object(packager, "MAX_PACKAGE_FILE_BYTES", 4):
            with self.assertRaisesRegex(packager.DistributionError, "byte count"):
                packager.package_distribution(self.package, archive, descriptor, self.contract,
                    "https://aagedal.me/models/AuraFaceR100.mlpackage.zip", False)
        self.assertFalse(archive.exists()); self.assertFalse(descriptor.exists())
        target = self.package / "Manifest.json"
        outside = self.root / "linked.json"; outside.write_bytes(target.read_bytes())
        target.unlink(); target.symlink_to(outside)
        with self.assertRaisesRegex(packager.DistributionError, "linked"):
            packager.verify_package(self.package, self.contract)

    def test_output_paths_cannot_overwrite_model_or_alias_candidates(self) -> None:
        archive = self.root / "AuraFaceR100.mlpackage.zip"
        for descriptor in (self.package / "Manifest.json", self.package / "new" / "descriptor.json", archive):
            with self.subTest(descriptor=descriptor):
                with self.assertRaises(packager.DistributionError):
                    packager.package_distribution(self.package, archive, descriptor, self.contract,
                        "https://aagedal.me/models/AuraFaceR100.mlpackage.zip", True)
                self.assertFalse(archive.exists())
                self.assertEqual({name: (self.package / name).read_bytes() for name in self.files}, self.files)
        alias = self.root / "model-alias"; alias.symlink_to(self.package, target_is_directory=True)
        with self.assertRaisesRegex(packager.DistributionError, "overlap"):
            packager.package_distribution(self.package, archive, alias / "Manifest.json", self.contract,
                "https://aagedal.me/models/AuraFaceR100.mlpackage.zip", True)

    def test_descriptor_basename_cannot_collide_with_replacement_backups(self) -> None:
        archive = self.root / "AuraFaceR100.mlpackage.zip"
        descriptor = self.root / "backup-AuraFaceR100.mlpackage.zip"
        archive.write_bytes(b"previous archive"); descriptor.write_bytes(b"previous descriptor")
        packager.package_distribution(self.package, archive, descriptor, self.contract,
            "https://aagedal.me/models/AuraFaceR100.mlpackage.zip", True)
        self.assertEqual(json.loads(descriptor.read_bytes())["schemaVersion"], 2)
        packager.verify_distribution(archive, descriptor, self.contract)

    def test_late_destination_without_replace_is_preserved(self) -> None:
        archive = self.root / "AuraFaceR100.mlpackage.zip"
        descriptor = self.root / "candidate.json"
        real_link = packager.os.link

        def racing_link(source, destination, **kwargs):
            if Path(destination) == archive:
                archive.write_bytes(b"independent completed artifact")
            return real_link(source, destination, **kwargs)

        with mock.patch.object(packager.os, "link", side_effect=racing_link):
            with self.assertRaises(FileExistsError):
                packager.package_distribution(self.package, archive, descriptor, self.contract,
                    "https://aagedal.me/models/AuraFaceR100.mlpackage.zip", False)
        self.assertEqual(archive.read_bytes(), b"independent completed artifact")
        self.assertFalse(descriptor.exists())

    def test_app_target_and_release_gate_enforce_model_separation(self) -> None:
        project = (REPOSITORY / "Aagedal Photo Agent.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        self.assertIn("Resources/Models/AuraFaceR100.mlpackage,", project)

        release = (REPOSITORY / "scripts/release.sh").read_text(encoding="utf-8")
        self.assertIn(
            'python3 -B scripts/ci/validate_model_omission.py "$APP" > "$OUTPUT_DIR/model-omission.json"',
            release,
        )
        self.assertIn('|| die "Exported app failed the recursive on-demand model omission check."', release)


if __name__ == "__main__":
    unittest.main()
