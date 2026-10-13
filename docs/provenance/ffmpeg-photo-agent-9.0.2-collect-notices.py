#!/usr/bin/env python3
"""Collect available license notices from the recorded dependency source checkout.

This inventory is deterministic source evidence, not a linked-object audit or a
claim that every bundled source notice applies to the resulting executable.
"""
import argparse
import hashlib
import json
from pathlib import Path

DEPENDENCIES = (
    'SVT-AV1-v4.2.0', 'brotli-1.2.0', 'freetype-2.15.0', 'fribidi-1.0.17',
    'harfbuzz-14.6.0', 'highway-1.4.0', 'lame-4.0', 'libaom-3.15.2',
    'libass-0.17.5', 'libjxl-0.12.0', 'libogg-1.3.6', 'libpng-1.6.59',
    'libtheora-1.2.0', 'libvorbis-1.3.7', 'libvpx-1.17.0', 'libwebp-1.6.0',
    'openjpeg-2.5.4', 'opus-1.6.1', 'vmaf-3.2.1', 'vvenc-1.14.0',
    'whisper.cpp-1.9.5', 'x264', 'x265-4.2',
)
EXCLUDED = {'.git', 'build', '_build', 'objs', 'test', 'tests', 'testdata',
            'examples', 'bindings', 'perf', 'debian', 'bazel', 'contrib',
            'googletest', 'HEVCSoftware', 'release', 'bin'}
HEADER = '''FFmpeg 9.0.2 Photo Agent variant — dependency source notices

The application bundles a GPL version 3 or later FFmpeg build with no nonfree
configuration flag. Build identity and limitations are recorded in
docs/provenance/ffmpeg-photo-agent-9.0.2.md.

These notices were collected from the available dependency sources in the
recorded reused build prefix's source checkout. The inventory includes nested
source notices where available. It does not establish which optional nested
components were linked, complete corresponding-source delivery, or release approval.
The deterministic inventory and collection script are recorded beside the provenance.
Only trailing spaces/tabs, CRLF line endings and final blank lines are normalized
in this combined output; source-byte hashes and lengths remain in the inventory.

'''


def collect(source):
    paths = []
    for name in DEPENDENCIES:
        root = source / name
        if not root.is_dir():
            raise SystemExit(f'Missing dependency source: {root}')
        for p in root.rglob('*'):
            if not p.is_file() or any(part in EXCLUDED for part in p.relative_to(root).parts[:-1]):
                continue
            filename = p.name.upper()
            if filename.startswith(('LICENSE', 'COPYING', 'PATENTS', 'NOTICE', 'COPYRIGHT')) or filename == 'FTL.TXT':
                # Reject binary or invalid-UTF8 files instead of silently changing notices.
                data = p.read_bytes()
                if b'\0' in data:
                    raise SystemExit(f'Unexpected binary notice: {p}')
                data.decode('utf-8')
                paths.append(p)
    for name in ('freetype-2.15.0/docs/GPLv2.TXT', 'freetype-2.15.0/src/bdf/README', 'freetype-2.15.0/src/pcf/README'):
        p = source / name
        p.read_bytes().decode('utf-8')
        paths.append(p)
    return sorted(set(paths), key=lambda p: p.relative_to(source).as_posix())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    args = parser.parse_args()
    notices = []
    body = [HEADER]
    for p in collect(args.source_root):
        data = p.read_bytes()
        name = 'sources/' + p.relative_to(args.source_root).as_posix()
        notices.append({'path': name, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
        body.append('=' * 72 + '\n' + name + '\n' + '=' * 72 + '\n\n' + data.decode('utf-8') + '\n\n')
    normalized = '\n'.join(line.rstrip(' \t') for line in ''.join(body).splitlines()).rstrip('\n') + '\n'
    args.output.write_text(normalized, encoding='utf-8')
    args.inventory.write_text(json.dumps({'dependencies': DEPENDENCIES, 'outputNormalization': 'Strip trailing spaces/tabs, normalize line endings to LF, and emit one final newline; source hashes/bytes refer to unmodified inputs.', 'notices': notices}, indent=2) + '\n', encoding='utf-8')
    print(f'Collected {len(notices)} notices from {len(DEPENDENCIES)} dependencies')


if __name__ == '__main__':
    main()
