# Cycle 74 — Template import authority, MCP discovery and local FFmpeg boundary

Baseline: `44189fb`, clean at initial inspection. Independent agents implemented import
preview authority and MCP discovery; a third reviewed integrity/security and investigated
the Whisper-capable artifact. The coordinator owns integration, validation and commits.
No release-readiness gate is claimed complete. FFmpeg source/tests are committed as `e93ab1d`; template import and MCP discovery source/tests as `b08d678`.

## Implemented

Metadata template import previews retain the decoded bundle, canonical storage directory,
directory identity and exact JSON inventory bytes. Confirmation refuses changed inventory,
new target occupancy, replaced/switched roots, malformed targets and ambiguous UUIDs before
writing. Between entries the importer revalidates the expected inventory and advances its
own authority using exact emitted serialization, never a reread that might adopt peer bytes.
Partial failure/cancellation retains the exact completed IDs/counts. Reopening the bundle
creates a fresh review; editing the source bundle after preview cannot substitute new input.
Noncooperating filesystem writers still have the existing check/write race.

The bundled MCP helper exposes read-only `list_templates` with `kind: metadata | develop`.
Discovery requires enabled automation, a configured custom Templates folder, template iCloud
sync disabled, and explicit root authorization. It returns UUIDs, names, schema and SHA-256
content revisions; field values and disk paths are omitted. Header validation is deliberately
separate from application semantics and the result declares no application authority.
Default/private and iCloud template libraries remain unavailable through this endpoint.

Discovery holds the shared folder reservation, opens no-follow descriptor-relative entries,
rejects links and special files, checks canonical UUID filenames and unique IDs, captures
bounded exact bytes, repeats inventory validation, and rechecks configured scope, authorization
and anchored ancestors immediately before publication. Limits are 256 JSON entries, 4096
scanned directory entries, 1 MiB/file, 8 MiB/inventory and 1024 UTF-8 bytes/name, plus the
existing serialized tool-result limit. Refusal messages do not expose file contents.

FFmpeg image operations now pass through one private invocation boundary: exactly one absolute
local input and output, no NUL bytes or protocol overrides, `file` protocol allowlists before
both input and output, and disabled stdin interaction. This follows the protocol option model
in [FFmpeg's primary documentation](https://ffmpeg.org/ffmpeg-protocols.html). It preserves
local filenames as argv elements and is not a sandbox for references to other local files.
The shipped photo-only FFmpeg binary is unchanged.

## Verification

The final focused run passes **67 tests / five suites**, zero failures/skips, in 2.577 seconds
(result-bundle summary verified). It includes template file authority, MCP discovery/core, local
FFmpeg boundary and AVIF encoding. The first executed focused run exposed a test fixture that
passed a `/var` alias to an injected worker while production uses the canonical `/private/var`
root; the fixture now uses the captured authority URL without weakening production validation.
The full integrated suite passes **3,072 tests / 325 suites**, zero failures/skips, in 124.380 seconds
(result-bundle summary verified). Twelve Thread Performance Checker entries and preexisting
`MDB_MAP_FULL` diagnostics remain observations. Native results follow below.

The built executable passed initialize, tools/list and invalid-kind refusal with three valid
JSON-RPC responses, exit 0 and zero stderr bytes. No app authorization preferences changed.
Evidence: `build/qa-v3-cycle74-protocol.json` and the actual embedded executable probe `build/qa-v3-cycle74-protocol-bundled.json` (SHA-256 `71622808020e4f15793bf0fa84099a80debc61ba78f62654b45a5088ef8da4c8`). This is not supported-client end-to-end validation.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-cycle74-full.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

Logs/result bundles use `build/qa-v3-cycle74-*`.
Host: arm64 macOS 27.0; Xcode macOS 27 SDK. Debug app version 3.0.0, build 739. Initial sandboxed Xcode failed before building because
package caches were outside the writable roots. Approved normal Xcode access resolved this.
The next integration attempt overlapped the new helper source before project registration and
failed on its missing type; source and test registrations are now included.

Independent review found a post-save authority race and the final bookmark-resolution revocation
window; both were corrected with regression coverage. Repository validation passes, including the final run after newly tracked sources and privacy/help updates. Evidence: `build/qa-v3-cycle74-repository-final.log`.

## Native verification

The complete UI smoke target executed 15 cases in 318.680 seconds: 13 passed, the explicitly
opt-in installed-language speech drill skipped, and the new import test failed on an incorrect
file-picker accessibility assumption before reaching preview. The test expected a ComboBox;
this macOS exposes the Go to Folder editor differently. Its keyboard flow now enters the path
without depending on that element type. No application code changed; the targeted corrected
import drill passes in **36.892 seconds**, zero failures, in
`build/qa-v3-cycle74-ui-import-v6.xcresult` (sibling log). Across the initial complete run and
corrected focused rerun, **14 distinct native checks pass and one opt-in speech case is skipped**.
This is combined coverage, not a claim that the initial unfiltered UI invocation was green.

Intermediate targeted runs exposed a Touch Bar duplicate Open button, a macOS static-text
label/value query difference, and an extra Return that confirmed an already-present preview
when reopening the same file. The test now follows the native keyboard picker and checks
whether preview is already visible before another Return. An intervening run stopped during
app launch before Settings; no new Photo Agent crash report was found and its cause is not
established. Later runs reached the workflow. None of these corrections changed app source.

The passing run verifies the actual conflict text, exact peer-byte preservation, a fresh
preview, visible replacement name and decoded saved JSON. Existing browser/search, Caption,
Batch Rename, Deadline, recovery, Known People, template-editor conflict, transcript review/
relaunch and one/two-photo application checks passed in the full run. Test teardown removes
fixtures; CUA inventory confirms all Photo Agent app entries and the UI runner stopped. All runs
use disposable local fixtures and the existing opt-in test storage routes. App path:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-cycle74-ui.xcresult
```

The installed-language speech test requires `APA_RUN_NATIVE_SPEECH=1`; this invocation does
not opt into it. A skip is not evidence of installed-language/offline transcription completion.
The new template import test uses the real Settings import picker, modifies fixture bytes after
preview, expects refusal with exact peer-byte preservation, then opens a fresh preview and verifies
the confirmed replacement's JSON and visible name. It does not bypass the normal confirmation UI.

## Whisper artifact investigation

The local Media Converter binary is a candidate, not the installed Photo Agent artifact:

- SHA-256: `25ee9d7ecd96c81b18cf5970e58201f4c94c4b1f5b4dea51c765aa28c639afd2`.
- Size: 54,661,504 bytes; arm64; Whisper JSON filter present.
- Evidence in the neighboring Media Converter checkout:
  `docs/provenance/4.4-local-builds/ffmpeg-attributed-build/`, including
  `binary-replacement.json`, `evidence.json`, `source-input-coverage.json`, `recipe/`, `rebuild/`
  and source-archive reference. All 2074 recorded compiler inputs have coverage.
- Live capability comparison found none of the current Photo binary's listed 8 encoders,
  28 decoders, 16 filters, 4 muxers or 29 demuxers missing. Listing parity is not pixel/color proof.
- Direct execution against the tracked synthetic TIFF fixture passed PNG/AVIF/JXL encoding
  and AVIF/JXL PNG decoding with file-only input/output policies. HTTP input was rejected by the
  whitelist before connection. Evidence: `build/qa-v3-cycle74-ffmpeg/results.json` and sibling logs.
  Fixture SHA-256: `dc6f93ee87d0c1346d0509cc1b3264f9499009642838e54ece8c512ebfe45998`.

Full image/HDR/color regression, local nested-reference policy, bundled provenance/notices,
size measurement and package verification must precede artifact replacement. Whisper provider,
canonical JSON/provenance, signed model lifecycle and generalized audio admission remain open.

## Remaining release work

Complete default/iCloud template discovery or explicitly resolve its required scope, full shared
template application, operation status/cancellation, face/transcription tools and two-phase IPTC
mutations. Complete Whisper integration and its runtime/model fault matrix. Broader native,
VoiceOver/IME, authentic Sony, archive/reassociation/transcript/delivery, real-server/cloud,
interoperability, hardware/performance, legal and remote-CI evidence remain open. Final candidate
packaging, independent readiness review and user acceptance follow those gates; signing and
publication remain separately authorized distribution steps.
