#!/usr/bin/env python3
"""Create or verify a deterministic AuraFace on-demand distribution archive.

This is release-engineering tooling. It packages the already-converted Core ML
artifact; it never downloads ONNX or performs model conversion on a user's Mac.
The generated descriptor binds the archive bytes, every package file, the model
version, and the persisted embedding-space version to one HTTPS download URL.
Outputs are unsigned schema-2 candidates. Production signing with a dedicated
model key and migration of the schema-1 Photo Agent consumer remain separate gates.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import struct
import tempfile
import zipfile
import zlib
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
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
ARCHIVE_FILENAME = "AuraFaceR100.mlpackage.zip"
ALLOWED_ORIGINS = {"aagedal.me", "www.aagedal.me"}
MAX_DESCRIPTOR_BYTES = 16_384
MAX_ARCHIVE_BYTES = 256 * 1_048_576
MAX_PACKAGE_FILE_BYTES = 192 * 1_048_576
ZIP_DATE = ((FIXED_ZIP_TIMESTAMP[0] - 1980) << 9) | (1 << 5) | 1
LOCAL = struct.Struct("<IHHHHHIIIHH")
CENTRAL = struct.Struct("<IHHHHHHIIIHHHHHII")
END = struct.Struct("<IHHHHIIH")


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


def canonical_bytes(document: object) -> bytes:
    return json.dumps(document, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def strict_json(data: bytes) -> object:
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise DistributionError("JSON contains a duplicate key")
            result[key] = value
        return result

    def invalid_constant(_):
        raise DistributionError("JSON contains a non-finite number")

    return json.loads(data, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def positive_size(value: object, maximum: int, label: str) -> int:
    if type(value) is not int or not 0 < value <= maximum:
        raise DistributionError(f"{label} must be a positive integer at most {maximum}")
    return value


@contextmanager
def regular_file(path: Path, maximum: int):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        before = os.fstat(handle.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise DistributionError("artifact must be one regular, unlinked file")
        positive_size(before.st_size, maximum, "artifact byte count")
        yield handle, before.st_size
        after = os.fstat(handle.fileno())
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_nlink")
        if any(getattr(before, field) != getattr(after, field) for field in fields):
            raise DistributionError("artifact changed while being read")


def require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise DistributionError(f"{label} must be one lowercase SHA-256 digest")
    return value


def load_contract(manifest_path: Path, root: Path) -> DistributionContract:
    document = strict_json(manifest_path.read_bytes())
    if not isinstance(document, dict):
        raise DistributionError("manifest must be an object")
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
    if not isinstance(model_version, str) or not model_version or len(model_version.encode("utf-8")) > 128:
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
    if not isinstance(value, str) or any(ord(char) <= 32 or ord(char) == 127 for char in value):
        raise DistributionError("download URL must be one credential-free HTTPS artifact URL on aagedal.me")
    try:
        parsed = urlparse(value)
    except ValueError as error:
        raise DistributionError("download URL must be one credential-free HTTPS artifact URL on aagedal.me") from error
    if (
        not value.startswith("https://")
        or parsed.scheme != "https"
        or parsed.netloc not in ALLOWED_ORIGINS
        or parsed.username is not None
        or parsed.password is not None
        or not parsed.path
        or parsed.path.endswith("/")
        or parsed.query
        or parsed.fragment
        or parsed.params
        or "\\" in value
        or "?" in value or "#" in value
        or re.fullmatch(r"(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})+", parsed.path) is None
    ):
        raise DistributionError(
            "download URL must be one credential-free HTTPS artifact URL on aagedal.me"
        )
    return value


def verify_package(package: Path, contract: DistributionContract) -> None:
    if package.is_symlink() or not package.is_dir():
        raise DistributionError(f"Core ML package is missing: {package}")
    if any(path.is_symlink() for path in package.rglob("*")):
        raise DistributionError("Core ML package contains a linked entry")
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
    total = 0
    for relative, expected in contract.package_hashes.items():
        digest = hashlib.sha256()
        with regular_file(package / relative, MAX_PACKAGE_FILE_BYTES) as (source, size):
            total += size
            if total > MAX_ARCHIVE_BYTES:
                raise DistributionError("Core ML package exceeds the archive size limit")
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != expected:
            raise DistributionError(
                f"Core ML package hash mismatch for {relative}: expected {expected}, got {actual}"
            )


def create_archive(package: Path, archive: Path) -> None:
    if archive.name != ARCHIVE_FILENAME:
        raise DistributionError(f"archive filename must be {ARCHIVE_FILENAME}")
    archive.parent.mkdir(parents=True, exist_ok=True)
    # Write ZIP32 explicitly: zipfile resets flags for ASCII names and force_zip64
    # introduces extra fields. The companion requires UTF-8 flags on BOTH headers.
    central_entries = []
    with archive.open("wb") as output:
        for relative in sorted(PACKAGE_FILES):
            name = f"{PACKAGE_DIRECTORY}/{relative}".encode("utf-8")
            with regular_file(package / relative, MAX_PACKAGE_FILE_BYTES) as (source, size):
                crc = 0
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    crc = zlib.crc32(chunk, crc)
                offset = output.tell()
                if offset + LOCAL.size + len(name) + size > MAX_ARCHIVE_BYTES:
                    raise DistributionError("archive exceeds the ZIP32 distribution size limit")
                output.write(LOCAL.pack(0x04034B50, 20, 0x800, 0, 0, ZIP_DATE, crc, size, size, len(name), 0))
                output.write(name)
                source.seek(0)
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    output.write(chunk)
                central_entries.append(CENTRAL.pack(0x02014B50, 0x314, 20, 0x800, 0, 0, ZIP_DATE,
                    crc, size, size, len(name), 0, 0, 0, 0, 0o100644 << 16, offset) + name)
        central_offset = output.tell()
        central = b"".join(central_entries)
        output.write(central)
        output.write(END.pack(0x06054B50, 0, 0, 3, 3, len(central), central_offset, 0))
        if output.tell() > MAX_ARCHIVE_BYTES:
            raise DistributionError("archive exceeds the ZIP32 distribution size limit")


def descriptor_document(
    archive: Path,
    contract: DistributionContract,
    download_url: str,
) -> dict[str, object]:
    with zipfile.ZipFile(archive) as source:
        sizes = {str(info.filename.removeprefix(PACKAGE_DIRECTORY + "/")): info.file_size for info in source.infolist()}
    return {
        "schemaVersion": 2,
        "componentID": COMPONENT_ID,
        "modelVersion": contract.model_version,
        "embeddingVersion": contract.embedding_version,
        "packageDirectory": PACKAGE_DIRECTORY,
        "packageFiles": {path: {"byteCount": sizes[path], "sha256": digest} for path, digest in contract.package_hashes.items()},
        "archive": {
            "fileName": archive.name,
            "byteCount": archive.stat().st_size,
            "sha256": sha256(archive),
        },
        "downloadURL": validate_download_url(download_url),
    }


def write_descriptor(document: dict[str, object], path: Path) -> None:
    data = canonical_bytes(document)
    if len(data) > MAX_DESCRIPTOR_BYTES:
        raise DistributionError("descriptor exceeds size limit")
    path.write_bytes(data)


def read_exact(source, count: int) -> bytes:
    data = source.read(count)
    if len(data) != count:
        raise DistributionError("distribution archive is truncated")
    return data


def verify_zip32(source, archive_size: int, declarations: dict[str, dict[str, object]]) -> None:
    """Inspect local and central records independently of Python's permissive ZIP reader."""
    if archive_size < END.size:
        raise DistributionError("distribution archive is truncated")
    source.seek(archive_size - END.size)
    end = END.unpack(read_exact(source, END.size))
    signature, disk, central_disk, disk_count, count, central_size, central_offset, comment = end
    if (signature, disk, central_disk, disk_count, count, comment) != (0x06054B50, 0, 0, 3, 3, 0):
        raise DistributionError("distribution archive must be a comment-free single-disk ZIP32")
    if central_size > 16_384 or central_offset + central_size != archive_size - END.size:
        raise DistributionError("distribution archive central directory is invalid")
    source.seek(central_offset)
    entries = []
    for relative in sorted(PACKAGE_FILES):
        raw = read_exact(source, CENTRAL.size)
        fields = CENTRAL.unpack(raw)
        (signature, made, needed, flags, method, time, date, crc, compressed, size,
         name_length, extra, comment, disk, internal, external, offset) = fields
        name = f"{PACKAGE_DIRECTORY}/{relative}".encode("utf-8")
        declared_size = declarations[relative]["byteCount"]
        if ((signature, made, needed, flags, method, time, date) !=
                (0x02014B50, 0x314, 20, 0x800, 0, 0, ZIP_DATE)
                or (compressed, size, name_length, extra, comment, disk, internal, external) !=
                (declared_size, declared_size, len(name), 0, 0, 0, 0, 0o100644 << 16)
                or read_exact(source, len(name)) != name):
            raise DistributionError("distribution archive has incompatible central ZIP32 headers")
        entries.append((relative, name, crc, size, offset))
    if source.tell() != central_offset + central_size:
        raise DistributionError("distribution archive has extra central records")
    next_offset = 0
    for relative, name, crc, size, offset in entries:
        if offset != next_offset or offset + LOCAL.size + len(name) + size > central_offset:
            raise DistributionError("distribution archive has gaps or overlapping records")
        source.seek(offset)
        expected = LOCAL.pack(0x04034B50, 20, 0x800, 0, 0, ZIP_DATE, crc, size, size, len(name), 0)
        if read_exact(source, LOCAL.size) != expected or read_exact(source, len(name)) != name:
            raise DistributionError("distribution archive has incompatible local ZIP32 headers")
        digest = hashlib.sha256()
        actual_crc = 0
        remaining = size
        while remaining:
            chunk = read_exact(source, min(1024 * 1024, remaining))
            remaining -= len(chunk)
            digest.update(chunk)
            actual_crc = zlib.crc32(chunk, actual_crc)
        if actual_crc != crc or digest.hexdigest() != declarations[relative]["sha256"]:
            raise DistributionError(f"distribution archive hash or CRC mismatch for {relative}")
        next_offset = source.tell()
    if next_offset != central_offset:
        raise DistributionError("distribution archive has undeclared bytes before central directory")


def verify_distribution(
    archive: Path,
    descriptor_path: Path,
    contract: DistributionContract,
) -> None:
    with regular_file(descriptor_path, MAX_DESCRIPTOR_BYTES) as (source, size):
        descriptor_bytes = read_exact(source, size)
    document = strict_json(descriptor_bytes)
    if canonical_bytes(document) != descriptor_bytes:
        raise DistributionError("distribution descriptor must use exact canonical JSON bytes")
    expected_keys = {
        "schemaVersion", "componentID", "modelVersion", "embeddingVersion",
        "packageDirectory", "packageFiles", "archive", "downloadURL",
    }
    if not isinstance(document, dict) or set(document) != expected_keys:
        raise DistributionError("distribution descriptor has an unexpected schema")
    if type(document["schemaVersion"]) is not int or document["schemaVersion"] != 2 or document["componentID"] != COMPONENT_ID:
        raise DistributionError("distribution descriptor identity is invalid")
    if document["modelVersion"] != contract.model_version:
        raise DistributionError("distribution modelVersion does not match the component manifest")
    positive_size(document["embeddingVersion"], 2**63 - 1, "embeddingVersion")
    if document["embeddingVersion"] != contract.embedding_version:
        raise DistributionError("distribution embeddingVersion does not match the component manifest")
    if document["packageDirectory"] != PACKAGE_DIRECTORY:
        raise DistributionError("distribution packageDirectory is invalid")
    files = document["packageFiles"]
    if not isinstance(files, dict) or set(files) != set(PACKAGE_FILES):
        raise DistributionError("distribution packageFiles do not match the component manifest")
    total = 0
    for relative, expected_hash in contract.package_hashes.items():
        declaration = files[relative]
        if not isinstance(declaration, dict) or set(declaration) != {"byteCount", "sha256"}:
            raise DistributionError("distribution package file declaration is invalid")
        total += positive_size(declaration["byteCount"], MAX_PACKAGE_FILE_BYTES, "package file byteCount")
        if require_digest(declaration["sha256"], "package file sha256") != expected_hash:
            raise DistributionError("distribution packageFiles do not match the component manifest")
    if total > MAX_ARCHIVE_BYTES:
        raise DistributionError("distribution package exceeds the size limit")
    validate_download_url(document["downloadURL"])
    declaration = document["archive"]
    if not isinstance(declaration, dict) or set(declaration) != {"fileName", "byteCount", "sha256"}:
        raise DistributionError("distribution archive declaration is invalid")
    if declaration["fileName"] != ARCHIVE_FILENAME or archive.name != ARCHIVE_FILENAME:
        raise DistributionError("distribution archive filename does not match")
    expected_size = positive_size(declaration["byteCount"], MAX_ARCHIVE_BYTES, "archive byteCount")
    expected_hash = require_digest(declaration["sha256"], "archive sha256")
    with regular_file(archive, MAX_ARCHIVE_BYTES) as (source, actual_size):
        if actual_size != expected_size:
            raise DistributionError("distribution archive size does not match")
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        if digest.hexdigest() != expected_hash:
            raise DistributionError("distribution archive SHA-256 does not match")
        verify_zip32(source, actual_size, files)


def install_pair(staged_archive: Path, staged_descriptor: Path, archive: Path, descriptor: Path, replace: bool) -> None:
    destinations = ((staged_archive, archive), (staged_descriptor, descriptor))
    existing = [destination for _, destination in destinations if destination.exists() or destination.is_symlink()]
    if existing and not replace:
        raise DistributionError(
            f"destination exists: {existing[0]}; pass --replace after reviewing the generated candidate"
        )
    backups: list[tuple[Path, Path]] = []
    installed: list[Path] = []
    # Isolate backups from every caller-chosen candidate basename.
    backup_directory = Path(tempfile.mkdtemp(prefix="prior-outputs-", dir=staged_archive.parent))
    try:
        for index, (staged, destination) in enumerate(destinations):
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists() or destination.is_symlink():
                if not replace:
                    raise DistributionError("destination arrived before install; existing output was preserved")
                backup = backup_directory / str(index)
                os.replace(destination, backup)
                backups.append((backup, destination))
            # Destination must still be vacant after any explicit backup. A late
            # arrival must not be overwritten, including when --replace is absent.
            os.link(staged, destination, follow_symlinks=False)
            installed.append(destination)
            staged.unlink()
    except BaseException:
        for destination in reversed(installed):
            if destination.exists():
                destination.unlink()
        for backup, destination in reversed(backups):
            os.replace(backup, destination)
        backup_directory.rmdir()
        raise
    for backup, _ in backups:
        backup.unlink()
    backup_directory.rmdir()


def validate_output_paths(package: Path, archive: Path, descriptor: Path) -> None:
    if archive.name != ARCHIVE_FILENAME:
        raise DistributionError(f"archive filename must be {ARCHIVE_FILENAME}")
    if archive.name == descriptor.name or archive.resolve() == descriptor.resolve():
        raise DistributionError("archive and descriptor must use distinct candidate filenames")
    for destination in (archive, descriptor):
        if destination.is_symlink():
            raise DistributionError("distribution output must not be a symbolic link")
        # Inode comparisons cover existing case/symlink aliases of the package,
        # including a new output nested under an existing package directory.
        for ancestor in (destination, *destination.parents):
            if ancestor.exists() and os.path.samefile(ancestor, package):
                raise DistributionError("distribution output must not overlap the source Core ML package")
    if archive.exists() and descriptor.exists() and os.path.samefile(archive, descriptor):
        raise DistributionError("archive and descriptor must not alias the same file")


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
    validate_output_paths(package, archive, descriptor)
    staging_parent = archive.parent
    staging_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="auraface-distribution-", dir=staging_parent) as temporary:
        temporary_path = Path(temporary)
        staged_archive = temporary_path / archive.name
        staged_descriptor = temporary_path / descriptor.name
        create_archive(package, staged_archive)
        write_descriptor(descriptor_document(staged_archive, contract, download_url), staged_descriptor)
        verify_distribution(staged_archive, staged_descriptor, contract)
        validate_output_paths(package, archive, descriptor)
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
            print(f"AuraFace unsigned schema-2 archive verified: {archive}")
            print(f"AuraFace unsigned schema-2 descriptor verified: {descriptor}")
        else:
            verify_distribution(archive, descriptor, contract)
            print(f"AuraFace unsigned schema-2 distribution integrity verified: {archive}")
        print("Publication requires dedicated model signing and schema-2 consumer support; neither is performed here.")
    except (DistributionError, OSError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"AuraFace distribution failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
