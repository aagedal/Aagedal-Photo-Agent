# Plan-status archive, roster, license, and crop continuation — 2026-08-30

## Scope and checklist result

This continuation advances two broad v3.0 audit gates: Phase 3.1 filesystem responsiveness and Phase 4.1
Develop state ownership. Image Analysis project archives, match-roster persistence, and bundled license-text
loading now cross serialized asynchronous boundaries, while Develop crop state has a dedicated lifecycle
owner. These slices do not complete the remaining filesystem inventory, real-volume measurement, Thread
Performance Checker, or broader Develop ownership exit conditions, so the audit remains **63 of 75 complete**.

## Image Analysis project archive boundary

`ImageAnalysisProjectArchiveService` serializes complete export, inspection, and import workflows away from
the main actor. Enumeration, chunked hashing, validation, staging, and case-path rebasing now observe
cancellation at stable boundaries. Export and import return immutable commit evidence that distinguishes
pre-commit cancellation from cancellation observed after a durable commit, including whether import replaced
an empty destination. The existing public facade and caller-visible archive behavior remain unchanged.

Four focused additions cover off-main serialized execution, queued cancellation before I/O, cancellation
observed during a durable commit, and facade-to-service source routing. Existing archive round-trip and atomic
replacement coverage remains in place.

## Match-roster persistence boundary

`MatchRosterService` now routes load and atomic save work through one shared actor with an injectable file
boundary. Immutable results distinguish missing data, complete loads, cancellation around a non-preemptible
read, cancellation before save, and cancellation observed after commit. Face recognition owns a request ID
and task lifetime per folder session, rejects stale completion, and cancels navigation replacement. Metadata,
match setup, and face-management callers now await the same boundary instead of touching roster files on the
main actor.

Five focused tests cover off-main execution, serialization, queued cancellation, durable commit evidence,
and source/caller contracts.

## Bundled license-text boundary

License disclosure expansion no longer performs `Bundle` lookup and `String(contentsOf:)` synchronously in
the SwiftUI view. `BundleTextResourceService` serializes extension probing and mapped reads away from the main
actor, returns complete immutable text or explicit missing/cancelled evidence, and never publishes bytes from
a request cancelled during a non-preemptible read. The view owns one task and request identity per resource,
rejects stale publication, and cancels outstanding work on disappearance.

Four focused tests cover off-main lookup/read behavior, extension fallback, pre-read cancellation,
post-read cancellation without text publication, and the view source contract.

## Develop crop state owner

`DevelopCropSessionCoordinator` now owns crop-tool visibility, crop-preview zoom, aspect ratio, locked
geometry, transient crop/straighten drag state, and image/workspace cleanup. It also owns the display/sensor
crop transformations and returns an explicit preview-only or durable-commit intent to the workspace. This
keeps gesture previews from silently crossing the XMP or named-version persistence boundary while preserving
the existing rendering and commit behavior.

Five characterizations cover navigation lifecycle, tool teardown, one-shot drag consumption, persistence
intent, angle clamping, reset behavior, and the view source contract.

## Validation

The roster selection first passed **5 tests** in `MatchRosterServiceTests`; that run compiled the application
and test targets after the shared source tree was stable. A newly added crop test file was then registered in
the project's manually maintained unit-test target, and its missing direct `CoreGraphics` import was caught
and corrected by the focused build.

Because Xcode's parallel macOS test worker twice stalled while materializing, the final focused selection was
run serially against the current compiled products. It passed **21 tests** across the four affected suites:

```text
BundleTextResourceServiceTests
ImageAnalysisProjectArchiveTests
MatchRosterServiceTests
DevelopCropSessionCoordinatorTests
```

Result bundle:

```text
/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/
Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_12-41-31-+0200.xcresult
```

The serial unfiltered `test-without-building` gate then passed. Its Xcode result records **1,817 expanded test
cases** and 196 named Swift Testing suites (plus the root group):

```text
/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/
Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_12-42-11-+0200.xcresult
```

`git diff --check` and the direct-call source audits also pass. The expanded-case metric is the Xcode result
count and should not be compared directly with earlier Swift Testing logical-test summaries.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 still requires completion of the lower-priority
filesystem inventory plus local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, and
Thread Performance Checker evidence. Phase 4.1 still needs dedicated ownership for layer, white-balance,
broader render-policy/publication, export, and persistence state.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing plus supported-macOS
validation.
