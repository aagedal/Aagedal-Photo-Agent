# Cycle 11: verified Write All completion

Implementation `8fd931c54b9134005d7293118bb1db3fe9242d9b` passes independent review,
focused and integrated tests, and the bounded native cases below. No release readiness claim.
The separate [native Review recovery report](cycle-11-review-recovery-native-2026-09-11.md)
uses the previous unchanged binary.

## Problem and implementation

The previous Write All path called a Void embedded writer that skipped RAW, then deleted pending
JSON and counted success. Existing XMP could also shadow an embedded write. The replacement uses
strict owned-record discovery, fresh per-photo credential facts, immutable captured requests and
verified full editorial completion. RAW routes to XMP; embedded formats mirror existing XMP.
History, unknown JSON and explicit nil original snapshots remain retained. Outcomes distinguish
completed, skipped, failed, cancelled and physically partial writes, including undispatched items.
Independent batch details remain accessible when the selected editor changes.

## Validation record

The first focused test build compiled successfully. 38 tests across four suites ran in 1.337s;
37 passed and the strengthened embedded/XMP mask-preservation case failed before physical writes.
The failure exposed fresh mask UUIDs created by each XMP parse: model equality falsely rejected
an unchanged carrier. The correction uses the already-read exact XMP byte snapshot for
Write All admission, retaining parseability and exact carrier-change rejection. Existing technical
callers keep their prior contract. A twelfth service test rejects changed bytes and an explicitly
absent expectation against an existing sidecar, preserving both JSON and XMP. No test assertion
was suppressed. Independent final review passes the snapshot semantics, strengthened technical
fixtures and independent batch-attention UI. Focused v2 adds MetadataEditorReadServiceTests for
existing pending-orientation admission. Focused v2 passes **91 tests / 5 suites in 4.622s**.
Log: `/private/tmp/aagedal-coordinator-cycle11-focused-v2.log`. Integrated checks pass **2,602 tests / 288 suites in 94.961s**.
Repository validation and whitespace checks pass. Logs: `/private/tmp/aagedal-coordinator-cycle11-full.log`
and `/private/tmp/aagedal-coordinator-cycle11-repository.log`.

Command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests'
-configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO`, with whole-suite
selectors for PendingMetadataWriteServiceTests, PendingMetadataWriteCallerTests,
MetadataReplayIntentTests and MetadataSidecarMirrorTests.
Log: `/private/tmp/aagedal-coordinator-cycle11-focused.log`.

## Native fixtures and remaining verification

Prepared disposable `build/qa-write-all-cycle11/photos` from existing generated QA PNGs and owned
JSON/XMP. Known/null originals, opaque JSON, old shadowing XMP, explicit label clear and a third
photo with an empty XMP directory obstruction are included. `fixture-origin.json` identifies all
initial hashes; `before-native-snapshot.json` records parsed values and pixel hashes. Native testing below uses the full-suite binary for this implementation. The synthetic RAW routing unit fixture uses an
injected source-facts seam and does not establish real camera RAW compatibility.

## Native verification — PASS for the bounded cases

Identity: Debug 3.0.0 (738), arm64, macOS 27.0 (26A428), built from `8fd931c` with only
coordinator documentation dirty. App path:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
`build/qa-write-all-cycle11/tested-binary-identity.json` records the complete identity. SHA-256:

- Executable: `9bf1505da2afcd1e055d5ca2a4725b6ca017f36ea89c3880e0d2fff3a978e6f2`
- Debug dylib: `64ee4e5c944f92602b3a3dcce722bfe613b7026fe85dc18bad0f65d3cd0ea582`
- Preview dylib: `98fe7a860d7c4c0785e1e48bd936fd313490aed88f4f580bcd2de70e2588cfe0`

1. Launched the full-suite app and opened the disposable photos folder. Browser showed all three
   photos pending, rating four, label None. Clicked Write All Pending.
2. Native selectable/scrollable details reported **wrote 2, skipped 0, failed 1**, with the full
   folder and c-obstructed photo path. The error was visible in an inline screenshot. Read-back
   proved A/B embedded and existing XMP headlines equal W11 and both physical labels empty.
   A/B JSON remained present with pending=false; C JSON and PNG were exactly unchanged/pending.
   All three original snapshots, history counts (two each), opaque QA objects and pixel hashes
   remained unchanged. Known A and null B originals were preserved.
3. Dismissed the report and selected b-null. Its new headline displayed. Write All Details remained
   available and reopened the exact original report independently of the selected editor.
4. Removed only the empty `c-obstructed.xmp` directory. Retried Write All while B remained selected.
   The success was quiet, details action cleared, and C's pending marker disappeared. C embedded
   headline/label now matched its full pending record. C JSON stayed present/pending=false with
   original/history/opaque values retained. No unnecessary C XMP was created. Every A/B artifact
   remained byte-identical to the first successful write; already-completed photos were not rewritten.
5. Quit normally and confirmed all QA app entries stopped in native inventory. Relaunched the same
   binary, reopened the folder and selected C: all pending markers remained cleared and its W11
   headline displayed. Inline screenshot confirmed the final UI. Complete artifact snapshots equal
   the post-retry state exactly; all three executable hashes still match the identity manifest.
6. Quit normally again. Final native inventory confirms all Aagedal Photo Agent entries stopped.
   No write preferences changed; the temporary obstruction is removed. Other applications were
   not operated. Screenshots were observed inline, not saved as standalone files.

Evidence under `build/qa-write-all-cycle11`: `before-native-snapshot.json`,
`after-partial-snapshot.json`, `after-retry-snapshot.json`, `after-quit-snapshot.json`,
`after-relaunch-snapshot.json`, `fixture-origin.json`, and `tested-binary-identity.json`.
The snapshots include complete artifact hashes, pixel-payload hashes, metadata, originals and
history counts; additional assertions checked the retained opaque JSON objects.

## Remaining scope

Real camera RAW, credential-protected files, native cancellation during an admitted write,
large-folder performance, and native technical mask preservation still require their own observed
coverage. Unit coverage of synthetic routing, injected cancellation and physical technical values
is not substituted for those cases. Existing non-Write-All technical callers still use parsed
cameraRaw equality; the fresh-mask-ID behavior should be inventoried there separately.

Variable-writer folder/mode/partial-acknowledgement and early-success defects remain the next
mandatory implementation slice; its concrete semantics/ownership proposal is in the
[field-write design](field-write-completion-design.md). HTML case A17 now provides complete Write
All setup, numbered steps, expected outcomes and cleanup, with results initially unrun and no
final candidate assigned. Sixty authoritative criteria remain open. No release was published.
