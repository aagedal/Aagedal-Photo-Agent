# FFmpeg Whisper canonical output investigation

This is a parser prerequisite, not an implemented transcription provider or a closed Phase 5A gate.
No binary, model, provider preference, persisted transcript schema or approval authority changes.

## Exact local upstream evidence

Inspected the neighboring Media Converter checkout's attributed source archive, read-only:

- Archive: `Aagedal-Media-Converter/build/attribution/ffmpeg-9.0.1-source.tar.gz`.
- Recorded archive SHA-256: `23587fed102cfe66910db1d4ae66b50565387a1750e039fb10fde6fbfd027e71`.
  This is the manifest's recorded hash; the complete archive was not rehashed in this investigation.
- Member: `sources/ffmpeg-9.0.1/libavfilter/af_whisper.c`.
- Extracted member SHA-256, measured: `322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6`.
- Attribution manifest: `docs/provenance/4.4-local-builds/ffmpeg-attributed-build/source-archive.json`
  in that checkout. The candidate binary/build investigation is recorded in cycle 74.

The emitter at lines 283–285 writes one object per line, in `start`, `end`, `text` order.
Timestamps are signed 64-bit integer **milliseconds**, with the queue timestamp added to
whisper's segment offsets. There is no JSON array or wrapper object. This differs from the
standalone whisper-cli output and must not be parsed as that format.

The emitter supplies **no detected-language field**. Requested language, translation mode and
actual detected language are different facts: future provenance must retain requested settings,
but cannot infer a detected language from these JSON bytes. The parser reports it as unavailable.

**Upstream release blocker:** text is interpolated with `%s` inside JSON quotes without escaping.
Quotes, backslashes and control characters in recognized speech can produce invalid JSON or alter
its decoded meaning. The bounded parser refuses syntactically malformed output; it cannot identify
valid-looking escape sequences introduced by this upstream defect. Fix the attributed emitter and
rebuild/revalidate the candidate before shipping canonical JSON transcription. Do not repair raw
strings heuristically or fall back to console/SRT text. No upstream sources were modified here.

## Bounded parsing foundation

`FFmpegWhisperJSONParser` accepts the emitter's strict key order and shape, preserves original
segment text and integer timing, and derives trimmed, space-joined editable text. It refuses
unknown/duplicate keys, wrappers, nested values, noninteger/overflow timing, invalid UTF-8,
negative/reversed intervals and backward segment starts. Overlaps and zero-length intervals are
retained. Empty or whitespace-only text yields a distinct no-speech result.

Limits are 8 MiB total input, 64 KiB per line, 20,000 segments and 2 MiB editable UTF-8 text.
Line scanning avoids allocating an array for every newline. The eventual file reader still needs
an enforced incremental read limit, regular-file/path admission and successful process completion;
a parser receiving `Data` cannot establish those guarantees. It also cannot establish source
identity, provider/model provenance, successful inference completion or reviewed approval.

The tests use synthetic strings matching the inspected emitter, not live model inference. They
cover Nordic text, exact timing, overlap, escaping, malformed and unsupported JSON, invalid UTF-8,
no-speech and each independent resource bound. Build/test execution belongs to the coordinating
integration run; this investigation itself did not execute a build or model.

## Remaining integration

The source and tests are registered and pass the integrated focused checks; see
[cycle 75 validation](cycle-75-local-discovery-avif-2026-09-20.md).
Keep the parser separate from approved transcript state until subprocess success, cancellation,
exact audio identity, provider/build/model hashes and language/translation settings are validated.
Canonical persistence, signed model installation and lifecycle, admitted audio formats, offline
inference, application/review UI and the complete fault/real-audio matrix remain open.
