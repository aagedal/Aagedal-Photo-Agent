# Cycle 76 — revision-bound IPTC previews and Whisper output

Baseline `f0b22f8`, initially clean. Validated on arm64 macOS 27.0 (26A428), Xcode 27.0
(27A266a), Debug app 3.0.0 build 739. Three sub-agents owned IPTC preparation, transcript
output admission and the FFmpeg correction; the coordinator integrated, validated and
committed the work. Source commits are `acc32e8` (FFmpeg correction) and `2793597`
(IPTC preview/output reader plus help). Tests exercised those exact source changes before commit.
Cross-review found no remaining blocker in these bounded changes.
The release remains IMPLEMENTING; no complete Phase 5A acceptance criterion closes.

## Implemented

- The bundled MCP helper exposes `prepare_iptc_patch` for one explicit authorized photo.
  It requires all three source/XMP/app-sidecar revision strings from the metadata read.
  Seventeen descriptive scalar fields plus Keywords and Person Shown accept typed `set`
  or `clear`; unknown fields, duplicate operations, malformed/oversized values, stale
  revisions and XMP conflicts refuse. The existing retained snapshot reservation and final
  carrier/ancestor/authorization checks cover preparation and bounded serialization.
- Previews contain exact before/proposed values, shared legacy IIM byte-limit warnings,
  pending-draft disclosure, five-minute expiry and a content-bound preview ID. They are
  explicitly read-only and not persisted or committable. Physical normalization, preservation,
  publication approval and semantic read-back are not evaluated. This is not a completed
  two-phase IPTC transaction. Help, privacy, capability and limitation documentation agree.
- `FFmpegWhisperOutputReader` admits only absolute local no-follow paths with regular,
  singly linked files after a caller-supplied successful process exit. Reads are bounded
  by the initial length plus one growth probe and the parser's 8 MiB cap. Cancellation,
  truncation/growth/rewrites, leaf replacement and ancestor replacement refuse publication.
  Original timing/text and unavailable language evidence remain intact. Future provider job
  ownership, actual process supervision, audio/model identity and approval remain separate.
- The pinned [FFmpeg source package](../../scripts/ffmpeg/README.md), committed as `acc32e8`,
  contains the attributed original LGPL fixture, license, zero-fuzz patch, exact-hash
  preparation script and sanitizer harness. It corrects JSON escaping, preserves original
  segment text, propagates inference/allocation/write/flush/close/final-frame errors, and
  fixes overlapping sample compaction. Applying it writes only a new output file.
  No bundled or neighboring binary was rebuilt or modified.

## Verification

The final focused Swift selection passes **64 tests / four suites** in **1.419 seconds**.
It includes authorized real synthetic-JPEG metadata-read/preview execution, unchanged photo
bytes/no sidecar creation, old-token refusal and concurrent source drift; reader multi-chunk
UTF-8, unsafe files, exact limits, cancellation and replacement; existing parser/protocol tests.
The first run exposed a fixture path issue: Foundation shortened the temporary path to `/var`,
which is a symlink. POSIX `realpath` now supplies `/private/var`; production admission was not
weakened. All affected checks passed on rerun.

The final complete serial suite passes **3,106 tests / 328 suites** in **138.654 seconds**,
with zero failures or skips.
Repository validation passes, including the new self-contained C harness: **63 exact JSON
text round-trips, 13 runtime/fault scenarios and 12 allocation-failure positions** under
AddressSanitizer/UndefinedBehaviorSanitizer, plus source-hash and overwrite refusal. Staged
patch context lines initially triggered Git whitespace checks; zero-context diff formatting
preserves the exact patched source hash and passes the same harness.

The actual embedded `Contents/MacOS/photo-agent-mcp` passes initialize/discovery, read-only
preview schema, malformed preview refusal and absent commit-tool checks: four correlated
responses, exit 0, zero stderr. Binary SHA-256:
`c243e7be84882d9ecb54e0e5c5ca690071565656fe6a7c3075ce1a23fb2a7691`.
This is direct executable evidence, not native supported-client acceptance. No production
folder grants, personal photos, recipients or neighboring app files were changed. Cycle 74
remains the latest native UI evidence; this cycle changes no GUI workflow.

Initial sandboxed Xcode was unable to write its normal compiler/package caches; ordinary
cache access through the approval mechanism resolved that. Existing `MDB_MAP_FULL` host
logging and unrelated compiler warnings were observed and do not establish performance health.

Evidence (ignored under `build/`):

- `qa-v3-cycle76-focused-final.xcresult` and `.log` (passing final focused selection).
- `qa-v3-cycle76-focused-approved.xcresult` and `.log` (initial fixture failure).
- `qa-v3-cycle76-full.xcresult` and `.log` (integrated complete selection).
- `qa-v3-cycle76-whisper-patch.log`, `qa-v3-cycle76-repository-final.log`.
- `qa-v3-cycle76-bundled-helper-protocol.json` (requests, responses and executable hash).

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-cycle76-full.xcresult
python3 -B scripts/ci/test_ffmpeg_whisper_patch.py
scripts/ci/validate_repository.sh
git diff --check
```

Tested app:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.

## Remaining before release

Complete persisted/normalized patch plans and verified commit/approval/preservation/recovery;
production template, face and batch-transcription tools; shared operation admission/status/
cancellation; remaining iCloud discovery and real-client validation. Rebuild the full attributed
FFmpeg candidate with the patch, validate actual ABI/AVIO/error exits and image compatibility,
record artifact provenance, implement signed/custom model lifecycle and connect inference to
source-bound editable drafts without implicit approval. Preserved `[BLANK_AUDIO]` is currently
nonempty parser text; real-model silence handling is an explicit remaining provider gate.

Broader mandatory evidence remains: authentic Sony and external metadata round trips; offline
speech/model install/update/rollback; real iCloud/multi-Mac and FTP/FTPS/SFTP; native recovery,
keyboard/VoiceOver/IME, solar/report and display/HDR; hardware/performance/storage interruption;
qualified privacy/legal review and protected remote CI. Then inspect the exact release candidate,
obtain independent readiness review and final user acceptance. Signing, notarization and
publication remain separate authorized distribution steps. The manual checklist remains draft.
