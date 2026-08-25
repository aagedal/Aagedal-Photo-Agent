#!/usr/bin/env python3
"""Print a compact Markdown summary from xcresulttool's test summary JSON."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} RESULT_BUNDLE", file=sys.stderr)
        return 2

    result_bundle = Path(sys.argv[1])
    if not result_bundle.is_dir():
        print(f"Test result bundle was not created: `{result_bundle}`")
        return 1

    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        str(result_bundle),
        "--compact",
    ]
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
        summary = json.loads(completed.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Could not read the test summary: `{error}`")
        return 1

    result = summary.get("result", "Unknown")
    total = summary.get("totalTestCount", "unknown")
    passed = summary.get("passedTests", "unknown")
    failed = summary.get("failedTests", "unknown")
    skipped = summary.get("skippedTests", "unknown")
    print(f"Result: **{result}** — total {total}, passed {passed}, failed {failed}, skipped {skipped}.")

    failures = summary.get("testFailures") or []
    for failure in failures[:10]:
        name = failure.get("testName") or failure.get("name") or "Unnamed test"
        message = " ".join(str(failure.get("message", "")).split())
        print(f"- `{name}`: {message[:300]}")
    if len(failures) > 10:
        print(f"- …and {len(failures) - 10} more failures; inspect the attached `.xcresult`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
