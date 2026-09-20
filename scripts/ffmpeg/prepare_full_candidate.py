#!/usr/bin/env python3
"""Prepare an isolated, hash-pinned full FFmpeg/Whisper rebuild (never install it)."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

from prepare_whisper_source import patched_source

SOURCE_SHA256 = "23587fed102cfe66910db1d4ae66b50565387a1750e039fb10fde6fbfd027e71"
LIBVPX_SHA256 = "7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c"


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def require_hash(path, expected):
    actual = digest(path)
    if actual != expected:
        raise ValueError(f"{path}: expected SHA-256 {expected}, got {actual}")


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"unexpected attributed recipe; expected one occurrence of {old!r}")
    return text.replace(old, new, 1)


def prepare(archive, libvpx_archive, output, jobs):
    if not 1 <= jobs <= 32:
        raise ValueError("jobs must be between 1 and 32")
    require_hash(archive, SOURCE_SHA256)
    require_hash(libvpx_archive, LIBVPX_SHA256)
    # A new directory prevents combining retained objects or unrelated dependencies.
    output.mkdir(parents=False, exist_ok=False)
    with tarfile.open(archive) as source:
        source.extractall(output, filter="data")
    # Uppercase Build escaped the companion's output exclusion. CMake refuses its
    # old absolute workspace path; retain sources, regenerate only this cache.
    stale_cache = output / "sources/SVT-AV1-v4.2.0/Build/CMakeCache.txt"
    stale_cache_hash = digest(stale_cache)
    stale_cache.unlink()
    # FreeType's generated .pc is a make target, not a configure output; its
    # retained timestamp otherwise preserves the original installation prefix.
    stale_freetype = output / "sources/freetype-2.14.3/builds/unix/freetype2.pc"
    stale_freetype_hash = digest(stale_freetype)
    stale_freetype.unlink()
    # The companion incorrectly excluded libvpx's source directory named build.
    # Restore only that directory from its separately attributed original archive.
    with tarfile.open(libvpx_archive) as source:
        members = [m for m in source if m.name.startswith("libvpx-1.16.0/build/")]
        if not any(m.name.endswith("/make/configure.sh") for m in members):
            raise ValueError("libvpx archive lacks required build sources")
        source.extractall(output / "sources", members=members, filter="data")
    target = output / "sources/ffmpeg-9.0.1/libavfilter/af_whisper.c"
    target.write_bytes(patched_source(target))
    extras = output / "scripts/11-extras.sh"
    original_extras_hash = digest(extras)
    recipe = replace_once(extras.read_text(),
                          '    tar xf "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"\n',
                          '    tar xf "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"\nfi\n')
    recipe = replace_once(recipe,
                          '    ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build" install\nfi',
                          '    ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build" install')
    recipe = replace_once(recipe,
                          '    ninja -C "harfbuzz-${HARFBUZZ_VERSION}/build"\n',
                          '    ninja ${MAKEFLAGS} -C "harfbuzz-${HARFBUZZ_VERSION}/build"\n')
    extras.write_text(recipe)
    config = output / "config.sh"
    original_config_hash = digest(config)
    recipe = replace_once(config.read_text(), "export CPU_COUNT\n",
                          f"CPU_COUNT={jobs}\nexport CPU_COUNT\n")
    recipe = replace_once(recipe, "download_file() {\n",
                          'download_file() {\n    echo "Offline attributed build: refusing download" >&2\n    return 1\n')
    config.write_text(recipe)
    evidence = {
        "archiveSHA256": SOURCE_SHA256,
        "libvpxOriginalArchiveSHA256": LIBVPX_SHA256,
        "patchedFilterSHA256": digest(target),
        "jobs": jobs,
        "removedStaleSVTCacheSHA256": stale_cache_hash,
        "removedStaleFreeTypePkgConfigSHA256": stale_freetype_hash,
        "originalRecipes": {"config.sh": original_config_hash,
                            "scripts/11-extras.sh": original_extras_hash},
        "preparedRecipes": {"config.sh": digest(config), "scripts/11-extras.sh": digest(extras)},
        "changes": ["Pinned canonical Whisper JSON patch", "Restore omitted libvpx build source directory",
                    "Regenerate retained SVT-AV1 CMake cache containing the original absolute workspace",
                    "Regenerate retained FreeType pkg-config file containing the original install prefix",
                    "Rebuild HarfBuzz even when its source directory exists", "Bound parallel jobs",
                    "Refuse recipe download_file calls"],
        "candidateBuilt": False,
    }
    (output / "photo-agent-preparation.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--libvpx-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new directory; parent must exist")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    try:
        evidence = prepare(args.archive, args.libvpx_archive, args.output, args.jobs)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot prepare full FFmpeg candidate: {error}\n")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
