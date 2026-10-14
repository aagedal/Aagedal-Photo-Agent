# Web import empty-download continuation — 2026-10-14

This continuation closes the empty web-download success behavior identified in the
[Caption and web import async continuation](plan-status-caption-web-import-async-continuation-2026-10-14.md).
The broad audit remains 66 of 75; no release qualification gate is closed.

## Changes

A downloader response containing no completed media files fails before creating the
Working directory or publishing metadata/provenance records. Previously, the service
returned a Working path even when cleanup had removed the entire empty batch, causing
the import sheet to offer an unavailable folder as a successful import.

The existing filesystem worker performs cleanup before the error reaches the caller.
Empty batches are removed; partial originals and their post inspection record remain
available for recovery. Cancellation is checked first, so a cancelled empty response
retains the cancellation outcome. Nonempty JPEG/video imports retain their existing
copy verification, metadata read-back and original-preservation behavior.

## Verification

Regression coverage exercises empty results with and without a partial download,
checks that working-copy/metadata/provenance operations never begin, verifies retained
original bytes and post inspection evidence, and checks cancellation precedence.

The regression-first baseline failed both empty-result cases with five recorded
issues: premature Working creation, successful return and a retained empty Working
directory. Cancellation and existing JPEG/video imports passed on the baseline.
Baseline bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_13-49-49-+0200.xcresult`.

After the guard was added, both web import suites passed **11 tests in two suites**
(including both parameterized empty-result cases), zero failures/skips, in 0.715
seconds of Swift Testing runtime. Exact command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/WebMediaImportTests' \
  -only-testing:'Aagedal Photo Agent Tests/WebImportFilesystemExecutorTests' test
```

Focused result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_13-55-35-+0200.xcresult`.
Console evidence is retained at `/private/tmp/aagedal-web-empty-baseline.log` and
`/private/tmp/aagedal-web-empty-focused.log`.

`scripts/ci/validate_repository.sh` passed; `git diff --check` passed. Repository
validation evidence is `/private/tmp/aagedal-web-empty-repository.log`. The initial
sandboxed Xcode attempt could not write existing dependency/compiler caches; the
normal-cache rerun completed. Reviewed ignored AuraFace and web downloader resources
were copied from the main checkout for the build; they are not source changes.
Existing `MDB_MAP_FULL` observations remain in the focused console log. No full-suite,
native UI, independent-agent review or distribution-signing qualification is claimed.

## Remaining work

Real-server downloader behavior, native import-sheet acceptance, network/iCloud volume
performance, synchronous compatibility durability callers and the broader 3.0 release
gates remain open. This change does not require every selected item to appear in a
nonempty downloader result or establish recovery/resume of partial downloads.
