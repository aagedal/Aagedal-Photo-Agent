# Shared image-memory coordination validation

**Date:** 2026-08-27
**Scope:** App-improvement audit Phase 3.2 implementation foundation; this record does not claim the
Instruments benchmark or exit gate is complete.

## Architecture

`ImageMemoryCoordinator` supplies one process-wide budget to the disposable image stores used by
full-screen viewing, Develop pre-caching, thumbnails, and Analysis scope rasters. The budget is one
eighth of physical memory, clamped to 256–1,024 MiB. Its shares total exactly 100%:

| Participant | Share |
| --- | ---: |
| Full-screen primary images | 32% |
| Full-screen display previews | 12% |
| Original + edited thumbnails | 16% |
| Analysis/scope derived rasters | 8% |
| Speculative Develop textures | 32% |

When more than one cache registers for a category (for example live, clean-feed, and offscreen Metal
pipelines), that category share is divided among them rather than duplicated per instance.

The coordinator does not replace the caches' existing identity, LRU, request-coalescing, or scoped
invalidation behavior. It registers limit/eviction callbacks with those caches and installs one
macOS dispatch memory-pressure source.

Source dimensions affect cache and prefetch policy. The estimate accounts for the source's decoded
bytes, a complete mip chain, and two foreground footprints (the current source and an intermediate).
Large sources progressively halve or quarter disposable cache limits. Develop prefetch becomes zero
when an adjacent full-resolution texture cannot fit after the foreground reservation. Full-screen
directional prefetch similarly shortens its six-item candidate window based on decoded display size.

## Memory-pressure protocol

Both warning and critical pressure first cancel registered speculative work, preventing a completed
decode from immediately repopulating a purged cache. Eviction then follows this documented order:

1. speculative Develop textures;
2. derived Analysis/scope rasters;
3. full-screen display previews;
4. thumbnails (critical pressure only);
5. full-screen primary images (critical pressure only).

The live Develop source is foreground state, not a disposable cache, and is not evicted out from under
the editor. Its footprint is instead reserved by the adaptive policy. Existing per-URL invalidation and
folder-switch cleanup remain unchanged.

## Automated validation

`ImageMemoryCoordinatorTests` covers:

- hardware-scaled budget clamping and the exact 100% allocation invariant;
- dimension-aware limit reduction and zero speculative GPU prefetch for a representative 48 MP source;
- cancellation-before-eviction behavior;
- warning and critical eviction order.

The focused build also runs the existing `FullScreenImageCacheTests` and
`AnalysisDerivedViewCacheTests` to protect prefetch reuse, suppression, invalidation, orientation,
decode recovery, and derived-view LRU behavior.

## Remaining exit-gate work

Run Instruments against representative large RAW and HDR files during rapid navigation, Develop
editing, and export. Record physical/IOSurface peak memory, allocation failures, pressure recovery,
and representative machine memory. An agreed peak budget and a bounded recovery measurement are
required before checking the Phase 3.2 benchmark substep or declaring its exit gate complete.
