#!/usr/bin/env python3
"""Build and record an unsigned local model-free candidate from clean committed source.

This does not sign, notarize, publish, launch, or validate production model downloads.
Existing output directories are never reused, including after a failed build.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import zipfile
from pathlib import Path, PurePosixPath

from validate_model_omission import inspect_app


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()


def source_revision(repo: Path) -> str:
    if git(repo, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('candidate requires a clean worktree, including untracked files')
    return git(repo, 'rev-parse', 'HEAD')


def verify_source(repo: Path, expected: str) -> None:
    if source_revision(repo) != expected:
        raise ValueError('source revision changed during candidate creation')


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify_archive(app: Path, archive: Path) -> dict:
    """Compare packaged payload bytes, links, and executable bits without extracting.

    ditto's optional AppleDouble metadata is separate from the bundle payload. All
    archive names, including metadata, must still be relative, canonical paths.
    """
    expected = {}
    expected_directories = {app.name}

    def fail(error):
        raise error

    for directory, directories, files in os.walk(app, followlinks=False, onerror=fail):
        for name in directories + files:
            path = Path(directory) / name
            relative = path.relative_to(app.parent).as_posix()
            if path.is_symlink():
                expected[relative] = ('link', os.readlink(path), 0)
            elif path.is_file():
                expected[relative] = ('file', sha256(path), path.stat().st_mode & 0o111)
            elif path.is_dir():
                expected_directories.add(relative)
            else:
                raise ValueError(f'unsupported bundle entry: {relative}')
    seen = set()
    names = set()
    with zipfile.ZipFile(archive) as package:
        for entry in package.infolist():
            name = entry.filename.rstrip('/')
            parts = PurePosixPath(name).parts
            if (not name or name.startswith('/') or '\\' in name
                    or any(part in ('.', '..', '') for part in name.split('/'))):
                raise ValueError(f'unsafe archive entry: {entry.filename}')
            if name in names:
                raise ValueError(f'duplicate archive entry: {name}')
            names.add(name)
            metadata_name = name.removeprefix('__MACOSX/')
            metadata_path = PurePosixPath(metadata_name)
            metadata_target = str(metadata_path.with_name(metadata_path.name[2:])) if metadata_path.name.startswith('._') else None
            if name not in expected and metadata_target in (expected.keys() | expected_directories):
                # ditto can emit AppleDouble next to the payload or under __MACOSX.
                # Require its magic and consume all bytes to verify its CRC.
                with package.open(entry) as stream:
                    if stream.read(4) != b'\x00\x05\x16\x07':
                        raise ValueError(f'invalid archive metadata: {name}')
                    while stream.read(1024 * 1024):
                        pass
                continue
            if parts[0] == '__MACOSX' and entry.is_dir():
                if metadata_name == '__MACOSX' or metadata_name in expected_directories:
                    continue
            if entry.is_dir():
                if name not in expected_directories:
                    raise ValueError(f'unexpected archive directory: {name}')
                continue
            if name not in expected:
                raise ValueError(f'unexpected archive payload: {name}')
            kind, value, executable_bits = expected[name]
            mode = entry.external_attr >> 16
            if kind == 'link':
                if not stat.S_ISLNK(mode) or package.read(entry) != os.fsencode(value):
                    raise ValueError(f'archive link differs from bundle: {name}')
            else:
                if not stat.S_ISREG(mode) or mode & 0o111 != executable_bits:
                    raise ValueError(f'archive file type or executable bits differ: {name}')
                digest = hashlib.sha256()
                with package.open(entry) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
                if digest.hexdigest() != value:
                    raise ValueError(f'archive bytes differ from bundle: {name}')
            seen.add(name)
    if seen != expected.keys():
        raise ValueError('archive is missing bundle payload entries')
    return {'archivePayloadVerified': True, 'archivePayloadEntryCount': len(seen)}


def build_candidate(repo: Path, output: Path) -> dict:
    revision = source_revision(repo)
    # Keep generated files in the repository's ignored build directory so the final
    # clean-source check can distinguish unrelated edits from our own build output.
    output = output.resolve()
    build_root = (repo / 'build').resolve()
    if not output.is_relative_to(build_root) or output == build_root:
        raise ValueError('output must be a new directory inside the repository build directory')
    output.mkdir(parents=True, exist_ok=False)
    command = [
        'xcodebuild', 'build', '-project', 'Aagedal Photo Agent.xcodeproj',
        '-scheme', 'Aagedal Photo Agent', '-configuration', 'Release',
        '-destination', 'generic/platform=macOS', 'CODE_SIGNING_ALLOWED=NO',
        f'CONFIGURATION_BUILD_DIR={output / "products"}',
    ]
    with (output / 'build.log').open('w') as log:
        subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True)
    verify_source(repo, revision)
    app = output / 'products/Aagedal Photo Agent.app'
    result = inspect_app(app)
    archive = output / 'model-omitted-app.zip'
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
    result.update(verify_archive(app, archive))
    # Check the bundle again after packaging before publishing success evidence.
    final_inventory = inspect_app(app)
    if final_inventory != {key: result[key] for key in final_inventory}:
        raise ValueError('bundle inventory changed during candidate packaging')
    result.update({
        'sourceRevision': revision,
        'configuration': 'Release, CODE_SIGNING_ALLOWED=NO',
        'buildCommand': command,
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'macOS': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
        'macOSBuild': subprocess.check_output(['sw_vers', '-buildVersion'], text=True).strip(),
        'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
        'zipBytes': archive.stat().st_size,
        'zipSHA256': sha256(archive),
        'validationScope': 'Unsigned local build and model omission only; no launch, signing, notarization, or production-server validation',
    })
    verify_source(repo, revision)
    # A success manifest appears only after every build, bundle, archive, and source check.
    (output / 'measurement.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new directory under build/')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    try:
        print(json.dumps(build_candidate(repo, args.output), indent=2, sort_keys=True))
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
