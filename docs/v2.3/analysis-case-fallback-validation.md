# Analysis-case read-only-folder fallback validation

**Validation date:** 2026-08-23

## Implemented boundary

Image Analysis continues to prefer the portable `.photo_analysis` store beside the source images.
When the source folder is known to be read-only, or a folder-local save fails with a Cocoa
no-permission or read-only-volume error, `AnalysisCaseRepository` writes to the app's local
Application Support directory instead.

The fallback owns:

- a versioned index that records each case's complete `SourceImageRevision` and its fallback
  filename;
- a folder-identity entry for each working-folder map document;
- atomic, validated case, folder-map, and index documents with the existing bounded backups;
- folder-local preference when an equal document exists in both stores; and
- a workspace warning that the fallback investigation data is stored on this Mac and will not
  automatically travel with the photo folder.

Fallback data remains app-private and local-only. The implementation does not write source bytes,
XMP, IPTC, or portable settings. An unsupported newer fallback-index schema blocks an older writer
before it can install fallback state.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -derivedDataPath /private/tmp/aagedal-analysis-fallback-derived-data-20260823 \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisCaseTests"
```

Coverage includes:

- indexed Application Support case persistence for a known read-only photo folder;
- repository recreation and exact source-revision reopening from fallback storage;
- source-byte and XMP non-write assertions;
- fallback persistence and reopening for the shared working-folder map;
- folder-local preference after the photo folder becomes writable again;
- refusal to save through a newer fallback-index schema; and
- a usable workspace with published fallback storage state and portability-warning copy.

The focused suite passed 67 tests in one suite on 2026-08-23.

## Remaining release boundary

This evidence closes only the Phase 0 folder-local-versus-Application-Support UX decision. The
broader Phase 12 source/folder permission regression remains open: Open Recent and Favorites launch
paths, lost security-scope restoration, iCloud offline transitions, real read-only volumes, and
interactive warning review still require the release matrix.
