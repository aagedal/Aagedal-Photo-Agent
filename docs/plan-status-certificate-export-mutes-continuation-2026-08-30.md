# Plan-status certificate, export, and section-mute continuation — 2026-08-30

## Scope and checklist result

This continuation implements two more Phase 3.1 filesystem slices and one Phase 4.1 Develop state-owner
extraction. These changes advance broad open gates without completing the remaining filesystem inventory,
real-volume measurement, manual, or architectural exit conditions, so the app-improvement audit remains
**63 of 75 complete**.

## C2PA signing-configuration filesystem owner

PEM and PKCS#12 certificate reads, parsing, staged certificate replacement, private-key Keychain replacement,
rollback, status inspection, and removal now cross the serialized `C2PASigningConfigurationService` actor.
Import returns immutable evidence that distinguishes cancellation before a read, cancellation after a
non-preemptible read, and cancellation observed after the certificate/key pair has durably committed. Failed
certificate or Keychain replacement restores the previous pair instead of leaving mixed signing material.

Settings owns task and request identity, cancels replaced or disappearing work, and rejects stale completion.
Certificate availability is refreshed at app scope and injected into FTP upload presentation. Availability
fails closed until the actor confirms the saved file exists, and a stale saved path is cleared if the file has
disappeared. Ten focused tests cover transaction rollback, successful replacement, off-main parsing, actor
serialization, both cancellation boundaries, app-scoped availability, view/request wiring, and the test-signer
manifest contract.

## Keyword text-export filesystem owner

Keyword-list and Structured Keyword text exports no longer call synchronous `String.write` from their
MainActor views. Both use the serialized `TextFileExportService`, which atomically writes UTF-8 data and
returns immutable evidence for pre-write cancellation, committed byte count, and cancellation observed after
a durable commit. Each editor owns request identity and its export task, cancels superseded or disappearing
work, and cannot publish an old completion. Five focused tests cover off-main atomic commit, pre-cancellation,
serialization, queued cancellation, durable-after-cancel evidence, and both editor source contracts.

## Develop section-mute owner

`DevelopSectionMuteCoordinator` now owns the sticky Color, Exposure, Detail, Tone Curve, HSL, and Film mute
state as one workspace-lifetime value snapshot. `EditWorkspaceView` routes all six section bindings and
toggles through that owner while preserving the existing image-navigation lifetime and render-only behavior.
Two characterizations prove independent toggles, exact render snapshots, retained workspace state, and
explicit restoration into a new owner.

## Full-load timing stabilization

The first unfiltered run exposed one scheduler-starved backup-inventory probe: under 190-suite parallel load,
the test task could miss its five-second start ceiling even though focused behavior remained immediate. The
inventory and sibling preview probe ceilings now use the suite's established 30-second full-load budget. No
production behavior, polling interval, or successful-path delay changed. The two focused backup suites passed
all **10 tests** in 0.011 seconds:

```text
/tmp/aagedal-v3-session-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_11-52-52-+0200.xcresult
```

## Integrated validation

A clean build of the complete application and unit-test targets succeeded before the final availability
integration, and the subsequent focused test build recompiled every changed application and test source:

```text
xcodebuild build-for-testing -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-v3-session-20260830 CODE_SIGNING_ALLOWED=NO
** TEST BUILD SUCCEEDED **
```

The combined implementation selection passed **17 tests in 3 suites**:

```text
/tmp/aagedal-v3-session-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_11-53-09-+0200.xcresult
```

The unfiltered current-source run passed **1,658 tests in 190 suites** in 45.194 seconds of Swift Testing
runtime:

```text
/tmp/aagedal-v3-session-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_11-53-17-+0200.xcresult
```

The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature, and SwiftUI
background-publication diagnostics; they did not produce a build or test issue.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work includes lower-priority direct
filesystem paths such as code-replacement source/bookmark reads, quick-list creation, LUT import, and broader
roster/approved-list stores, plus the full blocking-work inventory. Phase 4.1 still includes crop, layer,
white-balance and broader interaction ownership; render-policy/Clean Feed publication; export presentation;
and persistence ownership.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; local/network/iCloud/read-only/large-folder Thread Performance Checker captures; Instruments
RAW/HDR memory benchmarks; and production AuraFace publishing plus supported-macOS validation.
