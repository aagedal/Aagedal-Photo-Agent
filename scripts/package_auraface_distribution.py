#!/usr/bin/env python3
"""Create or verify a deterministic AuraFace on-demand distribution archive.

This is release-engineering tooling. It packages the already-converted Core ML
artifact; it never downloads ONNX or performs model conversion on a user's Mac.
The generated descriptor binds the archive bytes, every package file, the model
version, and the persisted embedding-space version to one HTTPS download URL.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Sequence
from urllib.parse import urlparse


DEFAULT_MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
DEFAULT_PACKAGE = Path("Aagedal Photo Agent/Resources/Models/AuraFaceR100.mlpackage")
DEFAULT_ARCHIVE = Path("build/auraface/AuraFaceR100.mlpackage.zip")
DEFAULT_DESCRIPTOR = Path("build/auraface/AuraFaceR100.distribution.json")
COMPONENT_ID = "auraface-r100-coreml"
PACKAGE_DIRECTORY = "AuraFaceR100.mlpackage"
PACKAGE_FILES = (
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
    "Manifest.json",
)
FIXED_ZIP_TIMESTAMP = (2026, 1, 1, 0, 0, 0)


class DistributionError(ValueError):
    """The model, manifest, archive, or descriptor violates the release contract."""


@dataclass(frozen=True)
class DistributionContract:
    model_version: str
    embedding_version: int
    package_hashes: dict[str, str]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise DistributionError(f"{label} must be one lowercase SHA-256 digest")
    return value


def load_contract(manifest_path: Path, root: Path) -> DistributionContract:
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    components = document.get("components")
    if not isinstance(components, list):
        raise DistributionError("manifest components must be an array")
    matches = [item for item in components if isinstance(item, dict) and item.get("id") == COMPONENT_ID]
    if len(matches) != 1:
        raise DistributionError(f"manifest must contain exactly one {COMPONENT_ID!r} component")
    component = matches[0]
    model_version = component.get("version")
    build_contract = component.get("buildContract")
    package_hashes = component.get("artifactFiles")
    if not isinstance(model_version, str) or not model_version:
        raise DistributionError("AuraFace version must be a non-empty string")
    if not isinstance(build_contract, dict):
        raise DistributionError("AuraFace buildContract must be an object")
    embedding_version = build_contract.get("embeddingVersion")
    if not isinstance(embedding_version, int) or isinstance(embedding_version, bool) or embedding_version <= 0:
        raise DistributionError("AuraFace embeddingVersion must be a positive integer")
    if not isinstance(package_hashes, dict) or set(package_hashes) != set(PACKAGE_FILES):
        raise DistributionError("AuraFace artifactFiles must declare the exact Core ML package file set")
    for name, digest in package_hashes.items():
        require_digest(digest, f"artifactFiles[{name!r}]")

    swift_path = root / "Aagedal Photo Agent/Models/FaceRecognitionDefaults.swift"
    swift = swift_path.read_text(encoding="utf-8")
    match = re.search(r"\bembeddingVersion\s*=\s*(\d+)", swift)
    if match is None or int(match.group(1)) != embedding_version:
        raise DistributionError(
            "AuraFace manifest embeddingVersion does not match FaceRecognitionDefaults.embeddingVersion"
        )
    return DistributionContract(model_version, embedding_version, dict(package_hashes))


def validate_download_url(value: str) -> str:
    parsed = urlparse(value)
    hostname = (parsed.hostname or "").lower()
    if (
        parsed.scheme != "https"
        or hostname not in {"aagedal.me", "www.aagedal.me"}
        or parsed.username is not None
        or parsed.password is not None
        or not parsed.path
        or parsed.path.endswith("/")
        or parsed.query
        or parsed.fragment
    ):
        raise DistributionError(
            "download URL must be one credential-free HTTPS artifact URL on aagedal.me"
        )
    return value


def verify_package(package: Path, contract: DistributionContract) -> None:
    if not package.is_dir():
        raise DistributionError(f"Core ML package is missing: {package}")
    actual_files = {
        str(path.relative_to(package))
        for path in package.rglob("*")
        if path.is_file()
    }
    if actual_files != set(PACKAGE_FILES):
        raise DistributionError(
            "Core ML package file set mismatch; "
            f"missing={sorted(set(PACKAGE_FILES) - actual_files)}, "
            f"extra={sorted(actual_files - set(PACKAGE_FILES))}"
        )
    for relative, expected in contract.package_hashes.items():
        actual = sha256(package / relative)
        if actual != expected:
            raise DistributionError(
                f"Core ML package hash mismatch for {relative}: expected {expected}, got {actual}"
            )


def create_archive(package: Path, archive: Path) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as output:
        for relative in sorted(PACKAGE_FILES):
            info = zipfile.ZipInfo(f"{PACKAGE_DIRECTORY}/{relative}", FIXED_ZIP_TIMESTAMP)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o100644 << 16
            info.flag_bits = 0x800
            with (package / relative).open("rb") as source, output.open(info, "w", force_zip64=True) as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)


def descriptor_document(
    archive: Path,
    contract: DistributionContract,
    download_url: str,
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "componentID": COMPONENT_ID,
        "modelVersion": contract.model_version,
        "embeddingVersion": contract.embedding_version,
        "packageDirectory": PACKAGE_DIRECTORY,
        "packageFiles": contract.package_hashes,
        "archive": {
            "fileName": archive.name,
            "byteCount": archive.stat().st_size,
            "sha256": sha256(archive),
        },
        "downloadURL": validate_download_url(download_url),
    }


def write_descriptor(document: dict[str, object], path: Path) -> None:
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def verify_distribution(
    archive: Path,
    descriptor_path: Path,
    contract: DistributionContract,
) -> None:
    document = json.loads(descriptor_path.read_text(encoding="utf-8"))
    expected_keys = {
        "schemaVersion", "componentID", "modelVersion", "embeddingVersion",
        "packageDirectory", "packageFiles", "archive", "downloadURL",
    }
    if not isinstance(document, dict) or set(document) != expected_keys:
        raise DistributionError("distribution descriptor has an unexpected schema")
    if document.get("schemaVersion") != 1 or document.get("componentID") != COMPONENT_ID:
        raise DistributionError("distribution descriptor identity is invalid")
    if document.get("modelVersion") != contract.model_version:
        raise DistributionError("distribution modelVersion does not match the component manifest")
    if document.get("embeddingVersion") != contract.embedding_version:
        raise DistributionError("distribution embeddingVersion does not match the component manifest")
    if document.get("packageDirectory") != PACKAGE_DIRECTORY:
        raise DistributionError("distribution packageDirectory is invalid")
    if document.get("packageFiles") != contract.package_hashes:
        raise DistributionError("distribution packageFiles do not match the component manifest")
    validate_download_url(str(document.get("downloadURL", "")))

    archive_declaration = document.get("archive")
    if not isinstance(archive_declaration, dict) or set(archive_declaration) != {"fileName", "byteCount", "sha256"}:
        raise DistributionError("distribution archive declaration is invalid")
    if archive_declaration.get("fileName") != archive.name:
        raise DistributionError("distribution archive filename does not match")
    if archive_declaration.get("byteCount") != archive.stat().st_size:
        raise DistributionError("distribution archive size does not match")
    expected_archive_hash = require_digest(archive_declaration.get("sha256"), "archive sha256")
    if sha256(archive) != expected_archive_hash:
        raise DistributionError("distribution archive SHA-256 does not match")

    expected_names = {f"{PACKAGE_DIRECTORY}/{relative}" for relative in PACKAGE_FILES}
    with zipfile.ZipFile(archive, "r") as source:
        infos = source.infolist()
        names = {info.filename for info in infos}
        if len(infos) != len(names) or names != expected_names:
            raise DistributionError("distribution archive file set is invalid")
        for info in infos:
            path = PurePosixPath(info.filename)
            if path.is_absolute() or ".." in path.parts or info.is_dir():
                raise DistributionError("distribution archive contains an unsafe path")
            if info.compress_type != zipfile.ZIP_STORED:
                raise DistributionError("distribution archive must use deterministic stored entries")
            relative = str(path.relative_to(PACKAGE_DIRECTORY))
            actual = hashlib.sha256(source.read(info)).hexdigest()
            if actual != contract.package_hashes[relative]:
                raise DistributionError(f"distribution archive hash mismatch for {relative}")


def install_pair(staged_archive: Path, staged_descriptor: Path, archive: Path, descriptor: Path, replace: bool) -> None:
    destinations = ((staged_archive, archive), (staged_descriptor, descriptor))
    existing = [destination for _, destination in destinations if destination.exists()]
    if existing and not replace:
        raise DistributionError(
            f"destination exists: {existing[0]}; pass --replace after reviewing the generated candidate"
        )
    backups: list[tuple[Path, Path]] = []
    installed: list[Path] = []
    try:
        for staged, destination in destinations:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                backup = staged.parent / f"backup-{destination.name}"
                os.replace(destination, backup)
                backups.append((backup, destination))
            os.replace(staged, destination)
            installed.append(destination)
    except BaseException:
        for destination in reversed(installed):
            if destination.exists():
                destination.unlink()
        for backup, destination in reversed(backups):
            os.replace(backup, destination)
        raise
    for backup, _ in backups:
        backup.unlink()


def package_distribution(
    package: Path,
    archive: Path,
    descriptor: Path,
    contract: DistributionContract,
    download_url: str,
    replace: bool,
) -> None:
    verify_package(package, contract)
    validate_download_url(download_url)
    staging_parent = archive.parent
    staging_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="auraface-distribution-", dir=staging_parent) as temporary:
        temporary_path = Path(temporary)
        staged_archive = temporary_path / archive.name
        staged_descriptor = temporary_path / descriptor.name
        create_archive(package, staged_archive)
        write_descriptor(descriptor_document(staged_archive, contract, download_url), staged_descriptor)
        verify_distribution(staged_archive, staged_descriptor, contract)
        install_pair(staged_archive, staged_descriptor, archive, descriptor, replace)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    result.add_argument("--root", type=Path, default=Path.cwd())
    commands = result.add_subparsers(dest="operation", required=True)
    package = commands.add_parser("package", help="create and self-verify the hosted archive and descriptor")
    package.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    package.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    package.add_argument("--descriptor", type=Path, default=DEFAULT_DESCRIPTOR)
    package.add_argument("--download-url", required=True)
    package.add_argument("--replace", action="store_true")
    verify = commands.add_parser("verify", help="verify an existing hosted archive and descriptor offline")
    verify.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    verify.add_argument("--descriptor", type=Path, default=DEFAULT_DESCRIPTOR)
    return result


def resolve(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    root = arguments.root.resolve()
    manifest = resolve(root, arguments.manifest)
    try:
        contract = load_contract(manifest, root)
        archive = resolve(root, arguments.archive)
        descriptor = resolve(root, arguments.descriptor)
        if arguments.operation == "package":
            package_distribution(
                resolve(root, arguments.package), archive, descriptor, contract,
                arguments.download_url, arguments.replace,
            )
            print(f"AuraFace distribution package verified: {archive}")
            print(f"AuraFace distribution descriptor verified: {descriptor}")
        else:
            verify_distribution(archive, descriptor, contract)
            print(f"AuraFace distribution verified: {archive}")
    except (DistributionError, OSError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"AuraFace distribution failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
