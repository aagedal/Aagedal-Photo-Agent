#!/usr/bin/env python3
"""Verify installed qualification evidence parsing without launching an app."""

import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid

import probe_installed_native_review as probe


class InstalledNativeReviewProbeTests(unittest.TestCase):
    def setUp(self):
        self.request_id, self.epoch, self.operation_id, self.owner_id = [str(uuid.uuid4()) for _ in range(4)]

    def cases(self):
        cases = []
        for index in range(9):
            refused = index in (0, 2, 4, 5, 6)
            value = {"code": "native_review_unavailable" if index < 4 else "native_execution_unavailable"} if refused else {
                "status": "reviewRequired" if index < 4 else "executionRequested" if index == 7 else "linkedOperation",
                "operationID": self.operation_id if index == 8 else None,
                "requestID": self.request_id, "requestEpoch": self.epoch,
                "consentGranted": False, "executionStarted": False, "completionConfirmed": False,
                "directHelperExecutionAvailable": index >= 4, "nativeConsentConsumed": index == 7,
            }
            stdout = "\n".join(json.dumps(line) for line in [
                {"id": 1, "result": {}}, {"id": 2, "result": {"isError": refused, "structuredContent": value}},
            ])
            cases.append({"exitCode": 0, "stderr": "", "stdout": stdout,
                          "requestID": self.request_id, "requestEpoch": self.epoch})
        return cases

    def test_review_requires_four_closed_truthful_responses(self):
        cases = self.cases()[:4]
        self.assertTrue(probe.validate_results(cases))
        self.assertFalse(probe.validate_results(cases[:3]))

    def test_execution_requires_refusals_consumption_and_nonreplayed_link(self):
        cases = self.cases()
        self.assertTrue(probe.validate_results(cases, execution=True))
        self.assertFalse(probe.validate_results(cases[:8], execution=True))
        result = json.loads(cases[8]["stdout"].splitlines()[1])
        result["result"]["structuredContent"]["nativeConsentConsumed"] = True
        cases[8]["stdout"] = json.dumps({"id": 1, "result": {}}) + "\n" + json.dumps(result)
        self.assertFalse(probe.validate_results(cases, execution=True))

    def test_scheduling_cannot_claim_execution_or_completion(self):
        for field in ("executionStarted", "completionConfirmed"):
            with self.subTest(field=field):
                cases = self.cases()
                result = json.loads(cases[7]["stdout"].splitlines()[1])
                result["result"]["structuredContent"][field] = True
                cases[7]["stdout"] = json.dumps({"id": 1, "result": {}}) + "\n" + json.dumps(result)
                self.assertFalse(probe.validate_results(cases, execution=True))

    def write_archive(self, root, relative, records):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps({"schemaVersion": 1, "records": records}).encode()
        target.write_text(json.dumps({"payload": base64.b64encode(payload).decode(),
                                     "sha256": hashlib.sha256(payload).hexdigest()}))
        target.chmod(0o600)

    def evidence_fixture(self, root, owner_id=None):
        request = {"requestID": self.request_id, "requestEpoch": self.epoch, "state": "linked",
                   "admission": {"operationID": self.operation_id, "ownerID": self.owner_id}}
        operation = {"id": self.operation_id.upper(), "ownerID": (owner_id or self.owner_id).upper(),
                     "ownerLeaseManaged": True, "kind": "voice_transcription", "state": "completed",
                     "outcome": "verified", "batchProgress": {"items": [{"outcome": "draftSaved"}] * 2}}
        self.write_archive(root, "transcription-review-requests/operations.json", [request])
        self.write_archive(root, "transcription-review-operations/operations.json", [operation])
        drafts = root / ".photo_metadata"
        drafts.mkdir()
        for index in range(2):
            (drafts / f"{index}.meta.json").write_text(json.dumps({
                "voiceMemoTranscript": {"generatedText": "Synthetic review transcript"},
            }))
        return request

    def test_durable_summary_matches_exact_owner_and_link_without_transcript(self):
        with tempfile.TemporaryDirectory(prefix="installed-probe-schema-") as temporary:
            root = Path(temporary).resolve()
            request = self.evidence_fixture(root)
            evidence = probe.completed_operation_evidence(root, request)
            self.assertEqual(evidence["operationID"], self.operation_id)
            self.assertEqual(evidence["ownerID"], self.owner_id)
            self.assertEqual(evidence["draftSavedCount"], 2)
            self.assertFalse(evidence["captionApprovalGranted"])
            self.assertNotIn("Synthetic review transcript", json.dumps(evidence))

    def test_similar_completed_operation_with_wrong_owner_cannot_prove_link(self):
        with tempfile.TemporaryDirectory(prefix="installed-probe-schema-") as temporary:
            root = Path(temporary).resolve()
            request = self.evidence_fixture(root, owner_id=str(uuid.uuid4()))
            with self.assertRaisesRegex(probe.ProbeFailure, "completed_operation_linkage_mismatch"):
                probe.completed_operation_evidence(root, request)


if __name__ == "__main__":
    unittest.main()
