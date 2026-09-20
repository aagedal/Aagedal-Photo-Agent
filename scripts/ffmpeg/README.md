# FFmpeg Whisper canonical JSON source correction

This is a reproducible source correction and isolated C regression harness, **not a built,
installed or approved transcription provider**. No neighboring checkout or binary is modified.

## Attribution and source identity

`fixtures/af_whisper.c` is the unmodified FFmpeg filter source extracted read-only from the
attributed Media Converter source archive described in
[`ffmpeg-whisper-json-evidence-2026-09-20.md`](../../docs/release/ffmpeg-whisper-json-evidence-2026-09-20.md):

- Archive member: `sources/ffmpeg-9.0.1/libavfilter/af_whisper.c`.
- Original member SHA-256: `322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6`.
- Patched member SHA-256: `611490390f75fe07ab463046856c93a860758f898442ff808783a3d1131d7b13`.
- Copyright (c) 2025 Vittorio Palmisano; FFmpeg, GNU LGPL 2.1 or later. The original
  copyright/license header is retained. See the included [`COPYING.LGPLv2.1`](COPYING.LGPLv2.1).
- The license text was copied from the neighboring Media Converter checkout's attributed
  `docs/provenance/4.4-local-builds/mpvkit-sources/FFmpeg-COPYING.LGPLv2.1`.
- `af_whisper-canonical-json.patch` records local modifications made 2026-09-20 and is
  distributed under the same LGPL 2.1-or-later terms as the modified source.

The archive filename identifies the local attributed build; this package does not assert
that its contents match an independently fetched upstream release tag. The original fixture
is included so repository regression checks do not depend on an untracked local source tree.

## Reproduce

From the repository root:

```sh
python3 scripts/ffmpeg/prepare_whisper_source.py scripts/ffmpeg/fixtures/af_whisper.c
python3 scripts/ci/test_ffmpeg_whisper_patch.py
```

Preparation requires the exact original source hash and applies the patch with zero fuzz
inside a temporary directory. It verifies only unless `--output /path/to/new/af_whisper.c`
is provided; that destination must not exist. It never writes into the input source tree.
The test runner accepts `--source` to verify another extraction of the same pinned member
and `--cc` to select a C compiler. A compiler with AddressSanitizer and UndefinedBehaviorSanitizer
support is required; absent tooling is a failure, not a silently skipped check.

## Behavior changed

- JSON quotes, backslashes and all non-NUL ASCII control bytes are escaped. UTF-8 bytes,
  integer millisecond timing and the `start`, `end`, `text` line format are retained.
- **JSON now retains the original segment text**, including leading whitespace, empty
  strings and literal `[BLANK_AUDIO]` text (including split pieces). Unlike the old emitter,
  it does not strip a leading whitespace byte or remove case-insensitive blank-audio markers.
  This is intentional lossless canonical data; semantic no-speech classification of such
  model tokens still requires live-model validation. Text/SRT retain their existing cleaning;
  JSON frame metadata also receives the preserved text.
- Inference, missing-context, null-segment, allocation, metadata and destination write/flush
  errors propagate through `run_transcription`. Failed batches retain their buffered samples.
- Queue, VAD, and final-frame callers propagate the failure and release owned frames/segments.
  VAD failure is an error. `activate` propagates final-frame, destination flush/close and
  upstream input errors before reporting successful EOF.
- Buffered sample compaction uses `memmove` because source and destination can overlap.

## Executed regression evidence and boundaries

The local runner passed 63 exact text roundtrips (including all representable non-NUL control
bytes, Unicode, literal escape sequences, blank markers, empty text, whitespace and 50 seeded
mixed strings), 13 runtime/fault scenarios, allocation failure injection at 12 successive
allocation positions, source-hash refusal and existing-output refusal under ASan/UBSan.

The harness compiles **the extracted patched functions**, not a reimplementation of their
logic: escaping, transcription and activation. Minimal dependency stubs inject inference,
allocation, metadata, write, last-frame, flush and close failures. It checks exact decoded JSON,
no leaks in tracked allocations, failed batches remaining buffered, overlapping compaction,
no-speech success and suppression of successful EOF on failures. Frame/VAD callsite wiring
is source-reviewed; the harness stubs final-frame dispatch and does not prove the full FFmpeg
or whisper.cpp ABI, actual AVIO transport behavior or actual model results.

Before release, build the complete attributed FFmpeg candidate with this patch, record the
source/build/binary hashes and legal provenance, verify successful process exit and canonical
output with live audio/models, and run disk-full/closed-pipe/cancellation/inference/VAD failures
through the real application process boundary. This correction does not address every upstream
edge case (for example invalid backend segment counts, overflowing backend timestamp arithmetic,
or oversized incoming audio frames). Source admission, runtime bounds and real-backend testing
remain required. No upstream submission, binary rebuild or provider release gate is claimed here.
