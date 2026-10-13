#!/usr/bin/env python3
"""Verify, copy and sign the private Python runtime inside-out. Build performs no network access."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, destination = map(Path, sys.argv[1:])
if not source.is_dir():
    raise SystemExit("error: Missing Vendor/web-download-runtime in this checkout. Run python3 scripts/web_downloads/fetch_python.py, then python3 scripts/web_downloads/prepare_runtime.py build/web-download-python. See scripts/web_downloads/README.md.")
manifest = json.loads((source / "runtime.json").read_text())
actual_files = set()
for path in source.rglob("*"):
    # Finder metadata is not runtime content and must not invalidate a prepared tree.
    if path.name == ".DS_Store":
        continue
    if path.is_symlink():
        try:
            path.resolve(strict=True).relative_to(source.resolve())
        except (ValueError, OSError):
            raise RuntimeError(f"Unsafe downloader runtime symlink: {path}")
    elif path.is_file() and path != source / "runtime.json":
        actual_files.add(str(path.relative_to(source)))
if actual_files != set(manifest["files"]):
    raise RuntimeError("Downloader runtime file set differs from the preparation manifest")
for name, digest in manifest["files"].items():
    path = source / name
    if ".." in Path(name).parts or Path(name).is_absolute() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f"Downloader runtime artifact mismatch: {name}")
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns(".DS_Store"))
identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
    magics = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
    binaries = []
    for path in destination.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in magics:
                    binaries.append(path)
    for path in sorted(binaries, key=lambda path: (path.parent.name == "bin", str(path))):
        command = ["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", identity]
        if identity != "-":
            command.append("--timestamp")
        subprocess.run(command + [str(path)], check=True)
subprocess.run([str(destination / "bin/python3"), "-I", "-B", "-c", "import ssl, sqlite3, zlib"], check=True)
