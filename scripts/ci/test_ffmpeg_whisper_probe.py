#!/usr/bin/env python3
"""Reject misleading success evidence in the real-process Whisper probe."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import probe_ffmpeg_whisper as probe


class WhisperProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.transcript = self.directory / "output.json"

    def test_empty_silence_is_valid_but_missing_output_is_not(self):
        with self.assertRaisesRegex(ValueError, "did not create"):
            probe.validate_transcript(self.transcript, 5000)
        self.transcript.write_text("")
        self.assertEqual(probe.validate_transcript(self.transcript, 5000), 0)
        with self.assertRaisesRegex(ValueError, "no non-marker"):
            probe.validate_transcript(self.transcript, 5000, require_text=True)

    def test_marker_is_not_speech_but_embedded_literal_is(self):
        self.transcript.write_text('{"start":0,"end":5000,"text":" [BLANK_AUDIO]"}\n')
        with self.assertRaisesRegex(ValueError, "no non-marker"):
            probe.validate_transcript(self.transcript, 5000, require_text=True)
        self.transcript.write_text('{"start":0,"end":5000,"text":"say [BLANK_AUDIO]"}\n')
        self.assertEqual(probe.validate_transcript(self.transcript, 5000, require_text=True), 1)

    def test_rejects_noncanonical_and_unbounded_records(self):
        for record in [
            '{"start":0,"end":5001,"text":"x"}',
            '{"start":-1,"end":0,"text":"x"}',
            '{"start":2,"end":1,"text":"x"}',
            '{"start":0.0,"end":1,"text":"x"}',
            '{"start":false,"end":1,"text":"x"}',
            '{"start":0,"end":1,"text":null}',
            '{"start":0,"end":1,"text":"x","extra":0}',
            '{"start":0,"end":1,"text":"x","start":0}',
            '[]', '\n', '{"start":0,"end":1,"text":"bad\x01control"}',
        ]:
            with self.subTest(record=record):
                self.transcript.write_text(record)
                with self.assertRaises(ValueError):
                    probe.validate_transcript(self.transcript, 5000)

    def test_preserves_unicode_escaping_empty_text_and_zero_length(self):
        self.transcript.write_text('{"start":0,"end":0,"text":""}\n'
                                   '{"start":0,"end":5000,"text":" 你好\\n\\\"x\\\""}\n')
        self.assertEqual(probe.validate_transcript(self.transcript, 5000), 2)

    def test_option_names_must_be_real_declarations(self):
        options = "Filter whisper\n" + "\n".join(f"   {name} <string> ..F" for name in probe.OPTIONS)
        probe.validate_options(options)
        with self.assertRaisesRegex(ValueError, "options missing"):
            probe.validate_options("Filter whisper\n" + " ".join(probe.OPTIONS))

    def test_failure_probe_rejects_crash_success_and_unrelated_error(self):
        for returncode, output in [(0, b"expected"), (-9, b"expected"), (1, b"unrelated")]:
            with self.subTest(returncode=returncode, output=output):
                with patch.object(probe.subprocess, "run", return_value=
                                  subprocess.CompletedProcess([], returncode, b"", output)):
                    with self.assertRaisesRegex(ValueError, "controlled failure"):
                        probe.process(Path("ffmpeg"), self.directory, [], "negative", 1,
                                      expected_error="expected")

    def test_failure_probe_accepts_only_matching_positive_exit(self):
        with patch.object(probe.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 1, b"", b"expected")):
            result = probe.process(Path("ffmpeg"), self.directory, [], "negative", 1,
                                   expected_error="expected")
        self.assertTrue(result["passed"])

    def test_timeout_is_failure_and_retains_diagnostics(self):
        with patch.object(probe.subprocess, "run", side_effect=
                          subprocess.TimeoutExpired([], 1, output=b"out", stderr=b"err")):
            with self.assertRaisesRegex(ValueError, "timed out"):
                probe.process(Path("ffmpeg"), self.directory, [], "timeout", 1)
        self.assertEqual((self.directory / "timeout.log").read_bytes(), b"outerr")


if __name__ == "__main__":
    unittest.main()
