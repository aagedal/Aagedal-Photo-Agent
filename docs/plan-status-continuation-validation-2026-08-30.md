# Plan-status continuation validation — 2026-08-30

## Scope and checklist result

This continuation implemented three independent code-only slices from the 3.0 app-improvement audit. The
compile-time Metal live-preview facade closes one checklist substep, moving the audit to **63 of 75 complete**.
The FTP availability and Develop comparison work advance the broader Phase 3.1 and Phase 4.1 items without
claiming their full exit gates.

## FTP Recent Uploads filesystem boundary

`FTPUploadView` no longer performs repeated synchronous `FileManager.fileExists` calls while SwiftUI evaluates
an expanded Recent Uploads disclosure. The existing injected `FTPUploadFileSystemBoundary` actor now returns an
ordered immutable snapshot for every recorded path. Completion is explicit: either the whole scan completed or
cancellation occurred after a named checked prefix. Cancellation is checked before and after each synchronous,
non-preemptible existence probe.

Disclosure expansion starts the asynchronous scan and shows a neutral progress state. The main actor installs
only a complete result for the entry that remains expanded; queued cancellation, mid-probe cancellation, and a
stale expansion therefore cannot publish partial or unrelated availability. Reopening an entry requests a fresh
snapshot.

Five added characterizations cover exact available/missing ordering, pre-cancellation with zero probes,
cancellation after one probe, an injected blocking probe that leaves the main actor responsive while actor work
remains serialized, and the view source contract. Together with the existing inventory/staging/sequencing
coverage, all **9 tests** in `FTPUploadFileSystemBoundaryTests` passed.

## Develop comparison render coordinator

`DevelopComparisonRenderCoordinator` is the named owner for Develop comparison mode, image/version target,
left/right rendered sources, visible error/loading state, debounce task, cancellation, and request identity.
Opening another target, rescheduling, closing Compare, or tearing down the workspace cancels the previous task
and advances the request token. A renderer that ignores cooperative cancellation cannot publish late pixels or
an obsolete error. Version comparison results publish the live and target renders together.

Rendering remains injected through async closures, preserving the existing `ComparisonRenderService` behavior
while giving lifecycle and stale-result handling a deterministic test seam. Three characterizations cover a
replacement rejecting late pixels, close rejecting a late failure and clearing state, and mode switching with
atomic version-pair publication. All **3 tests** in `DevelopComparisonRenderCoordinatorTests` passed.

## Compile-time Metal live-preview facade

Interactive pipelines are now constructed and retained as `@MainActor MetalLivePreviewPipeline`. The raw live
`MetalEditPipeline` initializer is file-private, so UI code cannot construct or retain the unchecked engine and
bypass actor isolation. Develop, `MetalPreviewView`, `MetalScopeView`, `ScopeViewModel`, Clean Feed, and relevant
tests use the facade. Its mirror association retains facade identity while forwarding the existing weak engine
mirror.

The existing serialized `OffscreenRendererExecutor` and static `renderOffscreen*` compatibility APIs are
unchanged. The facade forwards mutable render-state work on the main actor and exposes only four documented
worker-safe exceptions as `nonisolated`: source upload, adjacent-source precache, CI-context warmup, and
white-balance solving. A source contract requires the facade, the file-private raw initializer, the explicit
exceptions, and facade typing at every production live owner/consumer. Repository search finds raw
`MetalEditPipeline` construction only inside `MetalEditPipeline.swift`: the offscreen executor and the facade.

The facade-focused build succeeded. `BrushRasterizationTests` and `MetalPipelineTSANStressTests` passed **17 of
17 tests**; `ImageMemoryCoordinatorTests` passed **7 of 7 tests**. The preserved result bundles are:

```text
/private/tmp/aagedal-v3-metal-facade/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_00-59-43-+0200.xcresult

/private/tmp/aagedal-v3-metal-facade/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_01-01-31-+0200.xcresult
```

## Integrated focused validation

The same current-source build ran all touched suites together:

```text
xcodebuild test-without-building -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/aagedal-v3-metal-facade CODE_SIGNING_ALLOWED=NO \
  -only-testing:"Aagedal Photo Agent Tests/FTPUploadFileSystemBoundaryTests" \
  -only-testing:"Aagedal Photo Agent Tests/DevelopComparisonRenderCoordinatorTests" \
  -only-testing:"Aagedal Photo Agent Tests/BrushRasterizationTests" \
  -only-testing:"Aagedal Photo Agent Tests/ImageMemoryCoordinatorTests" \
  -only-testing:"Aagedal Photo Agent Tests/MetalPipelineTSANStressTests"
** TEST EXECUTE SUCCEEDED ** — 36 tests in 5 suites
```

```text
/private/tmp/aagedal-v3-metal-facade/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_01-02-12-+0200.xcresult
```

The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature, and SwiftUI
background-publication diagnostics. They did not produce a build failure, test issue, cancellation, or test
failure. The complete `scripts/ci/validate_repository.sh` gate then passed generated-document checks, release
metadata, JSON/plist/project validation, bundled-component provenance, logger and investigation privacy checks,
conflict-marker scanning, and whitespace validation. `git diff --check` passed.

An additional unfiltered diagnostic run executed **1,604 tests in 180 suites**. It did not pass cleanly:
nine async characterization tests recorded 13 short-deadline issues while all suites competed in parallel,
including existing Develop-version, Delivery Receipt, AI-mask, and rejected-move tests plus two new comparison
tests. The run completed in 42.323 seconds of test time (56.629 seconds for the Xcode operation). All five
reported suites were then rerun together without the unrelated full-suite load and passed **25 of 25 tests**
in 0.254 seconds:

```text
/private/tmp/aagedal-v3-metal-facade/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_01-06-31-+0200.xcresult
```

This confirms the reported failures are parallel-load timing sensitivity rather than a reproducible focused
failure, but it does not claim a clean unfiltered run. The full-suite timing sensitivity should be stabilized
before relying on that run as release evidence.

## Remaining boundary after this session

The audit has **12 open checklist substeps**. Code work still includes the broader inventory of lower-priority
blocking filesystem paths, additional state-owning Develop/render extraction, and stabilization of short async
test deadlines under the unfiltered parallel suite. Manual and external work still includes protected
release-branch configuration, focused Known People privacy/legal review, real FTP/FTPS/SFTP drills,
VoiceOver/keyboard/IME/contrast/motion/localization/display validation, slow-volume and Thread Performance
Checker evidence, Instruments RAW/HDR memory benchmarks, and production AuraFace publishing plus supported-
macOS validation.
