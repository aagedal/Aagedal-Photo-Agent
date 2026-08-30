# Slow-volume responsiveness measurement gate

**Date:** 2026-08-30  
**Scope:** Repeatable Phase 3.1 evidence; this does not claim the manual slow-volume, Instruments, or
Thread Performance Checker exit gates are complete.

## Production measurement intervals

`FileSystemService` now emits stable `OSSignposter` intervals under subsystem
`com.aagedal.photo-agent` and category `FileSystemRead` for three common volume-facing reads:

| Interval | Boundary measured |
| --- | --- |
| `FolderScan` | browser folder enumeration, availability checks, and `ImageFile` snapshots |
| `SupportedFilesSnapshot` | filtered and sorted non-recursive URL inventory |
| `DropSourceClassification` | existence/type probes for sidebar and content-area drops |

Intervals end with a ready, deferred, cancelled, or failed result. Ready/deferred records contain only
private aggregate counts. Paths and filenames are never recorded. These names can be used unchanged in an
Instruments Points of Interest template while comparing local SSD, network, iCloud-placeholder, read-only,
and very-large-folder runs. A focused source-contract test locks the category, three interval labels,
private-count payloads, and absence of path/filename fields so measurement templates cannot silently drift.

## Deterministic responsiveness characterization

`SlowVolumeResponsivenessGateTests.blockedDropSourceProbeDoesNotBlockMainActor` injects a synchronous
drop-source probe that cannot return until the test releases it. While that simulated volume call remains
blocked, the test executes assertions on the main actor, verifies the probe is off-main, queues a second
request, cancels it, and then proves the queued request performed no filesystem probe. Synchronization uses
an explicit condition rather than elapsed-time thresholds or sleeps, so slower CI machines do not weaken
the result. Failure to enter the probe has a 30-second diagnostic deadline rather than hanging the gate.

Run the repeatability gate with:

```sh
scripts/run_slow_volume_responsiveness_gate.sh
```

The default is 20 serial iterations using one reusable Derived Data directory. The bounds are intentionally
finite; override them when needed:

```sh
APA_SLOW_VOLUME_GATE_ITERATIONS=100 \
APA_SLOW_VOLUME_GATE_DERIVED_DATA=/private/tmp/aagedal-slow-volume-100 \
scripts/run_slow_volume_responsiveness_gate.sh
```

An invalid iteration count (non-numeric, zero, or greater than 200) exits with status 64 before invoking
Xcode. A passing run is evidence that this actor boundary remains UI-responsive and cancellation-aware
under a deterministically blocked synchronous probe.

Focused validation on 2026-08-30 passed both tests once, then passed **10 test executions across five
serial iterations** in 0.020 seconds of Swift Testing runtime. The repeatability result bundle is:

```text
/tmp/aagedal-slow-volume-focused/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_10-14-30-+0200.xcresult
```

The integrated current-source gate subsequently passed its default **20 serial iterations**—40 test
executions—in 0.078 seconds of Swift Testing runtime:

```text
/tmp/aagedal-v3-responsiveness/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_10-21-14-+0200.xcresult
```

## Evidence this gate does not provide

The synthetic probe does not reproduce transport disconnects, kernel/provider behavior, iCloud download
state, permissions, real directory sizes, or target-hardware scheduling. Before Phase 3.1 can close, capture
the new intervals on each required volume class, exercise UI navigation and error presentation on supported
macOS tiers, and retain Thread Performance Checker evidence. Phase 3.2's representative large RAW/HDR
Instruments memory benchmark, peak budget, IOSurface/allocation checks, and pressure-recovery measurement
also remain separate and open.
