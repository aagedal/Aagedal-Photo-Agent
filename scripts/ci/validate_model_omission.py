#!/usr/bin/env python3
"""Inspect a built app for accidentally bundled AuraFace payloads; never modify it."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
from pathlib import Path

MODEL_SUFFIXES = {'.mlmodelc', '.mlpackage', '.mlmodel', '.onnx', '.zip'}


def inspect_app(app: Path) -> dict:
    app = app.resolve(strict=True)
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError('expected an existing .app directory')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = info.get('CFBundleExecutable')
    if (not isinstance(executable, str) or Path(executable).name != executable
            or not (app / 'Contents/MacOS' / executable).is_file()):
        raise ValueError('app executable is missing or invalid')
    count = size = 0

    def fail(error):
        raise error

    for directory, directories, files in os.walk(app, followlinks=False, onerror=fail):
        for name in directories + files:
            path = Path(directory) / name
            if 'auraface' in name.lower() and path.suffix.lower() in MODEL_SUFFIXES:
                raise ValueError(f'app contains on-demand model payload: {path.relative_to(app)}')
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(app):
                raise ValueError(f'app link resolves outside its bundle: {path.relative_to(app)}')
            if path.is_file() and not path.is_symlink():
                count += 1
                size += path.stat().st_size
    return {
        'schemaVersion': 1, 'app': str(app), 'modelOmitted': True,
        'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
        'regularFileCount': count, 'regularFileBytes': size,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect_app(args.app), indent=2, sort_keys=True))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
