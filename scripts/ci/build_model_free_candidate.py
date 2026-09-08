#!/usr/bin/env python3
"""Build and record an unsigned local model-free candidate from clean committed source.

This does not sign, notarize, publish, launch, or validate production model downloads.
Existing output directories are never reused, including after a failed build.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

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
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
