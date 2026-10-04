#!/usr/bin/env python3
"""Copy verified runtime into Contents/Resources and sign inside-out for release builds."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, destination = map(Path, sys.argv[1:])
manifest = json.loads((source / 'runtime.json').read_text())
for name, digest in manifest['files'].items():
    if Path(name).name != name or hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'Bundled llama.cpp artifact mismatch: {name}')
# Migrate only known generated helper paths after source verification. Helpers is
# reserved for code entries; Resources permits the accompanying manifest/license.
if destination.name == 'llama-runtime' and destination.parent.name == 'Resources':
    for name in ('llama.cpp', 'llama-runtime'):
        obsolete = destination.parent.parent / 'Helpers' / name
        if obsolete.is_symlink():
            obsolete.unlink()
        elif obsolete.exists():
            shutil.rmtree(obsolete)
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination)
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '')
if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' and identity and identity != '-':
    for artifact in [*sorted(destination.glob('*.dylib')), destination / 'llama-completion']:
        subprocess.run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', identity, str(artifact)], check=True)
