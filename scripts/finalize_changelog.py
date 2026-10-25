#!/usr/bin/env python3
"""Release-day CHANGELOG step: turn the release-notes draft into the dated release section.

Takes the section below the `---` line of the draft (for example
docs/release/3.0.0-release-notes-draft.md), dates its heading, inserts it under an empty
`## Unreleased`, and moves the current Unreleased entries beneath it as
`### Changes since <previous heading>`. Refuses to run twice and checks the Highlights that
scripts/release.sh turns into the Sparkle appcast notes.

Usage:
  scripts/finalize_changelog.py --version 3.0.0 --date 2026-11-02 \
      --draft docs/release/3.0.0-release-notes-draft.md [--changelog CHANGELOG.md] [--dry-run]
"""

import argparse
import datetime
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    sys.exit(f"finalize_changelog: {message}")


def draft_section(draft: str, version: str, date: str) -> str:
    parts = re.split(r"^---\s*$", draft, maxsplit=1, flags=re.M)
    if len(parts) != 2:
        fail("the draft needs a '---' line above the release section")
    section = parts[1].strip()
    heading = re.match(rf"^## {re.escape(version)} — (\S+)\s*$", section.splitlines()[0])
    if not heading:
        fail(f"the draft section must start with '## {version} — YYYY-MM-DD'")
    section = section.replace(f"## {version} — {heading.group(1)}", f"## {version} — {date}", 1)
    return section + "\n"


def highlights_block(section: str) -> str:
    match = re.search(r"^### Highlights\s*$(.*?)(?=^### |\Z)", section, flags=re.M | re.S)
    return match.group(1) if match else ""


def highlights(section: str) -> list[str]:
    return [line for line in highlights_block(section).splitlines() if line.startswith("- ")]


def highlight_problems(section: str) -> list[str]:
    """release.sh copies each bullet's first line verbatim into the appcast HTML."""
    problems = []
    for line in highlights_block(section).splitlines():
        if line.strip() and not line.startswith("- "):
            problems.append(f"a Highlights bullet continues on another line (only the first line reaches the appcast): {line.strip()!r}")
    for bullet in highlights(section):
        if "**" in bullet or "](" in bullet or "`" in bullet:
            problems.append(f"a Highlights bullet uses markdown, which the appcast shows as raw text: {bullet!r}")
        if "]]>" in bullet:
            problems.append(f"a Highlights bullet contains ']]>', which would break the appcast CDATA block: {bullet!r}")
    return problems


def finalize(changelog: str, section: str, version: str) -> str:
    if re.search(rf"^## {re.escape(version)}( |$)", changelog, flags=re.M):
        fail(f"CHANGELOG already has a '## {version}' section")
    unreleased = re.search(r"^## Unreleased\s*$\n(.*?)(?=^## )", changelog, flags=re.M | re.S)
    if not unreleased:
        fail("CHANGELOG needs a '## Unreleased' section followed by an earlier release")
    previous = re.search(r"^## (\S+)", changelog[unreleased.end():], flags=re.M).group(1)
    entries = unreleased.group(1).strip()
    moved = f"\n### Changes since {previous}\n\n{entries}\n" if entries else ""
    replacement = f"## Unreleased\n\n{section.rstrip()}\n{moved}\n"
    return changelog[:unreleased.start()] + replacement + changelog[unreleased.end():]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True)
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    parser.add_argument("--draft", required=True, type=Path)
    parser.add_argument("--changelog", default=Path("CHANGELOG.md"), type=Path)
    parser.add_argument("--dry-run", action="store_true", help="print the result instead of writing it")
    args = parser.parse_args()

    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        fail("--date must be YYYY-MM-DD")
    section = draft_section(args.draft.read_text(encoding="utf-8"), args.version, args.date)
    bullets = highlights(section)
    if not bullets:
        fail("the draft has no bullets under '### Highlights' (the appcast notes need at least one)")
    problems = highlight_problems(section)
    if problems:
        fail("\n  ".join(["the Highlights can't go into the appcast as written:"] + problems))

    result = finalize(args.changelog.read_text(encoding="utf-8"), section, args.version)
    if args.dry_run:
        sys.stdout.write(result)
    else:
        args.changelog.write_text(result, encoding="utf-8")
        print(f"Added '## {args.version} — {args.date}' with {len(bullets)} highlights to {args.changelog}.")


if __name__ == "__main__":
    main()
