# Fresh FFmpeg 9.0.2 candidate admission — 2026-10-13

The user supplied the full Apple Silicon build at
`/Users/truls.aagedal/.t3/worktrees/ffmpeg-apple-silicon/t3-118d2ca2/dist/9.0.2/full`.
Its `ffmpeg` is arm64, 60,126,976 bytes, SHA-256
`9efa9e08558472806b57cd3ad846c5bfdb8d18efd6dc3fb9fa5cebf8a97f990f`.
It reports version 9.0.2 and includes Whisper. No source or binary in the supplied
checkout was modified.

## Admission result

**Not admitted as the app's replacement binary.** The supplied build's filter
source remains byte-identical to the original unpatched fixture:
`322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6`.
The binary also retains the raw JSON format string
`{"start":%lld,"end":%lld,"text":"%s"}`. This inserts recognition text without
JSON escaping and lacks Photo Agent's sample-bound timing and error-propagation
corrections. The [bundled artifact contract](../provenance/ffmpeg-whisper-bundled.md)
still applies. A version increase cannot remove those requirements.

The default real-process smoke probe passes filter options, local WAV decoding and
controlled missing/malformed-model refusal. It uses no model download or speech
inference and cannot establish canonical transcript correctness.

Photo Agent's existing pinned patch applies cleanly with zero fuzz to the supplied
9.0.2 source. The prepared output has the exact established corrected-source hash
`eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71`.
It is retained locally at `build/ffmpeg-9.0.2-admission/af_whisper-patched.c`.
Preparation does not rebuild or qualify a binary. The bundled 9.0.1 resource and
component manifest remain unchanged.

## Evidence and next action

Ignored evidence: `build/ffmpeg-9.0.2-admission/` contains the version report,
`process-smoke/` fixtures/logs/report, patch-admission output and patch tests.
Use the repository's `scripts/ffmpeg/af_whisper-canonical-json.patch` in a new 9.0.2
build, then capture exact source/dependency/recipe/binary provenance and corresponding
source delivery. Before replacement, verify actual canonical output/timing and failure
behavior, image codecs and the signed app's generated Whisper artifact descriptor.
The current app's manifest, notices and generated component documentation must be
updated to that qualified artifact together. This check closes no release gate.
