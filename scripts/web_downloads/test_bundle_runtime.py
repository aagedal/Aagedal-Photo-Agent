#!/usr/bin/env python3
"""Exercise strict runtime verification without downloading or signing artifacts."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("bundle_runtime.py")


class BundleRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.destination = self.root / "destination"
        executable = self.source / "bin/python3"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        (self.source / "runtime.json").write_text(json.dumps({"files": {
            "bin/python3": hashlib.sha256(executable.read_bytes()).hexdigest()
        }}))

    def bundle(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.source), str(self.destination)],
            env={**os.environ, "CODE_SIGNING_ALLOWED": "NO"}, capture_output=True, text=True)

    def test_finder_metadata_is_ignored_and_not_shipped(self):
        (self.source / ".DS_Store").write_bytes(b"Finder metadata")
        (self.source / "bin/.DS_Store").write_bytes(b"Finder metadata")
        result = self.bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / "bin/python3").is_file())
        self.assertEqual(list(self.destination.rglob(".DS_Store")), [])

    def test_unmanifested_runtime_file_is_rejected(self):
        (self.source / "bin/unreviewed.py").write_text("unreviewed content")
        result = self.bundle()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("file set differs", result.stderr)
        self.assertFalse(self.destination.exists())

    def test_modified_runtime_file_is_rejected(self):
        (self.source / "bin/python3").write_text("modified executable")
        result = self.bundle()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("artifact mismatch", result.stderr)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
