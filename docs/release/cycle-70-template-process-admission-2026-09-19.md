# Cycle 70 — Template process admission

State: IMPLEMENTED AND AUTOMATED-VERIFIED; broader release gates remain open.
Baseline `6ef7257`; checkout initially clean.

## Implementation

Metadata and Develop template CRUD previously serialized complete transactions only within
one app process. A second cooperating process could read an intermediate shortcut inventory
or interleave changes with the transaction. Production template CRUD now acquires the shared
process folder reservation after captured-root in-process admission and retains it through
reads, shortcut reassignment, persistence, Trash, export and final inventory refresh.
Metadata template import preview and commit use the same reservation and acquisition order.

Busy ownership refuses before the storage worker runs. An already-cancelled queued request
still reaches its typed pre-operation cancellation result without acquiring a process lease.
Every success and thrown-error path releases ownership. Independent template directories
remain independent, and captured canonical roots retain existing alias/rerouting behavior.

This is a prerequisite for stable-UUID MCP template discovery/application, not a new helper
endpoint. Legacy synchronous storage helpers, external editors and iCloud peers do not become
coordinated by this change. Template stale-snapshot detection and automation store authority
still need their own implementation; this lock does not establish either.

## Verification

The focused final-source run passes **37 tests across two suites**, zero failures, in
0.888 seconds. Four new parameterized tests exercise 18 cases: metadata and Develop CRUD
contention, metadata import preview/commit contention, callback ownership and storage-error
release. They verify unchanged stored bytes and existing exports on refusal, shortcut
reassignment on retry, exact recoverable deletion, successful export and reacquisition.
Existing queued-cancellation, captured-root, import-ordering and editor-recovery tests pass.

Evidence: `build/qa-template-admission-focused-authorized.xcresult` and corresponding `.log`.
The full final-source integrated suite passes **3,029 tests across 319 suites**, zero
failures, in 131.855 seconds: `build/qa-template-admission-full.xcresult` and corresponding
`.log`. Repository validation passes: `build/qa-template-admission-repository.log`.
Twelve Thread Performance Checker diagnostics and test-host `MDB_MAP_FULL` messages remain
observations; no claim of resolving those prior release issues is made.

Host: arm64, macOS 27.0; Debug app 3.0.0 build 739 at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Tested source is baseline plus this cycle's four Swift files.
The initial sandboxed build could not access Xcode/Swift compiler caches; the normal approved
macOS build/test invocation succeeds. This was a test-environment permission failure.
No native UI, real MCP client, cloud or cross-device release evidence is claimed.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests' \
  '-only-testing:Aagedal Photo Agent Tests/DevelopTemplateTests' \
  -resultBundlePath build/qa-template-admission-focused-authorized.xcresult
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-template-admission-full.xcresult
scripts/ci/validate_repository.sh
```

## Remaining before release

Production MCP template/provider discovery, face scans, template application, transcription,
operation status/cancellation and two-phase IPTC commits remain unfinished. FFmpeg Whisper
and model delivery remain mandatory. Broader writer coordination, authentic camera/editor/
transport, native/accessibility, cloud, supported-hardware/performance, and recovery evidence
remain open. Qualified privacy/legal review, remote CI enforcement, exact-candidate package
validation, independent release review, final acceptance and authorized signing/distribution
remain release gates. No Phase 5A checkbox is closed by this prerequisite.
