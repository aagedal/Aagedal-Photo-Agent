#!/usr/bin/env python3
"""Fetch or verify the manifest-pinned AuraFace ONNX source.

The network path deliberately delegates Hub resolution to the supported `hf` CLI.
The downloaded bytes are not installed until their SHA-256 matches the repository
manifest, and a failed fetch never replaces an existing destination.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


DEFAULT_MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
COMPONENT_ID = "auraface-r100-coreml"
HF_URL_PREFIX = "https://huggingface.co/"


class SourceError(ValueError):
    """The manifest or fetched source violates the pinned-source contract."""


@dataclass(frozen=True)
class SourcePin:
    repository: str
    revision: str
    filename: str
    sha256: str


Runner = Callable[[Sequence[str], Path], None]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_source_pin(manifest_path: Path) -> SourcePin:
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    components = document.get("components")
    if not isinstance(components, list):
        raise SourceError("manifest components must be an array")

    matches = [item for item in components if isinstance(item, dict) and item.get("id") == COMPONENT_ID]
    if len(matches) != 1:
        raise SourceError(f"manifest must contain exactly one {COMPONENT_ID!r} component")

    upstream = matches[0].get("upstream")
    if not isinstance(upstream, dict):
        raise SourceError("AuraFace upstream declaration must be an object")
    url = upstream.get("url")
    revision = upstream.get("revision")
    filename = upstream.get("sourceFile")
    expected_hash = upstream.get("sourceSHA256")

    if not isinstance(url, str) or not url.startswith(HF_URL_PREFIX):
        raise SourceError("AuraFace upstream URL must be a huggingface.co repository URL")
    repository = url.removeprefix(HF_URL_PREFIX).strip("/")
    if repository.count("/") != 1 or any(part in {"", ".", ".."} for part in repository.split("/")):
        raise SourceError("AuraFace Hugging Face repository identifier is invalid")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise SourceError("AuraFace revision must be a full 40-character lowercase commit hash")
    if (
        not isinstance(filename, str)
        or Path(filename).name != filename
        or filename in {"", ".", ".."}
    ):
        raise SourceError("AuraFace sourceFile must be one safe basename")
    if not isinstance(expected_hash, str) or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None:
        raise SourceError("AuraFace sourceSHA256 must be a lowercase SHA-256 digest")

    return SourcePin(repository, revision, filename, expected_hash)


def verify_source(path: Path, pin: SourcePin) -> None:
    if not path.is_file():
        raise SourceError(f"AuraFace source is missing: {path}")
    actual_hash = file_sha256(path)
    if actual_hash != pin.sha256:
        raise SourceError(
            f"AuraFace source SHA-256 mismatch: expected {pin.sha256}, got {actual_hash}"
        )


def default_runner(command: Sequence[str], download_directory: Path) -> None:
    environment = os.environ.copy()
    environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
    environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
    subprocess.run(
        command,
        check=True,
        cwd=download_directory,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def hf_download_command(pin: SourcePin, local_directory: Path, hf_command: str = "hf") -> list[str]:
    return [
        hf_command,
        "download",
        pin.repository,
        pin.filename,
        "--revision",
        pin.revision,
        "--local-dir",
        str(local_directory),
        "--format",
        "quiet",
    ]


def fetch_source(
    destination: Path,
    pin: SourcePin,
    *,
    replace: bool = False,
    hf_command: str = "hf",
    runner: Runner = default_runner,
) -> str:
    if destination.exists():
        try:
            verify_source(destination, pin)
            return "already verified"
        except SourceError:
            if not replace:
                raise SourceError(
                    f"destination exists but does not match the manifest: {destination}; "
                    "pass --replace only after reviewing the path"
                )

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="auraface-source-", dir=destination.parent) as temporary:
        download_directory = Path(temporary)
        runner(hf_download_command(pin, download_directory, hf_command), download_directory)
        downloaded = download_directory / pin.filename
        verify_source(downloaded, pin)
        # The temporary directory is deliberately created beside the destination,
        # so this install is one same-volume atomic replacement with no shared
        # staging filename for concurrent fetches to collide over.
        os.replace(downloaded, destination)
    return "downloaded and verified"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    subparsers = result.add_subparsers(dest="operation", required=True)

    verify = subparsers.add_parser("verify", help="verify an existing ONNX source without network access")
    verify.add_argument("source", type=Path)

    fetch = subparsers.add_parser("fetch", help="fetch the pinned ONNX source with the hf CLI")
    fetch.add_argument(
        "destination",
        type=Path,
        nargs="?",
        default=Path("build/model-sources/auraface/glintr100.onnx"),
    )
    fetch.add_argument("--replace", action="store_true")
    fetch.add_argument("--hf-command", default="hf")

    command = subparsers.add_parser("print-command", help="print the resolved pinned hf command")
    command.add_argument("--local-dir", type=Path, default=Path("build/model-sources/auraface"))
    command.add_argument("--hf-command", default="hf")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        pin = load_source_pin(arguments.manifest)
        if arguments.operation == "verify":
            verify_source(arguments.source, pin)
            print(f"AuraFace source verified: {arguments.source} ({pin.sha256})")
        elif arguments.operation == "fetch":
            status = fetch_source(
                arguments.destination,
                pin,
                replace=arguments.replace,
                hf_command=arguments.hf_command,
            )
            print(f"AuraFace source {status}: {arguments.destination} ({pin.sha256})")
        else:
            print(" ".join(hf_download_command(pin, arguments.local_dir, arguments.hf_command)))
    except (OSError, SourceError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"AuraFace source fetch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
