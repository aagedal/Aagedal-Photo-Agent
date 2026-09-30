# Cycle 115 — rooted voice-memo admission

Baseline: `7c2a43f`, initially clean. Verification used owned dirty changes; the identical
committed implementation is `99b091a`. Documentation is committed separately. No application
source changed after the final full suite and native build. State remains **IMPLEMENTING**; no whole 3.0 release
gate closes. One bounded sub-agent owned admission and regression tests, a second independently
reviewed the production relationship contract and implementation, and the parent owned integration,
verification, documentation and commits. Chat inventory found no other active chat editing this
checkout.

## Implemented behavior

- Read-only `get_photo_voice_memo` accepts exactly one absolute photo `path`, with automation
  enabled and explicit root authority. It reads only the persisted adjacent
  `.<full photo filename>.voice-memo.json` relationship. An adjacent WAV without that record
  remains undiscovered; the result reports `associationState: none`.
- Strict schema-1/2 decoding checks the current full photo filename, safe WAV basename, profile
  and optional provenance, content identities and discovery-hint types. Unsupported, stale or
  malformed relationships refuse inspection. Discovery hints are never followed or returned.
  Production's legacy renamed-filename projection is deliberately outside this helper slice;
  recover the relationship in the app before using the tool.
- The existing photo reservation and root-anchored descriptors cover photo/metadata capture,
  relationship and independently authorized WAV reads, and final publication checks. Relationship
  and audio handles remain retained through final entry, generation, ancestor and authorization
  checks. Symlinks, aliases, special files, hard links and private WAV targets are refused.
- Reads are bounded: relationship JSON is at most 1 MiB; photo bytes and WAV audio are each at
  most 256 MiB. WAV hashing streams through bounded chunks and checks the captured length plus
  one-byte growth probe. The output contains opaque photo, metadata, relationship and audio
  revisions and the WAV length; no raw audio, transcript, relationship path or profile text.
- Historical photo/audio content matches are separately nullable comparison facts. A normal
  metadata edit or replacement WAV can produce `false` without inventing recovery authority or
  invalidating the newly captured current revision. Current WAV admission uses its extension;
  `audioContentDecoded` is false and no playable-content claim is made.
- Provider readiness remains unavailable in the helper. Inspection grants no consent, starts no
  operation, inference or download, saves no draft and writes no metadata. Capability discovery,
  tool annotations and the real helper protocol probe expose the same boundary.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
All fixtures are generated and disposable; no user photos or provider/model installations are used.

- Focused serial suite: **77 tests / two suites**, zero failures, 2.437 seconds,
  `build/qa-v3-cycle115-focused-v2.{log,xcresult}`. Covers persisted-only discovery, schema/optional
  types, historical matches and edits, byte preservation, private/symlink/
  hard-link/FIFO/oversized WAVs and relationship records, fresh enablement and root authority,
  carrier/ancestor/root replacement, reservation retention and the existing batch executor.
- Final complete serial suite: **3,640 tests / 361 suites**, zero failures/skips, 99.326 seconds,
  `build/qa-v3-cycle115-full.{log,xcresult}` and `build/qa-v3-cycle115-full-summary.json`.
  Four existing Thread Performance Checker diagnostics and 340 host `MDB_MAP_FULL` messages
  leave the broader performance/environment gates open.
- Built helper protocol probe: **23 tools**, persistent/pipelined requests, malformed-input
  recovery, strict associated-audio argument refusal, honest capability/executor boundaries,
  clean exit and zero stderr. Rechecked after the native build in
  `build/qa-v3-cycle115-helper-final.{log,json}`. Helper SHA-256:
  `881db0324179e1f4fe4bfc98c16def41dca645c75336c168708178cc84562b7d`.
- Final repository validation passes in `build/qa-v3-cycle115-repository-docs-final.log`.
  Whitespace checks and 443 local links across eight changed documents pass.
- Native build-for-testing succeeds in `build/qa-v3-cycle115-ui-build.log`.
- Actual native consent/save/relaunch workflow: **one test**, zero failures, 32.115 seconds,
  `build/qa-v3-cycle115-ui.{log,xcresult}`. Verifies preview cancellation, explicit consent,
  ordered unapproved drafts, guarded current-review refresh, source/editorial preservation and
  relaunch persistence using real filesystem admission/persistence and gated synthetic provider
  recognition/readiness. It does not establish real Apple/Whisper inference or model accuracy.

Exact Xcode commands are retained at the beginning of each log. Unit runs use Debug,
`platform=macOS`, disabled automatic package resolution and serial testing. Native tests use the
UI Smoke Tests scheme and explicit named workflow selection. The rooted admission fixtures use
real filesystem reads and injected configuration; they do not alter the user's root preferences.

The initial focused build caught Swift selecting the newly added three-argument defaulted closure
for an existing two-argument trailing closure. The existing snapshot call now explicitly labels
`consume`, preserving its dispatch. The WAV hard-link regression uses an independent audio file,
so refusal exercises audio admission rather than rejecting a hard-linked photo first.

## Remaining and next actions

1. Add authenticated helper-to-app invocation bound to immutable photo/relationship/WAV revisions,
   provider parameters, native readiness and explicit consent before enabling helper transcription.
2. Qualify installed Apple and admitted Whisper providers, cancellation, relaunch and device behavior;
   connect the remaining face-scan/template executors and guarded helper commits.
3. Preserve physical crash/archive-loss, iCloud, signed Whisper lifecycle, authentic Sony/metadata/
   server/hardware, accessibility, display/HDR/solar, performance, legal/privacy, protected CI and
   exact signed-candidate gates. Final user acceptance and publication remain separate; llama.cpp
   stays deferred to 3.1.
