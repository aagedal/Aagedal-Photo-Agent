# Comparison rename regression and Batch Rename usability — 2026-09-05

## Manual finding

The user tested File → Rename in Compare, first focusing one pane and then the other. The first
rename appeared successful; after the second, the other pane showed Source Missing and the whole
comparison area collapsed vertically. This is a failed manual check of the previous continuation,
not a completed interaction gate. File → Rename targets the focused image in Compare; the previous
instructions incorrectly implied it would rename both comparison sources together.

The user also reported a clipped five-column Batch Rename preview, sequence inputs whose placeholder
labels disappeared when populated, and confusion because padding values 0 and 1 produced the same
output.

## Fix

The browser used equal file counts as evidence that source identities were unchanged. A rename
keeps the count but changes URL keys; refreshing the old sorted list by those keys dropped the
renamed row. The first rename could survive in Compare provisionally, then disappear from its
availability snapshot during the second rename. The browser now compares URL identities before
reusing sorted order. A two-step regression checks both rows, selection and name sorting after
successive focused-image renames.

The folder watcher could also begin or finish a scan while the rename executor was moving bundles, before
its completion callback published the source-to-destination mapping. Compare treated that intermediate
listing as an authoritative removal and erased the source, so the later mapping could not recover it.
A scan captured earlier could also overwrite the browser's already-projected destination list.

Browser refresh now pauses from rename preparation until successful URL projection or failure
recovery. Existing refresh work is cancelled and invalidated by request ID, and every asynchronous
refresh boundary checks cancellation, request ownership and folder identity before publishing.
Preparation errors and aborted execution release the pause. Compare independently retains its
sources and queued mappings while the rename sheet is open, then reconciles the committed snapshot.
The workspace, split layouts and missing-source placeholder explicitly fill available space, removing
the intrinsic-size collapse when a pane changes content type.

Batch Rename now displays wrapping Current name, New name and Status columns. Row issues occupy the
full width below the names. The recipe result appears only when it differs from the actual planned
name, retaining conflict-resolution information without a redundant column. Summary badges wrap.
Sequence inputs retain Start, Step and Minimum digits labels. Inline examples explain that this is
a minimum width: 0 and 1 both render 7 as 7; 3 renders it as 007; larger numbers are never truncated.
Sequence rendering and stored recipe semantics are unchanged.

## Automated validation

An initial 2,077-test run passed. The stronger suspended-refresh test then exposed the equal-count
sorted-list bug through lost selection, alongside a fixture mismatch between macOS temporary-directory
URL spellings. The test now takes its initial URLs from the real folder scanner and uses a bounded
wait and production-standardized URL assertions.

Final validation after the identity correction:

- Focused rename/refresh/companion suite: **20 tests passed**.
- Serial unfiltered run: **2,079 tests in 237 suites passed**, zero failures, 62.974 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_22-56-30-+0200.xcresult`
in Xcode DerivedData. Full log: `/private/tmp/aagedal-compare-rename-complete.log`.
Focused log: `/private/tmp/aagedal-compare-rename-focused-final.log`.
Repository log: `/private/tmp/aagedal-compare-rename-fix-repository.log`.
These automated checks do not claim the visual manual retest below.

## Analysis annotation manual result

**User-reported pass (2026-09-05):** renaming inside Analysis and outside Analysis both retained
the annotation when switching between Analysis and Single view. This report does not cover the
Compare source/layout regression or Batch Rename presentation changes below.

## Browser selection freeze follow-up

The next user run froze before entering Compare. A five-second live stack sample of build 738
(`/private/tmp/aagedal-freeze-sample.txt`) showed the main thread waiting inside Apple's RAW
initialization from `ThumbnailService.orientedToSidecar` → `fileEXIFOrientation`. A background
HDR classification held that initialization's once lock while `NSUserDefaults.registerDefaults`
posted a notification and waited for an operation to finish. This establishes a decoder /
main-thread notification wait cycle, independent of the earlier rename identity failure.

Changes:

- Explicit `@concurrent` boundaries keep original thumbnail generation, edited thumbnail
  rendering, cloud availability checks, and shared edited preview decoding off MainActor.
  Under this project's approachable concurrency settings, `nonisolated async` alone inherits
  caller execution and did not provide the previously documented off-main guarantee.
- Preferences sync observers receive on the posting thread and asynchronously deliver background
  events to MainActor. Main-thread events remain inline to preserve remote-update echo suppression.
  NotificationCenter's synchronous main OperationQueue wait is removed.
- Browser and Metadata Review defaults subscriptions schedule their UI updates on the main queue,
  addressing the background-publication warning triggered by decoder defaults registration.
- Regression tests cover off-main thumbnail generation, nonblocking background preference delivery,
  and synchronous main-thread preference delivery.

Validation: **2,082 tests in 237 suites passed**, 70.517 seconds, in the full serial run.
`scripts/ci/validate_repository.sh` and `git diff --check` passed. The initial validation
builds caught a missing Combine import and a test-only synchronous-wait restriction; both
were corrected before the passing run.

- Full log: `/private/tmp/aagedal-freeze-tests-complete.log`
- Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_23-08-26-+0200.xcresult`
- Repository checks: `/private/tmp/aagedal-freeze-repository.log`

### First retest: browser responsiveness

1. In Xcode, click Stop (the square button) to end the frozen run.
2. Select the **Aagedal Photo Agent** app scheme and choose Product → Run (Command-R) to rebuild.
3. Open the same **TestImages copy** folder. As thumbnails appear, click one photo, then hold
   Command and click a second photo, reproducing the selection that froze the app.
4. Before opening Compare, scroll the grid and click another photo. The selection should change
   immediately and the app should remain responsive while metadata finishes loading.
5. Quit the app and run it again, then repeat steps 3–4 once. This matters because RAW initialization
   happens once per process. Report any freeze or repeated background-publication warning.
6. If this passes, continue the Compare and Batch Rename checks below.

This real-folder retest remains pending. The stack sample is retained outside the repository;
no user photo files were changed during diagnosis.

## Requested manual retest

Use two copied photos in the latest development build:

1. Select both photos in Browser and open Compare Two Images. Zoom/pan to an obvious detail.
2. Focus the left photo. Choose File → Rename, enter a different filename while retaining its
   extension, inspect the preview and click Rename.
3. Focus the right photo and repeat with a different filename. Both photos should remain visible,
   retain the current zoom/pan, and occupy the same full-height comparison area.
4. Close Compare and verify that both renamed files remain in Browser. Reopen Compare with them.
5. Select both photos in Browser and open File → Rename. Verify Current name, New name and Status
   remain visible; long names and any issues should wrap rather than hide columns.
6. In a Sequence component, check that Start, Step and Minimum digits remain visible above populated
   inputs. With Start 7 and Step 1, minimum digits 0/1 should yield 7/8 and minimum digits 3 should
   yield 007/008 in the preview. No file rename is needed for this last check.

Visual/manual checks above remain unverified until the user reports the result. Broader real-volume,
Thread Performance Checker, Instruments, accessibility and release gates remain open; the audit
checklist remains at 66 of 75 completed substeps.

## Full-screen and Compare preview latency follow-up

The user reported a persistent pixelated full-screen view of an edited JPEG and slow initial
Compare preparation. Live samples taken after the reports did not capture an active image decode
or a blocked main thread; they do not establish the duration or exact bottleneck of those loads.

Implemented:

- Full-screen interim non-RAW previews now use a screen-sized ImageIO downsample, with edits and
  orientation applied, instead of a fixed 960-pixel Core Image/HDR-first preview. The separate final
  render retains HDR. The interim SDR image may change tonality when final HDR becomes available.
- Both foreground stages request enough source pixels for the displayed crop to reach the screen
  target. Previously a crop could reduce even the final screen-sized decode below that target.
- Cached display previews use the same progressive upgrade path, removing a duplicated final-load
  implementation and retaining generation, navigation, and cancellation checks.
- Compare downsamples an oversized, matching full-screen cache entry within its memory budget
  instead of discarding it and decoding the source again. The larger shared entry stays intact.
- Compare source and live-edit rendering explicitly execute away from MainActor under approachable
  concurrency. Exact source-revision capture is retained.
- A regression test covers Compare cached-image dimensions, HDR headroom, and reuse of an already
  bounded bitmap.

Manual retest after rebuilding:

1. Stop the current Xcode run, choose the app scheme, and press Command-R.
2. Select the same edited JPEG in Single view and press Space. Note approximately how long it
   takes to become sharp enough to inspect at fit-to-screen. The initial thumbnail should be
   replaced by a screen-sized preview; final HDR may refine its appearance afterward.
3. Exit full screen, select another photo, and repeat. Include a cropped photo if available.
4. Open Compare with those two photos, then close and reopen it. Check first-load and repeat-load
   times separately, and verify both images, edits, orientation, zoom, and pan remain correct.
5. Report approximate seconds to a useful preview and whether image quality eventually finishes
   improving. Report the filename/format of any consistently slow example.

Real-folder timing remains unverified. Cold Compare still waits for both completed renders and
exact revisions. RAW interim-preview orientation restrictions and final-prefetch reuse remain as
before; these changes do not claim to eliminate every source of decode latency.

Validation: **2,083 tests in 237 suites passed**, 66.612 seconds, in an isolated full run.
Repository validation and whitespace checks passed. Earlier shared-build runs encountered a stale
unsigned/missing test bundle and a test-host restart; isolated build products avoided those issues.
The initial HDR assertion also caught an SDR test fixture, corrected to explicit extended linear
sRGB with input and output highlight assertions above 1.9.

- Full log: `/private/tmp/aagedal-preview-isolated-tests.log`
- Isolated DerivedData: `/private/tmp/aagedal-preview-validation`
- Repository checks: `/private/tmp/aagedal-preview-repository.log`
- Live samples: `/private/tmp/aagedal-fullscreen-sample.txt`,
  `/private/tmp/aagedal-compare-latency-sample.txt`
