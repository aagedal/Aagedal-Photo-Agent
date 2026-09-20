# Cycle 87 — model recovery and proofreading preservation evidence

Baseline: `1a8f3c6`, initially clean. Status remains **IMPLEMENTING**.
Implementation commits: `5862e72` (managed Whisper recovery) and `2708c58` (MCP semantic evidence).
Tests ran on these exact combined source changes before committing; only release notes changed afterward.

## Implementation

Managed Whisper setup suppresses cancelled transport errors and late progress, revokes
late admission receipts, and keeps installed-model retry/removal controls available after
a failed removal. Overlapping removal/download work is refused. Missing or malformed
UI-test model-root arguments now select isolated temporary storage rather than the user's cache.

Downloads reject unsafe cached links and linked ancestors before creation. Directory and
target identities are captured before inspection, rechecked after transfer, and publication
and cleanup use the admitted directory descriptor. Hash verification checks the same regular
file's identity before returning; permissions are applied to its descriptor. First installation
uses exclusive rename, so a newly appearing model cannot be overwritten. Failed transfers
preserve existing model bytes and allow retry on the same service.

MCP proofreading previews now contain canonical before/expected-after SHA-256 fingerprints
for all 42 production verification fields. They use the production comparison rules, preserve
edited intent for clears and normalized no-ops, and distinguish Headline from localized Titles.
The preservation preflight schema is now 2. Reconstruction refuses old archived previews lacking
this evidence, requiring fresh preparation before local review or consent. No mutation endpoint
or physical-verification claim is introduced.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), app 3.0.0 (739). Tests use generated local fixtures
and isolated model/preferences roots. The native target runs the Debug app in the Xcode
`Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug` directory.

Complete integrated regression passes **3,243 tests / 338 suites** with zero failures in
**118.095 seconds**. This includes all new setup/storage/preview tests and the corrected durable
legacy-preview fixture. No failure assertion or timeout was weakened.

Three native cases pass with zero failures in **83.207 seconds**:

1. Corrupt cached Base model: Settings reports size mismatch across two launches, offers explicit
   download, never becomes ready, and preserves the corrupt file and all photo/memo/transcript bytes.
2. Missing model: opening/reopening Settings starts no download and leaves Caption compact.
3. MCP native review: exact before/proposed values display and source drift prevents approval.

The rebuilt helper passes the persistent-pipe protocol/discovery probe; repository validation passes.
Native evidence is `build/qa-v3-cycle87-native.{log,xcresult}`; helper evidence is
`build/qa-v3-cycle87-mcp-probe.{log,json}`. Full-suite evidence is
`build/qa-v3-cycle87-full.{log,xcresult}`; repository evidence is
`build/qa-v3-cycle87-repository-final.log`. Xcode commands use the repository test schemes,
Debug, `-destination platform=macOS -parallel-testing-enabled NO -jobs 3`, with the result
bundle paths above. The native selectors are `testManagedWhisperRefusesCorruptCachedModelAcrossRelaunch`,
`testManagedWhisperUsesSettingsAndWaitsForExplicitModelDownload` and
`testAutomationPatchReviewDisplaysExactPlanAndRefusesChangedPhoto` in `CoreWorkflowSmokeTests`.
CUA observation of the running exact build also confirms compact Caption, disabled Transcribe and
retained approved fixture text. The native runner terminates the app and removes its fixtures.

Initial focused verification
found one new fixture error: a temporary archive path contained the `/var` alias rejected by
the production no-follow storage traversal. The fixture now uses POSIX `realpath`, matching
existing persistence tests; production protections were unchanged. Initial sandboxed Xcode
execution could not access compiler caches; the approved Xcode run used normal host caches.

Independent reviews covered setup, storage and semantic-preview changes. The cached-target
identity capture was moved before inspection in response to review. No unresolved actionable
finding remains within this bounded change.

## Remaining limits

- Semantic fingerprints describe effective values, including pending drafts. They do not prove
  physical-carrier preservation; hashes are not a confidentiality guarantee for guessable values.
  Production mutation admission, exact consent binding, writes/read-back, cancellation and recovery
  remain required before exposing commits or claiming complete operation execution.
- Replacing an existing corrupt model retains a narrow check-to-rename race with a noncooperating
  process running as the same user. First installation uses atomic exclusion. No orphan sweep,
  resumable transfer, signed update/rollback policy or power-loss durability claim is added.
- Complete corresponding-source distribution/rebuild, signed model lifecycle, broader offline/GPU/
  audio-format/accuracy acceptance, authentic Sony and server/cloud evidence, accessibility,
  interoperability and hardware/performance validation remain open, alongside qualified privacy/legal
  review, remote CI protection, final signed/notarized candidate and user acceptance.

No broad release gate is closed by this cycle.
