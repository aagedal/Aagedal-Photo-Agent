# Plan-status Develop source-decode continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by removing concrete Develop source-decode
execution and fallback policy from `EditWorkspaceView`. It also strengthens Phase 3.2 resource control by ensuring
that foreground and speculative Develop RAW requests cannot establish concurrent CIRAWFilter memory peaks. It does
not complete the broad Phase 4.1 extraction gate, so the audit remains at 63 of 75 completed substeps.

## Actor-owned decode execution

`DevelopSourceDecodeService` now owns the image-production work that feeds the existing preview-session and Metal
publication owners:

- embedded RAW preview extraction and orientation correction;
- HDR-first non-RAW preview decode with ImageIO and AppKit fallbacks;
- screen-resolution RAW and full-resolution non-RAW decode;
- lazy full-resolution RAW/non-RAW zoom upgrades;
- adjacent-RAW speculative pre-cache decode;
- shared file-orientation-to-session-orientation correction; and
- bounded half-float materialization used to release heavyweight decode graphs after the Metal upload.

All CIRAWFilter work crosses one actor. A foreground screen decode, lazy sensor-resolution upgrade, and background
neighbor pre-cache therefore execute serially rather than each retaining a large transient demosaic graph. Queued
work checks cancellation before touching the decoder and every result checks cancellation after the non-preemptible
decode. The existing `DevelopPreviewSessionCoordinator` still owns task lifetime and source publication identity;
the Metal pipeline still owns generation-gated texture mutation. This service neither publishes UI state nor
weakens those established stale-result boundaries.

The RAW decoder and orientation reader are injected for deterministic characterization. The production default
retains the existing RAW profile, decoder-version preference, neutral temperature/tint, screen-size, HDR-first,
thumbnail fallback, and target-orientation behavior.

## Characterization and validation

Four new tests prove that concurrent RAW requests execute one at a time, a pre-cancelled request never reaches the
decoder, Core Image and AppKit representations receive the same orientation frame, and the Develop view contains no
direct source-decode/materialization calls.

- Focused decode-service selection: 4 tests in 1 suite passed.
- Adjacent Develop interaction, full-screen decode, image-memory, and comparison selection: 78 tests in 5 suites
  passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,849 tests in 217 suites passed in 61.034 seconds.
- Result bundle:
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_19-50-03-+0200.xcresult`.

The test host emitted its existing App Intents, iCloud entitlement, LMDB cache-capacity, AppKit monitor-token, and
background-publication warnings; none failed the focused or unfiltered gates and none originated in this change.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs broader render-policy, geometry, and view-decomposition
ownership before the major-feature exit gate can be claimed. Phase 3.1 remains open for lower-priority direct
filesystem paths plus local SSD, network, iCloud-placeholder, read-only, large-library, signpost, and Thread
Performance Checker evidence. The real RAW/HDR Instruments benchmark remains open in Phase 3.2; serialized Develop
RAW execution reduces a known source of concurrent transient memory but does not replace that measurement.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
