# Retained face effects and Develop recovery inspection — 2026-10-12

Baseline: `203881b`, initially clean. Three implementation agents continued the
latest face/Develop handoff, with independent cross-review and coordinator
integration. State remains **IMPLEMENTING**; no complete release gate closes.
Implementation commits: `bc54acb` (embedded Develop authority), `540b758` (retained
face effects), `18c1a1f` (authority-aware source invariant) and `563fda0` (recovery
inspection and native accessibility fixes).

## Implemented behavior

The internal native face-scan bridge takes an exact retained session intent. Its
folder descriptor and exclusive reservation survive pending persistence, detection,
thumbnail repairs, periodic/final document saves and final presentation. Full original
inventory and authorization are checked at read/effect boundaries. Effect refusal is
terminal for that retained capability. Initial asynchronous refusal releases its
lease, unchanged scans recheck authority, and refused final reloads cannot replace
the displayed or cached snapshot. Retained scans omit secondary Known People,
roster and lens operations that do not yet accept this authority.

Completion evidence preserves committed thumbnail UUIDs, document persistence
results and full-reset results after post-effect refusal. Authority failure remains
distinct from cancellation. Production document/thumbnail savers check authority
after encoding and before atomic saving; read-only recovery loads suppress both
corrupt-file relocation and age cleanup.

Primary Develop embedded writes serialize through the existing metadata library
into a private same-filesystem staging directory. Before replacing the original,
the writer rechecks source bytes with synchronous stat/hash/stat capture and checks
retained authority again after hashing. Refusal before replacement leaves the
original intact and attempts cleanup of owned staging. Refusal after publication preserves possible
write/revision evidence. Successful replacement preserves permissions, creation
date and visibility. XMP/JSON boundaries retain their preceding checks.

Automation Settings has a separate **Develop Batch Recovery** section. Explicit
folder selection holds security scope during read-only inspection. Descriptor-based
inventory keeps corrupt, newer and inaccessible entries visible alongside valid
checkpoint summaries, bounds entry count and aggregate payload size, and creates
no missing journals or locks. Ordered photo results, active uncertain writes,
physical receipt flags, unexpected writer receipts and retention failures are
presented for review. This does not check current photo files or permit replay.

## Review and remaining boundaries

Review corrected source drift during embedded serialization, private staging,
retained lease release on early refusal, unchecked detector reads, stale unchanged
presentation and post-refusal cache refresh. Compiler verification also required
explicit closure/local-function isolation and a loop rather than an actor-isolated
closure capturing heterogeneous JSON arrays. No assertions were weakened.
Actual native inspection also exposed a parent identifier overriding recovery
control identifiers and an unlabelled disclosure triangle. Individual identifiers
now survive, and visible/accessibility batch labels share the same identity/status
text. The native test uses the real disclosure type and label/value representation,
with a canonical private fixture path rather than the runner's temporary-path aliases.

Face completion receipts remain in memory. Authenticated native consent, durable
face operations/progress/recovery and helper execution are still required. Face
Foundation saves/deletion and embedded image replacement remain path-based rather
than descriptor-anchored authorized-root mutation; same-account external namespace
races remain outside this bounded capability. Directory creation can precede later
publication refusal and is not represented as a committed photo/document receipt.
This work adds no helper execution endpoint or consent grant.

Production Develop template capture, native review, checkpoint storage-root wiring,
watermark admission and anchored physical mutation remain open. Recovery selection
is transient and inspection-only. Signed Whisper catalog/key/Settings integration,
authentic-media, accessibility, device/performance, external interoperability and
signed-candidate qualification remain the next release work.

## Verification

Verification evidence is retained under ignored `build/continuation-12/`.
Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
The pinned ignored AuraFace package and cached dependency checkouts were copied
into this worktree. Tests use disposable generated media and synthetic face records;
recognition quality is not claimed. Verification results and implementation
commit identities are recorded here. All 16 changed source/test hashes in
`source-sha256.json` match committed `563fda0`; only documentation changed afterward.
Tested app: `build/continuation-12/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 742, development signed. This is a local continuation build,
not published Beta 3 or a final Release candidate.

- Focused core verification passes **105 tests / four Swift suites**, zero failures
  or skips, in **1.188 seconds** (`focused-v4.xcresult`, `focused-summary.json`,
  `focused-v4.log`). It covers actual embedded writes/refusal/source drift/staging
  privacy, retained scan scope/lease release and post-effect receipts, and checkpoint
  discovery/projection/corruption/version/receipt evidence. The final full suite
  includes these cases after the later accessibility fixes.
- Final-source integrated regression passes **4,018 tests, two opt-in Sony skips,
  zero failures** out of 4,020 tests / 393 Swift suites, in **125.315 seconds**
  (`full-final-v2.xcresult`, `full-final-summary.json`, `full-final-v2.log`). Existing
  QoS diagnostics and test-host `MDB_MAP_FULL` logging remain observations; performance
  qualification remains open.
- All **four native workflows pass**, zero failures/skips, in **89.230 seconds**
  (`native-final.xcresult`, `native-summary.json`, `native-final.log`): complete
  two-image scan/relaunch (23.862 seconds), unreadable recovery entry selection,
  accessible name/status, refresh and exact directory/evidence/photo preservation
  (30.785 seconds), explicit jersey-scan cancellation (13.085 seconds), and historical
  thumbnail repair/relaunch with retained identities (21.497 seconds). The recovery
  case qualifies unreadable inventory, not expanded valid-checkpoint receipt UI or
  replay/consent. Face recognition quality and wider accessibility remain unqualified.
- Final bundled model and post-native development signature verification pass
  (`model-bundle-final.log`, `signature-post-native.log`). The actual embedded
  persistent STDIO helper passes with **36 tools**, strict argument refusal and
  zero stderr (`mcp-helper-final.json`, `mcp-helper-final.log`); its SHA-256 is
  `57a3c82cbe2f6bcaf1578fff3c7da9541cd97d71ca031d3964b5e7752c6d9c02`.
  `start_face_scan` remains absent. Final repository and whitespace checks are
  recorded in `repository-final.log`.
- Independent cross-review accepts the bounded implementation and final native
  accessibility correction. Desktop inventory confirms no unrelated Photo Agent
  instance before native verification and none left running afterward. The temporary
  inspection instance had no images open; its Settings selection was restored to
  General before quitting. No existing photos were edited.

The first complete suite found one stale textual source assertion for the previous
unparameterized persistence call. It now requires forwarding `effectAuthority` and
still prohibits direct view-model storage writes; independent review accepts the
stronger assertion. Initial native attempts failed application activation before
the workflows (`Running Background`); a slow desktop observation returned later.
After the desktop responded, retries found the actual accessibility defects and
test locator issues above. Earlier results/logs remain under the same evidence
directory; only the final-source outcomes are authoritative.

The initial restricted Xcode build could not write normal external compiler/package
caches. Approved Xcode access resolved that. An early bootstrap overlapped enum
changes; subsequent builds caught and corrected Swift isolation errors before any
test execution. No automatic approval review rejection blocked verification.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-12 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-12/full-final-v2.xcresult
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-12 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testCompleteFolderFaceScanPersistsAcrossRelaunch' \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testDevelopRecoveryInspectionPreservesUnreadableEvidence' \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testExplicitJerseyScanCancellation' \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testHistoricalMissingFaceThumbnailRepairPersistsAcrossRelaunch' \
  -resultBundlePath build/continuation-12/native-final.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-12/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

Native selection uses `Aagedal Photo Agent UI Smoke Tests` and the four
`CoreWorkflowSmokeTests` methods corresponding to the workflows above. Focused selectors are
`ActivityHistoryTests`, `MCPFaceScanAdmissionServiceTests`,
`DevelopTemplateBatchExecutionServiceTests` and `PrimaryDevelopWriteServiceTests`.

## Next actions

1. Connect exact retained face intents to authenticated native consent and durable
   operations/progress/cancellation/recovery; anchor source and face-data effects.
2. Wire production Develop template capture, native review, checkpoint storage-root
   discovery and watermark dependencies, with anchored physical publication.
3. Finish production signed Whisper catalog/key/Settings integration and broader
   native, authentic-media, external, device, accessibility and performance gates.
