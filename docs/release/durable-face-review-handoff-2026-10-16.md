# Durable face review retention and authenticated presentation — 2026-10-16

This continues the [3.0 coordinator](coordinator.md) on baseline `28b47a0`.
State remains IMPLEMENTING. The broad improvement audit remains 66 of 75;
this continuation does not close scan execution or release qualification gates.

## Implemented boundary

A dedicated bounded, checksum-protected face review archive freezes original canonical
request ID/epoch, root/folder identity, normalized options, inventory revision/count,
preparation/expiry dates and immutable intent digest. It stores coordination evidence,
not consent. Exact retries preserve original evidence. Conflicting handles/options,
corrupt records and stale epochs refuse. An explicit internal cancellation-only capacity recovery API
rotates the submission epoch and preserves active records. No automatic eviction occurs.

The original five-minute lifetime starts before folder capture. A boot-session identity
and continuous Mach time witness survive process handoff and include system sleep.
Missing/replaced witnesses, backwards time, expiry and changed authorization/inventory
refuse fresh presentation, including with a frozen wall clock. Historical status remains
inspectable after expiry/cancellation and does not imply current authority or freshness.
Checksums detect corruption; they do not authenticate consent or prevent a same-user
archive rollback. No execution capability is derived from these records.

Five helper tools expose capacity, request retention, status, cancellation and native
presentation. The new authenticated socket kind carries only the original request ID and
epoch. It has no face-start variant. The running matching signed app revalidates the whole
inventory before and after UI handoff. Final publication checks the original lifetime;
generation invalidation and retirement of the bounded UI handoff waiter prevent that
queued handoff from publishing after its waiter expires. One in-flight face
validation slot remains occupied until timed-out background work drains. Existing
transcription review/start routes remain separate.

The synchronous initial inventory recapture is not cancelled by the socket's three-second
I/O deadline. It can finish and enqueue a still-fresh read-only review after the client
times out. Work remains bounded until it drains and the original expiry still applies.
This is not end-to-end timeout cancellation and must not be reused as an execution grant.

Automation settings displays original folder/options, exact immediate photo inventory,
request identity and expiry as literal text. Dismissal drops only presentation. The view
has no scanner/model initialization, consent toggle or Start action. Connecting durable
requests to the existing executable native face review would require one-way durable
admission and exact reserved operation/owner linkage first. Descriptor-anchored scanner
effects remain required before helper execution is exposed.

## Verification

Environment: macOS 27.0.1 (26A434), arm64, development app 3.0.0/build 742.
Source and tests were uncommitted during verification. Fixtures use generated disposable
image bytes and the existing isolated native helper qualification workflow; no user photos
or production automation configuration are needed.

The initial restricted Xcode invocation could not write existing package/compiler caches.
The normal-access retry uses the existing development signing configuration and caches.
An initial compilation began before the newly delegated view existed, so that incomplete
source discovery failed; the settled-source build is recorded below. Ignored pinned
AuraFace and web runtime resources were copied from the main checkout; the tracked web
bridge was restored to this baseline and is not a source change.

Focused regression passes **134 tests in five suites**, zero failures/skips, in
2.882 seconds of Swift Testing runtime. It covers archive bounds/corruption, exact retries,
relaunch, preparation-time expiry, frozen-clock/boot/lost-witness refusal, epoch rotation,
changed inventory/authority, helper argument/annotation contracts, presentation expiry,
retired/bounded handoffs and existing rooted face/channel behavior. Test-only fixture fixes
made the clocks explicitly nonisolated, accepted optional authorization data and used a
physical temporary path for the no-follow archive. Application safeguards were unchanged.

Focused command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanReviewRequestStoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/AutomationNativeFaceScanReviewInvocationServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/AutomationNativeInvocationChannelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPServerCoreTests' test
```

Focused console: `build/face-review-handoff/focused.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_19-06-00-+0200.xcresult`.
The complete integrated command uses the same configuration without `-only-testing`.

Repository validation passes with temporary compiler caches. Actual persistent-pipe helper
probing passes all **41 tools**, including strict face tool schemas and existing transport
recovery; its annotation oracle was extended for the new private coordination mutations.
Seven installed-probe parsing regressions pass. Model bundle validation and final
completed-app deep/strict development-signature verification pass. Verification during
an earlier active build saw temporarily unsigned/invalid sealed resources; the completed
artifact retry passed. Evidence: `build/face-review-handoff/repository.log`, `helper.json`,
`model.json`, and `signature.log`.

The integrated run passes **4,192 total tests in 407 suites**: 4,190 passed,
zero failures and the two existing opt-in Sony fixture skips. Swift Testing runtime is
160.366 seconds. The result summary reports zero runtime warnings; neither focused nor
integrated console records Main Thread Checker or Thread Performance Checker messages.
Existing `MDB_MAP_FULL` observations remain. The 10,000-file rename benchmark reports
4.091 seconds and 59.5 MiB resident growth. This does not establish application-wide
warning remediation or real-volume performance qualification.

Integrated console and summary: `build/face-review-handoff/integrated.log` and
`integrated-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_19-06-56-+0200.xcresult`.
Extracting its summary needed normal cache access for xcresulttool's report cache.

The first signed native run reached successful authenticated presentation but failed its
accessibility lookup: the container identifier propagated to all children. An explicit
containing accessibility element fixes the identifiers. The second run passes its UI
assertions and all four signed helper calls but fails qualification cleanup because forced
XCTest termination leaves an inert listener endpoint. The final test uses normal Quit,
matching the existing transcription qualification. No expired intent is renewed to retry;
each run creates a new disposable fixture and preserves its original evidence.

Final signed native qualification passes **one test**, zero failures/skips, in 23.412
seconds. Four actual bundled helper calls verify wrong-epoch refusal, exact original
inventory/options, dismissal/reopening with unchanged expiry and byte-identical request,
authorization, photo and WAV artifacts. The face view exposes only Dismiss, with no consent
checkboxes or scan action. Normal Quit releases the listener; the probe confirms complete
fixture cleanup, unchanged host preferences and no execution submitted/requested.

```sh
python3 -B scripts/ci/probe_installed_native_review.py --face-review \
  --app 'build/face-review-handoff/DerivedData/Build/Products/Debug/Aagedal Photo Agent.app' \
  --derived-data-path build/face-review-handoff/DerivedData \
  --result-bundle build/face-review-handoff/native-v3.xcresult \
  --log build/face-review-handoff/native-v3.log \
  --output build/face-review-handoff/native-v3.json
```

The isolated native build uses the same reviewed resources, development signing, and
two build jobs; it starts from a local clone of the test caches and rebuilds its own
artifacts. Its application executable SHA-256 is
`1790aa37e20ab19940332dc3646f6f9e89577aa719b74201852d086608b991f4`;
the paired helper is
`69fcef89f47075c318b41c397e085a18f3a0e3361857b01ae147f0b1934090e5`.
Exact final source/test/project hashes are in `build/face-review-handoff/source-sha256.json`.
The exact native-tested artifact passes 41-tool helper probing, model bundle validation
and deep/strict development-signature verification (`helper-final.json`, `model-final.json`,
`signature-final.log`). Native assertions qualify generated disposable fixtures and this
presentation path, not scanner execution, distribution signing/notarization or broad UI
and accessibility acceptance. The prior native result bundles/logs remain retained.

Independent review finds no blocking issue in the archive/integration or signed qualification
scope. It explicitly retains the initial synchronous recapture/socket-timeout limitation
above. Final integrated regression is repeated after the accessibility grouping change;
the final run passes **4,192 total tests / 407 suites**, with 4,190 passed, zero
failures and the same two Sony skips, in 142.216 seconds. Its summary reports zero runtime
warnings, and its console has no Main Thread Checker or Thread Performance Checker messages.
The rename benchmark reports 3.966 seconds and 59.6 MiB resident growth; existing LMDB
observations remain. Final source/test/project hashes match the recorded native candidate.
Console and summary: `build/face-review-handoff/integrated-final.log` and
`integrated-final-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_19-18-43-+0200.xcresult`.
Final repository validation, project plist lint and `git diff --check` pass. The final
repository console is `build/face-review-handoff/repository-final.log`.

## Next implementation

Native cancelled-request capacity maintenance is implemented in the
[following continuation](native-face-review-capacity-maintenance-2026-10-16.md). Implement a one-way durable face admission with exact reserved operation/owner linkage,
then explicitly adopt app-local review bound to the original durable request and original
expiry. Preserve the original continuous lifetime through every adoption; never recapture
a new five-minute window. Complete descriptor-anchored reset/thumbnail/document effects
before exposing helper execution. Native scanner/provider, real-volume performance,
accessibility and distribution qualification remain separate gates.
