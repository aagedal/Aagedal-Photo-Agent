# Cycle 116 — immutable transcription batch previews

Baseline: `94683a8`, initially clean. Verification used owned dirty changes; the committed
implementation is `eacb4d3`. A single trailing space was removed while staging, with no Swift-token
change; that difference is recorded separately below. State remains **IMPLEMENTING**; no whole 3.0 release
gate closes. One sub-agent owned the plan store, whole-set facade, tool integration and regression
tests; another independently reviewed the design, implementation and documentation. The parent
owned integration, builds, native testing, documentation and commits. Chat inventory found no other
active chat editing this checkout.

## Implemented behavior

- `prepare_voice_transcription` accepts one to eight explicitly ordered photos, each with the exact
  source, app-sidecar, XMP, relationship and audio revisions from `get_photo_voice_memo`. Provider,
  language, translation and GPU requests are explicit. Unsupported options, malformed tokens,
  missing relationships and shared photo/metadata reservation ownership refuse the entire batch.
  Distinct photos may legitimately share one WAV; requested order survives sorted lease acquisition.
- Every photo reservation, immutable photo/metadata snapshot, anchored carrier validator and
  relationship/WAV witness remains retained through whole-set checks before and after private plan
  publication. The retained source/metadata bytes have a 256 MiB aggregate limit; existing individual
  relationship and streaming WAV bounds remain. Earlier inputs changing during later capture,
  publication-time relationship/WAV changes and changed root authority cannot publish a result.
- Plans bind the complete captured authorization configuration and options. The private durable
  archive at `Automation/VoiceTranscriptionPlans` permits at most 64 live plans and an 8 MiB
  serialized-preview budget, with a nonblocking process lock covering reload and replacement.
  Plans expire after five minutes; successful preparation prunes expired records. Inspection neither
  prunes nor rewrites the archive. Newer, corrupt and checksum-valid unknown schemas/fields or
  untruthful authority flags refuse restoration without overwriting the archive. Checksums detect
  corruption and do not authenticate consent.
- `get_voice_transcription_plan` accepts only the returned lowercase canonical UUID `planID`.
  It revalidates every input, exact root grants and expiry, and returns the unchanged preview.
  Changed carriers, revoked/regranted authority and clock rollback require a fresh preparation.
- Preparation is annotated as a private coordination mutation; retrieval is read-only. Neither
  starts an operation, inference or download, creates a transcript draft, approves text or writes
  photo metadata. Provider readiness and executable/model identity remain explicitly unresolved.
  Apple locale syntax does not establish installed-language support; Whisper options do not admit
  an executable/model. Native review handoff and authenticated execution remain unfinished.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures are generated and disposable; tests do not authorize user folders, use user photos or
install providers/models.

- Final focused serial suite: **92 tests / four suites**, zero failures, 2.235 seconds,
  `build/qa-v3-cycle116-focused-final.{log,xcresult}`. Covers ordered/native provider intent,
  saved-schema restoration and immutable inspection, all carrier/authority drift, expiry/rollback,
  cross-store capacity, malformed inputs/storage, shared WAV and metadata ownership, all-photo lease
  retention, and first-item changes during later capture/publication. Existing core, template-batch
  and native transcription executor suites also pass.
- Complete serial integrated suite: **3,653 tests / 362 suites**, zero failures/skips,
  119.774 seconds, `build/qa-v3-cycle116-full.{log,xcresult}` and
  `build/qa-v3-cycle116-full-summary.json`. Four existing QoS warnings and 340 host `MDB_MAP_FULL`
  messages leave broader performance/environment gates open.
- Built helper protocol probe: **25 tools**, persistent/pipelined requests, malformed-input recovery,
  strict preview/retrieval argument refusal, accurate storage-mutation annotations and capability
  discovery, honest unavailable executor/provider boundaries, clean exit and zero stderr.
  `build/qa-v3-cycle116-helper-final.{log,json}` records SHA-256
  `4e3b67acd23749890addaf00eac7c9229b7db4323dafb03f1756f5574de6d2e7`.
- Final repository validation passes in `build/qa-v3-cycle116-repository-final.log`; whitespace
  checks and 446 local links across nine changed documents pass (`build/qa-v3-cycle116-links.json`).
- Native build-for-testing succeeds in `build/qa-v3-cycle116-ui-build.log`.
- Actual native consent/save/relaunch and provider/changed-WAV refusal: **two tests**, zero failures,
  58.853 seconds, `build/qa-v3-cycle116-ui.{log,xcresult}` and
  `build/qa-v3-cycle116-ui-summary.json`. Preview cancellation, explicit consent, ordered unapproved
  drafts, guarded review refresh, source/editorial preservation, relaunch persistence and refusals
  pass using real filesystem admission/persistence with gated synthetic recognition/readiness.
  This does not establish real Apple/Whisper inference, model accuracy or spoken accessibility.

Exact Xcode commands are retained at the start of each log. Unit runs use Debug, `platform=macOS`,
disabled automatic package resolution and serial testing. Native tests use the UI Smoke Tests
scheme and explicit named workflows. Final application/project/test file hashes are retained in
`build/qa-v3-cycle116-source-hashes.json` and checked against the tested source. The verified
single-space cleanup is recorded in `build/qa-v3-cycle116-post-test-whitespace.json`; all other
application/project/test bytes match, and no executable behavior changed after testing.

Independent review caught missing post-storage whole-set revalidation and overly permissive
restored-input shapes; both were fixed before final verification. Integration also corrected valid
team-creation preference decoding and placed cheap argument parsing before disabled-authority
refusal. The initial focused runs caught test expectations for reservation collisions (`busy`) and
Foundation's canonical temporary-path spelling; the final assertions now test those actual contracts.
The initial sandboxed helper build could not write Xcode caches; authorized build/test/report access
passes. These diagnostics do not constitute release or real-provider qualification.

## Remaining and next actions

1. Add a separate epoch-bound native transcription review handoff and exact operation linkage.
   Existing IPTC purpose/kind/retirement/UI rules must not be reused by merely adding an enum value.
2. Bind native consent and execution to the exact persisted relationship carrier, rooted photo/WAV
   evidence, admitted provider/model identity and requested options. Current native preparation binds
   parsed relationship equality; the helper intent preview alone grants no authenticated invocation.
3. Qualify actual Apple/Whisper inference, cancellation/relaunch/offline/device behavior and signed
   model lifecycle; connect remaining face-scan/template executors and guarded helper commits.
4. Preserve physical crash/archive-loss, iCloud, authentic Sony/metadata/server/hardware,
   accessibility, display/HDR/solar, performance, legal/privacy, protected CI and exact signed-candidate
   gates. Final user acceptance and publication remain separate; llama.cpp stays deferred to 3.1.
