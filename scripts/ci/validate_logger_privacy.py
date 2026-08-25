#!/usr/bin/env python3
"""Reject unapproved public interpolation in the app's unified logs."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


APP_SOURCE = Path("Aagedal Photo Agent")
PUBLIC_SUFFIX = re.compile(r",\s*privacy\s*:\s*\.public\s*$", re.DOTALL)
SAFE_PUBLIC_EXPRESSIONS = (
    re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\.count"),
    re.compile(r"key\.rawValue"),
    re.compile(r'orientation\s*\?\?\s*"nil"'),
    re.compile(r"String\(describing:\s*(?:referenceSource|reason)\)"),
)


@dataclass(frozen=True)
class PublicInterpolation:
    path: Path
    line: int
    expression: str


def interpolation_expressions(source: str):
    """Yield balanced Swift string-interpolation expressions and their offsets."""
    cursor = 0
    while True:
        start = source.find(r"\(", cursor)
        if start < 0:
            return
        index = start + 2
        depth = 1
        in_string = False
        while index < len(source):
            character = source[index]
            if character == '"' and not _is_escaped(source, index):
                in_string = not in_string
            elif not in_string:
                if character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                    if depth == 0:
                        yield start, source[start + 2:index]
                        cursor = index + 1
                        break
            index += 1
        else:
            cursor = start + 2


def _is_escaped(source: str, index: int) -> bool:
    slashes = 0
    index -= 1
    while index >= 0 and source[index] == "\\":
        slashes += 1
        index -= 1
    return slashes % 2 == 1


def public_interpolations(path: Path) -> list[PublicInterpolation]:
    source = path.read_text(encoding="utf-8")
    findings = []
    for offset, interpolation in interpolation_expressions(source):
        match = PUBLIC_SUFFIX.search(interpolation)
        if match is None:
            continue
        expression = interpolation[:match.start()].strip()
        findings.append(PublicInterpolation(
            path=path,
            line=source.count("\n", 0, offset) + 1,
            expression=" ".join(expression.split()),
        ))
    return findings


def is_approved_public(expression: str) -> bool:
    return any(pattern.fullmatch(expression) for pattern in SAFE_PUBLIC_EXPRESSIONS)


def validate(root: Path) -> tuple[list[PublicInterpolation], int, int]:
    source_root = root / APP_SOURCE
    swift_files = sorted(source_root.rglob("*.swift"))
    all_public = [
        finding
        for path in swift_files
        for finding in public_interpolations(path)
    ]
    violations = [item for item in all_public if not is_approved_public(item.expression)]
    return violations, len(swift_files), len(all_public)


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
    if len(sys.argv) > 2 or not (root / APP_SOURCE).is_dir():
        print(f"usage: {Path(sys.argv[0]).name} [REPOSITORY_ROOT]", file=sys.stderr)
        return 2

    violations, file_count, public_count = validate(root)
    if violations:
        for item in violations:
            relative = item.path.relative_to(root)
            print(
                f"{relative}:{item.line}: prohibited public log interpolation: "
                f"{item.expression}",
                file=sys.stderr,
            )
        print(
            "Potentially identifying log values must be private/redacted. "
            "Extend the narrow safe-public allowlist only for non-user data.",
            file=sys.stderr,
        )
        return 1

    print(
        f"logger privacy validation passed across {file_count} Swift files; "
        f"{public_count} approved non-identifying public interpolation(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
