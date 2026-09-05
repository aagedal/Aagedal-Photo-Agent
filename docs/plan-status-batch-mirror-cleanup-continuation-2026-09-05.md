# Plan-status batch mirror and refresh cleanup continuation — 2026-09-05

## Scope and result

This continuation advances Phase 3.1. The audit remains at 66 of 75 completed substeps;
its broad filesystem inventory and real-volume gates remain open.

Metadata batch embedded-write mirroring now obtains its ordered existence preflight from a
cancellable actor. The preflight is an optimization only: each serialized XMP transaction rechecks
existence, including on revision retries, and does not recreate an externally deleted sidecar.
The view model no longer reads XMP records to preserve Develop settings or orientation. Camera Raw
remains untouched by the descriptive transaction, and missing embedded orientation is filled from
the current XMP revision within that transaction. An explicit embedded orientation still wins.

Post-processing refresh now deletes unneeded app JSON sidecars through a serialized conditional
transaction. It rechecks both current and legacy filenames under the existing photo lock and only
removes records without pending changes or history. Unreadable, newer-schema, and mismatched-source
records are retained. Content tokens are compared immediately before deletion and changes trigger
an eligibility retry, preventing observed newer history or pending edits from being deleted based
on the refresh's older snapshot. Pre-cancellation prevents entry; admitted work retains the
coordinator's existing run-to-completion behavior. As with the existing filesystem transactions,
external processes do not share the app lock, so revision checks cannot provide an OS-level
compare-and-delete guarantee against changes in the final check-to-removal interval.

## Validation

Ten added tests cover off-main ordered preflight, cancellation before/during preflight, Camera Raw
and orientation preservation, latest-revision orientation fallback, deletion after preflight,
off-main JSON cleanup, absent-sidecar no-op, revision retry after new pending edits/history,
legacy/unreadable/newer-schema preservation, and pre-cancelled cleanup.

The sub-agent implemented and reviewed the mirror slice and independently reviewed the conditional
cleanup change. The initial combined build caught a synchronous deletion helper inheriting MainActor;
that pure filesystem helper is now explicitly nonisolated. A newer-schema test fixture was corrected
to set the JSON schema field directly because the model encoder intentionally writes the current
schema. The mirror suite was moved into an existing test source after checking execution counts
revealed that its initial standalone file was not registered in the Xcode test target.

Validation completed:

- Focused cleanup and descriptive-boundary selection: 47 tests in two suites passed.
- Final serial unfiltered run, including the registered six-test mirror suite: 2,048 tests in
  235 suites passed with zero failures in 64.952 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

Final full-run command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_20-18-46-+0200.xcresult`
in Xcode DerivedData. The complete log is `/private/tmp/aagedal-metadata-continuation-final-tests.log`;
repository validation is `/private/tmp/aagedal-metadata-repository-validation.log`.
Automated results do not substitute for the manual and real-volume gates below.

## Remaining work

Metadata full-record batch XMP and JSON baseline read-modify-write paths, explicit discard/folder
sidecar deletion, and post-write deletion still require complete transaction-owned async boundaries.
Known People database cache-miss/reload migration and shared Compare/Analysis rename identity
preparation remain open. The broad filesystem gate still needs local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence.
Phase 3.2 retains its representative RAW/HDR Instruments benchmark.

Other release gates remain protected-release-branch enforcement, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace
model-omitted release candidate plus supported-macOS production-server install/offline/update/rollback/
removal/interrupted-or-corrupt-download drills. Production model publication was already completed;
this session does not repeat or claim those external validation passes.
