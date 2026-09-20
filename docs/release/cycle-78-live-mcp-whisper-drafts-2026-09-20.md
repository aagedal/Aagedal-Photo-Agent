# Cycle 78 — live MCP transport and source-bound Whisper drafts

Baseline `f4b4850`, initially clean. Three sub-agents implemented production IPTC normalization,
the explicit Whisper adapter and isolated FFmpeg rebuild preparation; the coordinator reproduced
and fixed a real persistent-client transport defect, integrated and reviewed changes, and owns
builds, native checks and commits. Application source/tests are committed as `b9054ea`; tests exercised
these changes before commit. State remains IMPLEMENTING; no complete Phase 5A gate closes.

## Implemented

- MCP STDIO now uses one POSIX read per available chunk, retaining bounded framing and EINTR
  handling. Foundation's `read(upToCount:)` waited for more bytes on an open pipe: an actual
  Claude Code connection timed out after 30 seconds, while EOF-based tests passed. A controlled
  held-open pipe reproduced no response before EOF. The new executable regression keeps input
  open across initialize, notification, ping and discovery and accumulates partial responses.
- IPTC preview schema 2 uses production typed field mutation, canonical semantic comparison and
  edited-field IIM validation. Exact `sourceValue` and `requestedValue` remain alongside normalized
  before/after and comparison rules. Empty set requires explicit clear. Source/authorization
  revalidation, immutable session retention and no-commit authority remain intact. Physical carrier
  support/preservation, active publication profile and approval are explicitly unevaluated.
- An explicit internal FFmpeg Whisper adapter feeds the existing transcription service. It requires
  caller artifact authorization, binds runner results to the exact request, revalidates WAV bytes
  and relationship after inference, and returns unapproved editable drafts. No UI selection,
  download, fallback, automatic persistence/approval or IPTC write is introduced.
- Optional strict provenance survives the existing review lifecycle: exact model/build hashes and
  byte counts, identifiers, requested language, GPU choice, fixed `translate=false`, and original
  millisecond segment timing/text. Detected language remains unavailable. Unknown/newer nested
  evidence and contradictory provider/model/language/generated text refuse decoding. Legacy
  Apple records without Whisper evidence remain readable.
- Full FFmpeg preparation requires exact attributed source and libvpx archive hashes, a fresh output
  directory, pinned canonical JSON patch, repaired HarfBuzz replay, restored omitted libvpx build
  source scripts, regenerated stale SVT CMake cache and regenerated FreeType pkg-config prefix. It bounds parallelism and refuses recipe
  download calls. No shipped binary is replaced and no model is downloaded.

## Review and automated verification

Independent review found and closed unknown nested provenance loss and contradictory record
identity acceptance. The coordinator split the value-only provenance model for the helper target
when the first build exposed its missing dependency. Review also caught partial-response assumptions
in the live-pipe regression; the final test uses newline framing with a deadline and byte limit.
No concrete blocking finding remains in this bounded reviewed scope.

Final focused tests pass **84 tests / five suites**, zero failures, in **1.093 seconds**.
They cover all registered patch fields, semantic no-ops, empty intent, production byte limits,
retained-plan checks, persistent STDIO, Apple speech regressions and seven Whisper integration tests.
The disk-backed Whisper case uses real disposable PCM WAV/relationship/sidecar files, production
lookup/hash/save/load services and fresh service instances. It verifies approval/revocation, variable
authority, unknown top-level extensions and unchanged image/audio/relationship bytes. Inference is
injected; this is persistence evidence, not real-model quality or compatibility evidence.

The complete integrated suite passes **3,140 tests / 331 suites**, zero failures/skips, in
**118.555 seconds**. Twelve QoS priority-inversion diagnostics and existing test-host MDB_MAP_FULL logging remain
observations; passing tests do not close the performance gate.
Both native UI tests pass (**2 tests**, zero failures, **55.148 seconds**): Apple and synthetic
persisted Whisper-evidence records undergo text editing, approval revocation, relaunch and explicit
reapproval. Exact Whisper evidence and WAV/relationship bytes survive. This does not exercise actual
Whisper inference or provider selection. Disposable fixtures are removed and the tested app is stopped.
XCTest emitted main-thread responsiveness and debugger lookup diagnostics; no test failure occurred.
Final repository validation passes (`qa-v3-cycle78-repository-final.log`), including the pinned C sanitizer harness and all component checks.

Commands and evidence (ignored `build/`):

- `qa-v3-cycle78-focused-final.log` / `.xcresult`: final focused run.
- `qa-v3-cycle78-full.log` / `.xcresult`: integrated run.
- `qa-v3-cycle78-repository.log`: repository validation.
- `qa-v3-cycle78-native.log` / `.xcresult`: native review lifecycle.
- `qa-v3-cycle78-clients/live-protocol.json`: three correlated responses before input closure,
  zero stderr, helper SHA-256 `604652fb8558971b0ed7058280f50933427f8f5d04d81b79fe5c50d44bb9c39b`.
- Earlier `focused` and `focused-approved`: sandbox cache refusal and missing helper type; `focused-v2`
  is the first 64-test passing checkpoint, superseded by final focused evidence.

All Xcode runs use project `Aagedal Photo Agent.xcodeproj`, Debug, destination `platform=macOS`,
`-parallel-testing-enabled NO -jobs 2`. Test scheme is `Aagedal Photo Agent Tests`; native scheme
is `Aagedal Photo Agent UI Smoke Tests`. Host: arm64 macOS 27.0, Xcode 27.0, app 3.0.0 build 739.
App path:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.

## Supported-client checks

Claude Code 2.1.236, using disposable `CLAUDE_CONFIG_DIR` under
`build/qa-v3-cycle78-clients/claude-config`, initially timed out both sandboxed and with approved
host access. The rebuilt helper reports **Connected** with the same configuration. This is actual
client launch/handshake evidence; enabled-root reads, proposals, revocation and mutation acceptance
remain unrun in that client. Production Photo Agent authorization was not changed.

Codex CLI 0.154.0 accepts the helper path through a command-line-only configuration override and
`mcp get --json`; that read-only configuration check does not prove connection or tool use. Its
configuration shape was checked against [official documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
OpenCode's installed 1.18.30 executable exits 137 before printing `--version`, both sandboxed and
with approved host execution. `codesign --verify --verbose=2` reports an invalid arm64 signature
(code or signature modified). A valid client installation is needed; its signature was not altered.
It cannot provide supported-client evidence on this host yet.
Logs/config results remain under `build/qa-v3-cycle78-clients/`. No API/model prompt was submitted,
user client configurations were not edited, and no photographs were sent to a client.

## FFmpeg rebuild

The full attributed rebuild succeeds, including all 22 requested external/platform feature flags
and the Whisper filter. Tooling is committed as `7c815f3`. The isolated arm64 FFmpeg candidate is
`build/qa-v3-cycle78-ffmpeg/dist/9.0.1/full/ffmpeg`, **55,427,144 bytes**, SHA-256
`15a27e05462f52979374f6f6fa45c3f3177345b67270b20d320927c978bf4aaf`.
FFprobe is 55,251,720 bytes, SHA-256
`06ad49d10c6e5b10fef75799ba590caf1efef9c51709887f0e44409af2dfe9a6`.
Linkage contains no Homebrew/local/compiled-prefix dylibs. Nine image cases pass decoded-sample
parity against the shipped binary. This is the existing bounded image corpus, not exhaustive
container/color/hardware acceptance. No shipped binary or component manifest was replaced.

The build exposed and repaired omitted libvpx build scripts, a skipped HarfBuzz build, retained SVT
CMake cache and FreeType pkg-config prefix. Final preparation verification regenerates the exact
recipe hashes and confirms those repairs. Xcode's resolver failed to locate installed Metal;
explicit existing `FFMPEG_METALCC`/`FFMPEG_METALLIB` recipe overrides selected Apple Metal
32023.921 from the installed cryptex. All dependencies were rebuilt in the isolated prefix.
No codec was removed and no network download was needed. The exact compiler paths, input/dependency
hashes and configure recipe are in current `cycle78-*` evidence; the archive's old `build-evidence`
files are provenance only, not validation of this binary.

Direct CPU process probes use synthetic macOS speech and an existing local **custom/unverified**
base model, SHA-256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`.
Speech exits zero and emits valid NDJSON with original whitespace; missing/malformed models exit
251, invalid destination exits 235, and direct-child termination exits 255. Five-second silence
emits preserved blank-audio markers. A separately compiled harness using the actual committed
Photo Agent runner/parser/output-reader sources successfully transcribes generated speech and
returns `noSpeech` for a separate silent WAV after exact-input snapshotting and canonical admission.
This verifies the actual runner with the candidate; it does not establish trusted artifact/model
installation or end-to-end UI inference.

Two quality findings remain: the short phrase “red bicycle” was misrecognized as “Red Vice Attorney
General”, and raw silence segment end times extended to 10–12.944 seconds for five-second audio.
Do not claim speech accuracy or source-duration-constrained timing from these probes. CPU execution
alone does not establish GPU/offline/storage-fault acceptance. No downloaded/signed model descriptor
was available, and this local model is not a curated component.

The binary grows from 19,298,560 to 55,427,144 bytes (+36,128,584). Deterministic gzip-9 size grows
from 8,253,231 to 24,514,648 bytes (+16,261,417). This is a single-binary compression proxy, not
signed app/DMG/Sparkle update size; final distribution-size measurement remains open.

Evidence:

- `qa-v3-cycle78-ffmpeg/cycle78-inputs.json`, `cycle78-artifact.json`, capability text and build log.
- `qa-v3-cycle78-ffmpeg-preparation-complete-verification.log`.
- `qa-v3-cycle78-ffmpeg-images/report.json`: nine image comparisons.
- `qa-v3-cycle78-ffmpeg-runtime/{inputs.json,results.json,run-probes.py}`: exact process probes.
- `qa-v3-cycle78-ffmpeg-runtime/runner-probe.swift`, build log and `runner-probe.log`: actual runner.
- `qa-v3-cycle78-ffmpeg-size-comparison.json`: binary/compression measurements.

## Remaining before final release

- Durable IPTC plans, physical preservation and approval binding, verified commits/recovery;
  production face, metadata/Develop template and batch-transcription tools with operation status
  and cancellation; iCloud template discovery and full real-client acceptance.
- Attributed patched FFmpeg candidate validation and component/license/size manifest; trusted model
  delivery/custom imports, explicit persisted provider selection, real-model audio/offline/failure
  tests and additional associated audio formats.
- Authentic Sony/RAW/C2PA and external metadata interoperability; multi-Mac/iCloud and real
  FTP/FTPS/SFTP; remaining native recovery/accessibility/IME/map/report/display, performance,
  hardware and storage-interruption evidence.
- Qualified privacy/legal review, protected remote CI, exact-candidate packaging and independent
  release review, final user acceptance, then separately authorized signing/notarization/distribution.
