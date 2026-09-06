# Analysis counter markup and photo layers — 2026-09-06

## Behavior

- The photo Counter tool (C) places a numbered badge with each click. Each exact palette/custom
  color has an independent sequence. Changing colors after placement does not recolor the last
  marker because placement clears selection. Drags do not place counters.
- Numbers are contiguous within each color in persisted layer order. Deletion, recoloring,
  pasted annotations, undo, and redo recalculate the sequences, as requested by the user.
- Counter Evidence derives totals from all counter annotations, including hidden markers.
  It appears in the Pixel Analysis Evidence/Layers sidebar and OSINT Photo Annotations pane.
  Frozen report snapshots retain the per-marker data and PDF reports derive totals from that
  snapshot; hiding markers cannot silently reduce evidence totals.
- Pixel Analysis has a dedicated Layers inspector. Both workspaces offer photo-layer type and
  color filters, show/hide matching layers, and groups by type/color with visible/total counts.
  Filters narrow only the list. Visibility changes persist and undo as one operation per group.
- JPEG evidence and PDF image figures draw numbered badges; optional user labels are preserved.
  Hidden markers are omitted from images, while PDF textual evidence retains their counts.
  Counter outline widths are capped so a thick line-tool preference cannot cover the numbers.
- Case schema 10 migrates schema 9 without requiring counter metadata on older annotations.
  Persisted counter sequences reject duplicate/gapped numbers. Snapshot schema 5 derives totals
  from frozen annotations rather than maintaining a second, potentially stale stored total.

Counter evidence remains manual, source-bound analysis data. It does not modify IPTC/XMP or
claim automated object recognition. This change adds photo counters; the existing map marker
tool remains separate.

## Validation

Final serial app/test run: **2,166 tests in 250 suites passed**, zero issues,
65.319 seconds of Swift Testing execution. Repository validation and `git diff --check` passed.

Coverage includes independent color sequences, deletion/recolor/paste, persistence, undo/redo,
group visibility, older schema migration, malformed counter metadata, frozen report totals,
PDF text, JPEG badge numerals/labels/hidden-marker omission, thick outlines, letterboxed hit
selection and movement, and intersecting filters/group counts over 1,000 markers. Custom colors
with similar displayed RGB values remain distinct groups.

The first integrated build identified one additional annotation-kind switch in map-linked naming
and a test-macro key-path issue; both were corrected. The first executing full run found only an
older all-kinds fixture missing the new Counter entry; it has been updated.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-analysis-counters-final.log` and
`/private/tmp/aagedal-analysis-counters-repository.log`.

Manual follow-up: check the new Layers layout at the user's window sizes, color-picker operation,
VoiceOver navigation, and interactive responsiveness with thousands of placed markers. Automated
coverage includes data/model scale and exported raster pixels, not live UI performance measurements.
