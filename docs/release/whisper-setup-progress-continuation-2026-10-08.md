# Whisper setup progress and stale refresh — 2026-10-08

Baseline: `441dd2f`, initially clean. This bounded continuation improves the
3.0 transcription Settings flow. The release remains **IMPLEMENTING**.

## Behavior

- Model installation and local artifact preparation now have distinct presentation
  phases. Settings switches from download progress to **Verifying transcription
  files…** while admitting the installed model and bundled executable.
- Cancellation immediately shows **Cancelling model setup…** and disables repeated
  cancellation until the owned task finishes. Cancellation during admission revokes
  a late receipt. Already installed weights retain removal/retry controls, without
  granting provider readiness.
- Progress accepts only finite values and never moves backward. Delayed transfer
  callbacks cannot alter progress during preparation, cancellation or a later request.
- A refresh captures its model generation before awaiting local inventory. Model
  changes and task cancellation during that await now refuse subsequent model
  lookup/admission. Previously an obsolete refresh could begin checking the newly
  selected model after its inventory request finished.

The existing download service still owns checksum verification, atomic installation,
path admission and partial-file cleanup. The new phase describes subsequent artifact
preparation; no new filesystem or execution authority is introduced.

## Verification

Focused regression cases cover model changes/cancellation during inventory loading,
finite monotonic progress, cancellation during noncooperative admission, late receipt
revocation and retained installed-model recovery controls. Adjacent suites cover the
download service and artifact admission.

The final focused run passes **65 tests / three suites**, zero failures, in
0.476 seconds (`focused-approved.xcresult`, `focused-approved.log`). Repository
validation and whitespace checks pass (`repository-final.log`). Existing test-host
`MDB_MAP_FULL` diagnostics remain separate from performance/storage qualification.

Build/test evidence is retained under ignored `build/continuation-model-setup/`.
The initial sandboxed invocation could not write normal compiler/package caches;
the approved invocation uses the existing pinned local SourcePackages cache with
automatic package resolution and updates disabled. The required ignored AuraFace
package was copied from the main checkout into this worktree. Package pins and
production model caches were not changed.

No new native UI, actual-model inference, GPU, distribution-signature or full-release
acceptance evidence is claimed by this continuation. Those gates remain in the
owning implementation plan.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-model-setup \
  -clonedSourcePackagesDirPath /Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/ManagedWhisperSetupModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDownloadServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FFmpegWhisperArtifactAdmissionServiceTests' \
  -resultBundlePath build/continuation-model-setup/focused-approved.xcresult
scripts/ci/validate_repository.sh
git diff --check
```
