# FFmpeg Whisper canonical JSON source correction

This is a reproducible source correction and isolated C regression harness, **not a built,
installed or approved transcription provider**. No neighboring checkout or binary is modified.

## Attribution and source identity

`fixtures/af_whisper.c` is the unmodified FFmpeg filter source extracted read-only from the
attributed Media Converter source archive described in
[`ffmpeg-whisper-json-evidence-2026-09-20.md`](../../docs/release/ffmpeg-whisper-json-evidence-2026-09-20.md):

- Archive member: `sources/ffmpeg-9.0.1/libavfilter/af_whisper.c`.
- Original member SHA-256: `322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6`.
- Patched member SHA-256: `eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71`.
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
  JSON frame metadata also receives the preserved text. The Swift parser now omits complete
  marker-only segments from editable text while retaining exact evidence; embedded mentions and
  split fragments remain unchanged.
- Inference, missing-context, null-segment, allocation, metadata and destination write/flush
  errors propagate through `run_transcription`. Failed batches retain their buffered samples.
- Queue, VAD, and final-frame callers propagate the failure and release owned frames/segments.
  VAD failure is an error. `activate` propagates final-frame, destination flush/close and
  upstream input errors before reporting successful EOF.
- Segment times are constrained to the audio samples actually supplied to each inference
  call. Negative ticks become zero; padded/oversized ticks stop at the chunk's end; reversed
  ends become the bounded start. Bounds are applied before multiplying model ticks, avoiding
  integer overflow. Text and zero-duration segments remain preserved. These are normalized
  emitter timestamps, not unchanged raw model timestamps or evidence of recognition accuracy.
- Buffer origins are tracked in integer samples using the incoming frame time base. Partial
  queue/VAD consumption advances by the exact consumed samples, avoiding accumulated float
  millisecond truncation. Absolute start/end milliseconds round down to stay within the
  supplied interval. Existing frame PTS origins are retained; discontinuity handling is not
  established by these unit regressions.
- Buffered sample compaction uses `memmove` because source and destination can overlap.

## Executed regression evidence and boundaries

The local runner passed 63 exact text roundtrips (including all representable non-NUL control
bytes, Unicode, literal escape sequences, blank markers, empty text, whitespace and 50 seeded
mixed strings), 14 runtime/fault scenarios, 11 sample-bound timing regressions (including
five-second padded silence ticks, fractional chunk origins, submillisecond audio, successive
partial consumes and extreme/negative/reversed ticks), allocation failure injection at 12 successive
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
edge case (for example invalid backend segment counts, missing/discontinuous input timestamps,
or oversized incoming audio frames). Source admission, runtime bounds and real-backend testing
remain required. The cycle-78 binary predates the sample-timing correction and its runtime evidence does not
validate these new timing bounds. No upstream submission, updated binary rebuild or provider
release gate is claimed here.

## Prepare the full attributed build

`prepare_full_candidate.py` requires Python 3.12 or later and the two local archives below.
It admits their exact recorded SHA-256 values before extracting into a new directory, applies
the pinned Whisper patch, and records the recipe changes and hashes in
`photo-agent-preparation.json`. It does not build, install, sign or approve a provider.

```sh
python3 scripts/ffmpeg/prepare_full_candidate.py /path/to/ffmpeg-9.0.1-source.tar.gz \
  --libvpx-archive /path/to/v1.16.0.tar.gz \
  --output build/ffmpeg-candidate --jobs 4
bash build/ffmpeg-candidate/rebuild.sh
```

The source companion hash is `23587fed102cfe66910db1d4ae66b50565387a1750e039fb10fde6fbfd027e71`.
The libvpx original archive hash is `7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c`,
recorded in the attributed build's `evidence.json`. Its `build/` directory contains required
source scripts, which the companion's blanket build-directory exclusion omitted. Preparation
restores only those files. It also fixes the companion replay's HarfBuzz guard, which otherwise
skips compilation of an already extracted source tree, and limits parallel jobs. No codecs are
removed and no compiled dependency prefix is reused. Recipe `download_file` calls refuse;
this is not a network sandbox for arbitrary third-party build programs. The archive and original
dependency archive must be supplied locally. Missing inputs or later build failures remain
explicit failures; preparation alone does not establish completeness or reproducibility.
The retained SVT-AV1 CMake cache is removed so CMake can regenerate its old absolute workspace
paths; source files in its uppercase `Build/` directory remain intact.
FreeType's retained generated `freetype2.pc` is also removed so `make` regenerates the
installation prefix before HarfBuzz resolves that dependency.
If Xcode's `xcrun` resolver cannot locate an already installed Metal toolchain, the retained
recipe accepts explicit `FFMPEG_METALCC` and `FFMPEG_METALLIB` environment paths. Record the
selected compiler path/version in build evidence; do not disable Metal to bypass that failure.
