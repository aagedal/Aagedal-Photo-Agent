# Plan-status Develop Metal-publication continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by closing the stale source-texture
publication gap between the existing Develop preview-session owner and the live Metal pipeline. It does not
complete the broad Phase 4.1 extraction gate, so the audit remains at 63 of 75 completed substeps.

## Generation-gated Metal publication

`DevelopPreviewSessionCoordinator`'s image-session generation now crosses every asynchronous Develop source
texture upload: embedded/quick preview, screen-resolution RAW decode, full-resolution non-RAW decode, in-memory
rotation, and lazy full-resolution zoom upgrade. `MetalSourcePublicationGate` serializes the final editor and
Clean Feed texture swap against navigation or teardown under one lock.

This closes the gap left by cooperative task cancellation. Once a Metal command buffer has been committed it
cannot be cancelled; previously, obsolete work could replace the shared texture before its Swift task noticed
cancellation. The final publication now has deterministic ordering:

- if navigation/teardown wins the gate first, the old upload is rejected after completing its private texture;
- if an upload wins first, navigation/teardown clears it before the transition returns;
- editor and Clean Feed mirror textures publish or clear in the same gated closure;
- in-memory rotation advances the preview-session generation and the Metal gate without blanking the last good
  texture, rejecting pre-rotation work even though the image URL is unchanged; and
- a rejected stale upload cannot re-enable speculative adjacent-image precaching after memory pressure.

The render engine still exposes its unscoped source upload for isolated pipeline and test callers. Interactive
Develop uses only the generation-bearing facade overload. Decode execution and shader/render policy remain at
their existing boundaries.

## Characterization and validation

Three new gate characterizations cover navigation replacement, same-image rotation replacement, and teardown.
The preview-session characterization now verifies that rotation advances generation and rejects a pre-rotation
materialization, while a source contract verifies every Develop upload carries the captured generation and that
workspace teardown invalidates the Metal source.

- Focused preview-session, Metal-publication, and memory-coordination selection: 16 tests in 3 suites passed.
- Focused real-GPU Metal stress rerun: 1 test in 1 suite passed, including scoped editor/Clean Feed publication,
  navigation clearing, stale-generation rejection, and current-generation replacement.
- Adjacent Develop interaction, Clean Feed, preview-render, image-memory, and Metal stress selection: 40 tests in
  5 suites passed before the final rotation-identity strengthening; the final focused selection recompiled and
  covered that strengthening.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,845 tests in 216 suites passed in 64.069 seconds.
- Result bundle: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_17-32-45-+0200.xcresult`.
- Focused real-GPU result bundle: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_17-35-08-+0200.xcresult`.

The test host emitted its existing App Intents, iCloud entitlement, LMDB cache-capacity, and AppKit monitor-token
warnings; none failed the focused gates or originated in this change.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs broader decode-execution, render-policy, geometry, and
view-decomposition ownership before the major-feature exit gate can be claimed. Phase 3.1 remains open for
lower-priority direct filesystem paths plus local SSD, network, iCloud-placeholder, read-only, large-library,
signpost, and Thread Performance Checker evidence.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
