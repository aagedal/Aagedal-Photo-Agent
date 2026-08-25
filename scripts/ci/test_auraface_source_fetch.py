#!/usr/bin/env python3
"""Offline tests for the manifest-pinned AuraFace source fetcher."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "fetch_auraface_source.py"
SPEC = importlib.util.spec_from_file_location("fetch_auraface_source", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
fetcher = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = fetcher
SPEC.loader.exec_module(fetcher)


class AuraFaceSourceFetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source_bytes = b"pinned ONNX fixture"
        self.digest = hashlib.sha256(self.source_bytes).hexdigest()
        self.manifest = self.root / "manifest.json"
        self.write_manifest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_manifest(
        self,
        *,
        revision: str = "a" * 40,
        source_hash: str | None = None,
        source_file: str = "glintr100.onnx",
    ) -> None:
        self.manifest.write_text(
            json.dumps({
                "components": [{
                    "id": fetcher.COMPONENT_ID,
                    "upstream": {
                        "url": "https://huggingface.co/fal/AuraFace-v1",
                        "revision": revision,
                        "sourceFile": source_file,
                        "sourceSHA256": source_hash or self.digest,
                    },
                }],
            }),
            encoding="utf-8",
        )

    def test_pin_and_command_use_exact_manifest_revision(self) -> None:
        pin = fetcher.load_source_pin(self.manifest)
        command = fetcher.hf_download_command(pin, Path("download"))
        self.assertEqual(pin.repository, "fal/AuraFace-v1")
        self.assertEqual(command[:4], ["hf", "download", "fal/AuraFace-v1", "glintr100.onnx"])
        self.assertEqual(command[command.index("--revision") + 1], "a" * 40)
        self.assertNotIn("main", command)

    def test_rejects_mutable_revision_and_unsafe_filename(self) -> None:
        self.write_manifest(revision="main")
        with self.assertRaisesRegex(fetcher.SourceError, "full 40-character"):
            fetcher.load_source_pin(self.manifest)
        self.write_manifest(source_file="../glintr100.onnx")
        with self.assertRaisesRegex(fetcher.SourceError, "safe basename"):
            fetcher.load_source_pin(self.manifest)

    def test_verify_rejects_hash_drift(self) -> None:
        source = self.root / "source.onnx"
        source.write_bytes(b"different")
        with self.assertRaisesRegex(fetcher.SourceError, "SHA-256 mismatch"):
            fetcher.verify_source(source, fetcher.load_source_pin(self.manifest))

    def test_fetch_is_offline_testable_and_installs_only_verified_bytes(self) -> None:
        destination = self.root / "output" / "glintr100.onnx"
        commands: list[list[str]] = []

        def runner(command: list[str], download_directory: Path) -> None:
            commands.append(command)
            (download_directory / "glintr100.onnx").write_bytes(self.source_bytes)

        status = fetcher.fetch_source(destination, fetcher.load_source_pin(self.manifest), runner=runner)
        self.assertEqual(status, "downloaded and verified")
        self.assertEqual(destination.read_bytes(), self.source_bytes)
        self.assertEqual(len(commands), 1)

    def test_bad_download_does_not_replace_existing_destination(self) -> None:
        destination = self.root / "glintr100.onnx"
        destination.write_bytes(b"existing")

        def runner(_command: list[str], download_directory: Path) -> None:
            (download_directory / "glintr100.onnx").write_bytes(b"bad download")

        with self.assertRaisesRegex(fetcher.SourceError, "SHA-256 mismatch"):
            fetcher.fetch_source(
                destination,
                fetcher.load_source_pin(self.manifest),
                replace=True,
                runner=runner,
            )
        self.assertEqual(destination.read_bytes(), b"existing")

    def test_matching_destination_skips_hf(self) -> None:
        destination = self.root / "glintr100.onnx"
        destination.write_bytes(self.source_bytes)

        def unexpected_runner(_command: list[str], _download_directory: Path) -> None:
            self.fail("hf runner should not be called for an already verified source")

        status = fetcher.fetch_source(
            destination,
            fetcher.load_source_pin(self.manifest),
            runner=unexpected_runner,
        )
        self.assertEqual(status, "already verified")


if __name__ == "__main__":
    unittest.main()
