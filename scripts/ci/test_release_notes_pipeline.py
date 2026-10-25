#!/usr/bin/env python3
"""Release notes: finalize_changelog.py output and release.sh's appcast Highlights extraction."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import finalize_changelog  # noqa: E402

CHANGELOG = """# Changelog

## Unreleased

- Fixed a thing since the last beta.

## 3.0.0-beta.3 — 2026-10-11

### Highlights

- Beta three highlight.

## 2.2.0 — 2026-07-30

### Highlights

- Old release highlight.
"""

DRAFT = """# 3.0.0 release notes (draft)

Instructions for the owner.

---

## 3.0.0 — YYYY-MM-DD

Intro paragraph.

### Highlights

- First highlight.
- Second highlight.

### Changes for 2.x users

- Not a highlight.
"""


def release_sh_notes(changelog: str, version: str) -> list[str]:
    """Runs the exact awk program release.sh uses to build the appcast notes."""
    script = (ROOT / "scripts/release.sh").read_text(encoding="utf-8")
    program = re.search(r"""NOTES="\$\(awk -v ver="\$VERSION" '(.*?)' "\$CHANGELOG"\)\"""", script, re.S)
    assert program, "release.sh no longer has the expected NOTES awk block"
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(changelog)
    output = subprocess.run(["awk", "-v", f"ver={version}", program.group(1), handle.name],
                            capture_output=True, text=True, check=True).stdout
    Path(handle.name).unlink()
    return [line.strip() for line in output.splitlines() if line.strip()]


class ReleaseNotesPipelineTests(unittest.TestCase):
    def finalized(self) -> str:
        section = finalize_changelog.draft_section(DRAFT, "3.0.0", "2026-11-02")
        return finalize_changelog.finalize(CHANGELOG, section, "3.0.0")

    def test_finalize_dates_the_section_and_moves_unreleased_entries(self):
        result = self.finalized()
        self.assertIn("## Unreleased\n\n## 3.0.0 — 2026-11-02\n", result)
        self.assertIn("### Changes since 3.0.0-beta.3\n\n- Fixed a thing since the last beta.\n", result)
        self.assertLess(result.index("## 3.0.0 — "), result.index("## 3.0.0-beta.3"))

    def test_finalize_refuses_to_run_twice(self):
        section = finalize_changelog.draft_section(DRAFT, "3.0.0", "2026-11-02")
        with self.assertRaises(SystemExit):
            finalize_changelog.finalize(self.finalized(), section, "3.0.0")

    def test_appcast_notes_contain_only_the_release_highlights(self):
        notes = release_sh_notes(self.finalized(), "3.0.0")
        self.assertEqual(notes, ["<li>First highlight.</li>", "<li>Second highlight.</li>"])

    def test_beta_and_older_versions_still_extract(self):
        result = self.finalized()
        self.assertEqual(release_sh_notes(result, "3.0.0-beta.3"), ["<li>Beta three highlight.</li>"])
        self.assertEqual(release_sh_notes(result, "2.2.0"), ["<li>Old release highlight.</li>"])

    def test_markdown_and_wrapped_highlights_are_reported(self):
        bad = DRAFT.replace("- Second highlight.", "- Second **bold** highlight\n  that wraps.")
        problems = finalize_changelog.highlight_problems(finalize_changelog.draft_section(bad, "3.0.0", "2026-11-02"))
        self.assertEqual(len(problems), 2)

    def test_real_draft_has_highlights(self):
        draft = (ROOT / "docs/release/3.0.0-release-notes-draft.md").read_text(encoding="utf-8")
        section = finalize_changelog.draft_section(draft, "3.0.0", "2026-11-02")
        self.assertTrue(finalize_changelog.highlights(section))
        self.assertEqual(finalize_changelog.highlight_problems(section), [])


if __name__ == "__main__":
    unittest.main()
