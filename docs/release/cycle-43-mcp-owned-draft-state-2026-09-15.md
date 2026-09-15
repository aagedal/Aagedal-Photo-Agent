# Cycle 43 — owned metadata draft state in MCP revision inspection

**State:** IMPLEMENTING for 3.0. This advances the read-only metadata-state prerequisite; complete typed `get_photo_metadata` remains open.

## Behavior

- `inspect_photo_revision` now reports `appSidecarDraftState` as `absent`, `saved`, `pending`, `unsupported-schema`, or `unknown`, alongside the existing opaque source, XMP and owned-JSON tokens. It reads only an exact-owner Photo Agent JSON carrier through the cycle-42 root-anchored descriptors. No caption, transcript, history or other private JSON value is returned.
- The state follows the persisted `pendingChanges` flag and treats an orientation draft as pending, including schema-1 sidecars that use the legacy `version` key. A newer schema is reported as unsupported rather than interpreted as a saved draft. Missing or invalid state is `unknown`.
- Two current/legacy sidecars both claiming the photo are refused as ambiguous. Missing candidate files are rechecked before publication, and the private metadata directory must still be the same no-follow directory. Carrier post-read validation now also refuses a newly introduced hard link.
- This state does not establish effective IPTC source, field values, reconciliation or conflict. It cannot be used as authority for a mutation.

## Verification

Source baseline `3331e17` on `main`; cycle 42 was already present as an uncommitted continuation when cycle 43 began. Host: arm64 macOS 27.0, Xcode 27.0; development app 3.0.0 (738). All checks used the combined cycle-42/43 worktree.

- The focused MCP selection passed 16 executions, zero failures and zero skips at `build/qa-mcp-cycle43-focused.xcresult`. The final small directory/legacy-orientation adjustment came afterward, so the final-source complete suite below is authoritative.
- Final-source command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 -resultBundlePath build/qa-mcp-cycle43-final-full.xcresult -quiet`. It passed **3,769 executions, zero failures and zero skips**. The Xcode result metrics were read with `xcresulttool get object --legacy`; the test operation took 144.665 seconds.
- `scripts/ci/validate_repository.sh` and `git diff --check` passed against the final documentation-inclusive worktree. Disposable MCP fixtures cover absent, saved, pending, orientation-draft, newer-schema and foreign-legacy states; duplicate ownership and linked private storage are refused. No user photo or automation preference was changed. No real MCP client or native metadata workflow was exercised by this cycle.

## Beta and final-release distance

Beta still needs complete typed metadata reads, the production automation facade, guarded face/template/transcription and two-phase IPTC operations with status/cancellation, complete GUI/MCP admission, FFmpeg Whisper and model lifecycle, and real-client end-to-end evidence. The Phase 5A plan still has **26 unchecked criteria**. This cycle closes a narrow draft-state read prerequisite, not a complete Phase 5A workflow.

Final release additionally requires exact-candidate hardware, performance, accessibility, physical-volume and recovery checks; authentic Sony/cloud/server interoperability evidence; qualified privacy/legal and independent readiness reviews; protected CI; user acceptance; and signed/notarized distribution. The four authoritative plans still have **81 unchecked criteria** in total, including beta work, final verification and conditional/external gates. These counts describe scope, not a release percentage; no calendar date follows from this narrow implementation increment.
