# RAW full-screen preview resolution — 2026-09-19

## Scope

This 3.0 continuation addresses the reported intermittent low-resolution RAW full-screen
preview. Audit remains **66 of 75** and delivery **119 of 142** complete; the broad
performance, hardware, recovery and release gates remain open.

The investigation found two unguarded quality boundaries: a primary-cache hit returned
from full-screen loading without checking its dimensions, and RAW ImageIO thumbnail API
results were accepted as completed screen/full-resolution decodes regardless of their size.
These are plausible causes of the report, not a reproduction with the affected camera file.

- Full-screen cache hits and awaited prefetch results must meet the current display target,
  capped by the cropped source dimensions. A smaller cached result no longer skips the
  foreground quality upgrade. Orientation and edit-token matching remain in force.
- RAW screen and full-resolution ImageIO results are checked against the requested size.
  An absent or undersized result falls back to a non-draft CIRAWFilter sensor decode on the
  existing decode worker. The fallback explicitly uses the camera profile for this original
  raster path, and its resulting pixels are checked before publication. A 2% tolerance
  permits active-sensor borders and decoder rounding.
- Insufficient/failed fallback and cancellation return no completed decode. Existing
  full-screen failure UI can report the failed upgrade while its placeholder remains.
  Adequate embedded results keep their fast path. Diagnostic logging records fallback size.
- The quick embedded RAW preview remains a temporary display preview; it does not satisfy
  the primary-cache resolution requirement.

## Validation

Focused cache tests passed: **20 tests in 1 suite**, including resolution-aware primary
and awaited-cache reads, preservation of smaller cache entries, undersized/missing RAW
fallback, adequate-result fast paths, failed or still-undersized fallback, and cancellation
during fallback. Fixtures use generated PNG pixels and injected fallback boundaries;
they do not establish camera-specific RAW decoder behavior.

The final-source full regression suite passed **2,959 tests in 317 suites**, zero
failures, in **127.661 seconds**. Repository validation and `git diff --check` passed.
The initial sandboxed Xcode attempt could not write compiler/package caches; approved
Xcode access resolved that restriction.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-raw-preview-tests.log`,
`/private/tmp/aagedal-raw-preview-full-tests.log`, and
`/private/tmp/aagedal-raw-preview-repository.log`.

## Remaining validation

Reproduce with the affected RAW format/camera, including first open, rapid navigation,
original/edited toggles, crop, zoom and display changes. Verify sharpness and fallback
color against the source, and measure decode latency/memory on representative hardware.
No signed/notarized release or distributable candidate is claimed by this continuation.

## Apple RAW decoder settings follow-up

Apple's [WWDC26 RAW processing session](https://developer.apple.com/videos/play/wwdc2026/305/)
confirms that RAW 9 on macOS 27 requires explicit opt-in for supported files. The previous
Auto (Newest) implementation left the filter default untouched, which did not implement
that promise. Auto now explicitly selects the numerically newest advertised identifier;
unsupported pins use the same fallback, so an older OS or unsupported camera remains usable.
Selection does not assume an ordering of `supportedDecoderVersions`.

Pinned versions use exact identifiers, including Apple's `9.dng`/`8.dng` variants, verified
against the local Core Image constants. Decoder selection precedes draft/profile properties.
The shared sensor loader is used by Develop, edited preview and export rendering. Embedded
camera JPEGs and ordinary ImageIO previews do not use that preference. Settings now explain
this scope and require an app restart to clear previously decoded images.

Regression coverage includes newer and older supported-version lists, opposite API orderings,
future multi-digit versions, real Core Image identifier constants, pinned versions 6–9,
DNG variants, unsupported pins and empty support lists. Camera-specific image-quality and
RAW 9 latency/memory measurements remain open.

The decoder-settings follow-up compiled successfully and passed **23 focused tests in
1 suite**, zero failures, in **0.461 seconds**. Repository validation and whitespace
checks passed. Logs: `/private/tmp/aagedal-raw-decoder-tests.log` and
`/private/tmp/aagedal-raw-decoder-repository.log`. The 2,959-test full-suite result above
predates this follow-up; the focused run validates the subsequent decoder-selection change.
