# Staged delivery validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 bounded staging, metadata write, exact-byte read-back, and verification

## Implemented contract

- `StagedDeliveryCoordinator` revalidates the frozen plan, expected fingerprint, current profile,
  and every source before creating output, then rechecks each source immediately before rendering.
- An injected renderer-aware estimate—not source-file size guessing—must be valid and fit known free
  capacity before a unique batch directory is created.
- Items run sequentially through render/copy, descriptive metadata write, read of the actual staged
  bytes, and comparison of every controlled field through `IPTCMetadataVerifier`. The coordinator
  retains only one item's bytes at a time.
- After controlled-field read-back, each item must also carry an acceptable source-to-staged
  unrelated-metadata report. Semantic mismatch and unconfirmed/unknown reads fail closed; explicit
  unsupported carrier boundaries remain typed. C2PA carriage is reported separately from validity.
- A mismatch blocks batch completion. `stagedSHA256` is populated only after success and hashes the
  exact bytes supplied to read-back verification, binding the later uploader to verified content.
- Typed Codable progress/results use sanitized failure messages. Failure and cancellation retain
  verified and partial staging files; no path implicitly cleans them up.
- Explicit cleanup requires a coordinator token, canonical direct-child batch path, expected batch
  name, and lowercase hexadecimal plan fingerprint. The service never mutates originals or
  performs network work.

## Test evidence

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-delivery-staging-tests-01' \
  -jobs 2 \
  -only-testing:'Aagedal Photo Agent Tests/StagedDeliveryCoordinatorTests'
```

The original staging suite passed **7 tests with 15 parameterized cases**. After adding mandatory
preservation, an isolated build and combined preservation/staging run passed **17 tests in 2
suites**, including preservation mismatch, unconfirmed-read, and cancellation failures. The app
and full test target compiled; PBX parsing and `git diff --check` passed.

## Remaining integration

- Wire production render/copy, staged descriptive writer, exact-byte decoder/verifier, and output-
  size estimator adapters through the future Send workflow.
- Add a persisted staging/resume manifest and explicit user cleanup controls.
