# Metal pipeline combined TSAN stress scenario — 2026-08-25

## Scope

This is the scheduled, repeatable Phase 4.2 sanitizer scenario for the remaining unchecked Metal
pipeline boundary. `MetalPipelineTSANStressTests` drives production render paths in one overlapping
loop rather than treating the requested activities as independent checks:

- **preview:** a main-thread-owned `MetalEditPipeline` uploads a source and repeatedly changes edit
  parameters and viewport state;
- **Clean Feed:** the preview mirrors its source and parameter changes into a second live pipeline,
  with assertions that navigation promotes the same source size into both owners;
- **export:** two sibling tasks per iteration use the real shared `renderOffscreenAsync` renderer;
- **cancellation:** another export is held behind a deterministic gate, cancelled, and then released
  through the production cancellation fast path while sibling exports are queued;
- **navigation:** an adjacent image is precached on a worker through `precacheTexture` and promoted on
  the main-thread owner through `applyCachedTexture` while preview and export work is active.

The test performs eight internal overlap loops for ordinary targeted runs. The committed runner uses
Xcode's `-test-iterations` option to execute the entire isolated scenario 40 times under Thread
Sanitizer; `APA_TSAN_STRESS_ITERATIONS` can select 1 through 200 complete scenario runs. Each loop
varies image dimensions, pixels, adjustments, zoom, and pan while keeping the sequence deterministic
and fixture-free.

## Runbook

From the repository root:

```sh
scripts/run_metal_pipeline_tsan_stress.sh
```

For a longer pre-release soak and a separate reusable build directory:

```sh
APA_TSAN_STRESS_ITERATIONS=100 \
APA_TSAN_STRESS_DERIVED_DATA=/private/tmp/aagedal-metal-pipeline-tsan-soak \
scripts/run_metal_pipeline_tsan_stress.sh
```

The run passes only when the selected test succeeds and Thread Sanitizer emits no data-race report.
An unavailable system Metal device or missing edit shader is a test failure, not a silent skip.

## Coverage boundary

This is a host-side ownership and render-pipeline stress test. It intentionally avoids requiring a
physical second monitor: the second live pipeline is the production Clean Feed mirror seam, but the
test does not create an `NSWindow`, obtain an `MTKView` drawable, or validate display hot-plug and
HDR/SDR presentation. Those visual/external-display checks remain in their existing manual release
gate. Metal GPU kernel execution itself is outside TSAN instrumentation; this scenario detects host
memory races in source publication, cache access, mirrored state updates, task cancellation, and
the serialized offscreen renderer around that GPU work.

## Validation result

The committed default runner completed on 2026-08-25 with Thread Sanitizer enabled. Xcode repeated
the suite 40 times; all 40 tests passed in 13.057 seconds with no TSAN data-race report. Across those
runs the harness completed 320 combined overlap loops: 640 successful offscreen exports, 320
deterministically cancelled export requests, 320 worker-precache/main-owner navigation promotions,
and mirrored preview/Clean Feed parameter and source updates in every loop.

The complete `xcodebuild` test operation took 18.700 seconds after the TSAN build was available and
wrote its result bundle under `/private/tmp/aagedal-metal-stress-build/Logs/Test`. The test host also
printed its existing LMDB map-size and background-publication startup diagnostics; neither was a
Thread Sanitizer report and neither originated in the selected Metal stress suite.

The Phase 4.2 scheduling item is complete. The broader Phase 4.2 facade/actor split and unsafe-state
reduction remain open, as does the physical external-display release gate described above.
