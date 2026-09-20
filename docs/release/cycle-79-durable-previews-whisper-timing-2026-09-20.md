# Cycle 79 — durable previews and sample-bound Whisper timing

Baseline `324fce0`, initially clean. Three sub-agents implemented durable preview storage,
custom artifact identity admission and the FFmpeg timing correction. The coordinator owns
production integration, review, builds, native checks and commits. Application/source tests and
user-facing disclosures are committed as `85f114f`; timing tooling is `ded6151`. Tests ran on
that source before commit. State remains IMPLEMENTING.
No complete Phase 5A release criterion is newly closed.

## Implementation

- The bundled helper now stores immutable read-only IPTC previews in the private local
  `~/Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans` archive.
  Opaque IDs survive restart within their original five-minute lifetime. Every retrieval
  rechecks current authorization generation, exact photo/carrier revisions and the complete
  freshly reconstructed production preview. No approval or commit authority is added.
- Descriptor-relative no-follow traversal, private permissions, shared process locking,
  bounded reads, atomic replacement and file/directory identity checks protect persistence.
  Schema, checksum and unknown nested authorization fields fail closed without overwriting
  the archive. Limits remain 64 live previews / 8 MiB of result data, with a separate bounded
  serialized archive allowance. Checksums detect corruption; they do not authenticate content
  against the same local account. The caller cannot supply replacement values at retrieval.
- Expiry prevents use immediately; physical pruning occurs on the next successful preparation.
  Interrupted writes can leave private temporary files. Help, Settings and privacy text now
  disclose local retention and manual archive removal. Corrupt/newer stores require recovery;
  this is not a durable committable transaction or automatic recovery service.
- Custom Whisper artifact admission records exact regular-file bytes, hashes, sizes and
  filesystem identities without executing files. Session receipts have a 16-entry bound and
  explicit revocation. Utility-executor hashing supports cancellation. Provenance is always
  labeled custom/unverified; matching hashes do not prove compatibility, signing or licensing.
  The provider now rechecks artifact authorization after inference before returning a draft.
  Persisted bookmarks, import UI, execution consent and curated delivery remain open.
- The pinned FFmpeg emitter now bounds normalized timestamps to the actual supplied samples,
  using integer sample origins across chunks. Model ticks are clipped before multiplication;
  padded and reversed intervals cannot exceed the chunk end. These are normalized emitter
  timestamps, not unchanged raw model timing. The shipped FFmpeg binary is unchanged. Timing source/tests are committed as `ded6151`.

## Verification

Final focused validation passes **79 tests / five suites**, zero failures, in **1.779 seconds**.
Repository validation passes, including the source-pinned sanitizer harness. The complete integrated suite passes **3,154 tests / 332 suites**, zero failures,
in **128.906 seconds** (`qa-v3-cycle79-full.log` / `.xcresult`). The first attempt was denied Xcode cache access; approved builds
then exposed a missing nonisolated flock declaration and a nested Swift Testing macro. Both were
fixed. The initial executable run passed other scopes but failed seven durable fixture cases:
Foundation returned `/var/...`, while no-follow admission correctly requires `/private/var/...`.
A standalone persistence probe demonstrated failure for the Foundation path and successful
write/read for POSIX realpath; production Application Support already matched realpath.
Only fixture construction changed; no file-safety check was relaxed.

Independent reviewers checked timing, custom identity admission, durable storage and final production
integration. Findings addressed include nested authority field loss, bounded receipt/capacity handling,
real-photo set/clear restart checks and lock contention. Remaining process/crash and provider acceptance
limitations are explicit. A direct actual-helper persistent-pipe probe passes initialize/discovery,
restartable-plan description, absence of commit tools and clean EOF (11 tools, zero stderr).
Helper SHA-256: `10d97aae25f460d939e083ff3f9ebab34e0528eaa23a7b9b20e03e1f639b1b77`.

All Xcode tests use project `Aagedal Photo Agent.xcodeproj`, Debug, scheme
`Aagedal Photo Agent Tests`, `-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2`.
Focused selection includes MCPServerCoreTests, MCPIPTCPatchPreparationTests,
MCPIPTCPatchPlanStoreTests, FFmpegWhisperArtifactAdmissionServiceTests and
FFmpegWhisperTranscriptionProviderTests. Host is arm64 macOS 27.0 / Xcode 27.0;
app version 3.0.0 build 739. Logs and xcresults use the `build/qa-v3-cycle79-` prefix.

The sanitizer harness passes 63 exact text roundtrips, 14 runtime/fault scenarios,
11 timing cases and 12 allocation-failure positions. Independent timing review found no
blocking arithmetic or chunk-origin defect. The harness extracts transcription functions;
it does not independently exercise `filter_frame` incoming time-base assignment.

The isolated cycle-78 configured source/dependency tree was incrementally rebuilt after
saving its previous filter source. This is reuse of the attributed dependency build, not a
new clean reproduction. The revised source SHA-256 is
`eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71`.
Candidate FFmpeg SHA-256 is
`54f5d1c12e9d2a735059fed43f8f134ff24a527c295ec819cad77185db667c33`.

Actual CPU probes with the existing custom/unverified model pass: missing/malformed model
and invalid output destinations fail, generated speech emits bounded timing, silence emits
only blank-audio markers, and direct-child termination exits unsuccessfully. Five-second
silence now emits intervals `[0, 2944]` and `[2944, 5000]` milliseconds. Speech ends at
4,824 milliseconds. The “red bicycle” recognition error remains; timing correctness does
not establish model quality. All nine synthetic image comparisons retain decoded-sample
parity with the shipped artifact. A separately compiled harness using the actual Swift
runner/parser/output-reader sources also passes bounded speech and `noSpeech` silence
with this revised executable; this remains custom-model CPU evidence, not provider UI acceptance.

Evidence under ignored `build/`:

- `qa-v3-cycle79-ffmpeg/{af_whisper.c,af_whisper.previous.c,build.log}`.
- `qa-v3-cycle79-ffmpeg-runtime/{run-probes.py,results.json,probes.log}`.
- `qa-v3-cycle79-ffmpeg-images/report.json`.
- `qa-v3-cycle79-ffmpeg-runtime/{runner-probe.swift,runner-build.log,runner-probe.log}`.
- `qa-v3-cycle79-focused*.log` / `.xcresult` and repository logs.
- `qa-v3-cycle79-helper/{probe.py,results.json,probe.log}`.
- `qa-v3-cycle79-plan-storage-probe/{main.swift,coordinator-results.log}`.

## Native disclosure check

After the final-source full suite, the coordinator launched the exact Debug app at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Cmd-comma → Automation exposes the full retention explanation in the accessibility tree.
A screenshot confirms the text wraps within the Settings layout. Enablement stayed off and
no folders were authorized. The lower privacy section now distinguishes ordinary inspection
from archived previews. The General tab was restored and the app quit normally. The first
name-based launch resolved the older `/Applications` app; that was identified from its helper
path, closed, and excluded from final-candidate evidence. An initial computer-use call took
approximately 14 minutes to return; subsequent exact-path interactions completed normally.
No photo data, automation authority or client configuration was changed.

This is narrow native disclosure/layout evidence. It does not establish VoiceOver speech,
real-client two-helper restart, process-contention or crash/storage-fault recovery acceptance.

## Remaining before release

Guarded IPTC approval/preservation/verified commits and recovery; production MCP workflow
operations/status/cancellation and full supported-client acceptance; trusted Whisper artifact
and model lifecycle, provider UI/bookmarks, additional audio formats, real-model quality,
offline and failure testing; authentic Sony/RAW/C2PA and external metadata interoperability;
real FTP/FTPS/SFTP, iCloud/multi-Mac and storage interruption; broad native accessibility,
map/report/display and performance evidence; qualified legal/privacy review and protected
remote CI; exact-candidate package/independent review, final user acceptance and separately
authorized signing/notarization/distribution. General llama.cpp/GGUF remains deferred to 3.1.
