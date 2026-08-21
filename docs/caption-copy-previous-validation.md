# Caption Copy Previous validation

**Validated:** 2026-08-21  
**Scope:** Phase 2 safe previous-image field transfer

## Implemented contract

- The UI default copies only caption, headline, people, and keywords from the immediately previous
  image in the current visible/sorted caption session.
- Replace and append modes are explicit. List append retains current order, appends new source
  values in source order, and removes duplicates deterministically.
- Capture-specific identity and state cannot be copied even if a programmatic caller selects and
  allowlists it: GUID/supplier ID, creation/capture dates, legacy and structured created location,
  GPS, rating/label, Camera Raw/develop settings, and orientation are protected.
- The pure service returns structured applied, unchanged, missing, not-allowed, and protected
  results without including field values, so its preview/result is safe to log.
- Previous metadata is loaded without changing browser selection. Pending app-sidecar metadata
  wins, followed by current XMP descriptive metadata and then embedded metadata.
- The workspace crosses its normal flush barrier before copying, retains the current image/session
  focus, rejects stale asynchronous results, and persists the resulting draft through the existing
  sidecar path on the next save/navigation.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-caption-copy-previous-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionCopyPreviousServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionSessionTests' \
  EXCLUDED_SOURCE_FILE_NAMES=RenameExecutionServiceTests.swift
```

Result: **17 tests passed** across two suites: eight Copy Previous tests and nine Caption Session
tests. Production and Caption Workspace code compiled successfully. The exclusion was temporary
while the independent rename-executor test file was still under active development; the final
consolidated run will include it.

## Remaining integration

- Add a field-selection UI if workflows need more than the safe four-field default.
- Restore a specific AppKit editor focus after the mandatory buffered-text flush.
- Add manual keyboard-only testing with long Unicode captions and large folders.
