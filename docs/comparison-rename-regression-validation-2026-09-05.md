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
