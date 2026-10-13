#!/usr/bin/env python3
"""Fetch the exact reviewed Apple Silicon python-build-standalone archive."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

URL = "https://github.com/astral-sh/python-build-standalone/releases/download/20260602/cpython-3.13.13%2B20260602-aarch64-apple-darwin-install_only_stripped.tar.gz"
SHA256 = "b929647e1ebe243bd8b66c731e102b97dd7bdcc08127f03b7b22997ac4667403"

parser = argparse.ArgumentParser()
parser.add_argument("destination", type=Path, nargs="?", default=Path("build/web-download-python"))
args = parser.parse_args()
if args.destination.exists():
    raise SystemExit("Destination already exists; choose a new preparation directory")
with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory)
    archive = temporary / "python.tar.gz"
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2", "--output", str(archive), URL], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Standalone Python archive checksum mismatch")
    extracted = temporary / "extracted"
    extracted.mkdir()
    with tarfile.open(archive) as payload:
        for entry in payload.getmembers():
            path = Path(entry.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "python":
                raise RuntimeError("Unsafe Python archive path")
            if not (entry.isfile() or entry.isdir() or entry.issym() or entry.islnk()):
                raise RuntimeError("Unexpected Python archive entry")
            if entry.issym() or entry.islnk():
                parent = extracted / path.parent if entry.issym() else extracted
                target = (parent / entry.linkname).resolve()
                try:
                    target.relative_to((extracted / "python").resolve())
                except ValueError:
                    raise RuntimeError(f"Unsafe Python archive link: {entry.name}")
        # All names and links admitted above; archive bytes are pinned before extraction.
        payload.extractall(extracted)
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(extracted / "python", args.destination, symlinks=True)
print(args.destination)
