# Cycle 77 — revalidated IPTC plans and owned Whisper process jobs

Baseline `4e85465`, initially clean. Three sub-agents implemented the plan store, process runner,
and parser/review slice; the coordinator integrated the helper, authorization generation, tests
and documentation. Validation used arm64 macOS 27.0 and Xcode 27.0, Debug app 3.0.0 build 739.
Source is committed as `1443faa`; tests exercised those source changes before commit.
The release remains IMPLEMENTING; no complete Phase 5A acceptance criterion closes.

## Implemented

- `prepare_iptc_patch` retains immutable typed requests and exact previews in helper memory.
  `get_iptc_patch_plan` returns the same result only after fresh authorization, source/XMP/app JSON
  revisions, effective values and deadline checks. IDs are opaque; replacement arguments refuse.
  Plans have five-minute expiry, a 64-plan limit and an 8 MiB serialized-result budget. This is
  not a total resident-memory measurement. Restart discards every plan; no disk persistence,
  physical normalization, approval, write or recovery authority is added.
- Authorization saves rotate a UUID generation, while older records remain readable. Revoke/regrant
  of identical enabled/root values cannot revive a retained plan. Photo snapshot publication also
  compares the complete captured authorization configuration. Direct external restoration of old
  preference bytes is outside this API generation guarantee.
- `FFmpegWhisperJobRunner` owns a private job directory and exact size/SHA-256 checked snapshots
  of the explicitly supplied executable, WAV and model. Fixed private filenames avoid filter-path
  injection. Invocation is file-only, WAV-only, fail-fast (`-xerror`), with explicit untranslated
  output and unsplit text. Only normal exit zero followed by canonical JSON admission can return
  an inference result; it never approves text or writes photo metadata.
- The runner enforces input limits, a monotonic subprocess deadline, cancellation, output growth
  detection, direct-child teardown and owned-directory cleanup. Diagnostics are discarded, and
  report/debug/loader environment is not inherited. Output polling is not a filesystem quota;
  cleanup is best effort. The caller must still supply trusted/signature-verified artifacts,
  establish model compatibility and revalidate the photo/audio relationship before draft publication.
- Complete case-insensitive blank-audio-marker segments no longer become editable draft text.
  Original segment text/timing remains intact. All-marker output reports no speech; embedded
  literal mentions and split fragments remain text. Real-model silence/hallucination testing remains.

## Review and verification

Independent review found and closed two plan issues: preparation now advertises non-idempotency
because it allocates a new plan; older concurrent preparation completion no longer evicts a newer
live plan. Regression tests cover both. Runner review also required `-xerror` to prevent tolerated
decode errors from looking successful. No concrete finding remains in this bounded review scope.

The final focused suite passes **86 tests / six suites** in **4.706 seconds**, including all
13 runner tests and 20 immediate signal exits. The complete integrated suite passes
**3,128 tests / 330 suites** in **126.577 seconds**, with zero failures or skips. Repository
validation passes. Four existing QoS priority-inversion warnings in CaptionSessionTests and
MetadataEditorReadServiceTests plus test-host MDB_MAP_FULL logging remain observations, not
evidence that performance gates are closed. The actual embedded
helper passes four correlated protocol responses, read-only retrieval, non-idempotent preparation,
unknown/malformed plan refusal, absent commit endpoint and zero stderr. Its SHA-256 is
`a569d75da1530eb3cfe898f56be96183b65721aa51628755cd1f5dc364c16230`.
This is executable protocol evidence, not supported-client acceptance. Synthetic subprocess fixtures
exercise the process boundary, not FFmpeg/whisper inference. The production JPEG fixture covers
actual helper-service preparation/retrieval, byte preservation, source drift and revoke/regrant.

The initial sandboxed Xcode invocation could not access normal compiler/package caches; approved
cache access resolved that. The first focused build overlapped review fixes: it compiled the older
implementation and subsequently compiled the new tests, which exposed the two reviewed defects.
A subsequent focused run exposed a real `Process.waitUntilExit` hang after a signalled child
had already exited. A stack sample isolated the Foundation run-loop wait; teardown now observes
termination asynchronously without inheriting cancellation. The signal regression now performs
20 immediate exits. The same run found nondeterministic text-fallback JSON key ordering for an
otherwise identical retrieved plan; sorted serialization preserves exact text as well as typed
values. The final-source rerun is authoritative; no assertions were weakened.

Evidence is retained under ignored `build/qa-v3-cycle77-*` paths:

- `qa-v3-cycle77-focused-v3.xcresult` and `.log`: final focused verification.
- `qa-v3-cycle77-full.xcresult` and `.log`: complete integrated verification.
- `qa-v3-cycle77-repository-final.log` and `qa-v3-cycle77-bundled-helper-protocol.json`.
- Earlier `focused-approved` and `focused-final` logs/results plus
  `qa-v3-cycle77-stalled-test-sample.txt`: initial failures and diagnosed teardown hang.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-cycle77-full.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

Tested app:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
 No personal photos, production
recipients, installed model/binary, neighboring checkout, or production authorization was changed.
No GUI feature changed and no new native GUI acceptance is claimed. The draft checklist now includes
real-client preview retrieval, expiry, restart, edit and revoke/regrant cases; these remain unrun.

## Attempted full FFmpeg rebuild

Rehashed the attributed source archive and matched
`23587fed102cfe66910db1d4ae66b50565387a1750e039fb10fde6fbfd027e71`.
Extracted only FFmpeg into a new ignored build directory and applied the zero-fuzz pinned patch,
yielding filter SHA-256 `611490390f75fe07ab463046856c93a860758f898442ff808783a3d1131d7b13`.
Copied local compiled dependencies into that isolated directory, recorded all copied input hashes,
and attempted the attributed configure recipe using the copy.

Configuration refused: the available compiled prefix contains libass 0.17.4 rather than the recipe's
0.17.5 and lacks its required fontconfig/libunibreak/harfbuzz and zlib/bzip2 pkg-config dependencies.
It is not the reproducible dependency set. No dependency was silently omitted and no candidate
binary was produced. Rebuild the complete dependencies from the attributed companion sources before
retrying FFmpeg; then validate the full ABI/AVIO behavior, image compatibility and actual model.

Evidence: `build/qa-v3-cycle77-ffmpeg-build.log`,
`build/qa-v3-cycle77-ffmpeg/inputs.json`, and the extracted tree's `ffbuild/config.log`.
The shipped Photo Agent FFmpeg remains unchanged.

## Remaining before release

- Durable normalized patch plans, approval/preservation, verified commits and recovery; production
  template/Develop/face/batch-transcription tools and shared operation status/cancellation.
- Rebuilt attributed FFmpeg, complete artifact/license manifest, signed/custom model lifecycle,
  provider selection/provenance/draft integration, real audio and offline/model failure validation.
- Real MCP client acceptance and iCloud template discovery; authentic Sony/external metadata,
  multi-Mac/iCloud and FTP/FTPS/SFTP; broader native recovery/accessibility/IME/map/report/display,
  performance/hardware and storage interruption evidence.
- Qualified privacy/legal review and protected remote CI; exact-candidate package/review, final
  user acceptance, followed by separately authorized signing/notarization/distribution steps.
