# Video still and dictation filesystem continuation — 2026-10-16

This continues phase 3.1 of the [app improvement audit](app-improvement-audit-plan.md)
on baseline `1efca5a` with the implementation/test changes described below in the working
tree during validation. State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Changes

Video still destination collision checks, JPEG/TIFF ImageIO encoding, JXL parsing,
provenance insertion, exclusive publication and temporary-file removal now use a retained
serial Dispatch actor. The original extraction task retains cancellation and task-local
context across the filesystem boundary, including after FFmpeg suspension. JXL still uses
the source video and actual presentation timestamp directly, preserving high-bit-depth
extraction. Destination probes are advisory; exclusive creation remains the final protection
against competing writers. Cancellation stops uncommitted work. A completed publication
returns success before cancellation is considered for the next marker, preserving saved-prefix
accounting and remaining markers after partial failure.

Microphone dictation creates its private workspace, streams the Whisper SHA-256/byte count
in 1 MiB chunks and removes temporary audio on another retained Dispatch actor. Cancellation
after directory creation transfers ownership to the model before its cancellation check.
The model keeps its busy slot until teardown drains, refusing replacement recording or
language installation during cleanup. Recognition/provider work retains the audio until it
returns; cancelled tasks still remove their workspace. The existing best-effort deletion
behavior and native AVAudioRecorder boundary remain. This does not establish that every
recording framework call or application filesystem path is free of main-thread work.

One sub-agent implemented the video slice. A separate sub-agent reviewed both slices and
investigated the next authenticated face-review boundary. No blocking review findings remain.

## Verification

Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0, build 742.
Fixtures are disposable generated image/audio bytes under the temporary directory and the
existing generated video corpus in `Aagedal Photo Agent Tests/Fixtures/Video`.

Verification uses the development package caches and
`/private/tmp/aagedal-settings-search-build`. Ignored pinned AuraFace and web runtime
resources were copied from the main checkout with `ditto`; they are not source changes.
The first restricted Xcode invocation could not write package/compiler caches. The permitted
normal-cache invocation uses the development signing configuration.

Focused command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/VideoStillFilesystemExecutorTests' \
  -only-testing:'Aagedal Photo Agent Tests/VideoTimecodeTests' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptionDictationStorageTests' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptionDictationLanguageTests' test
```

Focused regressions cover executor/task-local context, JPEG/TIFF captions, filename
collisions and competing publication, cancellation and partial prefix preservation, JXL
cleanup after extractor failure/suspension, exact 16-bit JXL samples/provenance, private
workspace permissions, multichunk hash/size, cancelled creation/reading and cancelled teardown.
A gated model test cancels after physical workspace creation, blocks cleanup and proves
that the UI can run while new recording/language work remains refused until removal drains.

The focused run passed **20 tests in four suites**, zero failures/skips, in 0.630
seconds of Swift Testing runtime. Console: `/private/tmp/aagedal-media-io-focused.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_00-38-14-+0200.xcresult`.
The integrated run uses the same command configuration with no `-only-testing` arguments.

The final integrated run passed **4,171 total tests in 404 suites**: 4,169 passed,
zero failures and the two existing opt-in Sony fixture skips. Swift Testing runtime was
150.322 seconds; the result summary reports zero runtime warnings. The 10,000-file rename
benchmark reports 4.066 seconds and 63.1 MiB resident growth. Existing `MDB_MAP_FULL` console
messages remain; neither focused nor integrated console recorded Main Thread Checker or
Thread Performance Checker messages. This does not establish application-wide warning
remediation or performance qualification.

Integrated console: `/private/tmp/aagedal-media-io-integrated.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_00-46-16-+0200.xcresult`.
Summary: `/private/tmp/aagedal-media-io-integrated-summary.json`.

Repository validation passed with temporary compiler caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-media-io-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-media-io-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-media-io-repository.log`.

Project property-list lint and bundled model validation pass. Final deep/strict development
signature verification passes with normal certificate access. Its initial restricted invocation
reported `CSSMERR_TP_NOT_TRUSTED`; the permitted normal-access retry passed. Model evidence:
`/private/tmp/aagedal-media-io-model-bundle.log`; signature console:
`/private/tmp/aagedal-media-io-signature.log`. Final `git diff --check` passed.

## Next authenticated face-review implementation

The current helper `prepare_face_scan` returns a read-only snapshot, without retaining an
intent. A helper-generated UUID cannot name an app-local retained intent. The existing
IPTC request archive also hardcodes purpose and operation evidence and cannot safely gain
face behavior by adding a purpose enum alone.

The next complete slice needs a dedicated bounded, checksum-protected durable face review
request archive. Freeze canonical request ID/epoch, folder/root identity, normalized options,
original inventory revision/count, preparation/expiry times and an immutable intent digest.
Exact retries return original evidence; conflicting IDs, stale epochs, corrupt records,
changed authorization/inventory and expired requests refuse. Cancellation-only cleanup must
rotate the epoch so retired requests cannot replay.

Extend the authenticated invocation channel with review-only ID/epoch presentation. Revalidate
both before and after main-actor handoff, then explicitly adopt a new app-local session intent
bound to the original durable request and capped by its original expiry; never renew the
300-second window through recapture. Preserve a verifiable original monotonic lifetime across
process handoff, or refuse when its witness is lost; wall-clock expiry alone must not allow
repeated adoption under a frozen clock. Presentation must grant no scanner execution or consent.
Before connecting a start action, implement one-way durable admission and exact reserved
operation/owner linkage. Descriptor-anchored scanner effects remain required before helper
execution is exposed.

## Remaining qualification

Native video/dictation interaction, actual microphone/provider teardown, real local/network/
iCloud/read-only-volume latency, memory/Instruments, accessibility and distribution packaging
remain open. Automated correctness and executor checks do not close those release gates.
