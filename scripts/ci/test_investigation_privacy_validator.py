#!/usr/bin/env python3
"""Positive and fail-closed checks for validate_investigation_privacy.py."""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("validate_investigation_privacy.py")
SPEC = importlib.util.spec_from_file_location("validate_investigation_privacy", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


def main() -> int:
    repository = SCRIPT.parents[2]
    assert VALIDATOR.validate(repository) == []

    with tempfile.TemporaryDirectory(prefix="photo-agent-investigation-privacy-") as directory:
        fixture = Path(directory)
        for relative in {requirement.path for requirement in VALIDATOR.REQUIREMENTS}:
            destination = fixture / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repository / relative, destination)

        mutations = (
            (
                Path("Aagedal Photo Agent/Services/AnalysisPDFReportRenderer.swift"),
                "var includeLocationCoordinates = false",
                "var includeLocationCoordinates = true",
                "exact coordinates",
            ),
            (
                Path("Aagedal Photo Agent/Services/AnalysisOpenStreetMapSnapshotter.swift"),
                "configuration.urlCache = nil",
                "configuration.urlCache = URLCache.shared",
                "URL cache",
            ),
            (
                Path("Aagedal Photo Agent/Views/Analysis/AnalysisOpenStreetMapView.swift"),
                "URLSessionConfiguration.ephemeral",
                "URLSessionConfiguration.default",
                "interactive OpenStreetMap tiles use an ephemeral session",
            ),
            (
                Path("Aagedal Photo Agent/Services/FTPService.swift"),
                "mode_t(0o600)",
                "mode_t(0o644)",
                "owner-only permissions",
            ),
        )
        for relative, old, new, expected_label in mutations:
            target = fixture / relative
            original = target.read_text(encoding="utf-8")
            assert old in original
            target.write_text(original.replace(old, new, 1), encoding="utf-8")
            failures = VALIDATOR.validate(fixture)
            assert any(expected_label in failure for failure in failures), failures
            target.write_text(original, encoding="utf-8")

    print("investigation privacy validator self-test passed (positive plus 4 regressions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
