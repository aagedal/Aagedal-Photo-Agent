#!/usr/bin/env python3
"""Assemble the GPL corresponding-source companion for the bundled FFmpeg 9.0.2 build.

The bundled `Aagedal Photo Agent/Resources/ffmpeg` is the "photo-agent" variant of the
ffmpeg-apple-silicon build (docs/provenance/ffmpeg-photo-agent-9.0.2.md). Its recipe and
Photo Agent's source patches are retained in this repository; the upstream archives and git
checkouts live in the build workspaces. This script reads both (never writing to them) and
produces one directory plus a single .tar archive with a SHA-256 manifest, ready to publish
next to the release DMG.

The recipe downloads and builds in one step (several components only compile inside their
"not yet downloaded" branch), so the companion does not pre-extract anything. It ships
`offline/curl` and `offline/git` stand-ins that serve each requested file from `upstream/`;
with them first on PATH, `build.sh` runs exactly as it did originally, without a network.

Usage:
    python3 scripts/ffmpeg/make_source_companion.py \
        --sources ~/.t3/worktrees/ffmpeg-apple-silicon/t3-118d2ca2/sources \
        --sources ~/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/sources

Output defaults to build/ffmpeg-source-companion/ (git-ignored). An existing output
directory is refused so a published companion is never silently rewritten.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ROOT / "docs/provenance/ffmpeg-photo-agent-9.0.2-build"
PROVENANCE = [
    ROOT / "docs/provenance/ffmpeg-photo-agent-9.0.2.md",
    ROOT / "docs/provenance/ffmpeg-photo-agent-9.0.2.json",
    ROOT / "docs/provenance/ffmpeg-photo-agent-9.0.2-README.md",
    ROOT / "docs/provenance/ffmpeg-photo-agent-9.0.2-notices.json",
]
NOTICES = [
    ROOT / "Aagedal Photo Agent/Resources/Licenses/License-GPL-3.0.txt",
    ROOT / "Aagedal Photo Agent/Resources/Licenses/License-FFmpeg-Dependencies.txt",
]
ARCHIVE_SUFFIXES = (".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".zip")
# Sources fetched with `git clone` by the recipe (02-x264.sh, 03-x265.sh), not as archives.
GIT_CHECKOUTS = ["x264", "x265-4.2"]
# libjxl's deps.sh downloads pinned GitHub tarballs (third_party sources and testdata),
# cached by commit hash in this directory.
LIBJXL_DOWNLOADS = "libjxl-0.12.0/downloads"
# The single binary this companion corresponds to.
BINARY = ROOT / "Aagedal Photo Agent/Resources/ffmpeg"

OFFLINE_CURL = r"""#!/bin/bash
# Offline stand-in for curl used while rebuilding from this companion. It serves the file a
# recipe asks for from ../upstream (matched by output name, URL name, or a GitHub tarball
# commit hash) and never touches the network. Unknown requests fail loudly.
set -euo pipefail
upstream="$(cd "$(dirname "$0")/../upstream" && pwd)"
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && [ -n "$url" ] || { echo "offline curl: need -o and a URL" >&2; exit 1; }
candidates=("$(basename "${out%.part}")" "$(basename "${out%.tmp}")" "$(basename "$url")" "$(basename "$url").tar.gz")
for name in "${candidates[@]}"; do
  found="$(find "$upstream" -type f -name "$name" -print -quit)"
  if [ -n "$found" ]; then
    cp "$found" "$out"
    echo "offline curl: served $name" >&2
    exit 0
  fi
done
echo "offline curl: $url is not in this companion" >&2
exit 1
"""

OFFLINE_GIT = r"""#!/bin/bash
# Offline stand-in for `git clone` used while rebuilding from this companion. The recipe
# clones x264 and x265; this extracts the matching snapshot from ../upstream instead.
# Every other git command runs the real git found later on PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" != "clone" ]; then
  while IFS= read -r candidate; do
    [ "$(cd "$(dirname "$candidate")" && pwd)" = "$here" ] || exec "$candidate" "$@"
  done < <(type -ap git)
  echo "offline git: no real git found on PATH" >&2
  exit 1
fi
shift
url="" target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --depth|-b|--branch) shift 2 ;;
    -*) shift ;;
    *) if [ -z "$url" ]; then url="$1"; else target="$1"; fi; shift ;;
  esac
done
[ -n "$target" ] || target="$(basename "${url%.git}")"
snapshot="$(find "$here/../upstream" -type f -name "$target-*.tar.gz" -print -quit)"
[ -n "$snapshot" ] || { echo "offline git: no snapshot for $target" >&2; exit 1; }
tar -xzf "$snapshot"
echo "offline git: extracted $(basename "$snapshot") as $target" >&2
"""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def find_one(sources: list[Path], relative: str) -> Path | None:
    for directory in sources:
        candidate = directory / relative
        if candidate.exists():
            return candidate
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sources", type=Path, action="append", required=True,
                        help="ffmpeg-apple-silicon sources/ directory (repeatable; first match wins)")
    parser.add_argument("--output", type=Path, default=ROOT / "build/ffmpeg-source-companion")
    arguments = parser.parse_args()

    sources = [path.expanduser().resolve() for path in arguments.sources]
    for directory in sources:
        if not directory.is_dir():
            parser.error(f"not a directory: {directory}")
    output = arguments.output.expanduser().resolve()
    if output.exists():
        parser.error(f"output already exists, refusing to overwrite: {output}")
    for required in [RECIPE, BINARY, *PROVENANCE, *NOTICES]:
        if not required.exists():
            parser.error(f"missing repository input: {required.relative_to(ROOT)}")

    name = "ffmpeg-9.0.2-photo-agent-source"
    staging = output / name
    upstream = staging / "upstream"
    upstream.mkdir(parents=True)
    entries: list[dict[str, object]] = []
    missing: list[str] = []

    def record(path: Path, origin: str) -> None:
        entries.append({"path": str(path.relative_to(staging)), "bytes": path.stat().st_size,
                        "sha256": sha256(path), "origin": origin})

    seen: set[str] = set()
    for directory in sources:
        for archive in sorted(directory.iterdir()):
            if archive.name in seen or not archive.name.endswith(ARCHIVE_SUFFIXES):
                continue
            seen.add(archive.name)
            target = upstream / archive.name
            shutil.copy2(archive, target)
            record(target, "upstream archive as downloaded by the recipe")
    if "ffmpeg-9.0.2.tar.xz" not in seen:
        missing.append("ffmpeg-9.0.2.tar.xz")

    for checkout in GIT_CHECKOUTS:
        located = find_one(sources, checkout)
        if located is None:
            missing.append(checkout)
            continue
        commit = subprocess.run(["git", "-C", str(located), "rev-parse", "HEAD"], check=True,
                                capture_output=True, text=True).stdout.strip()
        target = upstream / f"{checkout}-{commit[:12]}.tar.gz"
        subprocess.run(["git", "-C", str(located), "archive", "--format=tar.gz",
                        f"--prefix={checkout}/", "-o", str(target), "HEAD"], check=True)
        record(target, f"git archive of {checkout} at commit {commit}")

    located = find_one(sources, LIBJXL_DOWNLOADS)
    if located is None:
        missing.append(LIBJXL_DOWNLOADS)
    else:
        jxl = upstream / "libjxl-deps"
        jxl.mkdir()
        for tarball in sorted(located.glob("*.tar.gz")):
            target = jxl / tarball.name
            shutil.copy2(tarball, target)
            record(target, "GitHub tarball pinned by commit hash in libjxl deps.sh")

    if missing:
        shutil.rmtree(output)
        print("error: required source inputs not found: " + ", ".join(missing), file=sys.stderr)
        return 1

    shutil.copytree(RECIPE, staging / "recipe", ignore=shutil.ignore_patterns(".DS_Store"))
    for path in sorted((staging / "recipe").rglob("*")):
        if path.is_file():
            if path.suffix == ".sh":
                path.chmod(0o755)  # the repository stores the recipe snapshot as plain files
            record(path, "build recipe and Photo Agent patches retained in the app repository")
    (staging / "offline").mkdir()
    for tool, text in [("curl", OFFLINE_CURL), ("git", OFFLINE_GIT)]:
        path = staging / "offline" / tool
        path.write_text(text)
        path.chmod(0o755)
        record(path, "offline download stand-in serving files from upstream/")
    (staging / "provenance").mkdir()
    for source in PROVENANCE + NOTICES:
        target = staging / "provenance" / source.name
        shutil.copy2(source, target)
        record(target, "provenance / license notice")

    readme = staging / "README.md"
    readme.write_text("""# Corresponding source: FFmpeg 9.0.2 (photo-agent build) in Aagedal Photo Agent

Aagedal Photo Agent bundles a statically linked FFmpeg 9.0.2 binary licensed GPL version 3 or
later. This archive is the complete corresponding source for that binary (SHA-256 before app
signing is recorded in provenance/ffmpeg-photo-agent-9.0.2.json).

- `upstream/`: every upstream source archive the build recipe downloads, unmodified;
  snapshots of the x264 and x265 git checkouts; and, in `libjxl-deps/`, the GitHub tarballs
  libjxl's `deps.sh` downloads (its third-party sources and test data), named by commit hash.
- `recipe/`: the exact build scripts (`build.sh`, `config.sh`, `scripts/NN-*.sh`) and Photo
  Agent's FFmpeg patches (`scripts/ffmpeg/af_whisper-canonical-json.patch`,
  `scripts/ffmpeg/yadif-videotoolbox-autorelease.patch`).
- `offline/`: `curl` and `git` stand-ins that serve the recipe's downloads and clones from
  `upstream/`, so the build needs no network and uses exactly these sources.
- `provenance/`: configure flags, library versions, notices and license texts.

## Rebuild

On an Apple Silicon Mac with Xcode, CMake, Meson, Ninja, pkg-config and autotools:

```sh
cp -R recipe /path/to/work && cd /path/to/work
PATH="/path/to/this/companion/offline:$PATH" bash build.sh
```

Answer `c` (clean) or `r` at the first prompt and press Return at the second. The script
builds every dependency and three FFmpeg variants. The bundled binary is the `photo-agent`
variant (`scripts/12b-ffmpeg-photo-agent.sh`), which applies both patches to a separate
source tree and verifies the patched `af_whisper.c` hash. Output: `dist/9.0.2/photo-agent/`.

`MANIFEST.json` lists the size and SHA-256 of every file in this archive.
""")
    record(readme, "rebuild instructions")

    manifest = {"component": "FFmpeg", "version": "9.0.2", "variant": "photo-agent",
                "license": "GPL-3.0-or-later", "bundledBinarySHA256": sha256(BINARY),
                "files": sorted(entries, key=lambda entry: str(entry["path"]))}
    (staging / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")

    bundle = output / f"{name}.tar"
    with tarfile.open(bundle, "w") as archive:
        archive.add(staging, arcname=name)
    total = sum(int(entry["bytes"]) for entry in entries)
    print(f"{len(entries)} files, {total / 1e6:.1f} MB")
    print(f"{bundle}  sha256 {sha256(bundle)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
