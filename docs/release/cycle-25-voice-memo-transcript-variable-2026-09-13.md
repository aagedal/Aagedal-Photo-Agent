# Cycle 25 — exact-approved voice-memo transcript variable

**State:** COMPLETE for the shared resolver and exact approval authority. Overall 3.0 readiness
remains **IMPLEMENTING** because the dedicated affected-image preview, Deadline WAV policy,
transcription failure breadth and native/offline/Sony/application evidence remain open.

## Source and scope

- The implementation continues cycle 24 checkpoint `7b67354` on `main`.
- `{voiceMemoTranscript}` is now a carrier-neutral entry in the shared variable catalog and
  `PresetVariableInterpolator`. It is not an IPTC field and approval alone still mutates no
  descriptive metadata.
- The variable accepts only nonempty reviewed text with an explicit approval timestamp after the
  current persisted relationship, association profile, WAV byte count and SHA-256 have been
  revalidated. Generated or edited-but-unapproved drafts do not resolve.
- Batch resolution loads a separate authority for every photo. The authority is retained with the
  immutable variable write request and compared with a freshly validated authority immediately
  before both initial and retried metadata execution.
- Substitution happens after ordinary and recursive field-variable processing. Braces contained in
  spoken or reviewed transcript text are literal content and cannot execute `{date}`, `{field:…}`
  or another template token.

## Metadata boundary

The implementation uses the existing explicit template/variable action, Append/Replace choice,
per-photo metadata history and verified write/recovery machinery. Missing, unapproved, source-stale
or changed approval produces a scoped failure before that photo enters the write executor. The
captured editor/template request remains recoverable under the existing variable-conflict contract;
no resolver silently clears a destination or substitutes empty text.

This slice does not claim the remaining dedicated affected-image preview. It also does not yet
restrict or explain compatible target fields in presentation, prove application through a native
relaunch/read-back drill, or define WAV delivery disposition.

## Automated verification

- The focused run passes 55 tests across `PresetVariableInterpolatorTests`,
  `CaptionVoiceMemoTranscriptionTests` and `VariableMetadataCallerTests`. New coverage proves direct
  and recursive resolution, literal nested braces, unresolved context behavior, exact approved
  context loading, unapproved refusal, per-photo batch isolation and changed-approval refusal before
  executor mutation.
- The final complete serial suite passes 2,886 tests in 314 suites with zero failures in 119.565 seconds.
- `scripts/ci/validate_repository.sh` passes generated documentation, release metadata,
  JSON/property-list/project parsing, bundled component/model provenance, logger/investigation
  privacy, conflict-marker and whitespace checks.
- Existing compiler warnings and synthetic LMDB map-full diagnostics remain visible. No new warning
  is attributed to this slice. Independent source review and native application were not run.

## Remaining work

1. Add a dedicated pre-mutation affected-image preview with compatible destinations and exact
   Append/Replace results, including partial-batch refusal without hidden writes.
2. Add visible Deadline WAV include/exclude policy and record disposition in delivery receipts.
3. Complete unsupported/offline, installation cancellation, empty/malformed audio,
   consumer/finalization failure, long-file cancellation and reservation-limit tests.
4. Run native download/failure/retry, installed-offline recognition, permission, navigation,
   relaunch, variable application/read-back and authorized Sony WAV checks.
5. Broaden lifecycle evidence through real archive/recovery/reassociation and physical volumes.
