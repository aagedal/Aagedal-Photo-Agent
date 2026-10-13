# Native face consent, durable Develop admission and receipt inspection — 2026-10-13

Baseline: `7afd91b`, initially clean. Two implementation sub-agents and an independent
reviewer continued the 3.0 handoff; the coordinator integrated project membership,
read-only receipt presentation, regression and native verification. State remains
**IMPLEMENTING**. Implementation: `18a48aa`. No complete release gate closes.

## Implemented behavior

App-side native face review binds an exact retained inventory, options and consequences
to a caller-owned native session. Full/jersey scans require explicit acknowledgement of
saved-result reset. Replacing or dismissing review revokes prior capabilities. Approval
is single use, including after durable-admission failure. A preparation-fixed monotonic
five-minute deadline prevents wall-clock adjustments extending admission; already
admitted work continues after preview expiry while checking session and frozen
configuration at retained scanner boundaries. The capability ends after the actual
worker drains. Tokens remain process-only; no helper endpoint or execution UI is added.

Develop capture now freezes complete automation configuration and each target's exact
filesystem identity alongside template, ordered carrier, decoder and writer evidence.
A private anchored journal retains that evidence with a digest, independently of
physical checkpoints. The store limits evidence to 16 MiB per capture, 128 records and
64 MiB of serialized storage, without silently evicting recovery evidence. Live review
tokens belong to one service instance and are consumed durably before consent/execution
can suspend. Reopened evidence cannot reconstruct an executable request or grant consent.
Cancellation, failed consent, drift and restart cannot replay an old review token.

Reviewed sidecar execution rechecks current native session, exact automation configuration,
template/configuration revisions and original identities/carriers/decoder facts. Every
worker authority callback checks the current and later untouched targets, preventing
same-byte inode replacement during a suspended earlier write or repeated preeffect check.
Existing managed physical checkpoints retain exact writer outcomes. Embedded destinations
refuse reviewed admission before persistence until owned-effect stages are represented.

Settings → Automation → **Face Scan Receipts** inspects the managed private archive or
an explicitly chosen original receipt folder. Missing managed storage is reported without
creating folders, locks or journals. Expand a receipt to inspect scan options, committed
thumbnail/document counts, reset, cancellation after commit and incomplete/uncertain
completion. Refresh and unreadable-archive refusal preserve evidence. Current photos and
face data are not revalidated; inspection never restores or replays scans.

## Review and boundaries

Independent review required retained native-session validation, full configuration capture,
monotonic face approval expiry and original target checks throughout preeffect admission.
The first one-shot callback proposal was insufficient: the native writer invokes authority
more than once before embedded publication. It was removed; reviewed admission explicitly
refuses embedded destinations while sidecar admission checks every callback. Final source
review passes for this bounded implementation.

Authenticated helper face review transport, production review UI/session construction,
model readiness, live progress and execution wiring remain open. The physical scanner
still uses path-based storage. Develop review UI and managed admission discovery/cleanup,
watermark dependency admission, embedded owned-effect stages, synchronous physical commit
capabilities and descriptor-anchored publication remain open. Caller-provided asynchronous
session checks do not establish authority at every synchronous XMP/JSON commit. No new
helper mutation tool is exposed. Native receipt inspection does not close those gates.

Signed Whisper provisioning and broader interoperability, hardware, accessibility,
performance, legal/privacy, remote CI and exact signed-release qualification remain open.

## Verification

Evidence: ignored `build/continuation-14/`. Host: arm64 macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a). The pinned ignored AuraFace package and cached dependencies were
copied into this worktree. Fixtures are generated disposable JPEGs, synthetic detections,
metadata and journals; recognition quality is not claimed. Debug app:
`build/continuation-14/Build/Products/Debug/Aagedal Photo Agent.app`, version 3.0.0,
build 742. This is a local continuation build, not a release candidate.

- Final focused verification passes **67 tests / six Swift suites**, zero failures/skips,
  in **1.169 seconds** (`focused-v3.xcresult`, `focused-summary.json`, `focused-v3.log`).
  It includes actual face review → native scanner → saved document → durable receipt and
  Develop capture → durable review → production sidecar writer → physical checkpoint.
- The initial integrated source passes **4,071 tests, two opt-in Sony skips, zero failures**,
  out of 4,073 tests / 398 Swift suites in **125.827 seconds** (`full.xcresult`,
  `full-summary.json`, `full.log`). The later receipt-view correction is verified by the
  final integrated run below.
- Final implementation source **`18a48aa`** passes **4,071 tests, two opt-in Sony skips,
  zero failures**, out of 4,073 tests / 398 Swift suites in **124.009 seconds**
  (`full-final.xcresult`, `full-final-summary.json`, `full-final.log`). All **15**
  changed source/test/project hashes match this commit (`source-sha256.json`).
- Final native receipt inspection passes **one test**, zero failures/skips, in
  **25.842 seconds** (`native-v4.xcresult`, `native-summary.json`, `native-v4.log`). It
  checks managed absent-storage/Refresh without creation, corrupt evidence refusal,
  accessible receipt identity/expanded state, interrupted-effect detail and exact
  archive/photo preservation. Disposable generated photo and manually constructed
  incomplete receipt fixtures exercise presentation, not recognition or recovery.
- Repository validation passes (`repository-post-native.log`). The actual persistent STDIO
  helper passes **36 tools**, strict argument refusal, exit zero and zero stderr
  (`helper.json`, `helper.log`). Model bundle verification passes (`model-bundle.log`).
  Final helper/model checks pass again (`helper-final.json`, `helper-final.log`,
  `model-bundle-final.log`). Approved post-build strict deep development-signature
  verification passes (`signature-final.log`). This is not release notarization.
- Independent service/authority review and final native-view review pass. Native session
  withdrawal, configuration drift, monotonic expiry and repeated same-byte target
  replacement regressions exercise the refused authority cases. Physical synchronous
  commit authority and descriptor anchors are deliberately not claimed. Full regression
  retains four runtime warnings and test-host `MDB_MAP_FULL` observations; the native run
  retains one runtime warning. No performance gate closes.

The first restricted Xcode attempt could not write normal compiler/package caches;
approved cache access resolved it. A cold build overlapped the evolving Develop validation
signature and failed to link mixed objects. A stable-source rerun compiled successfully.
Its new production face fixture initially expected `/private/tmp` spelling while rooted
admission correctly returned canonical `/tmp` URLs. Assertions now compare canonical
admitted targets without weakening exact inventory or persisted-file checks. The final
focused run is authoritative. The first three native attempts preserved absent/corrupt
evidence but could not expand
the standard disclosure row. Exported failure screenshots and accessibility hierarchies
show the collapsed state and hit-target mismatch. The final UI uses a named button
with explicit Expanded/Collapsed accessibility state; the fourth run verifies the
actual detail text and unchanged bytes. Failure bundles and exported evidence remain
retained. An early signature inspection overlapped an incremental build; post-build
verification is recorded separately.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-14 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-14/full-final.xcresult
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-14 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testFaceReceiptInspectionPreservesAbsentAndCorruptStorage' \
  -resultBundlePath build/continuation-14/native-v4.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-14/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

## Next actions

1. Construct authenticated native face review sessions, readiness and live receipt/progress
   presentation, then descriptor-anchor all physical scanner effects before helper execution.
2. Connect exact Develop review to native UI and managed journal lifecycle, represent embedded
   owned-effect stages, and retain synchronous rooted commit/watermark authority.
3. Continue signed Whisper model provisioning and broader release qualification.
