# Photo Agent FFmpeg 9.0.2 integration — 2026-10-13

Implementation: `261b5d2`, following the rejected unpatched full candidate.
The app bundles the dedicated Photo Agent variant supplied at
`/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-8b3606d8/dist/9.0.2/photo-agent/ffmpeg`.
No shared/full binary or other application's video-to-SRT configuration was changed.
State remains **IMPLEMENTING**; this is local integration, not release publication.

## Identity and packaging

- Imported artifact: arm64, 60,477,800 bytes, SHA-256
  `4020b2049584b45e9bda4767ed4fd26cc0dd276dca0bcbac7c069beb97b3cfd1`.
- Its Whisper source matches the established corrected member exactly:
  `eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71`.
  JSON escaping, sample-bound timing and error propagation remain present. The
  variant also includes its recorded YADIF VideoToolbox teardown correction.
- The external artifact was subsequently Developer ID signed by its builder during
  this task. Integration retains the imported pre-signing artifact rather than
  silently following changes to that external path.
- Manifest, generated README source offer, dependency notices and
  [current provenance](../provenance/ffmpeg-photo-agent-9.0.2.md) identify 9.0.2.
  Recipe snapshots/patches are content-pinned. A narrow Git whitespace rule preserves
  original imported recipe/patch bytes; application files and generated notices
  retain normal checks. Notice aggregation documents whitespace normalization while
  retaining original source hashes.
- Xcode signs the copied helper and then generates its runtime descriptor. Tested
  signed helper: 60,144,464 bytes, SHA-256
  `f3c3e9c527cece3e01a11a6592f714c358d66f5c97782ded21a8c4d1b8bb86ce`.
  `whisper-runtime.json` matches those bytes and the existing
  `photo-agent-whisper-json-v1` contract. Bundled manifest/notices match repository
  payloads. Runtime authority uses the signed helper identity, not the source digest.

## Verification

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a). Ignored evidence:
`build/ffmpeg-9.0.2-photo-agent/`. Tested app: development-signed Debug build 742,
version 3.0.0, `build/continuation-13/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures are the tracked synthetic gradient, generated disposable media and the
Whisper distribution's public JFK sample. No model download or user media/preferences
were changed.

- **Ten production runner/provider/parser/reader/provenance cases pass** on the
  imported helper (`provider-approved/report.json`) and again on the actual app-signed
  helper (`provider-signed/report.json`): explicit/automatic CPU language, no speech,
  timeout, cancellation, changed audio/executable/model, post-inference authorization
  refusal and GPU request. GPU-request success does not prove hardware acceleration.
- **Seven real-process cases pass** (`process-integrated/report.json`): filter options,
  local WAV decoding, missing/malformed model refusal, bounded canonical silence/speech
  JSON and invalid destination refusal. Supplied Tiny English model SHA-256:
  `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`;
  speech SHA-256: `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
- **Nine synthetic photo comparisons execute successfully** (`image-comparison/report.json`).
  Both decoders agree for each encoded artifact. Three JPEG XL and two HDR AVIF cases
  preserve exact decoded samples across encoders. Four SDR AVIF encodings differ,
  so aggregate `allDecodedSamplesEqual` is **false**, not a parity pass. Color
  declarations match. Mean absolute channel change is 1.05–1.11 on a 0–255 scale,
  maximum 12–13 on the tiny fixture (`avif-drift.json`). This is encoder drift evidence,
  not real-photo visual quality/HDR/color acceptance.
- **Integrated regression passes 4,050 tests, two opt-in Sony skips, zero failures**
  out of 4,052 tests / 396 Swift suites in **126.862 seconds** (`app-full.xcresult`,
  `app-full-summary.json`, `app-full.log`). Four existing QoS summary warnings and
  test-host `MDB_MAP_FULL` logs retain performance/environment gates.
- Component/repository/generated-documentation/whitespace checks and development
  app/helper signatures pass (`component-validator.log`, `repository.log`,
  `app-signature.log`, `helper-signature.log`). Exact signed descriptor validation is
  retained in `signed-descriptor-check.json`. Independent provenance, notices,
  runtime-admission and byte-exact snapshot review passes.
- The initial restricted probe could not run `/bin/ps`; approved execution permits
  process-tree checks and passes. No automatic approval-review rejection blocked work.
- All 47 integration file hashes match `261b5d2` (`source-sha256.json`); later
  handoff edits change documentation only.

The CLI probes do not qualify a new native consent/provider-setup UI session.
The builder reused compiled dependencies. Clean independent rebuild, complete modified/
dependency source publication, legal source-delivery verification, release signing/
notarization and representative native/provider/device/color/accuracy gates remain open.
Builder-reported codec/YADIF/Whisper checks remain separate from local evidence.

Repeatable commands (use new output/result directories when repeating):

```sh
python3 -B scripts/ci/probe_whisper_provider.py \
  --binary 'build/continuation-13/Build/Products/Debug/Aagedal Photo Agent.app/Contents/Resources/ffmpeg' \
  --model /path/to/ggml-tiny.en.bin --audio /path/to/jfk.wav \
  --output build/ffmpeg-9.0.2-photo-agent/provider-signed --gpu
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-13 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/ffmpeg-9.0.2-photo-agent/app-full.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-13/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```
