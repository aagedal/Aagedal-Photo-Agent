# Cycle 71 — Template editor conflict refusal

Baseline: `d3b0f73`, clean at start. Implementation is in the working tree.

Existing metadata and Develop template editors retain the typed snapshot originally opened.
Saving compares that snapshot with exactly one current matching UUID under the captured-root
in-process and process reservations. Changed, missing, unreadable and duplicate entries refuse
before shortcut reassignment or template writes. Failed saves keep the editable draft and
provide fixed, path-free guidance to reopen the latest template or Save as New. Reloading the
inventory does not authorize the open stale editor. New-copy saves retain their existing UUID
creation and explicit shortcut reassignment semantics.

This is deliberately a typed editor conflict check. It does not establish byte-level automation
store authority, capture unknown JSON members, bind the original storage root, or coordinate
external editors/iCloud peers that do not use process reservations. Imports, deletion and
non-editor compatibility save APIs retain their existing contracts. Stable template discovery
and guarded automated application remain open.

## Verification

Two parameterized regression tests exercise ten cases across metadata and Develop editors:
changed, removed, corrupt, duplicate and unchanged storage. Assertions cover exact original
and peer-file preservation on refusal, retained draft/error state, reload refusal, Save as New
recovery, successful unchanged-baseline saves and normal shortcut reassignment.
The existing filesystem-failure retry fixture now restores the original template before
retrying, rather than accidentally expecting a deleted existing template to be recreated.

The initial focused run passed 39 tests across two suites in 1.536 seconds. After the
fixed recovery-copy changes, the full final-source suite passed **3,031 tests across 319
suites**, zero failures, in 119.630 seconds. Repository validation and `git diff --check`
pass. Twelve Thread Performance Checker diagnostics and test-host `MDB_MAP_FULL` messages
remain observations; this change does not claim to resolve them.

Evidence: `build/qa-template-stale-focused-authorized.xcresult` and `.log`,
`build/qa-template-stale-full.xcresult` and `.log`, and
`build/qa-template-stale-repository.log`.
Host: arm64 macOS 27.0; Debug app 3.0.0 build 739 at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Tested source: baseline plus this cycle's eight Swift files, with documentation changes.
The initial sandboxed invocation could not write Xcode/Swift compiler caches; normal
approved test execution succeeded.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-template-stale-full.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

The focused invocation adds `-only-testing:Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests`
and `-only-testing:Aagedal Photo Agent Tests/DevelopTemplateTests` (each shell-quoted as one argument).
No native interaction, real MCP client or broader release gate is claimed by these regressions.

## Remaining before release

Template-store authority and stable-UUID discovery/application; remaining face/transcription
MCP operations, status/cancellation and two-phase IPTC mutation; FFmpeg Whisper/model delivery;
broader writer coordination and real-volume recovery; native/accessibility, authentic camera,
external editor/transport, cloud and supported-hardware performance evidence; qualified privacy/
legal review and remote CI enforcement; exact-candidate package verification, independent
readiness review, final acceptance and separately authorized signing/distribution.
