#!/usr/bin/env python3
"""Build and verify AuraFace Core ML from the manifest-pinned ONNX source.

The lightweight ``contract`` and package-digest checks need only the standard
library. ``reproduce`` and semantic ``verify`` must run through the checked-in
uv lock so the conversion imports exactly the reviewed dependency graph.
"""

from __future__ import annotations

import argparse
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
from typing import Sequence


DEFAULT_MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
DEFAULT_SOURCE = Path("build/model-sources/auraface/glintr100.onnx")
DEFAULT_OUTPUT = Path("build/auraface/AuraFaceR100.mlpackage")
COMPONENT_ID = "auraface-r100-coreml"
PACKAGE_FILES = (
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
    "Manifest.json",
)
PACKAGE_NAMESPACE = uuid.UUID("de036ddf-a840-58e7-92c7-e42de6a05bbf")


class BuildError(ValueError):
    """The declared build contract or generated artifact is invalid."""


@dataclass(frozen=True)
class Contract:
    source_sha256: str
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
    if not isinstance(shape, list) or not shape or not all(isinstance(item, int) and item > 0 for item in shape):
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
    if not isinstance(interface.get("outputLength"), int) or interface["outputLength"] <= 0:
        raise BuildError("AuraFace outputLength must be a positive integer")

    clean_builds = determinism.get("cleanBuilds")
    seed = determinism.get("seed")
    samples = semantic.get("samples")
    minimum_cosine = semantic.get("minimumCosineSimilarity")
    if not isinstance(clean_builds, int) or clean_builds < 2:
        raise BuildError("AuraFace determinism requires at least two clean builds")
    if not isinstance(seed, int) or seed < 0:
        raise BuildError("AuraFace determinism seed must be a non-negative integer")
    if not isinstance(samples, int) or samples < 2:
        raise BuildError("AuraFace semantic verification requires at least two samples")
    if not isinstance(minimum_cosine, (int, float)) or not 0.99 <= minimum_cosine <= 1.0:
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

    python_version = build.get("pythonVersion")
    uv_version = build.get("uvVersion")
    if not isinstance(python_version, str) or re.fullmatch(r"3\.12\.\d+", python_version) is None:
        raise BuildError("AuraFace pythonVersion must pin one Python 3.12 patch release")
    if not isinstance(uv_version, str) or re.fullmatch(r"\d+\.\d+\.\d+", uv_version) is None:
        raise BuildError("AuraFace uvVersion must pin one exact release")

    return Contract(
        source_sha256=require_digest(upstream.get("sourceSHA256"), "AuraFace sourceSHA256"),
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
    dot = sum(float(a) * float(b) for a, b in zip(left, right))
    left_norm = math.sqrt(sum(float(value) ** 2 for value in left))
    right_norm = math.sqrt(sum(float(value) ** 2 for value in right))
    if left_norm == 0 or right_norm == 0:
        raise BuildError("semantic output has zero norm")
    return dot / (left_norm * right_norm)


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


def install_package(source: Path, destination: Path, replace: bool) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and not replace:
        raise BuildError(f"destination exists: {destination}; pass --replace after reviewing it")
    staging = destination.parent / f".{destination.name}.new-{uuid.uuid4().hex}"
    backup = destination.parent / f".{destination.name}.old-{uuid.uuid4().hex}"
    shutil.copytree(source, staging)
    moved_existing = False
    try:
        if destination.exists():
            os.replace(destination, backup)
            moved_existing = True
        os.replace(staging, destination)
    except BaseException:
        if moved_existing and not destination.exists():
            os.replace(backup, destination)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
        if backup.exists():
            shutil.rmtree(backup)


def reproduce(source: Path, output: Path, contract: Contract, replace: bool) -> tuple[dict[str, str], list[float]]:
    verify_runtime(contract)
    verify_source(source, contract)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="auraface-builds-", dir=output.parent) as temporary:
        build_root = Path(temporary)
        packages = []
        torch_model = None
        for index in range(contract.clean_builds):
            package = build_root / f"clean-{index + 1}.mlpackage"
            torch_model = convert_once(source, package, contract)
            packages.append(package)
        first_hashes = package_hashes(packages[0])
        for index, package in enumerate(packages[1:], start=2):
            if package_hashes(package) != first_hashes:
                raise BuildError(f"AuraFace clean build {index} is not byte-identical to clean build 1")
        assert torch_model is not None
        similarities = semantic_verify(torch_model, packages[0], contract)
        install_package(packages[0], output, replace)
    return first_hashes, similarities


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
            hashes, similarities = reproduce(source, output, contract, arguments.replace)
            print(json.dumps({"artifactFiles": hashes}, indent=2, sort_keys=True))
            print("AuraFace semantic cosine similarities: " + ", ".join(f"{value:.9f}" for value in similarities))
            print(f"AuraFace reproducible package installed: {output}")
    except (BuildError, OSError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        print(f"AuraFace Core ML build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
