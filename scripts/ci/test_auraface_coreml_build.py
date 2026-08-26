#!/usr/bin/env python3
"""Offline tests for the deterministic AuraFace Core ML build contract."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "build_auraface_coreml.py"
SPEC = importlib.util.spec_from_file_location("build_auraface_coreml", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = builder
SPEC.loader.exec_module(builder)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class AuraFaceCoreMLBuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "scripts/auraface").mkdir(parents=True)
        self.files = {
            "scripts/build.py": b"recipe\n",
            "scripts/fetch.py": b"fetch\n",
            "scripts/auraface/.python-version": b"3.12.11\n",
            "scripts/auraface/uv.lock": b'''version = 1
requires-python = "==3.12.*"

[[package]]
name = "aagedal-auraface-converter"
version = "0.0.0"
source = { virtual = "." }

[package.metadata]
requires-dist = [
    { name = "coremltools", specifier = "==9.0" },
    { name = "numpy", specifier = "==1.26.4" },
]

[[package]]
name = "coremltools"
version = "9.0"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://example.invalid/coremltools.whl", hash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }]

[[package]]
name = "numpy"
version = "1.26.4"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://example.invalid/numpy.whl", hash = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }]
''',
        }
        for relative, data in self.files.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        swift = self.root / "Aagedal Photo Agent/Services/FaceEmbedding/CoreMLFaceEmbedder.swift"
        swift.parent.mkdir(parents=True)
        swift.write_text(
            '''let dimension = 512
private static let inputSize = 112
private static let inputName = "input"
private static let outputName = "embedding"
private static let mean: Float = 127.5
private static let std: Float = 127.5
private static let inputIsRGB = true
''',
            encoding="utf-8",
        )
        self.project = self.root / "scripts/auraface/pyproject.toml"
        self.project.write_text(
            """[project]
requires-python = "==3.12.*"
dependencies = ["coremltools==9.0", "numpy==1.26.4"]

[tool.uv]
required-version = "==0.11.19"
""",
            encoding="utf-8",
        )
        self.files["scripts/auraface/pyproject.toml"] = self.project.read_bytes()
        self.manifest = self.root / "manifest.json"
        self.write_manifest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_manifest(self, *, clean_builds: int = 2, minimum_cosine: float = 0.999) -> None:
        support = {
            relative: f"sha256:{digest(data)}"
            for relative, data in self.files.items()
            if relative != "scripts/build.py"
        }
        document = {
            "components": [{
                "id": builder.COMPONENT_ID,
                "artifactPath": "artifact.mlpackage",
                "artifactFiles": {name: "a" * 64 for name in builder.PACKAGE_FILES},
                "upstream": {"sourceSHA256": "b" * 64},
                "buildRecipe": {
                    "repositoryPath": "scripts/build.py",
                    "revision": f"sha256:{digest(self.files['scripts/build.py'])}",
                    "supportingFiles": support,
                },
                "buildContract": {
                    "pythonVersion": "3.12.11",
                    "uvVersion": "0.11.19",
                    "dependencies": {"coremltools": "9.0", "numpy": "1.26.4"},
                    "determinism": {"seed": 7, "cleanBuilds": clean_builds},
                    "semanticVerification": {"samples": 3, "minimumCosineSimilarity": minimum_cosine},
                    "modelInterface": {
                        "inputName": "input",
                        "inputShape": [1, 3, 112, 112],
                        "inputType": "float32",
                        "layout": "NCHW",
                        "channelOrder": "RGB",
                        "normalization": "(x - 127.5) / 127.5",
                        "outputName": "embedding",
                        "outputLength": 512,
                    },
                    "metadata": {
                        "author": "fixture",
                        "license": "Apache-2.0",
                        "shortDescription": "fixture",
                        "sourceRevision": "c" * 40,
                        "versionString": "fixture-v1",
                    },
                },
            }],
        }
        self.manifest.write_text(json.dumps(document), encoding="utf-8")

    def make_package(self, path: Path, *, model: bytes = b"model") -> None:
        (path / "Data/com.apple.CoreML/weights").mkdir(parents=True)
        (path / "Data/com.apple.CoreML/model.mlmodel").write_bytes(model)
        (path / "Data/com.apple.CoreML/weights/weight.bin").write_bytes(b"weights")
        (path / "Manifest.json").write_text(json.dumps({
            "fileFormatVersion": "1.0.0",
            "itemInfoEntries": {
                "RANDOM-MODEL": {
                    "author": "com.apple.CoreML",
                    "description": "CoreML Model Specification",
                    "name": "model.mlmodel",
                    "path": "com.apple.CoreML/model.mlmodel",
                },
                "RANDOM-WEIGHTS": {
                    "author": "com.apple.CoreML",
                    "description": "CoreML Model Weights",
                    "name": "weights",
                    "path": "com.apple.CoreML/weights",
                },
            },
            "rootModelIdentifier": "RANDOM-MODEL",
        }), encoding="utf-8")
        builder.normalize_package_manifest(path)

    def test_contract_verifies_all_content_pinned_recipe_files(self) -> None:
        contract = builder.load_contract(self.manifest)
        builder.verify_contract_files(self.root, contract)
        (self.root / "scripts/auraface/uv.lock").write_text("drift\n", encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildError, "recipe drift"):
            builder.verify_contract_files(self.root, contract)

    def test_contract_rejects_single_build_and_weak_semantic_threshold(self) -> None:
        self.write_manifest(clean_builds=1)
        with self.assertRaisesRegex(builder.BuildError, "at least two clean builds"):
            builder.load_contract(self.manifest)
        self.write_manifest(minimum_cosine=0.9)
        with self.assertRaisesRegex(builder.BuildError, "between 0.99 and 1.0"):
            builder.load_contract(self.manifest)

    def test_contract_rejects_swift_preprocessing_drift(self) -> None:
        contract = builder.load_contract(self.manifest)
        swift = self.root / "Aagedal Photo Agent/Services/FaceEmbedding/CoreMLFaceEmbedder.swift"
        swift.write_text(swift.read_text(encoding="utf-8").replace("inputIsRGB = true", "inputIsRGB = false"), encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildError, "Swift preprocessing"):
            builder.verify_contract_files(self.root, contract)

    def test_package_manifest_normalization_removes_generated_identifiers(self) -> None:
        first = self.root / "first.mlpackage"
        second = self.root / "second.mlpackage"
        self.make_package(first)
        self.make_package(second)
        self.assertEqual((first / "Manifest.json").read_bytes(), (second / "Manifest.json").read_bytes())
        self.assertNotIn("RANDOM", (first / "Manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(set(builder.package_hashes(first)), set(builder.PACKAGE_FILES))

    def test_package_file_set_fails_closed(self) -> None:
        package = self.root / "package.mlpackage"
        self.make_package(package)
        (package / "unexpected.txt").write_text("unexpected", encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildError, "file set mismatch"):
            builder.package_hashes(package)

    def test_cosine_similarity_validates_shape_and_zero_norm(self) -> None:
        self.assertAlmostEqual(builder.cosine_similarity([1, 2], [2, 4]), 1.0)
        with self.assertRaisesRegex(builder.BuildError, "same non-zero length"):
            builder.cosine_similarity([1], [1, 2])
        with self.assertRaisesRegex(builder.BuildError, "zero norm"):
            builder.cosine_similarity([0, 0], [1, 1])

    def test_reproduce_requires_identical_clean_packages_before_install(self) -> None:
        contract = builder.load_contract(self.manifest)
        source = self.root / "source.onnx"
        source.write_bytes(b"source")
        output = self.root / "output.mlpackage"
        calls = 0

        def mismatched_convert(_source: Path, package: Path, _contract: object) -> object:
            nonlocal calls
            calls += 1
            self.make_package(package, model=f"model-{calls}".encode())
            return object()

        with (
            mock.patch.object(builder, "verify_runtime"),
            mock.patch.object(builder, "verify_source"),
            mock.patch.object(builder, "convert_once", side_effect=mismatched_convert),
            mock.patch.object(builder, "semantic_verify", return_value=[1.0, 1.0, 1.0]),
        ):
            with self.assertRaisesRegex(builder.BuildError, "not byte-identical"):
                builder.reproduce(source, output, contract, False)
        self.assertFalse(output.exists())

    def test_reproduce_installs_only_after_semantic_verification(self) -> None:
        contract = builder.load_contract(self.manifest)
        source = self.root / "source.onnx"
        source.write_bytes(b"source")
        output = self.root / "output.mlpackage"

        def identical_convert(_source: Path, package: Path, _contract: object) -> object:
            self.make_package(package)
            return object()

        with (
            mock.patch.object(builder, "verify_runtime"),
            mock.patch.object(builder, "verify_source"),
            mock.patch.object(builder, "convert_once", side_effect=identical_convert),
            mock.patch.object(builder, "semantic_verify", return_value=[0.9999, 0.9998, 0.9997]) as semantic,
        ):
            hashes, similarities = builder.reproduce(source, output, contract, False)
        self.assertEqual(hashes, builder.package_hashes(output))
        self.assertEqual(similarities, [0.9999, 0.9998, 0.9997])
        semantic.assert_called_once()


if __name__ == "__main__":
    unittest.main()
