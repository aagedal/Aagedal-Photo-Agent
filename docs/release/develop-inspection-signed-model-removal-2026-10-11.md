# Develop inspection and signed-model removal — 2026-10-11

Baseline: `deefa37`, initially clean. Implementation commits: `0cbbcc9` (MCP inspection)
and `4989fba` (signed model removal); native-test/evidence changes accompany this record.
State remains **IMPLEMENTING**. These are bounded
prerequisites for the mandatory MCP Develop workflow and signed Whisper lifecycle;
no complete Phase 5A or release acceptance criterion closes.

## Behavior

`inspect_develop_template` accepts a canonical lowercase UUID and exact SHA-256 revision
from `list_templates`. It decodes the production Develop model, reports normalized controls
and crop policy, omits the dormant crop when the destination crop must be preserved,
and identifies destination decoder/as-shot and layer-identifier requirements. It revalidates
the authorized anchored inventory, routing and authorization before returning a bounded response.
Inspection creates no photo preview, write plan, approval or application authority. The bundled
helper now explicitly compiles the same Develop model as the app.

Signed Whisper lifecycle removal preflights current, rollback and high-water model entries,
refuses unsafe links and permissions, and permits removal of corrupt regular weights.
It durably rotates the generation before deletion so a suspended old-generation install,
repair or rollback cannot republish files afterward. Signed release evidence and the replay
floor survive removal and relaunch. A failed/partial removal requires reloading before retry;
exact-current repair remains available with fresh authority. This store/lifecycle API is
not yet connected to production signed Settings. Transfer-cache/orphan cleanup remains
separate, and production signing/catalog/Settings integration remains open.

The pinned-model native test now explicitly controls and checks the GPU request for both
CPU and GPU-request variants, checks saved provider/model/build provenance, and checks
transcript, preference and protected photo/WAV/relationship persistence after relaunch.
A successful GPU request does not prove that the backend used hardware acceleration.

## Environment and verification

Host: Apple M5 Pro, 64 GB RAM, arm64 macOS 27.0.1 (26A434), Xcode 27.0.
The ignored reviewed AuraFace package was copied from the main checkout and passes
`build_auraface_coreml.py verify`. Package checkouts were copied into the isolated derived
data directory; package resolution remained pinned, with automatic resolution and updates disabled.
No package pins changed. Test fixtures use disposable folders and isolated preferences.

The initial sandboxed build and repository checks could not write the compiler caches;
approved reruns resolve that constraint. The initial provider probe could not inspect child
processes through `/bin/ps`; an approved rerun passes. The first native build exposed missing
Develop model membership in the helper target; the project membership correction fixes it.
The first focused run passed discovery and signed lifecycle but failed the existing exact
MCP tool catalog expectation, which now includes the new tool. The first built native run
used the older cycle-86 speech fixture and stopped on the inherited “photo” word assertion
in both variants. The original qualified fixture was recovered from the earlier worktree
and verified against its recorded hash; both unchanged assertions then pass.
Sandboxed signature verification could not resolve developer trust; approved verification passes.

Focused verification passes **132 declared tests / three suites**, zero failures/skips;
Xcode reports 185 parameter-expanded runs. Both native cases pass, zero failures/skips:
GPU request in 33.085 seconds and CPU in 30.778 seconds. Each executes the actual bundled
provider, retains the saved transcript and exact provenance, and checks relaunch readiness,
GPU preference, visible text and protected bytes. The exact fixture is the previous public
synthetic recording, SHA-256 `eba04c12be2073f1c6d04461553a7f34a67138f3c568ce8b236e6dd73dd3e0c8`.
These runs provide persistence/provider evidence, not broad transcription accuracy.
Final integrated regression passes **3,906 passed, two skipped, zero failed out of 3,908
reported tests**, across 388 Swift suites in 123.411 seconds. The two skipped opt-in Sony
cases provide no new authentic-camera evidence. Existing host LMDB map-full and QoS
runtime diagnostics remain outside this bounded qualification; no performance/device
gate closes. `full.xcresult`, `full.log` and `full-summary.json` retain the final result.
Final source/project/probe SHA-256 identities relative to the clean baseline are in
`source-sha256.json`; no subsequent application source changes occurred.

Independent read-only review found no correctness/security blocker in implementation,
project integration, test coverage or user-facing scope descriptions. Review explicitly
retains signed Settings integration, cache cleanup, actual GPU-backend proof and Develop
application as unfinished.

## Evidence and repeatable commands

Ignored evidence directory: `build/continuation-3/`.

- `baseline-approved.xcresult`: 13 existing runner tests pass; this preparation run is not
  the final integrated source identity.
- `provider-gpu-approved/report.json`: all 10 real production-provider CLI cases pass:
  explicit/automatic CPU language, silence, timeout, cancellation/reaped child,
  changed audio/model/executable, revoked authorization and GPU request. Base model:
  147,951,465 bytes, SHA-256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`.
  Runtime SHA-256 `54f5d1c12e9d2a735059fed43f8f134ff24a527c295ec819cad77185db667c33`.
  Supplied speech is the existing local synthetic PCM fixture; this is not camera,
  recognition-accuracy, offline-network-denial or accelerated-backend qualification.
- `mcp-helper-final.json`: actual bundled helper persistent-STDIO probe passes, including strict
  new-tool schema/invalid-argument refusal and existing transport contracts. No grants
  or user files are changed.
- `focused-final.xcresult` / `focused-summary.json`: focused pass described above.
- `native-corrected-fixture.xcresult` / `native-summary.json`: native pass described above.
- `repository-final.log`: final repository checks pass.
- `model-bundle.log`: required compiled AuraFace weights match the pinned hash.
- `signature-approved.log`: development app signature verifies with `--deep --strict`.
- App: `build/continuation-3/Build/Products/Debug/Aagedal Photo Agent.app`, version 3.0.0,
  build 741. This is a Debug verification build, not a notarized/final Release candidate.
- Failed/preparation logs are retained alongside final logs.

Focused test command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath build/continuation-3 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPTemplateDiscoveryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDistributionStateStoreTests' \
  -resultBundlePath build/continuation-3/focused-final.xcresult
```

Integrated regression uses the same command without the three test selectors. Native
qualification uses the UI Smoke Tests scheme and the two pinned Whisper tests, supplying
`TEST_RUNNER_APA_NATIVE_WHISPER_MODEL` and `TEST_RUNNER_APA_NATIVE_WHISPER_AUDIO` with
existing local Base-model and PCM speech paths. Source hashes and exact result summaries
remain in the evidence directory. Final signing/distribution and broader release gates remain open.

## GPU default follow-up

After `abb21a8`, the user requested GPU acceleration by default. Whisper Settings now
requests GPU when no preference exists, while preserving saved true/false preferences.
The shared Settings value applies to bundled and custom Whisper. Initialization does not
persist an implicit default or grant provider execution consent. Focused setup tests pass
(`build/continuation-3/gpu-default.xcresult` / `gpu-default.log`), including absent preference,
saved GPU/CPU choices and CPU selection surviving reconstruction. `git diff --check` passes.
Earlier full/native results above identify the pre-default-change source; this narrow
preference change was validated with the affected setup suite.
