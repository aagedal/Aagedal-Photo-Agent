# Verified delivery upload validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 verified-artifact admission, upload lifecycle, remote evidence, and resumability

## Implemented contract

- `DeliveryVerifiedStagedBatch.validated` admits only a completed staging result whose ordered
  items are verified against every controlled field, have no mismatch/failure, match the plan and
  stage fingerprints, remain safe children of the staging directory, and carry SHA-256/size from
  the exact read-back-verified bytes.
- Unrelated-metadata status labels are not trusted by themselves. Every claimed preservation match
  must retain equal lowercase SHA-256 semantic identities, while explicitly unsupported domains
  must carry no fabricated identity; malformed persisted evidence is refused before transport.
- Before any transport call and again at each file boundary, the coordinator inspects the current
  local file and requires the exact verified SHA-256 and byte size. Same-size replacement after
  metadata verification is refused before upload.
- Per-item lifecycle is queued, uploading, remote-confirming, sent, failed, or cancelled. Arbitrary
  transport errors never enter state, logs, or checkpoints.
- Protocol upload acknowledgement is separate from optional remote existence/size observation.
  Remote size matching is explicitly non-cryptographic and missing/size-mismatched remote objects
  fail the item.
- Cancellation is requested at file boundaries. An active transport/stat operation runs to a
  definitive result, after which queued items are cancelled and all staging files remain retained.
- Privacy-safe checkpoints contain no paths, filenames, credentials, or editorial values. Resume
  requires the same plan, staging batch, sequential sent prefix, stage fingerprints, current local
  SHA/size, and coherent acknowledgement timestamps.

## Test evidence

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-delivery-upload-tests-01' \
  -jobs 2 CODE_SIGNING_ALLOWED=NO \
  -only-testing:'Aagedal Photo Agent Tests/VerifiedDeliveryUploadCoordinatorTests'
```

Result: **8 tests passed in 1 suite** (`TEST SUCCEEDED`; 3.792 seconds cached test runtime).
Explicit PBX membership, PBX parsing, and scoped `git diff --check` passed.

## Remaining integration

- Add a production transport adapter that resolves credentials internally and preserves the
  coordinator's file-boundary cancellation contract. The current `FTPService` accepts a password
  at the call site and terminates curl mid-file, so adapting it would weaken both guarantees.
- Persist checkpoints atomically and project lifecycle into Activity/Deadline UI.
- Assemble and record a receipt only after terminal staging/upload evidence is revalidated.
