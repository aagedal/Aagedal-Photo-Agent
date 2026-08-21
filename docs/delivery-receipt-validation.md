# Delivery receipt validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 privacy-preserving receipt model, persistence, retention, and summary

## Implemented contract

- The schema-v2 `DeliveryReceipt` records batch/profile/app identity and timestamps; source
  SHA-256/size without source name/path; delivered filename/SHA-256/size; every typed controlled
  `IPTCMetadataVerificationField` and identifier-only verification issues; actual renderer-reported
  facts; canonical lowercase destination UUID plus path; accepted warning IDs; and separate
  upload-protocol and remote-size-stat acknowledgements.
- The type cannot represent connection credentials or caption, person, location, or other editorial
  values. Human-readable summaries additionally omit filenames and hashes.
- `DeliveryReceiptRepository` atomically records, lists, reads, and manually deletes receipts with
  deterministic ordering, duplicate receipt/batch no-overwrite rules, and configurable count/age
  retention. An actor access gate spans complete transactions.
- Version-one documents migrate to schema two. Corrupt-primary backup recovery is supported, while
  top-level and nested future schemas fail closed. A future primary cannot be downgraded or
  overwritten through a valid older backup.
- Accepted warnings are stored once at batch scope. Item warning IDs are only the image-scoped
  subset, so list and summary counts cannot multiply a shared warning by the number of images.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-delivery-receipt-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/DeliveryReceiptRepositoryTests'
```

Result: **12 tests passed** and the app/test target graph—including the concurrent DeliveryPlan
foundation—compiled successfully. PBX parsing and `git diff --check` also passed.

## Follow-up validation

- Terminal assembly and Activity inspection are covered by the companion validation records.
- Define the product retention default and wire it to user-controlled settings; never add implicit
  iCloud synchronization.
