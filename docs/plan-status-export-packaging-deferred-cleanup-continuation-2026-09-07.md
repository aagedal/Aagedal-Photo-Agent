# Export packaging and deferred cleanup continuation — 2026-09-07

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete and delivery remains **119 of 142**. Broad async storage,
manual, hardware, and distribution gates remain open.

- Keyword exports copy selected managed files without suspension on the shared filesystem
  actor. A separate packaging actor owns manifest creation, compression, atomic destination
  replacement, and private staging cleanup. Managed edits can proceed during compression
  without changing the captured export. Destination security-scoped access spans the whole
  awaited operation. Cancellation and errors before replacement preserve an existing archive;
  durable success remains explicit when cancellation arrives after replacement.
- Known People imports remove deferred thumbnails on the serialized archive actor instead
  of MainActor. Destination reservations remain held through cleanup. Deletions arriving
  during cleanup drain in subsequent batches; peer and owner thumbnail caches invalidate
  after removal. Cleanup completes on cancellation/failure, and cancellation and storage
  revision are checked again after the new suspension before returning success. Deletion
  remains best-effort, matching the existing void deletion API.

One sub-agent implemented Known People cleanup and its regression cases. The parent implemented
export packaging, reviewed the new suspension boundaries, requested the post-cleanup cancellation
and storage-revision checks, and ran integrated validation.

## Validation

The focused archive staging suite passed **2 tests in 1 suite**, containing five parameterized
cases: blocked extraction success/cancellation and blocked compression success/cancellation/failure.
While compression is blocked, a managed edit completes; compression still observes the original
captured list. Cancellation and failure preserve the previous destination bytes, and every case
removes private staging and adjacent temporary archives. Existing round-trip tests exercise real
`ditto` packaging. The Known People reservation test now covers eight same/cross-instance cases,
including cancellation during commit, cancellation during cleanup, and storage-revision change
during cleanup; it checks off-main removal, continued write exclusion, a second deletion batch,
and successful writes after reservation release.

The final application/test build succeeded and the unfiltered suite passed **2,217 tests
in 258 suites**, zero failures, in **68.317 seconds** of Swift Testing execution.
Repository validation and `git diff --check` also passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:'Aagedal Photo Agent Tests/KeywordListsSharedFilesystemTests'
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-export-packaging-tests.log`,
`/private/tmp/aagedal-packaging-cleanup-full-tests.log`, and
`/private/tmp/aagedal-packaging-cleanup-repository.log`. The first sandboxed build could not
write compiler/package caches; the successful builds used approved access to existing caches.
An initial repository check caught trailing whitespace in the in-progress Known People changes;
it was removed before the successful repository validation. Automated evidence does not replace
manual, real-volume, device, or production-server checks.

## Remaining work

1. **Known People async ownership:** database/root loading, migrations, ordinary CRUD,
   conflict/tombstone maintenance, clearing, ordinary thumbnail writes/deletions, and deferred
   event replay still contain synchronous MainActor filesystem work. Imports still use a
   process-wide FIFO, and cleanup retains the existing best-effort error policy.
2. **Keyword routing and transactions:** routing reconciliation and MainActor preference/cache
   publication remain separate; captured requests can commit to an older root. Snapshot copying
   still occupies the shared actor, though compression no longer does. In-process serialization
   does not provide cross-process/cloud-device atomicity.
3. **Performance and interaction:** agree hardware/budgets; measure local/network/iCloud-
   placeholder/read-only/large-folder responsiveness; collect Thread Performance Checker,
   RAW/HDR Instruments, long-running GPU/cancellation, multi-display, accessibility, IME,
   localization, contrast, Reduce Motion, permissions, and runtime privacy evidence.
4. **Recovery and external gates:** real upgrade/downgrade, backup/restore, crash-interruption,
   protected release-branch CI, Known People privacy/legal review, and real FTP/FTPS/SFTP
   certificate, host-key, and failure drills.
5. **Model and release gates:** supported-macOS production-server install/offline/update/
   rollback/removal/relaunch/interrupted/corrupt-download drills and signed/notarized distribution.
   The unsigned model-free candidate remains tied to its earlier recorded source revision.
   The conditional AI-origin analyzer requires model/license/corpus decisions and product approval.
