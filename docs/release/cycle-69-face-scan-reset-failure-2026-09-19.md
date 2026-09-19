# Cycle 69 — Full face-scan reset failure

State: IMPLEMENTED AND AUTOMATED-VERIFIED; broader release gates remain open. Baseline `c0a02eb`; checkout initially clean.

## Implementation

A full face rescan previously cleared visible results before deleting the existing face
store, reported a deletion failure, and then continued scanning from an empty snapshot.
That continuation could overwrite surviving data and conceal the reset failure.

The scan now requires a committed reset before clearing presentation or preparing its
scan plan. Failed or uncommitted deletion ends the operation, resets progress, releases
the folder reservation, and keeps the existing visible results and editor baseline.
The storage failure remains visible and an explicit retry can start normally. Immediate
cancellation still waits for the detached reset operation and honors its failure result.

This prevents subsequent scan writes after a failed reset. It does not make recursive
filesystem deletion atomic or restore files already removed before an underlying failure.

## Verification

A temporary-folder regression exercises normal and immediately cancelled full scans with
an injected permission failure. It checks unchanged document bytes and thumbnail data,
retained visible faces/completion, no replacement save, idle progress state, error
presentation and released admission. Each case then allows deletion and verifies a real
retry replaces the old scan and removes its thumbnail, using an invalid disposable JPEG
so no face-model inference is required.

The focused suite passes **28 tests in one suite**, zero failures:
`build/qa-face-reset-focused-authorized.xcresult`. Repository validation passes
(`build/qa-face-reset-repository.log`). The full integrated suite passes **3,025 tests
across 319 suites**, zero failures, in 120.911 seconds:
`build/qa-face-reset-full.xcresult` (`build/qa-face-reset-full.log`). Twelve Thread
Performance Checker QoS diagnostics remain unresolved release observations.
The initial sandboxed Xcode invocation could not write compiler caches; the authorized
invocation uses the normal macOS test host. No native UI or authentic
camera evidence is claimed by these fault-injection tests.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/ActivityHistoryTests' \
  -resultBundlePath build/qa-face-reset-focused-authorized.xcresult
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-face-reset-full.xcresult
scripts/ci/validate_repository.sh
```

Host: arm64, macOS 27.0 (26A428), Debug app 3.0.0 build 739 in
`Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug`
under the user's Xcode DerivedData directory. Tested source: baseline plus this cycle's
two Swift files. Test-host `MDB_MAP_FULL` diagnostics remain observed.

## Remaining before release

Production MCP workflow tools, operation status/cancellation, guarded IPTC commits,
template integration and FFmpeg Whisper remain unfinished. Broader writer admission,
authentic camera/editor/transport interoperability, native/accessibility, cloud,
hardware/performance and migration/recovery evidence remain open. Qualified privacy/legal
review, remote CI enforcement, exact-candidate packaging, independent release review,
final user acceptance and authorized signed distribution are still required.
