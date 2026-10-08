# Whisper cancellation after model publication — 2026-10-08

Baseline: `5a1986a`, initially clean. This bounded continuation advances the 3.0
managed model lifecycle criterion. Release state remains **IMPLEMENTING**.

## Behavior

The download service verifies exact size/hash and atomically installs weights before
returning their URL. Cancellation can arrive after that publication but before
Settings receives the successful result. Settings previously checked cancellation
first, leaving the newly installed model presented as absent until a later refresh.

Settings now records installed presence, clears corrupt-model replacement state,
and updates the local picker inventory before checking cancellation. Cancellation
still prevents artifact admission and provider readiness. Retry Setup and Remove
remain available for the verified installed file. Obsolete model selections are
refused before any of this bookkeeping; no filesystem authority changes.

## Verification

The new deterministic regression uses the production download service with a small
hash-pinned disposable fixture for first installation and corrupt-weight replacement.
It pauses after atomic installation, cancels setup,
and verifies retained presence/removal controls, zero artifact admissions, no
provider, and successful explicit file removal. Existing cancellation coverage now
expects retained presence when a noncooperative transfer returns success. Adjacent
suites cover transfer cleanup, corrupt replacement and artifact admission.

Focused Xcode verification passes **66 tests / three suites**, zero failures, in
0.470 seconds (`focused-approved.xcresult`, `focused-approved.log`). Repository
validation and whitespace checks pass (`repository-final.log`).
Evidence is under ignored `build/continuation-published-model/`.

The initial sandboxed Xcode invocation could not write normal compiler/package
caches. The approved invocation uses existing pinned local SourcePackages with
automatic resolution and package updates disabled. The required ignored AuraFace
package was copied from the main checkout. Production weights and package pins
were not changed.

No native GUI, actual-model inference, GPU, signed-distribution or complete-release
acceptance is claimed. The broader lifecycle and release criteria remain open.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-published-model \
  -clonedSourcePackagesDirPath /Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/ManagedWhisperSetupModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDownloadServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FFmpegWhisperArtifactAdmissionServiceTests' \
  -resultBundlePath build/continuation-published-model/focused-approved.xcresult
scripts/ci/validate_repository.sh
git diff --check
```
