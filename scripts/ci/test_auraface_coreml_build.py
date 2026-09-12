#!/usr/bin/env python3
"""Offline tests for the deterministic AuraFace Core ML build contract."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "build_auraface_coreml.py"
REPOSITORY_FIXTURE = SCRIPT.parent / "auraface/fixtures/channel-asymmetric-112x112.ppm.base64"
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
            str(builder.CHANNEL_FIXTURE): b"fixture\n",
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
                "version": "fixture-v1",
                "artifactPath": "artifact.mlpackage",
                "artifactFiles": {name: "a" * 64 for name in builder.PACKAGE_FILES},
                "upstream": {
                    "url": "https://example.invalid/fixture",
                    "revision": "c" * 40,
                    "sourceFile": "source.onnx",
                    "sourceSHA256": "b" * 64,
                },
                "buildRecipe": {
                    "repositoryPath": "scripts/build.py",
                    "revision": f"sha256:{digest(self.files['scripts/build.py'])}",
                    "supportingFiles": support,
                },
                "buildContract": {
                    "embeddingVersion": 3,
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
        self.write_manifest(clean_builds=True)
        with self.assertRaisesRegex(builder.BuildError, "at least two clean builds"):
            builder.load_contract(self.manifest)
        self.write_manifest(minimum_cosine=0.9)
        with self.assertRaisesRegex(builder.BuildError, "between 0.99 and 1.0"):
            builder.load_contract(self.manifest)
        self.write_manifest(minimum_cosine=True)
        with self.assertRaisesRegex(builder.BuildError, "between 0.99 and 1.0"):
            builder.load_contract(self.manifest)

    def test_contract_rejects_swift_preprocessing_drift(self) -> None:
        contract = builder.load_contract(self.manifest)
        swift = self.root / "Aagedal Photo Agent/Services/FaceEmbedding/CoreMLFaceEmbedder.swift"
        swift.write_text(swift.read_text(encoding="utf-8").replace("inputIsRGB = true", "inputIsRGB = false"), encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildError, "Swift preprocessing"):
            builder.verify_contract_files(self.root, contract)

    def test_runtime_requires_fixed_python_hash_seed(self) -> None:
        contract = builder.load_contract(self.manifest)
        versions = {"coremltools": "9.0", "numpy": "1.26.4"}
        with (
            mock.patch.object(builder.platform, "python_version", return_value="3.12.11"),
            mock.patch.object(builder.platform, "machine", return_value="arm64"),
            mock.patch.object(builder.sys, "platform", "darwin"),
            mock.patch.object(builder.importlib.metadata, "version", side_effect=versions.__getitem__),
            mock.patch.dict(builder.os.environ, {}, clear=True),
        ):
            with self.assertRaisesRegex(builder.BuildError, "PYTHONHASHSEED=0"):
                builder.verify_runtime(contract)
        with (
            mock.patch.object(builder.platform, "python_version", return_value="3.12.11"),
            mock.patch.object(builder.platform, "machine", return_value="arm64"),
            mock.patch.object(builder.sys, "platform", "darwin"),
            mock.patch.object(builder.importlib.metadata, "version", side_effect=versions.__getitem__),
            mock.patch.dict(builder.os.environ, {"PYTHONHASHSEED": "0"}, clear=True),
        ):
            builder.verify_runtime(contract)

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
        with self.assertRaisesRegex(builder.BuildError, "non-finite"):
            builder.cosine_similarity([math.nan, 1], [1, 1])

    def test_checked_in_fixture_is_exact_size_and_channel_asymmetric(self) -> None:
        document, width, height, pixels = builder.decode_ppm_fixture(REPOSITORY_FIXTURE)
        self.assertEqual((width, height), (112, 112))
        self.assertEqual(len(pixels), 112 * 112 * 3)
        self.assertEqual(hashlib.sha256(document).hexdigest(), "3a447d70e3e4e4dde6a3757d34f37dc745a7fdba3b8e5db4c9c14d6fd5d83223")
        rgb = builder.preprocess_rgb_pixels(pixels, width, height, "RGB")
        bgr = builder.preprocess_rgb_pixels(pixels, width, height, "BGR")
        plane = width * height
        self.assertEqual(rgb[:plane], bgr[2 * plane:])
        self.assertEqual(rgb[2 * plane:], bgr[:plane])
        self.assertNotEqual(rgb, bgr)

    def test_channel_control_requires_consistent_runtimes_and_material_bgr_difference(self) -> None:
        contract = builder.load_contract(self.manifest)
        rgb = [1.0, 0.0] + [0.0] * 510
        bgr = [0.0, 1.0] + [0.0] * 510
        result = builder.validate_channel_outputs(rgb, rgb, bgr, bgr, contract, "d" * 64, 112, 112)
        self.assertEqual(result.torch_coreml_rgb_cosine, 1.0)
        self.assertEqual(result.torch_rgb_bgr_cosine, 0.0)
        with self.assertRaisesRegex(builder.BuildError, "not materially different"):
            builder.validate_channel_outputs(rgb, rgb, rgb, rgb, contract, "d" * 64, 112, 112)
        with self.assertRaisesRegex(builder.BuildError, "Torch/Core ML similarity"):
            builder.validate_channel_outputs(rgb, bgr, bgr, bgr, contract, "d" * 64, 112, 112)

    def channel_result(self) -> object:
        vector = (1.0, 0.0) + (0.0,) * 510
        return builder.ChannelVerification(
            fixture_sha256="d" * 64,
            width=112,
            height=112,
            torch_coreml_rgb_cosine=0.99999,
            torch_coreml_bgr_cosine=0.99998,
            torch_rgb_bgr_cosine=0.7,
            coreml_rgb_bgr_cosine=0.70001,
            normalized_torch_reference=vector,
            normalized_coreml_reference=vector,
        )

    def test_receipt_is_deterministic_canonical_and_detects_tampering(self) -> None:
        contract = builder.load_contract(self.manifest)
        hashes = {name: digest(name.encode()) for name in reversed(builder.PACKAGE_FILES)}
        first = builder.build_receipt(contract, hashes, [0.99991, 0.99992, 0.99993], self.channel_result())
        second = builder.build_receipt(contract, dict(reversed(list(hashes.items()))), [0.99991, 0.99992, 0.99993], self.channel_result())
        canonical = builder.canonical_json_bytes(first)
        self.assertEqual(canonical, builder.canonical_json_bytes(second))
        self.assertFalse(canonical.endswith(b"\n"))
        self.assertIn("normalizedCoreMLReference", first["channelVerification"])
        builder.verify_receipt_bytes(canonical, first)
        with self.assertRaisesRegex(builder.BuildError, "canonical JSON"):
            builder.verify_receipt_bytes(json.dumps(first, indent=2).encode(), first)
        tampered = json.loads(canonical)
        tampered["artifactFiles"][builder.PACKAGE_FILES[0]]["sha256"] = "0" * 64
        with self.assertRaisesRegex(builder.BuildError, "does not match"):
            builder.verify_receipt_bytes(builder.canonical_json_bytes(tampered), first)

    def test_package_and_receipt_install_roll_back_if_second_install_fails(self) -> None:
        contract = builder.load_contract(self.manifest)
        source = self.root / "new.mlpackage"
        destination = self.root / "installed.mlpackage"
        receipt = self.root / "installed.build-receipt.json"
        self.make_package(source, model=b"new model")
        self.make_package(destination, model=b"old model")
        receipt.write_bytes(b"old receipt")
        old_hashes = builder.package_hashes(destination)
        new_hashes = builder.package_hashes(source)
        document = builder.build_receipt(
            contract,
            new_hashes,
            [0.9999, 0.9998, 0.9997],
            self.channel_result(),
        )
        calls = 0

        def fail_receipt_install(source_path: Path, destination_path: Path) -> None:
            nonlocal calls
            calls += 1
            if calls == 4:
                raise OSError("injected receipt install failure")
            builder.os.replace(source_path, destination_path)

        with self.assertRaisesRegex(OSError, "injected receipt install failure"):
            builder.install_reproduction(
                source,
                document,
                destination,
                receipt,
                True,
                replace_item=fail_receipt_install,
            )
        self.assertEqual(builder.package_hashes(destination), old_hashes)
        self.assertEqual(receipt.read_bytes(), b"old receipt")
        self.assertFalse(any(path.name.startswith(".installed") for path in self.root.iterdir()))

    def test_reproduce_requires_identical_clean_packages_before_install(self) -> None:
        contract = builder.load_contract(self.manifest)
        source = self.root / "source.onnx"
        source.write_bytes(b"source")
        output = self.root / "output.mlpackage"
        receipt = self.root / "output.build-receipt.json"
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
                builder.reproduce(source, output, receipt, self.root / builder.CHANNEL_FIXTURE, contract, False)
        self.assertFalse(output.exists())

    def test_reproduce_installs_only_after_semantic_verification(self) -> None:
        contract = builder.load_contract(self.manifest)
        source = self.root / "source.onnx"
        source.write_bytes(b"source")
        output = self.root / "output.mlpackage"
        receipt = self.root / "output.build-receipt.json"

        def identical_convert(_source: Path, package: Path, _contract: object) -> object:
            self.make_package(package)
            return object()

        with (
            mock.patch.object(builder, "verify_runtime"),
            mock.patch.object(builder, "verify_source"),
            mock.patch.object(builder, "convert_once", side_effect=identical_convert),
            mock.patch.object(builder, "semantic_verify", return_value=[0.9999, 0.9998, 0.9997]) as semantic,
            mock.patch.object(builder, "channel_verify", return_value=self.channel_result()) as channel,
        ):
            hashes, similarities, receipt_document = builder.reproduce(
                source,
                output,
                receipt,
                self.root / builder.CHANNEL_FIXTURE,
                contract,
                False,
            )
        self.assertEqual(hashes, builder.package_hashes(output))
        self.assertEqual(similarities, [0.9999, 0.9998, 0.9997])
        semantic.assert_called_once()
        self.assertEqual(channel.call_count, 2)
        builder.verify_receipt_bytes(receipt.read_bytes(), receipt_document)


if __name__ == "__main__":
    unittest.main()
