#!/usr/bin/env python3
"""Focused positive and negative tests for validate_logger_privacy.py."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("validate_logger_privacy.py")
SPEC = importlib.util.spec_from_file_location("validate_logger_privacy", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


def validate_fixture(source: str):
    with tempfile.TemporaryDirectory(prefix="photo-agent-log-privacy-") as directory:
        root = Path(directory)
        source_root = root / VALIDATOR.APP_SOURCE
        source_root.mkdir()
        (source_root / "Fixture.swift").write_text(source, encoding="utf-8")
        return VALIDATOR.validate(root)[0]


def main() -> int:
    safe = r'''
import os
let logger = Logger()
logger.info("Processed \(items.count, privacy: .public) item(s)")
logger.info("Source \(url.path, privacy: .private(mask: .hash))")
logger.error("Failure: \(error.localizedDescription, privacy: .private)")
'''
    assert validate_fixture(safe) == []

    prohibited = {
        "path": r'logger.info("Source \(url.path, privacy: .public)")',
        "filename": r'logger.info("Source \(url.lastPathComponent, privacy: .public)")',
        "identifier": r'logger.info("Face \(faceID.uuidString, privacy: .public)")',
        "metadata": r'logger.info("Title \(metadata.title, privacy: .public)")',
        "destination": r'logger.info("Host \(connection.host, privacy: .public)")',
        "arguments": r'logger.info("Args \(arguments.joined(), privacy: .public)")',
        "error": r'logger.error("Failure \(error.localizedDescription, privacy: .public)")',
    }
    for label, source in prohibited.items():
        findings = validate_fixture(source)
        assert len(findings) == 1, f"{label} public interpolation was not rejected"

    print("logger privacy validator self-test passed (safe plus 7 prohibited categories)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
