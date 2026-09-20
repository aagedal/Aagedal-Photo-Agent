#!/usr/bin/env python3
"""Bind the app resource seal to the exact FFmpeg bytes after nested code signing."""
import hashlib
import json
import os
from pathlib import Path
import sys


def main():
    executable, destination = map(Path, sys.argv[1:])
    digest = hashlib.sha256()
    count = 0
    with executable.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
            count += len(chunk)
    if count <= 0:
        raise ValueError('Bundled FFmpeg is empty')
    value = {'schemaVersion': 1, 'executableSHA256': digest.hexdigest(),
             'executableByteCount': count, 'producerContract': 'photo-agent-whisper-json-v1'}
    data = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    if destination.exists() and destination.read_bytes() == data:
        return
    temporary = destination.with_suffix('.tmp')
    temporary.write_bytes(data)
    os.replace(temporary, destination)


if __name__ == '__main__':
    main()
