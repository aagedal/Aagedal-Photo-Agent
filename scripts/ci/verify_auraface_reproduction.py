#!/usr/bin/env python3
"""Verify AuraFace reproduction across two independent locked processes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence


DEFAULT_SOURCE = Path("build/model-sources/auraface/glintr100.onnx")
DEFAULT_MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
PACKAGE_FILES = (
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
    "Manifest.json",
)
EVIDENCE_NAME = "verification-evidence.json"


class VerificationError(ValueError):
    """The repository or independent reproduction evidence is invalid."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


CommandRunner = Callable[[Sequence[str], Path, Mapping[str, str]], CommandResult]


@dataclass(frozen=True)
class VerificationConfig:
    root: Path
    source: Path
    manifest: Path
    evidence_directory: Path


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def files_equal(left: Path, right: Path) -> bool:
    if left.stat().st_size != right.stat().st_size:
        return False
    with left.open("rb") as left_handle, right.open("rb") as right_handle:
        while True:
            left_chunk = left_handle.read(1024 * 1024)
            right_chunk = right_handle.read(1024 * 1024)
            if left_chunk != right_chunk:
                return False
            if not left_chunk:
                return True


def canonical_json_bytes(document: object) -> bytes:
    return json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def default_runner(arguments: Sequence[str], cwd: Path, environment: Mapping[str, str]) -> CommandResult:
    completed = subprocess.run(
        list(arguments),
        cwd=cwd,
        env=dict(environment),
        check=False,
        capture_output=True,
        text=True,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def run_checked(
    arguments: Sequence[str],
    cwd: Path,
    environment: Mapping[str, str],
    runner: CommandRunner,
    label: str,
) -> CommandResult:
    result = runner(arguments, cwd, environment)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit status {result.returncode}"
        raise VerificationError(f"{label} failed: {detail}")
    return result


def require_clean_commit(root: Path, runner: CommandRunner, environment: Mapping[str, str]) -> str:
    status = run_checked(
        ("git", "status", "--porcelain=v1", "--untracked-files=no"),
        root,
        environment,
        runner,
        "Git status check",
    )
    if status.stdout.strip():
        raise VerificationError("tracked repository state is dirty; commit or restore it before reproduction")
    revision = run_checked(
        ("git", "rev-parse", "--verify", "HEAD"),
        root,
        environment,
        runner,
        "Git revision check",
    ).stdout.strip()
    if len(revision) != 40 or any(character not in "0123456789abcdef" for character in revision):
        raise VerificationError("Git HEAD is not one full lowercase commit identifier")
    return revision


def paths_overlap(left: Path, right: Path) -> bool:
    return left == right or left in right.parents or right in left.parents


def validate_paths(config: VerificationConfig) -> VerificationConfig:
    root = config.root.resolve()
    source = config.source.resolve()
    manifest = config.manifest.resolve()
    evidence = config.evidence_directory.resolve()
    if not root.is_dir():
        raise VerificationError(f"repository root is missing: {root}")
    if not source.is_file():
        raise VerificationError(f"pinned ONNX source is missing: {source}")
    if not manifest.is_file():
        raise VerificationError(f"component manifest is missing: {manifest}")
    if evidence.exists():
        raise VerificationError(f"evidence directory already exists and will not be replaced: {evidence}")
    if evidence == root or evidence in root.parents:
        raise VerificationError("evidence directory cannot be the repository root or its ancestor")
    git_directory = root / ".git"
    if evidence == git_directory or git_directory in evidence.parents:
        raise VerificationError("evidence directory cannot be inside repository Git metadata")
    if paths_overlap(source, evidence) or paths_overlap(manifest, evidence):
        raise VerificationError("reproduction source, manifest, and evidence outputs must not overlap")
    first = evidence / "process-1"
    second = evidence / "process-2"
    if paths_overlap(first, second):
        raise VerificationError("independent reproduction output directories overlap")
    return VerificationConfig(root, source, manifest, evidence)


def reproduction_command(config: VerificationConfig, process_directory: Path) -> tuple[str, ...]:
    return (
        "uv",
        "run",
        "--frozen",
        "--project",
        "scripts/auraface",
        "python",
        "scripts/build_auraface_coreml.py",
        "--root",
        str(config.root),
        "--manifest",
        str(config.manifest),
        "reproduce",
        "--source",
        str(config.source),
        "--output",
        str(process_directory / "AuraFaceR100.mlpackage"),
        "--receipt",
        str(process_directory / "AuraFaceR100.build-receipt.json"),
    )


def read_receipt(path: Path) -> tuple[dict, bytes]:
    if path.is_symlink():
        raise VerificationError(f"reproduction receipt cannot be a symbolic link: {path}")
    try:
        data = path.read_bytes()
        document = json.loads(data)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid reproduction receipt: {path}") from error
    try:
        canonical = canonical_json_bytes(document)
    except (TypeError, ValueError) as error:
        raise VerificationError(f"reproduction receipt contains non-canonical values: {path}") from error
    if data != canonical:
        raise VerificationError(f"reproduction receipt is not compact canonical JSON: {path}")
    if document.get("matchesDeclaredArtifactFiles") is not True:
        raise VerificationError(f"reproduction does not match declared artifact files: {path}")
    artifact_files = document.get("artifactFiles")
    if not isinstance(artifact_files, dict) or set(artifact_files) != set(PACKAGE_FILES):
        raise VerificationError(f"receipt has an unexpected package file set: {path}")
    if document.get("declaredArtifactFiles") != artifact_files:
        raise VerificationError(f"receipt generated and declared artifact maps differ: {path}")
    return document, data


def verify_package(package: Path, receipt: dict) -> dict[str, dict[str, object]]:
    if package.is_symlink() or not package.is_dir():
        raise VerificationError(f"reproduced package is missing: {package}")
    entries = list(package.rglob("*"))
    if any(path.is_symlink() for path in entries):
        raise VerificationError(f"reproduced package cannot contain symbolic links: {package}")
    actual_files = {
        str(path.relative_to(package))
        for path in entries
        if path.is_file()
    }
    if actual_files != set(PACKAGE_FILES):
        raise VerificationError(f"reproduced package has an unexpected file set: {package}")
    evidence: dict[str, dict[str, object]] = {}
    for relative in PACKAGE_FILES:
        path = package / relative
        expected = receipt["artifactFiles"][relative]
        if not isinstance(expected, dict) or set(expected) != {"sha256"}:
            raise VerificationError(f"receipt artifact declaration is invalid: {relative}")
        actual_hash = sha256(path)
        if expected["sha256"] != actual_hash:
            raise VerificationError(f"receipt hash does not match reproduced package file: {relative}")
        evidence[relative] = {"byteCount": path.stat().st_size, "sha256": actual_hash}
    return evidence


def write_exclusive(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise


def verify(config: VerificationConfig, runner: CommandRunner = default_runner) -> dict:
    config = validate_paths(config)
    environment = dict(os.environ)
    environment["PYTHONHASHSEED"] = "0"
    repository_revision = require_clean_commit(config.root, runner, environment)
    source_hash = sha256(config.source)
    manifest_hash = sha256(config.manifest)
    config.evidence_directory.mkdir(parents=True, exist_ok=False)

    commands: list[tuple[str, ...]] = []
    receipts: list[dict] = []
    receipt_bytes: list[bytes] = []
    package_evidence: list[dict[str, dict[str, object]]] = []
    packages: list[Path] = []
    for index in (1, 2):
        process_directory = config.evidence_directory / f"process-{index}"
        process_directory.mkdir()
        command = reproduction_command(config, process_directory)
        commands.append(command)
        run_checked(command, config.root, environment, runner, f"AuraFace reproduction process {index}")
        package = process_directory / "AuraFaceR100.mlpackage"
        receipt_path = process_directory / "AuraFaceR100.build-receipt.json"
        receipt, raw_receipt = read_receipt(receipt_path)
        receipts.append(receipt)
        receipt_bytes.append(raw_receipt)
        package_evidence.append(verify_package(package, receipt))
        packages.append(package)

    for relative in PACKAGE_FILES:
        if not files_equal(packages[0] / relative, packages[1] / relative):
            raise VerificationError(f"independent reproductions differ byte-for-byte: {relative}")
    if receipt_bytes[0] != receipt_bytes[1]:
        raise VerificationError("independent canonical build receipts differ byte-for-byte")
    if package_evidence[0] != package_evidence[1]:
        raise VerificationError("independent package hash evidence differs")
    ending_revision = require_clean_commit(config.root, runner, environment)
    if ending_revision != repository_revision:
        raise VerificationError("Git HEAD changed during independent reproduction")
    if sha256(config.source) != source_hash or sha256(config.manifest) != manifest_hash:
        raise VerificationError("source or manifest bytes changed during independent reproduction")

    first_receipt = receipts[0]
    receipt_source = first_receipt.get("source")
    if not isinstance(receipt_source, dict) or receipt_source.get("sha256") != source_hash:
        raise VerificationError("receipt source hash does not match the reproduced ONNX source")
    source_revision = receipt_source.get("revision")
    if not isinstance(source_revision, str) or len(source_revision) != 40:
        raise VerificationError("receipt does not bind one full upstream source revision")
    runtime_contract = first_receipt.get("runtimeContract")
    if not isinstance(runtime_contract, dict) or runtime_contract.get("pythonHashSeed") != "0":
        raise VerificationError("receipt runtime contract does not bind the fixed Python hash seed")
    evidence = {
        "schemaVersion": 1,
        "status": "verified",
        "repositoryRevision": repository_revision,
        "commands": [
            {"environment": {"PYTHONHASHSEED": "0"}, "arguments": list(command)}
            for command in commands
        ],
        "runtimeContract": runtime_contract,
        "source": receipt_source,
        "manifest": {"sha256": manifest_hash},
        "packageFiles": package_evidence[0],
        "receipt": {
            "byteCount": len(receipt_bytes[0]),
            "sha256": sha256_bytes(receipt_bytes[0]),
        },
        "matchesDeclaredArtifactFiles": True,
        "independentProcessCount": 2,
    }
    write_exclusive(config.evidence_directory / EVIDENCE_NAME, canonical_json_bytes(evidence))
    return evidence


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, default=Path.cwd())
    result.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    result.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    result.add_argument("--evidence-directory", type=Path, required=True)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    root = arguments.root.resolve()
    source = arguments.source if arguments.source.is_absolute() else root / arguments.source
    manifest = arguments.manifest if arguments.manifest.is_absolute() else root / arguments.manifest
    evidence = (
        arguments.evidence_directory
        if arguments.evidence_directory.is_absolute()
        else root / arguments.evidence_directory
    )
    try:
        document = verify(VerificationConfig(root, source, manifest, evidence))
    except (VerificationError, OSError) as error:
        print(canonical_json_bytes({"status": "failed", "error": str(error)}).decode("utf-8"), file=sys.stderr)
        return 1
    print(canonical_json_bytes(document).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
