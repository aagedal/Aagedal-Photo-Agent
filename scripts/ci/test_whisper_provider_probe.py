#!/usr/bin/env python3
"""Keep real-production provider qualification evidence strict and text-free."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import probe_whisper_provider as probe


class WhisperProviderProbeTests(unittest.TestCase):
    def positive(self, mode="cpu-explicit"):
        return {"name": mode, "passed": True, "segments": 1,
                "requestedLanguage": "auto" if mode == "cpu-auto" else "en",
                "exactProvenanceValidated": True, "provenanceRoundTripValidated": True,
                "authorizationCalls": 2}

    def test_speech_requires_identity_provenance_round_trip_and_reauthorization(self):
        for mode in ("cpu-explicit", "cpu-auto", "gpu-opt-in"):
            probe.validate_case_report(self.positive(mode), mode)
        for field, value in (("passed", False), ("segments", 0), ("segments", True),
                             ("exactProvenanceValidated", False), ("authorizationCalls", 1),
                             ("provenanceRoundTripValidated", False), ("requestedLanguage", "auto")):
            with self.subTest(field=field):
                report = self.positive()
                report[field] = value
                with self.assertRaises(ValueError):
                    probe.validate_case_report(report, "cpu-explicit")

    def test_rejects_unrecognized_or_transcript_bearing_fields(self):
        for field in ("text", "provenance", "stderr", "refusal", "observedRealChildReaped"):
            with self.subTest(field=field):
                report = self.positive()
                report[field] = "recognized words"
                with self.assertRaisesRegex(ValueError, "unexpected fields"):
                    probe.validate_case_report(report, "cpu-explicit")

    def test_negative_cases_require_the_precise_expected_error(self):
        for mode, refusal in (("no-speech", "noSpeech"), ("timeout", "timedOut"),
                              ("changed-audio", "identityMismatch"),
                              ("changed-model", "identityMismatch"),
                              ("changed-executable", "identityMismatch")):
            report = {"name": mode, "passed": True, "refusal": refusal}
            probe.validate_case_report(report, mode)
            report["refusal"] = "unrelatedFailure"
            with self.assertRaisesRegex(ValueError, "wrong refusal"):
                probe.validate_case_report(report, mode)

    def test_cancellation_requires_observed_real_child_reaped(self):
        report = {"name": "cancellation", "passed": True, "refusal": "cancelled",
                  "observedRealChildReaped": True}
        probe.validate_case_report(report, "cancellation")
        report["observedRealChildReaped"] = False
        with self.assertRaisesRegex(ValueError, "real child"):
            probe.validate_case_report(report, "cancellation")

    def test_revocation_must_be_observed_after_inference_authorization(self):
        report = {"name": "authorization-revoked", "passed": True,
                  "refusal": "authorizationRevokedAfterInference", "authorizationCalls": 2}
        probe.validate_case_report(report, "authorization-revoked")
        report["authorizationCalls"] = 1
        with self.assertRaisesRegex(ValueError, "reauthorization"):
            probe.validate_case_report(report, "authorization-revoked")

    def test_error_declaration_is_exact_slice_not_reimplemented(self):
        text = (probe.ROOT / probe.ERROR_SOURCE).read_text()
        declaration = probe.error_declaration(text)
        self.assertTrue(declaration.startswith("nonisolated enum VoiceMemoTranscriptionError:"))
        self.assertTrue(declaration.endswith("\n}\n"))
        self.assertIn(declaration, text)
        self.assertNotIn("VoiceMemoTranscriptionService", declaration)
        self.assertIn("case noSpeech", declaration)

    def test_watchdog_and_nonzero_exit_cannot_be_passing_cases(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                process = MagicMock(pid=12345, returncode=1)
                process.communicate.side_effect = ([subprocess.TimeoutExpired([], 1), (b"", b"")]
                                                   if timeout else [(b"", b"")])
                with patch.object(probe.subprocess, "Popen", return_value=process), \
                        patch.object(probe, "stranded_children", return_value=[]), \
                        patch.object(probe.os, "killpg") as kill:
                    with self.assertRaisesRegex(ValueError, "deadline" if timeout else "harness failed"):
                        probe.execute_case(Path("probe"), {"mode": "cpu-explicit"}, directory, 1)
                    self.assertEqual(kill.called, timeout)

    def test_stranded_process_is_failure_and_gets_killed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            process = MagicMock(pid=12345, returncode=0)
            process.communicate.return_value = (b"{}", b"")
            with patch.object(probe.subprocess, "Popen", return_value=process), \
                    patch.object(probe, "stranded_children", return_value=[12346]), \
                    patch.object(probe.os, "kill") as kill:
                with self.assertRaisesRegex(ValueError, "stranded an FFmpeg child"):
                    probe.execute_case(Path("probe"), {"mode": "timeout"}, directory, 1)
                kill.assert_called_once_with(12346, probe.signal.SIGKILL)

    def test_job_directory_is_failure_even_after_successful_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            process = MagicMock(pid=12345, returncode=0)
            def complete(timeout):
                (directory / "jobs/photo-whisper-leftover").mkdir()
                return b"{}", b""
            process.communicate.side_effect = complete
            with patch.object(probe.subprocess, "Popen", return_value=process), \
                    patch.object(probe, "stranded_children", return_value=[]):
                with self.assertRaisesRegex(ValueError, "stranded a private job"):
                    probe.execute_case(Path("probe"), {"mode": "timeout"}, directory, 1)


if __name__ == "__main__":
    unittest.main()
