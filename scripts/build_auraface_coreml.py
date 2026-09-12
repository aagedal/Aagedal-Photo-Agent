#!/usr/bin/env python3
"""Build and verify AuraFace Core ML from the manifest-pinned ONNX source.

The lightweight ``contract`` and package-digest checks need only the standard
library. ``reproduce`` and semantic ``verify`` must run through the checked-in
uv lock so the conversion imports exactly the reviewed dependency graph.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import re
import shutil
import sys
import tempfile
import tomllib
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


DEFAULT_MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
DEFAULT_SOURCE = Path("build/model-sources/auraface/glintr100.onnx")
DEFAULT_OUTPUT = Path("build/auraface/AuraFaceR100.mlpackage")
DEFAULT_RECEIPT = Path("build/auraface/AuraFaceR100.build-receipt.json")
CHANNEL_FIXTURE = Path("scripts/auraface/fixtures/channel-asymmetric-112x112.ppm.base64")
COMPONENT_ID = "auraface-r100-coreml"
PACKAGE_FILES = (
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
    "Manifest.json",
)
PACKAGE_NAMESPACE = uuid.UUID("de036ddf-a840-58e7-92c7-e42de6a05bbf")
MINIMUM_CHANNEL_COSINE_DISTANCE = 0.001
PYTHON_HASH_SEED = "0"
RECEIPT_FLOAT_DIGITS = 9


class BuildError(ValueError):
    """The declared build contract or generated artifact is invalid."""


@dataclass(frozen=True)
class Contract:
    source_url: str
    source_revision: str
    source_file: str
    source_sha256: str
    component_version: str
    embedding_version: int
    artifact_path: Path
    artifact_files: dict[str, str]
    python_version: str
    uv_version: str
    dependencies: dict[str, str]
    seed: int
    clean_builds: int
    semantic_samples: int
    minimum_cosine: float
    input_name: str
    input_shape: tuple[int, ...]
    channel_order: str
    output_name: str
    output_length: int
    metadata: dict[str, str]
    recipe_files: dict[Path, str]


@dataclass(frozen=True)
class ChannelVerification:
    fixture_sha256: str
    width: int
    height: int
    torch_coreml_rgb_cosine: float
    torch_coreml_bgr_cosine: float
    torch_rgb_bgr_cosine: float
    coreml_rgb_bgr_cosine: float
    normalized_torch_reference: tuple[float, ...]
    normalized_coreml_reference: tuple[float, ...]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise BuildError(f"{label} must be one lowercase SHA-256 digest")
    return value


def require_mapping(value: object, label: str) -> dict:
    if not isinstance(value, dict) or not value:
        raise BuildError(f"{label} must be a non-empty object")
    return value


def load_contract(manifest_path: Path) -> Contract:
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    components = document.get("components")
    if not isinstance(components, list):
        raise BuildError("manifest components must be an array")
    matches = [item for item in components if isinstance(item, dict) and item.get("id") == COMPONENT_ID]
    if len(matches) != 1:
        raise BuildError(f"manifest must contain exactly one {COMPONENT_ID!r} component")
    component = matches[0]
    upstream = require_mapping(component.get("upstream"), "AuraFace upstream")
    recipe = require_mapping(component.get("buildRecipe"), "AuraFace buildRecipe")
    build = require_mapping(component.get("buildContract"), "AuraFace buildContract")
    interface = require_mapping(build.get("modelInterface"), "AuraFace modelInterface")
    semantic = require_mapping(build.get("semanticVerification"), "AuraFace semanticVerification")
    determinism = require_mapping(build.get("determinism"), "AuraFace determinism")
    metadata = require_mapping(build.get("metadata"), "AuraFace metadata")
    required_metadata = {"author", "license", "shortDescription", "sourceRevision", "versionString"}
    if set(metadata) != required_metadata or not all(
        isinstance(value, str) and value for value in metadata.values()
    ):
        raise BuildError(f"AuraFace metadata must define exactly {sorted(required_metadata)}")

    dependencies = build.get("dependencies")
    if not isinstance(dependencies, dict) or not dependencies or not all(
        isinstance(key, str) and isinstance(value, str) and key and value
        for key, value in dependencies.items()
    ):
        raise BuildError("AuraFace dependencies must map package names to exact versions")

    artifact_files = component.get("artifactFiles")
    if not isinstance(artifact_files, dict) or set(artifact_files) != set(PACKAGE_FILES):
        raise BuildError("AuraFace artifactFiles must declare the exact Core ML package file set")
    for name, digest in artifact_files.items():
        require_digest(digest, f"artifactFiles[{name!r}]")

    shape = interface.get("inputShape")
    if not isinstance(shape, list) or not shape or not all(type(item) is int and item > 0 for item in shape):
        raise BuildError("AuraFace inputShape must contain positive integers")
    if interface.get("inputType") != "float32" or interface.get("layout") != "NCHW":
        raise BuildError("AuraFace conversion supports only float32 NCHW input")
    if tuple(shape) != (1, 3, 112, 112):
        raise BuildError("AuraFace inputShape must be exactly [1, 3, 112, 112]")
    if interface.get("channelOrder") not in {"RGB", "BGR"}:
        raise BuildError("AuraFace channelOrder must be RGB or BGR")
    if interface.get("normalization") != "(x - 127.5) / 127.5":
        raise BuildError("AuraFace normalization must be exactly (x - 127.5) / 127.5")
    if not isinstance(interface.get("inputName"), str) or not interface["inputName"]:
        raise BuildError("AuraFace inputName must be a non-empty string")
    if not isinstance(interface.get("outputName"), str) or not interface["outputName"]:
        raise BuildError("AuraFace outputName must be a non-empty string")
    if type(interface.get("outputLength")) is not int or interface["outputLength"] <= 0:
        raise BuildError("AuraFace outputLength must be a positive integer")

    clean_builds = determinism.get("cleanBuilds")
    seed = determinism.get("seed")
    samples = semantic.get("samples")
    minimum_cosine = semantic.get("minimumCosineSimilarity")
    if type(clean_builds) is not int or clean_builds < 2:
        raise BuildError("AuraFace determinism requires at least two clean builds")
    if type(seed) is not int or seed < 0:
        raise BuildError("AuraFace determinism seed must be a non-negative integer")
    if type(samples) is not int or samples < 2:
        raise BuildError("AuraFace semantic verification requires at least two samples")
    if type(minimum_cosine) not in (int, float) or not 0.99 <= minimum_cosine <= 1.0:
        raise BuildError("AuraFace minimum cosine similarity must be between 0.99 and 1.0")

    recipe_files: dict[Path, str] = {}
    repository_path = recipe.get("repositoryPath")
    revision = recipe.get("revision")
    if not isinstance(repository_path, str) or not isinstance(revision, str) or not revision.startswith("sha256:"):
        raise BuildError("AuraFace repository build recipe must have a content revision")
    recipe_files[Path(repository_path)] = require_digest(revision.removeprefix("sha256:"), "buildRecipe revision")
    supporting = recipe.get("supportingFiles")
    if not isinstance(supporting, dict) or not supporting:
        raise BuildError("AuraFace buildRecipe must declare supportingFiles")
    for name, digest in supporting.items():
        if not isinstance(name, str) or not isinstance(digest, str) or not digest.startswith("sha256:"):
            raise BuildError("AuraFace supportingFiles must map paths to sha256: revisions")
        recipe_files[Path(name)] = require_digest(digest.removeprefix("sha256:"), f"supportingFiles[{name!r}]")
    if CHANNEL_FIXTURE not in recipe_files:
        raise BuildError(f"AuraFace buildRecipe must content-pin {CHANNEL_FIXTURE}")

    python_version = build.get("pythonVersion")
    uv_version = build.get("uvVersion")
    if not isinstance(python_version, str) or re.fullmatch(r"3\.12\.\d+", python_version) is None:
        raise BuildError("AuraFace pythonVersion must pin one Python 3.12 patch release")
    if not isinstance(uv_version, str) or re.fullmatch(r"\d+\.\d+\.\d+", uv_version) is None:
        raise BuildError("AuraFace uvVersion must pin one exact release")
    source_url = upstream.get("url")
    source_revision = upstream.get("revision")
    source_file = upstream.get("sourceFile")
    if not isinstance(source_url, str) or not source_url.startswith("https://"):
        raise BuildError("AuraFace upstream URL must use HTTPS")
    if not isinstance(source_revision, str) or re.fullmatch(r"[0-9a-f]{40}", source_revision) is None:
        raise BuildError("AuraFace upstream revision must be one full Git commit")
    if not isinstance(source_file, str) or not source_file or Path(source_file).name != source_file:
        raise BuildError("AuraFace upstream sourceFile must be one filename")
    if metadata["sourceRevision"] != source_revision:
        raise BuildError("AuraFace metadata sourceRevision must match the upstream revision")
    component_version = component.get("version")
    embedding_version = build.get("embeddingVersion")
    if not isinstance(component_version, str) or not component_version:
        raise BuildError("AuraFace component version must be a non-empty string")
    if type(embedding_version) is not int or embedding_version <= 0:
        raise BuildError("AuraFace embeddingVersion must be a positive integer")

    return Contract(
        source_url=source_url,
        source_revision=source_revision,
        source_file=source_file,
        source_sha256=require_digest(upstream.get("sourceSHA256"), "AuraFace sourceSHA256"),
        component_version=component_version,
        embedding_version=embedding_version,
        artifact_path=Path(component["artifactPath"]),
        artifact_files=dict(artifact_files),
        python_version=python_version,
        uv_version=uv_version,
        dependencies=dict(dependencies),
        seed=seed,
        clean_builds=clean_builds,
        semantic_samples=samples,
        minimum_cosine=float(minimum_cosine),
        input_name=str(interface.get("inputName", "")),
        input_shape=tuple(shape),
        channel_order=interface["channelOrder"],
        output_name=str(interface.get("outputName", "")),
        output_length=int(interface.get("outputLength", 0)),
        metadata={str(key): str(value) for key, value in metadata.items()},
        recipe_files=recipe_files,
    )


def verify_contract_files(root: Path, contract: Contract) -> None:
    for relative, expected in sorted(contract.recipe_files.items(), key=lambda item: str(item[0])):
        path = root / relative
        if not path.is_file():
            raise BuildError(f"declared AuraFace recipe file is missing: {relative}")
        actual = sha256(path)
        if actual != expected:
            raise BuildError(f"AuraFace recipe drift for {relative}: expected {expected}, got {actual}")

    project_path = root / "scripts/auraface/pyproject.toml"
    project = tomllib.loads(project_path.read_text(encoding="utf-8"))
    declared = {}
    for requirement in project.get("project", {}).get("dependencies", []):
        name, separator, version = requirement.partition("==")
        if not separator or not version:
            raise BuildError(f"AuraFace dependency is not exactly pinned: {requirement}")
        declared[name.lower()] = version
    if declared != {name.lower(): version for name, version in contract.dependencies.items()}:
        raise BuildError("AuraFace manifest dependencies do not match pyproject.toml")
    if project.get("project", {}).get("requires-python") != "==3.12.*":
        raise BuildError("AuraFace pyproject must require Python 3.12 exactly")
    if project.get("tool", {}).get("uv", {}).get("required-version") != f"=={contract.uv_version}":
        raise BuildError("AuraFace pyproject uv version does not match the manifest")
    if (root / "scripts/auraface/.python-version").read_text(encoding="utf-8").strip() != contract.python_version:
        raise BuildError("AuraFace .python-version does not match the manifest")

    lock = tomllib.loads((root / "scripts/auraface/uv.lock").read_text(encoding="utf-8"))
    if lock.get("requires-python") != "==3.12.*":
        raise BuildError("AuraFace uv.lock must require Python 3.12 exactly")
    root_packages = [
        package for package in lock.get("package", [])
        if package.get("name") == "aagedal-auraface-converter"
    ]
    if len(root_packages) != 1:
        raise BuildError("AuraFace uv.lock must contain its conversion project exactly once")
    locked_direct = {}
    for requirement in root_packages[0].get("metadata", {}).get("requires-dist", []):
        specifier = requirement.get("specifier", "")
        if not isinstance(specifier, str) or not specifier.startswith("=="):
            raise BuildError("AuraFace uv.lock contains a non-exact direct requirement")
        locked_direct[str(requirement.get("name", "")).lower()] = specifier.removeprefix("==")
    if locked_direct != declared:
        raise BuildError("AuraFace uv.lock direct requirements do not match pyproject.toml")
    for package in lock.get("package", []):
        if package.get("source", {}).get("registry") is None:
            continue
        artifacts = ([package["sdist"]] if "sdist" in package else []) + package.get("wheels", [])
        if not artifacts or any(
            not isinstance(artifact.get("hash"), str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["hash"]) is None
            for artifact in artifacts
        ):
            raise BuildError(f"AuraFace uv.lock has unhashed artifacts for {package.get('name')}")

    swift_path = root / "Aagedal Photo Agent/Services/FaceEmbedding/CoreMLFaceEmbedder.swift"
    swift = swift_path.read_text(encoding="utf-8")
    expected_swift = {
        r"\blet dimension\s*=\s*(\d+)": str(contract.output_length),
        r"\binputSize\s*=\s*(\d+)": str(contract.input_shape[-1]),
        r'\binputName\s*=\s*"([^"]+)"': contract.input_name,
        r'\boutputName\s*=\s*"([^"]+)"': contract.output_name,
        r"\bmean:\s*Float\s*=\s*([0-9.]+)": "127.5",
        r"\bstd:\s*Float\s*=\s*([0-9.]+)": "127.5",
        r"\binputIsRGB\s*=\s*(true|false)": "true" if contract.channel_order == "RGB" else "false",
    }
    for pattern, expected in expected_swift.items():
        match = re.search(pattern, swift)
        if match is None or match.group(1) != expected:
            raise BuildError(
                f"AuraFace Swift preprocessing does not match the manifest ({pattern!r} expected {expected!r})"
            )


def verify_runtime(contract: Contract) -> None:
    actual_python = platform.python_version()
    if actual_python != contract.python_version:
        raise BuildError(f"AuraFace conversion requires Python {contract.python_version}, got {actual_python}")
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise BuildError("AuraFace conversion requires arm64 macOS")
    if os.environ.get("PYTHONHASHSEED") != PYTHON_HASH_SEED:
        raise BuildError(
            f"AuraFace conversion requires PYTHONHASHSEED={PYTHON_HASH_SEED}; rerun as: "
            "PYTHONHASHSEED=0 uv run --frozen --project scripts/auraface python "
            "scripts/build_auraface_coreml.py reproduce"
        )
    for name, expected in sorted(contract.dependencies.items()):
        try:
            actual = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError as error:
            raise BuildError(f"AuraFace conversion dependency is missing: {name}=={expected}") from error
        if actual != expected:
            raise BuildError(f"AuraFace conversion requires {name}=={expected}, got {actual}")


def verify_source(source: Path, contract: Contract) -> None:
    if not source.is_file():
        raise BuildError(f"AuraFace source is missing: {source}")
    actual = sha256(source)
    if actual != contract.source_sha256:
        raise BuildError(f"AuraFace source SHA-256 mismatch: expected {contract.source_sha256}, got {actual}")


def canonical_package_manifest(package: Path) -> dict:
    manifest_path = package / "Manifest.json"
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = document.get("itemInfoEntries")
    if not isinstance(entries, dict):
        raise BuildError("Core ML package manifest has no itemInfoEntries")
    normalized: dict[str, dict] = {}
    root_identifier = None
    for entry in entries.values():
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise BuildError("Core ML package manifest contains an invalid item entry")
        identifier = str(uuid.uuid5(PACKAGE_NAMESPACE, entry["path"])).upper()
        normalized[identifier] = entry
        if entry["path"] == "com.apple.CoreML/model.mlmodel":
            root_identifier = identifier
    if root_identifier is None:
        raise BuildError("Core ML package manifest does not identify model.mlmodel")
    return {
        "fileFormatVersion": "1.0.0",
        "itemInfoEntries": normalized,
        "rootModelIdentifier": root_identifier,
    }


def normalize_package_manifest(package: Path) -> None:
    document = canonical_package_manifest(package)
    (package / "Manifest.json").write_text(
        json.dumps(document, indent=4, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def normalize_model_spec(package: Path) -> None:
    import coremltools as ct

    model_path = package / "Data/com.apple.CoreML/model.mlmodel"
    spec = ct.utils.load_spec(str(model_path))
    model_path.write_bytes(spec.SerializeToString(deterministic=True))


def package_hashes(package: Path) -> dict[str, str]:
    if not package.is_dir():
        raise BuildError(f"Core ML package is missing: {package}")
    actual_files = {
        str(path.relative_to(package))
        for path in package.rglob("*")
        if path.is_file()
    }
    if actual_files != set(PACKAGE_FILES):
        raise BuildError(
            "Core ML package file set mismatch; "
            f"missing={sorted(set(PACKAGE_FILES) - actual_files)}, "
            f"extra={sorted(actual_files - set(PACKAGE_FILES))}"
        )
    return {relative: sha256(package / relative) for relative in PACKAGE_FILES}


def verify_declared_package(package: Path, contract: Contract) -> None:
    actual = package_hashes(package)
    if actual != contract.artifact_files:
        differences = [
            f"{name}: expected {contract.artifact_files[name]}, got {actual[name]}"
            for name in PACKAGE_FILES
            if actual[name] != contract.artifact_files[name]
        ]
        raise BuildError("AuraFace package hash mismatch; " + "; ".join(differences))


def cosine_similarity(left: Sequence[float], right: Sequence[float]) -> float:
    if len(left) != len(right) or not left:
        raise BuildError("semantic outputs must have the same non-zero length")
    left_values = tuple(float(value) for value in left)
    right_values = tuple(float(value) for value in right)
    if not all(math.isfinite(value) for value in left_values + right_values):
        raise BuildError("semantic output contains non-finite values")
    dot = sum(a * b for a, b in zip(left_values, right_values))
    left_norm = math.sqrt(sum(value ** 2 for value in left_values))
    right_norm = math.sqrt(sum(value ** 2 for value in right_values))
    if left_norm == 0 or right_norm == 0:
        raise BuildError("semantic output has zero norm")
    return dot / (left_norm * right_norm)


def normalized_vector(values: Sequence[float], expected_length: int) -> tuple[float, ...]:
    if len(values) != expected_length:
        raise BuildError(f"AuraFace reference embedding must contain {expected_length} values")
    norm = math.sqrt(sum(float(value) ** 2 for value in values))
    if norm == 0 or not math.isfinite(norm):
        raise BuildError("AuraFace reference embedding has an invalid norm")
    result = tuple(float(value) / norm for value in values)
    if not all(math.isfinite(value) for value in result):
        raise BuildError("AuraFace reference embedding contains non-finite values")
    return result


def decode_ppm_fixture(path: Path) -> tuple[bytes, int, int, bytes]:
    try:
        encoded = b"".join(path.read_bytes().split())
        document = base64.b64decode(encoded, validate=True)
    except (OSError, ValueError) as error:
        raise BuildError(f"AuraFace channel fixture is not valid base64: {path}") from error
    match = re.match(rb"\AP6\n([1-9][0-9]*) ([1-9][0-9]*)\n255\n", document)
    if match is None:
        raise BuildError("AuraFace channel fixture must be a canonical RGB8 P6 PPM")
    width = int(match.group(1))
    height = int(match.group(2))
    pixels = document[match.end():]
    if (width, height) != (112, 112) or len(pixels) != width * height * 3:
        raise BuildError("AuraFace channel fixture must contain exactly one 112x112 RGB8 image")
    return document, width, height, pixels


def preprocess_rgb_pixels(pixels: bytes, width: int, height: int, channel_order: str) -> tuple[float, ...]:
    if channel_order not in {"RGB", "BGR"}:
        raise BuildError("AuraFace fixture channel order must be RGB or BGR")
    if len(pixels) != width * height * 3:
        raise BuildError("AuraFace fixture pixel count does not match its dimensions")
    indices = (0, 1, 2) if channel_order == "RGB" else (2, 1, 0)
    return tuple(
        (pixels[pixel_offset + channel] - 127.5) / 127.5
        for channel in indices
        for pixel_offset in range(0, len(pixels), 3)
    )


def validate_channel_outputs(
    torch_rgb: Sequence[float],
    coreml_rgb: Sequence[float],
    torch_bgr: Sequence[float],
    coreml_bgr: Sequence[float],
    contract: Contract,
    fixture_sha256: str,
    width: int,
    height: int,
) -> ChannelVerification:
    outputs = (torch_rgb, coreml_rgb, torch_bgr, coreml_bgr)
    if any(len(output) != contract.output_length for output in outputs):
        raise BuildError(f"AuraFace fixture output must contain {contract.output_length} values")
    torch_coreml_rgb = cosine_similarity(torch_rgb, coreml_rgb)
    torch_coreml_bgr = cosine_similarity(torch_bgr, coreml_bgr)
    if min(torch_coreml_rgb, torch_coreml_bgr) < contract.minimum_cosine:
        raise BuildError("AuraFace fixture Torch/Core ML similarity is below the build contract")
    torch_rgb_bgr = cosine_similarity(torch_rgb, torch_bgr)
    coreml_rgb_bgr = cosine_similarity(coreml_rgb, coreml_bgr)
    maximum_negative_similarity = 1.0 - MINIMUM_CHANNEL_COSINE_DISTANCE
    if max(torch_rgb_bgr, coreml_rgb_bgr) > maximum_negative_similarity:
        raise BuildError(
            "AuraFace RGB/BGR negative control is not materially different "
            f"(required cosine <= {maximum_negative_similarity:.9f})"
        )
    return ChannelVerification(
        fixture_sha256=fixture_sha256,
        width=width,
        height=height,
        torch_coreml_rgb_cosine=torch_coreml_rgb,
        torch_coreml_bgr_cosine=torch_coreml_bgr,
        torch_rgb_bgr_cosine=torch_rgb_bgr,
        coreml_rgb_bgr_cosine=coreml_rgb_bgr,
        normalized_torch_reference=normalized_vector(torch_rgb, contract.output_length),
        normalized_coreml_reference=normalized_vector(coreml_rgb, contract.output_length),
    )


def convert_once(source: Path, output: Path, contract: Contract) -> object:
    import coremltools as ct
    import numpy as np
    import torch
    from coremltools.models.utils import rename_feature
    from onnx2torch import convert

    torch.manual_seed(contract.seed)
    torch.use_deterministic_algorithms(True)
    model = convert(str(source)).eval()
    element_count = math.prod(contract.input_shape)
    example = torch.linspace(-1.0, 1.0, steps=element_count, dtype=torch.float32).reshape(contract.input_shape)
    traced = torch.jit.trace(model, example, check_trace=True)
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name=contract.input_name, shape=contract.input_shape, dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    spec = converted.get_spec()
    if len(spec.description.output) != 1:
        raise BuildError("AuraFace converter produced an unexpected output count")
    rename_feature(spec, spec.description.output[0].name, contract.output_name)
    metadata = spec.description.metadata
    metadata.shortDescription = contract.metadata["shortDescription"]
    metadata.versionString = contract.metadata["versionString"]
    metadata.author = contract.metadata["author"]
    metadata.license = contract.metadata["license"]
    metadata.userDefined.clear()
    for key, value in sorted(contract.metadata.items()):
        metadata.userDefined[f"com.aagedal.auraface.{key}"] = value
    ct.models.MLModel(spec, weights_dir=converted.weights_dir).save(str(output))
    normalize_model_spec(output)
    normalize_package_manifest(output)
    return model


def semantic_verify(torch_model: object, package: Path, contract: Contract) -> list[float]:
    import coremltools as ct
    import numpy as np
    import torch

    generator = torch.Generator().manual_seed(contract.seed)
    coreml_model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    similarities = []
    for _ in range(contract.semantic_samples):
        sample = torch.rand(contract.input_shape, generator=generator, dtype=torch.float32) * 2.0 - 1.0
        with torch.no_grad():
            torch_output = torch_model(sample).detach().cpu().numpy().reshape(-1)
        prediction = coreml_model.predict({contract.input_name: sample.numpy()})
        coreml_output = np.asarray(prediction[contract.output_name]).reshape(-1)
        if torch_output.size != contract.output_length or coreml_output.size != contract.output_length:
            raise BuildError(f"AuraFace semantic output must contain {contract.output_length} values")
        similarity = cosine_similarity(torch_output.tolist(), coreml_output.tolist())
        if similarity < contract.minimum_cosine:
            raise BuildError(
                f"AuraFace semantic similarity {similarity:.9f} is below "
                f"{contract.minimum_cosine:.9f}"
            )
        similarities.append(similarity)
    return similarities


def channel_verify(
    torch_model: object,
    package: Path,
    contract: Contract,
    fixture_path: Path,
) -> ChannelVerification:
    import coremltools as ct
    import numpy as np
    import torch

    if contract.channel_order != "RGB":
        raise BuildError("AuraFace provenance fixture currently proves only the declared RGB contract")
    document, width, height, pixels = decode_ppm_fixture(fixture_path)
    coreml_model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)

    def evaluate(channel_order: str) -> tuple[list[float], list[float]]:
        values = preprocess_rgb_pixels(pixels, width, height, channel_order)
        sample = np.asarray(values, dtype=np.float32).reshape(contract.input_shape)
        with torch.no_grad():
            torch_output = torch_model(torch.from_numpy(sample)).detach().cpu().numpy().reshape(-1)
        prediction = coreml_model.predict({contract.input_name: sample})
        coreml_output = np.asarray(prediction[contract.output_name]).reshape(-1)
        return torch_output.tolist(), coreml_output.tolist()

    torch_rgb, coreml_rgb = evaluate("RGB")
    torch_bgr, coreml_bgr = evaluate("BGR")
    return validate_channel_outputs(
        torch_rgb,
        coreml_rgb,
        torch_bgr,
        coreml_bgr,
        contract,
        hashlib.sha256(document).hexdigest(),
        width,
        height,
    )


def receipt_float(value: float) -> float:
    if not math.isfinite(value):
        raise BuildError("AuraFace build receipt cannot contain non-finite numbers")
    return round(float(value), RECEIPT_FLOAT_DIGITS)


def canonical_json_bytes(document: object) -> bytes:
    encoded = json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )
    return encoded.encode("utf-8")


def build_receipt(
    contract: Contract,
    artifact_hashes: dict[str, str],
    semantic_similarities: Sequence[float],
    channel: ChannelVerification,
) -> dict:
    def reference(values: Sequence[float]) -> dict:
        rounded = [receipt_float(value) for value in values]
        return {
            "encoding": f"canonical JSON float array rounded to {RECEIPT_FLOAT_DIGITS} decimal places",
            "sha256": hashlib.sha256(canonical_json_bytes(rounded)).hexdigest(),
            "values": rounded,
        }

    maximum_negative_similarity = 1.0 - MINIMUM_CHANNEL_COSINE_DISTANCE
    return {
        "schemaVersion": 1,
        "componentID": COMPONENT_ID,
        "source": {
            "repository": contract.source_url,
            "revision": contract.source_revision,
            "file": contract.source_file,
            "sha256": contract.source_sha256,
        },
        "model": {
            "componentVersion": contract.component_version,
            "embeddingVersion": contract.embedding_version,
            "metadata": dict(sorted(contract.metadata.items())),
        },
        "recipeFiles": {
            str(path): {"sha256": digest}
            for path, digest in sorted(contract.recipe_files.items(), key=lambda item: str(item[0]))
        },
        "runtimeContract": {
            "platform": {"operatingSystem": "macOS", "architecture": "arm64"},
            "pythonVersion": contract.python_version,
            "pythonHashSeed": PYTHON_HASH_SEED,
            "uvVersion": contract.uv_version,
            "dependencies": dict(sorted(contract.dependencies.items())),
        },
        "modelInterface": {
            "inputName": contract.input_name,
            "inputShape": list(contract.input_shape),
            "inputType": "float32",
            "layout": "NCHW",
            "channelOrder": contract.channel_order,
            "normalization": "(x - 127.5) / 127.5",
            "outputName": contract.output_name,
            "outputLength": contract.output_length,
        },
        "artifactFiles": {
            path: {"sha256": digest}
            for path, digest in sorted(artifact_hashes.items())
        },
        "declaredArtifactFiles": {
            path: {"sha256": digest}
            for path, digest in sorted(contract.artifact_files.items())
        },
        "matchesDeclaredArtifactFiles": artifact_hashes == contract.artifact_files,
        "determinism": {
            "seed": contract.seed,
            "cleanBuilds": contract.clean_builds,
            "packagesByteIdentical": True,
        },
        "semanticVerification": {
            "minimumCosineSimilarity": contract.minimum_cosine,
            "randomTensorCosineSimilarities": [receipt_float(value) for value in semantic_similarities],
        },
        "channelVerification": {
            "fixture": {
                "path": str(CHANNEL_FIXTURE),
                "encoding": "base64(P6 PPM RGB8)",
                "decodedSHA256": channel.fixture_sha256,
                "width": channel.width,
                "height": channel.height,
            },
            "intendedChannelOrder": "RGB",
            "normalization": "(x - 127.5) / 127.5",
            "torchCoreMLCosineSimilarity": receipt_float(channel.torch_coreml_rgb_cosine),
            "normalizedCoreMLReference": reference(channel.normalized_coreml_reference),
            "normalizedTorchReference": reference(channel.normalized_torch_reference),
            "bgrNegativeControl": {
                "channelOrder": "BGR",
                "maximumCosineSimilarityToRGB": receipt_float(maximum_negative_similarity),
                "torchCoreMLCosineSimilarity": receipt_float(channel.torch_coreml_bgr_cosine),
                "torchCosineSimilarityToRGB": receipt_float(channel.torch_rgb_bgr_cosine),
                "coreMLCosineSimilarityToRGB": receipt_float(channel.coreml_rgb_bgr_cosine),
            },
        },
    }


def verify_receipt_bytes(data: bytes, expected: dict) -> None:
    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BuildError("AuraFace build receipt is not valid UTF-8 JSON") from error
    canonical = canonical_json_bytes(document)
    if data != canonical:
        raise BuildError("AuraFace build receipt is not canonical JSON")
    if document != expected:
        raise BuildError("AuraFace build receipt does not match the verified build")


def remove_item(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def install_reproduction(
    package_source: Path,
    receipt_document: dict,
    package_destination: Path,
    receipt_destination: Path,
    replace: bool,
    replace_item: Callable[[Path, Path], None] = os.replace,
) -> None:
    for destination in (package_destination, receipt_destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() and not replace:
            raise BuildError(f"destination exists: {destination}; pass --replace after reviewing it")

    transaction_id = uuid.uuid4().hex
    package_staging = package_destination.parent / f".{package_destination.name}.new-{transaction_id}"
    receipt_staging = receipt_destination.parent / f".{receipt_destination.name}.new-{transaction_id}"
    package_backup = package_destination.parent / f".{package_destination.name}.old-{transaction_id}"
    receipt_backup = receipt_destination.parent / f".{receipt_destination.name}.old-{transaction_id}"
    committed = False
    package_installed = False
    receipt_installed = False
    try:
        shutil.copytree(package_source, package_staging)
        receipt_staging.write_bytes(canonical_json_bytes(receipt_document))
        verify_receipt_bytes(receipt_staging.read_bytes(), receipt_document)
        receipt_hashes = {
            path: declaration["sha256"]
            for path, declaration in receipt_document["artifactFiles"].items()
        }
        if package_hashes(package_staging) != receipt_hashes:
            raise BuildError("staged AuraFace package does not match its build receipt")

        if package_destination.exists():
            replace_item(package_destination, package_backup)
        if receipt_destination.exists():
            replace_item(receipt_destination, receipt_backup)
        replace_item(package_staging, package_destination)
        package_installed = True
        replace_item(receipt_staging, receipt_destination)
        receipt_installed = True
        verify_receipt_bytes(receipt_destination.read_bytes(), receipt_document)
        committed = True
    except BaseException as error:
        rollback_errors = []
        try:
            if receipt_installed:
                remove_item(receipt_destination)
            if receipt_backup.exists():
                replace_item(receipt_backup, receipt_destination)
        except BaseException as rollback_error:
            rollback_errors.append(rollback_error)
        try:
            if package_installed:
                remove_item(package_destination)
            if package_backup.exists():
                replace_item(package_backup, package_destination)
        except BaseException as rollback_error:
            rollback_errors.append(rollback_error)
        if rollback_errors:
            raise BuildError("AuraFace package/receipt install failed and rollback was incomplete") from error
        raise
    finally:
        remove_item(package_staging)
        remove_item(receipt_staging)
        if committed:
            remove_item(package_backup)
            remove_item(receipt_backup)


def reproduce(
    source: Path,
    output: Path,
    receipt_path: Path,
    fixture_path: Path,
    contract: Contract,
    replace: bool,
) -> tuple[dict[str, str], list[float], dict]:
    verify_runtime(contract)
    verify_source(source, contract)
    if receipt_path == output or output in receipt_path.parents:
        raise BuildError("AuraFace receipt must be a sibling of, rather than inside, the model package")
    if (output.exists() or receipt_path.exists()) and not replace:
        existing = output if output.exists() else receipt_path
        raise BuildError(f"destination exists: {existing}; pass --replace after reviewing it")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="auraface-builds-", dir=output.parent) as temporary:
        build_root = Path(temporary)
        packages = []
        torch_models = []
        for index in range(contract.clean_builds):
            package = build_root / f"clean-{index + 1}.mlpackage"
            torch_models.append(convert_once(source, package, contract))
            packages.append(package)
        first_hashes = package_hashes(packages[0])
        for index, package in enumerate(packages[1:], start=2):
            if package_hashes(package) != first_hashes:
                raise BuildError(f"AuraFace clean build {index} is not byte-identical to clean build 1")
        similarities = semantic_verify(torch_models[0], packages[0], contract)
        receipts = [
            build_receipt(
                contract,
                first_hashes,
                similarities,
                channel_verify(torch_model, package, contract, fixture_path),
            )
            for torch_model, package in zip(torch_models, packages)
        ]
        first_receipt_bytes = canonical_json_bytes(receipts[0])
        for index, receipt in enumerate(receipts[1:], start=2):
            if canonical_json_bytes(receipt) != first_receipt_bytes:
                raise BuildError(f"AuraFace clean build {index} provenance receipt differs from clean build 1")
        install_reproduction(packages[0], receipts[0], output, receipt_path, replace)
    return first_hashes, similarities, receipts[0]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    result.add_argument("--root", type=Path, default=Path.cwd())
    commands = result.add_subparsers(dest="operation", required=True)
    commands.add_parser("contract", help="verify recipe hashes and the locked environment declaration")
    verify = commands.add_parser("verify", help="verify the declared package, optionally including semantics")
    verify.add_argument("--package", type=Path)
    verify.add_argument("--source", type=Path)
    reproduce_command = commands.add_parser("reproduce", help="build twice, compare bytes, and verify semantics")
    reproduce_command.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    reproduce_command.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    reproduce_command.add_argument("--receipt", type=Path, default=DEFAULT_RECEIPT)
    reproduce_command.add_argument("--replace", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    root = arguments.root.resolve()
    manifest = arguments.manifest if arguments.manifest.is_absolute() else root / arguments.manifest
    try:
        contract = load_contract(manifest)
        verify_contract_files(root, contract)
        if arguments.operation == "contract":
            print(f"AuraFace build contract verified ({len(contract.recipe_files)} content-pinned files)")
        elif arguments.operation == "verify":
            package = arguments.package or root / contract.artifact_path
            verify_declared_package(package, contract)
            if arguments.source:
                verify_runtime(contract)
                source = arguments.source if arguments.source.is_absolute() else root / arguments.source
                verify_source(source, contract)
                with tempfile.TemporaryDirectory(prefix="auraface-reference-") as temporary:
                    torch_model = convert_once(source, Path(temporary) / "reference.mlpackage", contract)
                    similarities = semantic_verify(torch_model, package, contract)
                print("AuraFace semantic cosine similarities: " + ", ".join(f"{value:.9f}" for value in similarities))
            print(f"AuraFace declared package verified: {package}")
        else:
            source = arguments.source if arguments.source.is_absolute() else root / arguments.source
            output = arguments.output if arguments.output.is_absolute() else root / arguments.output
            receipt = arguments.receipt if arguments.receipt.is_absolute() else root / arguments.receipt
            fixture = root / CHANNEL_FIXTURE
            hashes, similarities, receipt_document = reproduce(
                source,
                output,
                receipt,
                fixture,
                contract,
                arguments.replace,
            )
            print(json.dumps({"artifactFiles": hashes}, indent=2, sort_keys=True))
            print("AuraFace semantic cosine similarities: " + ", ".join(f"{value:.9f}" for value in similarities))
            print(f"AuraFace reproducible package installed: {output}")
            print(f"AuraFace canonical build receipt installed: {receipt} ({hashlib.sha256(canonical_json_bytes(receipt_document)).hexdigest()})")
    except (BuildError, OSError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        print(f"AuraFace Core ML build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
