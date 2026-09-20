# Cycle 75 — local discovery, MCP protocol and AVIF signaling

Baseline `18b288f`, initially clean, on arm64 macOS 27.0 / Xcode macOS 27 SDK.
Implementation and regressions are committed as `5da3ce2`; final tests exercised these exact
source changes before commit. Documentation follows separately.
Debug app 3.0.0, build 739. Three sub-agents owned discovery, protocol hardening and
Whisper output investigation; the coordinator owned integration, candidate comparison,
validation, documentation and commits. Independent cross-review found no remaining
blocking finding in this change. Release state remains IMPLEMENTING.

## Implemented

- `list_templates` supports the existing default local Templates directory as well as custom
  libraries. Both require explicit root authorization. Discovery creates no directories and
  never falls back from a stale custom bookmark or enabled iCloud route. It rechecks routing
  identity and the complete inventory after final scope resolution, then authorization and
  anchored ancestors before returning names, stable UUIDs and revisions. iCloud is still unavailable.
- MCP distinguishes invalid JSON from invalid request envelopes, preserves readable request IDs,
  rejects null IDs and non-object parameters, and prevents malformed initialized notifications
  from advancing the lifecycle. Unencodable and oversized results produce bounded errors.
- A bounded FFmpeg Whisper NDJSON parser retains exact integer millisecond segments and original
  text, derives editable text, and explicitly reports detected language as unavailable. It refuses
  malformed/ambiguous shapes, invalid timing/UTF-8, no-speech output and resource-limit violations.
  It is not yet connected to inference, persistence, model installation or transcript approval.
- FFmpeg AVIF encoding declares the already-rendered input primaries/transfer before decoding.
  FFmpeg copies first-frame values over output-only settings; ICC-tagged ImageIO TIFFs previously
  produced unspecified primaries/transfer. Actual encoder tests now assert sRGB, Display P3 and
  Rec.2020 nclx values and decodability. This declaration preserves samples rather than adding a
  color transform. Existing Adobe RGB approximation and HDR fallback policy are unchanged.
  Source evidence: the attributed `fftools/ffmpeg_enc.c` copies first-frame
  `color_primaries` and `color_trc` into the encoder context at lines 268–269.
  Output-only scale tagging would transform samples; explicit input interpretation avoids that.
- A reusable candidate comparison script checks nine synthetic image cases, using both binaries
  to encode and both to decode every case. It checks expected dimensions/depth and AVIF nclx
  signaling, then compares decoded PNG sample hashes without color conversion.

## Verification

The initial focused run passes **64 tests / three suites**, zero failures/skips, in 1.768 seconds.
The pre-AVIF-fix complete suite passes **3,088 tests / 326 suites**, zero failures/skips, in
133.528 seconds. After the AVIF fix, focused checks pass **nine tests / two suites**, zero
failures/skips, in 1.200 seconds. The final-source complete suite passes **3,090 tests /
326 suites**, zero failures/skips, in **119.492 seconds**. `xcresulttool` summaries confirm
those totals. Repository validation and staged/unstaged whitespace checks pass. Existing
`MDB_MAP_FULL` diagnostic logging remains an observation, not a failed assertion; performance
and real-environment gates remain open.

Initial sandboxed Xcode could not write its normal compiler/package caches; approved ordinary
Xcode cache access resolved this. Tests use disposable synthetic fixtures. No personal photos,
production recipients or existing app authorization preferences were modified.

The actual embedded `photo-agent-mcp` executable returns eight valid correlated protocol responses
for initialize, invalid lifecycle/envelopes/params, discovery, ping and malformed JSON, exits 0,
and emits zero stderr bytes. SHA-256:
`454923afc102363917901756a2dd5de1f5e37fa344e923f4a2188443e86ed1f7`.
Evidence: `build/qa-v3-cycle75-protocol-bundled.json`. This is direct executable validation,
not supported-client or native UI acceptance. Cycle 74 remains the latest native UI evidence.

The final comparison reports **nine passing cases**, with identical decoded samples across all
four encoder/decoder combinations, expected 8/16-bit dimensions, and correct AVIF nclx fields.
Cases: AVIF sRGB, P3, Rec.2020, Adobe fallback, P3 HLG, Rec.2020 HLG; JPEG XL SDR,
16-bit SDR and 16-bit lossless. Sources are the tracked CC0 synthetic TIFF and a generated
16-bit PPM gradient; hashes and binary sizes/hashes are retained in the report.
Evidence: `build/qa-v3-cycle75-ffmpeg-signaled/report.json` and sibling process logs.

The first comparison attempt found a fixture arithmetic overflow before any encoding. The
corrected comparison established sample parity, then nclx inspection exposed the real TIFF
signaling issue. The final script explicitly declares the synthetic input interpretation and
checks actual color tags. Synthetic sample parity and container tags do not prove visual color,
ICC interpretation, HDR display behavior or complete image/RAW compatibility. No bundled
binary was replaced and no artifact/provenance gate is marked complete.

```sh
python3 scripts/ci/compare_ffmpeg_image_candidate.py \
  --baseline 'Aagedal Photo Agent/Resources/ffmpeg' \
  --candidate '../Aagedal-Media-Converter/Aagedal Media Converter/Binaries/ffmpeg' \
  --output build/qa-v3-cycle75-ffmpeg-signaled
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-cycle75-full-final.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

The tested app is at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
All cycle logs and result bundles are ignored under `build/qa-v3-cycle75-*`.

## Whisper blocker and remaining release work

The attributed candidate's Whisper filter inserts transcript text into JSON without escaping.
Quotes/backslashes can make invalid JSON or silently alter decoded meaning. Parser validation
cannot repair that authority boundary. Fix and reproducibly rebuild the emitter before inference
integration; see [the exact source investigation](ffmpeg-whisper-json-evidence-2026-09-20.md).
The emitted format also contains no detected-language evidence.

Next implementation: production MCP metadata/Develop template application, operations/status/
cancellation, face and transcription tools, two-phase guarded IPTC commits, iCloud discovery
scope, corrected FFmpeg artifact/provenance and complete Whisper provider/model lifecycle.
Preserve Apple Speech and reviewed approval semantics. llama.cpp/GGUF remains deferred to 3.1.

Remaining release evidence includes supported real MCP clients; authentic Sony ingest/archive/
reassociation/transcription/delivery; installed-language offline speech; real iCloud/multi-Mac and
FTP/FTPS/SFTP drills; external metadata interoperability; keyboard/VoiceOver/IME and display/HDR;
hardware/performance/storage recovery; signed model server/update/rollback; qualified privacy/legal
review and protected remote CI. Then build and inspect the exact candidate, obtain independent
readiness review and final user acceptance. Signing/notarization/publication remain separate
release steps. The manual checklist remains a draft, not a ready-for-acceptance declaration.
