#!/usr/bin/env python3
"""Prepare the pinned upstream Apple Silicon completion runtime for app builds."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

TAG = 'b11377'
URL = f'https://github.com/ggml-org/llama.cpp/releases/download/{TAG}/llama-{TAG}-bin-macos-arm64.tar.gz'
SHA256 = 'f06daae194a06948c6c534960d8d211219c46168b84b7951ab7d651d25d71c69'
ROOT = Path(__file__).resolve().parents[2]

def prepare(archive):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('Runtime archive checksum mismatch')
    destination = ROOT / 'Vendor/llama.cpp'
    if destination.exists():
        raise RuntimeError('Remove Vendor/llama.cpp explicitly before replacing a runtime')
    with tempfile.TemporaryDirectory() as temporary:
        with tarfile.open(archive) as source:
            source.extractall(temporary, filter='data')
        extracted = Path(temporary) / f'llama-{TAG}'
        files = {}
        pending = ['llama-completion']
        while pending:
            name = pending.pop()
            if name in files:
                continue
            artifact = extracted / name
            if not artifact.resolve().is_relative_to(extracted.resolve()):
                raise RuntimeError('Library resolves outside archive')
            files[name] = artifact
            dependencies = subprocess.check_output(['otool', '-L', str(artifact)], text=True)
            for line in dependencies.splitlines()[1:]:
                dependency = line.strip().split(' (')[0]
                if dependency.startswith('@rpath/'):
                    pending.append(dependency.removeprefix('@rpath/'))
                elif not dependency.startswith(('/usr/lib/', '/System/Library/')):
                    raise RuntimeError(f'Nonportable dependency: {dependency}')
        destination.mkdir(parents=True)
        for name, artifact in files.items():
            shutil.copy2(artifact, destination / name, follow_symlinks=True)
        shutil.copy2(extracted / 'LICENSE', destination / 'LICENSE')
        manifest = {'upstream': 'https://github.com/ggml-org/llama.cpp', 'tag': TAG,
                    'archiveURL': URL, 'archiveSHA256': SHA256, 'architecture': 'arm64',
                    'license': 'MIT', 'files': {name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
                                              for name in sorted(files)}}
        (destination / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use an already downloaded, checksum-verified release archive')
    args = parser.parse_args()
    if args.archive:
        prepare(args.archive)
    else:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'runtime.tar.gz'
            urllib.request.urlretrieve(URL, archive)
            prepare(archive)
