#!/usr/bin/env python3
"""Generate the README's bundled FFmpeg source offer from the component manifest."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


MANIFEST = Path("Aagedal Photo Agent/Resources/bundled-components.json")
README = Path("README.md")
START = "<!-- BEGIN GENERATED BUNDLED GPL SOURCE -->"
END = "<!-- END GENERATED BUNDLED GPL SOURCE -->"


def generated_block(document: dict) -> str:
    ffmpeg = next(item for item in document["components"] if item["id"] == "ffmpeg-photo")
    upstream = ffmpeg["upstream"]
    recipe = ffmpeg["buildRecipe"]
    return "\n".join([
        START,
        f"- **FFmpeg {ffmpeg['version']}**, built with `--enable-gpl --enable-version3` (image-only, network",
        "  and device features disabled). The exact `configure` flags are embedded in the binary",
        f"  (`ffmpeg -version`). [Upstream source archive]({upstream['sourceArchive']}).",
        f"- The pinned build recipe is `{recipe['path']}` at revision `{recipe['revision']}` in",
        f"  [{recipe['url']}]({recipe['url']}).",
        END,
    ])


def replace_generated_block(readme: str, block: str) -> str:
    start = readme.find(START)
    end = readme.find(END)
    if start < 0 or end < start:
        raise ValueError("README generated-source markers are missing or out of order")
    end += len(END)
    return readme[:start] + block + readme[end:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail instead of updating stale output")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    arguments = parser.parse_args()

    try:
        document = json.loads((arguments.root / MANIFEST).read_text(encoding="utf-8"))
        readme_path = arguments.root / README
        current = readme_path.read_text(encoding="utf-8")
        expected = replace_generated_block(current, generated_block(document))
    except (OSError, ValueError, KeyError, StopIteration, json.JSONDecodeError) as error:
        print(f"bundled component documentation generation failed: {error}", file=sys.stderr)
        return 1

    if current == expected:
        print("README bundled-source offer is current")
        return 0
    if arguments.check:
        print(
            "README bundled-source offer is stale; run scripts/generate_bundled_component_docs.py",
            file=sys.stderr,
        )
        return 1
    readme_path.write_text(expected, encoding="utf-8")
    print("updated README bundled-source offer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
