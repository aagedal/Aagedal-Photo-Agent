# Plan-status batch baseline and selected discard continuation — 2026-09-05

## Scope and result

This continuation advances Phase 3.1. The audit remains at 66 of 75 completed substeps;
its broad filesystem inventory and real-volume gates remain open.

Metadata full-record batch XMP and JSON saves now own baseline reads, captured mutation
application, revision checks, and atomic installation inside the per-photo asynchronous
transaction. JSON history is constructed against the latest record and retains its original
image snapshot. XMP retries replay the intended mutation against the latest descriptive and
Develop metadata. Existing unknown-field and newer-schema JSON protections remain in use.
Pre-cancellation prevents admission; admitted operations retain the coordinator's existing
run-to-completion contract. Batch supplier append/replace/clear intent is now included in
captured mutation application. Single-image XMP publication uses the actual captured saved record.

Selected-image discard now deletes through the same photo lock, waits for a preceding editor
save, reports failures, and only resets UI state after successful completion for the same
selection, load generation, draft, and batch mutation intent. Successful batch discard clears
cached common values and explicit mutation state so later edits cannot replay discarded intent.
The injected delete boundary and awaitable completion support deterministic interaction tests.

JSON and XMP remain separate artifact commits with existing partial-success semantics. Selected
discard across images or current/legacy filenames is also not an all-or-nothing transaction;
an error is reported and the editor is retained, but already completed removals remain durable.
External processes do not share the app lock, so revision checks cannot guarantee OS-level
compare-and-swap against changes in the final check-to-install interval.

## Validation

Eleven added tests cover off-main baseline reads and deletion; XMP and JSON external-revision
retries; latest JSON history/snapshot construction; absent-record fallback; pre-cancellation;
explicit supplier append/clear through both JSON and XMP; discard errors; stale draft, selection,
and batch-intent completion; batch cache reset; and cancellation after deletion admission.
All tests were added to existing registered test sources.

Two sub-agents implemented/reviewed the batch slice and reviewed/tested selected discard. Review
added batch intent/cache reset and waiting for prior saves. An initial integration compile caught
a missing escaping closure annotation. An intermediate focused build overlapped the cancellation
fix and was superseded by the frozen-source full runs. The first full run exposed supplier clear
being lost by XMP's nonempty-value merge; explicit supplier intent now overrides that merge inside
the transaction, including retries. The final unfiltered run passed.

Validation completed:

- Final serial unfiltered run: **2,059 tests in 236 suites passed**, zero failures, 60.268 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

Final full-run command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_20-42-27-+0200.xcresult`
in Xcode DerivedData. Full log: `/private/tmp/aagedal-batch-discard-final.log`.
Repository validation: `/private/tmp/aagedal-batch-discard-repository.log`.
Automated results do not substitute for manual and real-volume gates.

## Remaining work

Folder-wide discard and post-write sidecar deletion still require complete transaction-owned
async boundaries. Known People database cache-miss/reload migration and shared Compare/Analysis
rename identity preparation remain open. The broad filesystem gate still needs local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread
Performance Checker evidence. Phase 3.2 retains its representative RAW/HDR Instruments benchmark.

Other release gates remain protected-release-branch enforcement, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace
model-omitted release candidate plus supported-macOS production-server install/offline/update/rollback/
removal/interrupted-or-corrupt-download drills. Production model publication was already completed;
this session does not repeat or claim those external validation passes.
