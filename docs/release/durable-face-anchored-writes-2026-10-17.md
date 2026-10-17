# Durable face anchored writes — 2026-10-17

Continues [native adoption](durable-face-native-adoption-2026-10-16.md) on clean
baseline `f18c395`. State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

Retained incremental scans now bind a `FaceDataWriteCapability` on the serial
filesystem worker before detection or thumbnail-repair suspensions. Construction
opens the canonical folder's ancestor chain without following links and binds
existing `.face_data` and `thumbnails` directory identities without creating,
relocating or deleting files. Missing storage is created only at a separately
validated write boundary; a directory that appeared externally after binding is
refused. Corrupt-document recovery remains read-only during retained scan loading.

The same capability spans detection, thumbnail repair, periodic document saves and
the detached final partial-result save. Publication uses descriptor-relative staging,
complete writes, file synchronization, exact inode and byte readback, atomic rename,
directory synchronization and postpublication identity/authority checks. Newly
created directory entries synchronize their parent, including the photo folder.
Injected legacy savers cannot replace the capability's write path.

Failures distinguish a file that was not published from a physically published file
whose verification failed. Document evidence retains `documentCommitted` and an
error; thumbnail evidence retains the committed face ID and an error. Prepublication
failures explicitly report any storage directories created before failure, without
claiming a document/thumbnail commit. Cleanup removes only a staging entry whose
inode still matches the open staged file, preserving substituted entries.

Retained full-reset requests now refuse before legacy recursive deletion or model
detection. Ordinary native scans retain their existing implementation. Settings still
exposes no durable request consent or Start action; this slice enables no helper
execution and changes no consent, request lifetime, durable admission or receipt
correlation rules.

## Review and filesystem limits

Independent review identified missing synchronization of newly created directory
entries and lost directory-creation diagnostics. Both are corrected, with service-level
coverage for withdrawal after directory creation and postpublication document failure.
The follow-up review reports no unresolved blockers in this slice. A further
physical-path compatibility review requested explicit folder/ancestor alias and traversal
refusal coverage, which is included in the final integrated run.

Directory binding and staged publication follow the existing rooted installer pattern:
validate immediately before mutation, use retained descriptors for effects, and verify
after publication. They do not freeze external writers. POSIX directory creation/open
and staged-entry validation/rename remain separate system calls; a hostile same-user
writer can race those narrow windows. Postpublication failure preserves physical
commit evidence and prevents a successful completion claim. This is no claim of
filesystem-wide atomicity or protection against arbitrary hostile same-user mutation.

## Verification

Environment: macOS 27.0.1 (26A434), arm64. Tests use generated disposable photo bytes
and private `/private/tmp` folders. Ignored pinned AuraFace and web runtime resources
were copied from the main checkout; tracked resources were unchanged. Evidence is in
`build/face-anchored-writes/`. The first restricted Xcode invocation could not write
package/compiler caches; the approved retry uses normal cache and development-signing
access.

The initial focused run (`focused.log`) exposed Foundation's abbreviation of existing
`/private/tmp` paths to `/tmp`, even through `resolvingSymlinksInPath()`. The no-follow
ancestor walker correctly refused that system symlink, but consequently refused every
valid temporary fixture. The constructor now uses Darwin `realpath` physical components
for traversal and compares the normalized physical URL with the approved URL before
opening anything. Arbitrary folder/ancestor aliases are refused; raw `..` traversal is
also refused. It preserves the original approved URL for authority comparisons.

The corrected focused run passes **56 tests in three suites**, zero failures/skips,
in 0.619 seconds of Swift Testing runtime. Console: `focused-final.log`; summary:
`focused-final-summary.json` (zero runtime warnings). Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_16-59-17-+0200.xcresult`.
The command is:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/FaceDataWriteCapabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FaceFolderLoadServiceTests' test
```

The complete regression rebuilds the final source with the same command and no
`-only-testing` arguments. It passes **4,245 tests in 410 suites**: 4,243 passed,
zero failures and the two existing opt-in Sony fixture skips, in 147.385 seconds of
Swift Testing runtime. Console: `integrated.log`; summary: `integrated-summary.json`
(zero runtime warnings). Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_17-01-39-+0200.xcresult`.
This also verifies the final ancestor-alias/traversal coverage added after the
corrected focused run. Neither final console records Main Thread Checker or Thread
Performance Checker messages. These are regression results, not performance qualification.

Repository validation passes (`repository.log`) with module caches directed to
`/private/tmp/aagedal-anchored-module-cache`. The actual persistent-pipe helper probe
passes all **41 tools** (`helper.json`, `helper.log`); model validation passes
(`model.log`). Final-source repository checks also pass (`repository-final.log`).
The final completed app passes the helper probe (`helper-final.json` / `helper-final.log`;
41 tools), bundled model validation (`model-final.log`) and deep/strict development
signature verification with certificate access (`signature-final.log`). The restricted
signature attempt could not establish certificate trust (`signature.log`); the normal
trust-store-access retry passes. No distribution-signature claim follows.

Final app: `/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app`,
3.0.0/build 742. Source/test/project hashes are in `source-sha256.json`; executable,
helper and metadata hashes are in `artifact-sha256.json`. Nothing was pushed or published.

The initial run also had a delayed XCTest session handshake. Process samples show
`XCTestDriver._prepareTestConfigurationAndIDESession` waiting before any case ran;
read-only native UI inspection found no blocking prompt. This is diagnostic evidence,
not native workflow or performance qualification. No consent/scan action was invoked.
Existing `MDB_MAP_FULL` startup diagnostics remain.

## Remaining work

Implement descriptor-based reset/deletion traversal with exact partial-deletion
evidence, cancellation and consent-withdrawal behavior; test directory replacement,
links and failures before and after each physical removal. Then connect explicit
native durable scan/reset consent, Start, and durable completion-record/history
context. Actual provider interaction, real-volume latency, accessibility, Instruments
and distribution qualification remain separate gates. This storage slice closes no
whole release gate.
