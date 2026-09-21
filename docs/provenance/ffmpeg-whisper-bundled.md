# Bundled FFmpeg with Whisper — development integration, 2026-09-21

Photo Agent now embeds the attributed full FFmpeg 9.0.1 build derived from Aagedal Media
Converter's source companion, with Photo Agent's canonical JSON and sample-bound timing
patch. It is not a byte-for-byte copy of Media Converter's binary. That unmodified emitter
does not satisfy Photo Agent's transcript parser contract.

## Exact artifact and sources

- Resource: `Aagedal Photo Agent/Resources/ffmpeg`, arm64, 55,361,912 bytes.
- Before app signing SHA-256: `54f5d1c12e9d2a735059fed43f8f134ff24a527c295ec819cad77185db667c33`.
- Imported from the cycle-79 incremental rebuild at
  `build/qa-v3-cycle78-ffmpeg/sources/ffmpeg-9.0.1/ffmpeg`. The older `dist/` copy is not used.
- Patched `af_whisper.c`: `eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71`.
- Attributed source companion `ffmpeg-9.0.1-source.tar.gz`:
  `23587fed102cfe66910db1d4ae66b50565387a1750e039fb10fde6fbfd027e71`.
- Additional original libvpx `v1.16.0.tar.gz` (restores omitted build source scripts):
  `7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c`.

The local source companion is retained in the neighboring Media Converter checkout's
`build/attribution/` directory. It is an attributed snapshot, not a claim that all contents
equal a pristine upstream tag. The manifest therefore pins that snapshot hash rather than
claiming the former image-only build's upstream or recipe revision. Preparation and patches
are content-pinned in the component manifest. See [rebuild instructions](../../scripts/ffmpeg/README.md).
This artifact reuses the cycle-78 compiled dependencies with the cycle-79 filter rebuild;
it is not an independent second clean reproduction.

## Capabilities and signing

Exact configuration, linked system libraries, filter options, license report, image comparisons
and CPU process probes are recorded in [machine-readable evidence](ffmpeg-whisper-bundled.json).
The build retains image codecs and enables `--enable-whisper`, `--enable-metal`,
`--enable-gpl` and `--enable-version3`. Full audio/video, device and network capabilities are
compiled in. The transcription runner continues to restrict protocols to local files and use
its private job directory; replacing the executable does not grant an external source URL.

The source artifact's ad-hoc signature passed `codesign --verify --strict`. The existing
Xcode helper-signing phase applies the distribution identity and hardened runtime before
the containing app is signed. That operation changes the file digest; runtime admission
must use the descriptor generated after helper signing, not the source artifact hash above.
This is development integration, not signed/notarized release evidence.

## Fresh checks

All nine synthetic image encoding/decoding comparisons preserve exact decoded samples
against the prior image-only resource. Real CPU subprocess probes using the existing local
test model pass speech and silence with bounded millisecond timestamps, reject missing and
malformed models and an invalid output destination, and exit unsuccessfully on cancellation.
Speech recognition still misidentifies words in the synthetic fixture; exact timestamps do
not establish transcription accuracy. These probes do not certify downloaded models or GPU
behavior. Source-pinned canonical escaping and fault handling remain covered by the sanitizer
harness; the bundled-component validator also now requires the actual Whisper filter.

## Repeatable process qualification

Repository CI now runs `scripts/ci/probe_ffmpeg_whisper.py` against the bundled executable.
It verifies the runner's required filter options, decodes a generated local five-second PCM
WAV, and requires controlled Whisper initialization failures for missing and malformed models.
A crash, successful exit, or unrelated error cannot satisfy either negative case. No model
download or network access is needed. The focused probe tests reject invalid JSON schemas,
duplicate fields, noninteger/out-of-bounds timestamps and misleading speech/failure evidence.

The same command accepts an explicitly supplied local model and speech fixture:

```sh
python3 -B scripts/ci/probe_ffmpeg_whisper.py \
  --model /path/to/model.bin --audio /path/to/speech.wav \
  --output build/whisper-process-evidence
```

The output directory must not already exist. It retains input fixtures, logs, transcripts and
a JSON report that identifies the binary, model and successful inference inputs by SHA-256.
Without `--output`, temporary evidence is removed and the report is printed. Supplying a model
adds CPU silence inference, canonical JSON/sample-duration checks and invalid-destination
failure propagation. Supplying speech also requires some non-marker text; this is not a
recognition-accuracy assertion. Empty silence output is permitted, but missing output is not.
Reports explicitly distinguish executed model/speech checks from the default smoke scope.
These checks do not qualify GPU execution, cancellation, real disk-full/closed-pipe behavior,
downloaded-model provenance, recognition quality or a second clean reproduction.

## Redistribution

Complete dependency notices ship in `License-FFmpeg-Dependencies.txt` and are available in
Settings → Licenses. The build reports GPL version 3 or later. Preserve the source snapshot,
libvpx source repair, local patch, preparation scripts and notices with release records.
Before distributing a final release, provide the complete corresponding source companion
and its accessible download location alongside the app, and verify a clean rebuild from it.
An unmodified upstream FFmpeg archive alone does not cover this binary's modified filter or
statically linked dependencies. This development commit does not claim that companion has
already been published or that final legal review is complete.
