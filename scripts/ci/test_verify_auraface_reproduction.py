#!/usr/bin/env python3
"""Offline tests for independent-process AuraFace reproduction verification."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify_auraface_reproduction.py")
SPEC = importlib.util.spec_from_file_location("verify_auraface_reproduction", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verifier
SPEC.loader.exec_module(verifier)


class FakeRunner:
    def __init__(
        self,
        *,
        dirty: bool = False,
        matches_declared: bool = True,
        noncanonical: bool = False,
        vary_second_receipt: bool = False,
        fail_process: int | None = None,
    ) -> None:
        self.dirty = dirty
        self.matches_declared = matches_declared
        self.noncanonical = noncanonical
        self.vary_second_receipt = vary_second_receipt
        self.fail_process = fail_process
        self.calls: list[tuple[tuple[str, ...], Path, dict[str, str]]] = []
        self.reproductions = 0

    def __call__(self, arguments: object, cwd: Path, environment: object) -> object:
        command = tuple(arguments)
        copied_environment = dict(environment)
        self.calls.append((command, cwd, copied_environment))
        if command[:2] == ("git", "status"):
            return verifier.CommandResult(0, " M scripts/build.py\n" if self.dirty else "", "")
        if command[:2] == ("git", "rev-parse"):
            return verifier.CommandResult(0, "a" * 40 + "\n", "")
        if command[:2] != ("uv", "run"):
            return verifier.CommandResult(127, "", "unexpected command")

        self.reproductions += 1
        if self.fail_process == self.reproductions:
            return verifier.CommandResult(2, "", "injected conversion failure")
        output = Path(command[command.index("--output") + 1])
        receipt_path = Path(command[command.index("--receipt") + 1])
        source_path = Path(command[command.index("--source") + 1])
        (output / "Data/com.apple.CoreML/weights").mkdir(parents=True)
        package_bytes = {
            "Data/com.apple.CoreML/model.mlmodel": b"deterministic model",
            "Data/com.apple.CoreML/weights/weight.bin": b"deterministic weights",
            "Manifest.json": b'{"deterministic":true}',
        }
        artifact_files = {}
        for relative, data in package_bytes.items():
            (output / relative).write_bytes(data)
            artifact_files[relative] = {"sha256": hashlib.sha256(data).hexdigest()}
        receipt = {
            "schemaVersion": 1,
            "matchesDeclaredArtifactFiles": self.matches_declared,
            "artifactFiles": artifact_files,
            "declaredArtifactFiles": artifact_files,
            "runtimeContract": {
                "pythonVersion": "3.12.11",
                "pythonHashSeed": "0",
                "uvVersion": "0.11.19",
            },
            "source": {
                "repository": "https://example.invalid/model",
                "revision": "b" * 40,
                "file": "model.onnx",
                "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
            },
        }
        if self.vary_second_receipt and self.reproductions == 2:
            receipt["runtimeContract"]["uvVersion"] = "0.11.20"
        raw = verifier.canonical_json_bytes(receipt)
        receipt_path.write_bytes(raw + (b"\n" if self.noncanonical else b""))
        return verifier.CommandResult(0, "reproduced\n", "")


class AuraFaceIndependentReproductionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        self.source = self.root / verifier.DEFAULT_SOURCE
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"pinned ONNX")
        self.manifest = self.root / verifier.DEFAULT_MANIFEST
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text("{}", encoding="utf-8")
        self.evidence = self.root / "build/reproduction-evidence"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def config(self, evidence: Path | None = None) -> object:
        return verifier.VerificationConfig(
            self.root,
            self.source,
            self.manifest,
            evidence or self.evidence,
        )

    def test_two_independent_processes_emit_canonical_machine_evidence(self) -> None:
        runner = FakeRunner()
        evidence = verifier.verify(self.config(), runner)
        reproduction_calls = [call for call in runner.calls if call[0][:2] == ("uv", "run")]
        self.assertEqual(len(reproduction_calls), 2)
        self.assertTrue(all(call[2]["PYTHONHASHSEED"] == "0" for call in reproduction_calls))
        self.assertNotEqual(
            reproduction_calls[0][0][reproduction_calls[0][0].index("--output") + 1],
            reproduction_calls[1][0][reproduction_calls[1][0].index("--output") + 1],
        )
        self.assertEqual(evidence["status"], "verified")
        self.assertEqual(evidence["repositoryRevision"], "a" * 40)
        self.assertEqual(evidence["source"]["revision"], "b" * 40)
        self.assertEqual(set(evidence["packageFiles"]), set(verifier.PACKAGE_FILES))
        written = (self.evidence / verifier.EVIDENCE_NAME).read_bytes()
        self.assertEqual(written, verifier.canonical_json_bytes(evidence))
        self.assertFalse(written.endswith(b"\n"))

    def test_dirty_tracked_state_is_rejected_before_outputs_are_created(self) -> None:
        runner = FakeRunner(dirty=True)
        with self.assertRaisesRegex(verifier.VerificationError, "tracked repository state is dirty"):
            verifier.verify(self.config(), runner)
        self.assertFalse(self.evidence.exists())
        self.assertFalse(any(call[0][:2] == ("uv", "run") for call in runner.calls))

    def test_existing_evidence_is_never_replaced_or_deleted(self) -> None:
        self.evidence.mkdir(parents=True)
        marker = self.evidence / "prior-evidence.json"
        marker.write_text("preserve me", encoding="utf-8")
        runner = FakeRunner()
        with self.assertRaisesRegex(verifier.VerificationError, "already exists"):
            verifier.verify(self.config(), runner)
        self.assertEqual(marker.read_text(encoding="utf-8"), "preserve me")
        self.assertEqual(runner.calls, [])

    def test_source_and_output_overlap_is_rejected(self) -> None:
        overlapping = Path(str(self.source) + "/evidence")
        runner = FakeRunner()
        with self.assertRaisesRegex(verifier.VerificationError, "must not overlap"):
            verifier.verify(self.config(overlapping), runner)
        self.assertEqual(runner.calls, [])

    def test_false_declared_artifact_match_is_rejected_and_outputs_are_retained(self) -> None:
        runner = FakeRunner(matches_declared=False)
        with self.assertRaisesRegex(verifier.VerificationError, "does not match declared"):
            verifier.verify(self.config(), runner)
        self.assertTrue((self.evidence / "process-1/AuraFaceR100.mlpackage").is_dir())
        self.assertTrue((self.evidence / "process-1/AuraFaceR100.build-receipt.json").is_file())
        self.assertFalse((self.evidence / verifier.EVIDENCE_NAME).exists())

    def test_noncanonical_receipt_is_rejected(self) -> None:
        runner = FakeRunner(noncanonical=True)
        with self.assertRaisesRegex(verifier.VerificationError, "not compact canonical JSON"):
            verifier.verify(self.config(), runner)

    def test_distinct_receipt_bytes_from_processes_are_rejected(self) -> None:
        runner = FakeRunner(vary_second_receipt=True)
        with self.assertRaisesRegex(verifier.VerificationError, "receipts differ byte-for-byte"):
            verifier.verify(self.config(), runner)

    def test_subprocess_failure_is_reported_without_deleting_process_directory(self) -> None:
        runner = FakeRunner(fail_process=2)
        with self.assertRaisesRegex(verifier.VerificationError, "injected conversion failure"):
            verifier.verify(self.config(), runner)
        self.assertTrue((self.evidence / "process-1/AuraFaceR100.mlpackage").is_dir())
        self.assertTrue((self.evidence / "process-2").is_dir())


if __name__ == "__main__":
    unittest.main()
