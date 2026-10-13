#!/usr/bin/env python3
"""Provision a relocatable python-build-standalone tree; never copy a venv or system Python."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("python_tree", type=Path, help="uv-managed python-build-standalone install root")
parser.add_argument("--destination", type=Path, default=Path("Vendor/web-download-runtime"))
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = args.python_tree.resolve()
lock = json.loads((root / "scripts/web_downloads/packages.lock.json").read_text())
if not (source / "bin/python3").is_file() or not (source / "lib").is_dir():
    raise SystemExit("Expected a standalone Python installation root")
version = subprocess.check_output([str(source / "bin/python3"), "-I", "-c", "import platform; print(platform.python_version())"], text=True).strip()
if version != lock["pythonVersion"]:
    raise SystemExit(f"Expected pinned Python {lock['pythonVersion']}, got {version}")
destination = args.destination.resolve()
if destination.exists():
    raise SystemExit("Destination exists; remove the generated runtime before preparing a replacement")
shutil.copytree(source, destination, symlinks=True)
python = destination / "bin/python3"
bridge = root / "Aagedal Photo Agent/Resources/WebDownloads/web_download_bridge.py"
with tempfile.TemporaryDirectory() as temporary:
    request = Path(temporary) / "request.json"
    def run(payload):
        request.write_text(json.dumps(payload))
        result = subprocess.run([str(python), "-I", str(bridge), str(request)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return json.loads(result.stdout)["result"]
    common = {"packages": str(destination / "packages")}
    versions = lock["versions"]
    run({**common, "action": "update", "destination": str(destination / "packages"), "versions": versions,
         "lockedArtifacts": lock["artifacts"]})
    assert run({**common, "action": "versions"}) == versions
    # Prove relocation, including SSL and native extension loading, before accepting it.
    relocated = Path(temporary) / "Relocated Runtime With Spaces"
    shutil.copytree(destination, relocated, symlinks=True)
    subprocess.run([str(relocated / "bin/python3"), "-I", "-c",
                    "import ssl, sqlite3, hashlib, zlib; print(ssl.OPENSSL_VERSION)"], check=True)
files = {}
for path in sorted(destination.rglob("*")):
    if path.is_symlink():
        try:
            path.resolve().relative_to(destination)
        except ValueError:
            raise RuntimeError(f"Runtime contains an external symlink: {path}")
    elif path.is_file() and "__pycache__" not in path.parts:
        files[str(path.relative_to(destination))] = hashlib.sha256(path.read_bytes()).hexdigest()
for path in destination.rglob("__pycache__"):
    shutil.rmtree(path)
(destination / "runtime.json").write_text(json.dumps({"python": subprocess.check_output(
    [str(python), "-I", "--version"], text=True).strip(), "packages": versions, "files": files}, indent=2))
print(f"Prepared {destination}: {versions}")
