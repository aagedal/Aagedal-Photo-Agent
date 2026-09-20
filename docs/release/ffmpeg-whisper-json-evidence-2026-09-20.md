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
Line scanning avoids allocating an array for every newline. `FFmpegWhisperOutputReader` now admits
only regular, singly linked files through an absolute component-by-component no-follow path walk.
Nonblocking leaf admission refuses FIFOs without waiting for a writer. Incremental reads are bounded
by both initial file size and the parser's 8 MiB cap; inode/size/mtime/ctime checks refuse observed
replacement, growth, truncation and mutation. Re-walking and comparing every ancestor identity also
refuses parent-directory substitution even if the same leaf inode is moved into the new directory.
The file and path are revalidated before parsing and after the final cancellation check.

The reader requires caller-reported normal process exit with status zero, and checks cancellation
before admission, throughout reading and before returning. These are explicit integration
preconditions, not independent evidence that a subprocess ran successfully: the future provider
must observe termination, own its private job directory and supply the correct cancellation scope.
Filesystem checks detect observed changes; they do not provide an atomic snapshot against an
arbitrary concurrent writer. Neither reader nor parser establishes source identity, provider/model
provenance, inference completion or reviewed approval.

The tests use synthetic strings matching the inspected emitter, not live model inference. They
cover Nordic text, exact timing, overlap, escaping, malformed and unsupported JSON, invalid UTF-8,
no-speech and each independent resource bound. Reader tests add process preconditions, cancellation
at admission/read/publication boundaries, symlink/hardlink/directory/FIFO refusal, oversized sparse
output, growth/truncation/same-size mutation, leaf replacement and parent substitution with the same
leaf inode. Build/test execution belongs to the coordinating
integration run; this investigation itself did not execute a build or model.

## Remaining integration

The source and tests are registered and pass the integrated focused checks; see
[cycle 75 validation](cycle-75-local-discovery-avif-2026-09-20.md).
Keep the parser separate from approved transcript state until subprocess success, cancellation,
exact audio identity, provider/build/model hashes and language/translation settings are validated.
Canonical persistence, signed model installation and lifecycle, admitted audio formats, offline
inference, application/review UI and the complete fault/real-audio matrix remain open.

## Reproducible source correction (cycle 76)

The repository now contains the exact attributed original source, a zero-fuzz patch, hash-gated
preparation script and sanitizer fault harness in [`scripts/ffmpeg`](../../scripts/ffmpeg/README.md).
The patch escapes canonical JSON, preserves original segment text and propagates inference,
allocation, write/flush/close and final-frame failures. This also exposes existing error-exit
requirements beyond the escaping defect. Original JSON cleaning changes intentionally: leading
spaces and literal `[BLANK_AUDIO]` tokens are retained. No-speech semantics require live-model
validation; the current parser considers a literal marker nonempty text.

This prepares the fix but does not close the binary blocker: no FFmpeg candidate has been rebuilt
or installed with it. Full ABI, AVIO transport, real audio/model, process failure, provenance and
image-compatibility revalidation remain required. See [cycle 76](cycle-76-iptc-preview-whisper-output-2026-09-20.md).
